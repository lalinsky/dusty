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
/// in-flight net_data item plus queued submissions/consume/cancel events.
const event_queue_cap = 256;

/// Per-stream receive window, and the size of each stream's body pipe buffer.
/// The buffer is sized to the window so the session coroutine's pipe writes
/// never block: HTTP/2 flow control bounds outstanding data to the window, and
/// the window only reopens (via `nghttp2_session_consume`) as the caller reads.
pub const stream_window_bytes = 256 * 1024;
/// Connection-level receive window — kept large so it isn't the bottleneck
/// across multiplexed streams (per-stream windows provide the backpressure).
const conn_window_bytes = 16 * 1024 * 1024;

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
    /// A caller consumed `n` body bytes of `stream_id`; return that flow-control
    /// credit to the peer (emits WINDOW_UPDATE).
    consume: struct { stream_id: i32, n: usize },
    /// A caller is abandoning `stream_id`; send RST_STREAM.
    cancel: i32,
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
    /// Final outgoing headers (the client already applied request/redirect
    /// policy: Host/Content-Length removed, sensitive/body headers stripped,
    /// Referer/User-Agent/Accept-Encoding added). This layer only drops
    /// h2-forbidden connection headers and lower-cases names.
    req_headers: ?*const Headers,
    req_body: []const u8 = &.{},
    req_sent: usize = 0,

    // Response (set by the session coroutine).
    parsed: ParsedResponse,
    /// Body pipe: the session coroutine pushes DATA frames in, the caller's
    /// reader pulls them out. Backed by a buffer on the request arena, sized to
    /// the stream window so pushes never block. Closed (graceful) at end-of-body.
    body: std.Io.Queue(u8),
    alloc_failed: bool = false,
    close_error: u32 = 0,
    err: ?anyerror = null,
    stream_id: i32 = -1,

    /// Set when the response headers are available (or the stream failed before
    /// them); the caller blocks on this and then reads the body via the pipe.
    headers_done: std.Io.Event = .unset,
    /// Set once the stream is fully finished (END_STREAM, RST, or error).
    done: std.Io.Event = .unset,
    /// Intrusive node in Connection.streams; touched only by the session coro.
    node: std.DoublyLinkedList.Node = .{},

    /// Mark the stream finished: record the error, then wake both a caller still
    /// waiting on headers and one reading the body.
    fn finish(s: *Stream, err: ?anyerror) void {
        if (err != null and s.err == null) s.err = err;
        s.headers_done.set(s.io);
        s.done.set(s.io);
    }
};

/// Called when a Connection's last reference is dropped, to release the
/// Connection itself, its transport, and its pool entry. Provided by the owner
/// (client.zig) since those types live there. Must call `conn.freeSession()`.
pub const ReapFn = *const fn (conn: *Connection) void;

