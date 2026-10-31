const std = @import("std");
const http = @import("dusty");

// --8<-- [start:info]
fn info(req: *http.Request, res: *http.Response) !void {
    const agent = req.headers.get("User-Agent") orelse "unknown";
    const page = req.query.get("page") orelse "1";
    try res.print(.text, "{f} {s}, page {s}, from {s}\n", .{ req.method, req.path, page, agent });
}
// --8<-- [end:info]

// --8<-- [start:body]
fn upload(req: *http.Request, res: *http.Response) !void {
    const body = try req.body() orelse "";
    try res.print(.text, "Got {d} bytes\n", .{body.len});
}
// --8<-- [end:body]

// --8<-- [start:reader]
fn count(req: *http.Request, res: *http.Response) !void {
    var buf: [4096]u8 = undefined;
    var body = try req.reader(&buf);

    var lines: usize = 0;
    while (try body.interface.takeDelimiter('\n')) |_| lines += 1;

    try res.print(.text, "Got {d} lines\n", .{lines});
}
// --8<-- [end:reader]

// --8<-- [start:form]
fn login(req: *http.Request, res: *http.Response) !void {
    const form = try req.formData();
    const user = form.get("user") orelse {
        res.status = .bad_request;
        return res.print(.text, "Missing user\n", .{});
    };
    try res.print(.text, "Hello, {s}\n", .{user});
}
// --8<-- [end:form]

// --8<-- [start:multipart]
fn avatar(req: *http.Request, res: *http.Response) !void {
    const form = try req.multiFormData();
    const file = form.get("avatar") orelse {
        res.status = .bad_request;
        return res.print(.text, "Missing avatar\n", .{});
    };
    try res.print(.text, "{s}, {d} bytes\n", .{ file.filename orelse "no name", file.value.len });
}
// --8<-- [end:multipart]

// --8<-- [start:cookies]
fn theme(req: *http.Request, res: *http.Response) !void {
    const value = req.cookies().get("theme") orelse "light";
    try res.print(.text, "Theme: {s}\n", .{value});
}
// --8<-- [end:cookies]

pub fn main(init: std.process.Init) !void {
    var server = http.Server(void).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        }},
    }, {});
    defer server.deinit();

    server.router.get("/info", info);
    server.router.post("/upload", upload);
    server.router.post("/count", count);
    server.router.post("/login", login);
    server.router.post("/avatar", avatar);
    server.router.get("/theme", theme);

    try server.run();
}
