const std = @import("std");
const dusty = @import("root.zig");

fn testClientServer(comptime Ctx: type, ctx: *Ctx) !void {
    const io = std.testing.io;
    const TestServer = dusty.Server(Ctx);

    var server = TestServer.init(std.testing.allocator, io, .{}, ctx);
    defer server.deinit();

    try ctx.setup(&server);

    var server_future = try io.concurrent(struct {
        fn run(s: *TestServer) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *TestServer, test_ctx: *Ctx, _io: std.Io) !void {
            try s.ready.wait(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);

            try test_ctx.makeRequest(&writer.interface);

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const response = try reader.interface.takeDelimiterExclusive('\n');

            std.log.info("Response: {s}", .{response});
        }
    }.run, .{ &server, ctx, io });

    try client_future.await(io);
}

test "Server: POST with body" {
    const TestContext = struct {
        const Self = @This();

        body_received: bool = false,
        received_body: [256]u8 = undefined,
        received_len: usize = 0,

        pub fn setup(ctx: *Self, server: *dusty.Server(Self)) !void {
            _ = ctx;
            server.router.post("/test", handlePost);
        }

        pub fn makeRequest(ctx: *Self, writer: *std.Io.Writer) !void {
            _ = ctx;
            const request_body = "Hello from test!";
            try writer.print("POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}", .{ request_body.len, request_body });
            try writer.flush();
        }

        fn handlePost(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            var reader = req.reader();

            var writer = std.Io.Writer.fixed(&ctx.received_body);
            const n = try reader.interface.streamRemaining(&writer);

            ctx.body_received = true;
            ctx.received_len = n;

            std.log.info("Received body: {s}", .{ctx.received_body[0..n]});

            res.body = "OK\n";
        }
    };

    var ctx: TestContext = .{};
    try testClientServer(TestContext, &ctx);

    try std.testing.expect(ctx.body_received);
    try std.testing.expectEqualStrings("Hello from test!", ctx.received_body[0..ctx.received_len]);
}

test "Server: POST with chunked encoding" {
    const TestContext = struct {
        const Self = @This();

        body_received: bool = false,
        received_body: [256]u8 = undefined,
        received_len: usize = 0,

        pub fn setup(ctx: *Self, server: *dusty.Server(Self)) !void {
            _ = ctx;
            server.router.post("/chunked", handlePost);
        }

        pub fn makeRequest(ctx: *Self, writer: *std.Io.Writer) !void {
            _ = ctx;
            try writer.writeAll("POST /chunked HTTP/1.1\r\n");
            try writer.writeAll("Host: localhost\r\n");
            try writer.writeAll("Transfer-Encoding: chunked\r\n");
            try writer.writeAll("\r\n");
            try writer.flush();

            try writer.writeAll("6\r\n");
            try writer.writeAll("Hello \r\n");
            try writer.flush();

            try writer.writeAll("5\r\n");
            try writer.writeAll("from \r\n");
            try writer.flush();

            try writer.writeAll("D\r\n");
            try writer.writeAll("chunked test!\r\n");
            try writer.flush();

            try writer.writeAll("0\r\n");
            try writer.writeAll("\r\n");
            try writer.flush();
        }

        fn handlePost(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            var reader = req.reader();

            var writer = std.Io.Writer.fixed(&ctx.received_body);
            const n = try reader.interface.streamRemaining(&writer);

            ctx.body_received = true;
            ctx.received_len = n;

            std.log.info("Received chunked body: {s}", .{ctx.received_body[0..n]});

            res.body = "OK\n";
        }
    };

    var ctx: TestContext = .{};
    try testClientServer(TestContext, &ctx);

    try std.testing.expect(ctx.body_received);
    try std.testing.expectEqualStrings("Hello from chunked test!", ctx.received_body[0..ctx.received_len]);
}

