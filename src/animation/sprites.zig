const std = @import("std");
const glfw = @import("glfw");
const gnorp = @import("../main.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Type);
    std.testing.refAllDecls(DescriptorSet);
    std.testing.refAllDecls(Descriptor);
    std.testing.refAllDecls(State);
}

/// Type defines supported animation types.
pub const Type = enum(u3) {
    loop, // 1,2,3,4,5,1,2,3,4,5,1,...
    reverse, // 1,2,3,4,5,4,3,2,1,2,3,...
    once, // 1,2,3,4,5
    once_reset, // 1,2,3,4,5,1
};

/// Attributes defines animation attributes.
pub const Attributes = packed struct(u8) {
    /// Flip each frame horizontally.
    flip_horizontal: bool = false,

    /// Flip each frame vertically.
    flip_vertical: bool = false,

    _: u6 = 0, // padding
};

/// DescriptorSet defines a collection of animation descriptors
/// with ref-counting facilities.
pub const DescriptorSet = struct {
    frame_size: [2]u32,
    animations: std.ArrayList(Descriptor),
    refcount: usize,

    /// initFromFile loads a descriptor set from the given text file.
    pub fn initFromFile(filename: []const u8) !*@This() {
        gnorp.log.debug(@src(), "loading sprite animations from: {s}", .{filename});

        const data = try std.fs.cwd().readFileAlloc(gnorp.allocator, filename, std.math.maxInt(usize));
        defer gnorp.allocator.free(data);

        var self = try init();
        errdefer self.release();

        var tok = std.mem.tokenize(u8, data, " \n\t");

        const fw = tok.next() orelse return error.MissingFrameWidth;
        const fh = tok.next() orelse return error.MissingFrameHeight;
        self.frame_size = .{
            try std.fmt.parseUnsigned(u32, fw, 0),
            try std.fmt.parseUnsigned(u32, fh, 0),
        };

        while (true) {
            const frame_index = tok.next() orelse break; // end of file -- not an error.
            const frame_count = tok.next() orelse return error.NissingAnimationFramecount;
            const frame_rate = tok.next() orelse return error.NissingAnimationFramerate;
            const _type = tok.next() orelse return error.NissingAnimationType;
            const attr = tok.next() orelse return error.NissingAnimationAttribute;

            try self.animations.append(.{
                .frame_index = try std.fmt.parseUnsigned(u16, frame_index, 0),
                .frame_count = try std.fmt.parseUnsigned(u16, frame_count, 0),
                .frame_rate = try std.fmt.parseFloat(f32, frame_rate),
                .type = try std.meta.intToEnum(Type, try std.fmt.parseUnsigned(u8, _type, 0)),
                .attr = @bitCast(Attributes, try std.fmt.parseUnsigned(u8, attr, 0)),
            });
        }

        gnorp.log.debug(@src(), "  loaded {d} animation(s), frame size: {} x {}", .{
            self.len(),
            self.frame_size[0],
            self.frame_size[1],
        });
        return self;
    }

    pub fn initFromDescriptors(frame_size: [2]u32, descriptors: []const Descriptor) !*@This() {
        var self = try gnorp.allocator.create(@This());
        errdefer gnorp.allocator.destroy(self);
        self.animations = try std.ArrayList(Descriptor).initCapacity(gnorp.allocator, descriptors.len);
        self.refcount = 0;
        self.frame_size = frame_size;
        self.animations.appendSliceAssumeCapacity(descriptors);
        return self.reference();
    }

    pub fn initCapacity(capacity: usize) !*@This() {
        var self = try gnorp.allocator.create(@This());
        errdefer gnorp.allocator.destroy(self);
        self.animations = try std.ArrayList(Descriptor).initCapacity(gnorp.allocator, capacity);
        self.refcount = 0;
        self.frame_size = .{ 1, 1 };
        return self.reference();
    }

    pub fn init() !*@This() {
        var self = try gnorp.allocator.create(@This());
        self.animations = std.ArrayList(Descriptor).init(gnorp.allocator);
        self.refcount = 0;
        self.frame_size = .{ 1, 1 };
        return self.reference();
    }

    fn deinit(self: *@This()) void {
        self.animations.deinit();
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

    pub inline fn appendAssumeCapacity(self: *@This(), desc: Descriptor) void {
        self.animations.appendAssumeCapacity(desc);
    }

    pub inline fn append(self: *@This(), desc: Descriptor) !void {
        try self.animations.append(desc);
    }

    /// len returns the number of animation descriptors.
    pub inline fn len(self: *const @This()) usize {
        return self.animations.items.len;
    }

    /// at returns the nth descri[tor.
    pub inline fn at(self: *const @This(), n: usize) *const Descriptor {
        return &self.animations.items[n];
    }
};

/// SpriteAnimationDescriptor describes animation properties.
pub const Descriptor = struct {
    /// The starting frame in a spritesheet where this animation begins.
    frame_index: u16 = 0,

    /// The number of frames in the animation.
    frame_count: u16 = 1,

    /// Animation speed in frames per second.
    frame_rate: f32 = 0,

    /// type defines the kind of animation.
    type: Type = .once,

    /// attr defines animation/frame attributes.
    attr: Attributes = .{},

    /// createState creates a new animation state with this descriptor.
    pub fn createState(self: *const @This()) State {
        return State.init(self);
    }
};

/// SpriteAnimationState describes the current state of a specific animation.
pub const State = struct {
    descriptor: *const Descriptor = undefined,
    frame: i32 = 0,
    update_interval: f64 = 0,
    last_update: f64 = 0,
    state: bool = false, // state used by a few animation types.

    pub fn init(desc: *const Descriptor) @This() {
        const zero = std.math.approxEqAbs(f32, desc.frame_rate, 0, std.math.floatEps(f32));
        const fps = if (zero) 1 else desc.frame_rate;
        return .{
            .descriptor = desc,
            .frame = 0,
            .update_interval = std.time.ns_per_s / (std.time.ns_per_s * fps),
            .last_update = glfw.getTime(),
            .state = false,
        };
    }

    /// reset resets the animation to its starting state.
    pub fn reset(self: *@This()) void {
        self.frame = 0;
        self.state = false;
        self.last_update = glfw.getTime();
    }

    /// getCurrentFrame returns the current animation frame index.
    /// Relative to the start of this animation.
    pub inline fn getCurrentFrame(self: *const @This()) u16 {
        return @intCast(u16, self.frame);
    }

    /// advance computes the current animation frame and returns true if the value
    /// changed since the last call to advance().
    pub fn advance(self: *@This()) bool {
        // Ignore this call if we have only zero or one frames.
        if (self.descriptor.frame_count < 2)
            return false;

        // Has enough time passed to advance to a new frame?
        const now = glfw.getTime();
        if ((now - self.last_update) < self.update_interval)
            return false;

        self.last_update = now;

        switch (self.descriptor.type) {
            .loop => self.frame = @rem((self.frame + 1), @intCast(i32, self.descriptor.frame_count)),
            .once => if (self.frame < (self.descriptor.frame_count - 1)) {
                self.frame += 1;
            },
            .once_reset => if (!self.state) {
                if (self.frame >= (self.descriptor.frame_count - 1)) {
                    self.state = true;
                    self.frame = 0;
                } else {
                    self.frame += 1;
                }
            },
            .reverse => self.advanceReverse(),
        }

        return true;
    }

    fn advanceReverse(self: *@This()) void {
        if (self.state) {
            if (self.frame == 0) {
                self.state = false;
                return self.advanceReverse();
            }
            self.frame -= 1;
        } else {
            if (self.frame >= self.descriptor.frame_count - 1) {
                self.state = true;
                return self.advanceReverse();
            }
            self.frame += 1;
        }
    }
};
