const std = @import("std");
const http = @import("dusty");

// --8<-- [start:app]
const App = struct {
    visits: std.atomic.Value(u64) = .init(0),

    pub fn notFound(req: *http.Request, res: *http.Response) !void {
        res.status = .not_found;
        try res.print(.text, "Nothing at {s}\n", .{req.path});
    }

    pub fn uncaughtError(req: *http.Request, res: *http.Response, err: anyerror) void {
        std.log.err("{s} failed: {t}", .{ req.path, err });
        res.status = .internal_server_error;
        res.print(.text, "Something went wrong\n", .{}) catch {};
    }
};
// --8<-- [end:app]

// --8<-- [start:visits]
fn index(app: *App, res: *http.Response) !void {
    const visit = app.visits.fetchAdd(1, .monotonic) + 1;
    try res.print(.text, "Visit number {d}\n", .{visit});
}
// --8<-- [end:visits]

// --8<-- [start:values]
fn listPosts(
    user: http.Param("id", u64),
    sort: http.Query("sort", ?enum { new, top }),
    lang: http.Header("Accept-Language", ?[]const u8),
    res: *http.Response,
) !void {
    try res.print(.text, "Posts of user {d}, sorted by {t}, in {s}\n", .{
        user.value,
        sort.value orelse .new,
        lang.value orelse "any language",
    });
}
// --8<-- [end:values]

// --8<-- [start:page]
const Page = struct {
    number: u32,
    size: u32,

    pub fn extract(scope: anytype) !Page {
        const number = try http.Query("page", ?u32).extract(scope);
        const size = try http.Query("size", ?u32).extract(scope);
        return .{
            .number = number.value orelse 1,
            .size = @min(size.value orelse 20, 100),
        };
    }
};

fn listComments(page: Page, res: *http.Response) !void {
    try res.print(.text, "Page {d}, {d} per page\n", .{ page.number, page.size });
}
// --8<-- [end:page]

// --8<-- [start:not_found]
fn getPost(id: http.Param("id", u64), res: *http.Response) !void {
    if (id.value > 100) return error.NotFound;
    try res.print(.text, "Post {d}\n", .{id.value});
}
// --8<-- [end:not_found]

fn fail() !void {
    return error.DatabaseDown;
}

pub fn main(init: std.process.Init) !void {
    var app: App = .{};

    var server = http.Server(App).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        }},
    }, &app);
    defer server.deinit();

    server.router.get("/", index);
    server.router.get("/users/:id/posts", listPosts);
    server.router.get("/comments", listComments);
    server.router.get("/posts/:id", getPost);
    server.router.get("/fail", fail);

    try server.run();
}
