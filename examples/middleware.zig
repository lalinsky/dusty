const std = @import("std");
const http = @import("dusty");

// --8<-- [start:app]
const App = struct {
    pub const RequestContext = struct {
        user: []const u8 = "guest",
        session: http.SessionData = .{},
    };
};
// --8<-- [end:app]

// --8<-- [start:timing]
const Timing = struct {
    pub const Config = struct {};

    pub fn init(_: Config) !Timing {
        return .{};
    }

    pub fn execute(_: *const Timing, req: *http.Request, res: *http.Response, executor: anytype) !void {
        const start = std.Io.Timestamp.now(req.io, .awake);
        try executor.next();
        const took = start.durationTo(std.Io.Timestamp.now(req.io, .awake));
        const text = try std.fmt.allocPrint(req.arena, "{d}us", .{took.toMicroseconds()});
        try res.header("X-Response-Time", text);
    }
};
// --8<-- [end:timing]

// --8<-- [start:auth]
const Auth = struct {
    pub const Config = struct {
        token: []const u8,
    };

    token: []const u8,

    pub fn init(config: Config) !Auth {
        return .{ .token = config.token };
    }

    pub fn execute(self: *const Auth, req: *http.Request, res: *http.Response, executor: anytype) !void {
        const header = req.headers.get("Authorization") orelse "";
        if (!std.mem.eql(u8, header, self.token)) {
            res.status = .unauthorized;
            return res.print(.text, "Unauthorized\n", .{});
        }
        executor.ctx.user = "admin";
        return executor.next();
    }
};
// --8<-- [end:auth]

// --8<-- [start:log]
const AccessLog = struct {
    pub const Config = struct {};

    pub fn init(_: Config) !AccessLog {
        return .{};
    }

    pub fn execute(_: *const AccessLog, _: *http.Request, _: *http.Response, executor: anytype) !void {
        return executor.next();
    }

    pub fn onComplete(_: *const AccessLog, req: *http.Request, res: *http.Response, _: anytype, err: ?anyerror) void {
        if (err) |e| {
            std.log.info("{f} {s} {d} ({t})", .{ req.method, req.url, @intFromEnum(res.status), e });
        } else {
            std.log.info("{f} {s} {d}", .{ req.method, req.url, @intFromEnum(res.status) });
        }
    }
};
// --8<-- [end:log]

// --8<-- [start:handlers]
fn dashboard(ctx: *App.RequestContext, res: *http.Response) !void {
    try res.print(.text, "Hello, {s}\n", .{ctx.user});
}
// --8<-- [end:handlers]

// --8<-- [start:session]
fn visit(req: *http.Request, ctx: *App.RequestContext, res: *http.Response) !void {
    const before = ctx.session.get("visits") orelse "0";
    const visits = (std.fmt.parseInt(u32, before, 10) catch 0) + 1;
    try ctx.session.set("visits", try std.fmt.allocPrint(req.arena, "{d}", .{visits}));
    try res.print(.text, "Visit {d}\n", .{visits});
}
// --8<-- [end:session]

fn index(res: *http.Response) !void {
    try res.print(.text, "Hello\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var app: App = .{};

    var server = http.Server(App).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        }},
    }, &app);
    defer server.deinit();

    // --8<-- [start:attach]
    const log = try server.middleware(AccessLog, .{});
    const timing = try server.middleware(Timing, .{});
    const session = try server.middleware(http.middleware.Session, .{
        .secret_key = "change me to 32 or more random bytes",
    });
    server.router.middlewares = &.{ log, timing, session };

    server.router.get("/", index);
    server.router.get("/visit", visit);

    const auth = try server.middleware(Auth, .{ .token = "Bearer secret" });
    const admin = server.router.group("/admin", &.{auth});
    admin.get("/", dashboard);
    // --8<-- [end:attach]

    try server.run();
}
