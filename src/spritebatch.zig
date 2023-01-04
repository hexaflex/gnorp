const std = @import("std");
const gpu = @import("gpu");
const zmath = @import("zmath");
const gnorp = @import("main.zig");
const math = gnorp.math;
const graphics = gnorp.graphics;
const animation = gnorp.animation.sprites;

test {
    std.testing.refAllDecls(@This());
}

const indices = [_]u16{ 0, 1, 2, 2, 1, 3 };

/// CPUSprite represents sprite metadata outside the GPU.
const CPUSprite = struct {
    transform: math.Transform,
    animation: animation.State,
};

/// GPUSprite defines data for a single sprite on the GPU.
const GPUSprite = extern struct {
    mat_model: zmath.Mat,
    uv: [8]f32,
    color: [4]f32,
};

const RenderUniforms = extern struct {
    mat_model: zmath.Mat,
    color: [4]f32,
};

const RenderUniformBuffer = graphics.UniformBuffer(RenderUniforms);

transform: math.Transform = math.Transform.init(),
blend_state: gpu.BlendState = .{},
pipeline: ?*gpu.RenderPipeline = null,
bind_group: ?*gpu.BindGroup = null,
spritesheet: *graphics.Spritesheet = undefined,
texture_view: *gpu.TextureView = undefined,
sampler: *gpu.Sampler = undefined,
uniforms: *RenderUniformBuffer = undefined,
index_buffer: *gpu.Buffer = undefined,
gpu_buffer: ?*gpu.Buffer = null,
gpu_sprites: []GPUSprite = &.{},
cpu_sprites: []CPUSprite = &.{},
sprites_index: usize = 0,
color: [4]f32 = .{ 1, 1, 1, 1 },
refcount: usize = 0,

pub fn init(spritesheet: *graphics.Spritesheet) !*@This() {
    var self = try gnorp.allocator.create(@This());
    errdefer gnorp.allocator.destroy(self);

    self.* = .{};
    self.spritesheet = spritesheet.reference();

    self.texture_view = spritesheet.texture.createView(&.{});
    errdefer self.texture_view.release();

    self.sampler = graphics.device.createSampler(&.{});
    errdefer self.sampler.release();

    self.uniforms = try RenderUniformBuffer.init();
    errdefer self.uniforms.release();

    self.initMesh();
    return self.reference();
}

