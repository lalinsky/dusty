# Build Options

Dusty uses two external libraries: [tls.zig](https://github.com/lalinsky/tls.zig) for TLS and
[zlib.zig](https://github.com/lalinsky/zlib.zig) for gzip and deflate. Both are on by default, and
you can turn either of them off. A library that's turned off isn't downloaded or compiled.

The options go in the `b.dependency` call in `build.zig`:

```zig
const dusty_dep = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
    .use_tls = false,
});
```

## use_tls

`use_tls` builds in TLS. Without it, HTTPS requests fail with `error.TlsNotConfigured`. A server
with a TLS listener fails to start.

## use_zlib

`use_zlib` builds in gzip and deflate. Without it, compressed bodies can't be decoded. Responses are
sent uncompressed, even when compression is turned on.

## Using Your Own tls.zig

Dusty pins a version of tls.zig. To use a different one, add it to your own `build.zig.zon`, set
`use_bundled_tls = false` and import its module into Dusty's:

```zig
const dusty_dep = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
    .use_bundled_tls = false,
});
const tls = b.dependency("tls", .{ .target = target, .optimize = optimize });
dusty_dep.module("dusty").addImport("tls", tls.module("tls"));
```

The module has to be compatible with the version Dusty pins. If you forget the import, the build
fails with an error that tells you what to add.

You import zio the same way. See [Deployment](server/deployment.md#running-on-zio).