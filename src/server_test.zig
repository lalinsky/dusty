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
            var read_buf: [1024]u8 = undefined;
            var reader = try req.reader(&read_buf);

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

test "Server: a gzip request body reaches the handler decoded" {
    const TestContext = struct {
        const Self = @This();

        // "Hello from test!", gzip compressed.
        const gzip_body = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\xf3\x48\xcd\xc9\xc9\x57" ++
            "\x48\x2b\xca\xcf\x55\x28\x49\x2d\x2e\x51\x04\x00\x7c\xe6\xd9\x99\x10\x00\x00\x00";

        received_body: [256]u8 = undefined,
        received_len: usize = 0,

        pub fn setup(ctx: *Self, server: *dusty.Server(Self)) !void {
            _ = ctx;
            server.router.post("/gzip", handlePost);
        }

        pub fn makeRequest(ctx: *Self, writer: *std.Io.Writer) !void {
            _ = ctx;
            try writer.print(
                "POST /gzip HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ gzip_body.len, gzip_body },
            );
            try writer.flush();
        }

        fn handlePost(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            var read_buf: [1024]u8 = undefined;
            var reader = try req.reader(&read_buf);
            var writer = std.Io.Writer.fixed(&ctx.received_body);
            ctx.received_len = try reader.interface.streamRemaining(&writer);
            res.body = "OK\n";
        }
    };

    var ctx: TestContext = .{};
    try testClientServer(TestContext, &ctx);

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
            var read_buf: [1024]u8 = undefined;
            var reader = try req.reader(&read_buf);

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
            var read_buf: [1024]u8 = undefined;
            var reader = try req.reader(&read_buf);

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

test "Server: a streamed body to an HTTP/1.0 client is not chunked" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/stream", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            var buf: [64]u8 = undefined;
            var body = try res.stream(&buf);
            try body.interface.writeAll("hello ");
            try body.interface.flush();
            try body.interface.writeAll("world");
            try body.end();
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

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("GET /stream HTTP/1.0\r\n\r\n");
    try writer.interface.flush();

    // The body ends when the connection does.
    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const raw = try reader.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(raw);

    try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, raw, "Transfer-Encoding") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Content-Length") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, raw, "\r\n\r\nhello world"));
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
            var read_buf: [1024]u8 = undefined;
            var reader = try req.reader(&read_buf);
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

/// Serves `/a`, `/b` and `/c` with their names, `/b` from its request body
/// and `/a` for any method without reading one. What a pipelining test
/// needs: enough routes to tell the responses apart, and bodies read and
/// unread for the parser to get past.
const PipelineCtx = struct {
    fn setup(server: *dusty.Server(void)) void {
        server.router.any("/a", struct {
            fn handle(_: *dusty.Request, res: *dusty.Response) !void {
                res.body = "a";
            }
        }.handle);
        server.router.post("/b", struct {
            fn handle(req: *dusty.Request, res: *dusty.Response) !void {
                res.body = (try req.body()) orelse "no body";
            }
        }.handle);
        server.router.get("/c", struct {
            fn handle(_: *dusty.Request, res: *dusty.Response) !void {
                res.body = "c";
            }
        }.handle);
    }
};

/// Sends `requests` in a single write and checks that every response in
/// `expected` comes back, in order, on the same connection.
fn expectPipelinedResponses(
    server: *dusty.Server(void),
    requests: []const u8,
    expected: []const []const u8,
) !void {
    const io = std.testing.io;

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(requests);
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);

    for (expected) |want| {
        var status: [64]u8 = undefined;
        var body: [64]u8 = undefined;
        const resp = try readResponse(&reader.interface, &status, &body);
        try std.testing.expect(std.mem.indexOf(u8, resp.status, "200") != null);
        try std.testing.expectEqualStrings(want, resp.body);
    }
}

test "Server: pipelined requests are answered in order on one connection" {
    var server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{}, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

    try expectPipelinedResponses(
        &server,
        "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
            "GET /c HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
            "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n",
        &.{ "a", "c", "a" },
    );
}

test "Server: a pipelined request behind a body is served after it" {
    var server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{}, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

    try expectPipelinedResponses(
        &server,
        "POST /b HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello" ++
            "GET /c HTTP/1.1\r\nHost: localhost\r\n\r\n",
        &.{ "hello", "c" },
    );
}

