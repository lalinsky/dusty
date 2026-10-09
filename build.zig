const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_tls = b.option(bool, "use_tls", "Build with TLS/HTTPS support via tls.zig") orelse true;
    const use_bundled_tls = b.option(
        bool,
        "use_bundled_tls",
        "Use Dusty's pinned tls.zig dependency; disable to inject a compatible 'tls' module",
    ) orelse true;
    // HTTP/2 support is gated behind this option (like use_tls) because it links
    // the nghttp2 C library. Defaults off until the implementation lands. Requires
    // use_tls, since h2 is negotiated via TLS ALPN.
    const use_http2 = b.option(bool, "use_http2", "Build with HTTP/2 support via nghttp2") orelse false;
    const use_zlib = b.option(bool, "use_zlib", "Build with gzip/deflate support via zlib.zig") orelse true;

    const mod = b.addModule("dusty", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "use_tls", use_tls);
    build_options.addOption(bool, "use_http2", use_http2);
    build_options.addOption(bool, "use_zlib", use_zlib);
    mod.addOptions("build_options", build_options);

    // Default `zio` import — a marker stub that selects the portable std.Io
    // timeout watchdog. Apps using the zio runtime override it so timeouts use
    // zio.AutoCancel instead:
    //   dusty_mod.addImport("zio", zio_dep.module("zio"));
    mod.addAnonymousImport("zio", .{
        .root_source_file = b.path("src/zio_stub.zig"),
    });

    // TLS support is a lazy dependency: only fetched when both TLS and the
    // bundled provider are enabled (the defaults). Applications can keep TLS
    // active while injecting a compatible module with:
    //   dusty_mod.addImport("tls", custom_tls_mod);
    if (!use_tls) {
        mod.addAnonymousImport("tls", .{
            .root_source_file = b.path("src/tls_stub.zig"),
        });
    } else if (use_bundled_tls) {
        if (b.lazyDependency("tls", .{
            .target = target,
            .optimize = optimize,
        })) |tls_dep| {
            mod.addImport("tls", tls_dep.module("tls"));
        }
    } else {
        mod.addAnonymousImport("tls", .{
            .root_source_file = b.path("src/tls_injection_required.zig"),
        });
    }

    // Content decoding (gzip, deflate) of request and response bodies is a
    // lazy dependency, like TLS: only fetched when `use_zlib` is set (the
    // default). When disabled, a stub is imported so everything still builds,
    // and a coded body is refused with error.UnsupportedContentEncoding.
    if (use_zlib) {
        if (b.lazyDependency("zlib", .{
            .target = target,
            .optimize = optimize,
        })) |zlib_dep| {
            mod.addImport("zlib", zlib_dep.module("zlib"));
        }
    } else {
        mod.addAnonymousImport("zlib", .{
            .root_source_file = b.path("src/zlib_stub.zig"),
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

    // HTTP/2 via vendored nghttp2 (src/nghttp2), gated behind use_http2. The
    // library is I/O-free (a pure protocol state machine), driven from Zig.
    if (use_http2) {
        const nghttp2_translate_c = b.addTranslateC(.{
            .root_source_file = b.path("src/nghttp2/lib/includes/nghttp2/nghttp2.h"),
            .target = target,
            .optimize = optimize,
        });
        nghttp2_translate_c.addIncludePath(b.path("src/nghttp2/lib/includes"));
        mod.addImport("nghttp2", nghttp2_translate_c.createModule());

        // nghttp2 needs platform feature macros so the right headers/APIs are
        // visible under -std=c99: a feature-test macro to un-hide POSIX/C99
        // declarations (e.g. clock_gettime, vsnprintf) plus HAVE_* to select
        // nghttp2's code paths. Windows uses nghttp2's own Win32 fallbacks
        // (its inline htonl, windows.h time). Applying the POSIX set
        // unconditionally breaks non-Unix builds (e.g. arpa/inet.h not found),
        // and a too-strict _POSIX_C_SOURCE hides vsnprintf on Darwin.
        const c99 = "-std=c99";
        const staticlib = "-DNGHTTP2_STATICLIB";
        const have_posix = [_][]const u8{
            "-DHAVE_ARPA_INET_H=1",
            "-DHAVE_NETINET_IN_H=1",
            "-DHAVE_CLOCK_GETTIME=1",
            "-DHAVE_DECL_CLOCK_MONOTONIC=1",
        };
        const nghttp2_flags: []const []const u8 = switch (target.result.os.tag) {
            .windows => &.{ c99, staticlib, "-DWIN32", "-DHAVE_WINDOWS_H=1", "-DHAVE_GETTICKCOUNT64=1" },
            .macos, .ios, .tvos, .watchos => &([_][]const u8{ c99, staticlib, "-D_DARWIN_C_SOURCE" } ++ have_posix),
            else => &([_][]const u8{ c99, staticlib, "-D_GNU_SOURCE" } ++ have_posix),
        };

        mod.addCSourceFiles(.{
            .files = &[_][]const u8{
                "src/nghttp2/lib/nghttp2_alpn.c",
                "src/nghttp2/lib/nghttp2_buf.c",
                "src/nghttp2/lib/nghttp2_callbacks.c",
                "src/nghttp2/lib/nghttp2_debug.c",
                "src/nghttp2/lib/nghttp2_extpri.c",
                "src/nghttp2/lib/nghttp2_frame.c",
                "src/nghttp2/lib/nghttp2_hd.c",
                "src/nghttp2/lib/nghttp2_hd_huffman.c",
                "src/nghttp2/lib/nghttp2_hd_huffman_data.c",
                "src/nghttp2/lib/nghttp2_helper.c",
                "src/nghttp2/lib/nghttp2_http.c",
                "src/nghttp2/lib/nghttp2_map.c",
                "src/nghttp2/lib/nghttp2_mem.c",
                "src/nghttp2/lib/nghttp2_option.c",
                "src/nghttp2/lib/nghttp2_outbound_item.c",
                "src/nghttp2/lib/nghttp2_pq.c",
                "src/nghttp2/lib/nghttp2_priority_spec.c",
                "src/nghttp2/lib/nghttp2_queue.c",
                "src/nghttp2/lib/nghttp2_ratelim.c",
                "src/nghttp2/lib/nghttp2_rcbuf.c",
                "src/nghttp2/lib/nghttp2_session.c",
                "src/nghttp2/lib/nghttp2_stream.c",
                "src/nghttp2/lib/nghttp2_submit.c",
                "src/nghttp2/lib/nghttp2_time.c",
                "src/nghttp2/lib/nghttp2_version.c",
                "src/nghttp2/lib/sfparse.c",
            },
            .flags = nghttp2_flags,
        });
        mod.addIncludePath(b.path("src/nghttp2/lib"));
        mod.addIncludePath(b.path("src/nghttp2/lib/includes"));
    }

    // Hashes the files of an asset bundle for `addAssets`; run on the host
    // whatever the target.
    const assets_gen = b.addExecutable(.{
        .name = "dusty-assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/assets/gen.zig"),
            .target = b.graph.host,
        }),
    });
    b.installArtifact(assets_gen);

    // Examples
    const examples_step = b.step("examples", "Build all examples");

    const example_files = [_][]const u8{
        "basic",
        "client",
        "proxy",
        "sse",
        "tls_server",
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

    const assets_gen_tests = b.addTest(.{
        .root_module = assets_gen.root_module,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    test_step.dependOn(&b.addRunArtifact(assets_gen_tests).step);

    const assets_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/assets/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    assets_tests.root_module.addImport("dusty", mod);
    assets_tests.root_module.addImport("assets", bundle(b, assets_gen, b.path("src/assets/root.zig"), .{
        .dir = b.path("src/assets/testdata"),
    }));
    test_step.dependOn(&b.addRunArtifact(assets_tests).step);

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

pub const AssetsOptions = struct {
    /// Every file under it is bundled, except dotfiles. A compressed copy
    /// next to a file, `app.css.br` for `app.css`, is served in its place
    /// to clients that accept it. The directory is listed when the build is
    /// configured, so it has to be in the source tree, and `--watch` sees
    /// changes to the files but not files added or removed.
    dir: std.Build.LazyPath,
    /// Where the files are served.
    prefix: []const u8 = "/assets",
};

/// Bundles a directory of assets into a module, to import into the app:
///
/// ```zig
/// const dusty = @import("dusty");
/// const assets = dusty.addAssets(b, dusty_dep, .{ .dir = b.path("assets") });
/// exe.root_module.addImport("assets", assets);
/// ```
///
/// The module embeds the files. Its `url("app.css")` gives the URL to link
/// to, with a hash of the content in it, and `register(router)` serves them
/// all.
pub fn addAssets(b: *std.Build, dusty_dep: *std.Build.Dependency, opts: AssetsOptions) *std.Build.Module {
    return bundle(b, dusty_dep.artifact("dusty-assets"), dusty_dep.path("src/assets/root.zig"), opts);
}

fn bundle(b: *std.Build, gen: *std.Build.Step.Compile, root: std.Build.LazyPath, opts: AssetsOptions) *std.Build.Module {
    const io = b.graph.io;

    // Copied first, so the tool can be given one directory, whose path
    // changes with its contents, rather than every file on its command line.
    const files = b.addWriteFiles();
    var dir = std.Io.Dir.cwd().openDir(io, opts.dir.getPath(b), .{ .iterate = true }) catch |err| {
        std.debug.panic("unable to open asset directory '{s}': {t}", .{ opts.dir.getPath(b), err });
    };
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err| std.debug.panic("unable to list asset directory: {t}", .{err})) |entry| {
        if (entry.basename[0] == '.') {
            if (entry.kind == .directory) walker.leave(io);
            continue;
        }
        const kind = switch (entry.kind) {
            .sym_link => (entry.dir.statFile(io, entry.basename, .{}) catch continue).kind,
            else => entry.kind,
        };
        if (kind != .file) continue;
        const name = b.dupe(entry.path);
        std.mem.replaceScalar(u8, name, std.fs.path.sep, '/');
        _ = files.addCopyFile(opts.dir.path(b, name), name);
    }

    const run = b.addRunArtifact(gen);
    const table = run.addOutputFileArg("files.zig");
    run.addArg(opts.prefix);
    run.addDirectoryArg(files.getDirectory());

    const module = b.addWriteFiles();
    _ = module.addCopyDirectory(files.getDirectory(), "files", .{});
    _ = module.addCopyFile(table, "files.zig");
    _ = module.addCopyFile(root, "root.zig");
    return b.createModule(.{ .root_source_file = module.getDirectory().path(b, "root.zig") });
}