fn deinit(self: *@This()) void {
    gnorp.allocator.free(self.gpu_sprites);
    gnorp.allocator.free(self.cpu_sprites);
    self.uniforms.release();
    self.index_buffer.release();
    if (self.gpu_buffer) |x| x.release();
    if (self.pipeline) |x| x.release();
    if (self.bind_group) |x| x.release();
    self.sampler.release();
    self.texture_view.release();
    self.spritesheet.release();
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

/// setBlendState sets the blend state used for all sprites.
pub fn setBlendState(self: *@This(), state: gpu.BlendState) !void {
    self.blend_state = state;
    try self.resizeRebuildPipeline(self.cpu_sprites.len);
}

/// setColor sets the color applied to the batch as a whole.
/// Use setSpriteColor to change the color for a specific sprite.
pub fn setColor(self: *@This(), clr: [4]f32) void {
    self.color = clr;

    // re-use the transform.dirty value to indicate we need to
    // re-upload the uniform struct inside update().
    self.transform.dirty = true;
}

/// setSpriteAnimation sets the nth sprite's animation as the active one.
/// Asserts that n is in bounds.
/// Asserts that index is in bounds.
pub fn setSpriteAnimation(self: *@This(), n: usize, index: u16) void {
    std.debug.assert(n < self.getSpriteCount());
    std.debug.assert(index < self.spritesheet.getAnimationCount());
    self.cpu_sprites[n].animation = self.spritesheet.getAnimation(index).createState();
}

/// setSpriteAnimationFrame sets the nth sprite's current animation frame.
/// Asserts that n is in bounds.
/// Asserts that frame is in bounds.
pub fn setSpriteAnimationFrame(self: *@This(), n: usize, frame: u16) void {
    std.debug.assert(n < self.getSpriteCount());
    std.debug.assert(frame < self.cpu_sprites[n].animation.descriptor.frame_count);
    self.cpu_sprites[n].animation.frame = frame;
}

/// setSpriteAngle sets the nth sprite's rotation in radians.
/// Asserts that n is in range.
pub inline fn setSpriteAngle(self: *@This(), n: usize, angle: f32) void {
    std.debug.assert(n < self.getSpriteCount());
    self.cpu_sprites[n].transform.setAngle(angle);
}

/// getSpriteAngle returns the nth sprite's rotation in radians.
/// Asserts that n is in range.
pub inline fn getSpriteAngle(self: *@This(), n: usize) f32 {
    std.debug.assert(n < self.getSpriteCount());
    return self.cpu_sprites[n].transform.getAngle();
}

/// setSpritePosition sets the nth sprite's position.
/// Asserts that n is in range.
pub inline fn setSpritePosition(self: *@This(), n: usize, pos: [2]f32) void {
    std.debug.assert(n < self.getSpriteCount());
    self.cpu_sprites[n].transform.setPosition(pos);
}

/// getSpritePosition returns the nth sprite's position.
/// Asserts that n is in range.
pub inline fn getSpritePosition(self: *@This(), n: usize) [2]f32 {
    std.debug.assert(n < self.getSpriteCount());
    return self.cpu_sprites[n].transform.getPosition();
}

/// setSpriteScale sets the nth sprite's scale.
/// Asserts that n is in range.
pub inline fn setSpriteScale(self: *@This(), n: usize, scale: [2]f32) void {
    std.debug.assert(n < self.getSpriteCount());
    self.cpu_sprites[n].transform.setScale(scale);
}

/// getSpriteScale returns the nth sprite's scale.
/// Asserts that n is in range.
pub inline fn getSpriteScale(self: *@This(), n: usize) [2]f32 {
    std.debug.assert(n < self.getSpriteCount());
    self.cpu_sprites[n].transform.getScale();
}

/// setSpriteColor sets the nth sprite's color.
/// Asserts that n is in range.
pub fn setSpriteColor(self: *@This(), n: usize, clr: [4]f32) void {
    std.debug.assert(n < self.getSpriteCount());
    self.gpu_sprites[n].color = clr;
    self.cpu_sprites[n].transform.dirty = true;
}

/// getSpriteColor returns the nth sprite's color.
/// Asserts that n is in range.
pub inline fn getSpriteColor(self: *@This(), n: usize) [4]f32 {
    std.debug.assert(n < self.getSpriteCount());
    return self.gpu_sprites[n].color;
}

/// getSpriteCount returns the number of sprites in the batch.
pub inline fn getSpriteCount(self: *const @This()) usize {
    return self.sprites_index;
}

/// addSprite adds a new sprite and returns its index.
pub fn addSprite(self: *@This()) !usize {
    try self.grow();

    const fs = self.spritesheet.animations.frame_size;
    var sprite = CPUSprite{
        .transform = math.Transform.init(),
        .animation = .{},
    };
    sprite.transform.setScale(.{
        @intToFloat(f32, fs[0]),
        @intToFloat(f32, fs[1]),
    });
    sprite.animation = self.spritesheet.getAnimation(0).createState();

    self.cpu_sprites[self.sprites_index] = sprite;
    self.gpu_sprites[self.sprites_index] = GPUSprite{
        .mat_model = zmath.identity(),
        .uv = .{ 0, 0, 1, 0, 0, 1, 1, 1 },
        .color = .{ 1, 1, 1, 1 },
    };
    self.sprites_index += 1;

    return self.sprites_index - 1;
}

/// removeSprite deletes the nth sprite.
/// Asserts that n is in range.
pub fn removeSprite(self: *@This(), n: usize) !void {
    std.debug.assert(n < self.getSpriteCount());

    self.cpu_sprites[n] = self.cpu_sprites[self.sprites_index - 1];
    self.gpu_sprites[n] = self.gpu_sprites[self.sprites_index - 1];
    self.sprites_index -= 1;
    try self.shrink();
}

/// grow grows various buffers if needed.
/// This also rebuilds the bind_group and pipeline because the shaders
/// have fixed sprite array sizes that need to have their size synchronized.
fn grow(self: *@This()) !void {
    const new_size = self.sprites_index + 1;
    const new_capacity = std.math.max(try std.math.ceilPowerOfTwo(usize, new_size), 8);

    if (new_capacity <= self.cpu_sprites.len)
        return;

    try self.resizeRebuildPipeline(new_capacity);
}

/// shrink shrinks the GPU buffer if needed.
fn shrink(self: *@This()) !void {
    var new_capacity = try std.math.ceilPowerOfTwo(usize, self.sprites_index);
    if (self.sprites_index == new_capacity or
        new_capacity >= self.cpu_sprites.len) return;

    try self.resizeRebuildPipeline(new_capacity);
}

/// update updates all sprite animations. Additionally, it ensures the shader
/// has the most up-to-date uniforms.
pub fn update(self: *@This()) !void {
    if (self.transform.getModelIfUpdated()) |mat| {
        self.uniforms.set(&.{
            .mat_model = mat,
            .color = self.color,
        });
    }

    var cs: *CPUSprite = undefined;
    var gs: *GPUSprite = undefined;
    var sprite_dirty = false;
    var queue = graphics.device.getQueue();
    var i: usize = 0;

    while (i < self.sprites_index) : (i += 1) {
        cs = &self.cpu_sprites[i];
        gs = &self.gpu_sprites[i];
        sprite_dirty = false;

        // Update uniforms where needed.
        if (cs.transform.getModelIfUpdated()) |mat| {
            gs.mat_model = mat;
            sprite_dirty = true;
        }

        // Advance animation where applicable and update UV coordinates accordingly.
        if (cs.animation.advance()) {
            self.spritesheet.getFrameOffsets(
                cs.animation.descriptor,
                cs.animation.getCurrentFrame(),
                &gs.uv,
            );
            sprite_dirty = true;
        }

        if (sprite_dirty) {
            queue.writeBuffer(
                self.gpu_buffer.?,
                i * @sizeOf(GPUSprite),
                self.gpu_sprites[i .. i + 1],
            );
        }
    }
}

/// draw returns a commandbuffer with the sprite drawing operations.
/// The returned buffer can be submitted to the GPU for execution.
/// Caller must release the buffer after use.
pub fn draw(self: *@This()) *gpu.CommandBuffer {
    const encoder = graphics.device.createCommandEncoder(null);
    defer encoder.release();

    if (self.getSpriteCount() == 0)
        return encoder.finish(null);

    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .label = @typeName(@This()) ++ " render pass",
        .color_attachments = &.{gnorp.getColorAttachment()},
    });

    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setIndexBuffer(self.index_buffer, .uint16, 0, indices.len * @sizeOf(u16));
    pass.setPipeline(self.pipeline.?);
    pass.setBindGroup(0, self.bind_group.?, &.{});
    pass.drawIndexed(6, @truncate(u32, self.getSpriteCount()), 0, 0, 0);
    pass.end();
    pass.release();

    return encoder.finish(null);
}

