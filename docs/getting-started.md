# Getting Started

This guide shows how to write a small HTTP server with Dusty. If you want to use the HTTP client,
see [Making Requests](client/requests.md) instead.

## Setup

We'll start from an empty project. You need Zig 0.16 or 0.17.

Create the project and add Dusty as a dependency:

```sh
$ zig init
$ zig fetch --save "git+https://github.com/lalinsky/dusty#v0.5.0"
```

Then open `build.zig` and add the module to your executable, after the `exe` definition:

```zig
const dusty = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("dusty", dusty.module("dusty"));
```

## Hello World

Put this into `src/main.zig`:

```zig
--8<-- "examples/hello_world.zig"
```

Now build and run it:

```sh
$ zig build run
info(dusty): Listening on 127.0.0.1:8080
```

Then try it from another terminal:

```sh
$ curl http://127.0.0.1:8080/
Hello, world!
$ curl http://127.0.0.1:8080/hello/zig
Hello, zig!
```

In a debug build, the server also logs each request it gets. If another program is already using
port 8080, `run` fails with `error.AddressInUse`.

Here is what the code does:

1. `App` holds the state of your application. Here it's only a greeting. In a real server it would
   be things like a database pool or settings loaded at startup.
2. [`http.Server(App).init`](../apidocs/#http.Server) creates the server. It takes an allocator, the `std.Io` implementation,
   the configuration, and a pointer to the app.
3. The configuration has a single listener on `127.0.0.1:8080`, so the server can only be reached
   from your own machine. Use `0.0.0.0` to accept connections from other machines.
4. [`server.router.get`](../apidocs/#http.Router) registers a handler for `GET` requests to a path. In `/hello/:name`, the
   `:name` part matches one segment of the path.
5. `server.run()` accepts connections and serves them until the program is stopped.

A handler declares only the parameters it needs. The order doesn't matter. Both handlers take
`*App` and [`*http.Response`](../apidocs/#http.Response). The `*App` is the pointer you passed to `init`. `hello` also takes
[`http.Param("name", []const u8)`](../apidocs/#http.Param), which holds the `:name` segment in `.value`. A handler that
needs the request itself, for example to read its headers or body, can also take [`*http.Request`](../apidocs/#http.Request).

[`res.print`](../apidocs/#http.Response.print) formats the body and sets the content type from its first argument. `.text` sends
`text/plain; charset=UTF-8`. The response is sent after the handler returns.

## Running in Production

The server above runs on `init.io`, which is `std.Io.Threaded` from the standard library. It gives
every connection its own OS thread. That's fine for development. See [Deployment](server/deployment.md)
for what to use in production.

## Next Steps

- [Routing](server/routing.md) covers path parameters, wildcards and groups.
- [Handlers](server/handlers.md) lists everything a handler can take and explains how errors
  become responses.
- [Configuration](server/configuration.md) has the listener, timeout and limit settings.
- [Making Requests](client/requests.md) covers the HTTP client.
