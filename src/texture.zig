const std = @import("std");
const gpu = @import("gpu");
const gnorp = @import("main.zig");
const graphics = gnorp.graphics;
const zimg = @import("zigimg");

test {
    std.testing.refAllDecls(@This());
}

pub const image_usage = gpu.Texture.UsageFlags{ .texture_binding = true, .copy_dst = true };
pub const storage_usage = gpu.Texture.UsageFlags{ .storage_binding = true, .copy_dst = true };

/// Size of the underlying texture.
texture_size: [2]f32 = .{ 0, 0 },

/// Area of the texture actually used by pixel data.
content_size: [2]f32 = .{ 0, 0 },

/// Pixel format of the texture's GPU data.
format: gpu.Texture.Format = undefined,

/// Underlying GPU texture handle.
gpu_texture: *gpu.Texture = undefined,

refcount: usize = 0,

/// initRandom us meant for debugging. It creates a texture of the given
/// dimensions and fills it with randomly coloured pixel data.
pub fn initRandom(width: u32, height: u32) !*@This() {
    var image_data = try gnorp.allocator.alloc(u8, width * height * 4);
    defer gnorp.allocator.free(image_data);

    var i: usize = 0;
    while (i < image_data.len) : (i += 4) {
        image_data[i + 0] = gnorp.math.random(u8);
        image_data[i + 1] = gnorp.math.random(u8);
        image_data[i + 2] = gnorp.math.random(u8);
        image_data[i + 3] = 0xff;
    }

    return try initFromImage(width, height, .rgba8_unorm, image_data);
}

/// initFromFile creates a texture from the given image file.
///
/// If the format is not specified, this will derive the format from the input image.
/// It is likely that the image data is copied and converted into a more useful format.
///
/// If the format is specified, the image data is passed into the texture unmodified
/// and the function will assume its pixel layout matches the given format.
pub fn initFromFile(filename: []const u8, format: ?gpu.Texture.Format) !*@This() {
    gnorp.log.debug(@src(), "loading texture from: {s}", .{filename});

    var img = try zimg.Image.fromFilePath(gnorp.allocator, filename);
    defer img.deinit();

    if (img.isAnimation())
        return error.AnimatedImagesNotSupported;

    gnorp.log.debug(@src(), "  size: {} x {}, format: {s}", .{ img.width, img.height, @tagName(img.pixels) });

    const width = @truncate(u32, img.width);
    const height = @truncate(u32, img.height);

    if (format) |fmt|
        return initFromImage(width, height, fmt, img.rawBytes());

    switch (img.pixels) {
        .bgra32 => {
            var data = try toBGRA8(&img);
            defer gnorp.allocator.free(data);
            flipVertical(data, img.height, img.width * 4);
            return initFromImage(width, height, .bgra8_unorm, img.rawBytes());
        },
        .indexed1,
        .indexed2,
        .indexed4,
        .indexed8,
        .indexed16,
        .rgb565,
        .rgb555,
        .rgb24,
        .bgr24,
        .rgb48,
        .rgba64,
        .grayscale8Alpha,
        .grayscale16Alpha,
        => {
            var data = try toBGRA8(&img);
            defer gnorp.allocator.free(data);
            flipVertical(data, img.height, img.width * 4);
            return initFromImage(width, height, .bgra8_unorm, data);
        },
        .grayscale1,
        .grayscale2,
        .grayscale4,
        .grayscale8,
        .grayscale16,
        => {
            var data = try toR8(&img);
            defer gnorp.allocator.free(data);
            flipVertical(data, img.height, img.width);
            return initFromImage(width, height, .r8_uint, data);
        },
        .rgba32 => |x| {
            var data = std.mem.sliceAsBytes(x);
            flipVertical(data, img.height, img.width * 4);
            return initFromImage(width, height, .rgba32_uint, data);
        },
        .float32 => |x| {
            var data = std.mem.sliceAsBytes(x);
            flipVertical(data, img.height, img.width * 16);
            return initFromImage(width, height, .rgba32_float, data);
        },
        else => return error.UnsupportedImageFormat,
    }
}

/// initFromImage creates a texture from the given image data.
/// This assumes the pixel data matches the given dimensions and format.
pub fn initFromImage(width: u32, height: u32, format: gpu.Texture.Format, data: []const u8) !*@This() {
    var self = try init(width, height, format, image_usage);
    errdefer self.release();
    try self.write(data);
    return self;
}

