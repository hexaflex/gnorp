const std = @import("std");
const gpu = @import("gpu");
const gnorp = @import("main.zig");
const graphics = gnorp.graphics;
const animation = gnorp.animation.sprites;
const math = gnorp.math;

test {
    std.testing.refAllDecls(@This());
}

const RenderUniforms = extern struct {
    mat_model: math.Mat,
    color: [4]f32,
};

const RenderUniformBuffer = graphics.UniformBuffer(RenderUniforms);
const vertex_buffer_size = 4 * 2 * @sizeOf(f32);
const uv_buffer_size = 4 * 2 * @sizeOf(f32);
const index_buffer_size = 6 * @sizeOf(u16);

transform: math.Transform = math.Transform.init(),
pipeline: ?*gpu.RenderPipeline = null,
bind_group: ?*gpu.BindGroup = null,
vertex_buffer: *gpu.Buffer = undefined,
uv_buffer: *gpu.Buffer = undefined,
index_buffer: *gpu.Buffer = undefined,
spritesheet: *graphics.Spritesheet = undefined,
texture_view: *gpu.TextureView = undefined,
sampler: *gpu.Sampler = undefined,
blend_state: gpu.BlendState = .{},
animation: animation.State = .{},
uniforms: *RenderUniformBuffer = undefined,
color: [4]f32 = .{ 1, 1, 1, 1 },
refcount: usize = 0,
pipeline_dirty: bool = true,
animation_index: u16 = 0,

pub fn init(spritesheet: *graphics.Spritesheet) !*@This() {
    var self = try gnorp.allocator.create(@This());
    errdefer gnorp.allocator.destroy(self);
    self.* = .{};

    self.spritesheet = spritesheet.reference();
    self.transform.setScale(spritesheet.getFrameSize());

    self.texture_view = spritesheet.texture.createView(&.{});
    errdefer self.texture_view.release();

    self.sampler = graphics.device.createSampler(&.{});
    errdefer self.sampler.release();

    self.uniforms = try RenderUniformBuffer.init();
    errdefer self.uniforms.release();

    self.initMesh();
    self.setAnimation(0);
    return self.reference();
}

fn deinit(self: *@This()) void {
    self.uniforms.release();
    if (self.pipeline) |x| x.release();
    if (self.bind_group) |x| x.release();
    self.vertex_buffer.release();
    self.uv_buffer.release();
    self.index_buffer.release();
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
pub fn release(self: *@This()) void {
    gnorp.resources.release(self, deinit);
}

/// setBlendState sets the sprite's blend mode. This force a rebuild
/// of the entire pipeline.
pub fn setBlendState(self: *@This(), state: gpu.BlendState) void {
    self.blend_state = state;
    self.pipeline_dirty = true;
}

/// getAnimation returns the current animation index.
pub fn getAnimation(self: *const @This()) u16 {
    return self.animation_index;
}

/// setAnimation sets the nth animation as the active one.
/// Asserts that index is in bounds.
pub fn setAnimation(self: *@This(), index: u16) void {
    std.debug.assert(index < self.spritesheet.getAnimationCount());
    self.animation_index = index;
    self.animation = self.spritesheet.getAnimation(index).createState();
    self.updateFrame(); // Ensure the first frame is visible.
}

pub fn setColor(self: *@This(), clr: [4]f32) void {
    self.color = clr;

    // re-use the transform.dirty value to indicate we need to
    // re-upload the uniform struct inside update(). This will
    // recompute the model matrix, possibly unnecessarily but meh.
    self.transform.dirty = true;
}

/// update updates the sprite's animation state if needed. Additionally, it
/// ensures the shader has the most up-to-date model matrix value.
pub fn update(self: *@This()) !void {
    if (self.transform.getModelIfUpdated()) |mat| {
        self.uniforms.set(&.{
            .mat_model = mat,
            .color = self.color,
        });
    }

    // Advance animation if applicable and update UV coordinates accordingly.
    if (self.animation.advance())
        self.updateFrame();

    if (self.pipeline_dirty) {
        self.pipeline_dirty = false;

        if (self.pipeline) |x| x.release();
        if (self.bind_group) |x| x.release();

        self.initPipeline();
    }
}

/// draw returns a commandbuffer with the sprite drawing operations.
/// The returned buffer can be submitted to the GPU for execution.
/// Caller must release the buffer after use.
pub fn draw(self: *@This(), encoder: *gpu.CommandEncoder) void {
    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .label = @typeName(@This()) ++ " render pass",
        .color_attachments = &.{graphics.getColorAttachment(.load)},
    });

    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setVertexBuffer(0, self.vertex_buffer, 0, vertex_buffer_size);
    pass.setVertexBuffer(1, self.uv_buffer, 0, uv_buffer_size);
    pass.setIndexBuffer(self.index_buffer, .uint16, 0, index_buffer_size);
    pass.setPipeline(self.pipeline.?);
    pass.setBindGroup(0, self.bind_group.?, &.{});
    pass.drawIndexed(6, 1, 0, 0, 0);
    pass.end();
    pass.release();
}

