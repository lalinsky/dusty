# Streaming Responses

!!! warning "Draft"

    This page is a draft. Still to cover:

    - Include examples/client.zig
    - Buffer size and `peek`/`take`
    - `decompress = false`
    - Whether the connection goes back to the pool when the body isn't read to the end

With `.stream = true`, `fetch` returns as soon as it has the headers, and you read the body from the
connection yourself:

```zig
var response = try client.fetch(url, .{ .stream = true });
defer response.deinit();

var buf: [8192]u8 = undefined;
var body = try response.reader(&buf);

var out_buf: [8192]u8 = undefined;
var out = std.Io.File.stdout().writer(io, &out_buf);
_ = try body.interface.streamRemaining(&out.interface);
try out.interface.flush();
```

`body.interface` is a `std.Io.Reader`, with chunked encoding and compression already undone. When a
read fails with `error.ReadFailed`, `body.err` has the real error.

A streamed body isn't limited by `max_response_size` or by the request timeout, which ends once the
headers have arrived.
