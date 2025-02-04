const std = @import("std");

pub const MAX_CONTROLLERS = 4;
pub const MAX_BUTTONS = 12;

pub inline fn kilobytes(value: anytype) @TypeOf(value) {
    return value * 1024;
}

pub inline fn megabytes(value: anytype) @TypeOf(value) {
    return kilobytes(value) * 1024;
}

pub inline fn gigabytes(value: anytype) @TypeOf(value) {
    return megabytes(value) * 1024;
}

pub inline fn terabytes(value: anytype) @TypeOf(value) {
    return gigabytes(value) * 1024;
}

pub const UpdateAndRender = fn (thread_context: *ThreadContext, memory: *Memory, input: *Input, frame_buffer: *FrameBuffer) void;
pub const GetSoundSamples = fn (thread_context: *ThreadContext, memory: *Memory, sound_output_buffer: *SoundOutputBuffer) void;

pub const FrameBuffer = struct {
    memory: []u8,
    width: i32,
    height: i32,
    pitch: i32,
    bytes_per_pixel: i32,
};

pub const SoundOutputBuffer = struct {
    samples: []i16,
    sample_count: i32,
    samples_per_second: i32,
};

pub const ButtonState = struct {
    half_transition_count: i32,
    ended_down: bool,
};

pub const Buttons = enum {
    MoveUp,
    MoveDown,
    MoveLeft,
    MoveRight,
    ActionUp,
    ActionDown,
    ActionLeft,
    ActionRight,
    LeftShoulder,
    RightShoulder,
    Start,
    Back,
};

pub const ControllerInput = struct {
    is_connected: bool,
    is_analog: bool,
    stick_average_x: f32,
    stick_average_y: f32,
    buttons: [Buttons]ButtonState,
};

pub const Input = struct {
    mouse_buttons: [5]ButtonState,
    mouse_x: i32,
    mouse_y: i32,
    mouse_z: i32,
    seconds_to_advance_over_update: f32,
    controllers: [MAX_CONTROLLERS]ControllerInput,
};

pub const State = struct {
    t_sine: f32,
};

pub const Memory = struct {
    is_initialized: bool,
    permanent_storage_size: u64,
    transient_storage_size: u64,
    permanent_storage: []u8,
    transient_storage: []u8,
};

pub const ThreadContext = struct {
    placeholder: i32,
};

pub fn outputSound(game_state: *State, sound_buffer: *SoundOutputBuffer, tone_hz: i32) void {
    const tone_volume = 3000;
    const wave_period: i32 = sound_buffer.samples_per_second / tone_hz;
    var samples = sound_buffer.samples;

    for (0..sound_buffer.sample_count - 1) |i| {
        var sample_value: i16 = 0;
        const sine_value: f32 = std.math.sin(game_state.t_sine);

        sample_value = @as(i16, @intCast(sine_value)) * @as(f32, @floatCast(tone_volume));
        samples[i * 2] = sample_value;
        samples[i * 2 + 1] = sample_value;
        game_state.t_sine += 2.0 * std.math.pi / @as(f32, @floatFromInt(wave_period));

        if (game_state.t_sine > 2.0 * std.math.pi) {
            game_state.t_size -= 2.0 * std.math.pi;
        }
    }
}

pub fn drawRectangle(buffer: *FrameBuffer, f_min_x: f32, f_min_y: f32, f_max_x: f32, f_max_y: f32, color: u32) void {
    var min_x: i32 = @intFromFloat(std.math.round(f_min_x));
    var min_y: i32 = @intFromFloat(std.math.round(f_min_y));
    var max_x: i32 = @intFromFloat(std.math.round(f_max_x));
    var max_y: i32 = @intFromFloat(std.math.round(f_max_y));

    if (min_x < 0) {
        min_x = 0;
    }
    if (min_y < 0) {
        min_y = 0;
    }
    if (max_x > buffer.width) {
        max_x = buffer.width;
    }
    if (max_y > buffer.height) {
        max_y = buffer.height;
    }

    const offset = min_x * buffer.bytes_per_pixel + min_y * buffer.pitch;
    var pixels: [*]u32 = @ptrCast(@alignCast(buffer.memory[offset..].ptr));

    for (min_y..max_y) |y| {
        for (min_x..max_x) |x| {
            pixels[y * buffer.width + x] = color;
        }
    }
}

export fn updateAndRender(thread_context: *ThreadContext, memory: *Memory, input: *Input, frame_buffer: *FrameBuffer) void {
    _ = thread_context;

    comptime {
        if (@sizeOf(State) <= memory.permanent_storage_size) {
            @compileError("State struct too large for permanent storage");
        }
    }

    const game_state: *State = @ptrCast(@alignCast(memory.permanent_storage.ptr));
    //TODO: Start using the game_state
    _ = game_state;

    if (!memory.is_initialized) {
        memory.is_initialized = true;
    }

    for (input.controllers) |controller| {
        if (controller.is_connected) {
            if (controller.is_analog) {
                //TODO: Use analog movement tuning
            } else {
                //TODO: Use digital movement tuning
            }
        }
    }

    //Fill the screen with a purple color
    drawRectangle(frame_buffer, 0.0, 0.0, @floatFromInt(frame_buffer.width), @floatFromInt(frame_buffer.height), 0x00FF00FF);
}

export fn getSoundSamples(thread_context: *ThreadContext, memory: *Memory, sound_output_buffer: *SoundOutputBuffer) void {
    _ = thread_context;

    const game_state: *State = @ptrCast(@alignCast(memory.permanent_storage.ptr));

    outputSound(game_state, sound_output_buffer, 262);
}
