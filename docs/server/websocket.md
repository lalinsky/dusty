# WebSocket

`res.upgradeWebSocket(req)` turns a request into a WebSocket connection. It returns null if the
request isn't a valid upgrade request, and the handler can answer it as a normal request.

After the upgrade, the handler reads messages with `ws.receive()` and sends them with
`ws.send(.text, data)`. When the other side closes the connection, `receive` returns a message of
type `.close`. Call `ws.deinit()` when you're done. The client side is `http.WebSocketClient`.
