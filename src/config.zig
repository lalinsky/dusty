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

pub const Address = union(enum) {
    ip: std.Io.net.IpAddress,
    unix: std.Io.net.UnixAddress,

    pub fn format(self: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .ip => |ip| try ip.format(w),
            .unix => |unix| try w.writeAll(unix.path),
        }
    }
};

/// One socket a server accepts on. `ServerConfig.listen` holds any number,
/// each with its own TLS, so one server can serve HTTPS on 443 and plain
/// HTTP on 80.
pub const Listener = struct {
    address: Address,
    /// When set, every connection accepted here is TLS. Requires the
    /// `use_tls` build option (enabled by default); with TLS compiled out,
    /// setting this fails `Server.run`.
    tls: ?ServerConfig.Tls = null,
    /// How many connections the kernel accepts on the server's behalf
    /// while it is not accepting itself. Past this, clients see the
    /// connection refused.
    kernel_backlog: u31 = 1024,
    /// Sets SO_REUSEADDR (and SO_REUSEPORT on POSIX) on an IP listener.
    reuse_address: bool = true,
    /// How many accept loops share the socket. With io_uring, an accept
    /// completes at most once per trip through the event loop, so a single
    /// loop takes one connection per trip however many are queued, which
    /// limits a server taking many short connections. Several accepts
    /// waiting together let one trip take several. An idle one costs a
    /// parked task, and on Windows a socket created ahead for the
    /// connection it will get. Zero is taken as one.
    acceptors: u16 = 2,
    /// Gives each accept loop a socket of its own instead of sharing one,
    /// all bound to the same address with SO_REUSEPORT, so the kernel
    /// spreads connections over as many accept queues as there are loops.
    /// That scales further than a shared queue when nearly every request
    /// comes on a new connection. The kernel picks a socket by hashing the
    /// connection, not by which loop is free, so a busy loop keeps getting
    /// its share and tail latency is worse under load; and a connection
    /// still queued on a socket when it closes is reset rather than handed
    /// to another. Linux only, and needs an IP address with
    /// `reuse_address` set.
    socket_per_acceptor: bool = false,
};

pub const ServerConfig = struct {
    timeout: Timeout = .{},
    request: Request = .{},
    /// Where the server accepts connections. `Server.run` serves all of
    /// them and refuses an empty list. Borrowed for the server's life, and
    /// requests point back into it through `Request.listener`.
    listen: []const Listener = &.{},
    /// Number of reverse-proxy hops between the server and the client. Zero
    /// reports the socket peer and ignores `X-Forwarded-For`. A positive
    /// value selects that address from the right of the forwarding chain:
    /// one trusts the directly connected proxy, two trusts it and the proxy
    /// before it, and so on.
    ///
    /// Only enable this when the server is unreachable except through that
    /// many trusted proxies. Otherwise a client can supply the header itself
    /// and choose the address reported to handlers.
    trusted_proxy_hops: usize = 0,
    /// How many connections may be open at once. At the cap the server stops
    /// accepting; what arrives meanwhile waits in the kernel's accept queue,
    /// `Listener.kernel_backlog` deep. Null lifts the cap.
    ///
    /// Costs about `request.buffer_size + 13K` per connection, 33K more
    /// under TLS, and 70K more for a connection that receives a body with a
    /// `Content-Encoding` while `request.decompress` is on.
    max_connections: ?u32 = 10_000,
    /// TLS is per listener: see `Listener.tls`.
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
        ///
        /// Which is the limit worth enforcing, but note what it costs: a
        /// connection can hold this much in its arena, and a compressed
        /// request reaches it for a fraction of the bytes on the wire. Size
        /// memory for `max_connections` of these, not for what a peer has
        /// to send to get one.
        max_body_size: usize = 1_048_576, // 1MB default
        /// Undo `Content-Encoding` on request bodies. A coding we cannot
        /// undo fails the read with `error.UnsupportedContentEncoding`
        /// rather than handing the handler bytes it would misread.
        ///
        /// Turn off to read what the wire carried, whatever it is;
        /// `Request.content_encoding` says what that was.
        ///
        /// Costs about 70K from the connection's arena -- a 64K sliding
        /// window and the decoder -- on the connections that actually
        /// receive a coded body, and only once each.
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
    try std.testing.expectEqual(@as(usize, 0), cfg.trusted_proxy_hops);
}
