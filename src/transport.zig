//! The rule every layer in this library follows, stated once here because
//! Zig will not enforce it and because this is where the descent it
//! describes is implemented:
//!
//!   A `std.Io.Reader` or `std.Io.Writer` the public API hands out must be
//!   reachable *through* something that also gives the caller the real
//!   cause.
//!
//! The interfaces themselves cannot carry one: their error sets are fixed at
//! `ReadFailed`/`WriteFailed` by the vtable, and those name nothing a caller
//! can act on.
//!
//! In practice that is one shape, everywhere -- a small wrapper, passed
//! around by value, with the interface to use and the cause beside it:
//!
//!   pub const X = struct {
//!       interface: std.Io.Reader,  // or Writer
//!       err: ?Error = null,        // what a failed read or write was
//!   };
//!
//! None of them carries its own buffer. Where bytes have to wait between
//! the caller and the connection, the caller passes the buffer in --
//! `Request.reader`, `ClientResponse.reader`, `Response.stream`,
//! `Response.startEventStream` -- and where they do not, because the
//! response arena or the stream below is already the buffer, there is none
//! at all. On a chunked body that buffer is also the chunk size, which is
//! another reason it is not ours to pick.
//!
//! `BodyReader` (`parser.zig`) and `BodyWriter`, `StreamingBodyWriter` and
//! `EventWriter` (`response.zig`) are all this. `WebSocket` and
//! `EventStream` hand out no interface at all and resolve inside `send` /
//! `receive`, which is the same promise kept a different way. `Transport`
//! and `Connection` expose a bare interface with accessors beside it, which
//! is allowed only because nothing sits above them to lose the answer.
//!
//! "Resolved" is the load-bearing word. An `err` holding a sentinel is no
//! better than the sentinel, and layers do record sentinels: tls.zig stores
//! `TransportReadFailed` when the layer below it failed, and
//! `std.compress.flate.Decompress` stores `error.ReadFailed` for the same
//! reason. Both mean "keep descending". So the code that reads them switches
//! past them rather than comparing, which drops them from the inferred error
//! set as well as from the answer -- making it true by construction that
//! what a caller is handed names a cause.
//!
//! A new layer added above an existing one inherits the obligation: resolve
//! through everything below it, or the answer stops at the wrapper. The
//! guard tests spread across these files walk every wrapper's `Error` and
//! fail at compile time if a sentinel is in one.

const std = @import("std");
const tls = @import("tls");
const build_options = @import("build_options");

/// A borrowed view of one connection's reader/writer stack: the interfaces
/// HTTP is spoken over, and the concrete layers beneath them that record why
/// a read or write failed.
///
/// A view rather than an owner, because the two ends of the library build the
/// stack differently -- the server carves its buffers from a per-connection
/// arena and runs `tls.server`, the client allocates them and runs
/// `tls.client` with ALPN -- while "what actually failed" has one answer for
/// both. Anything shared between the ends, such as `WebSocket`, can hold this
/// where it could hold neither `Connection`.
///
/// It borrows from whatever owns the layers and must not outlive it.
pub const Transport = struct {
    /// What HTTP is read and written through: the socket's own interfaces on
    /// a plain connection, the TLS layer's cleartext ones otherwise.
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,

    /// The socket. On a TLS connection it carries ciphertext, and it is where
    /// a transport failure is recorded.
    ///
    /// Optional so a test can drive the layers above over a plain `.fixed`
    /// reader and writer, with nothing beneath them to record a cause -- the
    /// same shape as a writer that failed without one, which resolves to
    /// `Unexpected` rather than needing a socket to fake.
    tcp_reader: ?*std.Io.net.Stream.Reader = null,
    tcp_writer: ?*std.Io.net.Stream.Writer = null,

    /// The TLS layer, on a connection that has one.
    tls_reader: ?*tls.Connection.Reader = null,
    tls_writer: ?*tls.Connection.Writer = null,

    // tls.zig records `TransportReadFailed`/`TransportWriteFailed` when the
    // layer below it failed, because all it saw was the ciphertext
    // reader/writer's generic error; the real cause is on the TCP layer.
    // So those two mean "keep descending". A TLS-level failure (bad record
    // mac, bad version, ...) is recorded as itself and stops the search.
    //
    // They are switched on rather than compared so that they drop out of
    // the inferred error set as well as out of the answer: like the
    // `ReadFailed`/`WriteFailed` they stand in for, they name no cause a
    // caller could act on, and nothing that descends past them can return one.

    fn checkReadError(self: Transport) !void {
        if (build_options.use_tls) {
            if (self.tls_reader) |tls_reader| {
                if (tls_reader.err) |e| switch (e) {
                    // Keep descending: the cause is on the TCP layer below.
                    error.TransportReadFailed => {},
                    else => |cause| return cause,
                };
            }
        }
        if (self.tcp_reader) |tcp_reader| {
            if (tcp_reader.err) |e| return e;
        }
    }

    /// The error type `getReadError` yields.
    pub const ReadError = @typeInfo(@TypeOf(checkReadError(undefined))).error_union.error_set;

    /// The real error behind a generic `error.ReadFailed`, if any was recorded.
    pub fn getReadError(self: Transport) ?ReadError {
        if (checkReadError(self)) |_| return null else |e| return e;
    }

    fn checkWriteError(self: Transport) !void {
        if (build_options.use_tls) {
            if (self.tls_writer) |tls_writer| {
                if (tls_writer.err) |e| switch (e) {
                    // Keep descending: the cause is on the TCP layer below.
                    error.TransportWriteFailed => {},
                    else => |cause| return cause,
                };
            }
        }
        if (self.tcp_writer) |tcp_writer| {
            if (tcp_writer.err) |e| return e;
        }
    }

    /// The error type `getWriteError` yields.
    pub const WriteError = @typeInfo(@TypeOf(checkWriteError(undefined))).error_union.error_set;

    /// The real error behind a generic `error.WriteFailed`, if any was
    /// recorded.
    pub fn getWriteError(self: Transport) ?WriteError {
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

test "Transport: no std.Io sentinel escapes a resolved error set" {
    // The rule at the top of this file, checked. Everything above the
    // transport resolves through these two, so a sentinel surviving here
    // would survive everywhere.
    inline for (.{ Transport.ReadError, Transport.WriteError }) |Set| {
        inline for (@typeInfo(Set).error_set.?) |e| {
            try std.testing.expect(!std.mem.eql(u8, e.name, "ReadFailed"));
            try std.testing.expect(!std.mem.eql(u8, e.name, "WriteFailed"));
            // The sentinels tls.zig stands in for them with, which mean
            // "keep descending" and are equally useless to a caller.
            try std.testing.expect(!std.mem.eql(u8, e.name, "TransportReadFailed"));
            try std.testing.expect(!std.mem.eql(u8, e.name, "TransportWriteFailed"));
        }
    }
}
