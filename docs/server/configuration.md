# Configuration

The third argument to `http.Server(App).init` is an
[`http.ServerConfig`](../../apidocs/#http.ServerConfig). Every field has a default, so you only set
the ones you want to change:

```zig
--8<-- "examples/configuration.zig:config"
```

This server listens on port 8080 on all interfaces, gives each request 60 seconds, and accepts
bodies up to 10 MiB.

## Listeners

`listeners` is the list of addresses the server accepts connections on. If you don't set it, the
server listens on `127.0.0.1:8080`. One server can listen on several addresses, with TLS on some of
them:

```zig
--8<-- "examples/configuration.zig:listeners"
```

This server accepts HTTPS on port 8443, plain HTTP on port 8080, and plain HTTP on a Unix socket.
`req.secure` tells a handler whether the request came over TLS.

### TLS

A listener with `.tls` set serves only TLS. The certificate and key are PEM files, with the
certificate chain leaf first. The key has to be PKCS#8 or an EC key, and it can't have a passphrase.
They are loaded when the server starts. `.bytes` instead of `.file` takes them from memory.

`.client_auth` asks clients for a certificate and checks it against the authorities in `.ca`:

```zig
.tls = .{
    .certificate = .{ .file = .{ .cert_path = "cert.pem", .key_path = "key.pem" } },
    .client_auth = .{ .ca = .{ .file = .{ .path = "clients-ca.pem" } } },
},
```

Clients without a valid certificate can't connect. With `.mode = .request`, clients that don't send
one are let in too.

See [`http.Listener`](../../apidocs/#http.Listener) for the other listener options.

## Timeouts

| Field | Default | Description |
|---|---|---|
| `timeout.request` | 30 s | Time to read the request and send the response, handler included |
| `timeout.keepalive` | 30 s | How long an idle connection is kept open |
| `timeout.request_count` | none | How many requests one connection can make |
| `timeout.shutdown` | 30 s | How long a graceful shutdown waits for open connections |

`null` turns a timeout off. A handler can change its own request timeout with `req.setTimeout`.

## Limits

| Field | Default | Description |
|---|---|---|
| `max_connections` | 10,000 | Most connections open at once |
| `request.max_body_size` | 1 MiB | Largest request body |
| `request.buffer_size` | 16 KiB | Largest request line and headers, together |
| `request.max_header_count` | 64 | Most headers in a request |
| `request.max_param_count` | 8 | Most path parameters |
| `request.max_query_count` | 32 | Most query parameters |
| `request.max_form_count` | 32 | Most form fields |
| `request.max_multiform_count` | 32 | Most multipart fields |

A body over `max_body_size` gets 413. A request with too many headers gets 431. At
`max_connections`, the server stops accepting connections until one closes.

## Behind a Proxy

Behind a reverse proxy, the socket peer is the proxy. Set `trusted_proxy_hops` to the number of
proxies in front of the server. `req.remote_address` then comes from the `X-Forwarded-For` header.
Only set it when clients can't reach the server except through the proxies. Otherwise they can put
any address they want in the header.

## Next Steps

- [Deployment](deployment.md) covers running the server in production.
