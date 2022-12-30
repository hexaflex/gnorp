const std = @import("std");
const gnorp = @import("main.zig");

test {
    std.testing.refAllDecls(@This());
}

/// assetPath returns the asset path for the given relative path.
/// The path is rooted at config.content_dir.
/// Caller owns the returned memory.
pub inline fn assetPath(path: []const u8) ![]const u8 {
    return std.fs.path.join(gnorp.allocator, &.{ gnorp.config.content_dir, path });
}

/// reference increments the given object's reference counter and returns it.
pub fn reference(obj: anytype) @TypeOf(obj) {
    obj.refcount += 1;
    return obj;
}

/// release decrements the given object's reference counter and calls deinit()
/// on it if it reaches zero.
/// Asserts that refcount > 0.
pub fn release(
    obj: anytype,
    comptime deinit: fn (@TypeOf(obj)) void,
) void {
    std.debug.assert(obj.refcount > 0);
    obj.refcount -= 1;
    if (obj.refcount == 0) {
        gnorp.log.debug(@src(), "destroying {s}", .{@typeName(@TypeOf(obj))});
        @call(.{}, deinit, .{obj});
    }
}