/// resizeRebuildPipeline recreates the pipeline and bind group after the sprite
/// buffers have grown or shrunk.
fn resizeRebuildPipeline(self: *@This(), new_capacity: usize) !void {
    if (new_capacity != self.cpu_sprites.len) {
        gnorp.log.debug(@src(), "{s} resizing: {} -> {}", .{
            @typeName(@This()),
            self.cpu_sprites.len,
            new_capacity,
        });

        self.cpu_sprites = try gnorp.allocator.realloc(self.cpu_sprites, new_capacity);
        self.gpu_sprites = try gnorp.allocator.realloc(self.gpu_sprites, new_capacity);

        if (self.gpu_buffer) |x|
            x.release();

        self.gpu_buffer = graphics.device.createBuffer(&.{
            .label = @typeName(@This()) ++ " sprite buffer",
            .usage = .{ .vertex = true, .storage = true, .copy_dst = true },
            .size = new_capacity * @sizeOf(GPUSprite),
        });
    }

    try self.initPipeline(new_capacity);
    graphics.device.getQueue().writeBuffer(self.gpu_buffer.?, 0, self.gpu_sprites);
}

/// initPipeline initializes the render pipeline.
fn initPipeline(self: *@This(), new_capacity: usize) !void {
    const color_target = gpu.ColorTargetState{
        .format = graphics.getSwapchainFormat(),
        .blend = &self.blend_state,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };

    // FIXME: We have to manually embed the sprite count in the shader source
    // because wgsl constants are not supported:
    //
    // gpu: validation error: Pipeline overridable constants are disallowed because they are partially implemented.
    const src = try getShaderSrc(new_capacity);
    defer gnorp.allocator.free(src);

    const module = graphics.device.createShaderModuleWGSL(
        @typeName(@This()) ++ " shader module",
        src,
    );
    defer module.release();

    const fragment_state = gpu.FragmentState.init(.{
        .module = module,
        .entry_point = "fs_main",
        .targets = &.{color_target},
    });

    const vertex_state = gpu.VertexState.init(.{
        .module = module,
        .entry_point = "vs_main",
        .buffers = null,
    });

    if (self.pipeline) |p|
        p.release();

    self.pipeline = graphics.device.createRenderPipeline(&.{
        .label = @typeName(@This()) ++ " render pipeline",
        .vertex = vertex_state,
        .fragment = &fragment_state,
        .depth_stencil = null,
        .multisample = .{ .count = gnorp.config.sample_count },
        .primitive = .{ .cull_mode = .back },
    });

    if (self.bind_group) |p|
        p.release();

    self.bind_group = graphics.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
        .label = @typeName(@This()) ++ " BindGroup",
        .layout = self.pipeline.?.getBindGroupLayout(0),
        .entries = &.{
            gnorp.getSharedBindGroupEntry(0),
            self.uniforms.getBindGroupEntry(1),
            gpu.BindGroup.Entry.buffer(2, self.gpu_buffer.?, 0, self.cpu_sprites.len * @sizeOf(GPUSprite)),
            gpu.BindGroup.Entry.textureView(3, self.texture_view),
            gpu.BindGroup.Entry.sampler(4, self.sampler),
        },
    }));
}

fn initMesh(self: *@This()) void {
    self.index_buffer = graphics.device.createBuffer(&.{
        .label = @typeName(@This()) ++ " index buffer",
        .usage = .{ .index = true, .copy_dst = true },
        .size = indices.len * @sizeOf(u16),
        .mapped_at_creation = true,
    });

    std.mem.copy(u16, self.index_buffer.getMappedRange(u16, 0, indices.len).?, &indices);
    self.index_buffer.unmap();
}

/// getShaderSrc returns the shader source where constants are set to correct values.
/// Caller owns returned memory.
fn getShaderSrc(new_capacity: usize) ![:0]const u8 {
    const src = @embedFile("shared_uniforms.wgsl") ++ @embedFile("spritebatch.wgsl");

    var out = try gnorp.allocator.allocSentinel(u8, src.len, 0);
    std.mem.copy(u8, out, src);

    const key = "SPRITE_CAPACITY";
    while (std.mem.indexOf(u8, out, key)) |index| {
        var arr = out[index .. index + key.len];
        std.mem.set(u8, arr, ' ');
        _ = std.fmt.formatIntBuf(arr, new_capacity, 10, .lower, .{});
    }

    return out;
}
