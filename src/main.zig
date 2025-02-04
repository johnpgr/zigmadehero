const std = @import("std");
const builtin = @import("builtin");
const game = @import("game.zig");

const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
});

const OffscreenBuffer = struct {
    texture: ?*c.SDL_Texture,
    frect: c.SDL_FRect,
    memory: ?[]u32,
    width: i32,
    height: i32,
    pitch: i32,
    bytes_per_pixel: i32,
};

const DebugTimeMarker = struct {
    output_play_cursor: i32,
    output_write_cursor: i32,
    output_location: i32,
    output_byte_count: i32,
    expected_flip_play_cursor: i32,
    flip_play_cursor: i32,
    flip_write_cursor: i32,
};

const WindowDimension = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const AudioRingBuffer = struct {
    size: i32,
    write_cursor: i32,
    play_cursor: i32,
    data: ?[]u8,
};

const SoundOutput = struct {
    samples_per_second: i32,
    running_sample_index: u32,
    bytes_per_sample: i32,
    buffer_size: i32,
    safety_bytes: i32,
};

const GameCode = struct {
    lib: ?std.DynLib,
    lib_last_write_time: ?i128,
    updateAndRender: ?game.UpdateAndRender,
    getSoundSamples: ?game.GetSoundSamples,

    pub fn unload(self: *GameCode) void {
        if (self.lib == null) return;

        self.lib.?.close();
        self.lib = null;
        self.updateAndRender = null;
        self.getSoundSamples = null;
    }
};

const RecordedInput = struct {
    input_count: i32,
    input_stream: []game.Input,
};

const ReplayBuffer = struct {
    path: []const u8,
    handle: std.io.StreamSource,
};

const State = struct {
    total_size: u64,
    game_memory_block: []u8,
    replay_buffers: [4]ReplayBuffer,
    recording_handle: std.io.StreamSource,
    playback_handle: std.io.StreamSource,
    input_recording_index: i32,
    input_playback_index: i32,
    build_path: []const u8,
};

const CHANNELS = 2;
const SAMPLES = 512;
const LEFT_DEADZONE = 7849;
const RIGHT_DEADZONE = 8689;
const MAX_CONTROLLER_HANDLES = game.MAX_CONTROLLERS;
const INITIAL_WINDOW_WIDTH = 1280;
const INITIAL_WINDOW_HEIGHT = 720;

var global_game_width: i32 = 0;
var global_game_height: i32 = 0;
var global_running: bool = true;
var global_pause: bool = false;
var global_x_offset: u32 = 0;
var global_y_offset: u32 = 0;
var global_backbuffer: OffscreenBuffer = undefined;
var global_ringbuffer: AudioRingBuffer = undefined;
var global_perf_count_frequency: u64 = 0;
var global_gamepad_handles: [MAX_CONTROLLER_HANDLES]*c.SDL_Gamepad = undefined;
var global_haptic_handles: [MAX_CONTROLLER_HANDLES]*c.SDL_Haptic = undefined;

pub fn copyFile(source: []const u8, target: []const u8) !void {
    const src_file = try std.fs.cwd().openFile(source, .{});
    defer src_file.close();

    const dst_file = try std.fs.cwd().createFile(target, .{});
    defer dst_file.close();

    try src_file.copyRange(0, src_file.getEndPos(), dst_file, 0);
}

pub fn getLastWriteTime(filename: []const u8) !i128 {
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    const stats = try file.stat();

    return stats.mtime;
}

pub fn getSharedLibExt() []const u8 {
    return comptime switch (builtin.target.os.tag) {
        .windows => "dll",
        .macos => "dylib",
        .linux => "so",
        else => @compileError("UNSUPPORTED OS"),
    };
}

pub fn loadGameCode(lib_path: []const u8, temp_lib_path: []const u8) !GameCode {
    var result: GameCode = undefined;
    result.lib_last_write_time = getLastWriteTime(lib_path);

    try copyFile(lib_path, temp_lib_path);

    result.lib = try std.DynLib.open(temp_lib_path);
    result.updateAndRender = result.lib.lookup(game.UpdateAndRender, "updateAndRender") or return error.GameUpdateAndRenderNotFound;
    result.getSoundSamples = result.lib.lookup(game.GetSoundSamples, "getSoundSamples") or return error.GameGetSoundSamplesNotFound;

    return result;
}

