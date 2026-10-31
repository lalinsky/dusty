# Server-Sent Events

A handler can keep the response open and send events on it:

```zig
var buf: [4096]u8 = undefined;
var events = try res.startEventStream(&buf);
try events.send("hello", .{ .event = "greeting" });
```

`res.startEventStream` sends the headers for an event stream and returns an `http.EventStream`. The
handler keeps sending events with `send` until it's done, or until `send` returns an error because
the client went away.