/// init creates a new, blank texture of the given properties.
/// If the given dimensions are non-power-of-two, they will be scaled up to
/// the nearest power-of-two.
///
/// Asserts that width and height are > 0.
pub fn init(width: u32, height: u32, format: gpu.Texture.Format, usage: gpu.Texture.UsageFlags) !*@This() {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);

    // const npot = gnorp.hasFeature(.texture_npot);
    const tex_size = [2]f32{
        @intToFloat(f32, try std.math.ceilPowerOfTwo(u32, width)),
        @intToFloat(f32, try std.math.ceilPowerOfTwo(u32, height)),
    };
    const content_size = [2]f32{
        @intToFloat(f32, width),
        @intToFloat(f32, height),
    };
    const descriptor = gpu.Texture.Descriptor.init(.{
        .label = @typeName(@This()) ++ " descriptor",
        .usage = usage,
        .dimension = .dimension_2d,
        .size = .{
            .width = @floatToInt(u32, tex_size[0]),
            .height = @floatToInt(u32, tex_size[1]),
            .depth_or_array_layers = 1,
        },
        .format = format,
        .mip_level_count = 1,
        .sample_count = 1,
    });

    var self = try gnorp.allocator.create(@This());

    self.* = .{};
    self.texture_size = tex_size;
    self.content_size = content_size;
    self.format = format;
    self.gpu_texture = graphics.device.createTexture(&descriptor);

    return self.reference();
}

