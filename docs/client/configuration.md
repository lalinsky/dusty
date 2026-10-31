# Configuration

The third argument to `http.Client.init` is an
[`http.ClientConfig`](../../apidocs/#http.ClientConfig). Its settings are the defaults for every
request the client makes:

```zig
var client = http.Client.init(gpa, io, .{
    .timeout = .fromSeconds(10),
    .max_idle_connections = 16,
    .user_agent = "my-app/1.0",
});
```

| Field | Default | Description |
|---|---|---|
| `timeout` | 30 s | Time limit for a whole `fetch`, redirects included |
| `max_redirects` | 10 | Most redirects `fetch` follows |
| `max_response_size` | 10 MiB | Largest body read into memory |
| `max_idle_connections` | 8 | Most idle connections kept in the pool (`0` turns pooling off) |
| `user_agent` | `dusty/X.Y.Z` | Sent unless the request sets its own `User-Agent` (`null` turns it off) |
| `buffer_size` | 16 KiB | Largest response status line and headers, together |
| `max_response_header_count` | 64 | Most headers in a response |

See [`http.ClientConfig`](../../apidocs/#http.ClientConfig) for the other settings.

## TLS

For HTTPS, the client checks the server's certificate against the system's trusted certificates.
`tls.ca` replaces them with certificates you choose. `tls.client_certificate` is the certificate the
client presents to servers that ask for one:

```zig
var client = http.Client.init(gpa, io, .{
    .tls = .{
        .ca = .{ .file = .{ .path = "internal-ca.pem" } },
        .client_certificate = .{ .file = .{ .cert_path = "client.pem", .key_path = "client-key.pem" } },
    },
});
```

The TLS settings can't change per request, because connections are pooled. Use a second client if
you need different TLS settings.

`tls.insecure_skip_verify = true` accepts any certificate. Use it only for testing. Anyone between
you and the server can then read and change the traffic.

## Unix Sockets

To talk to a service on a Unix socket, like the Docker daemon, pass `.unix_socket_path` to `fetch`:

```zig
var response = try client.fetch("http://localhost/v1.41/info", .{
    .unix_socket_path = "/var/run/docker.sock",
});
defer response.deinit();
```

The URL still sets the request path and the `Host` header.

## Next Steps

- [Making Requests](requests.md) covers the options for a single request.
