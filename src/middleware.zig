const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Action = @import("router.zig").Action;
const Connection = @import("server/connection.zig").Connection;

const log = std.log.scoped(.dusty);

/// Configuration passed to middleware init functions that accept 2 parameters.
/// Provides access to allocators for middlewares that need dynamic allocation.
pub const MiddlewareConfig = struct {
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
};

pub fn Middleware(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        ptr: *anyopaque,
        executeFn: *const fn (
            ptr: *anyopaque,
            req: *Request,
            res: *Response,
            executor: *Executor(Ctx),
        ) anyerror!void,
        deinitFn: ?*const fn (ptr: *anyopaque) void,

        pub fn init(impl: anytype) Self {
            const Ptr = @TypeOf(impl);
            const Impl = @typeInfo(Ptr).pointer.child;

            const gen = struct {
                fn execute(ptr: *anyopaque, req: *Request, res: *Response, executor: *Executor(Ctx)) anyerror!void {
                    const self: Ptr = @ptrCast(@alignCast(ptr));
                    return self.execute(req, res, executor);
                }

                fn deinit(ptr: *anyopaque) void {
                    const self: Ptr = @ptrCast(@alignCast(ptr));
                    self.deinit();
                }
            };

            return .{
                .ptr = @ptrCast(@constCast(impl)),
                .executeFn = gen.execute,
                .deinitFn = if (@hasDecl(Impl, "deinit")) gen.deinit else null,
            };
        }

        pub fn execute(self: Self, req: *Request, res: *Response, executor: *Executor(Ctx)) !void {
            return self.executeFn(self.ptr, req, res, executor);
        }

        pub fn deinit(self: Self) void {
            if (self.deinitFn) |f| {
                f(self.ptr);
            }
        }
    };
}

pub fn Executor(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        index: usize = 0,
        req: *Request,
        res: *Response,
        ctx: if (Ctx == void) void else *Ctx,
        action: ?Action(Ctx),
        middlewares: []const Middleware(Ctx),

        pub fn run(self: *Self) !void {
            self.next() catch |err| switch (err) {
                // Connection-level failures can't produce a response; propagate
                // so the connection loop aborts.
                error.ReadFailed, error.WriteFailed, error.Canceled => return err,
                // Handler/middleware errors: prepare an error response (500, or
                // the app's uncaughtError) and return normally so the server
                // writes it, instead of tearing down the connection with no
                // reply.
                else => {
                    if (self.res.headers_written) {
                        // The response already started (e.g. streaming/chunked
                        // body or a WebSocket upgrade), so headers were sent
                        // with framing that doesn't account for an error body.
                        // We can't safely rewrite it as a 500; abort the
                        // connection instead of corrupting the response.
                        log.err("unhandled error after response headers were sent: {}", .{err});
                        return err;
                    }
                    log.err("unhandled error in request handler: {}", .{err});
                    self.handleError(err);
                },
            };
        }

        pub fn next(self: *Self) anyerror!void {
            if (self.index < self.middlewares.len) {
                const mw = self.middlewares[self.index];
                self.index += 1;
                return mw.execute(self.req, self.res, self);
            }

            // All middlewares executed, call dispatcher or handler
            if (self.action) |action| {
                if (comptime Ctx != void and @hasDecl(Ctx, "dispatch")) {
                    return self.ctx.dispatch(action, self.req, self.res);
                } else if (comptime Ctx == void) {
                    return action(self.req, self.res);
                } else {
                    return action(self.ctx, self.req, self.res);
                }
            } else {
                try self.handleNotFound();
            }
        }

        fn handleNotFound(self: *Self) !void {
            // A middleware may have written part of a body before the
            // router came up empty, and `write` would send that in place
            // of the 404. Unlike the error path, nothing has checked the
            // headers yet: a middleware that started streaming has already
            // committed the framing, so there is nothing to replace.
            if (!self.res.headers_written) self.res.resetBody();
            if (comptime Ctx != void and @hasDecl(Ctx, "notFound")) {
                try self.ctx.notFound(self.req, self.res);
            } else {
                self.res.status = .not_found;
                self.res.content_type = .text;
                self.res.body = "404 Not Found\n";
            }
        }

        fn handleError(self: *Self, err: anyerror) void {
            // Whatever the handler managed to write is half of something
            // it did not finish, and `write` would send it in place of the
            // error response. The caller has already checked that the
            // headers are still open.
            self.res.resetBody();
            if (comptime Ctx != void and @hasDecl(Ctx, "uncaughtError")) {
                self.ctx.uncaughtError(self.req, self.res, err);
            } else {
                self.res.status = .internal_server_error;
                self.res.content_type = .text;
                self.res.body = "500 Internal Server Error\n";
            }
        }
    };
}

