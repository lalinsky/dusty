const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_tls = b.option(bool, "use_tls", "Build Dusty with TLS support") orelse true;
    const use_bundled_tls = b.option(bool, "use_bundled_tls", "Use Dusty's bundled TLS provider") orelse true;

    const dusty = b.dependency("dusty", .{
        .target = target,
        .optimize = optimize,
        .use_tls = use_tls,
        .use_bundled_tls = use_bundled_tls,
    });

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    // Override dusty's default `zio` stub with the real module so that
    // request/keepalive timeouts use zio.AutoCancel.
    const dusty_mod = dusty.module("dusty");
    dusty_mod.addImport("zio", zio.module("zio"));
    if (use_tls and !use_bundled_tls) {
        if (b.lazyDependency("custom_tls", .{
            .target = target,
            .optimize = optimize,
        })) |custom_tls| {
            dusty_mod.addImport("tls", custom_tls.module("tls"));
        }
    }

    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("dusty", dusty_mod);
    exe.root_module.addImport("zio", zio.module("zio"));

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run.step);
}
