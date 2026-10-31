# Responses

A handler fills in [`*http.Response`](../../apidocs/#http.Response) with a status, headers and a
body:

```zig
--8<-- "examples/responses.zig:basic"
```

The status is `.ok` unless the handler sets another one. Nothing is sent until the handler returns.
Middleware that runs after the handler can still change the response.

[`res.print`](../../apidocs/#http.Response.print) formats the body. Its first argument is the
content type, from [`http.ContentType`](../../apidocs/#http.ContentType): `.text`, `.html`, `.json`
and so on. `res.header` sets any other header.

A redirect is a status and a `Location` header:

```zig
--8<-- "examples/responses.zig:redirect"
```

## Writing the Body

`res.print` is enough for a body you can format in one call. For more than that, `res.writer()`
gives you a `std.Io.Writer` to write the body with:

```zig
--8<-- "examples/responses.zig:writer"
```

Call `end` when the body is done. The body is kept in memory until the handler returns, and sent
with the rest of the response.

`res.render` writes the body from a template. See [Templating](templating.md). `res.encode` and
`res.json` write it from a value. See [Serialization](serialization.md).

## Streaming

`res.stream` sends the headers right away, and then the body as the handler writes it:

```zig
--8<-- "examples/responses.zig:stream"
```

`buf` collects the body before it's sent. `flush` sends what is in it. The body is sent with chunked
encoding, unless the handler set a `Content-Length` header. Call `end` when the body is done.

Once the headers are sent, they can't change. If the handler fails after that, the server closes the
connection, since it can't send an error response anymore.

For events sent to a browser as they happen, see [Server-Sent Events](sse.md).

## Files

`res.sendFile` sends a file from a directory:

```zig
--8<-- "examples/responses.zig:file"
```

The file is opened when `sendFile` is called, so a missing file is an error the handler can still
turn into a 404. It's sent after the handler returns.

`router.static` serves files named by the request path, and checks that the path stays inside the
directory. See [Static Files and Assets](static-files.md).

## Compression

With `res.compress = true`, the body is sent gzipped to clients that accept it:

```zig
--8<-- "examples/responses.zig:compress"
```

## Cookies

`res.setCookie` adds a `Set-Cookie` header:

```zig
--8<-- "examples/responses.zig:cookie"
```

The options are in [`http.CookieOpts`](../../apidocs/#http.CookieOpts). To read cookies, see
[Requests](requests.md#cookies).

## Next Steps

- [Templating](templating.md) covers HTML pages.
- [Serialization](serialization.md) covers JSON and MessagePack.