// Tests

// Simple call tracker using fixed-size array
const CallTracker = struct {
    calls: [8]u8 = undefined,
    len: usize = 0,

    fn append(self: *CallTracker, id: u8) void {
        if (self.len < self.calls.len) {
            self.calls[self.len] = id;
            self.len += 1;
        }
    }

    fn items(self: *const CallTracker) []const u8 {
        return self.calls[0..self.len];
    }
};

const TestMiddleware = struct {
    tracker: *CallTracker,
    id: u8,

    pub fn execute(self: *const TestMiddleware, req: *Request, res: *Response, executor: *Executor(void)) !void {
        _ = req;
        _ = res;
        self.tracker.append(self.id);
        return executor.next();
    }
};

const ShortCircuitMiddleware = struct {
    tracker: *CallTracker,
    id: u8,

    pub fn execute(self: *const ShortCircuitMiddleware, req: *Request, res: *Response, executor: *Executor(void)) !void {
        _ = req;
        _ = executor;
        self.tracker.append(self.id);
        res.body = "short-circuited";
        // Don't call executor.next() - short circuit
    }
};

fn testHandler(req: *Request, res: *Response) !void {
    _ = req;
    res.body = "handler called";
}

fn makeTestResponse() Response {
    return Response{
        .body = "",
        .status = .ok,
        .headers = .{},
        .content_type = null,
        .arena = undefined,
        // Real storage rather than undefined: the 404 and 500 paths clear
        // the buffer, and `init` allocates nothing until something is
        // written, so a test that writes no body still leaks nothing.
        .buffer = .init(std.testing.allocator),
        .conn = undefined,
        .written = false,
        .headers_written = false,
        .keepalive = true,
        .chunked = false,
        .streaming = false,
    };
}

test "Middleware: single middleware executes before handler" {
    var tracker = CallTracker{};
    var mw = TestMiddleware{ .tracker = &tracker, .id = 1 };
    const middlewares = [_]Middleware(void){Middleware(void).init(&mw)};

    var req: Request = undefined;
    var res = makeTestResponse();

    var executor = Executor(void){
        .req = &req,
        .res = &res,
        .ctx = {},
        .action = testHandler,
        .middlewares = &middlewares,
    };

    try executor.next();

    try std.testing.expectEqual(1, tracker.len);
    try std.testing.expectEqual(1, tracker.items()[0]);
    try std.testing.expectEqualStrings("handler called", res.body);
}

test "Middleware: multiple middlewares execute in order" {
    var tracker = CallTracker{};

    var mw1 = TestMiddleware{ .tracker = &tracker, .id = 1 };
    var mw2 = TestMiddleware{ .tracker = &tracker, .id = 2 };
    var mw3 = TestMiddleware{ .tracker = &tracker, .id = 3 };

    const middlewares = [_]Middleware(void){
        Middleware(void).init(&mw1),
        Middleware(void).init(&mw2),
        Middleware(void).init(&mw3),
    };

    var req: Request = undefined;
    var res = makeTestResponse();

    var executor = Executor(void){
        .req = &req,
        .res = &res,
        .ctx = {},
        .action = testHandler,
        .middlewares = &middlewares,
    };

    try executor.next();

    try std.testing.expectEqual(3, tracker.len);
    try std.testing.expectEqual(1, tracker.items()[0]);
    try std.testing.expectEqual(2, tracker.items()[1]);
    try std.testing.expectEqual(3, tracker.items()[2]);
    try std.testing.expectEqualStrings("handler called", res.body);
}

