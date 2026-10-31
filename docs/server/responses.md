# Responses

!!! warning "Draft"

    This page is a draft. Still to cover:

    - `http.ContentType` values, setting headers, `Content-Length` vs chunked
    - `BodyWriter` and `StreamingBodyWriter`, and what HTTP/1.0 clients get
    - `sendFile` options
    - `setCookie` and `CookieOpts`
    - `resetBody` and `clearWriter` for error handling
    - What happens when a handler fails after writing part of the body

In the simple case, the handler sets a status, maybe some headers, and a body, and all of it goes out
after the handler returns, so middleware can still change it:

```zig
res.status = .created;
try res.header("Location", "/users/42");
try res.print(.json, "{{\"id\":{d}}}", .{42});
```

The body can also come from `res.render` for [templates](templating.md), `res.encode` or `res.json` for
[serialized data](serialization.md), or `res.writer()` for writing it piece by piece. With `res.compress = true`, the body is
gzipped for clients that accept it.

`res.stream(&buf)` sends the headers right away, and then the body as the handler writes it. Call
`end` on the writer from `writer()` or `stream()` before returning. `res.sendFile(dir, path, .{})`
serves a file from disk.

See also [Server-Sent Events](sse.md) and [WebSocket](websocket.md).
