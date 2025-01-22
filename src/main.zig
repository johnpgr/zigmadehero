const std = @import("std");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

var running = true;

fn handleEvent(e: *c.SDL_Event) void {
    switch (e.type) {
        c.SDL_EVENT_QUIT => {
            running = false;
        },
        c.SDL_EVENT_WINDOW_RESIZED => {
            std.debug.print("Window Resized\n Width: {d}\n  Height: {d}\n", .{ e.window.data1, e.window.data2 });
        },
        else => {},
    }
}

fn draw(renderer: ?*c.SDL_Renderer) void {
    _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_RenderPresent(renderer);
}

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL3 Init Error: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    var window: ?*c.SDL_Window = null;
    var renderer: ?*c.SDL_Renderer = null;
    _ = c.SDL_CreateWindowAndRenderer(
        "Zig Made Hero",
        800,
        600,
        c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_RESIZABLE,
        &window,
        &renderer,
    );

    if (window == null) {
        std.debug.print("Could not create window: {s}\n", .{c.SDL_GetError()});
        return error.SDLWindowCreationFailed;
    }
    defer c.SDL_DestroyWindow(window);

    if (renderer == null) {
        std.debug.print("Could not create renderer: {s}\n", .{c.SDL_GetError()});
        return error.SDLRendererCreationFailed;
    }
    defer c.SDL_DestroyRenderer(renderer);

    var e: c.SDL_Event = undefined;
    while (running) {
        while (c.SDL_PollEvent(&e)) {
            handleEvent(&e);
            draw(renderer);
        }
    }
}
