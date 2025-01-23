const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const OffscreenBuffer = struct {
    texture: ?*c.SDL_Texture,
    frect: c.SDL_FRect,
    pixels: ?[]u32,
    width: i32,
    height: i32,
    pitch: i32,
    bytes_per_pixel: i32,
};

const WindowDimension = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

//constants
const MAX_CONTROLLER_HANDLES = 4;

//global variables
var global_running: bool = undefined;
var global_pause: bool = undefined;
var global_backbuffer: OffscreenBuffer = undefined;
var global_perf_count_frequency: u64 = undefined;
var global_controller_handles: [MAX_CONTROLLER_HANDLES]?*c.SDL_Gamepad = undefined;
var global_rumble_handles: [MAX_CONTROLLER_HANDLES]?*c.SDL_Haptic = undefined;

pub fn getSharedLibExt() []u8 {
    switch (builtin.target.os.tag) {
        .windows => return "dll",
        .macos => return "dylib",
        .linux => return "so",
        else => @compileError("UNSUPPORTED OS"),
    }
}

pub fn getWindowDimension(window: ?*c.SDL_Window) WindowDimension {
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

pub fn getMonitorRefreshRate(window: ?*c.SDL_Window) i32 {
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

pub fn openGamepads() void {
    var c_max_joysticks: c_int = undefined;
    const joystick_ids = c.SDL_GetJoysticks(&c_max_joysticks);
    defer c.SDL_free(joystick_ids);

    const max_joysticks: u32 = @intCast(c_max_joysticks);
    var gamepad_index: u32 = 0;
    while (gamepad_index < max_joysticks) : (gamepad_index += 1) {
        if (!c.SDL_IsGamepad(gamepad_index)) {
            continue;
        }
        if (gamepad_index >= MAX_CONTROLLER_HANDLES) {
            break;
        }

        global_controller_handles[gamepad_index] = c.SDL_OpenGamepad(gamepad_index);
        global_rumble_handles[gamepad_index] = c.SDL_OpenHaptic(gamepad_index);

        const rumble_did_init = c.SDL_InitHapticRumble(global_rumble_handles[gamepad_index]);
        if (global_rumble_handles[gamepad_index] != null and rumble_did_init) {
            c.SDL_CloseHaptic(global_rumble_handles[gamepad_index]);
            global_rumble_handles[gamepad_index] = null;
        }

        gamepad_index += 1;
    }
}

pub fn closeGamepads() void {
    var i: u32 = 0;
    while (i < MAX_CONTROLLER_HANDLES) : (i += 1) {
        if (global_rumble_handles[i] != null) {
            c.SDL_CloseHaptic(global_rumble_handles[i]);
            global_rumble_handles[i] = null;
        }

        if (global_controller_handles[i] != null) {
            c.SDL_CloseGamepad(global_controller_handles[i]);
            global_controller_handles[i] = null;
        }
    }
}

pub fn handleEvent(allocator: std.mem.Allocator, event: *c.SDL_Event) void {
    const window = c.SDL_GetWindowFromID(event.window.windowID);

    while (c.SDL_PollEvent(event)) {
        switch (event.type) {
            c.SDL_EVENT_QUIT => {
                global_running = false;
            },
            c.SDL_EVENT_WINDOW_RESIZED => {
                const dim = getWindowDimension(window);
                const renderer = c.SDL_GetRenderer(window);
                resizeTexture(allocator, &global_backbuffer, renderer, dim.width, dim.height);
                std.debug.print("[Resized]: w = {d} h = {d}\n", .{ event.window.data1, event.window.data2 });
            },
            else => {},
        }
    }
}

pub fn resizeTexture(
    allocator: std.mem.Allocator,
    buffer: *OffscreenBuffer,
    renderer: ?*c.SDL_Renderer,
    width: i32,
    height: i32,
) void {
    if (buffer.texture != null) {
        c.SDL_DestroyTexture(buffer.texture);
    }
    if (buffer.pixels != null) {
        allocator.free(buffer.pixels.?);
    }

    buffer.width = width;
    buffer.height = height;
    buffer.bytes_per_pixel = 4;
    const buffer_memory_size: usize = @intCast(buffer.width * buffer.height * buffer.bytes_per_pixel);
    buffer.pixels = allocator.alloc(u32, buffer_memory_size) catch unreachable; //TODO: handle out of memory
    buffer.pitch = buffer.width * buffer.bytes_per_pixel;
    buffer.frect = c.SDL_FRect{
        .x = 0.0,
        .y = 0.0,
        .w = @floatFromInt(buffer.width),
        .h = @floatFromInt(buffer.height),
    };
    buffer.texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ARGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        @as(c_int, buffer.width),
        @as(c_int, buffer.height),
    );
}

pub fn renderWeirdGradient(buffer: *OffscreenBuffer, x_offset: i32, y_offset: i32) !void {
    if (buffer.pixels == null) return error.BackBufferPixelsNotInitialized;
    var row: [*]u8 = @ptrCast(buffer.pixels.?);
    var y: i32 = 0;
    while (y < buffer.height) : (y += 1) {
        var pixel: [*]u8 = row;
        var x: i32 = 0;
        while (x < buffer.width) : (x += 1) {
            // Blue - repeats every 256 pixels
            pixel[0] = @intCast((x + x_offset) & 0xFF);
            pixel += 1;
            // Green - repeats every 256 pixels
            pixel[0] = @intCast((y + y_offset) & 0xFF);
            pixel += 1;
            // Red
            pixel[0] = 0;
            pixel += 1;
            // Alpha
            pixel[0] = 255;
            pixel += 1;
        }
        row += @as(usize, @intCast(buffer.pitch));
    }
}

pub fn renderBufferToWindow(
    buffer: *OffscreenBuffer,
    renderer: ?*c.SDL_Renderer,
) void {
    if (buffer.pixels == null) unreachable;
    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_UpdateTexture(buffer.texture, null, buffer.pixels.?.ptr, @as(c_int, buffer.pitch));
    _ = c.SDL_RenderTexture(renderer, buffer.texture, null, &buffer.frect);
    _ = c.SDL_RenderPresent(renderer);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    global_perf_count_frequency = @as(u64, c.SDL_GetPerformanceFrequency());

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL3 Init Error: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("Zigmade Hero", 1280, 720, c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_RESIZABLE);
    defer c.SDL_DestroyWindow(window);
    if (window == null) {
        std.debug.print("Could not create window: {s}\n", .{c.SDL_GetError()});
        return error.SDLWindowCreationFailed;
    }

    // const monitor_refresh_hz = getMonitorRefreshRate();
    // const game_update_hz: f32 = @floatFromInt(@divTrunc(monitor_refresh_hz, 2));
    // const target_seconds_per_frame: f32 = 1 / game_update_hz;

    const renderer = c.SDL_CreateRenderer(window, null);
    defer c.SDL_DestroyRenderer(renderer);
    if (renderer == null) {
        std.debug.print("Could not create renderer: {s}\n", .{c.SDL_GetError()});
        return error.SDLRendererCreationFailed;
    }
    _ = c.SDL_SetRenderVSync(renderer, c.SDL_RENDERER_VSYNC_ADAPTIVE);

    const dim = getWindowDimension(window);
    resizeTexture(allocator, &global_backbuffer, renderer, dim.width, dim.height);
    defer if (global_backbuffer.pixels != null) {
        allocator.free(global_backbuffer.pixels.?);
    };

    global_running = true;
    global_pause = false;

    var x_offset: i32 = 0;
    var y_offset: i32 = 0;
    while (global_running) {
        var event: c.SDL_Event = undefined;
        handleEvent(allocator, &event);

        if (global_pause) {
            continue;
        }

        try renderWeirdGradient(&global_backbuffer, x_offset, y_offset);
        x_offset += 1;
        y_offset += 2;
        renderBufferToWindow(&global_backbuffer, renderer);
    }
}
