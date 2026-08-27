const std = @import("std");

/// Where a TLS peer's certificate authorities are loaded from. Shared by the
/// client (verifying server certificates) and the server (verifying client
/// certificates under mutual TLS).
pub const TlsCa = union(enum) {
    /// The platform trust store.
    system,
    /// A single PEM file holding one or more certificates.
    file: TlsPath,
    /// A directory of PEM files, each holding one or more certificates.
    dir: TlsPath,
    /// Trust nothing. Rejected unless the side using it says otherwise.
    none,

    /// Reads the certificates into a fresh bundle owned by the caller.
    pub fn load(self: TlsCa, allocator: std.mem.Allocator, io: std.Io) !std.crypto.Certificate.Bundle {
        const now = std.Io.Clock.real.now(io);

        var bundle: std.crypto.Certificate.Bundle = .empty;
        errdefer bundle.deinit(allocator);
        switch (self) {
            .system => try bundle.rescan(allocator, io, now),
            .file => |src| try bundle.addCertsFromFilePath(
                allocator,
                io,
                now,
                src.dir orelse std.Io.Dir.cwd(),
                src.path,
            ),
            .dir => |src| try bundle.addCertsFromDirPath(
                allocator,
                io,
                src.dir orelse std.Io.Dir.cwd(),
                src.path,
            ),
            .none => {},
        }
        return bundle;
    }
};

/// Kept free past the head in a connection's read buffer, which is sized
/// `buffer_size + body_read_reserve`. `parseHeaders` gives the body reader
/// whatever the head did not use, and a body reader with no buffer cannot
/// read; refusing a head that would eat into this is what makes it a reserve
/// rather than a hope.
pub const body_read_reserve = 1024;

pub const TlsPath = struct {
    path: []const u8,
    /// Directory `path` is resolved against. Defaults to the current working
    /// directory.
    dir: ?std.Io.Dir = null,
};

pub const ServerConfig = struct {
    timeout: Timeout = .{},
    request: Request = .{},
    listen: std.Io.net.IpAddress.ListenOptions = .{ .reuse_address = true, .kernel_backlog = 1024 },
    /// How many connections may be open at once. At the cap the server stops
    /// accepting; what arrives meanwhile waits in the kernel's accept queue,
    /// `listen.kernel_backlog` deep. Null lifts the cap.
    ///
    /// Costs about `request.buffer_size + 8K` per connection, 33K more under
    /// TLS.
    max_connections: ?u32 = 10_000,
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
        /// Ask connecting clients to authenticate with a certificate (mutual
        /// TLS). Null means client certificates are never requested.
        client_auth: ?ClientAuth = null,

        pub const ClientAuth = struct {
            /// Certificate authorities used to verify client certificates.
            /// `.none` is rejected by listen().
            ca: TlsCa,
            /// `.require` rejects a client that sends no certificate;
            /// `.request` asks for one but accepts an empty reply.
            mode: Mode = .require,

            pub const Mode = enum { request, require };
        };
    };

    pub const Timeout = struct {
        /// Maximum time to complete a request, including handler work and the
        /// response. TLS handshakes use the same timeout as a separate phase.
        /// Defaults to 30 seconds; set to null for long-lived handlers, or
        /// replace it from a handler with `Request.setTimeout`.
        ///
        /// Costs a second task per connection on any backend but zio, so on
        /// `std.Io.Threaded` setting either timeout means two threads per
        /// connection.
        request: ?std.Io.Duration = .fromSeconds(30),
        /// Maximum time to keep idle connections open. Defaults to 60 seconds;
        /// set to null to keep them open indefinitely.
        keepalive: ?std.Io.Duration = .fromSeconds(60),
        /// Maximum number of requests per keepalive connection
        request_count: ?usize = null,
        /// Maximum time a graceful shutdown waits for the connections still
        /// in flight. Null waits for all of them, however long they take --
        /// which for a connection that never closes on its own, such as a
        /// WebSocket or an event stream, is forever.
        shutdown: ?std.Io.Duration = .fromSeconds(30),
    };

    pub const Request = struct {
        /// Maximum size (bytes) for request body. Applies to the body a
        /// handler sees, so for a compressed request it bounds what was
        /// decoded rather than what arrived.
        max_body_size: usize = 1_048_576, // 1MB default
        /// Undo `Content-Encoding` on request bodies. Turn off to read what
        /// the wire carried; `Request.content_encoding` says what that is.
        /// A coding we cannot undo fails the read with
        /// `error.UnsupportedContentEncoding` either way.
        ///
        /// Costs a 64K sliding window from the connection's arena, on the
        /// connections that actually receive a coded body and only once each.
        decompress: bool = true,
        /// Buffer size (bytes) for reading the request head: the request
        /// line and all headers. This is also the limit on it -- the parsed
        /// header names and values are slices into this buffer rather than
        /// copies, so the head is held whole and cannot be read in pieces.
        /// A head that does not fit is answered with 431.
        buffer_size: usize = 16384,
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

test "ServerConfig: connection timeouts are finite by default" {
    const cfg: ServerConfig = .{};
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(30), cfg.timeout.request.?);
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(60), cfg.timeout.keepalive.?);
}
