const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");

const AppContext = struct {
    counter: usize = 0,

    pub fn uncaughtError(self: *AppContext, req: *dusty.Request, res: *dusty.Response, err: anyerror) void {
        _ = self;
        std.log.err("Uncaught error for {s}: {}", .{ req.url, err });
        res.status = .internal_server_error;
        res.body = std.fmt.allocPrint(res.arena, "Error: {s}\n", .{@errorName(err)}) catch "500 Internal Server Error\n";
    }

    pub fn notFound(self: *AppContext, req: *dusty.Request, res: *dusty.Response) !void {
        _ = self;
        std.log.warn("Route not found: {s}", .{req.url});
        res.status = .not_found;
        res.body = try std.fmt.allocPrint(res.arena, "Oops! '{s}' was not found\n", .{req.url});
    }
};

fn handleRoot(ctx: *AppContext, req: *dusty.Request, res: *dusty.Response) !void {
    _ = ctx;
    _ = req;
    res.body = "Hello World!\n";
}

fn handleUser(ctx: *AppContext, req: *dusty.Request, res: *dusty.Response) !void {
    _ = ctx;
    const id = req.params.get("id") orelse "unknown";
    res.body = try std.fmt.allocPrint(req.arena, "Hello User {s}\n", .{id});
}

fn handlePost(ctx: *AppContext, req: *dusty.Request, res: *dusty.Response) !void {
    ctx.counter += 1;

    // Read the request body
    var reader = req.reader();
    const body = try reader.interface.allocRemaining(req.arena, .limited(1024 * 1024));

    if (body.len > 0) {
        std.log.info("Received body ({d} bytes): {s}", .{ body.len, body });
        res.body = try std.fmt.allocPrint(req.arena, "Counter: {d}, Received {d} bytes: {s}\n", .{ ctx.counter, body.len, body });
    } else {
        res.body = try std.fmt.allocPrint(req.arena, "Counter: {d}\n", .{ctx.counter});
    }
}

fn handleError(ctx: *AppContext, req: *dusty.Request, res: *dusty.Response) !void {
    _ = ctx;
    _ = req;
    _ = res;
    return error.TestError;
}

fn handleChunked(ctx: *AppContext, req: *const dusty.Request, res: *dusty.Response) !void {
    _ = ctx;
    _ = req;

    // Set custom headers before first chunk
    try res.header("X-Demo", "Chunked-Response");
    res.status = .ok;

    // Send chunks of data
    try res.chunk("First chunk of data\n");
    try res.chunk("Second chunk of data\n");
    try res.chunk("Third chunk of data\n");

    // Dynamic content in chunk
    const dynamic = try std.fmt.allocPrint(res.arena, "Chunk with timestamp: {d}\n", .{std.time.timestamp()});
    try res.chunk(dynamic);

    try res.chunk("Final chunk!\n");
    // res.write() will be called automatically by the server to add terminator
}

pub fn runServer(allocator: std.mem.Allocator, rt: *zio.Runtime) !void {
    var ctx: AppContext = .{};

    var server = dusty.Server(AppContext).init(allocator, &ctx);
    defer server.deinit();

    // Register routes
    server.router.get("/", handleRoot);
    server.router.get("/users/:id", handleUser);
    server.router.post("/posts", handlePost);
    server.router.get("/error", handleError);
    server.router.get("/chunked", handleChunked);

    const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 8080);
    try server.listen(rt, addr);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(runServer, .{ allocator, rt }, .{});
}
