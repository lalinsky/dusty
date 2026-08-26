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

test "Client: pool evicts dead connection after server goes away" {
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

    try server.ready.wait(io);

    const port = server.address.ip.getPort();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/test", .{port});

    var client = dusty.Client.init(std.testing.allocator, io, .{});
    defer client.deinit();

    // A healthy fetch parks a keep-alive connection in the pool.
    {
        var response = try client.fetch(url, .{});
        defer response.deinit();

        try std.testing.expectEqual(.ok, response.status());
        _ = try response.body();
    }
    try std.testing.expectEqual(@as(usize, 1), client.pool.idle_len);

    // The server goes away, killing the pooled connection.
    server_future.cancel(io) catch {};

    // The fetch over the dead pooled connection fails...
    var failed = false;
    if (client.fetch(url, .{})) |response| {
        var r = response;
        r.deinit();
    } else |_| {
        failed = true;
    }
    try std.testing.expect(failed);

    // ...and the dead connection must be evicted, not returned to the pool,
    // so the next fetch dials fresh instead of re-acquiring it forever.
    try std.testing.expectEqual(@as(usize, 0), client.pool.idle_len);
}

test "Client: redirect failing after connection release does not double-release" {
    const io = std.testing.io;

    const Ctx = struct {
        location: []const u8,
    };

    // Find a port with no listener behind it: bind, note the port, close.
    // Redirecting there makes the redirect fetch fail at dial time, after
    // the first connection was already released back to the pool.
    const dead_port = blk: {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var listener = try addr.listen(io, .{});
        const p = listener.socket.address.getPort();
        listener.deinit(io);
        break :blk p;
    };

    var location_buf: [64]u8 = undefined;
    var ctx: Ctx = .{
        .location = try std.fmt.bufPrint(&location_buf, "http://127.0.0.1:{d}/", .{dead_port}),
    };

    var server = dusty.Server(Ctx).init(std.testing.allocator, io, .{}, &ctx);
    defer server.deinit();

    server.router.get("/redirect", struct {
        fn handle(c: *Ctx, req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.status = .found;
            try res.header("Location", c.location);
        }
    }.handle);

    server.router.get("/ok", struct {
        fn handle(c: *Ctx, req: *dusty.Request, res: *dusty.Response) !void {
            _ = c;
            _ = req;
            res.body = "OK";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(Ctx)) !void {
            const addr: dusty.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0) };
            try s.listen(addr);
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);

    const port = server.address.ip.getPort();
    var url_buf: [64]u8 = undefined;
    const redirect_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/redirect", .{port});

    var client = dusty.Client.init(std.testing.allocator, io, .{});
    defer client.deinit();

    var failed = false;
    if (client.fetch(redirect_url, .{})) |response| {
        var r = response;
        r.deinit();
    } else |_| {
        failed = true;
    }
    try std.testing.expect(failed);

    // The connection was released back to the pool before the redirect
    // failed; the failure must not release it a second time.
    try std.testing.expectEqual(1, client.pool.idle_len);

    // The pooled connection is still usable.
    var ok_url_buf: [64]u8 = undefined;
    const ok_url = try std.fmt.bufPrint(&ok_url_buf, "http://127.0.0.1:{d}/ok", .{port});
    {
        var response = try client.fetch(ok_url, .{});
        defer response.deinit();

        try std.testing.expectEqual(.ok, response.status());
        _ = try response.body();
    }
    try std.testing.expectEqual(1, client.pool.idle_len);
}

test "Client: connection with unread response body is not pooled" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();

    server.router.get("/test", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "some response body";
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

    const port = server.address.ip.getPort();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/test", .{port});

    var client = dusty.Client.init(std.testing.allocator, io, .{});
    defer client.deinit();

    // Deinit the response without reading the body: the connection sits at
    // an unknown stream position and must be closed, not pooled, or the
    // next request on it would read leftover body bytes as its response.
    {
        var response = try client.fetch(url, .{});
        defer response.deinit();

        try std.testing.expectEqual(.ok, response.status());
    }
    try std.testing.expectEqual(0, client.pool.idle_len);

    // A fully read response is still pooled as usual.
    {
        var response = try client.fetch(url, .{});
        defer response.deinit();

        try std.testing.expectEqual(.ok, response.status());
        _ = try response.body();
    }
    try std.testing.expectEqual(1, client.pool.idle_len);
}

