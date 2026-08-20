//! The HTTP/2 engine (sketch). Two fixed tasks per connection plus one task
//! per stream, all in ordinary blocking `std.Io` style, so the engine runs on
//! any Io implementation:
//!
//!   * the reader task (the task that entered `serve`) blocks on the
//!     connection reader and feeds bytes to the nghttp2 session,
//!   * the writer task parks until the session has output and writes it to
//!     the connection writer,
//!   * a handler task per stream runs the application code.
//!
//! The nghttp2 session is not reentrant, so a mutex serializes every
//! `nghttp2_*` call. All the session does under the mutex is pure
//! computation (HPACK, framing, callbacks); the socket I/O happens outside
//! it, so a slow peer blocks only the task that is talking to it.
//!
//! Over TLS the reader task decrypts and the writer task encrypts through
//! the same `tls.Connection`, which supports exactly this split: one
//! concurrent reader plus one writer.
//!
//! Request bodies flow through a per-stream `std.Io.Queue(u8)` sized to the
//! stream's flow-control window: the session side can therefore always push
//! without blocking (a peer that overruns the window is a protocol error
//! nghttp2 rejects before the data reaches us), and the handler side returns
//! window credit as it consumes. Closing the queue is the end-of-stream
//! signal in both the clean (END_STREAM) and abrupt (RST_STREAM) case.
//!
//! Sketch limits, to be lifted as the design lands:
//!   * handlers are a placeholder response, not the router/middleware
//!     executor; that needs the protocol-neutral Response backend first,
//!   * response bodies are complete buffers pulled by the data provider,
//!     no streaming/deferred path yet,
//!   * the session output is copied into a staging buffer under the mutex
//!     and written outside it; the no-copy send path can replace this later,
//!   * no timeouts yet.

const std = @import("std");

const Connection = @import("connection.zig").Connection;

const c = @import("nghttp2");

const log = std.log.scoped(.dusty_h2);

/// Per-stream receive window, and the capacity of the stream's body queue.
/// The queue is sized to the window so the session side never blocks on it.
const stream_window = 64 * 1024;
/// Connection-level receive window: bounds the total unread body bytes
/// buffered across all streams of one connection.
const conn_window = 1024 * 1024;
const max_concurrent_streams = 128;
/// Output staging: session output is copied here under the session mutex and
/// written to the connection outside it. Must hold at least one full frame
/// (16K payload + 9 byte header).
const staging_size = 32 * 1024;

