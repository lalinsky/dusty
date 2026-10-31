# Handlers

A handler is a function that gets the request and fills in the response. It declares only the
parameters it needs, in any order, and each one is filled in by its type:

- `*App`, the pointer you passed to [`http.Server(App).init`](../../apidocs/#http.Server)
- [`*http.Request`](../../apidocs/#http.Request)
- [`*http.Response`](../../apidocs/#http.Response)
- `*App.RequestContext`, a struct that each request gets its own copy of, see
  [Middleware](middleware.md)
- `http.Param`, `http.Query` and `http.Header`, values from the request
- Your own types, filled in by their `extract` function

The return type is `void` or `!void`.

## Values from the Request

[`http.Param`](../../apidocs/#http.Param), [`http.Query`](../../apidocs/#http.Query) and
[`http.Header`](../../apidocs/#http.Header) give the handler a path parameter, a query parameter
and a header, parsed as the type you ask for:

```zig
--8<-- "examples/handlers.zig:values"
```

```zig
server.router.get("/users/:id/posts", listPosts);
```

Each one takes a name and a type. The parsed value is in `.value`. They parse the same types:
integers, enums, `bool`, `[]const u8`, and types with a `parseParam` function. See
[Routing](routing.md#path-parameters) for the details.

They differ in what happens when the value isn't there or doesn't parse:

- A path parameter that doesn't parse makes the route not match, so the request gets a 404 unless
  another route matches it.
- A query parameter or header that is missing is a 400. With an optional type, like
  `?enum { new, top }` above, it's null instead.
- A query parameter or header that doesn't parse is a 400, optional or not. `?sort=old` gets a
  400 here.

## Your Own Parameter Types

A handler can take any type with a `pub fn extract(scope: anytype) !T` function. `scope` has four
fields: `app`, `req`, `res` and `ctx`. This one reads two
query parameters, with defaults:

```zig
--8<-- "examples/handlers.zig:page"
```

`extract` can return `error.MissingValue` or `error.InvalidValue`, and the request gets a 400. Any
other error is handled the same way as an error from the handler. Here, `http.Query(...).extract`
returns `error.InvalidValue` for `?page=x`, and `Page.extract` passes it on.

## App State

All requests get the same `*App`, and they can run at the same time on different threads.
Anything in the app that changes after startup has to be safe to use from several threads, for
example with an atomic or a mutex:

```zig
--8<-- "examples/handlers.zig:visits"
```

## Errors

When a handler returns an error, the server answers with a 500 and logs the error. Some errors are
the client's fault, and get a different status:

- Reading a body that is too large gives a 413. A body in an encoding the server can't decode
  gives a 415, and a broken body gives a 400.
- A query parameter, header or your own parameter type that is missing or doesn't parse gives a
  400, as described above.

A handler that returns `error.NotFound` gets the same 404 as a request with no route:

```zig
--8<-- "examples/handlers.zig:not_found"
```

Whatever the handler wrote to the response before the error is thrown away. If the handler has
already started sending the response, for example with `res.stream`, the server can't replace it
and closes the connection.

## Custom Error Responses

The app can replace the default 404 and error responses by declaring `notFound` and
`uncaughtError`:

```zig
--8<-- "examples/handlers.zig:app"
```

`notFound` takes parameters the same way a handler does, except path parameters, since there is no
route. `uncaughtError` returns `void`, so it can't fail. It can take the error as `anyerror`, but not
`http.Param`, `http.Query`, `http.Header` or your own types.

`uncaughtError` also gets the errors the server would answer with a 400, 413 or 415. [`req.bodyErrorStatus(err)`](../../apidocs/#http.Request.bodyErrorStatus) and
[`req.extractErrorStatus(err)`](../../apidocs/#http.Request.extractErrorStatus) return that status
for those errors, and null for the others.

## Timeouts

A request has 30 seconds to finish by default, including the handler. A handler that needs longer
can set a new deadline with
[`req.setTimeout`](../../apidocs/#http.Request.setTimeout):

```zig
req.setTimeout(.{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } });
```

The new deadline counts from the call. `req.setTimeout(.none)` removes it. See
[Configuration](configuration.md) to change the default.

## Next Steps

- [Requests](requests.md) covers the request body, forms and cookies.
- [Responses](responses.md) covers status codes, headers and the ways to write a body.
