# Build Options

Dusty uses external libraries for TLS and for gzip and deflate. TLS is off unless you pick a
library for it, and [zlib.zig](https://github.com/lalinsky/zlib.zig) is on unless you turn it off.
A library that isn't used isn't downloaded or compiled.

The options go in the `b.dependency` call in `build.zig`:

```zig
const dusty_dep = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
    .tls = .ztls,
});
```

## tls

`tls` picks the TLS library:

- `none`, the default, builds without TLS. HTTPS requests fail with `error.TlsNotConfigured`, and a
  server with a TLS listener fails to start.
- `ztls` uses [ztls](https://github.com/lalinsky/ztls), which does its cryptography with AWS-LC.
  AWS-LC is C, compiled along with your program, so the first build takes a while. On Windows and
  Intel Macs it's built without its assembly, which makes it slower there.
- `tls_zig` uses [tls.zig](https://github.com/lalinsky/tls.zig), which is written in Zig.
- `custom` uses a module you provide, see below.

Both libraries support everything Dusty does with TLS, client certificates included.

## use_zlib

`use_zlib` builds in gzip and deflate. Without it, compressed bodies can't be decoded. Responses are
sent uncompressed, even when compression is turned on.

## Using Your Own TLS Module

Dusty pins a version of each TLS library. To use a different one, add it to your own
`build.zig.zon`, set `tls = .custom` and import its module into Dusty's:

```zig
const dusty_dep = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
    .tls = .custom,
});
const tls = b.dependency("tls", .{ .target = target, .optimize = optimize });
dusty_dep.module("dusty").addImport("tls", tls.module("tls"));
```

The module has to be compatible with the version of tls.zig or ztls that Dusty pins. If you forget
the import, the build fails with an error that tells you what to add.

You import zio the same way. See [Deployment](server/deployment.md#running-on-zio).