# Deployment

## Running on zio

The examples in these docs run on `init.io`, the `std.Io.Threaded` implementation from the standard
library. It gives every connection an OS thread of its own, and a second one for its timeouts. A
handler waiting on a database keeps its thread busy until the answer comes back. You can use it for
development and small servers.

For production, run the server on [zio](https://lalinsky.github.io/zio/). It runs each connection
as a coroutine, and many coroutines share a few OS threads.

Add it to the project:

```sh
$ zig fetch --save "git+https://github.com/lalinsky/zio"
```

In `build.zig`, import it into your module and into Dusty's module. Dusty uses it for its timeouts:

```zig
const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zio", zio.module("zio"));
dusty_dep.module("dusty").addImport("zio", zio.module("zio"));
```

Then create the zio runtime in `main`, and pass its `io` to the server instead of `init.io`:

```zig
const zio = @import("zio");

pub const std_options_debug_io = zio.debug_io;

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    var app: App = .{};
    var server = http.Server(App).init(init.gpa, io, .{}, &app);
    defer server.deinit();

    // ...
}
```

`.executors = .auto` runs one executor thread per CPU. Without it, zio runs everything on the main
thread.

`std_options_debug_io` makes logging and `std.debug.print` go through zio too. Without it, a task
writing a log line can block a whole executor thread while it waits for stderr.

Pass the same `io` to anything else that does I/O, like a database client, so it runs on zio too.

## Graceful Shutdown

`server.run()` serves until its task is canceled. Then it stops accepting connections, waits for the
requests in flight to finish, and returns. This is from
[examples/todo](https://github.com/lalinsky/dusty/tree/main/examples/todo). It runs the server in a
task and cancels it on Ctrl-C or `SIGTERM`. systemd and Docker send `SIGTERM` when they stop a
service:

```zig
--8<-- "examples/todo/src/main.zig:shutdown"
```

The server waits up to `timeout.shutdown`, 30 seconds by default, and then cancels the requests that
are still running. WebSocket and event stream handlers run until the connection closes, so they keep
the shutdown waiting until the timeout. Docker kills the process 10 seconds after `SIGTERM` by default, so
raise its `stop_grace_period` or lower `timeout.shutdown`. If the server stops on its own, `main`
returns its error.

## Release Builds

Build with optimizations for production:

```sh
$ zig build -Doptimize=ReleaseSafe
```

## Logging

Dusty logs under the `.dusty` scope. To change how much it logs, set a level for that scope in
`std_options`:

```zig
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .dusty, .level = .warn }},
};
```

## Behind a Reverse Proxy

Timeouts and connection limits are on by default, and the server can run without a proxy. For public
traffic, we still recommend running it behind a reverse proxy or an HTTP load balancer, like nginx,
HAProxy or the one from your cloud provider. The proxy can take care of TLS, and it deals with the
common attacks before they reach the server, like floods of connections or clients that send their
requests very slowly. Most proxies also have rate limiting and circuit breaking, which stops sending
requests to a server that's failing or overloaded.

See the [nginx](https://docs.nginx.com/nginx/admin-guide/web-server/reverse-proxy/) and
[Caddy](https://caddyserver.com/docs/quick-starts/reverse-proxy) guides for how to set one up. nginx
needs a few more lines for [WebSocket](https://nginx.org/en/docs/http/websocket.html), and
`proxy_buffering off` for event streams.

Behind a proxy, set `trusted_proxy_hops`, so `req.remote_address` is the client's address instead of
the proxy's. See [Configuration](configuration.md#behind-a-proxy).

## Next Steps

- [Configuration](configuration.md) covers the timeouts and limits.
- [Making Requests](../client/requests.md) covers the HTTP client.
