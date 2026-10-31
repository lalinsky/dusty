# Build Options

TLS and gzip are compiled in by default. You can turn them off when you add the dependency in
`build.zig`:

```zig
const dusty_dep = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
    .use_tls = false,
});
```

## use_tls

`use_tls` builds in TLS through [tls.zig](https://github.com/ianic/tls.zig). Without it, HTTPS
requests fail with `error.TlsNotConfigured`, and a server with a TLS listener fails to start.

## use_zlib

`use_zlib` builds in gzip and deflate through zlib. Without it, compressed bodies can't be decoded,
and responses are sent uncompressed even when compression is turned on.
