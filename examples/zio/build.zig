const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dusty = b.dependency("dusty", .{
        .target = target,
        .optimize = optimize,
    });

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("dusty", dusty.module("dusty"));
    exe.root_module.addImport("zio", zio.module("zio"));

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run.step);
}