pub fn audioCallback(userdata: ?*anyopaque, data: [*]u8, length: c_int) callconv(.C) void {
    if (userdata == null) {
        c.SDL_LogWarn(c.SDL_LOG_CATEGORY_APPLICATION, "AudioCallback: user_data is null");
        return;
    }

    const ring_buffer: *AudioRingBuffer = @ptrCast(@alignCast(userdata));
    const buffer_size: i32 = @intCast(length);
    var region_1_size: i32 = buffer_size;
    var region_2_size: i32 = undefined;

    if (ring_buffer.play_cursor + buffer_size > ring_buffer.size) {
        region_1_size = ring_buffer.size - ring_buffer.play_cursor;
        region_2_size = buffer_size - region_1_size;
    }

    // Ring Buffer Memory Layout:
    //
    // [...............................]  <- ring_buffer.data
    //      ^               ^
    //      |               |
    // play_cursor    write_cursor
    //
    // When play_cursor + bytes_to_write > buffer_size, we need two copies:
    // Copy 1: From play_cursor to end
    @memcpy(data[0..region_1_size], ring_buffer.data[ring_buffer.play_cursor..][0..region_1_size]);

    // Copy 2: From start to remaining bytes
    //
    // Memory Layout During Wrap:
    // Ring Buffer: [222|111111111111] (1=first region, 2=second region)
    //                   ^
    //                play_cursor
    // Output:      [111111111111|222]
    @memcpy(data[region_1_size..][0..region_2_size], ring_buffer.data[0..region_2_size]);

    ring_buffer.play_cursor = (ring_buffer.play_cursor + buffer_size) % ring_buffer.size;
    ring_buffer.write_cursor = (ring_buffer.play_cursor + buffer_size) % ring_buffer.size;
}

pub fn handleResolutionChange(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer, back_buffer: *OffscreenBuffer) !void {
    const resolutions = [_]struct { w: i32, h: i32 }{
        .{ .w = 1280, .h = 720 },
        .{ .w = 1920, .h = 1080 },
        .{ .w = 2560, .h = 1440 },
        .{ .w = 3840, .h = 2160 },
    };

    //TODO: Display in-game ui to select resolution
    // Hardcoded a single value for now
    try resizeTexture(allocator, back_buffer, renderer, resolutions[1].w, resolutions[1].h);
}

pub fn getWindowDimension(window: *c.SDL_Window) WindowDimension {
    var result: WindowDimension = undefined;
    var x: c_int = undefined;
    var y: c_int = undefined;
    var w: c_int = undefined;
    var h: c_int = undefined;

    _ = c.SDL_GetWindowSize(window, &w, &h);
    _ = c.SDL_GetWindowPosition(window, &x, &y);

    result.x = x;
    result.y = y;
    result.width = w;
    result.height = h;

    return result;
}

pub fn getMonitorRefreshRate(window: *c.SDL_Window) i32 {
    const display_id = c.SDL_GetDisplayForWindow(window);
    const mode = c.SDL_GetDesktopDisplayMode(display_id).*;
    var result: i32 = 60;
    if (mode != null) {
        if (mode.refresh_rate > 0) {
            result = @intFromFloat(mode.refresh_rate);
        }
    }
    return result;
}

pub fn getSecondsElapsed(start: u64, end: u64) f32 {
    return @as(f32, @floatFromInt(end - start)) / global_perf_count_frequency;
}

