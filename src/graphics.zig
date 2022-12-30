const std = @import("std");
const glfw = @import("glfw");
const gpu = @import("gpu");
const gnorp = @import("main.zig");
const math = gnorp.math;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(objc);
}

/// Texture represents an image in GPU memory.
/// It can be loaded from a file or created manually.
pub const Texture = @import("texture.zig");

/// Spritesheet represents a texture and animation metadata used by a Sprite or
/// Spritebatch.
pub const Spritesheet = @import("spritesheet.zig");

/// Sprite represents a stand-alone, textured sprite.
///
/// If you wish to draw multiple sprites from the same spritesheet, it is more
/// efficient to use a Spritebatch.
pub const Sprite = @import("sprite.zig");

/// Spritebatch represents a collection of zero or more textured quads. This is
/// more efficient than creating individual Sprite objects, provided all the
/// sprites needed share the same spritesheet.
pub const Spritebatch = @import("spritebatch.zig");

/// Tilemap represents a 2D grid of (animated) tiles.
pub const Tilemap = @import("tilemap.zig");

/// UniformBuffer represents a uniform buffer object.
pub const UniformBuffer = @import("buffers.zig").Uniform;

// NOTE: This struct should be kept in sync with shared_uniforms.wgsl
const SharedUniforms = extern struct {
    mat_projection: gnorp.math.Mat,
};

/// SharedUniformBuffer represents the uniform buffer object
/// shared by all shaders that need its contents.
const SharedUniformBuffer = gnorp.graphics.UniformBuffer(SharedUniforms);

pub var device: *gpu.Device = undefined;
pub var window: glfw.Window = undefined;

var surface: *gpu.Surface = undefined;
var instance: *gpu.Instance = undefined;
var adapter: *gpu.Adapter = undefined;
var current_desc: gpu.SwapChain.Descriptor = undefined;
var target_desc: gpu.SwapChain.Descriptor = undefined;
var framebuffer_size: glfw.Window.Size = undefined;
var backend_type: gpu.BackendType = undefined;
var swap_chain: ?*gpu.SwapChain = null;
var back_buffer_view: ?*gpu.TextureView = null;
var shared_uniforms: *SharedUniformBuffer = undefined;
var clear_color: gpu.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

pub fn init() !void {
    if (!@import("builtin").is_test)
        gpu.Impl.init();

    backend_type = try detectBackendType();

    try initWindow();
    errdefer window.destroy();

    try initDevice();
    errdefer {
        device.release();
        adapter.release();
        surface.release();
        instance.release();
    }

    try initSwapchainDesc();

    shared_uniforms = try SharedUniformBuffer.init();
}

pub fn deinit() void {
    if (back_buffer_view) |bb|
        bb.release();

    if (swap_chain) |sc|
        sc.release();

    shared_uniforms.release();
    device.release();
    adapter.release();
    surface.release();
    instance.release();

    window.setUserPointer(null);
    window.destroy();
    glfw.terminate();
}

/// getSharedBindGroupLayoutEntry returns a bindgroup layout entry for the global/shared
/// uniform buffer and the given binding index.
pub inline fn getSharedBindGroupLayoutEntry(binding: u32) gpu.BindGroupLayout.Entry {
    return shared_uniforms.getBindGroupLayoutEntry(binding);
}

/// getSharedBindGroupEntry returns a bindgroup entry for the global/shared
/// uniform buffer and the given binding index.
pub inline fn getSharedBindGroupEntry(binding: u32) gpu.BindGroup.Entry {
    return shared_uniforms.getBindGroupEntry(binding);
}

/// getColorAttachment returns a renderpass color attachment with the current
/// backbuffer and clear color. As well as then given LoadOp.
pub fn getColorAttachment(load_op: gpu.LoadOp) gpu.RenderPassColorAttachment {
    return .{
        .view = back_buffer_view.?,
        .clear_value = clear_color,
        .load_op = load_op,
        .store_op = .store,
    };
}

/// getSwapchainFormat returns the application's swapchain texture format.
pub inline fn getSwapchainFormat() gpu.Texture.Format {
    return .bgra8_unorm;
}

/// getFramebufferSize retrieves the size of the framebuffer of the specified window.
/// This function retrieves the size, in pixels, of the framebuffer of the curent window.
pub inline fn getFramebufferSize() ![2]f32 {
    const fs = try window.getFramebufferSize();
    return .{
        @intToFloat(f32, fs.width),
        @intToFloat(f32, fs.height),
    };
}

