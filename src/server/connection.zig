const std = @import("std");
const tls = @import("tls");
const build_options = @import("build_options");

/// Owns the reader/writer (and, for TLS, the whole TLS + underlying TCP
/// layer), plus the arena backing their buffers, for one accepted
/// connection. Initialized in place: `tls_conn` stores pointers into
/// `tcp_reader`/`tcp_writer`, and `tls_reader`/`tls_writer` store a pointer
/// back into `tls_conn`, so a `Connection` must never be moved after
/// `initPlain`/`initTls` runs.
pub const Connection = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    arena: std.heap.ArenaAllocator = undefined,

    tcp_reader: std.Io.net.Stream.Reader = undefined,
    tcp_writer: std.Io.net.Stream.Writer = undefined,
    write_buffer: [4096]u8 = undefined,

    // TLS layer: tcp_reader/tcp_writer above carry ciphertext; tls_conn wraps
    // them, and tls_reader/tls_writer expose the cleartext Reader/Writer used
    // for HTTP I/O.
    tls_conn: ?tls.Connection = null,
    tls_rng: std.Random.IoSource = undefined,
    tls_cleartext_write_buffer: [4096]u8 = undefined,
    tls_reader: tls.Connection.Reader = undefined,
    tls_writer: tls.Connection.Writer = undefined,

    // Active reader/writer, whichever path is in use.
    reader: *std.Io.Reader = undefined,
    writer: *std.Io.Writer = undefined,

    pub fn initPlain(self: *Connection, allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream) void {
        self.* = .{ .io = io, .stream = stream };
        self.arena = .init(allocator);
        self.tcp_reader = stream.reader(io, &.{});
        self.tcp_writer = stream.writer(io, &self.write_buffer);
        self.reader = &self.tcp_reader.interface;
        self.writer = &self.tcp_writer.interface;
    }

    pub fn initTls(
        self: *Connection,
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
        request_buffer_size: usize,
        auth: *tls.config.CertKeyPair,
    ) !void {
        self.* = .{ .io = io, .stream = stream };
        self.arena = .init(allocator);

        // Aim for a single backing allocation per connection: prime the
        // arena with room for the two TLS record buffers plus a working
        // budget, then recycle it (reset keeps the memory). The TLS buffers
        // and the per-request arena are then carved from that one
        // allocation; only unusually large requests grow it.
        const conn_reserve = tls.input_buffer_len + tls.output_buffer_len + 2 * (request_buffer_size + 1024);
        _ = try self.arena.allocator().alloc(u8, conn_reserve);
        _ = self.arena.reset(.retain_capacity);

        // The TLS record buffers live for the whole connection (the
        // tls.Connection points into them) and must survive the per-request
        // arena resets, so they come from the connection arena.
        const tcp_read_buffer = try self.arena.allocator().alloc(u8, tls.input_buffer_len);
        const tcp_write_buffer = try self.arena.allocator().alloc(u8, tls.output_buffer_len);

        self.tcp_reader = stream.reader(io, tcp_read_buffer);
        self.tcp_writer = stream.writer(io, tcp_write_buffer);
        self.tls_rng = .{ .io = io };
        self.tls_conn = try tls.server(&self.tcp_reader.interface, &self.tcp_writer.interface, .{
            .auth = auth,
            .now = std.Io.Clock.real.now(io),
            .rng = self.tls_rng.interface(),
        });
        self.tls_reader = self.tls_conn.?.reader(&.{});
        self.tls_writer = self.tls_conn.?.writer(&self.tls_cleartext_write_buffer);
        self.reader = &self.tls_reader.interface;
        self.writer = &self.tls_writer.interface;
    }

    /// For tests: wraps a bare writer with no real TLS/TCP layer behind it.
    /// `tcp_writer.err` is left settable so a test can simulate the real
    /// error a write failure should surface.
    pub fn initWriterForTesting(self: *Connection, w: *std.Io.Writer) void {
        self.* = .{ .io = undefined, .stream = undefined, .reader = undefined, .writer = w };
        self.tcp_reader.err = null;
        self.tcp_writer.err = null;
    }

    pub fn deinit(self: *Connection) void {
        self.arena.deinit();
    }

    // tls.zig records `TransportReadFailed`/`TransportWriteFailed` when the
    // layer below it failed, because all it saw was the ciphertext
    // reader/writer's generic error; the real cause is on the TCP layer.
    // So those two mean "keep descending". A TLS-level failure (bad record
    // mac, bad version, ...) is recorded as itself and stops the search.

    fn checkReadError(self: *Connection) !void {
        if (build_options.use_tls) {
            if (self.tls_conn != null) {
                if (self.tls_reader.err) |e| if (e != error.TransportReadFailed) return e;
            }
        }
        if (self.tcp_reader.err) |e| return e;
    }

    /// The real error behind a generic `error.ReadFailed`, if any was recorded.
    pub fn getReadError(self: *Connection) ?@typeInfo(@TypeOf(checkReadError(self))).error_union.error_set {
        if (checkReadError(self)) |_| return null else |e| return e;
    }

    fn checkWriteError(self: *Connection) !void {
        if (build_options.use_tls) {
            if (self.tls_conn != null) {
                if (self.tls_writer.err) |e| if (e != error.TransportWriteFailed) return e;
            }
        }
        if (self.tcp_writer.err) |e| return e;
    }

    /// The error type `getWriteError` yields.
    pub const WriteError = @typeInfo(@TypeOf(checkWriteError(undefined))).error_union.error_set;

    /// The real error behind a generic `error.WriteFailed`, if any was
    /// recorded.
    pub fn getWriteError(self: *Connection) ?@typeInfo(@TypeOf(checkWriteError(self))).error_union.error_set {
        if (checkWriteError(self)) |_| return null else |e| return e;
    }

    /// True when `err` means the peer is gone rather than something being
    /// wrong. Teardown is the same either way; this only decides whether the
    /// connection is worth a log line and whether shutdown() is worth a
    /// syscall.
    pub fn isPeerGone(err: anyerror) bool {
        return switch (err) {
            error.EndOfStream,
            // Peer closed the transport between TLS records without
            // close_notify. Rude, but routine from clients that just close
            // the socket. `TlsTruncated`, where a record was cut in half, is
            // deliberately not here.
            error.TlsUnexpectedEof,
            error.ConnectionResetByPeer,
            error.BrokenPipe,
            => true,
            else => false,
        };
    }
};