test "Middleware: short-circuit prevents handler execution" {
    var tracker = CallTracker{};

    var mw1 = TestMiddleware{ .tracker = &tracker, .id = 1 };
    var mw2 = ShortCircuitMiddleware{ .tracker = &tracker, .id = 2 };
    var mw3 = TestMiddleware{ .tracker = &tracker, .id = 3 };

    const middlewares = [_]Middleware(void){
        Middleware(void).init(&mw1),
        Middleware(void).init(&mw2),
        Middleware(void).init(&mw3),
    };

    var req: Request = undefined;
    var res = makeTestResponse();

    var executor = Executor(void){
        .req = &req,
        .res = &res,
        .ctx = {},
        .action = testHandler,
        .middlewares = &middlewares,
    };

    try executor.next();

    // mw1 runs, mw2 short-circuits, mw3 and handler don't run
    try std.testing.expectEqual(2, tracker.len);
    try std.testing.expectEqual(1, tracker.items()[0]);
    try std.testing.expectEqual(2, tracker.items()[1]);
    try std.testing.expectEqualStrings("short-circuited", res.body);
}

test "Middleware: no middlewares calls handler directly" {
    var req: Request = undefined;
    var res = makeTestResponse();

    var executor = Executor(void){
        .req = &req,
        .res = &res,
        .ctx = {},
        .action = testHandler,
        .middlewares = &.{},
    };

    try executor.next();

    try std.testing.expectEqualStrings("handler called", res.body);
}

test "Middleware: no action returns 404" {
    var tracker = CallTracker{};
    var mw = TestMiddleware{ .tracker = &tracker, .id = 1 };
    const middlewares = [_]Middleware(void){Middleware(void).init(&mw)};

    var req: Request = undefined;
    var res = makeTestResponse();

    var executor = Executor(void){
        .req = &req,
        .res = &res,
        .ctx = {},
        .action = null,
        .middlewares = &middlewares,
    };

    try executor.next();

    try std.testing.expectEqual(1, tracker.len);
    try std.testing.expectEqual(.not_found, res.status);
    try std.testing.expectEqualStrings("404 Not Found\n", res.body);
}

fn errorHandler(_: *Request, _: *Response) !void {
    return error.TestError;
}

test "Executor: default 500 handler on action error" {
    var req: Request = undefined;
    var res = makeTestResponse();

    var executor = Executor(void){
        .req = &req,
        .res = &res,
        .ctx = {},
        .action = errorHandler,
        .middlewares = &.{},
    };

    executor.run() catch {};

    try std.testing.expectEqual(.internal_server_error, res.status);
    try std.testing.expectEqualStrings("500 Internal Server Error\n", res.body);
}

test "Executor: error after headers written propagates instead of rewriting the response" {
    var req: Request = undefined;
    var res = makeTestResponse();
    // Simulate a response that already started (e.g. a streamed/chunked body
    // or a WebSocket upgrade) before the handler failed.
    res.headers_written = true;

    var executor = Executor(void){
        .req = &req,
        .res = &res,
        .ctx = {},
        .action = errorHandler,
        .middlewares = &.{},
    };

    try std.testing.expectError(error.TestError, executor.run());

    // handleError() must not run: the already-sent headers can't be undone,
    // so status/body are left untouched rather than rewritten to a 500.
    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings("", res.body);
}

const CustomCtx = struct {
    not_found_called: bool = false,
    uncaught_error_called: bool = false,
    dispatch_called: bool = false,
    last_error: ?anyerror = null,

    pub fn notFound(self: *CustomCtx, _: *Request, res: *Response) !void {
        self.not_found_called = true;
        res.status = .not_found;
        res.body = "custom 404";
    }

    pub fn uncaughtError(self: *CustomCtx, _: *Request, res: *Response, err: anyerror) void {
        self.uncaught_error_called = true;
        self.last_error = err;
        res.status = .internal_server_error;
        res.body = "custom 500";
    }

    pub fn dispatch(self: *CustomCtx, action: Action(CustomCtx), req: *Request, res: *Response) !void {
        self.dispatch_called = true;
        res.body = "before dispatch | ";
        try action(self, req, res);
    }
};

fn customCtxHandler(ctx: *CustomCtx, _: *Request, res: *Response) !void {
    _ = ctx;
    res.body = "custom handler";
}

fn customCtxErrorHandler(_: *CustomCtx, _: *Request, _: *Response) !void {
    return error.CustomError;
}

const ErrorMiddleware = struct {
    pub fn execute(_: *const ErrorMiddleware, _: *Request, _: *Response, _: *Executor(CustomCtx)) !void {
        return error.MiddlewareError;
    }
};