test "Client: pool survives concurrent fetches on a shared client" {
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

    try server.ready.wait(io);

    const port = server.address.ip.getPort();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/test", .{port});

    // More workers than idle slots, so releases keep racing against evictions.
    const max_idle = 4;
    const workers = 8;
    const rounds = 20;

    var client = dusty.Client.init(std.testing.allocator, io, .{ .max_idle_connections = max_idle });
    defer client.deinit();

    const worker = struct {
        fn run(c: *dusty.Client, u: []const u8) !void {
            for (0..rounds) |_| {
                var response = try c.fetch(u, .{});
                defer response.deinit();

                try std.testing.expectEqual(.ok, response.status());
                const body = try response.body();
                try std.testing.expectEqualStrings("OK", body.?);
            }
        }
    }.run;

    const WorkerFuture = std.Io.Future(@typeInfo(@TypeOf(worker)).@"fn".return_type.?);
    var futures: [workers]WorkerFuture = undefined;
    var started: usize = 0;
    errdefer for (futures[0..started]) |*f| f.cancel(io) catch {};

    while (started < workers) : (started += 1) {
        futures[started] = try io.concurrent(worker, .{ &client, url });
    }

    var first_err: ?anyerror = null;
    for (&futures) |*f| {
        f.await(io) catch |err| {
            if (first_err == null) first_err = err;
        };
    }
    if (first_err) |err| return err;

    // idle_len must still agree with the list, and must respect max_idle.
    var counted: usize = 0;
    var node = client.pool.idle.first;
    while (node) |n| : (node = n.next) counted += 1;

    try std.testing.expectEqual(counted, client.pool.idle_len);
    try std.testing.expect(client.pool.idle_len <= max_idle);

    // Guard against the invariants above passing on a pool that never pooled
    // anything: connections must actually be getting reused.
    try std.testing.expect(client.pool.idle_len > 0);
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

const build_options = @import("build_options");

// Self-signed test certificate from examples/certs. It is CA:TRUE with SANs
// for localhost and 127.0.0.1, so the same file serves as the server
// certificate and as the CA that validates it.
const test_cert_path = "examples/certs/cert.pem";
const test_key_path = "examples/certs/key.pem";

test "Client: HTTPS with a custom CA file" {
    if (!build_options.use_tls) return error.SkipZigTest;
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .tls = .{ .cert_path = test_cert_path, .key_path = test_key_path },
    }, {});
    defer server.deinit();

    server.router.get("/secure", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "over tls";
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

            var client = dusty.Client.init(std.testing.allocator, _io, .{
                .tls = .{ .ca = .{ .file = .{ .path = test_cert_path } } },
            });
            defer client.deinit();

            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/secure", .{s.address.ip.getPort()});

            var response = try client.fetch(url, .{});
            defer response.deinit();

            try std.testing.expectEqual(.ok, response.status());
            try std.testing.expectEqualStrings("over tls", (try response.body()).?);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Client: presents a client certificate for mutual TLS" {
    if (!build_options.use_tls) return error.SkipZigTest;
    const io = std.testing.io;

    // The test certificate is CA:TRUE and self-signed, so the same file serves
    // as the server certificate, the client certificate, and the CA that
    // validates both.
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .tls = .{
            .cert_path = test_cert_path,
            .key_path = test_key_path,
            .client_auth = .{ .ca = .{ .file = .{ .path = test_cert_path } } },
        },
    }, {});
    defer server.deinit();

    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "authed";
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
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{s.address.ip.getPort()});

            var client = dusty.Client.init(std.testing.allocator, _io, .{
                .tls = .{
                    .ca = .{ .file = .{ .path = test_cert_path } },
                    .client_certificate = .{ .cert_path = test_cert_path, .key_path = test_key_path },
                },
            });
            defer client.deinit();

            var response = try client.fetch(url, .{});
            defer response.deinit();

            try std.testing.expectEqual(.ok, response.status());
            try std.testing.expectEqualStrings("authed", (try response.body()).?);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: client_auth .require rejects a client with no certificate" {
    if (!build_options.use_tls) return error.SkipZigTest;
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .tls = .{
            .cert_path = test_cert_path,
            .key_path = test_key_path,
            .client_auth = .{ .ca = .{ .file = .{ .path = test_cert_path } }, .mode = .require },
        },
    }, {});
    defer server.deinit();

    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "unreachable";
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
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{s.address.ip.getPort()});

            var client = dusty.Client.init(std.testing.allocator, _io, .{
                .tls = .{ .ca = .{ .file = .{ .path = test_cert_path } } },
            });
            defer client.deinit();

            // In TLS 1.3 the client finishes its flight before the server can
            // reject the missing certificate, so the refusal surfaces on the
            // first read rather than as a handshake error -- and as the alert
            // the server actually sent, which is a layer below what the read
            // itself could report.
            try std.testing.expectError(error.TlsAlertCertificateRequired, client.fetch(url, .{}));
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: client_auth .request accepts a client with no certificate" {
    if (!build_options.use_tls) return error.SkipZigTest;
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .tls = .{
            .cert_path = test_cert_path,
            .key_path = test_key_path,
            .client_auth = .{ .ca = .{ .file = .{ .path = test_cert_path } }, .mode = .request },
        },
    }, {});
    defer server.deinit();

    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "anonymous";
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
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{s.address.ip.getPort()});

            var client = dusty.Client.init(std.testing.allocator, _io, .{
                .tls = .{ .ca = .{ .file = .{ .path = test_cert_path } } },
            });
            defer client.deinit();

            var response = try client.fetch(url, .{});
            defer response.deinit();

            try std.testing.expectEqual(.ok, response.status());
            try std.testing.expectEqualStrings("anonymous", (try response.body()).?);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Client: rejects a server certificate the configured CA does not cover" {
    if (!build_options.use_tls) return error.SkipZigTest;
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .tls = .{ .cert_path = test_cert_path, .key_path = test_key_path },
    }, {});
    defer server.deinit();

    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
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

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.ready.wait(_io);
            const port = s.address.ip.getPort();
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{port});

            // The system trust store does not contain the self-signed test cert.
            var strict = dusty.Client.init(std.testing.allocator, _io, .{});
            defer strict.deinit();
            try std.testing.expectError(error.TlsInitializationFailed, strict.fetch(url, .{}));

            // insecure_skip_verify takes it anyway.
            var lax = dusty.Client.init(std.testing.allocator, _io, .{
                .tls = .{ .ca = .none, .insecure_skip_verify = true },
            });
            defer lax.deinit();
            var response = try lax.fetch(url, .{});
            defer response.deinit();
            try std.testing.expectEqual(.ok, response.status());
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Client: ca .none without insecure_skip_verify is rejected" {
    if (!build_options.use_tls) return error.SkipZigTest;
    const io = std.testing.io;

    var client = dusty.Client.init(std.testing.allocator, io, .{
        .tls = .{ .ca = .none },
    });
    defer client.deinit();

    // Fails while loading the TLS material, before any connection is attempted.
    try std.testing.expectError(error.NoCertificateAuthority, client.fetch("https://localhost:1/", .{}));
}
