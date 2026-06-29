//! HTTP/2 client support, built on the vendored nghttp2 (src/nghttp2). nghttp2
//! is a pure, I/O-free protocol state machine: we feed it bytes read from the
//! socket via `nghttp2_session_mem_recv2`, it invokes our callbacks to surface
//! headers/data/stream events, and we pull bytes to write via
//! `nghttp2_session_mem_send2`.
//!
//! Concurrency model (the "actor"): one `Connection` owns a single nghttp2
//! session and multiplexes many concurrent request streams over one socket.
//! Two coroutines run per connection:
//!
//!   * the session coroutine is the SOLE caller of every `nghttp2_*` function.
//!     It blocks on one queue (`events`) carrying both inbound socket data and
//!     request submissions, dispatches each, and drains nghttp2's output to the
//!     socket. nghttp2's callbacks (run inside mem_recv on this coroutine) fill
//!     per-stream response state and signal completion.
//!   * the net-reader coroutine is the sole socket reader: it reads ciphertext,
//!     hands the decrypted bytes to the session coroutine via `events`, and
//!     waits for an ack before reading again.
//!
//! Caller coroutines (one per in-flight `fetch`) submit a `Stream` through the
//! queue and block on its `done` event; they never touch the session directly.
//! This keeps the non-reentrant nghttp2 session single-owner without a mutex.
//!
//! Concurrent read (net-reader) and write (session coroutine) touch disjoint
//! TLS cipher state (separate encrypt/decrypt fields), so sharing one
//! tls.Connection across the two coroutines is safe.
//!
//! This file is only compiled when the `use_http2` build option is set; callers
//! must guard `@import("http2.zig")` behind `build_options.use_http2`.

const std = @import("std");

const http = @import("http.zig");
const Method = http.Method;
const Status = http.Status;
const Headers = http.Headers;
const ContentType = http.ContentType;
const ContentEncoding = http.ContentEncoding;
const ParsedResponse = @import("parser.zig").ParsedResponse;

const c = @import("nghttp2");

const log = std.log.scoped(.dusty_h2);

/// Backing capacity of the per-connection event queue. Holds at most one
/// in-flight net_data item plus queued submissions.
const event_queue_cap = 256;

pub const Http2Error = error{
    /// Failed to allocate/initialize an nghttp2 session or callbacks.
    Http2Init,
    /// nghttp2 reported a protocol/session error while processing frames.
    Http2Protocol,
    /// The peer reset our stream (RST_STREAM with a non-zero error code).
    Http2StreamReset,
    /// The peer closed the stream/connection before a complete response.
    Http2IncompleteResponse,
    /// The connection was torn down (GOAWAY, socket error, or shutdown).
    Http2ConnectionClosed,
    /// Response body exceeded the configured maximum size.
    ResponseTooLarge,
};

/// Items carried on a connection's single event queue. Producers are the caller
/// coroutines (`submit`) and the net-reader coroutine (`net_*`); the sole
/// consumer is the session coroutine.
const Event = union(enum) {
    /// A caller wants to start a request on this stream.
    submit: *Stream,
    /// Decrypted bytes from the socket; the slice points into the net-reader's
    /// buffer and stays valid until the session acks via `consumed`.
    net_data: []const u8,
    /// The peer closed the connection cleanly (EOF).
    net_eof,
    /// A socket read error occurred.
    net_err,
};

