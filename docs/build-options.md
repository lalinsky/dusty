# Build Options

Dusty uses external libraries for TLS and for gzip and deflate. TLS is off unless you turn it
on, and [zlib.zig](https://github.com/lalinsky/zlib.zig) is on unless you turn it off.
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

`tls` picks how TLS is done:

- `none`, the default, builds without TLS. HTTPS requests fail with `error.TlsNotConfigured`, and a
  server with a TLS listener fails to start.
- `ztls` uses [ztls](https://github.com/lalinsky/ztls), with the TLS protocol implemented in Zig and
  the cryptography done by AWS-LC. AWS-LC is C, compiled along with your program, so the first
  build takes a while.
- `libssl` uses ztls with its libssl engine, which wraps AWS-LC's own TLS implementation. It needs
  a C++ runtime.
- `custom` uses a module you provide, see below.

## use_zlib

`use_zlib` builds in gzip and deflate. Without it, compressed bodies can't be decoded. Responses are
sent uncompressed, even when compression is turned on.

## Using Your Own TLS Module

Dusty pins a version of ztls. To use a different version, or another library such as
[tls.zig](https://github.com/lalinsky/tls.zig), add it to your own `build.zig.zon`, set
`tls = .custom` and import its module into Dusty's:

```zig
const dusty_dep = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
    .tls = .custom,
});
const tls = b.dependency("tls", .{ .target = target, .optimize = optimize });
dusty_dep.module("dusty").addImport("tls", tls.module("tls"));
```

ztls names its module `ztls`, so for it use `tls.module("ztls")`, still imported as `"tls"`.

The module has to have the same API as ztls or tls.zig. Dusty looks at the options it takes and
fills in the ones it has, so small differences between versions don't matter. If you forget
the import, the build fails with an error that tells you what to add.

You import zio the same way. See [Deployment](server/deployment.md#running-on-zio).