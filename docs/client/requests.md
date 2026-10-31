# Making Requests

!!! warning "Draft"

    This page is a draft. Still to cover:

    - Query strings and URL encoding
    - Request headers and their lifetime
    - Sending JSON with json.zig
    - Errors: `ResponseTooLarge`, `HeadersTooLarge`, `TlsNotConfigured`
    - How redirects change the method and body
    - Cost of timeouts on `std.Io.Threaded`, `error.ConcurrencyUnavailable`

```zig
--8<-- "examples/fetch.zig"
```

`fetch` connects, sends the request, follows redirects and reads the whole body before it returns.
`response.body()` gives you that body, or null if it was empty. The response owns its memory, so
anything you got from it is only valid until `response.deinit()`.

One `http.Client` is meant to be used for the whole program. It keeps idle connections in a pool
and reuses them for later requests to the same host.

## Options

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
