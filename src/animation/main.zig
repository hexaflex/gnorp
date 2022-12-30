const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

/// sprites defines sprite related animation objects.
pub const sprites = @import("sprites.zig");

/// transitions provides transition-animation related helpers.
pub const transitions = @import("transitions.zig");
