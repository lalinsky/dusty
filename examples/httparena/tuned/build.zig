const std = @import("std");
const zt = @import("zt");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const dusty_dep = b.dependency("dusty", .{
        .target = target,
        .optimize = optimize,
        .tls = .ztls,
        .compression = true,
    });
    const dusty_mod = dusty_dep.module("dusty");

    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const zio_mod = zio_dep.module("zio");

    dusty_mod.addImport("zio", zio_mod);

    const json_dep = b.dependency("json", .{
        .target = target,
        .optimize = optimize,
    });

    const pg_dep = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    });

    const zt_dep = b.dependency("zt", .{
        .target = target,
        .optimize = optimize,
    });
    const templates = zt.addTemplates(b, zt_dep, &.{
        b.path("src/templates/fortunes.zt"),
    });

    const exe = b.addExecutable(.{
        .name = "dusty-arena",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
        }),
    });
    exe.root_module.addImport("dusty", dusty_mod);
    exe.root_module.addImport("zio", zio_mod);
    exe.root_module.addImport("json", json_dep.module("json"));
    exe.root_module.addImport("pg", pg_dep.module("pg"));
    exe.root_module.addImport("zt", zt_dep.module("zt"));
    exe.step.dependOn(templates);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the server");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);
}
