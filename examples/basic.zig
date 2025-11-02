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
    var buf: [1024]u8 = undefined;
    var body_reader = try req.bodyReader();
    const n = try body_reader.readAll(&buf);

    if (n > 0) {
        std.log.info("Received body ({d} bytes): {s}", .{ n, buf[0..n] });
        res.body = try std.fmt.allocPrint(req.arena, "Counter: {d}, Received {d} bytes: {s}\n", .{ ctx.counter, n, buf[0..n] });
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

pub fn runServer(allocator: std.mem.Allocator, rt: *zio.Runtime) !void {
    var ctx: AppContext = .{};

    var server = dusty.Server(AppContext).init(allocator, &ctx);
    defer server.deinit();

    // Register routes
    server.router.get("/", handleRoot);
    server.router.get("/users/:id", handleUser);
    server.router.post("/posts", handlePost);
    server.router.get("/error", handleError);

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
