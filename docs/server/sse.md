# Server-Sent Events

!!! warning "Draft"

    This page is a draft. Still to cover:

    - Include examples/sse.zig
    - `EventStream.Options` (event, id, ...)
    - `startSend` and `EventWriter` for writing event data in pieces
    - Noticing when the client went away
    - Timeouts and graceful shutdown with long-lived streams

A handler can keep the response open and send events on it:

```zig
var buf: [4096]u8 = undefined;
var events = try res.startEventStream(&buf);
try events.send("hello", .{ .event = "greeting" });
```

`res.startEventStream` sends the headers for an event stream and returns an `http.EventStream`. The
handler keeps sending events with `send` until it's done, or until `send` returns an error because
the client went away.