test "Server: a pipelined request behind an unread body is served after it is drained" {
    var server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{}, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

    // `/a` never reads its body, so the server has to skip it to find the
    // request behind it.
    try expectPipelinedResponses(
        &server,
        "POST /a HTTP/1.1\r\nHost: localhost\r\nContent-Length: 7\r\n\r\nignored" ++
            "GET /c HTTP/1.1\r\nHost: localhost\r\n\r\n",
        &.{ "a", "c" },
    );
}

test "Server: a pipelined head that needs the whole read buffer is served" {
    // Under a 1024-byte head limit the read buffer is 2048 bytes, so two
    // heads of 1000 bytes arrive in one read. The second parses only if the
    // first has been moved out of its way: what it left the reader would
    // be too small for the reserve the body reader is owed.
    var server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{
        .request = .{ .buffer_size = 1024 },
    }, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

    var requests: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer requests.deinit();
    for (0..2) |_| {
        const prefix = "GET /c HTTP/1.1\r\nHost: localhost\r\nX-Pad: ";
        const suffix = "\r\n\r\n";
        try requests.writer.writeAll(prefix);
        try requests.writer.splatByteAll('A', 1000 - prefix.len - suffix.len);
        try requests.writer.writeAll(suffix);
    }

    try expectPipelinedResponses(&server, requests.written(), &.{ "c", "c" });
}

test "Server: a pipelined head that arrives in two parts is served" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

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

    // The start of the second head rides behind the first request, and the
    // rest only comes once the first has been answered.
    try w.writeAll("GET /a HTTP/1.1\r\nHost: localhost\r\n\r\nGET /c HTTP/1.1\r\nHo");
    try w.flush();

    var status1: [64]u8 = undefined;
    var body1: [32]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expectEqualStrings("a", resp1.body);

    try w.writeAll("st: localhost\r\n\r\n");
    try w.flush();

    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    const resp2 = try readResponse(r, &status2, &body2);
    try std.testing.expectEqualStrings("c", resp2.body);
}

test "Server: Connection: close on a pipelined request ends the connection after it" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

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
    try writer.interface.writeAll("GET /a HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" ++
        "GET /c HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    var status1: [64]u8 = undefined;
    var body1: [32]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expectEqualStrings("a", resp1.body);

    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, readResponse(r, &status2, &body2));
}

