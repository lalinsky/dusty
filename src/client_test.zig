const std = @import("std");
const zio = @import("zio");
const dusty = @import("root.zig");

test "Client: simple GET request" {
    const Test = struct {
        pub fn mainFn(io: *zio.Runtime) !void {
            var server = dusty.Server(void).init(std.testing.allocator, .{}, {});
            defer server.deinit();

            server.router.get("/test", handleGet);

            var server_task = try io.spawn(serverFn, .{ io, &server });
            defer server_task.cancel(io);

            var client_task = try io.spawn(clientFn, .{ io, &server });
            defer client_task.cancel(io);

            try client_task.join(io);
        }

        pub fn serverFn(io: *zio.Runtime, server: *dusty.Server(void)) !void {
            const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
            try server.listen(io, addr);
        }

        pub fn clientFn(io: *zio.Runtime, server: *dusty.Server(void)) !void {
            try server.ready.wait(io);

            // Connect directly like server_test.zig does
            const stream = try server.address.connect(io, .{});
            defer stream.close(io);
            defer stream.shutdown(io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(io, &write_buf);

            // Send GET request
            try writer.interface.writeAll("GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try writer.interface.flush();

            // Read response
            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');

            std.log.info("Response: {s}", .{status_line});
            try std.testing.expect(std.mem.indexOf(u8, status_line, "200 OK") != null);
        }

        fn handleGet(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "Hello from test!\n";
        }
    };

    var io = try zio.Runtime.init(std.testing.allocator, .{});
    defer io.deinit();

    var task = try io.spawn(Test.mainFn, .{io});
    try task.join(io);
}

test "Client: fetch GET request" {
    const Test = struct {
        pub fn mainFn(io: *zio.Runtime) !void {
            var server = dusty.Server(void).init(std.testing.allocator, .{}, {});
            defer server.deinit();

            server.router.get("/api", handleGet);

            var server_task = try io.spawn(serverFn, .{ io, &server });
            defer server_task.cancel(io);

            var client_task = try io.spawn(clientFn, .{ io, &server });
            defer client_task.cancel(io);

            try client_task.join(io);
        }

        pub fn serverFn(io: *zio.Runtime, server: *dusty.Server(void)) !void {
            const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
            try server.listen(io, addr);
        }

        pub fn clientFn(io: *zio.Runtime, server: *dusty.Server(void)) !void {
            try server.ready.wait(io);

            // Get the port
            const port = std.mem.bigToNative(u16, server.address.ip.in.port);

            // Build URL
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api", .{port});

            std.log.info("Making request to: {s}", .{url});

            // Use our client
            var client = dusty.Client.init(std.testing.allocator, .{});
            defer client.deinit();

            var response = try client.fetch(io, url, .{});
            defer response.deinit();

            std.log.info("Got response status: {d}", .{@intFromEnum(response.status())});

            try std.testing.expectEqual(.ok, response.status());

            const body = try response.body();
            std.log.info("Got body: {?s}", .{body});
            try std.testing.expect(body != null);
            try std.testing.expectEqualStrings("Hello from API!\n", body.?);
        }

        fn handleGet(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "Hello from API!\n";
        }
    };

    var io = try zio.Runtime.init(std.testing.allocator, .{});
    defer io.deinit();

    var task = try io.spawn(Test.mainFn, .{io});
    try task.join(io);
}

test "Client: connection pooling" {
    const Test = struct {
        pub fn mainFn(io: *zio.Runtime) !void {
            var server = dusty.Server(void).init(std.testing.allocator, .{}, {});
            defer server.deinit();

            server.router.get("/test", handleGet);

            var server_task = try io.spawn(serverFn, .{ io, &server });
            defer server_task.cancel(io);

            var client_task = try io.spawn(clientFn, .{ io, &server });
            defer client_task.cancel(io);

            try client_task.join(io);
        }

        pub fn serverFn(io: *zio.Runtime, server: *dusty.Server(void)) !void {
            const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
            try server.listen(io, addr);
        }

        pub fn clientFn(io: *zio.Runtime, server: *dusty.Server(void)) !void {
            try server.ready.wait(io);

            const port = std.mem.bigToNative(u16, server.address.ip.in.port);

            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/test", .{port});

            var client = dusty.Client.init(std.testing.allocator, .{});
            defer client.deinit();

            // Pool should be empty initially
            try std.testing.expectEqual(@as(usize, 0), client.pool.idle_len);

            // First request
            {
                var response = try client.fetch(io, url, .{});
                defer response.deinit();

                try std.testing.expectEqual(.ok, response.status());
                _ = try response.body();
            }

            // After first response is released, connection should be in pool
            try std.testing.expectEqual(@as(usize, 1), client.pool.idle_len);

            // Second request should reuse the pooled connection
            {
                var response = try client.fetch(io, url, .{});
                defer response.deinit();

                try std.testing.expectEqual(.ok, response.status());
                _ = try response.body();
            }

            // Connection should be back in pool
            try std.testing.expectEqual(@as(usize, 1), client.pool.idle_len);
        }

        fn handleGet(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "OK";
        }
    };

    var io = try zio.Runtime.init(std.testing.allocator, .{});
    defer io.deinit();

    var task = try io.spawn(Test.mainFn, .{io});
    try task.join(io);
}
