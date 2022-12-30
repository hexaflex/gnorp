const std = @import("std");
const gnorp = @import("main.zig");
const graphics = gnorp.graphics;
const animation = gnorp.animation.sprites;

test {
    std.testing.refAllDecls(@This());
}

/// The pixel data associated with the spritesheet.
texture: *graphics.Texture = undefined,

/// animations holds descriptors for all animations in the sprite sheet.
animations: *animation.DescriptorSet = undefined,

refcount: usize = 0,

/// initFromFile loads a spritesheet from the given, relative file path.
///
/// The path is not expected to have a file extension and should be relative
/// to the config.content_dir directory. This function will load a texture
/// from `gnorp.resources.assetPath(path + ".png")` and animation data from
/// `gnorp.resources.assetPath(path + ".txt")`.
pub fn initFromFile(path: []const u8) !*@This() {
    var alloc = gnorp.allocator;

    const res_path = try gnorp.resources.assetPath(path);
    defer alloc.free(res_path);

    const anim_path = try std.fmt.allocPrint(alloc, "{s}.txt", .{res_path});
    defer alloc.free(anim_path);

    const tex_path = try std.fmt.allocPrint(alloc, "{s}.png", .{res_path});
    defer alloc.free(tex_path);

    var texture = try graphics.Texture.initFromFile(tex_path, null);
    defer texture.release();

    var animations = try animation.DescriptorSet.initFromFile(anim_path);
    defer animations.release();

    return try init(texture, animations);
}

/// initFromTexture creates a new spritesheet for the given texture.
/// This creates a single sprite animation with one frame spanning the entire
/// texture. This ensures the spritesheet can be used to display the texture
/// as a single image.
pub fn initFromTexture(texture: *graphics.Texture) !*@This() {
    var animations = try animation.DescriptorSet.initCapacity(1);
    errdefer animations.release();

    animations.frame_size = .{
        @floatToInt(u32, texture.content_size[0]),
        @floatToInt(u32, texture.content_size[1]),
    };
    animations.appendAssumeCapacity(.{});

    return try init(texture, animations);
}

/// init creates a new spritesheet for the given texture, frame size and
/// animation data.
///
/// Ensures that animations has at least one entry.
/// Ensures that the frame_size values are > 0.
///
/// The spritesheet assumes ownership of the animation memory.
pub fn init(
    texture: *graphics.Texture,
    animations: *animation.DescriptorSet,
) !*@This() {
    if (animations.len() == 0)
        return error.InvalidAnimationCount;

    if (animations.frame_size[0] == 0)
        return error.InvalidFrameWidth;

    if (animations.frame_size[1] == 0)
        return error.InvalidFrameHeight;

    var self = try gnorp.allocator.create(@This());
    errdefer gnorp.allocator.destroy(self);

    self.* = .{};
    self.texture = texture.reference();
    self.animations = animations.reference();
    return self.reference();
}

fn deinit(self: *@This()) void {
    self.texture.release();
    self.animations.release();
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

/// getFrameSize returns the size of a single frame in pixels.
pub inline fn getFrameSize(self: *const @This()) [2]f32 {
    return [_]f32{
        @intToFloat(f32, self.animations.frame_size[0]),
        @intToFloat(f32, self.animations.frame_size[1]),
    };
}

/// getFrameSizeUV returns the size of a single frame in texture space.
pub inline fn getFrameSizeUV(self: *const @This()) [2]f32 {
    return [_]f32{
        @divFloor(@intToFloat(f32, self.animations.frame_size[0]), self.texture.texture_size[0]),
        @divFloor(@intToFloat(f32, self.animations.frame_size[1]), self.texture.texture_size[1]),
    };
}

/// getFrameOffsets fills uv with UV coordinates for the nth frame in the
/// given animation. The order of the coordinates is as follows:
/// Top-left, top-right, bottom-left, bottom-right.
///
/// Asserts that uv has at least 8 elements.
/// Asserts that frame is in range.
/// Asserts that the texture isn't empty.
pub fn getFrameOffsets(
    self: *const @This(),
    anim: *const animation.Descriptor,
    frame: u16,
    uv: []f32,
) void {
    std.debug.assert(uv.len >= 8);
    std.debug.assert(frame < anim.frame_count);

    const frame_abs = @as(u32, anim.frame_index) + @as(u32, frame);
    const ts = self.texture.texture_size;
    const fs = self.animations.frame_size;
    const frames_per_row = @floatToInt(u32, self.texture.content_size[0]) / fs[0];
    const frames_per_col = @floatToInt(u32, self.texture.content_size[1]) / fs[1];

    std.debug.assert(frames_per_row > 0);

    // invert the Y component, as the texture is up-side-down.
    const fx = frame_abs % frames_per_row;
    const fy = frames_per_col - 1 - (frame_abs / frames_per_row);

    const x1 = @intToFloat(f32, fx * fs[0]) / ts[0];
    const y1 = @intToFloat(f32, fy * fs[1]) / ts[1];
    const x2 = x1 + (@intToFloat(f32, fs[0]) / ts[0]);
    const y2 = y1 + (@intToFloat(f32, fs[1]) / ts[1]);

    // Top-left
    uv[0] = x1;
    uv[1] = y1;
    // top-right
    uv[2] = x2;
    uv[3] = y1;
    // bottom-left
    uv[4] = x1;
    uv[5] = y2;
    // bottom-right
    uv[6] = x2;
    uv[7] = y2;

    if (anim.attr.flip_horizontal) {
        uv[0] = x2;
        uv[2] = x1;
        uv[4] = x2;
        uv[6] = x1;
    }

    if (anim.attr.flip_vertical) {
        uv[1] = y2;
        uv[3] = y2;
        uv[5] = y1;
        uv[7] = y1;
    }
}

/// getAnimation returns the descriptor for the nth animation.
/// Asserts that the index is in range.
pub inline fn getAnimation(self: *@This(), index: u16) *const animation.Descriptor {
    std.debug.assert(index < self.getAnimationCount());
    return self.animations.at(index);
}

/// getAnimationCount returns the total number of available animations.
pub inline fn getAnimationCount(self: *const @This()) u16 {
    return @truncate(u16, self.animations.len());
}