test "Server: GET with no body" {
    const TestContext = struct {
        const Self = @This();

        reader_tested: bool = false,
        read_len: usize = 0,

        pub fn setup(ctx: *Self, server: *dusty.Server(Self)) !void {
            _ = ctx;
            server.router.get("/test", handleGet);
        }

        pub fn makeRequest(ctx: *Self, writer: *std.Io.Writer) !void {
            _ = ctx;
            try writer.writeAll("GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try writer.flush();
        }

        fn handleGet(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            var reader = req.reader();

            var body_buf: [256]u8 = undefined;
            var writer = std.Io.Writer.fixed(&body_buf);
            const n = reader.interface.streamRemaining(&writer) catch |err| blk: {
                if (err == error.EndOfStream) break :blk 0;
                return err;
            };

            ctx.reader_tested = true;
            ctx.read_len = n;

            std.log.info("Read {d} bytes from GET request body", .{n});

            res.body = "OK\n";
        }
    };

    var ctx: TestContext = .{};
    try testClientServer(TestContext, &ctx);

    try std.testing.expect(ctx.reader_tested);
    try std.testing.expectEqual(0, ctx.read_len);
}

test "Server: HTTP/1.0 GET request" {
    const TestContext = struct {
        const Self = @This();

        request_handled: bool = false,
        version_major: u16 = 0,
        version_minor: u16 = 0,

        pub fn setup(ctx: *Self, server: *dusty.Server(Self)) !void {
            _ = ctx;
            server.router.get("/http10", handleGet);
        }

        pub fn makeRequest(ctx: *Self, writer: *std.Io.Writer) !void {
            _ = ctx;
            try writer.writeAll("GET /http10 HTTP/1.0\r\n\r\n");
            try writer.flush();
        }

        fn handleGet(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            ctx.request_handled = true;
            ctx.version_major = req.version_major;
            ctx.version_minor = req.version_minor;

            res.body = "HTTP/1.0 OK\n";
        }
    };

    var ctx: TestContext = .{};
    try testClientServer(TestContext, &ctx);

    try std.testing.expect(ctx.request_handled);
    try std.testing.expectEqual(1, ctx.version_major);
    try std.testing.expectEqual(0, ctx.version_minor);
}

test "Server: WebSocket echo" {
    const io = std.testing.io;

    const TestContext = struct {
        const Self = @This();

        ws_upgraded: bool = false,
        message_received: bool = false,
        received_msg: [256]u8 = undefined,
        received_len: usize = 0,

        pub fn setup(ctx: *Self, server: *dusty.Server(Self)) !void {
            _ = ctx;
            server.router.get("/ws", handleWebSocket);
        }

        fn handleWebSocket(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            var ws = try res.upgradeWebSocket(req) orelse {
                res.status = .bad_request;
                return;
            };

            ctx.ws_upgraded = true;

            try ws.send(.text, "Welcome!");

            const msg = ws.receive() catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };

            if (msg.type == .text) {
                ctx.message_received = true;
                ctx.received_len = @min(msg.data.len, ctx.received_msg.len);
                @memcpy(ctx.received_msg[0..ctx.received_len], msg.data[0..ctx.received_len]);
                try ws.send(.text, msg.data);
            }
        }
    };

    var ctx: TestContext = .{};

    var server = dusty.Server(TestContext).init(std.testing.allocator, io, .{}, &ctx);
    defer server.deinit();

    try ctx.setup(&server);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(TestContext)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(TestContext), _io: std.Io) !void {
            try s.ready.wait(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            const w = &writer.interface;

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const r = &reader.interface;

            try w.writeAll("GET /ws HTTP/1.1\r\n");
            try w.writeAll("Host: localhost\r\n");
            try w.writeAll("Upgrade: websocket\r\n");
            try w.writeAll("Connection: Upgrade\r\n");
            try w.writeAll("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n");
            try w.writeAll("Sec-WebSocket-Version: 13\r\n");
            try w.writeAll("\r\n");
            try w.flush();

            var response_buf: [512]u8 = undefined;
            var response_len: usize = 0;
            while (response_len < response_buf.len - 1) {
                const buffered = r.buffered();
                if (buffered.len > 0) {
                    response_buf[response_len] = buffered[0];
                    r.toss(1);
                    response_len += 1;
                    if (response_len >= 4 and
                        response_buf[response_len - 4] == '\r' and
                        response_buf[response_len - 3] == '\n' and
                        response_buf[response_len - 2] == '\r' and
                        response_buf[response_len - 1] == '\n')
                    {
                        break;
                    }
                } else {
                    try r.fillMore();
                }
            }
            const response_str = response_buf[0..response_len];
            try std.testing.expect(std.mem.indexOf(u8, response_str, "101") != null);
            try std.testing.expect(std.mem.indexOf(u8, response_str, "Sec-WebSocket-Accept") != null);

            const readExact = struct {
                fn read(rdr: *std.Io.Reader, dest: []u8) !void {
                    var filled: usize = 0;
                    while (filled < dest.len) {
                        const buffered = rdr.buffered();
                        if (buffered.len > 0) {
                            const to_copy = @min(buffered.len, dest.len - filled);
                            @memcpy(dest[filled..][0..to_copy], buffered[0..to_copy]);
                            rdr.toss(to_copy);
                            filled += to_copy;
                        } else {
                            try rdr.fillMore();
                        }
                    }
                }
            }.read;

            var frame_header: [2]u8 = undefined;
            try readExact(r, &frame_header);
            try std.testing.expectEqual(0x81, frame_header[0]);
            const welcome_len = frame_header[1] & 0x7F;
            const welcome = try std.testing.allocator.alloc(u8, welcome_len);
            defer std.testing.allocator.free(welcome);
            try readExact(r, welcome);
            try std.testing.expectEqualStrings("Welcome!", welcome);

            const masked_hello = [_]u8{
                0x81,
                0x85,
                0x37,
                0xfa,
                0x21,
                0x3d,
                'H' ^ 0x37,
                'e' ^ 0xfa,
                'l' ^ 0x21,
                'l' ^ 0x3d,
                'o' ^ 0x37,
            };
            try w.writeAll(&masked_hello);
            try w.flush();

            try readExact(r, &frame_header);
            try std.testing.expectEqual(0x81, frame_header[0]);
            const echo_len = frame_header[1] & 0x7F;
            const echo = try std.testing.allocator.alloc(u8, echo_len);
            defer std.testing.allocator.free(echo);
            try readExact(r, echo);
            try std.testing.expectEqualStrings("Hello", echo);

            std.log.info("WebSocket test passed: received echo '{s}'", .{echo});
        }
    }.run, .{ &server, io });

    try client_future.await(io);

    try std.testing.expect(ctx.ws_upgraded);
    try std.testing.expect(ctx.message_received);
    try std.testing.expectEqualStrings("Hello", ctx.received_msg[0..ctx.received_len]);
}

