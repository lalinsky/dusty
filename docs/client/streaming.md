# Streaming Responses

By default `fetch` reads the whole body into memory. With `.stream = true`, it returns as soon as it
has the headers, and you read the body as it arrives. This function saves a download to a file:

```zig
--8<-- "examples/client_streaming.zig:download"
```

[`response.reader`](../../apidocs/#http.ClientResponse.reader) gives you the body. You read it
through `body.interface`, a `std.Io.Reader`. Chunked encoding and compression are already undone.
When a read fails with `error.ReadFailed`, `body.err` holds the underlying error.

The buffer you pass to `reader` is what the reader keeps bytes in until you take them. Code that only
streams the body somewhere else, like the download above, can pass an empty one.

## Reading Lines

`takeDelimiter` and `peek` work on the bytes in the reader's buffer, so the buffer has to hold the
longest line you need to see at once:

```zig
--8<-- "examples/client_streaming.zig:lines"
```

A line longer than the buffer fails with `error.StreamTooLong`.

## Limits and Timeouts

A streamed body isn't limited by `max_response_size`. The request timeout ends once the headers have
arrived, so reading the body has no time limit either.

## The Connection

`response.deinit()` releases the connection. If you didn't read the whole body, a small remainder is
read and thrown away so the connection can go back to the pool. A larger one closes the connection.

## Next Steps

- [Making Requests](requests.md) covers the request options.
- [WebSocket](websocket.md) covers connecting to a WebSocket server.