pub fn handleEvent(allocator: std.mem.Allocator, event: *c.SDL_Event) !void {
    while (c.SDL_PollEvent(event)) {
        switch (event.type) {
            c.SDL_EVENT_QUIT => {
                global_running = false;
            },
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                const key = event.key.key;
                const mod = event.key.mod;
                const down = event.key.down;
                const repeat = event.key.repeat;
                _ = repeat;
                _ = mod;

                switch (key) {
                    c.SDLK_P => {
                        if (down) {
                            global_pause = !global_pause;
                        }
                    },
                    c.SDLK_R => {
                        if (down) {
                            const window = c.SDL_GetWindowFromEvent(event);
                            const renderer = c.SDL_GetRenderer(window) orelse continue;
                            try handleResolutionChange(allocator, renderer, &global_backbuffer);
                        }
                    },
                    c.SDLK_ESCAPE => {},
                    else => {},
                }
            },
            c.SDL_EVENT_WINDOW_RESIZED => {
                // const window = c.SDL_GetWindowFromID(event.window.windowID);
                // const dim = getWindowDimension(window);
                // const renderer = c.SDL_GetRenderer(window);
                // try resizeTexture(allocator, &global_backbuffer, renderer, dim.width, dim.height);
            },
            else => {},
        }
    }
}

pub fn resizeTexture(
    allocator: std.mem.Allocator,
    buffer: *OffscreenBuffer,
    renderer: *c.SDL_Renderer,
    width: i32,
    height: i32,
) !void {
    global_game_width = width;
    global_game_height = height;

    if (buffer.texture != null) {
        c.SDL_DestroyTexture(buffer.texture);
    }
    if (buffer.memory != null) {
        allocator.free(buffer.memory.?);
    }

    buffer.width = width;
    buffer.height = height;
    buffer.bytes_per_pixel = 4;
    const buffer_memory_size: usize = @intCast(buffer.width * buffer.height * buffer.bytes_per_pixel);
    buffer.memory = try allocator.alloc(u32, buffer_memory_size);
    buffer.pitch = buffer.width * buffer.bytes_per_pixel;
    buffer.texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ARGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        @as(c_int, buffer.width),
        @as(c_int, buffer.height),
    );
    _ = c.SDL_SetTextureScaleMode(buffer.texture, c.SDL_SCALEMODE_NEAREST);
}

pub fn renderBufferToWindow(
    buffer: *OffscreenBuffer,
    renderer: *c.SDL_Renderer,
    window: *c.SDL_Window,
) void {
    if (buffer.memory == null) unreachable; //TODO: Log error

    var window_w: c_int = 0;
    var window_h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &window_w, &window_h);
    buffer.frect.w = @floatFromInt(window_w);
    buffer.frect.h = @floatFromInt(window_h);

    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_UpdateTexture(buffer.texture, null, buffer.memory.?.ptr, @as(c_int, buffer.pitch));
    _ = c.SDL_RenderTexture(renderer, buffer.texture, null, &buffer.frect);
    _ = c.SDL_RenderPresent(renderer);
}

pub fn renderWeirdGradient(buffer: *OffscreenBuffer, x_offset: u32, y_offset: u32) !void {
    var row: [*]u8 = @ptrCast(buffer.memory orelse return error.BackBufferPixelsNotInitialized);
    var y: u32 = 0;
    while (y < buffer.height) : (y += 1) {
        var pixel: [*]u8 = row;
        var x: u32 = 0;
        while (x < buffer.width) : (x += 1) {
            const blue: u8 = @truncate(@as(u32, @intCast(x + x_offset)));
            const green: u8 = @truncate(@as(u32, @intCast(y + y_offset)));
            const red: u8 = 0;
            const alpha: u8 = 255;

            const color: u32 = (@as(u32, alpha) << 24) |
                (@as(u32, red) << 16) |
                (@as(u32, green) << 8) |
                (@as(u32, blue));

            const pixel_u32: [*]u32 = @alignCast(@ptrCast(pixel));
            pixel_u32[0] = color;
            pixel += 4;
        }
        row += @as(usize, @intCast(buffer.pitch));
    }
}

