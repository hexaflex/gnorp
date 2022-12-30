const std = @import("std");
const gpu = @import("gpu");
const gnorp = @import("main.zig");
const graphics = gnorp.graphics;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Generic(f32));
    std.testing.refAllDecls(Uniform(extern struct { a: u16 }));
}

/// Generic creates a gpu Buffer with the given element type.
/// This type takes care of dynamic resizing on the CPU and GPU where needed.
pub fn Generic(comptime T: type) type {
    return struct {
        usage: gpu.Buffer.UsageFlags = undefined,
        gpu_buffer: ?*gpu.Buffer = null,
        data: std.ArrayList(T) = undefined,
        old_size: usize = 0,
        refcount: usize = 0,
        dirty: bool = true,

        pub fn init(usage: gpu.Buffer.UsageFlags) !*@This() {
            var self = try gnorp.allocator.create(@This());
            self.* = .{};
            self.usage = usage;
            self.data = std.ArrayList(T).init(gnorp.allocator);
            return self.reference();
        }

        fn deinit(self: *@This()) void {
            if (self.gpu_buffer) |gb|
                gb.release();
            self.data.deinit();
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

        /// len returns the number of elements in the buffer.
        pub inline fn len(self: *const @This()) usize {
            return self.data.items.len;
        }

        /// bindVertex sets this buffer as the vertex buffer on the given slot for the specified
        /// RenderPassEncoder.
        pub inline fn bindVertex(self: *const @This(), pass: *gpu.RenderPassEncoder, slot: u32) void {
            pass.setVertexBuffer(slot, self.gpu_buffer.?, 0, self.data.items.len * @sizeOf(T));
        }

        /// bindIndex sets this buffer as the index buffer for the specified RenderPassEncoder.
        pub inline fn bindIndex(self: *const @This(), pass: *gpu.RenderPassEncoder) void {
            switch (T) {
                u16 => pass.setIndexBuffer(self.gpu_buffer.?, .uint16, 0, self.data.items.len * @sizeOf(T)),
                u32 => pass.setIndexBuffer(self.gpu_buffer.?, .uint32, 0, self.data.items.len * @sizeOf(T)),
                else => unreachable,
            }
        }

        /// append appends the given value.
        pub inline fn append(self: *@This(), value: T) !void {
            try self.data.append(value);
            self.dirty = true;
        }

        /// appendSlice appends the given value.
        pub inline fn appendSlice(self: *@This(), values: []const T) !void {
            try self.data.appendSlice(values);
            self.dirty = true;
        }

        /// appendAssumeCapacity appends the given value.
        pub inline fn appendAssumeCapacity(self: *@This(), value: T) void {
            self.data.appendAssumeCapacity(value);
            self.dirty = true;
        }

        /// appendSliceAssumeCapacity appends the given value.
        pub inline fn appendSliceAssumeCapacity(self: *@This(), values: []const T) void {
            self.data.appendSliceAssumeCapacity(values);
            self.dirty = true;
        }

        /// resize adjusts the list's length to new_len.
        /// Does not initialize added items if any.
        pub inline fn resize(self: *@This(), new_len: usize) !void {
            try self.data.resize(new_len);
            self.dirty = true;
        }

        /// swapRemove removes the element at the specified index and returns it.
        /// The empty slot is filled from the end of the list.
        /// This operation is O(1).
        pub inline fn swapRemove(self: *@This(), i: usize) T {
            self.dirty = true;
            return self.data.swapRemove(i);
        }

        /// orderedRemove removes the element at index `i`, shifts elements after index
        /// `i` forward, and returns the removed element.
        /// Asserts the array has at least one item.
        /// Invalidates pointers to the end of the list.
        pub inline fn orderedRemove(self: *@This(), i: usize) T {
            self.dirty = true;
            return self.data.orderedRemove(i);
        }

        /// removeRange removes a range of values starting at the given index.
        pub fn removeRange(self: *@This(), index: usize, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1)
                _ = self.data.orderedRemove(index + i);
            self.dirty = true;
        }

        /// getBindGroupEntry returns a bindgroup entry for this buffer
        /// and the given binding index.
        pub inline fn getBindGroupEntry(self: *const @This(), binding: u32) gpu.BindGroup.Entry {
            const size = @truncate(u32, self.data.items.len * @sizeOf(T));
            return gpu.BindGroup.Entry.buffer(binding, self.gpu_buffer.?, 0, size);
        }

        /// sync ensures the GPU buffer is synchronized with the local data copy.
        pub fn sync(self: *@This()) !void {
            if (!self.dirty) return;

            // Shrink the arraylist of needed.
            if (self.data.items.len <= self.data.capacity / 2)
                self.data.shrinkAndFree(self.data.capacity / 2);

            const new_size = switch (self.data.capacity) {
                0 => 0,
                else => try std.math.ceilPowerOfTwo(usize, self.data.capacity),
            };

            // Recreate the GPU buffer of meeded.
            if (new_size != self.old_size) {
                if (self.gpu_buffer) |gb|
                    gb.release();

                self.old_size = new_size;
                self.gpu_buffer = graphics.device.createBuffer(&.{
                    .label = @typeName(@This()) ++ " buffer",
                    .usage = self.usage,
                    .size = new_size * @sizeOf(T),
                });

                gnorp.log.debug(@src(), "{s} resized to: {}", .{ @typeName(@This()), new_size });
            }

            graphics.device.getQueue().writeBuffer(self.gpu_buffer.?, 0, self.data.items);
            self.dirty = false;
        }
    };
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

    gnorp.math.Mat,
    gnorp.math.Vec,
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
