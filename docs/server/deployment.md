# Deployment

For production, run the server on [zio](https://lalinsky.github.io/zio/). It runs each connection
as a coroutine, and many coroutines share one OS thread. With `std.Io.Threaded`, every connection holds an OS thread of
its own, plus a second one while timeouts are enabled, and a handler waiting on a database keeps its
thread busy until the answer comes back.

Behind a reverse proxy, `req.remote_address` is the proxy's address. Set `trusted_proxy_hops` to the
number of proxies in front of the server, and the client's address is taken from `X-Forwarded-For`
instead. Only do that if the server can't be reached except through those proxies, because a client
can send the header itself.
