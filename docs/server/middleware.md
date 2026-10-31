# Middleware

!!! warning "Draft"

    This page is a draft. Still to cover:

    - `init` with `http.MiddlewareConfig` (arena, allocator)
    - Answering without calling `executor.next()`, like an auth check
    - `onHeaders` and `onComplete` hooks, when they run and in what order
    - Order of middleware in a chain, router vs group middleware
    - `RequestContext` example: authenticated user passed to the handler
    - `Cors` options
    - `Session`: `SessionData`, signing, cookie options

Middleware is a type with a `Config`, an `init` and an `execute` method. In `execute`, it can look at
the request, call `executor.next()` to run the rest of the chain, and look at the response after it
returns:

```zig
const AccessLog = struct {
    pub const Config = struct {};

    pub fn init(_: Config) !AccessLog {
        return .{};
    }

    pub fn execute(_: *const AccessLog, req: *http.Request, res: *http.Response, executor: anytype) !void {
        try executor.next();
        std.log.info("{f} {s} {d}", .{ req.method, req.url, @intFromEnum(res.status) });
    }
};
```

`server.middleware` creates one from its `Config`. Routes get their middleware when they're
registered, so set `server.router.middlewares` first, and it applies to every route registered after
that. Middleware passed to `server.router.group(...)` only applies to the routes of that group.

```zig
const log = try server.middleware(AccessLog, .{});
server.router.middlewares = &.{log};

server.router.get("/", index);
```

Dusty comes with `http.middleware.Cors` and `http.middleware.Session`.

Middleware that has something for the handler, like the user it authenticated, puts it in the app's
`RequestContext`. That's a struct you declare on the app, with a default for every field, and each
request gets a new one. Middleware reaches it as `executor.ctx`, and handlers take it as a
`*App.RequestContext` parameter.
