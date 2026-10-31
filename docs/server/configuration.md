# Configuration

!!! warning "Draft"

    This page is a draft. Still to cover:

    - TLS listener setup: certificates, keys, client certificates
    - Unix socket listeners (`Address.unix`)
    - `kernel_backlog`, `reuse_address`, `acceptors`
    - All request limits: params, query, form fields
    - Response buffer sizes, `timeout.request_count`
    - Link to `ServerConfig` in the API reference

The third argument to `http.Server(App).init` is an `http.ServerConfig`:

```zig
var server = http.Server(void).init(gpa, io, .{
    .listeners = &.{.{
        .address = .{ .ip = try std.Io.net.IpAddress.parse("0.0.0.0", 8080) },
    }},
    .timeout = .{ .request = .fromSeconds(60) },
}, {});
```

`listeners` is the list of addresses to listen on. Each one has its own optional `tls` settings, and
one server can have a TLS listener and a plain one at the same time. With no listeners, it listens
on `127.0.0.1:8080`.

By default, a request has 30 seconds to complete, an idle keep-alive connection is closed after 30
seconds, and a graceful shutdown waits up to 30 seconds. These are `timeout.request`,
`timeout.keepalive` and `timeout.shutdown`, and `null` turns one off.

Requests are limited to 64 headers and a 1 MiB body, and the server accepts at most 10,000
connections at once (`request.max_header_count`, `request.max_body_size`, `max_connections`).
