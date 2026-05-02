const std = @import("std");
const dusty = @import("root.zig");

test "Client: simple GET request" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/test", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "Hello from test!\n";
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

            const port = s.address.ip.getPort();

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

            std.log.info("Response: {s} (port {})", .{ status_line, port });
            try std.testing.expect(std.mem.indexOf(u8, status_line, "200 OK") != null);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Client: fetch GET request" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/api", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "Hello from API!\n";
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

            const port = s.address.ip.getPort();

            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api", .{port});

            std.log.info("Making request to: {s}", .{url});

            var client = dusty.Client.init(std.testing.allocator, _io, .{});
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
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Client: connection pooling" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/test", struct {
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
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.ready.wait(_io);

            const port = s.address.ip.getPort();

            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/test", .{port});

            var client = dusty.Client.init(std.testing.allocator, _io, .{});
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
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Client: WebSocket upgrade" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/ws", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            var ws = try res.upgradeWebSocket(req) orelse {
                res.status = .bad_request;
                return;
            };

            try ws.send(.text, "Welcome!");

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

            const port = s.address.ip.getPort();

            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/ws", .{port});

            var client = dusty.Client.init(std.testing.allocator, _io, .{});
            defer client.deinit();

            var ws = try client.connectWebSocket(url, .{});
            defer ws.deinit();

            const welcome = try ws.receive();
            try std.testing.expectEqual(.text, welcome.type);
            try std.testing.expectEqualStrings("Welcome!", welcome.data);

            try ws.send(.text, "Hello WebSocket!");

            const echo = try ws.receive();
            try std.testing.expectEqual(.text, echo.type);
            try std.testing.expectEqualStrings("Hello WebSocket!", echo.data);

            try ws.close(.normal, "done");
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Client: unix socket fetch" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!std.Io.net.has_unix_sockets) return error.SkipZigTest;

    const io = std.testing.io;

    var path_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "/tmp/dusty-client-test-unix-{d}.sock", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};

    var ready: std.Io.Event = .unset;

    var server_future = try io.concurrent(struct {
        fn run(path: []const u8, r: *std.Io.Event, _io: std.Io) !void {
            const unix_addr = try std.Io.net.UnixAddress.init(path);
            var server = try unix_addr.listen(_io, .{});
            defer server.deinit(_io);
            defer std.Io.Dir.cwd().deleteFile(_io, path) catch {};

            r.set(_io);

            const stream = try server.accept(_io);
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var read_buf: [4096]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            while (true) {
                const line = try reader.interface.takeDelimiterExclusive('\n');
                reader.interface.toss(1);
                if (std.mem.trimEnd(u8, line, "\r").len == 0) break;
            }

            var write_buf: [512]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            try writer.interface.writeAll(
                "HTTP/1.1 200 OK\r\n" ++
                    "Content-Length: 14\r\n" ++
                    "Connection: close\r\n" ++
                    "\r\n" ++
                    "Hello, Docker!",
            );
            try writer.interface.flush();
        }
    }.run, .{ socket_path, &ready, io });
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(path: []const u8, r: *std.Io.Event, _io: std.Io) !void {
            try r.wait(_io);

            var client = dusty.Client.init(std.testing.allocator, _io, .{});
            defer client.deinit();

            var response = try client.fetch("http://localhost/test", .{
                .unix_socket_path = path,
            });
            defer response.deinit();

            try std.testing.expectEqual(.ok, response.status());

            const b = try response.body();
            try std.testing.expect(b != null);
            try std.testing.expectEqualStrings("Hello, Docker!", b.?);
        }
    }.run, .{ socket_path, &ready, io });

    try client_future.await(io);
}