/// A multiplexed HTTP/2 connection. Heap-allocated and never moved (coroutines
/// hold its address). The underlying transport (socket + TLS) is owned by the
/// caller (client.zig); this only borrows `reader`/`writer`.
///
/// Lifetime is reference-counted (`refs`): one reference is held by the session
/// coroutine (dropped when it exits) and one by each caller from acquire until
/// its response is deinit'd. When the count reaches zero the `reaper` frees
/// everything. The session and net-reader coroutines are spawned into a shared,
/// Client-owned group; the net-reader is a child of the session (spawned into a
/// group on the session's stack), so the session joins it before reaping.
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

    /// In-flight streams, owned exclusively by the session coroutine.
    streams: std.DoublyLinkedList = .{},

    /// Set true once the connection is unusable (GOAWAY/EOF/error). Read by the
    /// pool to skip it for reuse; written by the session coroutine / on cancel.
    closed: std.atomic.Value(bool) = .init(false),
    /// Reference count; starts at 1 for the session coroutine. The thread that
    /// decrements it to zero invokes `reaper`.
    refs: std.atomic.Value(usize) = .init(1),
    reaper: ?ReapFn = null,
    /// Opaque back-reference to the owner's pool entry, used by `reaper`.
    owner: ?*anyopaque = null,

    // Pool key.
    host_buf: [255]u8 = undefined,
    host_len: u8 = 0,
    port: u16 = 0,

    /// Allocate and initialize a connection over the given (ALPN-negotiated)
    /// reader/writer. Does NOT spawn coroutines — call `spawn` once the reaper
    /// and pool entry are wired up.
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
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(conn.callbacks, onFrameRecv);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(conn.callbacks, onDataChunk);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(conn.callbacks, onStreamClose);

        // Manual flow control: nghttp2 must NOT auto-send WINDOW_UPDATE. We
        // return credit via nghttp2_session_consume only as the caller reads,
        // which is what bounds the body pipe and provides backpressure.
        var option: ?*c.nghttp2_option = null;
        if (c.nghttp2_option_new(&option) != 0) return error.Http2Init;
        defer c.nghttp2_option_del(option);
        c.nghttp2_option_set_no_auto_window_update(option, 1);

        if (c.nghttp2_session_client_new2(&conn.session, conn.callbacks, conn, option) != 0) return error.Http2Init;
        // Raise the connection-level receive window so it doesn't throttle
        // multiplexed streams (per-stream windows handle backpressure).
        _ = c.nghttp2_session_set_local_window_size(conn.session, @intCast(c.NGHTTP2_FLAG_NONE), 0, conn_window_bytes);

        return conn;
    }

    /// Spawn the session coroutine into the (shared, Client-owned) group. The
    /// session spawns and owns the net-reader itself. Must be called after the
    /// reaper/owner are set.
    pub fn spawn(conn: *Connection, group: *std.Io.Group) !void {
        group.concurrent(conn.io, sessionLoop, .{conn}) catch return error.Http2Init;
    }

    /// Release the nghttp2 session/callbacks. Called by the reaper; the reaper
    /// also frees the Connection struct and transport.
    pub fn freeSession(conn: *Connection) void {
        if (conn.session) |s| c.nghttp2_session_del(s);
        if (conn.callbacks) |cb| c.nghttp2_session_callbacks_del(cb);
    }

    pub fn isClosed(conn: *Connection) bool {
        return conn.closed.load(.acquire);
    }

    /// Try to take a reference. Returns false if the connection is already being
    /// reaped (refcount hit zero), which prevents resurrecting a dead conn that
    /// is racing with its reaper. Callers hold the pool mutex.
    pub fn tryAcquire(conn: *Connection) bool {
        var r = conn.refs.load(.monotonic);
        while (true) {
            if (r == 0) return false;
            r = conn.refs.cmpxchgWeak(r, r + 1, .acq_rel, .monotonic) orelse return true;
        }
    }

    /// Drop a reference; the dropper that reaches zero invokes the reaper.
    pub fn dropRef(conn: *Connection) void {
        if (conn.refs.fetchSub(1, .acq_rel) == 1) {
            conn.reaper.?(conn);
        }
    }

    /// Submit a request on `stream` and block until the response headers are
    /// available (or the stream fails). The body then streams via `stream.body`.
    /// The caller owns `stream` and its arena and must already hold a connection
    /// reference.
    pub fn request(conn: *Connection, stream: *Stream) !void {
        conn.events.putOne(conn.io, .{ .submit = stream }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return error.Http2ConnectionClosed,
        };
        stream.headers_done.wait(conn.io) catch |err| {
            // Cancellation while waiting: the session coroutine may still touch
            // the stream, so the caller must not free it here. Retire the
            // connection so it is not reused.
            conn.closed.store(true, .release);
            return err;
        };
    }

    /// Post flow-control credit for `n` consumed body bytes of `stream_id`.
    pub fn consume(conn: *Connection, stream_id: i32, n: usize) void {
        conn.events.putOne(conn.io, .{ .consume = .{ .stream_id = stream_id, .n = n } }) catch {};
    }

    /// Ask the session to RST a stream the caller is abandoning.
    pub fn cancelStream(conn: *Connection, stream_id: i32) void {
        conn.events.putOne(conn.io, .{ .cancel = stream_id }) catch {};
    }

    /// Drop the caller's reference once it is done with the connection. (Named
    /// for symmetry with the request lifecycle; the stream arg is unused.)
    pub fn releaseStream(conn: *Connection, stream: *Stream) void {
        _ = stream;
        conn.dropRef();
    }
};