test "Server: a handler's own EndOfStream is a 500, not a vanished peer" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/eof", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            var buf: [64]u8 = undefined;
            var r = try req.reader(&buf);
            // Nothing to read, so the std helper reports the end of the
            // body the way a peer hanging up is spelled.
            _ = try r.interface.takeDelimiterExclusive('\n');
            res.body = "unreachable";
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

    try w.writeAll("GET /eof HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status1: [64]u8 = undefined;
    var body1: [64]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expect(std.mem.indexOf(u8, resp1.status, "500") != null);

    try w.writeAll("GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status2: [64]u8 = undefined;
    var body2: [64]u8 = undefined;
    const resp2 = try readResponse(r, &status2, &body2);
    try std.testing.expect(std.mem.indexOf(u8, resp2.status, "200") != null);
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
            var event_buf: [4096]u8 = undefined;
            var events = try res.startEventStream(&event_buf);
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

test "Server: keepalive after handler ignores a compressed request body" {
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

    // The handler never reads it, so the drain has to throw away the wire
    // bytes -- and the header saying how many there are is one decoding
    // would have removed, had anything asked it to.
    const gzip_body = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\x2b\xc9\xc8\x2c\x56\x48" ++
        "\xca\x4f\xa9\x54\x00\xd2\x99\xe9\x79\xf9\x45\xa9\x29\x00\x79\xf5\xd8\x44\x14\x00\x00\x00";
    try w.print(
        "POST /ignore HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ gzip_body.len, gzip_body },
    );
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
/// Sends `raw` to a server with one GET route at `/` and returns the status
/// line it answers with.
fn statusLineFor(raw: []const u8, out: []u8) ![]const u8 {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "OK";
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
        fn run(s: *dusty.Server(void), _io: std.Io, request: []const u8, status_out: []u8) ![]const u8 {
            try s.ready.wait(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);

            try writer.interface.writeAll(request);
            try writer.interface.flush();

            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            @memcpy(status_out[0..status_line.len], status_line);
            return status_out[0..status_line.len];
        }
    }.run, .{ &server, io, raw, out });

    return client_future.await(io);
}

test "Server: a bad percent escape in the query is a 400, not a dropped connection" {
    var buf: [256]u8 = undefined;
    const status = try statusLineFor("GET /?q=100% HTTP/1.1\r\nHost: localhost\r\n\r\n", &buf);
    try std.testing.expectStringStartsWith(status, "HTTP/1.1 400 ");
}

test "Server: too many query parameters is a 400, not a dropped connection" {
    // One past the default limit of 32, each under its own name.
    const query = comptime blk: {
        var q: []const u8 = "";
        for (0..33) |i| q = q ++ std.fmt.comptimePrint("k{d}=v&", .{i});
        break :blk q;
    };
    var buf: [256]u8 = undefined;
    const status = try statusLineFor("GET /?" ++ query ++ " HTTP/1.1\r\nHost: localhost\r\n\r\n", &buf);
    try std.testing.expectStringStartsWith(status, "HTTP/1.1 400 ");
}

test "Server: more headers than the limit is a 431, not a dropped connection" {
    // One past the default limit of 32.
    const headers = comptime blk: {
        var h: []const u8 = "";
        for (0..33) |i| h = h ++ std.fmt.comptimePrint("X-H{d}: v\r\n", .{i});
        break :blk h;
    };
    var buf: [256]u8 = undefined;
    const status = try statusLineFor("GET / HTTP/1.1\r\nHost: localhost\r\n" ++ headers ++ "\r\n", &buf);
    try std.testing.expectStringStartsWith(status, "HTTP/1.1 431 ");
}

test "Server: a response written without reading the body does not wait for one held back by Expect" {
    // No POST route, so the 404 is written by nothing that reads the body,
    // and the peer never sends it: it is waiting for 100 Continue.
    var buf: [256]u8 = undefined;
    const status = try statusLineFor("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n", &buf);
    try std.testing.expectStringStartsWith(status, "HTTP/1.1 404 ");
}

test "Server: a body sent without waiting for 100 Continue is drained and the connection kept" {
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

    // Expect, and the body right behind it: the peer is not waiting.
    const body = "this body is ignored";
    try w.print("POST /ignore HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\nExpect: 100-continue\r\n\r\n{s}", .{ body.len, body });
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
/// Leaves one connection idle after a request and one that never sent any,
/// shuts the server down with a budget long enough that waiting it out would
/// be unmistakable, and checks that both were closed at once.
fn expectIdleConnectionsClosedOnShutdown(timeout: dusty.ServerConfig.Timeout) !void {
    const io = std.testing.io;

    var config: dusty.ServerConfig = .{ .timeout = timeout };
    config.timeout.shutdown = .fromMilliseconds(5000);
    var server = dusty.Server(void).init(std.testing.allocator, io, config, {});
    defer server.deinit();

    server.router.get("/", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "OK";
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

    // One connection idle after a request, one that never sent any.
    const used = try server.address.ip.connect(io, .{ .mode = .stream });
    defer used.close(io);
    const fresh = try server.address.ip.connect(io, .{ .mode = .stream });
    defer fresh.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = used.writer(io, &write_buf);
    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = used.reader(io, &read_buf);
    var status: [64]u8 = undefined;
    var body: [16]u8 = undefined;
    const resp = try readResponse(&reader.interface, &status, &body);
    try std.testing.expectEqualStrings("OK", resp.body);

    const start = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, server_future.cancel(io));
    const elapsed_ns = std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds;
    try std.testing.expect(elapsed_ns < 1000 * std.time.ns_per_ms);

    // Both were closed by the server, not abandoned to the cancel.
    try std.testing.expectError(error.EndOfStream, reader.interface.fillMore());
    var fresh_buf: [64]u8 = undefined;
    var fresh_reader = fresh.reader(io, &fresh_buf);
    try std.testing.expectError(error.EndOfStream, fresh_reader.interface.fillMore());
}

test "Server: a request arriving during the shutdown drain is refused, not served" {
    const io = std.testing.io;

    const sync = struct {
        var started: std.Io.Event = .unset;
        var release: std.Io.Event = .unset;
    };
    sync.started = .unset;
    sync.release = .unset;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .timeout = .{ .shutdown = .fromMilliseconds(5000) },
    }, {});
    defer server.deinit();

    // Holds the drain open until the test lets it go.
    server.router.get("/slow", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            sync.started.set(req.io);
            try sync.release.wait(req.io);
            res.body = "slow";
        }
    }.handle);
    server.router.get("/", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "OK";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        // Spelled out so the future can be named below.
        fn run(s: *dusty.Server(void)) anyerror!void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    const slow = try server.address.ip.connect(io, .{ .mode = .stream });
    defer slow.close(io);
    var slow_write_buf: [256]u8 = undefined;
    var slow_writer = slow.writer(io, &slow_write_buf);
    try slow_writer.interface.writeAll("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try slow_writer.interface.flush();
    try sync.started.wait(io);

    // Idle by the time the drain starts.
    const idle = try server.address.ip.connect(io, .{ .mode = .stream });
    defer idle.close(io);

    // The drain blocks on the slow handler, so it runs on a task of its own.
    var shutdown_future = try io.concurrent(struct {
        fn run(f: *std.Io.Future(anyerror!void), _io: std.Io) !void {
            try std.testing.expectError(error.Canceled, f.cancel(_io));
        }
    }.run, .{ &server_future, io });
    defer shutdown_future.cancel(io) catch {};
    while (!server.busy.load(.acquire).draining) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    var write_buf: [256]u8 = undefined;
    var writer = idle.writer(io, &write_buf);
    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = idle.reader(io, &read_buf);
    var status: [64]u8 = undefined;
    var body: [16]u8 = undefined;
    const resp = try readResponse(&reader.interface, &status, &body);
    try std.testing.expectStringStartsWith(resp.status, "HTTP/1.1 503 ");
    try std.testing.expectError(error.EndOfStream, reader.interface.fillMore());

    sync.release.set(io);
    try shutdown_future.await(io);
}

test "Server: graceful shutdown closes idle connections without waiting out the budget" {
    try expectIdleConnectionsClosedOnShutdown(.{});
}

test "Server: graceful shutdown closes idle connections with no deadlines configured" {
    try expectIdleConnectionsClosedOnShutdown(.{ .request = null, .keepalive = null });
}

test "Server: request resolves the client through a trusted proxy" {
    const io = std.testing.io;

    const Ctx = struct {
        seen: [2]?std.Io.net.IpAddress = @splat(null),
        count: usize = 0,
    };
    var ctx: Ctx = .{};

    var server = dusty.Server(Ctx).init(std.testing.allocator, io, .{ .trusted_proxy_hops = 1 }, &ctx);
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

            // Two requests on one connection. The first has no forwarding
            // chain and therefore falls back to the peer. The second must be
            // resolved afresh rather than inheriting the first request's
            // address through the keepalive reset.
            try writer.interface.writeAll("GET /whoami HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try writer.interface.flush();
            try readOneResponse(&reader.interface);

            try writer.interface.writeAll("GET /whoami HTTP/1.1\r\nHost: localhost\r\nX-Forwarded-For: 192.0.2.25\r\nConnection: close\r\n\r\n");
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
    const peer = ctx.seen[0] orelse return error.HandlerNeverRan;
    try std.testing.expect(peer == .ip4);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, peer.ip4.bytes);
    try std.testing.expect(peer.ip4.port != 0);

    const forwarded = ctx.seen[1] orelse return error.HandlerNeverRan;
    try std.testing.expect(forwarded == .ip4);
    try std.testing.expectEqual([4]u8{ 192, 0, 2, 25 }, forwarded.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 0), forwarded.ip4.port);
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

test "Server: a request head too large for the buffer gets 431, not a panic" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "OK";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            s.listen(addr) catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.ready.wait(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);

            // Comfortably past the default buffer_size + body_read_reserve,
            // in one header so max_header_count is not what rejects it. The
            // server answers and hangs up part way through, without reading
            // the rest, so these writes are allowed to fail; what is asserted
            // is the response.
            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            writer.interface.writeAll("GET / HTTP/1.1\r\nHost: a\r\nX-Big: ") catch {};
            writer.interface.splatByteAll('A', 20000) catch {};
            writer.interface.writeAll("\r\n\r\n") catch {};
            writer.interface.flush() catch {};

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings(
                "HTTP/1.1 431 Request Header Fields Too Large\r",
                status_line,
            );
            // The server hangs up with a FIN, not a reset, although it
            // never read the whole head: the rest of the answer arrives
            // and the end of it is clean.
            _ = try reader.interface.discardRemaining();
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: a peer that will not hang up after a 431 is hung up on anyway" {
    const io = std.testing.io;

    // No request deadline, so the drain's own is what ends it.
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .timeout = .{ .request = null } }, {});
    defer server.deinit();

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            s.listen(addr) catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.ready.wait(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            writer.interface.writeAll("GET / HTTP/1.1\r\nHost: a\r\nX-Big: ") catch {};
            writer.interface.splatByteAll('A', 20000) catch {};
            writer.interface.writeAll("\r\n\r\n") catch {};
            writer.interface.flush() catch {};

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings(
                "HTTP/1.1 431 Request Header Fields Too Large\r",
                status_line,
            );
            // The server's half-close is the end of what it sends.
            _ = try reader.interface.discardRemaining();
            // Keep the connection open and keep sending: a write is taken
            // while the server is still draining, and refused once the
            // drain deadline has passed and the server has closed.
            var probes: usize = 0;
            while (probes < 100) : (probes += 1) {
                try _io.sleep(.fromMilliseconds(50), .awake);
                writer.interface.writeByte('B') catch break;
                writer.interface.flush() catch break;
            }
            try std.testing.expect(probes < 100);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: a head that just fits is still served" {
    const io = std.testing.io;

    // 8 KB of header against the 16 KB default: comfortably under, so the
    // guard must not fire early.
    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            res.body = req.headers.get("X-Big") orelse "missing";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            s.listen(addr) catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.ready.wait(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: a\r\nX-Big: ");
            try writer.interface.splatByteAll('A', 8192);
            try writer.interface.writeAll("\r\n\r\n");
            try writer.interface.flush();

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r", status_line);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

/// What the handler saw, so a test can tell a head that was accepted from
/// one that was accepted and then could not read its body.
const HeadBoundaryCtx = struct {
    body: [16]u8 = undefined,
    body_len: usize = 0,

    pub fn handle(ctx: *HeadBoundaryCtx, req: *dusty.Request, res: *dusty.Response) !void {
        const b = (try req.body()) orelse "";
        ctx.body_len = @min(b.len, ctx.body.len);
        @memcpy(ctx.body[0..ctx.body_len], b[0..ctx.body_len]);
        res.body = "OK";
    }
};

/// Sends a request whose head is exactly `head_len` bytes -- a header value
/// padded so the terminating CRLFCRLF lands on the byte asked for -- with a
/// body behind it, and checks the status line that comes back.
///
/// The body is the point. What the head does not use of the read buffer is
/// all the body reader gets, so a head that parses but leaves nothing behind
/// it fails only once something tries to read one.
fn expectStatusForHeadOfLength(
    head_len: usize,
    expected_status: []const u8,
    expected_body: ?[]const u8,
) !void {
    const io = std.testing.io;
    const S = dusty.Server(HeadBoundaryCtx);

    var ctx: HeadBoundaryCtx = .{};
    var server = S.init(std.testing.allocator, io, .{}, &ctx);
    defer server.deinit();
    server.router.post("/", HeadBoundaryCtx.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *S) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            s.listen(addr) catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *S, len: usize, want: []const u8, _io: std.Io) !void {
            try s.ready.wait(_io);
            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);

            const prefix = "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nX-Pad: ";
            const suffix = "\r\n\r\n";
            std.debug.assert(len >= prefix.len + suffix.len);

            // A rejected head is answered part way through and the rest of it
            // never read, so these writes are allowed to fail.
            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            writer.interface.writeAll(prefix) catch {};
            writer.interface.splatByteAll('A', len - prefix.len - suffix.len) catch {};
            writer.interface.writeAll(suffix) catch {};
            writer.interface.writeAll("hello") catch {};
            writer.interface.flush() catch {};

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings(want, status_line);
        }
    }.run, .{ &server, head_len, expected_status, io });

    try client_future.await(io);

    if (expected_body) |want| {
        try std.testing.expectEqualStrings(want, ctx.body[0..ctx.body_len]);
    }
}

