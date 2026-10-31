# Making Requests

Dusty has an HTTP client too. Create one [`http.Client`](../../apidocs/#http.Client) and use it for
the whole program:

```zig
--8<-- "examples/fetch.zig:client"
```

The client keeps idle connections in a pool and reuses them for later requests to the same host.
Tasks running at the same time can share it.

## Fetching a URL

[`client.fetch`](../../apidocs/#http.Client.fetch) sends a request and returns the response:

```zig
--8<-- "examples/fetch.zig:basic"
```

`fetch` connects, sends the request, follows redirects and reads the whole body before it returns.
`response.body()` gives you that body, or null if it was empty. Call `response.deinit()` when you're
done. It puts the connection back in the pool. Anything you got from the response is only valid
until then.

The response also has `status()`, `headers()`, `contentType()` and `contentLength()`.

## Method, Headers and Body

The second argument to `fetch` sets the method, the headers and the body:

```zig
--8<-- "examples/fetch.zig:post"
```

`http.Headers.init` takes the number of headers it has room for. A non-2xx status isn't an error,
so check the status yourself.

To send JSON, encode it with [json.zig](../server/serialization.md) or `std.json` into a buffer
first, and pass that as the body.

## Query Strings

The URL is sent as it is, so escape the values you put in a query string:

```zig
--8<-- "examples/fetch.zig:query"
```

This sends `?q=fish%20%26%20chips`.

## Redirects

`fetch` follows up to 10 redirects. `.max_redirects` changes that for one request. With `0`, `fetch`
doesn't follow redirects and you get the redirect response itself.

## Compressed Responses

The client asks for gzip and deflate, and decodes the body for you. Pass `.decompress = false` to
get the body as it was sent. `response.contentEncoding()` tells you how it was encoded.

## Errors and Timeouts

A request has 30 seconds to finish by default. That covers connecting, the TLS handshake, every
redirect and the whole body. `.timeout` replaces it for one request, and `.timeout = .none` turns it
off:

```zig
var response = try client.fetch(url, .{
    .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
});
```

A request that runs out of time fails with `error.Timeout`.

A body over 10 MiB fails with `error.ResponseTooLarge`. `max_response_size` in the
[client configuration](configuration.md) changes the limit. For bigger bodies,
[stream the response](streaming.md) instead.

## Next Steps

- [Streaming Responses](streaming.md) covers reading the body as it arrives.
- [Configuration](configuration.md) covers the client settings.
