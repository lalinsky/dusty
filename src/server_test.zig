const std = @import("std");
const zio = @import("zio");
const dusty = @import("root.zig");

test "Server: POST with body" {
    const TestContext = struct {
        body_received: bool = false,
        received_body: [256]u8 = undefined,
        received_len: usize = 0,
    };

    const TestServer = dusty.Server(TestContext);

    const Test = struct {
        pub fn mainFn(rt: *zio.Runtime, ctx: *TestContext) !void {
            var server = TestServer.init(std.testing.allocator, ctx);
            defer server.deinit();

            server.router.post("/test", handlePost);

            var server_task = try rt.spawn(serverFn, .{ rt, &server }, .{});
            defer server_task.cancel(rt);

            var client_task = try rt.spawn(clientFn, .{ rt, &server }, .{});
            defer client_task.cancel(rt);

            try client_task.join(rt);
        }

        pub fn serverFn(rt: *zio.Runtime, server: *TestServer) !void {
            const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
            try server.listen(rt, addr);
        }

        pub fn clientFn(rt: *zio.Runtime, server: *TestServer) !void {
            try server.ready.wait(rt);

            const client = try server.address.connect(rt);
            defer client.close(rt);
            defer client.shutdown(rt, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = client.writer(rt, &write_buf);

            const request_body = "Hello from test!";
            const request = try std.fmt.allocPrint(
                std.testing.allocator,
                "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ request_body.len, request_body },
            );
            defer std.testing.allocator.free(request);

            try writer.interface.writeAll(request);
            try writer.interface.flush();

            // Read response
            var read_buf: [1024]u8 = undefined;
            var reader = client.reader(rt, &read_buf);
            const response = try reader.interface.takeDelimiterExclusive('\n');

            std.log.info("Response: {s}", .{response});
        }

        fn handlePost(ctx: *TestContext, req: *dusty.Request, res: *dusty.Response) !void {
            var body_reader = req.reader();
            const n = try body_reader.readAll(&ctx.received_body);
            ctx.body_received = true;
            ctx.received_len = n;

            std.log.info("Received body: {s}", .{ctx.received_body[0..n]});

            res.body = "OK\n";
        }
    };

    var ctx: TestContext = .{};

    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(Test.mainFn, .{ rt, &ctx }, .{});

    try std.testing.expect(ctx.body_received);
    try std.testing.expectEqualStrings("Hello from test!", ctx.received_body[0..ctx.received_len]);
}

test "Server: POST with chunked encoding" {
    const TestContext = struct {
        body_received: bool = false,
        received_body: [256]u8 = undefined,
        received_len: usize = 0,
    };

    const TestServer = dusty.Server(TestContext);

    const Test = struct {
        pub fn mainFn(rt: *zio.Runtime, ctx: *TestContext) !void {
            var server = TestServer.init(std.testing.allocator, ctx);
            defer server.deinit();

            server.router.post("/chunked", handlePost);

            var server_task = try rt.spawn(serverFn, .{ rt, &server }, .{});
            defer server_task.cancel(rt);

            var client_task = try rt.spawn(clientFn, .{ rt, &server }, .{});
            defer client_task.cancel(rt);

            try client_task.join(rt);
        }

        pub fn serverFn(rt: *zio.Runtime, server: *TestServer) !void {
            const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
            try server.listen(rt, addr);
        }

        pub fn clientFn(rt: *zio.Runtime, server: *TestServer) !void {
            try server.ready.wait(rt);

            const client = try server.address.connect(rt);
            defer client.close(rt);
            defer client.shutdown(rt, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = client.writer(rt, &write_buf);

            // Send chunked encoded request:
            // Chunk 1: "Hello " (6 bytes = 0x6)
            // Chunk 2: "from " (5 bytes = 0x5)
            // Chunk 3: "chunked test!" (13 bytes = 0xD)
            // Final chunk: 0
            const request =
                "POST /chunked HTTP/1.1\r\n" ++
                "Host: localhost\r\n" ++
                "Transfer-Encoding: chunked\r\n" ++
                "\r\n" ++
                "6\r\n" ++
                "Hello \r\n" ++
                "5\r\n" ++
                "from \r\n" ++
                "D\r\n" ++
                "chunked test!\r\n" ++
                "0\r\n" ++
                "\r\n";

            try writer.interface.writeAll(request);
            try writer.interface.flush();

            // Read response
            var read_buf: [1024]u8 = undefined;
            var reader = client.reader(rt, &read_buf);
            const response = try reader.interface.takeDelimiterExclusive('\n');

            std.log.info("Response: {s}", .{response});
        }

        fn handlePost(ctx: *TestContext, req: *dusty.Request, res: *dusty.Response) !void {
            var body_reader = req.reader();
            const n = try body_reader.readAll(&ctx.received_body);
            ctx.body_received = true;
            ctx.received_len = n;

            std.log.info("Received chunked body: {s}", .{ctx.received_body[0..n]});

            res.body = "OK\n";
        }
    };

    var ctx: TestContext = .{};

    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(Test.mainFn, .{ rt, &ctx }, .{});

    try std.testing.expect(ctx.body_received);
    try std.testing.expectEqualStrings("Hello from chunked test!", ctx.received_body[0..ctx.received_len]);
}