/// Streaming reader over a stream's body pipe. Pulls DATA bytes the session
/// coroutine pushed, and returns flow-control credit to the peer as it reads.
pub const BodyReader = struct {
    stream_obj: *Stream,
    conn: *Connection,
    interface: std.Io.Reader,

    pub fn init(stream_obj: *Stream, conn: *Connection, buffer: []u8) BodyReader {
        return .{
            .stream_obj = stream_obj,
            .conn = conn,
            .interface = .{
                .vtable = &.{ .stream = readStream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn readStream(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *BodyReader = @alignCast(@fieldParentPtr("interface", io_r));
        const s = self.stream_obj;
        const io = self.conn.io;

        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;

        const n = s.body.get(io, dest, 1) catch |err| switch (err) {
            error.Closed => {
                // Pipe drained and closed: end of body. Surface a stream error
                // (e.g. RST mid-body) instead of a clean EOF if one was recorded.
                if (s.err) |_| return error.ReadFailed;
                return error.EndOfStream;
            },
            error.Canceled => return error.ReadFailed,
        };
        w.advance(n);
        // Return the flow-control credit so the peer may send more.
        self.conn.consume(s.stream_id, n);
        return n;
    }
};

// ---------------------------------------------------------------------------
// Session coroutine
// ---------------------------------------------------------------------------

fn sessionLoop(conn: *Connection) std.Io.Cancelable!void {
    const io = conn.io;

    // The net-reader is a child of this coroutine: spawning it into a group on
    // our own stack lets us join it (cancel) before reaping, without making it a
    // peer in the shared Client group.
    var nr_group: std.Io.Group = .init;
    defer {
        // Join the net-reader (cancel interrupts its blocking read), then drop
        // the session's reference — which reaps the connection if it was the
        // last one. Nothing touches `conn` after dropRef.
        nr_group.cancel(io);
        conn.dropRef();
    }
    nr_group.concurrent(io, netReaderLoop, .{conn}) catch {
        fatalAll(conn, error.Http2Init);
        return;
    };

    submitSettings(conn) catch {
        fatalAll(conn, error.Http2Init);
        return;
    };
    drainSend(conn) catch {
        fatalAll(conn, error.Http2ConnectionClosed);
        return;
    };

    while (true) {
        // On cancel/close, wake any in-flight streams (callers may be blocked on
        // headers_done/done or on a body read) before unwinding. Cancellation
        // must still propagate — never swallow error.Canceled.
        const ev = conn.events.getOne(io) catch |err| {
            fatalAll(conn, error.Http2ConnectionClosed);
            if (err == error.Canceled) return error.Canceled;
            return; // error.Closed
        };
        switch (ev) {
            .submit => |s| handleSubmit(conn, s),
            .consume => |x| {
                // Ignore errors: the stream may already be closed.
                _ = c.nghttp2_session_consume(conn.session, x.stream_id, x.n);
            },
            .cancel => |stream_id| {
                _ = c.nghttp2_submit_rst_stream(conn.session, @intCast(c.NGHTTP2_FLAG_NONE), stream_id, @intCast(c.NGHTTP2_CANCEL));
            },
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
    // advertise the per-stream window that matches the body pipe size.
    const iv = [_]c.nghttp2_settings_entry{
        .{ .settings_id = @intCast(c.NGHTTP2_SETTINGS_ENABLE_PUSH), .value = 0 },
        .{ .settings_id = @intCast(c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE), .value = stream_window_bytes },
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
    if (s.req_headers) |hs| {
        for (hs.keys[0..hs.len], hs.values[0..hs.len]) |k, v| {
            if (isSkippedHeader(k)) continue;
            const lower = std.ascii.allocLowerString(arena, k) catch return s.finish(error.Http2Init);
            addNv(&nva, arena, lower, v) catch return s.finish(error.Http2Init);
        }
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
        // Close the body pipe too: a caller blocked in BodyReader.readStream is
        // waiting on body.get(), not on the headers_done/done events.
        s.body.close(s.io);
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
            conn.events.putOne(io, .{ .net_data = buffered }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Closed => return, // session gone
            };
            try conn.consumed.wait(io); // propagate cancellation
            conn.consumed.reset();
            conn.reader.toss(buffered.len);
        } else {
            conn.reader.fillMore() catch |err| switch (err) {
                // NOTE: std.Io.Reader maps a cancelled read to ReadFailed (not
                // Canceled), so cancellation surfaces here as the `else` arm; the
                // queue posts below still propagate Canceled if it races.
                error.EndOfStream => {
                    conn.events.putOne(io, .net_eof) catch |e| switch (e) {
                        error.Canceled => return error.Canceled,
                        error.Closed => {},
                    };
                    return;
                },
                else => {
                    conn.events.putOne(io, .net_err) catch |e| switch (e) {
                        error.Canceled => return error.Canceled,
                        error.Closed => {},
                    };
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
    s.parsed.headers.add(name_copy, value_copy) catch {
        // Too many response headers (past max_response_header_count). Reset just
        // this stream rather than failing the whole connection: returning
        // CALLBACK_FAILURE here would tear down every multiplexed stream, so use
        // TEMPORAL_CALLBACK_FAILURE, which makes nghttp2 RST only this stream.
        if (s.err == null) s.err = error.TooManyHeaders;
        return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
    };
    return 0;
}

fn onFrameRecv(
    session: ?*c.nghttp2_session,
    frame: [*c]const c.nghttp2_frame,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = user_data;
    // Response headers complete: hand the response to the waiting caller. (1xx
    // informational responses use a different category and don't wake it.)
    if (frame.*.hd.type == @as(u8, @intCast(c.NGHTTP2_HEADERS)) and
        frame.*.headers.cat == @as(c.nghttp2_headers_category, @intCast(c.NGHTTP2_HCAT_RESPONSE)))
    {
        const s = streamFor(session, frame.*.hd.stream_id) orelse return 0;
        s.headers_done.set(s.io);
    }
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
    // Non-blocking push (min=0). Flow control keeps outstanding data within the
    // window, which equals the pipe capacity, so everything fits; a short write
    // would mean a flow-control accounting bug, so fail the stream rather than
    // silently drop bytes.
    const placed = s.body.putUncancelable(s.io, data[0..len], 0) catch |err| switch (err) {
        error.Closed => return 0, // reader gone; drop
    };
    if (placed != len) {
        s.alloc_failed = true;
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    }
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
    }
    // Close the body pipe (graceful: the reader drains buffered bytes, then EOF).
    s.body.close(s.io);
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
