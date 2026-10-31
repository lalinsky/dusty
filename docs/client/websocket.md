# WebSocket

The client can also open WebSocket connections, with the same `http.Client` you use for other
requests. Pass a `ws://` URL to
[`client.connectWebSocket`](../../apidocs/#http.Client.connectWebSocket), and you get back an
[`http.WebSocketClient`](../../apidocs/#http.WebSocketClient) to send and receive messages on.

This example talks to the [echo server](../server/websocket.md) from the server docs:

```zig
--8<-- "examples/websocket_client.zig:connect"
```

If the server doesn't accept the upgrade, `connectWebSocket` returns
`error.WebSocketUpgradeFailed`.

`ws.send`, `ws.receive`, `ws.ping` and `ws.close` work the same as on an
[`http.WebSocket`](../../apidocs/#http.WebSocket) in a handler. See the [server WebSocket
page](../server/websocket.md). `ws.deinit()` drops the connection without sending a close message.
Call `ws.close` first, as the example does.

`wss://` URLs connect over TLS and use the client's [TLS settings](configuration.md#tls).

## Options

The second argument to `connectWebSocket` holds the options. `.headers` are sent with the upgrade
request, for example an `Authorization` header. `.unix_socket_path` connects over a Unix socket
instead of TCP.

## Next Steps

- [Configuration](configuration.md) covers the client settings.
