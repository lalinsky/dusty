//! The HTTP/2 server engine, on nghttp2. A connection runs as
//!
//!   * the reader task (the connection's own task, which entered `serve`):
//!     reads the connection and feeds the nghttp2 session,
//!   * a writer task: waits until the session has output, takes it and
//!     writes it to the connection,
//!   * one task per stream: builds a `Request` and a sink-backed `Response`
//!     and runs the router (`Server.dispatch`), so HTTP/2 serves the same
//!     handlers and middleware as HTTP/1.x.
//!
//! The session is not reentrant, so one mutex serializes every `nghttp2_*`
//! call. Under it the session only computes (HPACK, framing, callbacks); the
//! socket I/O and the handlers run outside it. Over TLS the reader decrypts
//! and the writer encrypts through one `tls.Connection`, which must support
//! one concurrent reader plus one writer (tls.zig does).
//!
//! Request bodies: a per-stream queue sized to the stream window, allocated
//! on the first DATA frame. The session side can always put into it without
//! blocking (a peer past its window is a protocol error nghttp2 rejects
//! first), and the handler returns window credit as it reads.
//!
//! Response bodies: the handler writes into a per-stream queue and blocks
//! when it is full; the data provider takes from it without blocking and
//! defers the stream when it is empty. Trailers go out from the provider at
//! the end of the body (`nghttp2_submit_trailer`).
//!
//! The shape follows the h2-engine sketch on this repository (#137); the
//! data provider with deferred data and trailers follows grpc-lite's server
//! (MIT, github.com/fanyang89/grpc-lite, db3c400, src/server.zig).
const std = @import("std");
const build_options = @import("build_options");

const c = @import("nghttp2");
const http = @import("../http.zig");
const Connection = @import("../server.zig").Connection;
const Listener = @import("../config.zig").Listener;
const ServerConfig = @import("../config.zig").ServerConfig;
const Request = @import("../request.zig").Request;
const BodySource = @import("../request.zig").BodySource;
const Response = @import("../response.zig").Response;
const Sink = @import("../sink.zig").Sink;
const Transport = @import("../transport.zig").Transport;
const Timer = @import("../deadline.zig").Timer;

const log = std.log.scoped(.dusty_h2);

/// The client connection preface (RFC 9113 §3.4).
pub const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// True when the connection opens with the HTTP/2 preface. Reads only while
/// what is buffered is still a prefix of it, so an HTTP/1.x request (which
/// cannot start with "PRI * HTTP/2.0") is never delayed past its first byte
/// that differs. The preface stays buffered; the session reads it.
pub fn sniffPreface(r: *std.Io.Reader) error{ReadFailed}!bool {
    while (true) {
        const have = r.buffered();
        const n = @min(have.len, preface.len);
        if (!std.mem.eql(u8, have[0..n], preface[0..n])) return false;
        if (n == preface.len) return true;
        r.fillMore() catch |err| switch (err) {
            error.EndOfStream => return false,
            error.ReadFailed => return error.ReadFailed,
        };
    }
}

/// Response body bytes queued per stream between the handler and the data
/// provider; a handler that gets this far ahead of the peer waits.
const out_queue_len = 32 * 1024;
/// The handler-side buffer in front of that queue.
const body_writer_len = 16 * 1024;

