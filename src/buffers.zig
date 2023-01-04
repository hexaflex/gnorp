const std = @import("std");
const gpu = @import("gpu");
const zmath = @import("zmath");
const gnorp = @import("main.zig");
const graphics = gnorp.graphics;
const math = gnorp.math;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Uniform(extern struct { a: u16 }));
}

/// Uniform creates a uniform buffer object with the fields in the given struct.
/// Asserts that T is an Extern struct, that it has at least one field and that
/// all fields are supported uniform data types. These include:
///
///```
///    u16, i16, u32, i32, i64, u64, f16, f32, f64,
///    [ 2]u16, [ 2]i16, [ 2]u32, [ 2]i32, [ 2]i64, [ 2]u64, [ 2]f16, [ 2]f32, [ 2]f64,
///    [ 3]u16, [ 3]i16, [ 3]u32, [ 3]i32, [ 3]i64, [ 3]u64, [ 3]f16, [ 3]f32, [ 3]f64,
///    [ 4]u16, [ 4]i16, [ 4]u32, [ 4]i32, [ 4]i64, [ 4]u64, [ 4]f16, [ 4]f32, [ 4]f64,
///    [16]u16, [16]i16, [16]u32, [16]i32, [16]i64, [16]u64, [16]f16, [16]f32, [16]f64,
///    zmath.Mat, zmath.Vec
///```
///
/// Additionally, any fields which are themselves extern structs or fixed-size
/// arrays with the restrictions listed above or a  of the above.
pub fn Uniform(comptime T: type) type {
    assertType(T);

    return struct {
        gpu_buffer: *gpu.Buffer = undefined,
        refcount: usize = 0,

        pub fn init() !*@This() {
            var self = try gnorp.allocator.create(@This());
            errdefer gnorp.allocator.destroy(self);
            self.* = .{};

            self.gpu_buffer = graphics.device.createBuffer(&.{
                .label = @typeName(@This()) ++ " buffer",
                .usage = .{ .copy_dst = true, .uniform = true },
                .size = @sizeOf(T),
                .mapped_at_creation = false,
            });

            return self.reference();
        }

        fn deinit(self: *@This()) void {
            self.gpu_buffer.release();
            gnorp.allocator.destroy(self);
        }

        /// reference increments this object's reference counter and returns itself.
        pub inline fn reference(self: *@This()) *@This() {
            return gnorp.resources.reference(self);
        }

        /// release decrements the object's reference counter and calls deinit()
        /// on it if it reaches zero. This is a no-op if the refcount is already zero.
        pub inline fn release(self: *@This()) void {
            gnorp.resources.release(self, deinit);
        }

        /// getBindGroupLayoutEntry returns a bindgroup layout entry for this uniformbuffer
        /// and the given binding index.
        pub inline fn getBindGroupLayoutEntry(_: *const @This(), binding: u32) gpu.BindGroupLayout.Entry {
            return gpu.BindGroupLayout.Entry.buffer(
                binding,
                .{ .vertex = true, .fragment = true },
                .uniform,
                false,
                @sizeOf(T),
            );
        }

        /// getBindGroupEntry returns a bindgroup entry for this uniformbuffer
        /// and the given binding index.
        pub inline fn getBindGroupEntry(self: *const @This(), binding: u32) gpu.BindGroup.Entry {
            return gpu.BindGroup.Entry.buffer(binding, self.gpu_buffer, 0, @sizeOf(T));
        }

        /// set uploads new buffer contents to the GPU.
        pub inline fn set(self: *@This(), value: *const T) void {
            graphics.device.getQueue().writeBuffer(self.gpu_buffer, 0, &[_]T{value.*});
        }
    };
}

/// supported_types defines all supported uniform field data types.
const supported_types = [_]type{
    u16,
    i16,
    u32,
    i32,
    i64,
    u64,
    f16,
    f32,
    f64,

    [2]u16,
    [2]i16,
    [2]u32,
    [2]i32,
    [2]i64,
    [2]u64,
    [2]f16,
    [2]f32,
    [2]f64,

    [3]u16,
    [3]i16,
    [3]u32,
    [3]i32,
    [3]i64,
    [3]u64,
    [3]f16,
    [3]f32,
    [3]f64,

    [4]u16,
    [4]i16,
    [4]u32,
    [4]i32,
    [4]i64,
    [4]u64,
    [4]f16,
    [4]f32,
    [4]f64,

    [16]u16,
    [16]i16,
    [16]u32,
    [16]i32,
    [16]i64,
    [16]u64,
    [16]f16,
    [16]f32,
    [16]f64,

    zmath.Mat,
    zmath.Vec,
};

/// isSupportedType returns true if T is a supported type.
fn isSupportedType(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .Struct => {
            assertType(T);
            return true;
        },
        .Array => |*x| {
            if (@typeInfo(x.child) == .Array) {
                inline for (supported_types) |st|
                    if (st == x.child) return true;
            } else {
                inline for (supported_types) |st|
                    if (st == T) return true;
            }
        },
        else => {
            inline for (supported_types) |st|
                if (st == T) return true;
        },
    }

    return false;
}

// assertType ensures that T has the expected properties to qualify as a
// uniform buffer struct.
fn assertType(comptime T: type) void {
    const info = @typeInfo(T);
    switch (info) {
        .Struct => |s| {
            if (s.layout != .Extern)
                @compileError(@typeName(T) ++ " must be an extern struct");

            if (s.fields.len == 0)
                @compileError(@typeName(T) ++ " has no fields");

            inline for (s.fields) |*f| {
                if (!isSupportedType(f.field_type))
                    @compileError("invalid uniform buffer field type: " ++ @typeName(T) ++ "." ++ f.name);
            }
        },
        else => @compileError(@typeName(T) ++ " must be a struct"),
    }
}