/// beginFrame selects the target backbuffer and ensures the swapchain is valid.
/// This should be called every frame before drawing of other components begins.
/// Drawing should conclude with a call to endFrame().
///
/// This function is used by the library internally and should not be called
/// directly by the host application.
pub fn beginFrame() !void {
    // Update uniforms if the framebuffer has been resized.
    const size = try window.getSize();
    if (size.width != framebuffer_size.width or size.height != framebuffer_size.height) {
        framebuffer_size = size;
        const fw = @intToFloat(f32, size.width);
        const fh = @intToFloat(f32, size.height);
        const mat = math.orthographicOffCenterLh(0, fw, 0, fh, 0, 1);
        shared_uniforms.set(&.{
            .mat_projection = math.transpose(mat),
        });
    }

    // (Re-)create the swapchain if needed.
    if ((swap_chain == null) or !std.meta.eql(current_desc, target_desc)) {
        if (swap_chain) |sc|
            sc.release();
        swap_chain = device.createSwapChain(surface, &target_desc);
        current_desc = target_desc;
    }

    back_buffer_view = swap_chain.?.getCurrentTextureView();
}

/// endFrame finishes drawing a scene and calls present on the current swapchain.
///
/// This function is used by the library internally and should not be called
/// directly by the host application.
pub fn endFrame() !void {
    swap_chain.?.present();
    back_buffer_view.?.release();
    back_buffer_view = null;

    // Vulkan has weird issues on linux when there is no frame limiter in place.
    // ref: https://github.com/hexops/mach/issues/444
    if (@import("builtin").target.os.tag == .linux) {
        if (backend_type == .vulkan)
            std.time.sleep(std.time.ns_per_s / 60);
    }
}

/// initSwapchainDesc creates swapchain descriptors.
fn initSwapchainDesc() !void {
    const fb_size = try window.getFramebufferSize();
    const descriptor = gpu.SwapChain.Descriptor{
        .label = @typeName(@This()) ++ " swap chain",
        .usage = .{ .render_attachment = true },
        .format = getSwapchainFormat(),
        .width = fb_size.width,
        .height = fb_size.height,
        .present_mode = switch (gnorp.config.vsync) {
            .no_buffer => .immediate,
            .double_buffer => .fifo,
            .triple_buffer => .mailbox,
        },
    };

    current_desc = descriptor;
    target_desc = descriptor;
}