test "Server: void context handlers" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/test", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "Hello from void context!\n";
        }
    }.handle);

    server.router.post("/echo", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            var reader = req.reader();
            const body = try reader.interface.allocRemaining(req.arena, .limited(1024));
            res.body = try std.fmt.allocPrint(res.arena, "Echo: {s}\n", .{body});
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.ready.wait(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);

            try writer.interface.writeAll("GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try writer.interface.flush();

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');

            std.log.info("Response: {s}", .{status_line});
            try std.testing.expect(std.mem.indexOf(u8, status_line, "200 OK") != null);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: graceful shutdown drain still blocks after an earlier connection closed" {
    const io = std.testing.io;

    const sync = struct {
        var slow_started: std.Io.Event = .unset;
    };
    sync.slow_started = .unset;

    // Short enough to expire long before the 2s handler finishes, so the
    // drain has to give up rather than wait it out.
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .timeout = .{ .shutdown = .fromMilliseconds(100) },
    }, {});
    defer server.deinit();

    server.router.get("/fast", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "OK";
        }
    }.handle);

    server.router.get("/slow", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            sync.slow_started.set(req.io);
            try req.io.sleep(.fromMilliseconds(2000), .awake);
            res.body = "slow";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    // cancel() is idempotent, so this is a no-op after the expectError below
    // consumes the future; it only matters if the test fails early.
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    // A connection closes before shutdown begins.
    {
        const stream = try server.address.ip.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        defer stream.shutdown(io, .both) catch {};

        var write_buf: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll("GET /fast HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();

        var read_buf: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        const status_line = try reader.interface.takeDelimiterExclusive('\n');
        try std.testing.expect(std.mem.indexOf(u8, status_line, "200 OK") != null);
    }

    // Wait until the server has fully torn down that connection.
    while (server.active_connections.load(.acquire) != 0) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    // Park a slow handler so shutdown has an active connection to drain.
    const slow_stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer slow_stream.close(io);
    defer slow_stream.shutdown(io, .both) catch {};

    var slow_write_buf: [1024]u8 = undefined;
    var slow_writer = slow_stream.writer(io, &slow_write_buf);
    try slow_writer.interface.writeAll("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try slow_writer.interface.flush();

    try sync.slow_started.wait(io);

    // Graceful shutdown: the drain must block, and give up when its budget
    // runs out rather than wait out the 2s handler. The elapsed time is what
    // shows that -- before the fix the drain spun hot until the handler
    // finished, which took the full two seconds. `listen` reports the
    // cancellation either way; the drain no longer reports how it went.
    const start = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, server_future.cancel(io));
    const elapsed_ns = std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds;
    try std.testing.expect(elapsed_ns < 1500 * std.time.ns_per_ms);
}

test "Server: 100-continue" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.post("/upload", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            const body = try req.body();
            res.body = body orelse "";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.ready.wait(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);

            const body = "Hello, World!";
            try writer.interface.print("POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\nExpect: 100-continue\r\n\r\n", .{body.len});
            try writer.interface.flush();

            const continue_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expect(std.mem.indexOf(u8, continue_line, "100 Continue") != null);
            reader.interface.toss(1);
            _ = try reader.interface.takeDelimiterExclusive('\n');
            reader.interface.toss(1);

            try writer.interface.writeAll(body);
            try writer.interface.flush();

            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expect(std.mem.indexOf(u8, status_line, "200 OK") != null);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

fn readResponse(r: *std.Io.Reader, status_buf: []u8, body_buf: []u8) !struct { status: []const u8, body: []const u8 } {
    const status_line = try r.takeDelimiterExclusive('\n');
    const status_len = @min(status_line.len, status_buf.len);
    @memcpy(status_buf[0..status_len], status_line[0..status_len]);
    r.toss(1);

    var content_length: usize = 0;
    while (true) {
        const line = try r.takeDelimiterExclusive('\n');
        r.toss(1);
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const value = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }

    const body_len = @min(content_length, body_buf.len);
    var got: usize = 0;
    while (got < body_len) {
        if (r.buffered().len == 0) try r.fillMore();
        const buffered = r.buffered();
        const to_copy = @min(buffered.len, body_len - got);
        @memcpy(body_buf[got..][0..to_copy], buffered[0..to_copy]);
        r.toss(to_copy);
        got += to_copy;
    }

    return .{ .status = status_buf[0..status_len], .body = body_buf[0..body_len] };
}

test "Server: keepalive after handler ignores request body" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.post("/ignore", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "first";
        }
    }.handle);

    server.router.get("/ping", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "second";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    const body = "this body is ignored";
    try w.print("POST /ignore HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    try w.flush();

    var status1: [64]u8 = undefined;
    var body1: [32]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expect(std.mem.indexOf(u8, resp1.status, "200") != null);
    try std.testing.expectEqualStrings("first", resp1.body);

    try w.writeAll("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    const resp2 = try readResponse(r, &status2, &body2);
    try std.testing.expect(std.mem.indexOf(u8, resp2.status, "200") != null);
    try std.testing.expectEqualStrings("second", resp2.body);
}

test "Server: handler error yields 500 and keeps the connection alive" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/boom", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            _ = res;
            return error.Boom;
        }
    }.handle);

    server.router.get("/ok", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "ok";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    // A handler that returns an error must still produce a written 500 response,
    // not tear down the connection with no reply.
    try w.writeAll("GET /boom HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status1: [64]u8 = undefined;
    var body1: [64]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expect(std.mem.indexOf(u8, resp1.status, "500") != null);

    // The connection stays alive, so a subsequent request still works.
    try w.writeAll("GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status2: [64]u8 = undefined;
    var body2: [64]u8 = undefined;
    const resp2 = try readResponse(r, &status2, &body2);
    try std.testing.expect(std.mem.indexOf(u8, resp2.status, "200") != null);
    try std.testing.expectEqualStrings("ok", resp2.body);
}

test "Server: an event stream is chunked and leaves the connection reusable" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/events", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            var events = try res.startEventStream();
            try events.send("first", .{ .event = "tick", .id = "1" });
            try events.send("second", .{});
        }
    }.handle);

    server.router.get("/ok", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "ok";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    try w.writeAll("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    // Read up to the chunked terminator, which is where the stream ends and
    // the connection becomes free for the next request.
    var got: [1024]u8 = undefined;
    var len: usize = 0;
    while (std.mem.indexOf(u8, got[0..len], "0\r\n\r\n") == null) {
        r.fillMore() catch break;
        const buffered = r.buffered();
        if (buffered.len == 0) break;
        const to_copy = @min(buffered.len, got.len - len);
        @memcpy(got[len..][0..to_copy], buffered[0..to_copy]);
        r.toss(to_copy);
        len += to_copy;
    }
    const reply = got[0..len];

    try std.testing.expect(std.mem.indexOf(u8, reply, "Content-Type: text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Transfer-Encoding: chunked") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Content-Length") == null);
    // Each event sits between a chunk header and its trailing CRLF, so it
    // reached the peer on its own rather than when a buffer filled.
    try std.testing.expect(std.mem.indexOf(u8, reply, "\r\nevent: tick\nid: 1\ndata: first\n\n\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\r\ndata: second\n\n\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, reply, "0\r\n\r\n"));

    // Chunks end the stream without ending the connection, so the next
    // request on it is still answered.
    try w.writeAll("GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status2: [64]u8 = undefined;
    var body2: [64]u8 = undefined;
    const resp2 = try readResponse(r, &status2, &body2);
    try std.testing.expect(std.mem.indexOf(u8, resp2.status, "200") != null);
    try std.testing.expectEqualStrings("ok", resp2.body);
}

test "Server: handler error after streaming started aborts the connection" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/bad-stream", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            // Start streaming, then fail - the headers and first chunk are
            // already on the wire, so the error can't be turned into a 500.
            var body_buf: [64]u8 = undefined;
            var body = try res.stream(&body_buf);
            try body.interface.writeAll("partial");
            try body.interface.flush();
            return error.Boom;
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    try w.writeAll("GET /bad-stream HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    // Read everything the server sends before closing the connection.
    var received: [256]u8 = undefined;
    var received_len: usize = 0;
    while (received_len < received.len) {
        r.fillMore() catch break;
        const buffered = r.buffered();
        if (buffered.len == 0) break;
        const to_copy = @min(buffered.len, received.len - received_len);
        @memcpy(received[received_len..][0..to_copy], buffered[0..to_copy]);
        r.toss(to_copy);
        received_len += to_copy;
    }
    const got = received[0..received_len];

    // The partial chunk was already flushed before the handler errored...
    try std.testing.expect(std.mem.indexOf(u8, got, "partial") != null);
    // ...but the chunked terminator must be absent: the connection was
    // aborted instead of silently completing a truncated, "successful" body.
    try std.testing.expect(std.mem.indexOf(u8, got, "0\r\n\r\n") == null);

    // The connection must not stay alive for reuse.
    w.writeAll("GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n") catch {};
    w.flush() catch {};
    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    _ = readResponse(r, &status2, &body2) catch return;
    return error.TestExpectedConnectionToBeClosed;
}

test "Server: closes connection when unread body exceeds max_body_size" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(
        std.testing.allocator,
        io,
        .{ .request = .{ .max_body_size = 100 } },
        {},
    );
    defer server.deinit();

    server.router.post("/ignore", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "first";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    const body = "x" ** 200;
    try w.print("POST /ignore HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    try w.flush();

    var status1: [64]u8 = undefined;
    var body1: [32]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expect(std.mem.indexOf(u8, resp1.status, "200") != null);
    try std.testing.expectEqualStrings("first", resp1.body);

    w.writeAll("GET /ignore HTTP/1.1\r\nHost: localhost\r\n\r\n") catch {};
    w.flush() catch {};

    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    _ = readResponse(r, &status2, &body2) catch return;
    return error.TestExpectedSecondResponseToFail;
}

test "Server: 417 Expectation Failed for unknown Expect value" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.post("/upload", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            const body = try req.body();
            res.body = body orelse "";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.ready.wait(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);

            try writer.interface.writeAll("POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nExpect: unknown-value\r\n\r\n");
            try writer.interface.flush();

            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expect(std.mem.indexOf(u8, status_line, "417") != null);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}
test "Server: HEAD is answered by the GET route with no body" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/thing", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.content_type = .text;
            res.body = "0123456789";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.ready.wait(_io);
            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            var conn_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &conn_buf);

            try writer.interface.writeAll("HEAD /thing HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            try writer.interface.flush();

            var rest: [2048]u8 = undefined;
            var sink: std.Io.Writer = .fixed(&rest);
            _ = reader.interface.streamRemaining(&sink) catch {};
            const got = sink.buffered();

            try std.testing.expect(std.mem.indexOf(u8, got, "HTTP/1.1 200") != null);
            // The length a GET would have reported...
            try std.testing.expect(std.mem.indexOf(u8, got, "Content-Length: 10") != null);
            // ...and none of those bytes.
            try std.testing.expect(std.mem.indexOf(u8, got, "0123456789") == null);
            try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\n"));
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: graceful shutdown waits for a connection that finishes in time" {
    const io = std.testing.io;

    const sync = struct {
        var started: std.Io.Event = .unset;
        var finished: bool = false;
    };
    sync.started = .unset;
    sync.finished = false;

    // Comfortably longer than the handler, so the drain has no reason to
    // give up on it.
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .timeout = .{ .shutdown = .fromMilliseconds(5000) },
    }, {});
    defer server.deinit();

    server.router.get("/slow", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            sync.started.set(req.io);
            try req.io.sleep(.fromMilliseconds(200), .awake);
            sync.finished = true;
            res.body = "slow";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();

    try sync.started.wait(io);

    const start = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, server_future.cancel(io));
    const elapsed_ns = std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds;

    // Waited for the handler rather than abandoning it, and stopped as soon
    // as it was done rather than sitting out the rest of the budget.
    try std.testing.expect(sync.finished);
    try std.testing.expect(elapsed_ns >= 100 * std.time.ns_per_ms);
    try std.testing.expect(elapsed_ns < 2000 * std.time.ns_per_ms);
}
test "Server: request carries the peer address" {
    const io = std.testing.io;

    const Ctx = struct {
        seen: [2]?std.Io.net.IpAddress = @splat(null),
        count: usize = 0,
    };
    var ctx: Ctx = .{};

    var server = dusty.Server(Ctx).init(std.testing.allocator, io, .{}, &ctx);
    defer server.deinit();

    server.router.get("/whoami", struct {
        fn handle(c: *Ctx, req: *dusty.Request, res: *dusty.Response) !void {
            if (c.count < c.seen.len) c.seen[c.count] = req.remote_address;
            c.count += 1;
            res.body = "OK\n";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(Ctx)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(Ctx), _io: std.Io) !void {
            try s.ready.wait(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            var conn_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &conn_buf);

            // Two requests on the one connection: the address belongs to
            // the connection, so the reset between them must not drop it.
            // Sent one at a time, since a pipelined second request is not
            // picked up. The second asks the server to close, so reading
            // to EOF proves its handler finished rather than guessing at
            // the framing.
            try writer.interface.writeAll("GET /whoami HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try writer.interface.flush();
            try readOneResponse(&reader.interface);

            try writer.interface.writeAll("GET /whoami HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            try writer.interface.flush();
            var rest: [2048]u8 = undefined;
            var sink: std.Io.Writer = .fixed(&rest);
            _ = reader.interface.streamRemaining(&sink) catch {};
            try std.testing.expect(std.mem.indexOf(u8, sink.buffered(), "HTTP/1.1 200") != null);
        }

        fn readOneResponse(r: *std.Io.Reader) !void {
            var content_length: usize = 0;
            while (true) {
                const line = std.mem.trimEnd(u8, try r.takeDelimiterExclusive('\n'), "\r");
                if (line.len == 0) break;
                const prefix = "Content-Length: ";
                if (std.ascii.startsWithIgnoreCase(line, prefix)) {
                    content_length = try std.fmt.parseInt(usize, line[prefix.len..], 10);
                }
            }
            _ = try r.take(content_length);
        }
    }.run, .{ &server, io });

    try client_future.await(io);

    try std.testing.expectEqual(@as(usize, 2), ctx.count);
    for (ctx.seen) |maybe| {
        const seen = maybe orelse return error.HandlerNeverRan;
        // The client connects over IPv4 loopback, so that is what the peer
        // must be -- not the unspecified default, and not the listen
        // address, whose port belongs to the server.
        try std.testing.expect(seen == .ip4);
        try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, seen.ip4.bytes);
        try std.testing.expect(seen.ip4.port != 0);
    }
    // The same connection, so the same peer both times.
    try std.testing.expect(ctx.seen[0].?.ip4.eql(ctx.seen[1].?.ip4));
}

test "Server: client_auth with ca .none is rejected by listen" {
    if (!@import("build_options").use_tls) return error.SkipZigTest;
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .tls = .{
            .cert_path = "examples/certs/cert.pem",
            .key_path = "examples/certs/key.pem",
            .client_auth = .{ .ca = .none },
        },
    }, {});
    defer server.deinit();

    const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
    try std.testing.expectError(error.NoCertificateAuthority, server.listen(addr));
}
