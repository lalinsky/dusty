# Handlers

A handler is a function that gets the request and fills in the response. It declares only the
parameters it needs, in any order, and each one is filled in by its type:

- `*App`, the pointer you passed to [`http.Server(App).init`](../../apidocs/#http.Server)
- [`*http.Request`](../../apidocs/#http.Request)
- [`*http.Response`](../../apidocs/#http.Response)
- `*App.RequestContext`, a struct that each request gets its own copy of, see
  [Middleware](middleware.md)
- `http.Path`, `http.Query` and `http.Header`, values from the request
- `http.Body`, the request body
- Your own types, filled in by their `extract` function

The return type is `void` or `!void`.

## Values from the Request

Dusty has parameter types that read a part of the request and give the handler its value,
already parsed:

```zig
--8<-- "examples/handlers.zig:values"
```

```zig
server.router.get("/users/:id/posts", listPosts);
```

The value is in `.value`. When a value is missing or doesn't parse, the handler isn't called, and
the request gets an error status instead, except where the table says otherwise.

| Type | Value | Missing | Doesn't parse |
|---|---|---|---|
| [`http.Path(name, T)`](../../apidocs/#http.Path) | Path parameter | Compile error | 404 |
| [`http.Query(name, T)`](../../apidocs/#http.Query) | Query parameter | 400, or null for `?T` | 400 |
| [`http.Header(name, T)`](../../apidocs/#http.Header) | Request header | 400, or null for `?T` | 400 |
| [`http.Body`](../../apidocs/#http.Body) | The whole body | Empty | — |

### Path, Query and Header

These take a name and a type. They parse the same types: integers, enums, `bool`, `[]const u8`,
and types with a `parseParam` function. See [Routing](routing.md#path-parameters) for the details.

A path parameter must be in the route, `:id` here, or the code doesn't compile. One that doesn't
parse makes the route not match, so the request gets a 404 unless another route matches it.

A query parameter or header that is missing is a 400. With an optional type, like
`?enum { new, top }` above, it's null instead. One that is there but doesn't parse is a 400,
optional or not, so `?sort=old` gets a 400 here. Header names ignore case, and when a header is
sent more than once, the first one counts.

### Body

`http.Body` reads the whole body with `req.body()`, and fails the same way, for example with a 413
for a body over `request.max_body_size`. A request with no body gets an empty `.value`. See
[Requests](requests.md#body).

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

An app with no state uses `http.Server(void)`, and passes `{}` in place of `&app`.

## Errors

When a handler returns an error, the server answers with a 500 and logs the error. Some errors are
the client's fault, and get a different status:

- Reading a body that is too large gives a 413. A body in an encoding the server can't decode
  gives a 415, and a broken body gives a 400.
- `req.json`, `req.formData` and `req.multiFormData` give a 415 when the request has a different
  content type, and a 400 when the body doesn't parse.
- A query parameter, header or your own parameter type that is missing or doesn't parse gives a
  400, as described above.

A handler that returns `error.NotFound` gets the same 404 as a request with no route:

```zig
--8<-- "examples/handlers.zig:not_found"
```

To answer with some other status, return `res.fail` with it:

```zig
if (!valid) return res.fail(.unprocessable_entity, .{ .message = "name is required" });
```

It returns `error.HttpFail`, and the server answers with the status, the same way it answers the
client errors above. The message is optional and goes to the client. You can also pass the error
that caused the failure as `.cause`, which goes to the log.

For both `res.fail` and the client errors above, the status only applies when the handler returns
the error it was recorded for: `error.HttpFail` or the cause, or `error.ReadFailed` from a body
the handler was streaming. If the handler catches it and returns a different error, that error is
handled like any other.

The body the handler wrote before the error is thrown away. If the handler has
already started sending the response, for example with `res.stream`, the server can't replace it
and closes the connection.

## Custom Error Responses

The app can replace the default 404 and error responses by declaring `notFound` and
`uncaughtError`:

```zig
--8<-- "examples/handlers.zig:app"
```

`notFound` takes parameters the same way a handler does, except path parameters, since there is no
route. The 405 for a method with no route on the path goes through `methodNotAllowed` the same way,
which gets the response with the status and the `Allow` header already set. `uncaughtError` returns
`void`, so it can't fail. It can take the error as `anyerror`, but not
`http.Path`, `http.Query`, `http.Header`, `http.Body` or your own types.

The 400, 413 and 415 for what the client got wrong, and the statuses from `res.fail`, don't go
through `uncaughtError`. To answer those yourself too, for example as JSON, turn off `answer_client_errors` in the server's request
settings:

```zig
.request = .{ .answer_client_errors = false },
```

`uncaughtError` then gets them as well, and `res.failure` holds the status the server would have
used, with the message and cause, or null when the error is the server's own.

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