pub fn initGamepads() void {
    var max_joyticks: c_int = undefined;
    _ = c.SDL_GetJoysticks(&max_joyticks);
    var connected_gamepad_index = 0;

    for (0..max_joyticks - 1) |device_index| {
        if (!c.SDL_IsGamepad(device_index)) continue;
        if (connected_gamepad_index >= MAX_CONTROLLER_HANDLES) break;

        global_gamepad_handles[connected_gamepad_index] = c.SDL_OpenGamepad(device_index);
        global_haptic_handles[connected_gamepad_index] = c.SDL_OpenHaptic(device_index);

        const rumble_did_init = c.SDL_InitHapticRumble(global_haptic_handles[connected_gamepad_index]);
        if (rumble_did_init and global_haptic_handles[connected_gamepad_index] != null) {
            c.SDL_CloseHaptic(global_haptic_handles[connected_gamepad_index]);
            global_haptic_handles[connected_gamepad_index] = null;
        }

        connected_gamepad_index += 1;
    }
}

pub fn closeGamepads() void {
    for (global_gamepad_handles, 0..) |handle, i| {
        if (handle != null) {
            c.SDL_CloseGamepad(handle);
            global_gamepad_handles[i] = null;
        }
    }

    for (global_haptic_handles, 0..) |handle, i| {
        if (handle != null) {
            c.SDL_CloseHaptic(handle);
            global_haptic_handles[i] = null;
        }
    }
}

pub fn processKeyboardMessage(new_state: *game.ButtonState, is_down: bool) void {
    if (new_state.is_down != is_down) {
        new_state.is_down = is_down;
        new_state.half_transition_count += 1;
    }
}

pub fn processControllerButton(old_state: *game.ButtonState, new_state: *game.ButtonState, value: bool) void {
    new_state.ended_down = value;
    new_state.half_transition_count += if (new_state.ended_down == old_state.ended_down) 1 else 0;
}

pub fn processStickValue(stick_value: i32, deadzone_threshold: i32, flip: bool) f32 {
    var result: f32 = 0.0;

    const joystick_min = -c.SDL_JOYSTICK_AXIS_MIN;
    const joystick_max = c.SDL_JOYSTICK_AXIS_MAX;
    var value = stick_value;

    if (flip) {
        joystick_min = c.SDL_JOYSTICK_AXIS_MAX;
        joystick_max = -c.SDL_JOYSTICK_AXIS_MIN;
        value = -value;
    }

    if (value < -LEFT_DEADZONE) {
        result = @as(f32, @floatFromInt(value + deadzone_threshold)) / @as(f32, @floatFromInt(joystick_min - deadzone_threshold));
    } else if (value > LEFT_DEADZONE) {
        result = @as(f32, @floatFromInt(value - deadzone_threshold)) / @as(f32, @floatFromInt(joystick_max - deadzone_threshold));
    }

    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO | c.SDL_INIT_GAMEPAD | c.SDL_INIT_HAPTIC)) {
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    if (!c.SDL_SetHint(c.SDL_HINT_RENDER_VSYNC, "1")) {
        c.SDL_LogWarn(c.SDL_LOG_CATEGORY_APPLICATION, "Could not set VSYNC!");
    }

    const window: *c.SDL_Window, const renderer: *c.SDL_Renderer = create_window_and_renderer: {
        var window: ?*c.SDL_Window = null;
        var renderer: ?*c.SDL_Renderer = null;
        if (!c.SDL_CreateWindowAndRenderer(
            "Zigmade hero",
            INITIAL_WINDOW_WIDTH,
            INITIAL_WINDOW_HEIGHT,
            c.SDL_WINDOW_RESIZABLE,
            &window,
            &renderer,
        )) {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Could not create window and renderer");
            unreachable;
        }

        break :create_window_and_renderer .{ window.?, renderer.? };
    };

    defer c.SDL_DestroyRenderer(renderer);
    defer c.SDL_DestroyWindow(window);

    const dim = getWindowDimension(window);
    try resizeTexture(allocator, &global_backbuffer, renderer, dim.width, dim.height);

    defer if (global_backbuffer.memory != null) {
        allocator.free(global_backbuffer.memory.?);
    };

    //main_loop
    while (global_running) {
        var event: c.SDL_Event = undefined;
        try handleEvent(allocator, &event);

        if (global_pause) {
            continue;
        }

        try renderWeirdGradient(&global_backbuffer, global_x_offset, global_y_offset);
        global_x_offset += 1;
        renderBufferToWindow(&global_backbuffer, renderer, window);
    }
}
