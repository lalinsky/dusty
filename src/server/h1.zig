//! The HTTP/1.x engine: one task per connection runs the sequential
//! request/keepalive loop over the connection's blocking reader/writer.

const std = @import("std");
const zio = @import("zio");

const Connection = @import("connection.zig").Connection;
const RequestParser = @import("../parser.zig").RequestParser;
const RequestBodyReader = @import("../parser.zig").RequestBodyReader;
const Request = @import("../request.zig").Request;
const parseHeaders = @import("../request.zig").parseHeaders;
const Response = @import("../response.zig").Response;
const Executor = @import("../middleware.zig").Executor;

const log = std.log.scoped(.dusty);

pub fn Engine(comptime Ctx: type) type {
    return struct {
        const Server = @import("../server.zig").Server(Ctx);

        /// Runs the request loop over an initialized connection.
        pub fn serve(server: *Server, connection: *Connection, needs_shutdown: *bool) !void {
            if (connection.tls_conn != null) {
                // Per-request arena nested on the connection arena: resetting it
                // between keepalive requests reuses the connection's memory
                // without touching the TLS buffers carved above.
                var request_arena = std.heap.ArenaAllocator.init(connection.arena.allocator());
                return handleRequests(server, connection, &request_arena, needs_shutdown);
            }
            return handleRequests(server, connection, &connection.arena, needs_shutdown);
        }

        /// Runs the HTTP request/keepalive loop over a connection.
        fn handleRequests(
            server: *Server,
            connection: *Connection,
            arena: *std.heap.ArenaAllocator,
            needs_shutdown: *bool,
        ) !void {
            var request: Request = .{
                .arena = arena.allocator(),
                .io = server.io,
                .conn = connection.reader,
                .parser = undefined,
                .config = server.config.request,
                .remote_address = connection.stream.socket.address,
            };

            var parser: RequestParser = undefined;
            try parser.init(&request);
            defer parser.deinit();

            request.parser = &parser;

            var request_count: usize = 0;

            var timeout: zio.AutoCancel = .init;
            defer timeout.clear();

            // Allocate initial buffer from arena
            connection.reader.buffer = request.arena.alloc(u8, server.config.request.buffer_size + 1024) catch |err| {
                log.err("Failed to allocate read buffer: {}", .{err});
                return err;
            };

            while (true) {
                request_count += 1;

                if (server.config.timeout.request) |duration| {
                    // TODO(zio): drop once we require a zio with
                    // lalinsky/zio#657. `set` is meant to handle a re-arm
                    // itself, and stopped: it arms on the executor the task
                    // is on now, so re-arming after a migration asks one
                    // loop for a timer live in another's heap.
                    timeout.clear();
                    timeout.set(.fromMilliseconds(@intCast(duration.toMilliseconds())));
                }

                parseHeaders(connection.reader, &parser) catch |err| switch (err) {
                    error.EndOfStream => {
                        needs_shutdown.* = false;
                        return;
                    },
                    error.ReadFailed => return connection.getReadError() orelse error.ReadFailed,
                    else => |e| return e,
                };

                log.debug("Received: {f} {s}", .{ request.method, request.url });

                var response = try Response.init(arena.allocator(), connection, server.config.request.max_header_count);
                response.head = request.method == .head;
                request.response = &response;

                // Handle Expect header (100-continue)
                if (request.headers.get("Expect")) |expect| {
                    if (std.ascii.eqlIgnoreCase(expect, "100-continue")) {
                        request.expects_continue = true;
                    } else {
                        // Unknown Expect value - return 417
                        response.status = .expectation_failed;
                        response.keepalive = false;
                        try response.write();
                        return;
                    }
                }

                // Check if the connection allows keepalive
                if (!parser.shouldKeepAlive()) {
                    response.keepalive = false;
                }

                // Check if we've reached the request count limit
                if (server.config.timeout.request_count) |max_count| {
                    if (request_count >= max_count) {
                        response.keepalive = false;
                    }
                }

                const found = try server.router.findHandler(&request);
                var executor = Executor(Ctx){
                    .req = &request,
                    .res = &response,
                    .ctx = server.ctx,
                    .action = if (found) |r| r.action else null,
                    .middlewares = if (found) |r| r.middlewares else server.router.middlewares,
                };
                executor.run() catch |err| switch (err) {
                    error.ReadFailed => return connection.getReadError() orelse error.ReadFailed,
                    error.WriteFailed => return connection.getWriteError() orelse error.WriteFailed,
                    else => |e| return e,
                };

                if (!parser.isBodyComplete()) {
                    const max = server.config.request.max_body_size;
                    const drainable = blk: {
                        const cl = request.headers.get("Content-Length") orelse break :blk false;
                        const n = std.fmt.parseInt(usize, cl, 10) catch break :blk false;
                        break :blk n <= max;
                    };
                    if (drainable) {
                        var scratch: [4096]u8 = undefined;
                        var body_reader = RequestBodyReader.init(&parser, connection.reader, &scratch);
                        if (body_reader.interface.discardShort(max + 1)) |consumed| {
                            if (consumed > max) response.keepalive = false;
                        } else |_| {
                            if (connection.getReadError()) |e| if (e == error.Canceled) return error.Canceled;
                            response.keepalive = false;
                        }
                    } else {
                        response.keepalive = false;
                    }
                }

                if (server.shutting_down.load(.acquire)) {
                    response.keepalive = false;
                }

                try response.write();

                if (!response.keepalive) {
                    break;
                }

                parser.reset();
                request.reset();

                // If there's buffered data (pipelining), close connection - we don't support it
                if (connection.reader.end > connection.reader.seek) {
                    break;
                }

                _ = arena.reset(.retain_capacity);

                // Allocate fresh buffer for keepalive wait (previous buffer was freed by arena reset)
                connection.reader.buffer = request.arena.alloc(u8, server.config.request.buffer_size + 1024) catch |err| {
                    log.err("Failed to allocate read buffer: {}", .{err});
                    return err;
                };
                connection.reader.seek = 0;
                connection.reader.end = 0;

                if (server.config.timeout.keepalive) |duration| {
                    // TODO(zio): drop with the one above, same reason.
                    timeout.clear();
                    timeout.set(.fromMilliseconds(@intCast(duration.toMilliseconds())));
                }

                // Fill some data here, under the keepalive timeout
                connection.reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        needs_shutdown.* = false;
                        return;
                    },
                    error.ReadFailed => {
                        const e = connection.getReadError() orelse error.ReadFailed;
                        // Nothing is in flight between requests, so a peer
                        // that went away here has cost us nothing. The socket
                        // is already gone, so skip the shutdown syscall too.
                        if (Connection.isPeerGone(e)) {
                            needs_shutdown.* = false;
                            return;
                        }
                        return e;
                    },
                };
            }
        }
    };
}

test {
    _ = RequestParser;
}
