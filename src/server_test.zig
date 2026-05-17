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
    try std.testing.expectError(error.EndOfStream, readResponse(r, &status2, &body2));
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