/// initDevice creates a GPU instance and device.
fn initDevice() !void {
    instance = gpu.createInstance(null) orelse
        return error.GPUInstanceCreationFailed;

    errdefer instance.release();

    surface = try createSurfaceForWindow();
    errdefer surface.release();

    var response: ?RequestAdapterResponse = null;
    instance.requestAdapter(&gpu.RequestAdapterOptions{
        .compatible_surface = surface,
        .power_preference = gnorp.config.device_requirements.power_preference,
        .force_fallback_adapter = false,
    }, &response, requestAdapterCallback);

    if (response == null)
        return error.GPUAdapterCreationFailed;

    if (response.?.status != .success) {
        gnorp.log.debug(@src(), "failed to find a suitable GPU adapter: {s}", .{response.?.message.?});
        return error.GPUAdapterCreationFailed;
    }

    // Print which adapter we are using.
    var props: gpu.Adapter.Properties = undefined;
    response.?.adapter.getProperties(&props);
    gnorp.log.debug(@src(), "using {s} backend on {s} adapter: {s}, {s}", .{
        props.backend_type.name(),
        props.adapter_type.name(),
        props.name,
        props.driver_description,
    });

    adapter = response.?.adapter;

    var limits: ?*gpu.RequiredLimits = null;
    if (gnorp.config.device_requirements.limits) |want_lim|
        limits = &gpu.RequiredLimits{ .limits = want_lim };

    device = adapter.createDevice(&gpu.Device.Descriptor.init(.{
        .label = @typeName(@This()) ++ " device descriptor",
        .required_features = gnorp.config.device_requirements.features,
        .required_limits = limits,
        .default_queue = .{},
    })) orelse return error.GPUDeviceCreationFailed;

    // Print supported limits to debug log.
    var have_lim = gpu.SupportedLimits{ .limits = undefined };
    if (device.getLimits(&have_lim)) {
        gnorp.log.debug(@src(), "device limits:", .{});
        gnorp.log.debug(@src(), "  max_texture_dimension_1d:                        {}", .{have_lim.limits.max_texture_dimension_1d});
        gnorp.log.debug(@src(), "  max_texture_dimension_2d:                        {}", .{have_lim.limits.max_texture_dimension_2d});
        gnorp.log.debug(@src(), "  max_texture_dimension_3d:                        {}", .{have_lim.limits.max_texture_dimension_3d});
        gnorp.log.debug(@src(), "  max_texture_array_layers:                        {}", .{have_lim.limits.max_texture_array_layers});
        gnorp.log.debug(@src(), "  max_bind_groups:                                 {}", .{have_lim.limits.max_bind_groups});
        gnorp.log.debug(@src(), "  max_dynamic_uniform_buffers_per_pipeline_layout: {}", .{have_lim.limits.max_dynamic_uniform_buffers_per_pipeline_layout});
        gnorp.log.debug(@src(), "  max_dynamic_storage_buffers_per_pipeline_layout: {}", .{have_lim.limits.max_dynamic_storage_buffers_per_pipeline_layout});
        gnorp.log.debug(@src(), "  max_sampled_textures_per_shader_stage:           {}", .{have_lim.limits.max_sampled_textures_per_shader_stage});
        gnorp.log.debug(@src(), "  max_samplers_per_shader_stage:                   {}", .{have_lim.limits.max_samplers_per_shader_stage});
        gnorp.log.debug(@src(), "  max_storage_buffers_per_shader_stage:            {}", .{have_lim.limits.max_storage_buffers_per_shader_stage});
        gnorp.log.debug(@src(), "  max_storage_textures_per_shader_stage:           {}", .{have_lim.limits.max_storage_textures_per_shader_stage});
        gnorp.log.debug(@src(), "  max_uniform_buffers_per_shader_stage:            {}", .{have_lim.limits.max_uniform_buffers_per_shader_stage});
        gnorp.log.debug(@src(), "  max_uniform_buffer_binding_size:                 {}", .{have_lim.limits.max_uniform_buffer_binding_size});
        gnorp.log.debug(@src(), "  max_storage_buffer_binding_size:                 {}", .{have_lim.limits.max_storage_buffer_binding_size});
        gnorp.log.debug(@src(), "  min_uniform_buffer_offset_alignment:             {}", .{have_lim.limits.min_uniform_buffer_offset_alignment});
        gnorp.log.debug(@src(), "  min_storage_buffer_offset_alignment:             {}", .{have_lim.limits.min_storage_buffer_offset_alignment});
        gnorp.log.debug(@src(), "  max_vertex_buffers:                              {}", .{have_lim.limits.max_vertex_buffers});
        gnorp.log.debug(@src(), "  max_vertex_attributes:                           {}", .{have_lim.limits.max_vertex_attributes});
        gnorp.log.debug(@src(), "  max_vertex_buffer_array_stride:                  {}", .{have_lim.limits.max_vertex_buffer_array_stride});
        gnorp.log.debug(@src(), "  max_inter_stage_shader_components:               {}", .{have_lim.limits.max_inter_stage_shader_components});
        gnorp.log.debug(@src(), "  max_inter_stage_shader_variables:                {}", .{have_lim.limits.max_inter_stage_shader_variables});
        gnorp.log.debug(@src(), "  max_color_attachments:                           {}", .{have_lim.limits.max_color_attachments});
        gnorp.log.debug(@src(), "  max_compute_workgroup_storage_size:              {}", .{have_lim.limits.max_compute_workgroup_storage_size});
        gnorp.log.debug(@src(), "  max_compute_invocations_per_workgroup:           {}", .{have_lim.limits.max_compute_invocations_per_workgroup});
        gnorp.log.debug(@src(), "  max_compute_workgroup_size_x:                    {}", .{have_lim.limits.max_compute_workgroup_size_x});
        gnorp.log.debug(@src(), "  max_compute_workgroup_size_y:                    {}", .{have_lim.limits.max_compute_workgroup_size_y});
        gnorp.log.debug(@src(), "  max_compute_workgroup_size_z:                    {}", .{have_lim.limits.max_compute_workgroup_size_z});
        gnorp.log.debug(@src(), "  max_compute_workgroups_per_dimension:            {}", .{have_lim.limits.max_compute_workgroups_per_dimension});
    } else {
        gnorp.log.err("unable to query device limits", .{});
    }

    device.setUncapturedErrorCallback({}, printUnhandledErrorCallback);
}

