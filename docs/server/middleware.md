# Middleware

Middleware is code that runs around the handlers. It's a struct with a `Config`, an `init` and an
`execute` method:

```zig
--8<-- "examples/middleware.zig:timing"
```

`execute` gets the request, the response, and the executor. `executor.next()` runs the next
middleware, and in the end the handler. When it returns, the handler is done. The middleware can
then look at the response and change it. This one adds an `X-Response-Time` header.

## Attaching Middleware

`server.middleware` creates the middleware from its `Config`. The router's middleware applies to
every route, and a group's middleware to the routes of the group:

```zig
--8<-- "examples/middleware.zig:attach"
```

Routes get the router's middleware when they're registered, so set `server.router.middlewares`
first. Middleware runs in the order of the list, with the router's before the group's. See
[Routing](routing.md#groups) for more about groups.

## Answering Early

Middleware doesn't have to call `executor.next()`. If it answers the request itself, the handler
doesn't run:

```zig
--8<-- "examples/middleware.zig:auth"
```

A request to `/admin/` without the right `Authorization` header gets a 401.

## Passing Values to Handlers

`Auth` in the snippet above sets `executor.ctx.user` for the handler. `executor.ctx` is the app's
`RequestContext`, a struct you declare on the app type. Every field needs a default, because each
request starts with a new one:

```zig
--8<-- "examples/middleware.zig:app"
```

A handler gets it by taking `*App.RequestContext`:

```zig
--8<-- "examples/middleware.zig:handlers"
```

## Hooks

Code after `executor.next()` runs when the handler returns. For a response the handler streams,
like a file download or [Server-Sent Events](sse.md), the headers are already sent by then, and
the body may be too. For those responses, middleware can declare `onHeaders` and `onComplete`.
They run for every middleware whose `execute` was called:

- `onHeaders(self, req, res, ctx)` runs right before the response headers are sent, so it can
  still add a header. It can return an error, which on a buffered response becomes the error
  response.
- `onComplete(self, req, res, ctx, err)` runs after the response has been sent, or failed to.
  `err` is the error, if there was one. It can't return an error.

This access log uses `onComplete`, so it also logs errors and responses that didn't finish:

```zig
--8<-- "examples/middleware.zig:log"
```

## Init and Deinit

`init` takes the `Config`. Middleware that needs to allocate can take a second parameter, an
[`http.MiddlewareConfig`](../../apidocs/#http.MiddlewareConfig). It has the router's `arena` and the
server's `allocator`. If the middleware has a `deinit` method, `server.deinit` calls it.

One instance of the middleware serves all requests at the same time. Put anything that changes per
request in the `RequestContext`. Any other state that changes has to be safe to use from several
threads.

## CORS

`http.middleware.Cors` adds the CORS headers, and answers preflight requests:

```zig
const cors = try server.middleware(http.middleware.Cors, .{
    .origin = "https://example.com",
    .methods = "GET, POST",
    .headers = "Content-Type",
    .max_age = "86400",
});
```

## Sessions

`http.middleware.Session` keeps a session in a signed cookie. The app's `RequestContext` needs a
`session` field:

```zig
const App = struct {
    pub const RequestContext = struct {
        session: http.SessionData = .{},
    };
};
```

The `secret_key` in its config, set in the [example above](#attaching-middleware), signs the
cookie. Keep it secret and make it at least 32 random bytes. The handler reads and writes the
session through the context:

```zig
--8<-- "examples/middleware.zig:session"
```

`ctx.session.remove(key)` removes one value, and `ctx.session.clear()` removes them all, for
example when the user logs out. A session with nothing in it deletes the cookie.

The session doesn't copy the values you give it. They have to live until the response is sent, so
allocate them with `req.arena`. The cookie is sent with `Secure` by default, so browsers only send
it back over HTTPS. `cookie_opts` in the config changes that.

## Next Steps

- [Static Files and Assets](static-files.md) covers serving files.
- [Configuration](configuration.md) covers the server settings.
