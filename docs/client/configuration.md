# Configuration

!!! warning "Draft"

    This page is a draft. Still to cover:

    - `tls.ca` options, `insecure_skip_verify` for testing
    - `http2` option
    - `buffer_size` and `max_response_header_count`
    - Sharing one client between tasks

The third argument to `http.Client.init` is an `http.ClientConfig`. Its settings apply to every
request the client makes.

```zig
var client = http.Client.init(gpa, io, .{
    .timeout = .fromSeconds(10),
    .max_idle_connections = 16,
});
```

`max_idle_connections` is how many connections the pool keeps open, 8 by default, and 0 turns
pooling off. `user_agent` is sent with every request unless the request has its own `User-Agent`.

For HTTPS, the server's certificate is checked against the system's trusted certificates. `tls.ca`
picks other certificates to trust, and `tls.client_certificate` is a certificate of your own to
present. TLS settings can't change per request, because connections are pooled.

To talk to a service on a Unix socket, like the Docker daemon, pass `.unix_socket_path` to `fetch`.
The URL still gives the path and the `Host` header.
