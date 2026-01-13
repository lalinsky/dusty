const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Action = @import("router.zig").Action;

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
        node: std.SinglyLinkedList.Node = .{},

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

        pub fn run(self: *Self) void {
            self.next() catch |err| {
                self.handleError(err);
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
            if (comptime Ctx != void and @hasDecl(Ctx, "notFound")) {
                try self.ctx.notFound(self.req, self.res);
            } else {
                self.res.status = .not_found;
                self.res.body = "404 Not Found\n";
            }
        }

        fn handleError(self: *Self, err: anyerror) void {
            if (comptime Ctx != void and @hasDecl(Ctx, "uncaughtError")) {
                self.ctx.uncaughtError(self.req, self.res, err);
            } else {
                self.res.status = .internal_server_error;
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
        .buffer = undefined,
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

    executor.run();

    try std.testing.expectEqual(.internal_server_error, res.status);
    try std.testing.expectEqualStrings("500 Internal Server Error\n", res.body);
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

    executor.run();

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

    executor.run();

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

    executor.run();

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

    executor.run();

    try std.testing.expect(ctx.uncaught_error_called);
    try std.testing.expectEqual(error.MiddlewareError, ctx.last_error.?);
    try std.testing.expectEqual(.internal_server_error, res.status);
    try std.testing.expectEqualStrings("custom 500", res.body);
}
