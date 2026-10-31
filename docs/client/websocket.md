# WebSocket

!!! warning "Draft"

    This page is a draft. Still to cover:

    - Complete example against the server example
    - `wss://`, extra headers for the upgrade, Unix sockets
    - Handling close, `deinit`

`client.connectWebSocket` sends the upgrade request and returns an `http.WebSocketClient`:

```zig
var ws = try client.connectWebSocket("ws://127.0.0.1:8080/ws", .{});
defer ws.deinit();

try ws.send(.text, "hello");
const msg = try ws.receive();
```

It has the same methods as the server side: `send`, `receive`, `ping` and `close`. Both `ws://` and
`wss://` URLs work.
