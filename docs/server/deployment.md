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

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    var server = http.Server(App).init(init.gpa, io, .{}, &app);
    defer server.deinit();

    // ...
}
```

`.executors = .auto` runs one executor thread per CPU. Without it, zio runs everything on the main
thread.

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
the shutdown waiting until then. Docker kills the process 10 seconds after `SIGTERM` by default, so
raise its `stop_grace_period` or lower `timeout.shutdown`. If the server stops on its own, `main`
returns its error.

## Release Builds

Build with optimizations for production:

```sh
$ zig build -Doptimize=ReleaseFast
```

`ReleaseSafe` keeps the safety checks, at some cost in speed.

## Behind a Reverse Proxy

When the server runs behind nginx or a load balancer, set `trusted_proxy_hops`, so
`req.remote_address` is the client's address instead of the proxy's. See
[Configuration](configuration.md#behind-a-proxy).

## Next Steps

- [Configuration](configuration.md) covers the timeouts and limits.
