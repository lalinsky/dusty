# Build Options

The options go in the `b.dependency` call in `build.zig`:

```zig
const dusty_dep = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
    .tls = .ztls,
});
```

A library that an option turns off isn't downloaded or compiled.

## tls

TLS is opt-in. By default, `tls` is `none`, so HTTPS requests fail with `error.TlsNotConfigured`,
and a server with a TLS listener fails to start.

Dusty has two TLS backends built in, both from [ztls](https://github.com/lalinsky/ztls), which is
built on [AWS-LC](https://github.com/aws/aws-lc). AWS-LC is C, compiled along with your program, so
the first build takes a while.

- `ztls` uses ztls's native engine, which implements the TLS protocol in Zig and uses AWS-LC for
  cryptography. It's the faster of the two: reading and writing don't share a lock, and records
  are encrypted and decrypted without extra copies. It's newer, and speaks only the modern parts
  of TLS: TLS 1.3 as client and server, and TLS 1.2 as client only.
- `libssl` uses ztls's libssl engine, which wraps AWS-LC's own TLS implementation. It has much more
  real-world use behind it, and speaks the older versions and cipher suites some peers still need,
  TLS 1.0 to 1.3 on both sides. It's a little slower, and needs a C++ runtime.

With `custom`, Dusty uses a TLS module you provide instead, which can be another version of ztls,
or any library with the same API, such as [tls.zig](https://github.com/ianic/tls.zig). Add it to
your own `build.zig.zon` and import its module into Dusty's as `"tls"`:

```zig
const dusty_dep = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
    .tls = .custom,
});
const tls = b.dependency("tls", .{ .target = target, .optimize = optimize });
dusty_dep.module("dusty").addImport("tls", tls.module("tls"));
```

ztls names its module `ztls`, so for it use `tls.module("ztls")`. Dusty looks at the options the
module takes and fills in the ones it has, so small differences between versions don't matter. If
you forget the import, the build fails with an error that tells you what to add. You import zio
the same way, see [Deployment](server/deployment.md#running-on-zio).

## compression

`compression` builds in gzip and deflate with [zlib.zig](https://github.com/lalinsky/zlib.zig).
It's off by default. Without it, compressed bodies can't be decoded, the client doesn't ask for
them, and responses are sent uncompressed, even with `res.compress = true`.
