const std = @import("std");
const glfw = @import("glfw");

test {
    std.testing.refAllDecls(@This());
}

/// log provides logging functions.
pub const log = @import("log.zig");

/// input provides input helpers.
pub const input = @import("input.zig");

/// timer provides timer helpers.
pub const timer = @import("timer.zig");

/// math exposes zmath and adds some additional helpers.
pub const math = @import("math.zig");

/// animation provides helper functions and types for various forms of animation.
pub const animation = @import("animation/main.zig");

/// resources facilitates reference counting and proper cleanup for objects using
/// its features. Additionally has some asset related helpers.
pub const resources = @import("resources.zig");

/// graphics provides the window and webGPU context, along with a number
/// of graphics related types like sprites, textures, tilemaps, etc.
pub const graphics = @import("graphics.zig");

/// Config defines application configuration.
pub const Config = @import("config.zig");

pub var config: Config = undefined;
pub var allocator: std.mem.Allocator = if (@import("builtin").is_test)
    std.testing.allocator
else blk: {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    break :blk gpa.allocator();
};

/// getInterface returns the underlying WebGPU implementation.
///
/// GPUInterface must be defined and set to this value in your application's
/// main.zig, so mach-gpu knows which WebGPU backend to use:
///
///```
/// pub const GPUInterface = gnorp.getInterface();
/// ...
/// pub fn main() { ... }
///```
///
/// Instead of this value, you can assign your own implementation of the
/// interface if you have one. Refer to `gpu.Interface()` for details on
/// what the implementation must define in order to qualify.
pub inline fn getInterface() type {
    return @import("gpu").dawn.Interface;
}

/// init initializes the application and all its components.
/// The custom allocator is optional and will default to a
/// `std.heap.GeneralPurposeAllocator` in runtime mode and
/// `std.testing.allocator` in test builds.
pub fn init(alloc: ?std.mem.Allocator, cfg: Config) !void {
    try cfg.validate();

    if (alloc) |a|
        allocator = a;
    config = cfg;

    log.init(std.io.getStdErr().writer(), cfg.debug);
    log.info("{s}", .{cfg.title});

    math.setSeed(@intCast(u64, std.time.milliTimestamp()));

    try graphics.init();
    errdefer graphics.deinit();

    try input.init();
    errdefer input.deinit();

    try timer.init();
    errdefer timer.deinit();
}

pub fn deinit() void {
    input.deinit();
    timer.deinit();
    graphics.deinit();
}

/// close instructs the application to shutdown and exit cleanly.
pub inline fn close() void {
    graphics.window.setShouldClose(true);
}

/// run goes into the main application loop and does not return until the
/// window is closed.
///
/// updateFunc is called once per frame. How fast that is, depends on the value
/// of config.vsync.
///
/// drawFunc is called at a fixed framerate if config.fixed_framerate > 0.
/// Otherwise it is called at the same rate as updateFunc.
pub inline fn run(
    context: anytype,
    comptime updateFunc: fn (@TypeOf(context)) anyerror!void,
    comptime drawFunc: fn (@TypeOf(context)) anyerror!void,
) !void {
    if (config.fixed_framerate == 0)
        return runUncapped(context, updateFunc, drawFunc);
    return runCapped(context, updateFunc, drawFunc);
}

fn runUncapped(
    context: anytype,
    comptime updateFunc: fn (@TypeOf(context)) anyerror!void,
    comptime drawFunc: fn (@TypeOf(context)) anyerror!void,
) !void {
    while (!graphics.window.shouldClose()) {
        try glfw.pollEvents();
        try timer.update();
        try input.update();
        try updateFunc(context);
        try graphics.beginFrame();
        try drawFunc(context);
        try graphics.endFrame();
    }
}

fn runCapped(
    context: anytype,
    comptime updateFunc: fn (@TypeOf(context)) anyerror!void,
    comptime drawFunc: fn (@TypeOf(context)) anyerror!void,
) !void {
    var last_update: u64 = 0;

    const update_interval = std.time.ms_per_s / @intCast(u64, config.fixed_framerate);

    while (!graphics.window.shouldClose()) {
        try glfw.pollEvents();

        try timer.update();
        try input.update();
        try updateFunc(context);

        if ((timer.frame_time - last_update) >= update_interval) {
            last_update = timer.frame_time;
            try graphics.beginFrame();
            try drawFunc(context);
            try graphics.endFrame();
        }
    }
}