// The read buffer is buffer_size + body_read_reserve, and the head is
// accepted exactly when it fits in buffer_size -- leaving the reserve for the
// body reader that inherits the rest.
const head_limit = 16384;
const head_buffer_len = head_limit + 1024;

test "Server: a head of exactly the limit is served, body and all" {
    try expectStatusForHeadOfLength(head_limit, "HTTP/1.1 200 OK\r", "hello");
}

test "Server: a head one byte over the limit gets 431" {
    try expectStatusForHeadOfLength(head_limit + 1, "HTTP/1.1 431 Request Header Fields Too Large\r", null);
}

test "Server: a head ending exactly at the buffer end gets 431, not a panic" {
    // The head parses cleanly and consumes the reserve with it, so nothing
    // during parsing objects -- the body reader is left a zero-length buffer
    // and panics on the first fill.
    try expectStatusForHeadOfLength(head_buffer_len, "HTTP/1.1 431 Request Header Fields Too Large\r", null);
}

/// Counts how many handlers are in flight at once, so a test can see whether
/// the cap held.
const ConcurrencyCtx = struct {
    active: std.atomic.Value(u32) = .init(0),
    peak: std.atomic.Value(u32) = .init(0),
    served: std.atomic.Value(u32) = .init(0),

    pub fn handle(ctx: *ConcurrencyCtx, req: *dusty.Request, res: *dusty.Response) !void {
        const now = ctx.active.fetchAdd(1, .acq_rel) + 1;
        _ = ctx.peak.fetchMax(now, .acq_rel);
        // Long enough that the others are all waiting, so the cap is what
        // limits overlap rather than the handlers being too brief to overlap.
        try req.io.sleep(.fromMilliseconds(30), .awake);
        _ = ctx.active.fetchSub(1, .acq_rel);
        _ = ctx.served.fetchAdd(1, .acq_rel);
        res.body = "OK";
    }
};

