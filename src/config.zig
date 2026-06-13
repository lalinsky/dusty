const std = @import("std");

pub const ServerConfig = struct {
    timeout: Timeout = .{},
    request: Request = .{},
    listen: std.Io.net.IpAddress.ListenOptions = .{ .reuse_address = true, .kernel_backlog = 1024 },
    /// TLS configuration. When set, the server performs a TLS handshake on every
    /// accepted connection and speaks HTTPS. Requires the `use_tls` build option
    /// (enabled by default); with TLS compiled out, setting this fails listen().
    tls: ?Tls = null,

    pub const Tls = struct {
        /// Path to the PEM certificate (chain) file, resolved against `dir`.
        cert_path: []const u8,
        /// Path to the PEM private key file, resolved against `dir`.
        key_path: []const u8,
        /// Directory the cert/key paths are resolved against. Defaults to the
        /// current working directory.
        dir: ?std.Io.Dir = null,
    };

    pub const Timeout = struct {
        /// Maximum time to receive a complete request
        request: ?std.Io.Duration = null,
        /// Maximum time to keep idle connections open
        keepalive: ?std.Io.Duration = null,
        /// Maximum number of requests per keepalive connection
        request_count: ?usize = null,
    };

    pub const Request = struct {
        /// Maximum size (bytes) for request body
        max_body_size: usize = 1_048_576, // 1MB default
        /// Buffer size (bytes) for reading request headers
        buffer_size: usize = 4096,
        /// Maximum number of headers allowed in a request
        max_header_count: usize = 32,
        /// Maximum number of route parameters (e.g., /user/:id/:action)
        max_param_count: usize = 8,
        /// Maximum number of query string parameters
        max_query_count: usize = 32,
        /// Maximum number of form fields (application/x-www-form-urlencoded)
        max_form_count: usize = 32,
        /// Maximum number of multipart form fields
        max_multiform_count: usize = 32,
    };
};
