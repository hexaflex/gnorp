const std = @import("std");
const Builder = std.build.Builder;
const glfw = @import("libs/mach-glfw/build.zig");
const system_sdk = @import("libs/mach-glfw/system_sdk.zig");
const GpuSdk = @import("libs/mach-gpu/sdk.zig").Sdk;
const GpuDawnSdk = @import("libs/mach-gpu-dawn/sdk.zig").Sdk;
const zmath = @import("libs/zmath/build.zig");
const this_dir = thisDir();

pub fn build(b: *Builder) !void {
    const build_mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const obj = b.addExecutable("gnorp", this_dir ++ "/src/main.zig");
    obj.setBuildMode(build_mode);
    obj.setTarget(target);
    obj.install();
    try link(b, obj);

    const exe_options = b.addOptions();
    exe_options.addOption([]const u8, "build_prefix", if (build_mode == .Debug) (this_dir ++ "/src/") else "");
    exe_options.addOption([]const u8, "content_dir", this_dir ++ "/zig-out/bin/assets");
    exe_options.addOption([:0]const u8, "title", "gnorp");
    exe_options.addOption([:0]const u8, "version", "v0.0.1");

    const tests = b.addTest(this_dir ++ "/src/main.zig");
    tests.setBuildMode(build_mode);
    tests.setTarget(target);
    tests.addOptions("build_options", exe_options);
    try link(b, tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}

pub fn link(b: *std.build.Builder, obj: *std.build.LibExeObjStep) !void {
    const gpu = GpuSdk(.{
        .glfw = glfw,
        .gpu_dawn = GpuDawnSdk(.{
            .glfw = glfw,
            .glfw_include_dir = this_dir ++ "/libs/mach-glfw/upstream/glfw/include",
            .system_sdk = system_sdk,
        }),
    });

    try glfw.link(b, obj, .{});
    try gpu.link(b, obj, .{});

    for (pkg.dependencies.?) |p|
        obj.addPackage(p);
}

pub const pkg = blk: {
    const gpu_dawn = GpuDawnSdk(.{
        .glfw = glfw,
        .glfw_include_dir = this_dir ++ "/libs/mach-glfw/upstream/glfw/include",
        .system_sdk = system_sdk,
    });

    const gpu = GpuSdk(.{
        .glfw = glfw,
        .gpu_dawn = gpu_dawn,
    });

    break :blk std.build.Pkg{
        .name = "gnorp",
        .source = .{ .path = this_dir ++ "/src/main.zig" },
        .dependencies = &.{ gpu.pkg, glfw.pkg, zmath.pkg, .{
            .name = "zigimg",
            .source = .{ .path = this_dir ++ "/libs/zigimg/zigimg.zig" },
        } },
    };
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}