/// Per-request stream state. Created and owned by the calling coroutine; the
/// request fields are filled before `submit`, the response fields are filled by
/// the session coroutine before `done` is set.
pub const Stream = struct {
    io: std.Io,
    arena: std.mem.Allocator,

    // Request (set by caller before submit).
    method: Method,
    scheme: []const u8,
    authority: []const u8,
    path: []const u8,
    req_headers: ?*const Headers,
    req_body: []const u8 = &.{},
    req_sent: usize = 0,
    /// When set, sent as the "accept-encoding" header (unless the user already
    /// provided one).
    accept_encoding: ?[]const u8 = null,

    // Response (set by the session coroutine).
    parsed: ParsedResponse,
    body: std.ArrayListUnmanaged(u8) = .empty,
    max_body: usize,
    too_large: bool = false,
    alloc_failed: bool = false,
    close_error: u32 = 0,
    err: ?anyerror = null,
    stream_id: i32 = -1,

    /// Set once by the session coroutine when the response is complete (or
    /// failed); awaited by the caller.
    done: std.Io.Event = .unset,
    /// Intrusive node in Connection.streams; touched only by the session coro.
    node: std.DoublyLinkedList.Node = .{},

    fn finish(s: *Stream, err: ?anyerror) void {
        if (err != null and s.err == null) s.err = err;
        s.done.set(s.io);
    }
};

/// A multiplexed HTTP/2 connection. Heap-allocated and never moved (coroutines
/// hold its address). The underlying transport (socket + TLS) is owned by the
/// caller (client.zig); this only borrows `reader`/`writer`.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,

    session: ?*c.nghttp2_session = null,
    callbacks: ?*c.nghttp2_session_callbacks = null,

    events: std.Io.Queue(Event),
    events_buf: [event_queue_cap]Event = undefined,
    /// session -> net-reader ack that the last net_data slice was consumed.
    consumed: std.Io.Event = .unset,
    group: std.Io.Group = .init,

    /// In-flight streams, owned exclusively by the session coroutine.
    streams: std.DoublyLinkedList = .{},

    /// Set true once the connection is unusable (GOAWAY/EOF/error/shutdown).
    /// Read by the pool to decide reuse; written by the session coroutine.
    closed: std.atomic.Value(bool) = .init(false),
    /// Count of in-flight streams, for pool bookkeeping.
    active: std.atomic.Value(usize) = .init(0),

    // Pool key.
    host_buf: [255]u8 = undefined,
    host_len: u8 = 0,
    port: u16 = 0,
    pool_node: std.DoublyLinkedList.Node = .{},

    /// Create and start a multiplexed HTTP/2 connection over the given
    /// (ALPN-negotiated) reader/writer. Spawns the session and net-reader
    /// coroutines.
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        host: []const u8,
        port: u16,
    ) !*Connection {
        const conn = try allocator.create(Connection);
        errdefer allocator.destroy(conn);

        conn.* = .{
            .allocator = allocator,
            .io = io,
            .reader = reader,
            .writer = writer,
            .events = undefined,
        };
        conn.events = .init(&conn.events_buf);

        const host_len: u8 = @intCast(@min(host.len, conn.host_buf.len));
        @memcpy(conn.host_buf[0..host_len], host[0..host_len]);
        conn.host_len = host_len;
        conn.port = port;

        if (c.nghttp2_session_callbacks_new(&conn.callbacks) != 0) return error.Http2Init;
        errdefer c.nghttp2_session_callbacks_del(conn.callbacks);
        c.nghttp2_session_callbacks_set_on_header_callback(conn.callbacks, onHeader);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(conn.callbacks, onDataChunk);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(conn.callbacks, onStreamClose);

        if (c.nghttp2_session_client_new(&conn.session, conn.callbacks, conn) != 0) return error.Http2Init;
        errdefer c.nghttp2_session_del(conn.session);

        // Spawn the two long-lived coroutines. They run until cancelled by
        // deinit() or until a fatal error makes them return.
        conn.group.concurrent(io, sessionLoop, .{conn}) catch return error.Http2Init;
        conn.group.concurrent(io, netReaderLoop, .{conn}) catch {
            // Tear down the already-spawned session coroutine before failing.
            conn.events.close(io);
            conn.group.cancel(io);
            return error.Http2Init;
        };

        return conn;
    }

    /// Stop the coroutines and free the session. The transport (socket/TLS) is
    /// the caller's responsibility.
    pub fn destroy(conn: *Connection) void {
        conn.closed.store(true, .release);
        conn.events.close(conn.io);
        conn.consumed.set(conn.io); // unblock net-reader if waiting on the ack
        conn.group.cancel(conn.io); // cancel + join both coroutines
        if (conn.session) |s| c.nghttp2_session_del(s);
        if (conn.callbacks) |cb| c.nghttp2_session_callbacks_del(cb);
        conn.allocator.destroy(conn);
    }

    pub fn isClosed(conn: *Connection) bool {
        return conn.closed.load(.acquire);
    }

    /// Submit a request on `stream` and block until the response is complete or
    /// the stream fails. The caller owns `stream` and its arena.
    pub fn request(conn: *Connection, stream: *Stream) !void {
        _ = conn.active.fetchAdd(1, .acq_rel);
        conn.events.putOne(conn.io, .{ .submit = stream }) catch {
            _ = conn.active.fetchSub(1, .acq_rel);
            return error.Http2ConnectionClosed;
        };
        stream.done.wait(conn.io) catch |err| {
            // Cancellation while waiting: the session coroutine may still touch
            // the stream, so the caller must not free it here. Mark the
            // connection unusable so it is retired rather than reused.
            conn.closed.store(true, .release);
            return err;
        };
    }

    /// Release a completed stream. Must be called after `request` returns.
    pub fn releaseStream(conn: *Connection, stream: *Stream) void {
        _ = conn.active.fetchSub(1, .acq_rel);
        _ = stream;
    }
};