fn deinit(self: *@This()) void {
    self.gpu_texture.release();
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

/// createView creates a texture view from this texture object.
pub inline fn createView(self: *const @This(), descriptor: *const gpu.TextureView.Descriptor) *gpu.TextureView {
    return self.gpu_texture.createView(descriptor);
}

/// write uploads the given pixel data to the GPU.
/// This assumes the data is in the same format and size as the texture.
pub fn write(self: *@This(), data: []const u8) !void {
    const stride = try bytesPerRow(self.format, @floatToInt(u32, self.texture_size[0]));

    graphics.device.getQueue().writeTexture(
        &.{ .texture = self.gpu_texture },
        &.{
            .bytes_per_row = stride,
            .rows_per_image = @floatToInt(u32, self.texture_size[1]),
        },
        &.{
            .width = @floatToInt(u32, self.content_size[0]),
            .height = @floatToInt(u32, self.content_size[1]),
        },
        data,
    );
}

/// bytesPerRow returns the number of bytes per row occupied by
/// the given texture format and pixel width.
fn bytesPerRow(format: gpu.Texture.Format, width: u32) !u32 {
    // ref: https://docs.rs/wgpu/latest/wgpu/enum.TextureFormat.html

    return switch (format) {
        .r8_unorm,
        .r8_snorm,
        .r8_uint,
        .r8_sint,
        .stencil8,
        => 1 * width,

        .r16_uint,
        .r16_sint,
        .r16_float,
        .rg8_unorm,
        .rg8_snorm,
        .rg8_uint,
        .rg8_sint,
        .depth16_unorm,
        => 2 * width,

        .depth24_plus => 3 * width,

        .r32_float,
        .r32_uint,
        .r32_sint,
        .rg16_uint,
        .rg16_sint,
        .rg16_float,
        .rgba8_unorm,
        .rgba8_unorm_srgb,
        .rgba8_snorm,
        .rgba8_uint,
        .rgba8_sint,
        .bgra8_unorm,
        .bgra8_unorm_srgb,
        .rgb10_a2_unorm,
        .rg11_b10_ufloat,
        .rgb9_e5_ufloat,
        .depth24_plus_stencil8,
        .depth32_float,
        => 4 * width,

        .depth32_float_stencil8 => 5 * width,

        .rg32_float,
        .rg32_uint,
        .rg32_sint,
        .rgba16_uint,
        .rgba16_sint,
        .rgba16_float,
        => 8 * width,

        .rgba32_float,
        .rgba32_uint,
        .rgba32_sint,
        => 16 * width,

        // .bc1_rgba_unorm,
        // .bc1_rgba_unorm_srgb,
        // .bc2_rgba_unorm,
        // .bc2_rgba_unorm_srgb,
        // .bc3_rgba_unorm,
        // .bc3_rgba_unorm_srgb,
        // .bc4_runorm,
        // .bc4_rsnorm,
        // .bc5_rg_unorm,
        // .bc5_rg_snorm,
        // .bc6_hrgb_ufloat,
        // .bc6_hrgb_float,
        // .bc7_rgba_unorm,
        // .bc7_rgba_unorm_srgb,
        // .etc2_rgb8_unorm,
        // .etc2_rgb8_unorm_srgb,
        // .etc2_rgb8_a1_unorm,
        // .etc2_rgb8_a1_unorm_srgb,
        // .etc2_rgba8_unorm,
        // .etc2_rgba8_unorm_srgb,
        // .eacr11_unorm,
        // .eacr11_snorm,
        // .eacrg11_unorm,
        // .eacrg11_snorm,
        // .astc4x4_unorm,
        // .astc4x4_unorm_srgb,
        // .astc5x4_unorm,
        // .astc5x4_unorm_srgb,
        // .astc5x5_unorm,
        // .astc5x5_unorm_srgb,
        // .astc6x5_unorm,
        // .astc6x5_unorm_srgb,
        // .astc6x6_unorm,
        // .astc6x6_unorm_srgb,
        // .astc8x5_unorm,
        // .astc8x5_unorm_srgb,
        // .astc8x6_unorm,
        // .astc8x6_unorm_srgb,
        // .astc8x8_unorm,
        // .astc8x8_unorm_srgb,
        // .astc10x5_unorm,
        // .astc10x5_unorm_srgb,
        // .astc10x6_unorm,
        // .astc10x6_unorm_srgb,
        // .astc10x8_unorm,
        // .astc10x8_unorm_srgb,
        // .astc10x10_unorm,
        // .astc10x10_unorm_srgb,
        // .astc12x10_unorm,
        // .astc12x10_unorm_srgb,
        // .astc12x12_unorm,
        // .astc12x12_unorm_srgb,
        // .r8_bg8_biplanar420_unorm,
        else => error.UnsupportedTextureFormat,
    };
}

/// toR8 converts the given image's pixel data into R8 format.
fn toR8(img: *zimg.Image) anyerror![]u8 {
    return switch (img.pixels) {
        .grayscale1 => |x| convertGray(img, x),
        .grayscale2 => |x| convertGray(img, x),
        .grayscale4 => |x| convertGray(img, x),
        .grayscale8 => |x| convertGray(img, x),
        .grayscale16 => |x| convertGray(img, x),
        else => unreachable,
    };
}

/// toBGRA8 converts the given image's pixel data into BGRA format.
fn toBGRA8(img: *zimg.Image) anyerror![]u8 {
    return switch (img.pixels) {
        .indexed1 => |*x| convertIndexed(img, x),
        .indexed2 => |*x| convertIndexed(img, x),
        .indexed4 => |*x| convertIndexed(img, x),
        .indexed8 => |*x| convertIndexed(img, x),
        .indexed16 => |*x| convertIndexed(img, x),
        .rgb565 => |x| convertBGR(img, x),
        .rgb555 => |x| convertBGR(img, x),
        .rgb24 => |x| convertBGR(img, x),
        .bgr24 => |x| convertBGR(img, x),
        .rgb48 => |x| convertBGR(img, x),
        .rgba64 => |x| convertBGRA(img, x),
        .grayscale8Alpha => |x| convertGrayAlpha(img, x),
        .grayscale16Alpha => |x| convertGrayAlpha(img, x),
        else => unreachable,
    };
}

fn convertGrayAlpha(img: *zimg.Image, x: anytype) ![]u8 {
    var data = try gnorp.allocator.alloc(u8, img.width * img.height * 4);
    var i: usize = 0;

    for (x) |c| {
        const fv = zimg.color.toF32Color(c.value);
        const fa = zimg.color.toF32Color(c.alpha);
        const v = zimg.color.toIntColor(u8, fv);
        data[i + 0] = v;
        data[i + 1] = v;
        data[i + 2] = v;
        data[i + 3] = zimg.color.toIntColor(u8, fa);
        i += 4;
    }

    return data;
}

fn convertGray(img: *zimg.Image, x: anytype) ![]u8 {
    var data = try gnorp.allocator.alloc(u8, img.width * img.height);
    var i: usize = 0;

    while (i < data.len) : (i += 1) {
        const fc = zimg.color.toF32Color(x[i].value);
        data[i] = zimg.color.toIntColor(u8, fc);
    }

    return data;
}

fn convertBGRA(img: *zimg.Image, x: anytype) ![]u8 {
    var data = try gnorp.allocator.alloc(u8, img.width * img.height * 4);
    var i: usize = 0;

    for (x) |c| {
        const fc = c.toColorf32();
        data[i + 0] = zimg.color.toIntColor(u8, fc.b);
        data[i + 1] = zimg.color.toIntColor(u8, fc.g);
        data[i + 2] = zimg.color.toIntColor(u8, fc.r);
        data[i + 3] = zimg.color.toIntColor(u8, fc.a);
        i += 4;
    }

    return data;
}

fn convertBGR(img: *zimg.Image, x: anytype) ![]u8 {
    var data = try gnorp.allocator.alloc(u8, img.width * img.height * 4);
    var i: usize = 0;

    for (x) |c| {
        const fc = c.toColorf32();
        data[i + 0] = zimg.color.toIntColor(u8, fc.b);
        data[i + 1] = zimg.color.toIntColor(u8, fc.g);
        data[i + 2] = zimg.color.toIntColor(u8, fc.r);
        data[i + 3] = 0xff;
        i += 4;
    }

    return data;
}

fn convertIndexed(img: *zimg.Image, x: anytype) ![]u8 {
    var data = try gnorp.allocator.alloc(u32, img.width * img.height);
    var i: usize = 0;

    while (i < data.len) : (i += 1) {
        const c = x.palette[x.indices[i]];
        data[i] = @bitCast(u32, c);
    }

    return std.mem.sliceAsBytes(data);
}

/// flipVertical flips the given image vertically.
fn flipVertical(data: []u8, height: usize, stride: usize) void {
    var row: usize = 0;
    var tmp = gnorp.allocator.alloc(u8, stride) catch unreachable;
    defer gnorp.allocator.free(tmp);

    while (row < height / 2) : (row += 1) {
        const sx = row * stride;
        const dx = (height - row - 1) * stride;
        std.mem.copy(u8, tmp, data[dx .. dx + stride]);
        std.mem.copy(u8, data[dx .. dx + stride], data[sx .. sx + stride]);
        std.mem.copy(u8, data[sx .. sx + stride], tmp);
    }
}
