const std = @import("std");
const http = @import("dusty");

// --8<-- [start:handlers]
fn listUsers(res: *http.Response) !void {
    try res.print(.text, "All users\n", .{});
}

fn createUser(res: *http.Response) !void {
    res.status = .created;
    try res.print(.text, "Created\n", .{});
}

fn getUser(id: http.Param("id", u64), res: *http.Response) !void {
    try res.print(.text, "User {d}\n", .{id.value});
}

fn getCurrentUser(res: *http.Response) !void {
    try res.print(.text, "You\n", .{});
}
// --8<-- [end:handlers]

// --8<-- [start:raw]
fn getOrder(req: *http.Request, res: *http.Response) !void {
    const id = req.params.get("id").?;
    try res.print(.text, "Order {s}\n", .{id});
}
// --8<-- [end:raw]

// --8<-- [start:enum]
const Lang = enum { en, de, sk };

fn getDocs(lang: http.Param("lang", Lang), res: *http.Response) !void {
    try res.print(.text, "Docs in {t}\n", .{lang.value});
}
// --8<-- [end:enum]

// --8<-- [start:slug]
const Slug = struct {
    text: []const u8,

    pub fn parseParam(raw: []const u8) ?Slug {
        for (raw) |c| switch (c) {
            'a'...'z', '0'...'9', '-' => {},
            else => return null,
        };
        return .{ .text = raw };
    }
};

fn getPost(slug: http.Param("slug", Slug), res: *http.Response) !void {
    try res.print(.text, "Post {s}\n", .{slug.value.text});
}
// --8<-- [end:slug]

// --8<-- [start:wildcard]
fn getFile(path: http.Param("path", []const u8), res: *http.Response) !void {
    try res.print(.text, "File {s}\n", .{path.value});
}
// --8<-- [end:wildcard]

fn apiStatus(res: *http.Response) !void {
    try res.print(.text, "OK\n", .{});
}

fn fallback(req: *http.Request, res: *http.Response) !void {
    res.status = .not_found;
    try res.print(.text, "Nothing at {s}\n", .{req.path});
}

pub fn main(init: std.process.Init) !void {
    var server = http.Server(void).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        }},
    }, {});
    defer server.deinit();

    // --8<-- [start:middleware]
    const cors = try server.middleware(http.middleware.Cors, .{ .origin = "*" });
    server.router.middlewares = &.{cors};
    // --8<-- [end:middleware]

    // --8<-- [start:routes]
    server.router.get("/users", listUsers);
    server.router.post("/users", createUser);
    server.router.get("/users/:id", getUser);
    server.router.get("/users/me", getCurrentUser);
    // --8<-- [end:routes]

    server.router.get("/orders/:id", getOrder);
    server.router.get("/docs/:lang", getDocs);
    server.router.get("/posts/:slug", getPost);

    // --8<-- [start:wildcard_route]
    server.router.get("/files/*path", getFile);
    // --8<-- [end:wildcard_route]

    // --8<-- [start:group]
    const api = server.router.group("/api/v1", &.{});
    api.get("/status", apiStatus);
    // --8<-- [end:group]

    // --8<-- [start:any]
    server.router.any("/*path", fallback);
    // --8<-- [end:any]

    try server.run();
}
