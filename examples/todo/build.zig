const std = @import("std");
const zt = @import("zt");

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
    const json = b.dependency("json", .{
        .target = target,
        .optimize = optimize,
    });
    const pg = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    });
    const zt_dep = b.dependency("zt", .{
        .target = target,
        .optimize = optimize,
    });

    // Override dusty's default `zio` stub with the real module so that
    // request/keepalive timeouts use zio.AutoCancel.
    const dusty_mod = dusty.module("dusty");
    dusty_mod.addImport("zio", zio.module("zio"));

    const templates = zt.addTemplates(b, zt_dep, &.{
        b.path("src/templates/todo.zt"),
    });

    const exe = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("dusty", dusty_mod);
    exe.root_module.addImport("zio", zio.module("zio"));
    exe.root_module.addImport("json", json.module("json"));
    exe.root_module.addImport("pg", pg.module("pg"));
    exe.root_module.addImport("zt", zt_dep.module("zt"));
    exe.step.dependOn(templates);

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run.step);
}
