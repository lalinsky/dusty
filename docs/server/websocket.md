# WebSocket

A handler turns a request into a WebSocket connection with
[`res.upgradeWebSocket`](../../apidocs/#http.Response.upgradeWebSocket). This one sends every text
and binary message back:

```zig
--8<-- "examples/websocket.zig:echo"
```

```zig
server.router.get("/ws", echo);
```

`res.upgradeWebSocket(req)` sends the response that accepts the upgrade and returns an
[`http.WebSocket`](../../apidocs/#http.WebSocket). If the request isn't a WebSocket upgrade, it
returns null. The handler can then answer it like any other request. Call `ws.deinit()` when you're
done with the connection.

## Messages

`ws.receive()` waits for the next message. A message has a `type`, such as `.text` or `.binary`, and
its `data`. The data is only valid until the next call to `receive`.

`ws.receiveMany()` also waits for the next message, but returns it together with every other
message that has already arrived. To send the answers to a batch in one write, set
`ws.autoflush = false` and call `ws.flush()` after the batch.

`ws.send(.text, data)` sends a message. One task can receive while other tasks send on the same
connection.

`receive` answers pings for you. `ws.ping(data)` sends a ping of your own.

## Closing

When the client closes the connection, `receive` answers the close and returns a message of type
`.close`. `error.EndOfStream` means the connection ended without a close message.

To close it from the server, call `ws.close(.normal, "bye")` with a close code and a reason.

## Timeouts

The WebSocket runs inside the handler, so the request timeout covers it. That timeout is 30 seconds
by default. The example calls `req.setTimeout` before every `receive`, so the connection closes
after the client has been quiet for 60 seconds. `req.setTimeout(.none)` turns it off.

## Next Steps

- [WebSocket](../client/websocket.md) in the client section covers connecting to a WebSocket
  server.
- [Server-Sent Events](sse.md) covers sending events to a browser over a normal response.