test "Server: max_connections caps overlap without dropping anyone" {
    const io = std.testing.io;
    const S = dusty.Server(ConcurrencyCtx);
    const clients = 8;
    const cap = 2;

    var ctx: ConcurrencyCtx = .{};
    var server = S.init(std.testing.allocator, io, .{ .max_connections = cap }, &ctx);
    defer server.deinit();
    server.router.get("/", ConcurrencyCtx.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *S) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            s.listen(addr) catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    const One = struct {
        fn run(s: *S, _io: std.Io) !void {
            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            // Closing is what frees the slot.
            defer stream.close(_io);

            var write_buf: [256]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
            try writer.interface.flush();

            var read_buf: [256]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r", status_line);
        }
    };

    const Fut = @TypeOf(try io.concurrent(One.run, .{ &server, io }));
    var futures: [clients]Fut = undefined;
    for (&futures) |*f| f.* = try io.concurrent(One.run, .{ &server, io });
    var first_err: ?anyerror = null;
    for (&futures) |*f| f.await(io) catch |err| {
        if (first_err == null) first_err = err;
    };
    if (first_err) |err| return err;

    try std.testing.expectEqual(@as(u32, clients), ctx.served.load(.acquire));
    // Equality rather than <=, so this cannot pass by nothing overlapping.
    try std.testing.expectEqual(@as(u32, cap), ctx.peak.load(.acquire));
}

