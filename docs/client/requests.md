# Making Requests

Pass the method, headers and body in the options to `fetch`:

```zig
var headers = try http.Headers.init(allocator, 4);
defer headers.deinit(allocator);
try headers.put("Content-Type", "application/json");

var response = try client.fetch("https://example.com/api/users", .{
    .method = .post,
    .headers = &headers,
    .body = "{\"name\":\"Alice\"}",
});
defer response.deinit();
```

The response has `status()`, `headers()`, `contentType()` and `contentLength()`, and `body()` for
the body. A gzip or deflate body is decoded unless you pass `.decompress = false`, and a body over
10 MiB fails with `error.ResponseTooLarge` (`max_response_size` in the client config).

`fetch` follows up to 10 redirects, and `.max_redirects` changes that for one request, and 0
turns redirects off.

A request has 30 seconds to finish by default. That covers connecting, the TLS handshake, every
redirect and the whole body. `.timeout` replaces it for one request, and `.timeout = .none` turns it
off.
