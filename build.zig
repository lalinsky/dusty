const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_tls = b.option(bool, "use_tls", "Build with TLS/HTTPS support via tls.zig") orelse true;

    const mod = b.addModule("dusty", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "use_tls", use_tls);
    mod.addOptions("build_options", build_options);

    // Default `zio` import — a stub that no-ops `clear` and panics on `set`.
    // Apps that want real timeouts override this in their own build.zig:
    //   dusty_mod.addImport("zio", zio_dep.module("zio"));
    mod.addAnonymousImport("zio", .{
        .root_source_file = b.path("src/zio_stub.zig"),
    });

    // TLS support is a lazy dependency: only fetched when `use_tls` is set (the
    // default). When disabled, a stub is imported so the client still builds but
    // HTTPS requests fail with error.TlsNotConfigured.
    if (use_tls) {
        if (b.lazyDependency("tls", .{
            .target = target,
            .optimize = optimize,
        })) |tls_dep| {
            mod.addImport("tls", tls_dep.module("tls"));
        }
    } else {
        mod.addAnonymousImport("tls", .{
            .root_source_file = b.path("src/tls_stub.zig"),
        });
    }

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/llhttp/llhttp.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path("src/llhttp"));
    mod.addImport("llhttp", translate_c.createModule());

    mod.link_libc = true;
    mod.addCSourceFiles(.{
        .files = &[_][]const u8{
            "src/llhttp/llhttp.c",
            "src/llhttp/api.c",
            "src/llhttp/http.c",
        },
        .flags = &.{"-std=c99"},
    });
    mod.addIncludePath(b.path("src/llhttp"));

    // Examples
    const examples_step = b.step("examples", "Build all examples");

    const example_files = [_][]const u8{
        "basic",
        "client",
        "proxy",
        "sse",
        "websocket",
    };

    for (example_files) |name| {
        const example = b.addExecutable(.{
            .name = b.fmt("{s}-example", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
            }),
        });
        example.root_module.addImport("dusty", mod);
        const install = b.addInstallArtifact(example, .{});
        examples_step.dependOn(&install.step);
        // Add to default install step so examples are built with plain `zig build`
        b.getInstallStep().dependOn(&install.step);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