test "Server: a max_connections of zero is refused at listen" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .max_connections = 0 }, {});
    defer server.deinit();
    const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
    try std.testing.expectError(error.NoConnectionsAllowed, server.listen(addr));
}

/// Sends `head` and then stops, holding the connection open, and reports how
/// long the server took to hang up on it. Returns null if the server answered
/// instead of hanging up.
fn millisUntilServerHangsUp(cfg: dusty.ServerConfig, head: []const u8) !?i64 {
    const io = std.testing.io;
    const S = dusty.Server(void);

    var server = S.init(std.testing.allocator, io, cfg, {});
    defer server.deinit();
    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "OK";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *S) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            s.listen(addr) catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(head);
    try writer.interface.flush();

    const started = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;

    var read_buf: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();
    _ = reader.interface.streamRemaining(&sink.writer) catch {};

    if (sink.written().len != 0) return null;
    const ended = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    return @intCast(@divTrunc(ended - started, std.time.ns_per_ms));
}

test "Server: a stalled request head is cut off by timeout.request" {
    // A head that never terminates.
    const elapsed = try millisUntilServerHangsUp(
        .{ .timeout = .{ .request = .fromMilliseconds(150) } },
        "GET / HTTP/1.1\r\nHost: a\r\n",
    ) orelse return error.ServerAnsweredInstead;

    try std.testing.expect(elapsed >= 100);
    try std.testing.expect(elapsed < 3000);
}

test "Server: an idle keepalive connection is cut off by timeout.keepalive" {
    const io = std.testing.io;
    const S = dusty.Server(void);

    var server = S.init(std.testing.allocator, io, .{
        .timeout = .{ .keepalive = .fromMilliseconds(150) },
    }, {});
    defer server.deinit();
    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "OK";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *S) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            s.listen(addr) catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
    try writer.interface.flush();

    var read_buf: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const status_line = try reader.interface.takeDelimiterExclusive('\n');
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r", status_line);

    const started = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();
    _ = reader.interface.streamRemaining(&sink.writer) catch {};
    const elapsed = @divTrunc(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - started, std.time.ns_per_ms);

    try std.testing.expect(elapsed >= 100);
    try std.testing.expect(elapsed < 3000);
}
