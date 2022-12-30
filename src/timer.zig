const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

pub var frame_rate: u64 = 0;
pub var frame_delta: u64 = 0;
pub var frame_time: u64 = 0;

var frame_rate_timer: u64 = 0;
var frame_counter: u64 = 0;

pub fn init() !void {}
pub fn deinit() void {}

/// update updates the internal timer state.
pub fn update() !void {
    frame_counter +%= 1;

    const now = @intCast(u64, std.time.milliTimestamp());
    frame_delta = (now - frame_time);
    frame_time = now;

    if ((now - frame_rate_timer) >= std.time.ms_per_s) {
        frame_rate_timer = now;
        frame_rate = frame_counter;
        frame_counter = 0;
    }
}
