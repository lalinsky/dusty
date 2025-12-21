const std = @import("std");
const zio = @import("zio");
const dusty = @import("root.zig");

fn testClientServer(comptime Ctx: type, ctx: *Ctx) !void {
    const TestServer = dusty.Server(Ctx);

    const Test = struct {
        pub fn mainFn(rt: *zio.Runtime, test_ctx: *Ctx) !void {
            var server = TestServer.init(std.testing.allocator, .{}, test_ctx);
            defer server.deinit();

            try test_ctx.setup(&server);

            var server_task = try rt.spawn(serverFn, .{ rt, &server }, .{});
            defer server_task.cancel(rt);

            var client_task = try rt.spawn(clientFn, .{ rt, &server, test_ctx }, .{});
            defer client_task.cancel(rt);

            try client_task.join(rt);
        }

        pub fn serverFn(rt: *zio.Runtime, server: *TestServer) !void {
            const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
            try server.listen(rt, addr);
        }

        pub fn clientFn(rt: *zio.Runtime, server: *TestServer, test_ctx: *Ctx) !void {
            try server.ready.wait(rt);

            const client = try server.address.connect(rt);
            defer client.close(rt);
            defer client.shutdown(rt, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = client.writer(rt, &write_buf);

            try test_ctx.makeRequest(&writer.interface);

            // Read response
            var read_buf: [1024]u8 = undefined;
            var reader = client.reader(rt, &read_buf);
            const response = try reader.interface.takeDelimiterExclusive('\n');

            std.log.info("Response: {s}", .{response});
        }
    };

    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var task = try rt.spawn(Test.mainFn, .{ rt, ctx }, .{});
    try task.join(rt);
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

            // Read all body data using streamRemaining
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
            // Send chunked encoded request in separate packets:
            // Headers
            try writer.writeAll("POST /chunked HTTP/1.1\r\n");
            try writer.writeAll("Host: localhost\r\n");
            try writer.writeAll("Transfer-Encoding: chunked\r\n");
            try writer.writeAll("\r\n");
            try writer.flush();

            // Chunk 1: "Hello " (6 bytes = 0x6)
            try writer.writeAll("6\r\n");
            try writer.writeAll("Hello \r\n");
            try writer.flush();

            // Chunk 2: "from " (5 bytes = 0x5)
            try writer.writeAll("5\r\n");
            try writer.writeAll("from \r\n");
            try writer.flush();

            // Chunk 3: "chunked test!" (13 bytes = 0xD)
            try writer.writeAll("D\r\n");
            try writer.writeAll("chunked test!\r\n");
            try writer.flush();

            // Final chunk: 0
            try writer.writeAll("0\r\n");
            try writer.writeAll("\r\n");
            try writer.flush();
        }

        fn handlePost(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            var reader = req.reader();

            // Read all body data using streamRemaining
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

            // Try to read body - should get 0 bytes since GET has no body
            var body_buf: [256]u8 = undefined;
            var writer = std.Io.Writer.fixed(&body_buf);
            const n = reader.interface.streamRemaining(&writer) catch |err| blk: {
                // EndOfStream is expected for empty body
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
            // HTTP/1.0 request - no Host header required, connection closes after response
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

test "Server: void context handlers" {
    const Test = struct {
        pub fn mainFn(rt: *zio.Runtime) !void {
            var server = dusty.Server(void).init(std.testing.allocator, .{}, {});
            defer server.deinit();

            server.router.get("/test", handleGet);
            server.router.post("/echo", handlePost);

            var server_task = try rt.spawn(serverFn, .{ rt, &server }, .{});
            defer server_task.cancel(rt);

            var client_task = try rt.spawn(clientFn, .{ rt, &server }, .{});
            defer client_task.cancel(rt);

            try client_task.join(rt);
        }

        pub fn serverFn(rt: *zio.Runtime, server: *dusty.Server(void)) !void {
            const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
            try server.listen(rt, addr);
        }

        pub fn clientFn(rt: *zio.Runtime, server: *dusty.Server(void)) !void {
            try server.ready.wait(rt);

            const client = try server.address.connect(rt);
            defer client.close(rt);
            defer client.shutdown(rt, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = client.writer(rt, &write_buf);

            // Test GET request
            try writer.interface.writeAll("GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try writer.interface.flush();

            // Read response - just verify we get something back
            var read_buf: [1024]u8 = undefined;
            var reader = client.reader(rt, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');

            std.log.info("Response: {s}", .{status_line});
            // Just verify we got a 200 OK response
            try std.testing.expect(std.mem.indexOf(u8, status_line, "200 OK") != null);
        }

        fn handleGet(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "Hello from void context!\n";
        }

        fn handlePost(req: *dusty.Request, res: *dusty.Response) !void {
            var reader = req.reader();
            const body = try reader.interface.allocRemaining(req.arena, .limited(1024));
            res.body = try std.fmt.allocPrint(res.arena, "Echo: {s}\n", .{body});
        }
    };

    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var task = try rt.spawn(Test.mainFn, .{rt}, .{});
    try task.join(rt);
}