/// initWindow initializes the GLFW window.
fn initWindow() !void {
    try glfw.init(.{});
    errdefer glfw.terminate();

    const monitor = glfw.Monitor.getPrimary() orelse
        return error.PrimaryMonitorNotFound;

    var hints = glfwWindowHintsForBackend(backend_type);
    hints.cocoa_retina_framebuffer = true;

    window = try glfw.Window.create(
        gnorp.config.width,
        gnorp.config.height,
        gnorp.config.title,
        if (gnorp.config.fullscreen) monitor else null,
        null,
        hints,
    );
    errdefer window.destroy();

    try window.setSizeLimits(
        .{ .width = 100, .height = 100 },
        .{ .width = null, .height = null },
    );

    // Center window on monitor if we're in windowed mode.
    if (!gnorp.config.fullscreen) {
        // Get the width and height of the entire window. Not just the framebuffer.
        const fb_size = try window.getFramebufferSize();
        const frame_size = try window.getFrameSize();
        const width = fb_size.width + frame_size.right + frame_size.left;
        const height = fb_size.height + frame_size.bottom + frame_size.top;
        const mode = try monitor.getVideoMode();
        try window.setPos(.{
            .x = @intCast(i64, mode.getWidth() / 2) - @intCast(i64, width / 2),
            .y = @intCast(i64, mode.getHeight() / 2) - @intCast(i64, height / 2),
        });
    }

    switch (backend_type) {
        .opengl, .opengles => try glfw.makeContextCurrent(window),
        else => {},
    }

    // Reconfigure the swap chain with the new framebuffer width/height,
    // otherwise e.g. the Vulkan device would be lost after a resize.
    window.setFramebufferSizeCallback((struct {
        fn callback(_: glfw.Window, width: u32, height: u32) void {
            gnorp.log.debug(null, "window resized to: {} x {}", .{ width, height });
            target_desc.width = width;
            target_desc.height = height;
        }
    }).callback);
}

fn detectBackendType() !gpu.BackendType {
    if (try getEnvVarOwned("MACH_GPU_BACKEND")) |backend| {
        defer gnorp.allocator.free(backend);

        if (std.ascii.eqlIgnoreCase(backend, "null")) return .nul;
        if (std.ascii.eqlIgnoreCase(backend, "webgpu")) return .nul;
        if (std.ascii.eqlIgnoreCase(backend, "d3d11")) return .d3d11;
        if (std.ascii.eqlIgnoreCase(backend, "d3d12")) return .d3d12;
        if (std.ascii.eqlIgnoreCase(backend, "metal")) return .metal;
        if (std.ascii.eqlIgnoreCase(backend, "vulkan")) return .vulkan;
        if (std.ascii.eqlIgnoreCase(backend, "opengl")) return .opengl;
        if (std.ascii.eqlIgnoreCase(backend, "opengles")) return .opengles;

        gnorp.log.err("unknown GPU Backend {s}", .{backend});
        return error.UnknownGPUBackend;
    }

    const target = @import("builtin").target;
    if (target.isDarwin()) return .metal;
    if (target.os.tag == .windows) return .d3d12;
    return .vulkan;
}

fn getEnvVarOwned(key: []const u8) error{ OutOfMemory, InvalidUtf8 }!?[]u8 {
    return std.process.getEnvVarOwned(gnorp.allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => @as(?[]u8, null),
        else => |e| e,
    };
}

inline fn printUnhandledErrorCallback(_: void, typ: gpu.ErrorType, message: [*:0]const u8) void {
    switch (typ) {
        .validation => gnorp.log.debug(null, "gpu: validation error: {s}", .{message}),
        .out_of_memory => gnorp.log.debug(null, "gpu: out of memory: {s}", .{message}),
        .device_lost => gnorp.log.debug(null, "gpu: device lost: {s}", .{message}),
        .unknown => gnorp.log.debug(null, "gpu: unknown error: {s}", .{message}),
        else => unreachable,
    }
    std.process.exit(1);
}

fn glfwWindowHintsForBackend(backend: gpu.BackendType) glfw.Window.Hints {
    return switch (backend) {
        .opengl => .{
            // Ask for OpenGL 4.4 which is what the GL backend requires
            // for compute shaders and texture views.
            .context_version_major = 4,
            .context_version_minor = 4,
            .opengl_forward_compat = true,
            .opengl_profile = .opengl_core_profile,
        },
        .opengles => .{
            .context_version_major = 3,
            .context_version_minor = 1,
            .client_api = .opengl_es_api,
            .context_creation_api = .egl_context_api,
        },
        else => .{
            // Without this GLFW will initialize a GL context on the window,
            // which prevents using the window with other APIs.
            .client_api = .no_api,
        },
    };
}

fn detectGLFWOptions() glfw.BackendOptions {
    const target = @import("builtin").target;
    if (target.isDarwin()) return .{ .cocoa = true };
    return switch (target.os.tag) {
        .windows => .{ .win32 = true },
        .linux => .{ .x11 = true },
        else => .{},
    };
}