// ---------------------------------------------------------------------------
// Session coroutine
// ---------------------------------------------------------------------------

fn sessionLoop(conn: *Connection) std.Io.Cancelable!void {
    const io = conn.io;

    submitSettings(conn) catch {
        fatalAll(conn, error.Http2Init);
        return;
    };
    drainSend(conn) catch {
        fatalAll(conn, error.Http2ConnectionClosed);
        return;
    };

    while (true) {
        const ev = conn.events.getOne(io) catch return; // Closed or Canceled
        switch (ev) {
            .submit => |s| handleSubmit(conn, s),
            .net_data => |bytes| {
                const rv = c.nghttp2_session_mem_recv2(conn.session, bytes.ptr, bytes.len);
                conn.consumed.set(io); // let the net-reader toss and read more
                if (rv < 0) {
                    log.debug("mem_recv2 failed: {s}", .{c.nghttp2_strerror(@intCast(rv))});
                    fatalAll(conn, error.Http2Protocol);
                    return;
                }
            },
            .net_eof => {
                fatalAll(conn, error.Http2IncompleteResponse);
                return;
            },
            .net_err => {
                fatalAll(conn, error.Http2ConnectionClosed);
                return;
            },
        }

        drainSend(conn) catch {
            fatalAll(conn, error.Http2ConnectionClosed);
            return;
        };

        // The peer closed the session cleanly (e.g. GOAWAY then no more work).
        if (c.nghttp2_session_want_read(conn.session) == 0 and
            c.nghttp2_session_want_write(conn.session) == 0)
        {
            fatalAll(conn, error.Http2ConnectionClosed);
            return;
        }
    }
}

fn submitSettings(conn: *Connection) !void {
    // Client preface SETTINGS (mandatory, first frame). Disable push and
    // advertise a 1 MiB initial stream window.
    const iv = [_]c.nghttp2_settings_entry{
        .{ .settings_id = @intCast(c.NGHTTP2_SETTINGS_ENABLE_PUSH), .value = 0 },
        .{ .settings_id = @intCast(c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE), .value = 1 << 20 },
    };
    if (c.nghttp2_submit_settings(conn.session, @intCast(c.NGHTTP2_FLAG_NONE), &iv, iv.len) != 0) {
        return error.Http2Init;
    }
}

