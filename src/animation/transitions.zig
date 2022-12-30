const std = @import("std");
const glfw = @import("glfw");
const gnorp = @import("../main.zig");
const timer = gnorp.timer;
const math = gnorp.math;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(LerpPoints(f32));
}

/// LerpPoints implements smooth interpolation between two points
/// with element type T over a configurable period of time.
pub fn LerpPoints(comptime T: type) type {
    return struct {
        _from: [2]T,
        _to: [2]T,
        _start: u64,
        _updated: u64,
        _duration: u64,
        _step: u64,

        /// init creates a new animation for the given points
        /// and the specified duration in milliseconds.
        ///
        /// Asserts that from != to.
        /// Asserts that duration > 0.
        pub fn init(
            from: [2]T,
            to: [2]T,
            duration: u64,
        ) @This() {
            std.debug.assert(duration > 0);

            const dist = switch (@typeInfo(T)) {
                .Int => @intCast(u64, math.distance(T, from, to)),
                .Float => @floatToInt(u64, math.distance(T, from, to)),
                else => unreachable,
            };
            std.debug.assert(dist > 0);

            return .{
                ._to = to,
                ._from = from,
                ._start = 0,
                ._updated = 0,
                ._duration = duration,
                ._step = duration / dist,
            };
        }

        /// getPosition returns the current position.
        pub inline fn getPosition(self: *const @This()) [2]T {
            return self._from;
        }

        /// update advances the animation and returns the new position.
        /// Returns null if the animation has finished.
        pub fn update(self: *@This()) ?[2]T {
            if (math.eql(self._from[0], self._to[0]) and
                math.eql(self._from[1], self._to[1]))
            {
                return null;
            }

            if (self._start == 0) {
                self._start = timer.frame_time;
                return self._from;
            }

            if ((timer.frame_time - self._updated) < self._step)
                return self._from;

            self._updated = timer.frame_time;

            const t1 = @intToFloat(f32, timer.frame_time - self._start) / @intToFloat(f32, self._duration);
            const t2 = std.math.clamp(t1, 0, 1);

            self._from[0] = math.lerpScalar(self._from[0], self._to[0], t2);
            self._from[1] = math.lerpScalar(self._from[1], self._to[1], t2);

            return self._from;
        }
    };
}

test "LerpPoints" {
    try glfw.init(.{});
    defer glfw.terminate();

    var a = LerpPoints(u32).init(.{ 0, 0 }, .{ 3, 4 }, std.time.ms_per_s / 2);
    while (a.update() != null) {
        gnorp.timer.update() catch unreachable;
    }

    const p = a.getPosition();
    try std.testing.expect(p[0] == @as(u32, 3));
    try std.testing.expect(p[1] == @as(u32, 4));
}
