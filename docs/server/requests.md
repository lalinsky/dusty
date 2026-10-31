# Requests

A handler that takes [`*http.Request`](../../apidocs/#http.Request) can read what the client sent:

```zig
--8<-- "examples/requests.zig:info"
```

`req.method` is the method, and `req.url` is the request target as it arrived. `req.path` is the
decoded part before the `?`. `req.query` has the query parameters. `req.headers.get` looks up a
header by name, ignoring case. Path parameters are in `req.params`. See
[Routing](routing.md#path-parameters).

For a value you need in many handlers, `http.Query` and `http.Header` give it to the handler already
parsed. See [Handlers](handlers.md#values-from-the-request).

## Body

The server doesn't read the body until the handler asks for it. `req.body()` reads all of it into
memory:

```zig
--8<-- "examples/requests.zig:body"
```

It returns null when the request has no body. `request.max_body_size` limits the body to 1 MiB by
default. A larger body fails with `error.BodyTooBig`, and if the handler returns that error, the
client gets a 413. A body sent with gzip or deflate `Content-Encoding` is decoded as it's read.

For a body too large to keep in memory, read it piece by piece with `req.reader`:

```zig
--8<-- "examples/requests.zig:reader"
```

`body.interface` is a `std.Io.Reader`. The body is decoded the same way, but `max_body_size` doesn't
apply. When a read fails with `error.ReadFailed`, `body.err` has the underlying error. A handler
that has taken the reader can't call `req.body()` after it.

## Forms

`req.formData()` reads a form sent as `application/x-www-form-urlencoded`, which is what an HTML
form sends by default:

```zig
--8<-- "examples/requests.zig:form"
```

A form with file uploads is sent as `multipart/form-data`, and `req.multiFormData()` reads it. Each
entry has the `value`, and the `filename` for a file:

```zig
--8<-- "examples/requests.zig:multipart"
```

Both read the whole body with `req.body()`, so the same size limit applies. If the request has a
different content type, they fail with `error.NotForm` or `error.NotMultipartForm`.

## JSON

`req.json(T)` parses the body with `std.json`, and returns null when there is no body.
[Serialization](serialization.md) shows how to decode it with json.zig, which is faster.

## Cookies

`req.cookies().get(name)` returns the value of a cookie the client sent:

```zig
--8<-- "examples/requests.zig:cookies"
```

To set a cookie, see [Responses](responses.md).

## The Client

`req.remote_address` is the address of the client. Behind a reverse proxy it's the proxy's address.
[Configuration](configuration.md#behind-a-proxy) shows how to get the client's address from
`X-Forwarded-For`.

`req.secure` is true when the connection uses TLS. On a server with more than one listener,
`req.listener` is the one the request came in on.

## Memory

`req.arena` is an allocator for anything that only has to live as long as the request. It's freed
after the response has been sent. Values the request gives you, like headers, the body and form
fields, live in the same memory, so copy them if you need them after that.

## Next Steps

- [Responses](responses.md) covers status codes, headers and the ways to write a body.
- [Middleware](middleware.md) covers code that runs before and after the handlers.