fn handleSubmit(conn: *Connection, s: *Stream) void {
    const arena = s.arena;

    var nva: std.ArrayListUnmanaged(c.nghttp2_nv) = .empty;
    addNv(&nva, arena, ":method", s.method.name()) catch return s.finish(error.Http2Init);
    addNv(&nva, arena, ":scheme", s.scheme) catch return s.finish(error.Http2Init);
    addNv(&nva, arena, ":authority", s.authority) catch return s.finish(error.Http2Init);
    addNv(&nva, arena, ":path", s.path) catch return s.finish(error.Http2Init);
    var user_has_accept_encoding = false;
    if (s.req_headers) |hs| {
        for (hs.keys[0..hs.len], hs.values[0..hs.len]) |k, v| {
            if (isSkippedHeader(k)) continue;
            if (std.ascii.eqlIgnoreCase(k, "accept-encoding")) user_has_accept_encoding = true;
            const lower = std.ascii.allocLowerString(arena, k) catch return s.finish(error.Http2Init);
            addNv(&nva, arena, lower, v) catch return s.finish(error.Http2Init);
        }
    }
    if (!user_has_accept_encoding) {
        if (s.accept_encoding) |ae| addNv(&nva, arena, "accept-encoding", ae) catch return s.finish(error.Http2Init);
    }

    var data_prd: c.nghttp2_data_provider = .{
        .source = .{ .ptr = s },
        .read_callback = readReqBody,
    };
    const prd_ptr: [*c]const c.nghttp2_data_provider =
        if (s.req_body.len > 0) &data_prd else null;

    const sid = c.nghttp2_submit_request(conn.session, null, nva.items.ptr, nva.items.len, prd_ptr, s);
    if (sid < 0) {
        log.debug("submit_request failed: {s}", .{c.nghttp2_strerror(sid)});
        return s.finish(error.Http2Protocol);
    }
    s.stream_id = sid;
    conn.streams.append(&s.node);
}

fn drainSend(conn: *Connection) !void {
    while (c.nghttp2_session_want_write(conn.session) != 0) {
        var data: [*c]const u8 = undefined;
        const n = c.nghttp2_session_mem_send2(conn.session, &data);
        if (n < 0) return error.Http2Protocol;
        if (n == 0) break;
        try conn.writer.writeAll(data[0..@intCast(n)]);
    }
    try conn.writer.flush();
}

/// Fail every in-flight stream and mark the connection closed.
fn fatalAll(conn: *Connection, err: anyerror) void {
    conn.closed.store(true, .release);
    var it = conn.streams.first;
    while (it) |node| {
        it = node.next;
        const s: *Stream = @fieldParentPtr("node", node);
        conn.streams.remove(node);
        s.finish(err);
    }
}

// ---------------------------------------------------------------------------
// Net-reader coroutine
// ---------------------------------------------------------------------------

fn netReaderLoop(conn: *Connection) std.Io.Cancelable!void {
    const io = conn.io;
    while (true) {
        const buffered = conn.reader.buffered();
        if (buffered.len > 0) {
            conn.events.putOne(io, .{ .net_data = buffered }) catch return; // Closed/Canceled
            conn.consumed.wait(io) catch return;
            conn.consumed.reset();
            conn.reader.toss(buffered.len);
        } else {
            conn.reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    conn.events.putOne(io, .net_eof) catch {};
                    return;
                },
                // ReadFailed also covers cancellation during teardown; the real
                // cause is stashed in the underlying reader. Either way we stop.
                else => {
                    conn.events.putOne(io, .net_err) catch {};
                    return;
                },
            };
        }
    }
}

// ---------------------------------------------------------------------------
// nghttp2 callbacks (run on the session coroutine, inside mem_recv2)
// ---------------------------------------------------------------------------

