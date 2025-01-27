const std = @import("std");
const builtin = @import("builtin");

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

const WindowDimension = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const INITIAL_WINDOW_WIDTH = 1280;
const INITIAL_WINDOW_HEIGHT = 720;

var global_game_width: i32 = 0;
var global_game_height: i32 = 0;
var global_perf_count_frequency: u64 = 0;
var global_running: bool = true;
var global_pause: bool = false;
var global_x_offset: u32 = 0;
var global_y_offset: u32 = 0;
var global_backbuffer: OffscreenBuffer = undefined;

/// Converts the return value of an SDL function to an error union.
inline fn sdlResult(value: anytype) error{SdlError}!switch (@import("shims.zig").typeInfo(@TypeOf(value))) {
    .bool => void,
    .pointer, .optional => @TypeOf(value.?),
    .int => |info| switch (info.signedness) {
        .signed => @TypeOf(@max(0, value)),
        .unsigned => @TypeOf(value),
    },
    else => @compileError("unerrifiable type: " ++ @typeName(@TypeOf(value))),
} {
    return switch (@import("shims.zig").typeInfo(@TypeOf(value))) {
        .bool => if (!value) error.SdlError,
        .pointer, .optional => value orelse error.SdlError,
        .int => |info| switch (info.signedness) {
            .signed => if (value >= 0) @max(0, value) else error.SdlError,
            .unsigned => if (value != 0) value else error.SdlError,
        },
        else => comptime unreachable,
    };
}

pub fn getSharedLibExt() []const u8 {
    switch (builtin.target.os.tag) {
        .windows => return "dll",
        .macos => return "dylib",
        .linux => return "so",
        else => @compileError("UNSUPPORTED OS"),
    }
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

    sdlResult(c.SDL_GetWindowSize(window, &w, &h)) catch {};
    sdlResult(c.SDL_GetWindowPosition(window, &x, &y)) catch {};

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
    sdlResult(c.SDL_GetWindowSize(window, &window_w, &window_h)) catch {};
    buffer.frect.w = @floatFromInt(window_w);
    buffer.frect.h = @floatFromInt(window_h);

    sdlResult(c.SDL_RenderClear(renderer)) catch {};
    sdlResult(c.SDL_UpdateTexture(buffer.texture, null, buffer.memory.?.ptr, @as(c_int, buffer.pitch))) catch {};
    sdlResult(c.SDL_RenderTexture(renderer, buffer.texture, null, &buffer.frect)) catch {};
    sdlResult(c.SDL_RenderPresent(renderer)) catch {};
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Hello, World!\n", .{});

    try sdlResult(c.SDL_Init(c.SDL_INIT_VIDEO));
    defer c.SDL_Quit();

    sdlResult(c.SDL_SetHint(c.SDL_HINT_RENDER_VSYNC, "1")) catch {
        std.debug.print("[WARN]: Could not set VSYNC!", .{});
    };

    const window: *c.SDL_Window, const renderer: *c.SDL_Renderer = create_window_and_renderer: {
        var window: ?*c.SDL_Window = null;
        var renderer: ?*c.SDL_Renderer = null;
        try sdlResult(c.SDL_CreateWindowAndRenderer("Zigmade hero", INITIAL_WINDOW_WIDTH, INITIAL_WINDOW_HEIGHT, 0, &window, &renderer));
        errdefer comptime unreachable;

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
