const std = @import("std");
pub const zmath = @import("zmath");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Transform);
}

pub const Mat = zmath.Mat;
pub const Vec = zmath.Vec;
pub const perspectiveFovLh = zmath.perspectiveFovLh;
pub const orthographicOffCenterLh = zmath.orthographicOffCenterLh;
pub const transpose = zmath.transpose;
pub const identity = zmath.identity;
pub const translation = zmath.translation;
pub const scaling = zmath.scaling;
pub const rotationZ = zmath.rotationZ;
pub const mul = zmath.mul;

/// Transform describes transformation data for a 2D object.
pub const Transform = struct {
    position: [2]f32,
    scale: [2]f32,
    angle: f32, // angle in radians.

    model: Mat,
    dirty: bool,

    pub fn init() @This() {
        return .{
            .position = .{ 0, 0 },
            .scale = .{ 1, 1 },
            .angle = 0,
            .model = identity(),
            .dirty = true,
        };
    }

    /// setAngle sets the rotation to the given angle in radians.
    pub inline fn setAngle(self: *@This(), angle: f32) void {
        self.angle = angle;
        self.dirty = true;
    }

    /// rotate turns the object by the given relative angle in radians.
    pub inline fn rotate(self: *@This(), angle: [2]f32) void {
        self.setAngle(self.angle + angle);
    }

    /// setPosition sets the position to the given value.
    pub inline fn setPosition(self: *@This(), pos: [2]f32) void {
        self.position = pos;
        self.dirty = true;
    }

    /// move offsets the position by the given relative distance.
    pub inline fn move(self: *@This(), dist: [2]f32) void {
        self.setPosition(.{ self.position[0] + dist[0], self.position[1] + dist[1] });
    }

    /// setScale sets the scale to the given value.
    pub inline fn setScale(self: *@This(), scale: [2]f32) void {
        self.scale = scale;
        self.dirty = true;
    }

    /// inflate increases/decreases the scale by the given relative offsets.
    pub inline fn inflate(self: *@This(), scale: [2]f32) void {
        self.setScale(.{ self.scale[0] + scale[0], self.scale[1] + scale[1] });
    }

    /// getModel returns the precomputed model matrix.
    pub inline fn getModel(self: *@This()) Mat {
        _ = self.getModelIfUpdated();
        return self.model;
    }

    /// getModelIfUpdated returns the up-to-date model matrix, or null if
    /// nothing has changed since the last call.
    pub fn getModelIfUpdated(self: *@This()) ?zmath.Mat {
        if (!self.dirty) return null;
        self.dirty = false;

        const m_translate = zmath.translation(self.position[0] + 0.375, self.position[1] + 0.375, 0);
        const m_scale = zmath.scaling(self.scale[0], self.scale[1], 0);
        const m_rotate = zmath.rotationZ(self.angle);

        self.model = zmath.mul(zmath.mul(m_scale, m_rotate), m_translate);
        return self.model;
    }
};

var rng: std.rand.Xoshiro256 = std.rand.DefaultPrng.init(1);

/// setSeed sets the seed used by subsequent random() and randomRange() calls.
pub fn setSeed(seed: u64) void {
    rng = std.rand.DefaultPrng.init(seed);
}

/// random returns a random number of the given type.
///
/// For integer types, it returns a random int `i` such that
/// `minInt(T) <= i <= maxInt(T)`. `i` is evenly distributed.
///
/// For float types, returns a floating point value evenly
/// distributed in the range [0, 1).
///
/// For Enum types, returns an evenly distributed random entry
/// from the enum.
pub inline fn random(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .Float => rng.random().float(T),
        .Int => rng.random().int(T),
        .Enum => |x| {
            const values = comptime blk: {
                var out: [x.fields.len]x.tag_type = undefined;
                for (x.fields) |f, i|
                    out[i] = f.value;
                break :blk out;
            };
            return @intToEnum(T, values[randomRange(usize, 0, values.len - 1)]);
        },
        else => @compileError("unsupported type " ++ @typeName(T) ++ " for random()"),
    };
}

/// randomRange returns a random number in the range [min, max].
pub inline fn randomRange(comptime T: type, min: T, max: T) T {
    return switch (@typeInfo(T)) {
        .Float => min + (random(T) * (max - min)),
        .Int => (random(T) % (max - min + 1)) + min,
        else => @compileError("unsupported type " ++ @typeName(T) ++ " for randomRange()"),
    };
}

/// eql returns true if the given values are considered equal.
pub fn eql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .Float => {
            // Are a and b close to zero?
            if (a > -0.1 and a < 0.1 and b > -0.1 and b < 0.1)
                return std.math.approxEqAbs(T, a, b, std.math.floatEps(T));
            return std.math.approxEqRel(T, a, b, std.math.floatEps(T));
        },
        else => return std.meta.eql(a, b),
    }
}

pub inline fn lerpScalar(v0: anytype, v1: @TypeOf(v0), t: f32) @TypeOf(v0) {
    const T = @TypeOf(v0);
    return switch (@typeInfo(T)) {
        .Float => v0 + (v1 - v0) * t,
        .Int => @floatToInt(T, lerpScalar(@intToFloat(f32, v0), @intToFloat(f32, v1), t)),
        else => unreachable,
    };
}

/// distance returns the distance between the given points.
pub inline fn distance(comptime T: type, from: [2]T, to: [2]T) T {
    const dx = to[0] - from[0];
    const dy = to[1] - from[1];
    return std.math.sqrt(dx * dx + dy * dy);
}