fn createSurfaceForWindow() !*gpu.Surface {
    const glfw_options = comptime detectGLFWOptions();
    const glfw_native = glfw.Native(glfw_options);
    const extension = if (glfw_options.win32) gpu.Surface.Descriptor.NextInChain{
        .from_windows_hwnd = &.{
            .hinstance = std.os.windows.kernel32.GetModuleHandleW(null).?,
            .hwnd = glfw_native.getWin32Window(window),
        },
    } else if (glfw_options.x11) gpu.Surface.Descriptor.NextInChain{
        .from_xlib_window = &.{
            .display = glfw_native.getX11Display(),
            .window = glfw_native.getX11Window(window),
        },
    } else if (glfw_options.cocoa) blk: {
        const ns_window = glfw_native.getCocoaWindow(window);
        const ns_view = objc.msgSend(ns_window, "contentView", .{}, *anyopaque); // [nsWindow contentView]

        // Create a CAMetalLayer that covers the whole window that will be passed to CreateSurface.
        objc.msgSend(ns_view, "setWantsLayer:", .{true}, void); // [view setWantsLayer:YES]
        const layer = objc.msgSend(objc.objc_getClass("CAMetalLayer"), "layer", .{}, ?*anyopaque); // [CAMetalLayer layer]
        if (layer == null) return error.MetalLayerCreationFailed;
        objc.msgSend(ns_view, "setLayer:", .{layer.?}, void); // [view setLayer:layer]

        // Use retina if the window was created with retina support.
        const scale_factor = objc.msgSend(ns_window, "backingScaleFactor", .{}, f64); // [ns_window backingScaleFactor]
        objc.msgSend(layer.?, "setContentsScale:", .{scale_factor}, void); // [layer setContentsScale:scale_factor]

        break :blk gpu.Surface.Descriptor.NextInChain{ .from_metal_layer = &.{ .layer = layer.? } };
    } else if (glfw_options.wayland) {
        return error.WaylandNotSupported;
    } else unreachable;

    return instance.createSurface(&gpu.Surface.Descriptor{
        .next_in_chain = extension,
    });
}

const RequestAdapterResponse = struct {
    status: gpu.RequestAdapterStatus,
    adapter: *gpu.Adapter,
    message: ?[*:0]const u8,
};

inline fn requestAdapterCallback(
    context: *?RequestAdapterResponse,
    status: gpu.RequestAdapterStatus,
    gpu_adapter: *gpu.Adapter,
    message: ?[*:0]const u8,
) void {
    context.* = RequestAdapterResponse{
        .status = status,
        .adapter = gpu_adapter,
        .message = message,
    };
}

// Copied from libs/mach-gpu/examples/
const objc = struct {
    // Extracted from `zig translate-c tmp.c` with `#include <objc/message.h>` in the file.
    pub const struct_objc_selector = opaque {};
    pub const SEL = ?*struct_objc_selector;
    pub const Class = ?*struct_objc_class;
    pub const struct_objc_class = opaque {};

    pub extern fn sel_getUid(str: [*c]const u8) SEL;
    pub extern fn objc_getClass(name: [*c]const u8) Class;
    pub extern fn objc_msgSend() void;

    // Borrowed from https://github.com/hazeycode/zig-objcrt
    pub fn msgSend(obj: anytype, sel_name: [:0]const u8, args: anytype, comptime ReturnType: type) ReturnType {
        const args_meta = @typeInfo(@TypeOf(args)).Struct.fields;

        const FnType = switch (args_meta.len) {
            0 => *const fn (@TypeOf(obj), SEL) callconv(.C) ReturnType,
            1 => *const fn (@TypeOf(obj), SEL, args_meta[0].field_type) callconv(.C) ReturnType,
            2 => *const fn (@TypeOf(obj), SEL, args_meta[0].field_type, args_meta[1].field_type) callconv(.C) ReturnType,
            3 => *const fn (@TypeOf(obj), SEL, args_meta[0].field_type, args_meta[1].field_type, args_meta[2].field_type) callconv(.C) ReturnType,
            4 => *const fn (@TypeOf(obj), SEL, args_meta[0].field_type, args_meta[1].field_type, args_meta[2].field_type, args_meta[3].field_type) callconv(.C) ReturnType,
            else => @compileError("Unsupported number of args"),
        };

        // NOTE: func is a var because making it const causes a compile error which I believe is a compiler bug
        var func = @ptrCast(FnType, &objc_msgSend);
        const sel = sel_getUid(@ptrCast([*c]const u8, sel_name));

        return @call(.{}, func, .{ obj, sel } ++ args);
    }
};
