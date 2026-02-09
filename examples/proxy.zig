const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

const AppContext = struct {
    io: *zio.Runtime,
    client: *http.Client,
    upstream_url: []const u8,
};

fn handleProxy(ctx: *AppContext, req: *http.Request, res: *http.Response) !void {
    // Build the full upstream URL
    const full_url = try std.fmt.allocPrint(req.arena, "{s}{s}", .{ ctx.upstream_url, req.url });
    std.log.info("Proxying {s} {s} -> {s}", .{ @tagName(req.method), req.url, full_url });

    // Create upstream request options
    var upstream_req: http.FetchOptions = .{
        .method = req.method,
        .decompress = false, // Important: disable decompression to preserve original body
    };

    // Forward request headers (excluding hop-by-hop headers)
    var headers: http.Headers = .{};
    var it = req.headers.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        // Skip hop-by-hop headers that shouldn't be forwarded
        if (std.ascii.eqlIgnoreCase(key, "connection") or
            std.ascii.eqlIgnoreCase(key, "keep-alive") or
            std.ascii.eqlIgnoreCase(key, "transfer-encoding") or
            std.ascii.eqlIgnoreCase(key, "upgrade") or
            std.ascii.eqlIgnoreCase(key, "proxy-connection"))
        {
            continue;
        }

        try headers.put(req.arena, key, value);
    }
    upstream_req.headers = &headers;

    // Forward request body if present
    var reader = req.reader();
    const body = try reader.interface.allocRemaining(req.arena, .limited(10 * 1024 * 1024)); // 10MB limit
    if (body.len > 0) {
        upstream_req.body = body;
        std.log.info("Forwarding request body: {d} bytes", .{body.len});
    }

    // Make upstream request
    var upstream_res = ctx.client.fetch(full_url, upstream_req) catch |err| {
        std.log.err("Upstream request failed: {}", .{err});
        res.status = .bad_gateway;
        res.body = try std.fmt.allocPrint(res.arena, "Upstream error: {s}\n", .{@errorName(err)});
        return;
    };
    defer upstream_res.deinit();

    // Copy upstream response status
    res.status = upstream_res.status();

    // Forward response headers (excluding hop-by-hop headers)
    var upstream_headers = upstream_res.headers();
    var upstream_it = upstream_headers.iterator();
    while (upstream_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        // Skip hop-by-hop headers
        if (std.ascii.eqlIgnoreCase(key, "connection") or
            std.ascii.eqlIgnoreCase(key, "keep-alive") or
            std.ascii.eqlIgnoreCase(key, "transfer-encoding") or
            std.ascii.eqlIgnoreCase(key, "upgrade") or
            std.ascii.eqlIgnoreCase(key, "proxy-connection"))
        {
            continue;
        }

        try res.header(key, value);
    }

    // Stream response body
    const body_reader = upstream_res.reader();
    const res_writer = res.writer();
    const bytes_written = try body_reader.streamRemaining(res_writer);

    std.log.info("Proxied response: {d} bytes", .{bytes_written});
}

pub fn runServer(allocator: std.mem.Allocator, io: *zio.Runtime, upstream_url: []const u8) !void {
    var client = http.Client.init(allocator, .{});
    defer client.deinit();

    var ctx: AppContext = .{
        .io = io,
        .client = &client,
        .upstream_url = upstream_url,
    };

    var server = http.Server(AppContext).init(allocator, .{}, &ctx);
    defer server.deinit();

    // Catch-all route - proxy everything
    // Register for all common HTTP methods
    server.router.get("/*", handleProxy);
    server.router.post("/*", handleProxy);
    server.router.put("/*", handleProxy);
    server.router.delete("/*", handleProxy);
    server.router.head("/*", handleProxy);

    const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 8080);

    std.log.info("Reverse proxy server running at http://127.0.0.1:8080", .{});
    std.log.info("Forwarding all requests to: {s}", .{upstream_url});
    std.log.info("", .{});
    std.log.info("Try: curl http://127.0.0.1:8080/get", .{});
    std.log.info("     curl -X POST http://127.0.0.1:8080/post -d 'hello=world'", .{});

    try server.listen(addr);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const upstream_url = if (args.len > 1)
        args[1]
    else
        "https://httpbin.org";

    var io = try zio.Runtime.init(allocator, .{});
    defer io.deinit();

    var task = try zio.spawn(runServer, .{ allocator, io, upstream_url });
    try task.join();
}
