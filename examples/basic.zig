const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");

const AppContext = struct {
    counter: usize = 0,
};

fn handleRoot(ctx: *AppContext, req: *const dusty.Request, res: *dusty.Response) void {
    _ = ctx;
    _ = req;
    res.body = "Hello World!\n";
}

fn handleUser(ctx: *AppContext, req: *const dusty.Request, res: *dusty.Response) void {
    _ = ctx;
    const id = req.params.get("id") orelse "unknown";
    res.body = std.fmt.allocPrint(req.arena, "Hello User {s}\n", .{id}) catch unreachable;
}

fn handlePost(ctx: *AppContext, req: *const dusty.Request, res: *dusty.Response) void {
    ctx.counter += 1;
    res.body = std.fmt.allocPrint(req.arena, "Counter: {d}\n", .{ctx.counter}) catch unreachable;
}

pub fn runServer(allocator: std.mem.Allocator, rt: *zio.Runtime) !void {
    var ctx: AppContext = .{};

    var server = dusty.Server(AppContext).init(allocator, &ctx);
    defer server.deinit();

    // Register routes
    server.router.get("/", handleRoot);
    server.router.get("/users/:id", handleUser);
    server.router.post("/posts", handlePost);

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
