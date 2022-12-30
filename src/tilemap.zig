const std = @import("std");
const glfw = @import("glfw");
const gpu = @import("gpu");
const gnorp = @import("main.zig");
const graphics = gnorp.graphics;
const animation = gnorp.animation;

test {
    std.testing.refAllDecls(@This());
}

// Keep this struct in sync with LocalUniforms in tilemap.wgsl
const RenderUniforms = extern struct {
    mat_model: gnorp.math.Mat,
    color: [4]f32,
    grid_width: u32,
    tile_width: u32,
    tile_height: u32,
    selected_tile: u32,
};

const RenderUniformBuffer = graphics.UniformBuffer(RenderUniforms);

/// CPUTile defines properties for a single tile on the CPU.
const CPUTile = struct {
    animation: animation.sprites.State,
};

/// GPUTile defines properties for a single tile on the GPU.
const GPUTile = extern struct {
    uv: [8]f32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    color: [4]f32 = .{ 1, 1, 1, 1 },
};

const index_buffer_size = 6 * @sizeOf(u16);

pub const tile_undefined = std.math.maxInt(u32);
pub var min_zoom: f32 = 0.5;
pub var max_zoom: f32 = 10.0;

transform: gnorp.math.Transform = gnorp.math.Transform.init(),
render_uniforms: *RenderUniformBuffer = undefined,
render_pipeline: *gpu.RenderPipeline = undefined,
render_bindgroup: *gpu.BindGroup = undefined,
spritesheet: *graphics.Spritesheet = undefined,
index_buffer: *gpu.Buffer = undefined,
tile_buffer: *gpu.Buffer = undefined,
texture_view: *gpu.TextureView = undefined,
sampler: *gpu.Sampler = undefined,
cpu_tiles: []CPUTile = &.{},
gpu_tiles: []GPUTile = &.{},
animating_tiles: std.ArrayList(usize) = undefined,
refcount: usize = 0,
width: u32 = 0,
height: u32 = 0,
color: [4]f32 = .{ 1, 1, 1, 1 },
selected_tile: u32 = tile_undefined,

/// init creates a new tilemap with the given dimensions and using the
/// specified spritesheet.
///
/// Asserts that width and height are > 0.
pub fn init(width: u32, height: u32, spritesheet: *graphics.Spritesheet) !*@This() {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);

    const alloc = gnorp.allocator;
    var self = try alloc.create(@This());
    errdefer alloc.destroy(self);

    self.* = .{};
    self.width = width;
    self.height = height;

    self.spritesheet = spritesheet.reference();
    errdefer self.spritesheet.release();

    self.render_uniforms = try RenderUniformBuffer.init();
    errdefer self.render_uniforms.release();

    self.texture_view = spritesheet.texture.createView(&.{});
    errdefer self.texture_view.release();

    self.sampler = graphics.device.createSampler(&.{});
    errdefer self.sampler.release();

    try self.initComponents();
    self.center(try graphics.getFramebufferSize());
    return self.reference();
}