pub fn Engine(comptime Ctx: type) type {
    return struct {
        const Server = @import("../server.zig").Server(Ctx);

        /// One h2 connection: the nghttp2 session, its streams, and the
        /// coordination state between the three kinds of tasks.
        const Conn = struct {
            server: *Server,
            connection: *Connection,
            io: std.Io,
            allocator: std.mem.Allocator,

            /// Serializes every nghttp2_* call. Held only for computation,
            /// never across I/O.
            mutex: std.Io.Mutex = .init,
            session: ?*c.nghttp2_session = null,
            streams: std.AutoHashMapUnmanaged(i32, *Stream) = .empty,

            /// Bumped (under the mutex) whenever the session may have new
            /// output; the writer task parks on it.
            write_gen: std.atomic.Value(u32) = .init(0),
            /// The reader saw EOF or a fatal error; the writer drains what
            /// the session still wants to send and exits.
            closing: bool = false,
            /// Set by the reader task around mem_recv so the END_HEADERS
            /// callback can spawn handler tasks into the connection's group.
            spawn_group: ?*std.Io.Group = null,

            fn initSession(conn: *Conn) !void {
                var callbacks: ?*c.nghttp2_session_callbacks = null;
                if (c.nghttp2_session_callbacks_new(&callbacks) != 0) return error.Http2Init;
                defer c.nghttp2_session_callbacks_del(callbacks);
                c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, onBeginHeaders);
                c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
                c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrameRecv);
                c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onDataChunk);
                c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onStreamClose);

                var option: ?*c.nghttp2_option = null;
                if (c.nghttp2_option_new(&option) != 0) return error.Http2Init;
                defer c.nghttp2_option_del(option);
                // Window credit is returned explicitly, from the pace the
                // handlers actually consume at; see BodyReader.
                c.nghttp2_option_set_no_auto_window_update(option, 1);

                if (c.nghttp2_session_server_new2(&conn.session, callbacks, conn, option) != 0) {
                    return error.Http2Init;
                }
                errdefer {
                    c.nghttp2_session_del(conn.session);
                    conn.session = null;
                }

                const iv = [_]c.nghttp2_settings_entry{
                    .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = max_concurrent_streams },
                    .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = stream_window },
                };
                if (c.nghttp2_submit_settings(conn.session, @intCast(c.NGHTTP2_FLAG_NONE), &iv, iv.len) != 0) {
                    return error.Http2Init;
                }
                _ = c.nghttp2_session_set_local_window_size(conn.session, @intCast(c.NGHTTP2_FLAG_NONE), 0, conn_window);
            }

            fn deinitSession(conn: *Conn) void {
                if (conn.session) |s| c.nghttp2_session_del(s);
                conn.session = null;
            }

            /// Tell the writer task the session may have output.
            fn kickWriter(conn: *Conn) void {
                _ = conn.write_gen.fetchAdd(1, .release);
                conn.io.futexWake(u32, &conn.write_gen.raw, 1);
            }
        };

        /// Who is done with a stream. The stream is destroyed by whichever
        /// side lets go second: the handler task can outlive the protocol
        /// stream (peer reset) and the protocol stream can outlive the
        /// handler (close frame arriving after the response went out).
        const StreamSide = enum { handler, protocol };

        const Stream = struct {
            conn: *Conn,
            id: i32,
            arena: std.heap.ArenaAllocator,

            // Request head, filled by the header callbacks before the
            // handler task is spawned. All slices live on the arena.
            method: []const u8 = "",
            path: []const u8 = "",
            authority: []const u8 = "",
            headers: std.ArrayListUnmanaged(Header) = .empty,

            /// Request body pipe: the session side puts DATA payloads, the
            /// handler side gets them. Capacity == stream window, so puts
            /// never block. Closed on END_STREAM, RST, or teardown.
            body: std.Io.Queue(u8),
            /// Peer reset the stream; the handler should not respond.
            reset: bool = false,

            /// Complete response body for the data provider to pull from.
            /// Sketch: no streaming responses yet.
            response_body: []const u8 = "",
            response_sent: usize = 0,

            handler_done: bool = false,
            protocol_done: bool = false,

            const Header = struct { name: []const u8, value: []const u8 };

            fn create(conn: *Conn, id: i32) !*Stream {
                var arena = std.heap.ArenaAllocator.init(conn.allocator);
                errdefer arena.deinit();
                const stream = try arena.allocator().create(Stream);
                const body_buffer = try arena.allocator().alloc(u8, stream_window);
                stream.* = .{
                    .conn = conn,
                    .id = id,
                    .arena = arena,
                    .body = .init(body_buffer),
                };
                return stream;
            }

            /// Drop one side's hold on the stream. Called under the session
            /// mutex; the second caller destroys it.
            fn release(stream: *Stream, side: StreamSide) void {
                switch (side) {
                    .handler => stream.handler_done = true,
                    .protocol => stream.protocol_done = true,
                }
                if (stream.handler_done and stream.protocol_done) {
                    _ = stream.conn.streams.remove(stream.id);
                    // The arena owns the Stream itself; this frees everything.
                    var arena = stream.arena;
                    arena.deinit();
                }
            }
        };

        /// Runs the h2 session over an initialized connection. The calling
        /// task becomes the reader; the writer and the per-stream handlers
        /// run in a task group that is torn down before returning.
        pub fn serve(server: *Server, connection: *Connection) !void {
            var conn: Conn = .{
                .server = server,
                .connection = connection,
                .io = server.io,
                .allocator = server.allocator,
            };
            {
                try conn.mutex.lock(conn.io);
                defer conn.mutex.unlock(conn.io);
                try conn.initSession();
            }
            defer {
                conn.mutex.lockUncancelable(conn.io);
                defer conn.mutex.unlock(conn.io);
                // release() removes entries, so take one at a time rather
                // than holding an iterator across the mutation. The handler
                // tasks are already joined (the group cancel runs first), so
                // each release here is the destroying one.
                while (true) {
                    var it = conn.streams.valueIterator();
                    const stream = (it.next() orelse break).*;
                    stream.body.close(conn.io);
                    stream.release(.protocol);
                }
                conn.streams.deinit(conn.allocator);
                conn.deinitSession();
            }

            var group: std.Io.Group = .init;
            // Handlers park in queue/futex waits and the writer parks on
            // write_gen; cancel reaches all of them.
            defer group.cancel(conn.io);

            try group.concurrent(conn.io, writerLoop, .{&conn});

            readerLoop(&conn, &group) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                if (Connection.isPeerGone(err)) {
                    log.debug("h2 connection closed by peer: {}", .{err});
                } else {
                    log.err("h2 connection error: {}", .{err});
                }
            };

            // Let the writer flush what the session already queued (GOAWAY,
            // RST). The deferred cancel above is its backstop.
            {
                conn.mutex.lockUncancelable(conn.io);
                defer conn.mutex.unlock(conn.io);
                conn.closing = true;
            }
            conn.kickWriter();
        }

        /// Blocking read loop: fill the connection reader, hand whatever is
        /// buffered to the session, repeat until the peer is done.
        fn readerLoop(conn: *Conn, group: *std.Io.Group) !void {
            const reader = conn.connection.reader;
            while (true) {
                const buffered = reader.buffered();
                if (buffered.len > 0) {
                    const consumed = consumed: {
                        try conn.mutex.lock(conn.io);
                        defer conn.mutex.unlock(conn.io);
                        // Callbacks fire in here: headers accumulate on
                        // streams, handler tasks spawn, DATA lands in body
                        // queues (which cannot block: window <= capacity).
                        conn.spawn_group = group;
                        defer conn.spawn_group = null;
                        const rv = c.nghttp2_session_mem_recv2(conn.session, buffered.ptr, buffered.len);
                        if (rv < 0) {
                            log.debug("h2 mem_recv2: {s}", .{c.nghttp2_strerror(@intCast(rv))});
                            return error.Http2Protocol;
                        }
                        break :consumed @as(usize, @intCast(rv));
                    };
                    reader.toss(consumed);
                    conn.kickWriter();

                    const done = done: {
                        try conn.mutex.lock(conn.io);
                        defer conn.mutex.unlock(conn.io);
                        break :done c.nghttp2_session_want_read(conn.session) == 0 and
                            c.nghttp2_session_want_write(conn.session) == 0;
                    };
                    if (done) return;
                    continue;
                }
                reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return,
                    error.ReadFailed => return conn.connection.getReadError() orelse error.ReadFailed,
                };
            }
        }

        /// Parks until the session has output, then copies it out under the
        /// mutex and writes it outside. Exits when the connection is closing
        /// and the session has nothing more to say.
        fn writerLoop(conn: *Conn) std.Io.Cancelable!void {
            runWriter(conn) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                if (!Connection.isPeerGone(err)) {
                    log.err("h2 write error: {}", .{err});
                }
            };
        }

        fn runWriter(conn: *Conn) !void {
            var staging: [staging_size]u8 = undefined;
            while (true) {
                const gen = conn.write_gen.load(.acquire);

                var len: usize = 0;
                var closing = false;
                {
                    try conn.mutex.lock(conn.io);
                    defer conn.mutex.unlock(conn.io);
                    closing = conn.closing;
                    while (true) {
                        var data: [*c]const u8 = undefined;
                        const n = c.nghttp2_session_mem_send2(conn.session, &data);
                        if (n < 0) return error.Http2Protocol;
                        if (n == 0) break;
                        const chunk: usize = @intCast(n);
                        if (len + chunk > staging.len) {
                            // Staging is full; nghttp2 re-serves what we did
                            // not take? It does not -- mem_send2 hands out
                            // the frame exactly once, so the staging buffer
                            // must always fit one chunk (asserted by sizes)
                            // and we only stop between chunks.
                            @memcpy(staging[len..][0..chunk], data[0..chunk]);
                            len += chunk;
                            break;
                        }
                        @memcpy(staging[len..][0..chunk], data[0..chunk]);
                        len += chunk;
                    }
                }

                if (len > 0) {
                    try conn.connection.writer.writeAll(staging[0..len]);
                    conn.connection.writer.flush() catch |err| switch (err) {
                        error.WriteFailed => return conn.connection.getWriteError() orelse error.WriteFailed,
                        else => |e| return e,
                    };
                    continue;
                }

                if (closing) return;
                conn.io.futexWait(u32, &conn.write_gen.raw, gen) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                };
            }
        }

        /// Placeholder application layer: drains the request body and sends
        /// a canned response. Replaced by router + middleware executor once
        /// the protocol-neutral Response backend exists.
        fn handleStream(conn: *Conn, stream: *Stream) std.Io.Cancelable!void {
            defer {
                conn.mutex.lockUncancelable(conn.io);
                defer conn.mutex.unlock(conn.io);
                stream.release(.handler);
            }
            runHandler(conn, stream) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                log.err("h2 stream {d} handler error: {}", .{ stream.id, err });
            };
        }

        fn runHandler(conn: *Conn, stream: *Stream) !void {
            // Drain the request body, returning window credit as it is
            // consumed. `error.Closed` is end-of-body.
            var scratch: [4096]u8 = undefined;
            while (true) {
                const n = stream.body.get(conn.io, &scratch, 1) catch |err| switch (err) {
                    error.Closed => break,
                    error.Canceled => return error.Canceled,
                };
                try conn.mutex.lock(conn.io);
                defer conn.mutex.unlock(conn.io);
                _ = c.nghttp2_session_consume(conn.session, stream.id, n);
                conn.kickWriter();
            }

            stream.response_body = "hello from the dusty h2 sketch\n";

            const nva = [_]c.nghttp2_nv{
                nv(":status", "200"),
                nv("content-type", "text/plain"),
            };
            var provider: c.nghttp2_data_provider2 = .{
                .source = .{ .ptr = stream },
                .read_callback = onProvideData,
            };
            {
                try conn.mutex.lock(conn.io);
                defer conn.mutex.unlock(conn.io);
                if (stream.reset) return;
                const rv = c.nghttp2_submit_response2(conn.session, stream.id, &nva, nva.len, &provider);
                if (rv != 0) {
                    log.debug("h2 submit_response2: {s}", .{c.nghttp2_strerror(rv)});
                    return error.Http2Protocol;
                }
            }
            conn.kickWriter();
        }

        fn nv(name: []const u8, value: []const u8) c.nghttp2_nv {
            return .{
                .name = @constCast(name.ptr),
                .namelen = name.len,
                .value = @constCast(value.ptr),
                .valuelen = value.len,
                .flags = c.NGHTTP2_NV_FLAG_NONE,
            };
        }

        // -- nghttp2 callbacks. All of them run inside a nghttp2_* call, so
        // -- the session mutex is already held by the calling task.

        fn connFromUserData(user_data: ?*anyopaque) *Conn {
            return @ptrCast(@alignCast(user_data.?));
        }

        fn streamFor(session: ?*c.nghttp2_session, stream_id: i32) ?*Stream {
            const ptr = c.nghttp2_session_get_stream_user_data(session, stream_id) orelse return null;
            return @ptrCast(@alignCast(ptr));
        }

        fn onBeginHeaders(
            session: ?*c.nghttp2_session,
            frame: [*c]const c.nghttp2_frame,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            const conn = connFromUserData(user_data);
            if (frame.*.hd.type != c.NGHTTP2_HEADERS) return 0;
            if (frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;

            const id = frame.*.hd.stream_id;
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
            name: [*c]const u8,
            namelen: usize,
            value: [*c]const u8,
            valuelen: usize,
            flags: u8,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            _ = flags;
            _ = user_data;
            const stream = streamFor(session, frame.*.hd.stream_id) orelse return 0;
            const alloc = stream.arena.allocator();

            const n = name[0..namelen];
            const v = alloc.dupe(u8, value[0..valuelen]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;

            if (std.mem.eql(u8, n, ":method")) {
                stream.method = v;
            } else if (std.mem.eql(u8, n, ":path")) {
                stream.path = v;
            } else if (std.mem.eql(u8, n, ":authority")) {
                stream.authority = v;
            } else if (n.len > 0 and n[0] != ':') {
                const name_copy = alloc.dupe(u8, n) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                stream.headers.append(alloc, .{ .name = name_copy, .value = v }) catch
                    return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            }
            return 0;
        }

        fn onFrameRecv(
            session: ?*c.nghttp2_session,
            frame: [*c]const c.nghttp2_frame,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            const conn = connFromUserData(user_data);
            const hd = frame.*.hd;

            switch (hd.type) {
                c.NGHTTP2_HEADERS => {
                    if (frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;
                    const stream = streamFor(session, hd.stream_id) orelse return 0;
                    // Head complete: hand the stream to a handler task.
                    const group = conn.spawn_group orelse return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                    group.concurrent(conn.io, handleStream, .{ conn, stream }) catch {
                        log.err("h2: failed to spawn stream handler", .{});
                        stream.body.close(conn.io);
                        // The handler side will never exist; on_stream_close
                        // releases the protocol side after the reset.
                        stream.release(.handler);
                        _ = c.nghttp2_submit_rst_stream(session, @intCast(c.NGHTTP2_FLAG_NONE), hd.stream_id, @intCast(c.NGHTTP2_INTERNAL_ERROR));
                        return 0;
                    };
                    if (hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) {
                        stream.body.close(conn.io);
                    }
                },
                c.NGHTTP2_DATA => {
                    if (hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) {
                        const stream = streamFor(session, hd.stream_id) orelse return 0;
                        stream.body.close(conn.io);
                    }
                },
                else => {},
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
            const conn = connFromUserData(user_data);
            const stream = streamFor(session, stream_id) orelse return 0;
            // Cannot block: the queue holds a full window and the peer
            // cannot legally have more than a window in flight.
            const put = stream.body.put(conn.io, data[0..len], len) catch |err| switch (err) {
                // Handler is gone (or never spawned); drop the bytes, the
                // stream is on its way down.
                error.Closed => return 0,
                error.Canceled => return c.NGHTTP2_ERR_CALLBACK_FAILURE,
            };
            std.debug.assert(put == len);
            return 0;
        }

        fn onStreamClose(
            session: ?*c.nghttp2_session,
            stream_id: i32,
            error_code: u32,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            _ = session;
            const conn = connFromUserData(user_data);
            const stream = streamFor(conn.session, stream_id) orelse return 0;
            if (error_code != c.NGHTTP2_NO_ERROR) {
                stream.reset = true;
            }
            stream.body.close(conn.io);
            stream.release(.protocol);
            return 0;
        }

        /// Data provider: serves the stream's complete response body.
        fn onProvideData(
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
            const stream: *Stream = @ptrCast(@alignCast(source.*.ptr.?));
            const rest = stream.response_body[stream.response_sent..];
            const n = @min(rest.len, length);
            @memcpy(buf[0..n], rest[0..n]);
            stream.response_sent += n;
            if (stream.response_sent == stream.response_body.len) {
                data_flags.* = c.NGHTTP2_DATA_FLAG_EOF;
            }
            return @intCast(n);
        }
    };
}

test "h2: engine compiles and nghttp2 links" {
    std.testing.refAllDecls(Engine(void));
    const info = c.nghttp2_version(0);
    try std.testing.expect(info.*.age >= 1);
}