fn streamFor(session: ?*c.nghttp2_session, stream_id: i32) ?*Stream {
    const ptr = c.nghttp2_session_get_stream_user_data(session, stream_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn onHeader(
    session: ?*c.nghttp2_session,
    frame: [*c]const c.nghttp2_frame,
    name: [*c]const u8,
    namelen: usize,
    value: [*c]const u8,
    valuelen: usize,
    flags: u8,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = flags;
    _ = user_data;
    const s = streamFor(session, frame.*.hd.stream_id) orelse return 0;
    const n = name[0..namelen];
    const v = value[0..valuelen];

    if (n.len > 0 and n[0] == ':') {
        if (std.mem.eql(u8, n, ":status")) {
            const code = std.fmt.parseInt(u16, v, 10) catch return 0;
            if (std.enums.fromInt(Status, code)) |st| s.parsed.status = st;
        }
        return 0;
    }

    // nghttp2's buffers are valid only during this callback; copy before storing.
    const name_copy = s.arena.dupe(u8, n) catch {
        s.alloc_failed = true;
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    };
    const value_copy = s.arena.dupe(u8, v) catch {
        s.alloc_failed = true;
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    };
    s.parsed.headers.add(name_copy, value_copy) catch {}; // ignore overflow
    return 0;
}

fn onDataChunk(
    session: ?*c.nghttp2_session,
    flags: u8,
    stream_id: i32,
    data: [*c]const u8,
    len: usize,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = flags;
    _ = user_data;
    const s = streamFor(session, stream_id) orelse return 0;
    if (s.too_large) return 0;
    if (s.body.items.len + len > s.max_body) {
        s.too_large = true;
        return 0;
    }
    s.body.appendSlice(s.arena, data[0..len]) catch {
        s.alloc_failed = true;
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    };
    return 0;
}

fn onStreamClose(
    session: ?*c.nghttp2_session,
    stream_id: i32,
    error_code: u32,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const conn: *Connection = @ptrCast(@alignCast(user_data.?));
    const s = streamFor(session, stream_id) orelse return 0;
    s.close_error = error_code;
    conn.streams.remove(&s.node);

    var err: ?anyerror = null;
    if (s.alloc_failed) {
        err = error.Http2Init;
    } else if (error_code != 0) {
        err = error.Http2StreamReset;
    } else if (s.too_large) {
        err = error.ResponseTooLarge;
    }
    s.finish(err);
    return 0;
}

fn readReqBody(
    session: ?*c.nghttp2_session,
    stream_id: i32,
    buf: [*c]u8,
    length: usize,
    data_flags: [*c]u32,
    source: [*c]c.nghttp2_data_source,
    user_data: ?*anyopaque,
) callconv(.c) isize {
    _ = session;
    _ = stream_id;
    _ = user_data;
    const s: *Stream = @ptrCast(@alignCast(source.*.ptr.?));
    const remaining = s.req_body[s.req_sent..];
    const n = @min(length, remaining.len);
    if (n > 0) @memcpy(buf[0..n], remaining[0..n]);
    s.req_sent += n;
    if (s.req_sent == s.req_body.len) {
        data_flags.* |= @as(u32, @intCast(c.NGHTTP2_DATA_FLAG_EOF));
    }
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn addNv(
    list: *std.ArrayListUnmanaged(c.nghttp2_nv),
    arena: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
) !void {
    // nghttp2 copies name/value during submit_request (default NV flags), so the
    // arena copies only need to outlive that call.
    const n = try arena.dupe(u8, name);
    const v = try arena.dupe(u8, value);
    try list.append(arena, .{
        .name = n.ptr,
        .value = v.ptr,
        .namelen = n.len,
        .valuelen = v.len,
        .flags = @as(u8, @intCast(c.NGHTTP2_NV_FLAG_NONE)),
    });
}

/// Headers carried as pseudo-headers or forbidden as HTTP/2 fields (RFC 9113 §8.2.2).
fn isSkippedHeader(name: []const u8) bool {
    const skip = [_][]const u8{
        "host",              "connection", "keep-alive", "proxy-connection",
        "transfer-encoding", "upgrade",    "te",
    };
    for (skip) |s| {
        if (std.ascii.eqlIgnoreCase(name, s)) return true;
    }
    return false;
}
