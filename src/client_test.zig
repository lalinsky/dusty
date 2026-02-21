const std = @import("std");
const zio = @import("zio");
const dusty = @import("root.zig");

test "Client: simple GET request" {
    const Test = struct {
        pub fn mainFn() !void {
            var server = dusty.Server(void).init(std.testing.allocator, .{}, {});
            defer server.deinit();

            server.router.get("/test", handleGet);

            var server_task = try zio.spawn(serverFn, .{&server});
            defer server_task.cancel();

            var client_task = try zio.spawn(clientFn, .{&server});
            defer client_task.cancel();

            try client_task.join();
        }

        pub fn serverFn(server: *dusty.Server(void)) !void {
            const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
            try server.listen(addr);
        }

        pub fn clientFn(server: *dusty.Server(void)) !void {
            try server.ready.wait();

            // Connect directly like server_test.zig does
            const stream = try server.address.connect(.{});
            defer stream.close();
            defer stream.shutdown(.both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(&write_buf);

            // Send GET request
            try writer.interface.writeAll("GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try writer.interface.flush();

            // Read response
            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(&read_buf);
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

    var task = try zio.spawn(Test.mainFn, .{});
    try task.join();
}

test "Client: fetch GET request" {
    const Test = struct {
        pub fn mainFn() !void {
            var server = dusty.Server(void).init(std.testing.allocator, .{}, {});
            defer server.deinit();

            server.router.get("/api", handleGet);

            var server_task = try zio.spawn(serverFn, .{&server});
            defer server_task.cancel();

            var client_task = try zio.spawn(clientFn, .{&server});
            defer client_task.cancel();

            try client_task.join();
        }

        pub fn serverFn(server: *dusty.Server(void)) !void {
            const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
            try server.listen(addr);
        }

        pub fn clientFn(server: *dusty.Server(void)) !void {
            try server.ready.wait();

            // Get the port
            const port = std.mem.bigToNative(u16, server.address.ip.in.port);

            // Build URL
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api", .{port});

            std.log.info("Making request to: {s}", .{url});

            // Use our client
            var client = dusty.Client.init(std.testing.allocator, .{});
            defer client.deinit();

            var response = try client.fetch(url, .{});
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

    var task = try zio.spawn(Test.mainFn, .{});
    try task.join();
}

test "Client: connection pooling" {
    const Test = struct {
        pub fn mainFn() !void {
            var server = dusty.Server(void).init(std.testing.allocator, .{}, {});
            defer server.deinit();

            server.router.get("/test", handleGet);

            var server_task = try zio.spawn(serverFn, .{&server});
            defer server_task.cancel();

            var client_task = try zio.spawn(clientFn, .{&server});
            defer client_task.cancel();

            try client_task.join();
        }

        pub fn serverFn(server: *dusty.Server(void)) !void {
            const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
            try server.listen(addr);
        }

        pub fn clientFn(server: *dusty.Server(void)) !void {
            try server.ready.wait();

            const port = std.mem.bigToNative(u16, server.address.ip.in.port);

            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/test", .{port});

            var client = dusty.Client.init(std.testing.allocator, .{});
            defer client.deinit();

            // Pool should be empty initially
            try std.testing.expectEqual(@as(usize, 0), client.pool.idle_len);

            // First request
            {
                var response = try client.fetch(url, .{});
                defer response.deinit();

                try std.testing.expectEqual(.ok, response.status());
                _ = try response.body();
            }

            // After first response is released, connection should be in pool
            try std.testing.expectEqual(@as(usize, 1), client.pool.idle_len);

            // Second request should reuse the pooled connection
            {
                var response = try client.fetch(url, .{});
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

    var task = try zio.spawn(Test.mainFn, .{});
    try task.join();
}

test "Client: WebSocket upgrade" {
    const Test = struct {
        pub fn mainFn() !void {
            var server = dusty.Server(void).init(std.testing.allocator, .{}, {});
            defer server.deinit();

            server.router.get("/ws", handleWebSocket);

            var server_task = try zio.spawn(serverFn, .{&server});
            defer server_task.cancel();

            var client_task = try zio.spawn(clientFn, .{&server});
            defer client_task.cancel();

            try client_task.join();
        }

        pub fn serverFn(server: *dusty.Server(void)) !void {
            const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
            try server.listen(addr);
        }

        pub fn clientFn(server: *dusty.Server(void)) !void {
            try server.ready.wait();

            const port = std.mem.bigToNative(u16, server.address.ip.in.port);

            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/ws", .{port});

            var client = dusty.Client.init(std.testing.allocator, .{});
            defer client.deinit();

            var ws = try client.connectWebSocket(url, .{});
            defer ws.deinit();

            // Server sends "Welcome!" first
            const welcome = try ws.receive();
            try std.testing.expectEqual(.text, welcome.type);
            try std.testing.expectEqualStrings("Welcome!", welcome.data);

            // Send a message
            try ws.send(.text, "Hello WebSocket!");

            // Receive echo
            const echo = try ws.receive();
            try std.testing.expectEqual(.text, echo.type);
            try std.testing.expectEqualStrings("Hello WebSocket!", echo.data);

            // Close
            try ws.close(.normal, "done");
        }

        fn handleWebSocket(req: *dusty.Request, res: *dusty.Response) !void {
            var ws = try res.upgradeWebSocket(req) orelse {
                res.status = .bad_request;
                return;
            };

            // Send welcome
            try ws.send(.text, "Welcome!");

            // Echo loop
            while (true) {
                const msg = ws.receive() catch |err| switch (err) {
                    error.EndOfStream => return,
                    else => return err,
                };
                if (msg.type == .close) return;
                if (msg.type == .text or msg.type == .binary) {
                    try ws.send(msg.type, msg.data);
                }
            }
        }
    };

    var io = try zio.Runtime.init(std.testing.allocator, .{});
    defer io.deinit();

    var task = try zio.spawn(Test.mainFn, .{});
    try task.join();
}

test "Client: unix socket fetch" {
    if (!zio.net.has_unix_sockets) return error.SkipZigTest;

    const Test = struct {
        pub fn mainFn() !void {
            const socket_path = "/tmp/dusty-client-test-unix.sock";
            std.fs.cwd().deleteFile(socket_path) catch {};

            var ready_buf: [1]bool = undefined;
            var ready_ch = zio.Channel(bool).init(&ready_buf);

            var server_task = try zio.spawn(serverFn, .{ socket_path, &ready_ch });
            defer server_task.cancel();

            var client_task = try zio.spawn(clientFn, .{ socket_path, &ready_ch });
            defer client_task.cancel();

            try client_task.join();
        }

        pub fn serverFn(socket_path: []const u8, ready: *zio.Channel(bool)) !void {
            const unix_addr = try zio.net.UnixAddress.init(socket_path);
            const server = try unix_addr.listen(.{});
            defer server.close();
            defer std.fs.cwd().deleteFile(socket_path) catch {};

            try ready.send(true);

            const stream = try server.accept();
            defer stream.close();
            defer stream.shutdown(.both) catch {};

            // Consume request headers
            var read_buf: [4096]u8 = undefined;
            var reader = stream.reader(&read_buf);
            while (true) {
                const line = try reader.interface.takeDelimiterExclusive('\n');
                if (std.mem.trimRight(u8, line, "\r").len == 0) break;
            }

            // Write a minimal HTTP response
            var write_buf: [512]u8 = undefined;
            var writer = stream.writer(&write_buf);
            try writer.interface.writeAll(
                "HTTP/1.1 200 OK\r\n" ++
                    "Content-Length: 14\r\n" ++
                    "Connection: close\r\n" ++
                    "\r\n" ++
                    "Hello, Docker!",
            );
            try writer.interface.flush();
        }

        pub fn clientFn(socket_path: []const u8, ready: *zio.Channel(bool)) !void {
            _ = try ready.receive();

            var client = dusty.Client.init(std.testing.allocator, .{});
            defer client.deinit();

            var response = try client.fetch("http://localhost/test", .{
                .unix_socket_path = socket_path,
            });
            defer response.deinit();

            try std.testing.expectEqual(.ok, response.status());

            const b = try response.body();
            try std.testing.expect(b != null);
            try std.testing.expectEqualStrings("Hello, Docker!", b.?);
        }
    };

    var io = try zio.Runtime.init(std.testing.allocator, .{});
    defer io.deinit();

    var task = try zio.spawn(Test.mainFn, .{});
    try task.join();
}