fn deinit(self: *@This()) void {
    const alloc = gnorp.allocator;

    self.animating_tiles.deinit();
    self.texture_view.release();
    self.sampler.release();
    self.render_uniforms.release();
    self.render_pipeline.release();
    self.render_bindgroup.release();
    self.spritesheet.release();
    self.index_buffer.release();
    self.tile_buffer.release();
    alloc.free(self.cpu_tiles);
    alloc.free(self.gpu_tiles);
    alloc.destroy(self);
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

/// getColor returns the color applied to all tiles.
pub inline fn getColor(self: *const @This()) [4]f32 {
    return self.color;
}

/// setColor sets the color applied to all tiles.
pub fn setColor(self: *@This(), clr: [4]f32) void {
    self.color = clr;
    self.transform.dirty = true;
}

/// getSelectedTile returns the x/y coordinates of the currently
/// selected tile. Returns null if no tile is selected.
pub inline fn getSelectedTile(self: *@This()) ?[2]u32 {
    return if (self.selected_tile != tile_undefined)
        [_]u32{
            self.selected_tile % self.width,
            self.selected_tile / self.width,
        }
    else
        null;
}

/// setSelectedTile sets the currently selected tile.
/// This unsets the current selection iff x or y are out of range
/// or set to `Tilemap.tile_undefined`.
pub fn setSelectedTile(self: *@This(), x: u32, y: u32) void {
    self.selected_tile = if (x < self.width and y < self.height)
        (y * self.width + x)
    else
        tile_undefined;
    self.transform.dirty = true;
}

/// getTileColor returns the nth tile's color.
/// Asserts that x/y are in range.
pub inline fn getTileColor(self: *const @This(), x: u32, y: u32) [4]f32 {
    std.debug.assert(x < self.width);
    std.debug.assert(y < self.height);
    return self.gpu_tiles[y * self.width + x].color;
}

/// setTileColor sets the nth tile's color.
/// Asserts that x/y are in range.
pub fn setTileColor(self: *@This(), x: u32, y: u32, clr: [4]f32) void {
    std.debug.assert(x < self.width);
    std.debug.assert(y < self.height);

    const n = y * self.width + x;
    self.gpu_tiles[n].color = clr;
    graphics.device.getQueue().writeBuffer(
        self.tile_buffer,
        n * @sizeOf(GPUTile),
        self.gpu_tiles[n .. n + 1],
    );
}

/// getTileAnimation returns the nth tile's animation.
/// Asserts that x/y are in range.
pub inline fn getTileAnimation(self: *const @This(), x: u32, y: u32) u16 {
    std.debug.assert(x < self.width);
    std.debug.assert(y < self.height);
    return &self.cpu_tiles[y * self.width + x].animation.descriptor;
}

/// setTileAnimation sets the nth tile's animation.
/// Asserts that x/y are in range.
/// Asserts that anim is in range.
pub fn setTileAnimation(self: *@This(), x: u32, y: u32, anim: u16) void {
    std.debug.assert(x < self.width);
    std.debug.assert(y < self.height);
    std.debug.assert(anim < self.spritesheet.getAnimationCount());

    const n = y * self.width + x;
    var _animation = self.spritesheet.getAnimation(anim);
    self.cpu_tiles[n].animation = _animation.createState();

    // If the new animation has 0 or 1 frame, we do not want `update()` to
    // waste time trying to update this tile's animation state.
    //
    // Therefor we add tiles with animations to a list which is used to
    // determine which tiles to update. Any tiles not in this list are
    // simply ignored.
    if (_animation.frame_count > 1) {
        // This tile animates. Add its index iff it is not already in the list.
        if (std.mem.indexOfScalar(usize, self.animating_tiles.items, n) == null)
            self.animating_tiles.appendAssumeCapacity(n);
    } else {
        // This tile is static. Remove its index from the list iff it is present.
        if (std.mem.indexOfScalar(usize, self.animating_tiles.items, n)) |index|
            _ = self.animating_tiles.swapRemove(index);
    }

    // Make sure the GPU has the initial frame UVs.
    self.spritesheet.getFrameOffsets(_animation, 0, &self.gpu_tiles[n].uv);
    graphics.device.getQueue().writeBuffer(
        self.tile_buffer,
        n * @sizeOf(GPUTile),
        self.gpu_tiles[n .. n + 1],
    );
}

/// getTilePosition returns the pixel position for the center of the given tile,
/// relative to the top-left corner of the tilemap. This accounts for the
/// current zoom factor.
///
/// Asserts that x/y are in range.
pub fn getTilePosition(self: *const @This(), x: u32, y: u32) [2]f32 {
    std.debug.assert(x < self.width);
    std.debug.assert(y < self.height);

    const zf = self.transform.scale;
    const ts = self.spritesheet.getFrameSize();
    const tw = ts[0] * zf[0];
    const th = ts[1] * zf[1];

    return .{
        @intToFloat(f32, x) * tw + tw * 0.5,
        @intToFloat(f32, y) * th + tw * 0.5,
    };
}

/// Scroll moves the grid origin by the given relative offset.
pub fn scroll(self: *@This(), offset: [2]f32) void {
    const pos = self.transform.position;
    self.transform.setPosition(.{ pos[0] + offset[0], pos[1] + offset[1] });
}

/// centerPosition centers the given pixel position on the tilemap in the
/// specified viewport.
pub inline fn centerPosition(self: *@This(), pos: [2]f32, view: [2]f32) void {
    self.transform.setPosition(.{
        (view[0] * 0.5) - pos[0],
        (view[1] * 0.5) - pos[1],
    });
}

/// centerTile centers the given tile in the specified viewport.
/// Asserts that x/y are in range.
pub fn centerTile(self: *@This(), x: u32, y: u32, view: [2]f32) void {
    std.debug.assert(x < self.width);
    std.debug.assert(y < self.height);

    const zf = self.transform.scale;
    const ts = self.spritesheet.getFrameSize();
    const tw = ts[0] * zf[0];
    const th = ts[1] * zf[1];

    self.transform.setPosition(.{
        (view[0] * 0.5) - (@intToFloat(f32, x) * tw + tw * 0.5),
        (view[1] * 0.5) - (@intToFloat(f32, y) * th + tw * 0.5),
    });
}

/// center centers the tilemap in the specified viewport.
pub inline fn center(self: *@This(), view: [2]f32) void {
    self.centerTile(self.width / 2, self.height / 2, view);
}

/// setZoom sets the current zoom factor.
pub fn setZoom(self: *@This(), value: u32) void {
    if (value > 0) {
        const s = std.math.clamp(@intToFloat(f32, value), min_zoom, max_zoom);
        self.transform.setScale(.{ s, s });
    }
}

/// zoom zooms in/out by the specified amount using the given point as
/// the zoom focus.
pub fn zoom(self: *@This(), delta: i32, focus: [2]f32) void {
    if (delta == 0) return;

    // Zooming needs to center on the given focal point.
    // For this to work, we figure out which position on the grid is currently
    // under the focus point. Then we perform the zoom and scroll back to that
    // position.

    const origin = self.transform.position;
    const abs_focus = [2]f32{
        focus[0] - origin[0],
        focus[1] - origin[1],
    };
    const fdelta = [2]f32{
        @intToFloat(f32, delta),
        @intToFloat(f32, delta),
    };

    const old_scale = self.transform.scale;
    self.transform.setScale(.{
        std.math.clamp(old_scale[0] + fdelta[0], min_zoom, max_zoom),
        std.math.clamp(old_scale[1] + fdelta[1], min_zoom, max_zoom),
    });

    const xy1 = [2]f32{
        abs_focus[0] / old_scale[0],
        abs_focus[1] / old_scale[1],
    };

    self.transform.setPosition(.{
        abs_focus[0] - ((xy1[0] * self.transform.scale[0]) - origin[0]),
        abs_focus[1] - ((xy1[1] * self.transform.scale[1]) - origin[1]),
    });
}

/// update updates tile states.
pub fn update(self: *@This()) !void {
    if (self.transform.getModelIfUpdated()) |mat| {
        const fs = self.spritesheet.getFrameSize();
        self.render_uniforms.set(&.{
            .mat_model = mat,
            .color = self.color,
            .grid_width = self.width,
            .tile_width = @floatToInt(u32, fs[0]),
            .tile_height = @floatToInt(u32, fs[1]),
            .selected_tile = self.selected_tile,
        });
    }

    var queue = graphics.device.getQueue();
    for (self.animating_tiles.items) |n| {
        const ct = &self.cpu_tiles[n];

        if (ct.animation.advance()) {
            const gt = &self.gpu_tiles[n];
            const frame = ct.animation.getCurrentFrame();
            self.spritesheet.getFrameOffsets(ct.animation.descriptor, frame, &gt.uv);
            queue.writeBuffer(self.tile_buffer, n * @sizeOf(GPUTile), self.gpu_tiles[n .. n + 1]);
        }
    }
}

/// draw records the tilemap render pass.
pub fn draw(self: *@This(), encoder: *gpu.CommandEncoder) void {
    const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = @typeName(@This()) ++ " render pass",
        .color_attachments = &.{graphics.getColorAttachment(.load)},
    }));
    pass.setIndexBuffer(self.index_buffer, .uint16, 0, index_buffer_size);
    pass.setPipeline(self.render_pipeline);
    pass.setBindGroup(0, self.render_bindgroup, &.{});
    pass.drawIndexed(6, self.width * self.height, 0, 0, 0);
    pass.end();
    pass.release();
}