/// updateFrame updates UV coordinates for the current sprite animation frame.
inline fn updateFrame(self: *const @This()) void {
    const frame = self.animation.getCurrentFrame();
    var uv_data: [8]f32 = undefined;
    self.spritesheet.getFrameOffsets(self.animation.descriptor, frame, &uv_data);
    graphics.device.getQueue().writeBuffer(self.uv_buffer, 0, &uv_data);
}

/// initPipeline initializes the render pipeline.
fn initPipeline(self: *@This()) void {
    const color_target = gpu.ColorTargetState{
        .format = graphics.getSwapchainFormat(),
        .blend = &self.blend_state,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };

    const module = graphics.device.createShaderModuleWGSL(
        @typeName(@This()) ++ " shader module",
        @embedFile("shared_uniforms.wgsl") ++ @embedFile("sprite.wgsl"),
    );
    defer module.release();

    const fragment_state = gpu.FragmentState.init(.{
        .module = module,
        .entry_point = "fs_main",
        .targets = &.{color_target},
    });

    const vertex_layout = gpu.VertexBufferLayout.init(.{
        .array_stride = 2 * @sizeOf(f32),
        .attributes = &.{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
        },
    });

    const uv_layout = gpu.VertexBufferLayout.init(.{
        .array_stride = 2 * @sizeOf(f32),
        .attributes = &.{
            .{ .format = .float32x2, .offset = 0, .shader_location = 1 },
        },
    });

    const vertex_state = gpu.VertexState.init(.{
        .module = module,
        .entry_point = "vs_main",
        .buffers = &.{ vertex_layout, uv_layout },
    });

    self.pipeline = graphics.device.createRenderPipeline(&.{
        .label = @typeName(@This()) ++ " render pipeline",
        .vertex = vertex_state,
        .fragment = &fragment_state,
        .depth_stencil = null,
        .multisample = .{ .count = gnorp.config.sample_count },
        .primitive = .{ .cull_mode = .back },
    });

    self.bind_group = graphics.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
        .label = @typeName(@This()) ++ " BindGroup",
        .layout = self.pipeline.?.getBindGroupLayout(0),
        .entries = &.{
            graphics.getSharedBindGroupEntry(0),
            self.uniforms.getBindGroupEntry(1),
            gpu.BindGroup.Entry.textureView(2, self.texture_view),
            gpu.BindGroup.Entry.sampler(3, self.sampler),
        },
    }));
}

/// initMesh initializes the necessary mesh components.
fn initMesh(self: *@This()) void {
    const index_data = [_]u16{ 0, 1, 2, 2, 1, 3 };
    const vertex_data = [_]f32{ 0, 1, 1, 1, 0, 0, 1, 0 };
    const uv_data = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };

    self.vertex_buffer = graphics.device.createBuffer(&.{
        .label = @typeName(@This()) ++ " vertex buffer",
        .usage = .{ .copy_dst = true, .vertex = true },
        .size = vertex_buffer_size,
        .mapped_at_creation = true,
    });
    std.mem.copy(f32, self.vertex_buffer.getMappedRange(f32, 0, vertex_data.len).?, &vertex_data);
    self.vertex_buffer.unmap();

    self.uv_buffer = graphics.device.createBuffer(&.{
        .label = @typeName(@This()) ++ " uv buffer",
        .usage = .{ .copy_dst = true, .vertex = true },
        .size = uv_buffer_size,
        .mapped_at_creation = true,
    });
    std.mem.copy(f32, self.uv_buffer.getMappedRange(f32, 0, uv_data.len).?, &uv_data);
    self.uv_buffer.unmap();

    self.index_buffer = graphics.device.createBuffer(&.{
        .label = @typeName(@This()) ++ " index buffer",
        .usage = .{ .copy_dst = true, .index = true },
        .size = index_buffer_size,
        .mapped_at_creation = true,
    });
    std.mem.copy(u16, self.index_buffer.getMappedRange(u16, 0, index_data.len).?, &index_data);
    self.index_buffer.unmap();
}
