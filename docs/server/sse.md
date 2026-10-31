# Server-Sent Events

Server-Sent Events let a handler keep the response open and send events to the browser as they
happen. This handler counts down from 10, one event a second:

```zig
--8<-- "examples/sse.zig:countdown"
```

[`res.startEventStream`](../../apidocs/#http.Response.startEventStream) sends the headers for an
event stream and returns an [`http.EventStream`](../../apidocs/#http.EventStream). Each `send` sends
one event to the client right away. The response ends when the handler returns.

`buf` is where each event is put together before it's sent. Make it big enough for a normal event,
so each one goes out in a single write.

In the browser, an `EventSource` gets the events:

```js
const source = new EventSource("/countdown");
source.addEventListener("tick", (e) => console.log(e.data));
source.addEventListener("done", () => source.close());
```

Without the `close`, the browser reconnects when the stream ends, and the countdown starts over.

## Event Fields

The second argument to `send` sets the other fields of the event:

- `.event` is the event type. The browser's `EventSource` uses it to pick the listener.
- `.id` is the event ID. A browser that reconnects sends the last one it got in the
  `Last-Event-ID` header.
- `.retry` tells the browser how many milliseconds to wait before it reconnects.

## Writing an Event in Pieces

`startSend` opens an event and gives you a writer for its data. Use it when the data comes from a
formatter or a serializer:

```zig
--8<-- "examples/sse.zig:writer"
```

Call `end` when the event is done, before you send the next one.

## When the Client Goes Away

When the client closes the connection, a later `send` returns an error. Return it from the handler
to end the request.

## Timeouts

The request timeout covers the whole stream. It's 30 seconds by default. Long streams turn it off
with `req.setTimeout(.none)`, as the countdown handler does. If a stream should stop after a fixed
time, set a timeout that long instead.

On shutdown, the server waits for streams that are still open, like any other request. It waits up
to `timeout.shutdown`, 30 seconds by default, and then cancels them. See
[Deployment](deployment.md) for more about shutting down.

## Next Steps

- [WebSocket](websocket.md) covers connections where the client sends messages too.
- [Configuration](configuration.md) covers the timeouts.