/// A Connection with no real transport, in TLS mode, so the error accessors
/// can be driven directly. Only the `err` fields are read.
fn testTlsConnection() Connection {
    var conn: Connection = undefined;
    conn.initWriterForTesting(undefined);
    conn.tls_conn = .{ .input = undefined, .output = undefined, .cipher = undefined };
    conn.tls_reader.err = null;
    conn.tls_writer.err = null;
    return conn;
}

test "Connection: error accessors descend past the TLS layer's generic error" {
    if (!build_options.use_tls) return error.SkipZigTest;

    { // a transport write failure: TLS records WriteFailed, TCP has the cause
        var conn = testTlsConnection();
        conn.tls_writer.err = error.TransportWriteFailed;
        conn.tcp_writer.err = error.ConnectionResetByPeer;
        try std.testing.expectEqual(error.ConnectionResetByPeer, conn.getWriteError().?);
    }
    { // same on the read side
        var conn = testTlsConnection();
        conn.tls_reader.err = error.TransportReadFailed;
        conn.tcp_reader.err = error.Canceled;
        try std.testing.expectEqual(error.Canceled, conn.getReadError().?);
    }
}

test "Connection: a TLS-level failure is reported as itself" {
    if (!build_options.use_tls) return error.SkipZigTest;

    { // not a transport failure, so there is nothing below to descend to
        var conn = testTlsConnection();
        conn.tls_reader.err = error.TlsBadRecordMac;
        conn.tcp_reader.err = error.ConnectionResetByPeer;
        try std.testing.expectEqual(error.TlsBadRecordMac, conn.getReadError().?);
    }
    { // and with nothing recorded anywhere there is no error to report
        var conn = testTlsConnection();
        try std.testing.expectEqual(@as(?anyerror, null), conn.getWriteError());
    }
}

test "Connection: isPeerGone separates a departed peer from a real failure" {
    try std.testing.expect(Connection.isPeerGone(error.EndOfStream));
    try std.testing.expect(Connection.isPeerGone(error.ConnectionResetByPeer));
    // Closed between records: nothing was in flight, nothing was lost.
    try std.testing.expect(Connection.isPeerGone(error.TlsUnexpectedEof));
    // Closed mid-record: a record was cut, which is worth hearing about.
    try std.testing.expect(!Connection.isPeerGone(error.TlsTruncated));
    try std.testing.expect(!Connection.isPeerGone(error.TlsBadRecordMac));
    try std.testing.expect(!Connection.isPeerGone(error.Canceled));
}