/// initComponents initializes all CPU- and GPU buffers as well as the pipeline
/// and bindgroup.
fn initComponents(self: *@This()) !void {
    const alloc = gnorp.allocator;
    const index_data = [_]u16{ 0, 1, 2, 2, 1, 3 };
    const gpu_buffer_size = self.width * self.height * @sizeOf(GPUTile);

    self.cpu_tiles = try alloc.alloc(CPUTile, self.width * self.height);
    errdefer alloc.free(self.cpu_tiles);
    std.mem.set(CPUTile, self.cpu_tiles, .{
        .animation = self.spritesheet.getAnimation(0).createState(),
    });

    self.gpu_tiles = try alloc.alloc(GPUTile, self.width * self.height);
    errdefer alloc.free(self.gpu_tiles);
    std.mem.set(GPUTile, self.gpu_tiles, .{});

    self.animating_tiles = try std.ArrayList(usize).initCapacity(gnorp.allocator, self.gpu_tiles.len);
    errdefer self.animating_tiles.deinit();

    self.index_buffer = graphics.device.createBuffer(&.{
        .label = @typeName(@This()) ++ " index_buffer",
        .usage = .{ .copy_dst = true, .index = true },
        .size = index_buffer_size,
        .mapped_at_creation = true,
    });

    std.mem.copy(u16, self.index_buffer.getMappedRange(u16, 0, index_data.len).?, &index_data);
    self.index_buffer.unmap();

    self.tile_buffer = graphics.device.createBuffer(&.{
        .label = @typeName(@This()) ++ " tile_buffer",
        .usage = .{ .copy_dst = true, .vertex = true, .storage = true },
        .size = gpu_buffer_size,
        .mapped_at_creation = true,
    });

    std.mem.copy(
        GPUTile,
        self.tile_buffer.getMappedRange(GPUTile, 0, self.gpu_tiles.len).?,
        self.gpu_tiles,
    );
    self.tile_buffer.unmap();

    const blend = gpu.BlendComponent{
        .operation = .add,
        .src_factor = .src_alpha,
        .dst_factor = .one_minus_src_alpha,
    };

    const color_target = gpu.ColorTargetState{
        .format = graphics.getSwapchainFormat(),
        .blend = &.{ .color = blend, .alpha = blend },
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };

    const src = try self.getShaderSrc();
    defer alloc.free(src);

    const module = graphics.device.createShaderModuleWGSL(
        @typeName(@This()) ++ " render shader module",
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
    });

    self.render_pipeline = graphics.device.createRenderPipeline(&.{
        .label = @typeName(@This()) ++ " render_pipeline",
        .vertex = vertex_state,
        .fragment = &fragment_state,
        .multisample = .{ .count = gnorp.config.sample_count },
        .primitive = .{ .cull_mode = .back },
    });

    const BgEntry = gpu.BindGroup.Entry;
    self.render_bindgroup = graphics.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
        .label = @typeName(@This()) ++ " render_bindgroup",
        .layout = self.render_pipeline.getBindGroupLayout(0),
        .entries = &.{
            graphics.getSharedBindGroupEntry(0),
            self.render_uniforms.getBindGroupEntry(1),
            BgEntry.buffer(2, self.tile_buffer, 0, gpu_buffer_size),
            BgEntry.textureView(3, self.texture_view),
            BgEntry.sampler(4, self.sampler),
        },
    }));
}

fn getShaderSrc(self: *const @This()) ![:0]const u8 {
    const alloc = gnorp.allocator;
    var out = try alloc.dupeZ(u8, @embedFile("shared_uniforms.wgsl") ++ @embedFile("tilemap.wgsl"));
    errdefer alloc.free(out);

    const key = "TILE_CAPACITY";
    while (std.mem.indexOf(u8, out, key)) |index| {
        var arr = out[index .. index + key.len];
        std.mem.set(u8, arr, ' ');
        _ = try std.fmt.bufPrint(arr, "{}u", .{self.gpu_tiles.len});
    }

    return out;
}