pub fn Engine(comptime Ctx: type) type {
    return struct {
        const Server = @import("../server.zig").Server(Ctx);

        /// One HTTP/2 connection: the session, its streams, and what the
        /// reader, writer and stream tasks share.
        const Conn = struct {
            server: *Server,
            connection: *Connection,
            listener: *const Listener,
            secure: bool,
            io: std.Io,
            allocator: std.mem.Allocator,
            config: ServerConfig.Http2,

            /// Serializes every nghttp2_* call, and guards everything below.
            /// Held only for computation, never across I/O.
            mutex: std.Io.Mutex = .init,
            session: ?*c.nghttp2_session = null,
            streams: std.AutoHashMapUnmanaged(i32, *Stream) = .empty,
            /// Streams with a handler still running or a response still
            /// going out, each counted in the server's in-flight requests.
            open_streams: usize = 0,
            /// Set while the reader runs the session, so a stream whose head
            /// completes can be handed to a task in the connection's group.
            group: ?*std.Io.Group = null,
            /// The reader is done; the writer sends what is left and exits.
            closing: bool = false,
            /// A GOAWAY went out because the server is draining.
            goaway_sent: bool = false,

            /// Bumped (under the mutex) whenever the session may have output.
            /// The writer waits on it.
            write_gen: std.atomic.Value(u32) = .init(0),

            fn kickWriter(conn: *Conn) void {
                _ = conn.write_gen.fetchAdd(1, .release);
                conn.io.futexWake(u32, &conn.write_gen.raw, 1);
            }

            fn lock(conn: *Conn) void {
                conn.mutex.lockUncancelable(conn.io);
            }

            fn unlock(conn: *Conn) void {
                conn.mutex.unlock(conn.io);
            }

            fn initSession(conn: *Conn) !void {
                var callbacks: ?*c.nghttp2_session_callbacks = null;
                if (c.nghttp2_session_callbacks_new(&callbacks) != 0) return error.OutOfMemory;
                defer c.nghttp2_session_callbacks_del(callbacks);
                c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, onBeginHeaders);
                c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
                c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrameRecv);
                c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onDataChunk);
                c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onStreamClose);
                c.nghttp2_session_callbacks_set_on_frame_send_callback(callbacks, onFrameSend);

                var option: ?*c.nghttp2_option = null;
                if (c.nghttp2_option_new(&option) != 0) return error.OutOfMemory;
                defer c.nghttp2_option_del(option);
                // Window credit is returned as handlers read (BodyReader).
                c.nghttp2_option_set_no_auto_window_update(option, 1);
                // The limits nghttp2 enforces itself, set here rather than
                // left to its defaults. The header list size is checked in
                // onHeader, against what SETTINGS advertised.
                c.nghttp2_option_set_stream_reset_rate_limit(option, conn.config.stream_reset_burst, conn.config.stream_reset_rate);
                c.nghttp2_option_set_max_continuations(option, conn.config.max_continuations);

                if (c.nghttp2_session_server_new2(&conn.session, callbacks, conn, option) != 0) return error.OutOfMemory;
                errdefer {
                    c.nghttp2_session_del(conn.session);
                    conn.session = null;
                }

                const iv = [_]c.nghttp2_settings_entry{
                    .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = conn.config.max_concurrent_streams },
                    .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = conn.config.stream_window },
                    .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, .value = conn.config.max_header_list_size },
                };
                if (c.nghttp2_submit_settings(conn.session, c.NGHTTP2_FLAG_NONE, &iv, iv.len) != 0) return error.OutOfMemory;
                if (conn.config.connection_window > 65535) {
                    _ = c.nghttp2_session_set_local_window_size(conn.session, c.NGHTTP2_FLAG_NONE, 0, conn.config.connection_window);
                }
            }
        };

        /// Who still needs a stream. Whichever lets go second frees it: the
        /// handler can outlive the protocol stream (a reset), and the
        /// protocol stream outlives the handler while the response drains.
        const Side = enum { handler, protocol };

        const Stream = struct {
            conn: *Conn,
            id: i32,
            /// Everything of the stream's lives here, the Stream included.
            arena: std.heap.ArenaAllocator,

            // The request head, filled by the header callbacks before the
            // handler task starts.
            method: []const u8 = "",
            path: []const u8 = "",
            authority: []const u8 = "",
            scheme: []const u8 = "",
            headers: std.ArrayList(Field) = .empty,
            /// Decoded header block size so far (RFC 9113 §6.5.2).
            header_list_size: usize = 0,

            /// Request body: DATA in, the handler out. Allocated on the
            /// first DATA frame; a request without a body never has one.
            body: ?std.Io.Queue(u8) = null,
            /// The request had no body at all (END_STREAM on its HEADERS),
            /// or its body has ended.
            body_done: bool = false,
            /// The peer reset the stream, or the connection went away.
            reset: bool = false,

            /// Response: what the handler's head was, and whether it has
            /// been submitted to the session.
            status: http.Status = .ok,
            response_nv: []c.nghttp2_nv = &.{},
            submitted: bool = false,
            /// Response body: the handler in, the data provider out.
            out: ?std.Io.Queue(u8) = null,
            /// Trailers for the provider to send after the body.
            trailer_nv: []c.nghttp2_nv = &.{},
            /// The handler ended the response.
            ended: bool = false,

            handler_done: bool = false,
            protocol_done: bool = false,
            /// Counted in the server's in-flight requests (by `startStream`)
            /// until it is freed.
            counted: bool = false,

            const Field = struct { name: []const u8, value: []const u8 };

            fn create(conn: *Conn, id: i32) !*Stream {
                var arena: std.heap.ArenaAllocator = .init(conn.allocator);
                errdefer arena.deinit();
                const stream = try arena.allocator().create(Stream);
                stream.* = .{ .conn = conn, .id = id, .arena = arena };
                return stream;
            }

            /// Drops one side's hold, under the mutex. The second frees it.
            fn release(stream: *Stream, side: Side) void {
                switch (side) {
                    .handler => stream.handler_done = true,
                    .protocol => stream.protocol_done = true,
                }
                if (!(stream.handler_done and stream.protocol_done)) return;
                const conn = stream.conn;
                _ = conn.streams.remove(stream.id);
                if (stream.counted) {
                    conn.open_streams -= 1;
                    conn.server.finishRequest();
                }
                var arena = stream.arena;
                arena.deinit();
            }

            /// No more request body: the stream ended or was reset.
            fn closeBody(stream: *Stream) void {
                stream.body_done = true;
                if (stream.body) |*q| q.close(stream.conn.io);
            }
        };

        /// Runs HTTP/2 over an initialized connection. The calling task is
        /// the reader; the writer and the streams run in a group torn down
        /// before this returns. `busy` is the connection's count in the
        /// server's in-flight requests, given back here: from now on each
        /// open stream is counted instead.
        pub fn serve(server: *Server, listener: *const Listener, secure: bool, connection: *Connection, busy: *bool) !void {
            if (busy.*) {
                busy.* = false;
                server.finishRequest();
            }

            // The connection's buffers for its whole life: the reader's must
            // hold what the session has not consumed yet, the writer's
            // batches frames into one write.
            const buffers = try server.request_buffers.acquire(@intFromPtr(connection));
            defer server.request_buffers.release(buffers);
            connection.useReadBuffer(buffers.read_buffer);
            connection.useWriteBuffer(buffers.write_buffer);
            defer connection.releaseWriteBuffer();

            var conn: Conn = .{
                .server = server,
                .connection = connection,
                .listener = listener,
                .secure = secure,
                .io = server.io,
                .allocator = server.allocator,
                .config = server.config.http2,
            };
            try conn.initSession();
            defer {
                conn.lock();
                defer conn.unlock();
                // The tasks are joined (the group's cancel runs first), so
                // each release here is the freeing one.
                while (true) {
                    var it = conn.streams.valueIterator();
                    const stream = (it.next() orelse break).*;
                    stream.reset = true;
                    stream.closeBody();
                    // No handler task is left (a stream whose head never
                    // completed never had one), so this frees it.
                    stream.handler_done = true;
                    stream.release(.protocol);
                }
                conn.streams.deinit(conn.allocator);
                c.nghttp2_session_del(conn.session);
                conn.session = null;
            }

            var group: std.Io.Group = .init;
            defer group.cancel(conn.io);
            try group.concurrent(conn.io, writerLoop, .{&conn});

            readerLoop(&conn, &group) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    if (Connection.isPeerGone(err)) {
                        log.debug("HTTP/2 connection closed by peer: {}", .{err});
                    } else {
                        log.info("HTTP/2 connection error: {}", .{err});
                    }
                },
            };

            // Let the writer send what the session still has (a GOAWAY after
            // a protocol error, the last responses), then stop.
            {
                conn.lock();
                defer conn.unlock();
                conn.closing = true;
            }
            conn.kickWriter();
            group.await(conn.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
            };
        }

        /// Reads the connection and feeds the session until the peer is
        /// done or the session wants nothing more. Holds the keepalive
        /// deadline while no stream is open.
        fn readerLoop(conn: *Conn, group: *std.Io.Group) !void {
            const reader = conn.connection.reader;
            var timer: Timer = .init(null);
            defer timer.clear(conn.io);
            while (true) {
                const buffered = reader.buffered();
                if (buffered.len > 0) {
                    const consumed = consumed: {
                        conn.lock();
                        defer conn.unlock();
                        conn.group = group;
                        defer conn.group = null;
                        const rv = c.nghttp2_session_mem_recv2(conn.session, buffered.ptr, buffered.len);
                        if (rv < 0) {
                            log.debug("HTTP/2 session: {s}", .{c.nghttp2_strerror(@intCast(rv))});
                            // nghttp2 queued a GOAWAY for a protocol error;
                            // the writer sends it on the way out.
                            return error.Http2ProtocolError;
                        }
                        break :consumed @as(usize, @intCast(rv));
                    };
                    reader.toss(consumed);
                    conn.kickWriter();

                    conn.lock();
                    const done = c.nghttp2_session_want_read(conn.session) == 0 and
                        c.nghttp2_session_want_write(conn.session) == 0;
                    conn.unlock();
                    if (done) return;
                    continue;
                }

                conn.lock();
                const idle = conn.open_streams == 0;
                conn.unlock();
                if (idle) {
                    if (conn.server.config.timeout.keepalive) |d| {
                        timer.set(conn.io, .{ .duration = .{ .raw = d, .clock = .awake } });
                    } else timer.clear(conn.io);
                } else timer.clear(conn.io);

                reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return,
                    error.ReadFailed => return conn.connection.getReadError() orelse error.Unexpected,
                };
            }
        }

        fn writerLoop(conn: *Conn) std.Io.Cancelable!void {
            runWriter(conn) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    if (!Connection.isPeerGone(err)) log.info("HTTP/2 write error: {}", .{err});
                    // Nothing more can go out; stop the reader too.
                    conn.connection.stream.shutdown(conn.io, .both) catch {};
                },
            };
        }

        /// Takes the session's output under the mutex, a frame at a time,
        /// and writes it outside. A frame from `mem_send2` is valid only
        /// until the next call, so it is copied into `staging` first.
        fn runWriter(conn: *Conn) !void {
            var staging: std.ArrayList(u8) = .empty;
            defer staging.deinit(conn.allocator);
            const writer = conn.connection.writer;
            while (true) {
                const gen = conn.write_gen.load(.acquire);
                var closing = false;
                {
                    conn.lock();
                    defer conn.unlock();
                    closing = conn.closing;
                    while (staging.items.len < 64 * 1024) {
                        var data: [*c]const u8 = undefined;
                        const n = c.nghttp2_session_mem_send2(conn.session, &data);
                        if (n < 0) return error.Http2ProtocolError;
                        if (n == 0) break;
                        try staging.appendSlice(conn.allocator, data[0..@intCast(n)]);
                    }
                }
                if (staging.items.len > 0) {
                    writer.writeAll(staging.items) catch return conn.connection.getWriteError() orelse error.Unexpected;
                    writer.flush() catch return conn.connection.getWriteError() orelse error.Unexpected;
                    staging.clearRetainingCapacity();
                    continue;
                }
                // The session is over (a GOAWAY went out, for a protocol
                // error or after the last stream of a closing session) and
                // wants neither to read nor to write: close the connection,
                // which also ends the reader's wait (RFC 9113 §5.4.1).
                conn.lock();
                const finished = c.nghttp2_session_want_read(conn.session) == 0 and
                    c.nghttp2_session_want_write(conn.session) == 0;
                conn.unlock();
                if (finished) {
                    conn.connection.stream.shutdown(conn.io, .both) catch {};
                    return;
                }
                if (closing) return;
                try conn.io.futexWait(u32, &conn.write_gen.raw, gen);
            }
        }

        // -- One stream: a request in, a response out --------------------

        fn runStream(conn: *Conn, stream: *Stream) std.Io.Cancelable!void {
            defer {
                conn.lock();
                defer conn.unlock();
                stream.release(.handler);
                conn.kickWriter();
            }
            serveStream(conn, stream) catch |err| {
                if (err == error.Canceled) {
                    resetStream(conn, stream, c.NGHTTP2_CANCEL);
                    return error.Canceled;
                }
                if (stream.reset or err == error.ConnectionResetByPeer) {
                    log.debug("HTTP/2 stream {d} reset: {}", .{ stream.id, err });
                } else {
                    log.err("HTTP/2 stream {d}: {}", .{ stream.id, err });
                    resetStream(conn, stream, c.NGHTTP2_INTERNAL_ERROR);
                }
            };
        }

        fn resetStream(conn: *Conn, stream: *Stream, code: u32) void {
            conn.lock();
            defer conn.unlock();
            if (stream.reset) return;
            stream.reset = true;
            _ = c.nghttp2_submit_rst_stream(conn.session, c.NGHTTP2_FLAG_NONE, stream.id, code);
            conn.kickWriter();
        }

        fn serveStream(conn: *Conn, stream: *Stream) !void {
            const server = conn.server;
            const arena = stream.arena.allocator();
            const io = conn.io;

            var timer: Timer = .init(null);
            defer timer.clear(io);
            if (server.config.timeout.request) |d| timer.set(io, .{ .duration = .{ .raw = d, .clock = .awake } });

            var request: Request = .{
                .arena = arena,
                .io = io,
                .parser = undefined,
                .transport = undefined,
                .config = server.config.request,
                .listener = conn.listener,
                .secure = conn.secure,
                .version_major = 2,
                .version_minor = 0,
                ._timeout_context = &timer,
                ._set_timeout = setTimeout,
            };
            var body_reader: BodyReader = .init(stream);
            request.body_source = .{ .reader = &body_reader.interface, .err = BodyReader.errorOf };

            var sink_state: StreamSink = .{ .stream = stream };
            var response = try Response.initSink(arena, io, sink_state.sink(), server.config.request.max_header_count);
            defer response.deinit();
            response.request = &request;
            request.response = &response;

            request.method = parseMethod(stream.method) orelse {
                response.status = .not_implemented;
                return response.write();
            };
            response.head = request.method == .head;
            request.url = stream.path;

            request.headers = http.Headers.init(arena, server.config.request.max_header_count) catch return error.OutOfMemory;
            var too_many = false;
            for (stream.headers.items) |f| request.headers.put(f.name, f.value) catch {
                too_many = true;
                break;
            };
            if (!too_many and request.headers.get("Host") == null and stream.authority.len > 0) {
                request.headers.put("Host", stream.authority) catch {
                    too_many = true;
                };
            }
            if (too_many) {
                response.status = .request_header_fields_too_large;
                return response.write();
            }
            request.applyEntityHeaders();
            request.remote_address = server.clientAddress(conn.connection.stream.socket.address, &request.headers);

            if (request.headers.get("Expect")) |expect| {
                if (std.ascii.eqlIgnoreCase(expect, "100-continue")) {
                    request.expects_continue = !stream.body_done;
                } else {
                    response.status = .expectation_failed;
                    return response.write();
                }
            }

            log.debug("Received (h2 stream {d}): {f} {s}", .{ stream.id, request.method, request.url });

            server.dispatch(&request, &response) catch |err| switch (err) {
                error.ReadFailed => return body_reader.err orelse error.Unexpected,
                error.WriteFailed => return sink_state.writeErr() orelse error.Unexpected,
                else => |e| return e,
            };
            try response.write();
        }

        fn setTimeout(context: *anyopaque, io: std.Io, timeout: std.Io.Timeout) void {
            const timer: *Timer = @ptrCast(@alignCast(context));
            timer.set(io, timeout);
        }

        fn parseMethod(name: []const u8) ?http.Method {
            var lower: [16]u8 = undefined;
            if (name.len == 0 or name.len > lower.len) return null;
            return std.meta.stringToEnum(http.Method, std.ascii.lowerString(&lower, name));
        }

        /// The request body, read from the stream's queue. Returns window
        /// credit for what the handler takes, so a stream's flow-control
        /// window is the handler's pace.
        const BodyReader = struct {
            stream: *Stream,
            interface: std.Io.Reader,
            err: ?Transport.ReadError = null,

            fn init(stream: *Stream) BodyReader {
                return .{ .stream = stream, .interface = .{
                    .vtable = &.{ .stream = streamFn },
                    .buffer = &.{},
                    .seek = 0,
                    .end = 0,
                } };
            }

            fn errorOf(r: *std.Io.Reader) ?Transport.ReadError {
                const self: *BodyReader = @alignCast(@fieldParentPtr("interface", r));
                return self.err;
            }

            fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                const self: *BodyReader = @alignCast(@fieldParentPtr("interface", r));
                const stream = self.stream;
                const conn = stream.conn;
                // The body queue appears with the first DATA frame; until
                // then, or for a request with no body, wait for one or the end.
                const queue = blk: {
                    while (true) {
                        conn.lock();
                        const q = if (stream.body) |*q| q else null;
                        const done = stream.body_done;
                        const reset = stream.reset;
                        conn.unlock();
                        if (reset) return self.fail(error.ConnectionResetByPeer);
                        if (q) |queue| break :blk queue;
                        if (done) return error.EndOfStream;
                        // A DATA frame or the end wakes the writer generation.
                        const gen = conn.write_gen.load(.acquire);
                        conn.lock();
                        const ready = stream.body != null or stream.body_done or stream.reset;
                        conn.unlock();
                        if (ready) continue;
                        conn.io.futexWait(u32, &conn.write_gen.raw, gen) catch return self.fail(error.Canceled);
                    }
                };
                const dest = limit.slice(try w.writableSliceGreedy(1));
                if (dest.len == 0) return 0;
                const n = queue.get(conn.io, dest, 1) catch |err| switch (err) {
                    error.Closed => {
                        conn.lock();
                        const reset = stream.reset;
                        conn.unlock();
                        if (reset) return self.fail(error.ConnectionResetByPeer);
                        return error.EndOfStream;
                    },
                    error.Canceled => return self.fail(error.Canceled),
                };
                w.advance(n);
                conn.lock();
                _ = c.nghttp2_session_consume(conn.session, stream.id, n);
                conn.unlock();
                conn.kickWriter();
                return n;
            }

            fn fail(self: *BodyReader, err: Transport.ReadError) std.Io.Reader.StreamError {
                self.err = err;
                return error.ReadFailed;
            }
        };

        /// The response side of a stream, for `Response.initSink`.
        const StreamSink = struct {
            stream: *Stream,
            writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
            err: ?Response.SendError = null,

            fn sink(self: *StreamSink) Sink {
                return .{ .ptr = self, .vtable = &.{
                    .head = head,
                    .interim = interim,
                    .body = body,
                    .end = end,
                    .writeError = writeError,
                    .peerGone = peerGone,
                } };
            }

            fn fromPtr(ptr: *anyopaque) *StreamSink {
                return @ptrCast(@alignCast(ptr));
            }

            fn writeErr(self: *StreamSink) ?Response.SendError {
                return self.err;
            }

            fn fail(self: *StreamSink, err: Response.SendError) std.Io.Writer.Error {
                self.err = err;
                return error.WriteFailed;
            }

            /// Records the head. It goes out with the first body bytes, a
            /// flush (a streamed response), or the end, whichever is first,
            /// so a response with no body is one HEADERS frame.
            fn head(ptr: *anyopaque, status: http.Status, headers: *const http.Headers, content_length: ?usize) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const stream = self.stream;
                const arena = stream.arena.allocator();
                stream.status = status;
                var nv: std.ArrayList(c.nghttp2_nv) = .empty;
                var status_buf: [3]u8 = undefined;
                const status_text = std.fmt.bufPrint(&status_buf, "{d}", .{@intFromEnum(status)}) catch unreachable;
                nv.append(arena, field(":status", arena.dupe(u8, status_text) catch return self.fail(error.SystemResources))) catch return self.fail(error.SystemResources);
                var has_length = false;
                var it = headers.iterator();
                while (it.next()) |entry| {
                    // RFC 9113 §8.2.2: connection-specific fields are malformed.
                    if (isConnectionSpecific(entry.key)) continue;
                    if (std.ascii.eqlIgnoreCase(entry.key, "content-length")) has_length = true;
                    const name = std.ascii.allocLowerString(arena, entry.key) catch return self.fail(error.SystemResources);
                    nv.append(arena, field(name, entry.value)) catch return self.fail(error.SystemResources);
                }
                if (!has_length and statusHasLength(status)) {
                    if (content_length) |len| {
                        const text = std.fmt.allocPrint(arena, "{d}", .{len}) catch return self.fail(error.SystemResources);
                        nv.append(arena, field("content-length", text)) catch return self.fail(error.SystemResources);
                    }
                }
                stream.response_nv = nv.items;
            }

            fn interim(ptr: *anyopaque, status: http.Status) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const stream = self.stream;
                const conn = stream.conn;
                var status_buf: [3]u8 = undefined;
                const text = std.fmt.bufPrint(&status_buf, "{d}", .{@intFromEnum(status)}) catch unreachable;
                const nva = [_]c.nghttp2_nv{field(":status", text)};
                conn.lock();
                defer conn.unlock();
                if (stream.reset) return self.fail(error.ConnectionResetByPeer);
                if (c.nghttp2_submit_headers(conn.session, c.NGHTTP2_FLAG_NONE, stream.id, null, &nva, nva.len, null) != 0)
                    return self.fail(error.Unexpected);
                conn.kickWriter();
            }

            fn body(ptr: *anyopaque) *std.Io.Writer {
                const self = fromPtr(ptr);
                if (self.writer.buffer.len == 0) {
                    // A handler that never writes a body never pays for it.
                    self.writer.buffer = self.stream.arena.allocator().alloc(u8, body_writer_len) catch &.{};
                }
                return &self.writer;
            }

            /// Submits the head with a data provider, once. Under the mutex.
            fn submit(self: *StreamSink, with_body: bool) std.Io.Writer.Error!void {
                const stream = self.stream;
                const conn = stream.conn;
                if (stream.submitted) return;
                if (stream.reset) return self.fail(error.ConnectionResetByPeer);
                var provider: c.nghttp2_data_provider2 = .{
                    .source = .{ .ptr = stream },
                    .read_callback = provideData,
                };
                const rv = c.nghttp2_submit_response2(
                    conn.session,
                    stream.id,
                    stream.response_nv.ptr,
                    stream.response_nv.len,
                    if (with_body) &provider else null,
                );
                if (rv != 0) {
                    log.debug("HTTP/2 submit_response2: {s}", .{c.nghttp2_strerror(rv)});
                    return self.fail(error.ConnectionResetByPeer);
                }
                stream.submitted = true;
                conn.kickWriter();
            }

            /// Moves body bytes into the stream's queue, blocking while it
            /// is full: the peer is behind, or out of window.
            fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                const self: *StreamSink = @alignCast(@fieldParentPtr("writer", w));
                const stream = self.stream;
                const conn = stream.conn;
                {
                    conn.lock();
                    defer conn.unlock();
                    if (stream.out == null) {
                        const buf = stream.arena.allocator().alloc(u8, out_queue_len) catch return self.fail(error.SystemResources);
                        stream.out = .init(buf);
                    }
                    try self.submit(true);
                }
                try self.put(w.buffered());
                w.end = 0;
                var n: usize = 0;
                if (data.len > 0) {
                    for (data[0 .. data.len - 1]) |bytes| {
                        try self.put(bytes);
                        n += bytes.len;
                    }
                    const pattern = data[data.len - 1];
                    for (0..splat) |_| {
                        try self.put(pattern);
                        n += pattern.len;
                    }
                }
                return n;
            }

            fn put(self: *StreamSink, bytes: []const u8) std.Io.Writer.Error!void {
                if (bytes.len == 0) return;
                const stream = self.stream;
                const conn = stream.conn;
                var rest = bytes;
                while (rest.len > 0) {
                    // At most a queue's worth at a time, so the provider is
                    // resumed while the rest waits.
                    const n = stream.out.?.put(conn.io, rest, 1) catch |err| switch (err) {
                        error.Closed => return self.fail(error.ConnectionResetByPeer),
                        error.Canceled => return self.fail(error.Canceled),
                    };
                    rest = rest[n..];
                    conn.lock();
                    _ = c.nghttp2_session_resume_data(conn.session, stream.id);
                    conn.unlock();
                    conn.kickWriter();
                }
            }

            fn end(ptr: *anyopaque, trailers: ?*const http.Headers) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const stream = self.stream;
                const conn = stream.conn;
                const arena = stream.arena.allocator();
                var trailer_nv: std.ArrayList(c.nghttp2_nv) = .empty;
                if (trailers) |t| {
                    var it = t.iterator();
                    while (it.next()) |entry| {
                        const name = std.ascii.allocLowerString(arena, entry.key) catch return self.fail(error.SystemResources);
                        trailer_nv.append(arena, field(name, entry.value)) catch return self.fail(error.SystemResources);
                    }
                }
                conn.lock();
                defer conn.unlock();
                stream.trailer_nv = trailer_nv.items;
                stream.ended = true;
                if (stream.out) |*q| {
                    q.close(conn.io);
                    _ = c.nghttp2_session_resume_data(conn.session, stream.id);
                    conn.kickWriter();
                    return;
                }
                // No body went out: one HEADERS frame, or HEADERS then
                // trailers through a provider that has nothing to send.
                try self.submit(stream.trailer_nv.len > 0);
            }

            fn writeError(ptr: *anyopaque) ?Response.SendError {
                return fromPtr(ptr).err;
            }

            fn peerGone(ptr: *anyopaque) bool {
                const stream = fromPtr(ptr).stream;
                stream.conn.lock();
                defer stream.conn.unlock();
                return stream.reset;
            }
        };

        fn field(name: []const u8, value: []const u8) c.nghttp2_nv {
            return .{
                .name = @constCast(name.ptr),
                .namelen = name.len,
                .value = @constCast(value.ptr),
                .valuelen = value.len,
                .flags = c.NGHTTP2_NV_FLAG_NONE,
            };
        }

        fn isConnectionSpecific(name: []const u8) bool {
            const banned = [_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade" };
            for (banned) |b| if (std.ascii.eqlIgnoreCase(name, b)) return true;
            return false;
        }

        fn statusHasLength(status: http.Status) bool {
            const code = @intFromEnum(status);
            return !(code < 200 or code == 204 or code == 304);
        }

        // -- nghttp2 callbacks. Each runs inside an nghttp2_* call, with the
        // -- connection's mutex held by the calling task.

        fn connFrom(user_data: ?*anyopaque) *Conn {
            return @ptrCast(@alignCast(user_data.?));
        }

        fn streamFor(session: ?*c.nghttp2_session, id: i32) ?*Stream {
            const ptr = c.nghttp2_session_get_stream_user_data(session, id) orelse return null;
            return @ptrCast(@alignCast(ptr));
        }

        fn onBeginHeaders(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connFrom(user_data);
            if (frame.*.hd.type != c.NGHTTP2_HEADERS or frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;
            const id = frame.*.hd.stream_id;

            // A draining server takes no new requests: refuse the stream,
            // which the client can safely retry elsewhere, and say so once
            // with GOAWAY.
            if (conn.server.busy.load(.acquire).draining) {
                if (!conn.goaway_sent) {
                    conn.goaway_sent = true;
                    _ = c.nghttp2_submit_goaway(session, c.NGHTTP2_FLAG_NONE, c.nghttp2_session_get_last_proc_stream_id(session), c.NGHTTP2_NO_ERROR, null, 0);
                }
                _ = c.nghttp2_submit_rst_stream(session, c.NGHTTP2_FLAG_NONE, id, c.NGHTTP2_REFUSED_STREAM);
                return 0;
            }

            const stream = Stream.create(conn, id) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            conn.streams.put(conn.allocator, id, stream) catch {
                var arena = stream.arena;
                arena.deinit();
                return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            };
            _ = c.nghttp2_session_set_stream_user_data(session, id, stream);
            return 0;
        }

        fn onHeader(
            session: ?*c.nghttp2_session,
            frame: [*c]const c.nghttp2_frame,
            name_ptr: [*c]const u8,
            name_len: usize,
            value_ptr: [*c]const u8,
            value_len: usize,
            flags: u8,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            _ = flags;
            _ = user_data;
            const stream = streamFor(session, frame.*.hd.stream_id) orelse return 0;
            // Trailers on a request are not passed on.
            if (frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;
            stream.header_list_size += name_len + value_len + 32;
            if (stream.header_list_size > stream.conn.config.max_header_list_size) {
                // Past what SETTINGS_MAX_HEADER_LIST_SIZE allowed: the stream
                // is reset and never reaches a handler.
                return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            }
            const arena = stream.arena.allocator();
            const name = name_ptr[0..name_len];
            const value = arena.dupe(u8, value_ptr[0..value_len]) catch return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            if (std.mem.eql(u8, name, ":method")) {
                stream.method = value;
            } else if (std.mem.eql(u8, name, ":path")) {
                stream.path = value;
            } else if (std.mem.eql(u8, name, ":authority")) {
                stream.authority = value;
            } else if (std.mem.eql(u8, name, ":scheme")) {
                stream.scheme = value;
            } else if (name.len > 0 and name[0] != ':') {
                const name_copy = arena.dupe(u8, name) catch return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
                stream.headers.append(arena, .{ .name = name_copy, .value = value }) catch return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            }
            return 0;
        }

        fn onFrameRecv(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connFrom(user_data);
            const hd = frame.*.hd;
            const stream = streamFor(session, hd.stream_id) orelse return 0;
            const end_stream = hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0;
            switch (hd.type) {
                c.NGHTTP2_HEADERS => {
                    if (frame.*.headers.cat == c.NGHTTP2_HCAT_REQUEST) {
                        if (end_stream) stream.closeBody();
                        startStream(conn, stream);
                    } else if (end_stream) {
                        stream.closeBody(); // trailers end the body
                    }
                },
                c.NGHTTP2_DATA => if (end_stream) stream.closeBody(),
                else => {},
            }
            conn.kickWriter(); // also wakes a body reader waiting for its queue
            return 0;
        }

        /// The head is complete: count the stream in flight and give it a
        /// task.
        fn startStream(conn: *Conn, stream: *Stream) void {
            const group = conn.group orelse return;
            _ = conn.server.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
            conn.open_streams += 1;
            stream.counted = true;
            group.concurrent(conn.io, runStream, .{ conn, stream }) catch {
                log.err("HTTP/2: no task for stream {d}", .{stream.id});
                stream.reset = true;
                stream.closeBody();
                stream.release(.handler);
                _ = c.nghttp2_submit_rst_stream(conn.session, c.NGHTTP2_FLAG_NONE, stream.id, c.NGHTTP2_REFUSED_STREAM);
            };
        }

        /// Once the frame that ends a response is out, a request body the
        /// handler left unread is not waited for: the stream ends with
        /// RST_STREAM(NO_ERROR) (RFC 9113 §8.1). Sent here rather than when
        /// the handler returns, since nghttp2 sends RST_STREAM ahead of a
        /// response still queued, which would cut it off.
        fn onFrameSend(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
            _ = user_data;
            const hd = frame.*.hd;
            if (hd.flags & c.NGHTTP2_FLAG_END_STREAM == 0) return 0;
            if (hd.type != c.NGHTTP2_HEADERS and hd.type != c.NGHTTP2_DATA) return 0;
            const stream = streamFor(session, hd.stream_id) orelse return 0;
            if (!stream.body_done and !stream.reset) {
                _ = c.nghttp2_submit_rst_stream(session, c.NGHTTP2_FLAG_NONE, hd.stream_id, c.NGHTTP2_NO_ERROR);
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
            const conn = connFrom(user_data);
            const stream = streamFor(session, stream_id) orelse return 0;
            if (stream.body_done) return 0;
            if (stream.body == null) {
                const buf = stream.arena.allocator().alloc(u8, conn.config.stream_window) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                stream.body = .init(buf);
            }
            // Cannot block: the queue holds a whole window, and the peer may
            // not send past it.
            const put = stream.body.?.putUncancelable(conn.io, data[0..len], 0) catch |err| switch (err) {
                // The handler is gone; the bytes are dropped with the stream.
                error.Closed => return 0,
            };
            if (put != len) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            return 0;
        }

        fn onStreamClose(session: ?*c.nghttp2_session, stream_id: i32, error_code: u32, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connFrom(user_data);
            const stream = streamFor(session, stream_id) orelse return 0;
            if (error_code != c.NGHTTP2_NO_ERROR or !stream.ended) stream.reset = true;
            stream.closeBody();
            if (stream.out) |*q| q.close(conn.io);
            stream.release(.protocol);
            conn.kickWriter();
            return 0;
        }

        /// Data provider: takes what the handler queued without waiting.
        /// Empty and not ended defers the stream until the handler resumes
        /// it; ended sends the end, with the trailers if there are any.
        fn provideData(
            session: ?*c.nghttp2_session,
            stream_id: i32,
            buf: [*c]u8,
            length: usize,
            data_flags: [*c]u32,
            source: [*c]c.nghttp2_data_source,
            user_data: ?*anyopaque,
        ) callconv(.c) c.nghttp2_ssize {
            const conn = connFrom(user_data);
            const stream: *Stream = @ptrCast(@alignCast(source.*.ptr.?));
            if (stream.out) |*q| {
                const n = q.getUncancelable(conn.io, buf[0..length], 0) catch |err| switch (err) {
                    error.Closed => return finish(session, stream_id, stream, data_flags),
                };
                if (n > 0) return @intCast(n);
                if (!stream.ended) return c.NGHTTP2_ERR_DEFERRED;
            }
            return finish(session, stream_id, stream, data_flags);
        }

        fn finish(session: ?*c.nghttp2_session, stream_id: i32, stream: *Stream, data_flags: [*c]u32) c.nghttp2_ssize {
            data_flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
            if (stream.trailer_nv.len > 0) {
                data_flags.* |= c.NGHTTP2_DATA_FLAG_NO_END_STREAM;
                if (c.nghttp2_submit_trailer(session, stream_id, stream.trailer_nv.ptr, stream.trailer_nv.len) != 0)
                    return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            }
            return 0;
        }
    };
}