test "Executor: custom notFound handler" {
    var ctx = CustomCtx{};
    var req: Request = undefined;
    var res = makeTestResponse();

    var executor = Executor(CustomCtx){
        .req = &req,
        .res = &res,
        .ctx = &ctx,
        .action = null,
        .middlewares = &.{},
    };

    executor.run() catch {};

    try std.testing.expect(ctx.not_found_called);
    try std.testing.expectEqual(.not_found, res.status);
    try std.testing.expectEqualStrings("custom 404", res.body);
}

test "Executor: custom uncaughtError handler" {
    var ctx = CustomCtx{};
    var req: Request = undefined;
    var res = makeTestResponse();

    var executor = Executor(CustomCtx){
        .req = &req,
        .res = &res,
        .ctx = &ctx,
        .action = customCtxErrorHandler,
        .middlewares = &.{},
    };

    executor.run() catch {};

    try std.testing.expect(ctx.uncaught_error_called);
    try std.testing.expectEqual(error.CustomError, ctx.last_error.?);
    try std.testing.expectEqual(.internal_server_error, res.status);
    try std.testing.expectEqualStrings("custom 500", res.body);
}

test "Executor: custom dispatch method" {
    var ctx = CustomCtx{};
    var req: Request = undefined;
    var res = makeTestResponse();

    var executor = Executor(CustomCtx){
        .req = &req,
        .res = &res,
        .ctx = &ctx,
        .action = customCtxHandler,
        .middlewares = &.{},
    };

    try executor.run();

    try std.testing.expect(ctx.dispatch_called);
    try std.testing.expectEqualStrings("custom handler", res.body);
}

test "Executor: middleware error triggers custom uncaughtError" {
    var ctx = CustomCtx{};
    var req: Request = undefined;
    var res = makeTestResponse();

    var mw = ErrorMiddleware{};
    const middlewares = [_]Middleware(CustomCtx){Middleware(CustomCtx).init(&mw)};

    var executor = Executor(CustomCtx){
        .req = &req,
        .res = &res,
        .ctx = &ctx,
        .action = customCtxHandler,
        .middlewares = &middlewares,
    };

    executor.run() catch {};

    try std.testing.expect(ctx.uncaught_error_called);
    try std.testing.expectEqual(error.MiddlewareError, ctx.last_error.?);
    try std.testing.expectEqual(.internal_server_error, res.status);
    try std.testing.expectEqualStrings("custom 500", res.body);
}

test "Executor: a handler that fails mid-body does not send the fragment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var req: Request = .{ .arena = arena.allocator(), .conn = undefined, .parser = undefined };
    var res = try Response.init(arena.allocator(), &connection, 32);

    var executor = Executor(void){
        .req = &req,
        .res = &res,
        .ctx = {},
        .action = struct {
            fn handle(_: *Request, r: *Response) !void {
                r.content_type = .json;
                var body = r.writer();
                try body.interface.writeAll("{\"half\":");
                return error.Boom;
            }
        }.handle,
        .middlewares = &.{},
    };

    try executor.run();
    try std.testing.expectEqual(.internal_server_error, res.status);

    try res.write();
    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "half") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "application/json") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "500 Internal Server Error\n"));
}

const WritingMiddleware = struct {
    pub fn execute(_: *const WritingMiddleware, _: *Request, res: *Response, executor: *Executor(void)) !void {
        res.content_type = .json;
        var body = res.writer();
        try body.interface.writeAll("{\"half\":");
        return executor.next();
    }
};

test "Executor: a middleware that wrote a body does not supply the 404" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var req: Request = .{ .arena = arena.allocator(), .conn = undefined, .parser = undefined };
    var res = try Response.init(arena.allocator(), &connection, 32);

    var mw = WritingMiddleware{};
    const middlewares = [_]Middleware(void){Middleware(void).init(&mw)};
    var executor = Executor(void){
        .req = &req,
        .res = &res,
        .ctx = {},
        // No route matched, so the executor falls through to the 404.
        .action = null,
        .middlewares = &middlewares,
    };

    try executor.run();
    try std.testing.expectEqual(.not_found, res.status);

    try res.write();
    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "half") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "application/json") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "404 Not Found\n"));
}
