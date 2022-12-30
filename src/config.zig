const std = @import("std");
const gpu = @import("gpu");
const gnorp = @import("main.zig");

test {
    std.testing.refAllDecls(@This());
}

/// VsyncMode defines possible vsync options.
pub const VsyncMode = enum {
    no_buffer,
    double_buffer,
    triple_buffer,
};

/// build_prefix is the path component for each source file, preceeding the "src/" part.
/// This is used to filter out unnecessary path data in debug log messages when @src()
/// is set. This will only be set in debug builds.
build_prefix: []const u8 = "",

/// The directory where runtime-loadable assets are stored.
content_dir: []const u8 = ".",

/// The window title.
title: [:0]const u8 = "unnamed application",

/// The width of the window.
width: u32 = 1024,

/// The height of the window.
height: u32 = 400,

/// vsync determines the buffer mdoe to be used when rendering.
vsync: VsyncMode = .double_buffer,

/// fixed_framerate determines if a fixed framerate should be used
/// for calls to the user's render handler. If this value is 0, it
/// will be called as often as the update handler, which runs once
/// per frame. How fast that is, depends on the vsync mode.
fixed_framerate: u32 = 60,

/// fullscreen determines if we run the application in fullscreen or windowed mode.
fullscreen: bool = false,

/// Is the window resizable?
/// Defaults to false if fullscreen is true.
resizable: bool = true,

/// The number of samples to use when rendering.
/// Must be >= 1.
sample_count: u32 = 1,

/// Enable or disable debug logging.
debug: bool = (@import("builtin").mode == .Debug),

/// device_requirements defines properties the selected graphics
/// adapter must support.
device_requirements: struct {
    /// Specify which power-usage profile we prefer when selecting a
    /// suitable adapter.
    power_preference: gpu.PowerPreference = .undef,

    /// A list of device features the applicatin requires.
    features: ?[]const gpu.FeatureName = null,

    /// A set of limits the device must support.
    limits: ?gpu.Limits = null,
} = .{},

/// validate ensures the configuration is sane.
pub fn validate(self: *const @This()) !void {
    if (self.width == 0)
        return error.InvalidDisplayWidth;

    if (self.height == 0)
        return error.InvalidDisplayHeight;

    if (self.sample_count == 0)
        return error.InvalidSampleCount;
}
