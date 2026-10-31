const std = @import("std");
const Request = @import("request.zig").Request;
const inject = @import("inject.zig");
const Response = @import("response.zig").Response;
const Method = @import("http.zig").Method;
const Middleware = @import("middleware.zig").Middleware;
const Static = @import("server/static.zig").Static;
const StaticOptions = @import("server/static.zig").StaticOptions;
const Precompressed = @import("server/static.zig").Precompressed;
const Embedded = @import("server/static.zig").Embedded;
const EmbeddedOptions = @import("server/static.zig").EmbeddedOptions;

/// What a request learns of the route it matched, as `Request.route`.
pub const RouteInfo = struct {
    /// The pattern the route was registered under, group prefix included:
    /// `/users/:id`, not the path that matched it.
    path: []const u8,
    /// Whatever the route was registered with, for its handler to cast
    /// back. Null for the routes `get`, `post` and the like register.
    data: ?*const anyopaque = null,
};

const NodeKind = enum {
    static,
    param,
    wildcard,
};

const Node = struct {
    // Compressed path segment
    segment: []const u8,

    // Type of this segment
    kind: NodeKind,

    // For param/wildcard nodes, the parameter name (without ':' or '*')
    param_name: ?[]const u8,

    // Children organized by type for proper precedence:
    // 1. Static children (checked first) - linked list
    static_children: ?*Node,
    // 2. Param child (checked second) - single node
    param_child: ?*Node,
    // 3. Wildcard child (checked last) - single node
    wildcard_child: ?*Node,

    // For linked list of siblings (only used in static_children)
    next_sibling: ?*Node,

    // Route (opaque pointer to Route) - only set on terminal nodes
    route: ?*const anyopaque,
};

pub fn Action(comptime Ctx: type) type {
    return *const Router(Ctx).Handler;
}

pub fn Router(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        /// What the router calls. A handler registered with `get`, `post`
        /// and the like can instead take any of `*Ctx`, `*Request`,
        /// `*Response` and `*Ctx.RequestState`, in any order.
        pub const Handler = if (Ctx == void)
            fn (*Request, *Response) anyerror!void
        else
            fn (*Ctx, *Request, *Response) anyerror!void;

        pub const Route = struct {
            info: RouteInfo,
            action: *const Handler,
            middlewares: []const Middleware(Ctx),
        };

        arena: std.heap.ArenaAllocator,
        // Each HTTP method has its own radix tree
        trees: [256]?*Node,
        // Routes registered with `any`, tried after the method's own tree
        any_tree: ?*Node = null,
        // Global middlewares applied to all routes
        middlewares: []const Middleware(Ctx) = &.{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .trees = @splat(null),
            };
        }

        pub fn deinit(self: *Self) void {
            // Arena deinit frees everything at once
            self.arena.deinit();
        }

        fn findChild(parent: *Node, segment: []const u8, kind: NodeKind) ?*Node {
            switch (kind) {
                .static => {
                    // Search in static_children linked list
                    var child = parent.static_children;
                    while (child) |c| {
                        if (std.mem.eql(u8, c.segment, segment)) {
                            return c;
                        }
                        child = c.next_sibling;
                    }
                    return null;
                },
                .param => return parent.param_child,
                .wildcard => return parent.wildcard_child,
            }
        }

        const Conflict = struct {
            method: Method,
            method_path: []const u8,
            any_path: []const u8,
        };

        /// The first route that registering `path` for `method`, or for
        /// `any` when null, would conflict with.
        fn findConflict(self: *const Self, path: []const u8, method: ?Method) ?Conflict {
            if (method) |m| {
                const root = self.any_tree orelse return null;
                const other = findConflictIn(root, path, false) orelse return null;
                return .{ .method = m, .method_path = path, .any_path = other };
            }
            for (self.trees, 0..) |tree, i| {
                const root = tree orelse continue;
                const other = findConflictIn(root, path, true) orelse continue;
                return .{ .method = @enumFromInt(i), .method_path = other, .any_path = path };
            }
            return null;
        }

        fn findConflictIn(node: *const Node, path: []const u8, path_is_any: bool) ?[]const u8 {
            if (node.route) |opaque_route| {
                const route: *const Route = @ptrCast(@alignCast(opaque_route));
                const other = route.info.path;
                if (if (path_is_any) conflicts(other, path) else conflicts(path, other)) return other;
            }
            var child = node.static_children;
            while (child) |c| : (child = c.next_sibling) {
                if (findConflictIn(c, path, path_is_any)) |other| return other;
            }
            if (node.param_child) |c| if (findConflictIn(c, path, path_is_any)) |other| return other;
            if (node.wildcard_child) |c| if (findConflictIn(c, path, path_is_any)) |other| return other;
            return null;
        }

        fn insertRoute(
            self: *Self,
            path: []const u8,
            method: ?Method,
            handler: *const Handler,
            middlewares: []const Middleware(Ctx),
            data: ?*const anyopaque,
        ) !void {
            if (self.findConflict(path, method)) |c| {
                std.debug.panic("route {s} {s} conflicts with any() route {s}: both match some paths, but {s} is not more specific", .{ c.method.name(), c.method_path, c.any_path, c.method_path });
            }

            const slot = if (method) |m| &self.trees[@intFromEnum(m)] else &self.any_tree;

            // Get or create root for this method
            if (slot.* == null) {
                const root = try self.arena.allocator().create(Node);
                root.* = Node{
                    .segment = "",
                    .kind = .static,
                    .param_name = null,
                    .static_children = null,
                    .param_child = null,
                    .wildcard_child = null,
                    .next_sibling = null,
                    .route = null,
                };
                slot.* = root;
            }

            var current = slot.*.?;

            var iter = std.mem.splitScalar(u8, path, '/');
            while (iter.next()) |segment| {
                if (segment.len == 0) continue;
                // Determine segment kind
                const kind: NodeKind = if (segment[0] == '*')
                    .wildcard
                else if (segment[0] == ':')
                    .param
                else
                    .static;

                const param_name = if (kind == .param or kind == .wildcard)
                    segment[1..]
                else
                    null;

                // Matched against the decoded segments of a request, so
                // `/a%2Fb` is the one segment `a/b`, as in Go's ServeMux.
                const static_segment = if (kind == .static and std.mem.indexOfScalar(u8, segment, '%') != null) blk: {
                    const buf = try self.arena.allocator().alloc(u8, segment.len);
                    const n = Request.unescapeSegment(buf, segment) catch
                        std.debug.panic("route {s} has a '%' that starts no escape", .{path});
                    break :blk buf[0..n];
                } else segment;

                // Find or create child
                var child = findChild(current, static_segment, kind);
                if (child) |existing| {
                    // One wildcard node captures under one name, and a route
                    // reading another would never find its value.
                    if (kind == .wildcard and !std.mem.eql(u8, existing.param_name.?, param_name.?)) {
                        @panic("wildcard registered under two names");
                    }
                }
                if (child == null) {
                    const new_node = try self.arena.allocator().create(Node);
                    new_node.* = Node{
                        .segment = try self.arena.allocator().dupe(u8, static_segment),
                        .kind = kind,
                        .param_name = if (param_name) |name| try self.arena.allocator().dupe(u8, name) else null,
                        .static_children = null,
                        .param_child = null,
                        .wildcard_child = null,
                        .next_sibling = null,
                        .route = null,
                    };

                    // Add to appropriate child field
                    switch (kind) {
                        .static => {
                            // Prepend to static_children linked list
                            new_node.next_sibling = current.static_children;
                            current.static_children = new_node;
                        },
                        .param => current.param_child = new_node,
                        .wildcard => current.wildcard_child = new_node,
                    }

                    child = new_node;
                }

                current = child.?;
            }

            // Create and store route
            const alloc = self.arena.allocator();
            const route = try alloc.create(Route);
            route.* = .{
                .info = .{ .path = try alloc.dupe(u8, path), .data = data },
                .action = handler,
                .middlewares = middlewares,
            };
            current.route = @ptrCast(route);
        }

        fn matchRecursive(node: *Node, req: *Request, index: usize) !?*Node {
            // Terminal case: consumed all segments
            if (index >= req._segments.len) {
                // Only return node if it has a route registered
                if (node.route == null) return null;
                return node;
            }

            const current_segment = req._segments[index];

            // Check children in precedence order: static > param > wildcard

            // 1. Try static children first (highest precedence)
            var static_child = node.static_children;
            while (static_child) |c| {
                if (std.mem.eql(u8, c.segment, current_segment)) {
                    const result = try matchRecursive(c, req, index + 1);
                    if (result != null) return result;
                }
                static_child = c.next_sibling;
            }

            // 2. Try param child (medium precedence)
            if (node.param_child) |c| {
                if (req.params.count() >= req.config.max_param_count) {
                    return error.TooManyParams;
                }
                try req.params.map.put(req.arena, c.param_name.?, current_segment);
                const result = try matchRecursive(c, req, index + 1);
                if (result != null) return result;
                _ = req.params.map.remove(c.param_name.?); // backtrack
            }

            // 3. Try wildcard child (lowest precedence)
            if (node.wildcard_child) |c| {
                if (req.params.count() >= req.config.max_param_count) {
                    return error.TooManyParams;
                }
                // Capture remaining path (without query parameters)
                const start = @intFromPtr(current_segment.ptr) - @intFromPtr(req.path.ptr);
                const remaining = req.path[start..];
                try req.params.map.put(req.arena, c.param_name.?, remaining);
                return c;
            }

            return null;
        }

        pub fn findHandler(self: *const Self, req: *Request) !?Route {
            req.route = null;
            req.query.map.clearRetainingCapacity();
            try parseQueryString(req, req.query_string);

            const route = try self.matchIn(req.method, req) orelse
                // A HEAD response is the GET response without the body, so a
                // HEAD with no route of its own is answered by the GET one.
                // Second, so a route registered with `head` still wins.
                (if (req.method == .head) try self.matchIn(.get, req) else null) orelse
                try self.matchIn(null, req);
            if (route) |r| {
                req.route = &r.info;
                return r.*;
            }
            return null;
        }

        fn matchIn(self: *const Self, method: ?Method, req: *Request) !?*const Route {
            const root = (if (method) |m| self.trees[@intFromEnum(m)] else self.any_tree) orelse return null;
            const node = try matchRecursive(root, req, 0) orelse return null;
            const opaque_route = node.route orelse return null;
            return @ptrCast(@alignCast(opaque_route));
        }

        pub fn get(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.insertRoute(path, .get, wrap(handler), self.middlewares, null) catch @panic("OOM");
        }

        pub fn head(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.insertRoute(path, .head, wrap(handler), self.middlewares, null) catch @panic("OOM");
        }

        pub fn post(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.insertRoute(path, .post, wrap(handler), self.middlewares, null) catch @panic("OOM");
        }

        pub fn put(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.insertRoute(path, .put, wrap(handler), self.middlewares, null) catch @panic("OOM");
        }

        pub fn delete(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.insertRoute(path, .delete, wrap(handler), self.middlewares, null) catch @panic("OOM");
        }

        pub fn patch(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.insertRoute(path, .patch, wrap(handler), self.middlewares, null) catch @panic("OOM");
        }

        pub fn options(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.insertRoute(path, .options, wrap(handler), self.middlewares, null) catch @panic("OOM");
        }

        pub fn query(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.insertRoute(path, .query, wrap(handler), self.middlewares, null) catch @panic("OOM");
        }

        /// Matches every method, for requests that no route of their own
        /// method matches (or, for HEAD, of GET). A route of one method
        /// conflicts with an `any` route when both match some path and its
        /// own path is not more specific, and registering the second of the
        /// two panics.
        pub fn any(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.insertRoute(path, null, wrap(handler), self.middlewares, null) catch @panic("OOM");
        }

        /// Serves the files under `dir` at `prefix`: `GET prefix/a/b.css` is
        /// `a/b.css` in `dir`, and a HEAD is answered the same way without
        /// the body. A path that leaves `dir` with `..` is a 404, and so is
        /// one naming nothing to serve. `dir` must stay open while the
        /// router is in use.
        pub fn static(self: *Self, prefix: []const u8, dir: std.Io.Dir, opts: StaticOptions) void {
            self.addStatic(prefix, dir, opts, self.middlewares);
        }

        fn addStatic(self: *Self, prefix: []const u8, dir: std.Io.Dir, opts: StaticOptions, middlewares: []const Middleware(Ctx)) void {
            const alloc = self.arena.allocator();
            const files = alloc.create(Static) catch @panic("OOM");
            files.* = .{ .dir = dir, .options = opts };
            if (opts.index) |index| files.options.index = alloc.dupe(u8, index) catch @panic("OOM");
            files.options.precompressed = alloc.dupe(Precompressed, opts.precompressed) catch @panic("OOM");
            const base = std.mem.trimEnd(u8, prefix, "/");
            // The directory itself, for its index.
            self.insertRoute(if (base.len == 0) "/" else base, .get, staticAction, middlewares, files) catch @panic("OOM");
            const files_path = std.fmt.allocPrint(alloc, "{s}/*" ++ Static.param, .{base}) catch @panic("OOM");
            self.insertRoute(files_path, .get, staticAction, middlewares, files) catch @panic("OOM");
        }

        /// Serves `data` at `path`, usually a file embedded with
        /// `@embedFile`, with the same conditional and `Range` handling as
        /// `static`. There is no `Last-Modified`; the `ETag` is a hash of
        /// the content. `data` must outlive the router.
        pub fn embedded(self: *Self, path: []const u8, data: []const u8, opts: EmbeddedOptions) void {
            self.addEmbedded(path, data, opts, self.middlewares);
        }

        fn addEmbedded(self: *Self, path: []const u8, data: []const u8, opts: EmbeddedOptions, middlewares: []const Middleware(Ctx)) void {
            const alloc = self.arena.allocator();
            const file = alloc.create(Embedded) catch @panic("OOM");
            file.* = Embedded.init(alloc, path, data, opts) catch @panic("OOM");
            self.insertRoute(path, .get, wrap(Embedded.handle), middlewares, file) catch @panic("OOM");
        }

        const staticAction = wrap(Static.handle);

        const CtxPtr = if (Ctx == void) void else *Ctx;

        fn wrap(comptime handler: anytype) Handler {
            const F = @TypeOf(handler);
            const returns_error = inject.returnsError(F, "handler " ++ @typeName(F), true);
            if (returns_error and std.meta.ArgsTuple(F) == std.meta.ArgsTuple(Handler)) return handler;
            const H = struct {
                fn call(ctx: CtxPtr, req: *Request, res: *Response) anyerror!void {
                    return @call(.auto, handler, inject.args(Ctx, F, ctx, req, res, {}));
                }

                fn callVoid(req: *Request, res: *Response) anyerror!void {
                    return call({}, req, res);
                }
            };
            return if (Ctx == void) H.callVoid else H.call;
        }

        /// Routes registered on the group get `prefix` in front of their
        /// path and run `middlewares` after the router's. A null or "/"
        /// prefix adds nothing, and trailing slashes are dropped.
        pub fn group(self: *Self, prefix: ?[]const u8, middlewares: []const Middleware(Ctx)) Group {
            return .{ .router = self, .prefix = trimPrefix(prefix), .middlewares = middlewares };
        }

        fn trimPrefix(prefix: ?[]const u8) []const u8 {
            return std.mem.trimEnd(u8, prefix orelse "", "/");
        }

        fn concatMiddlewares(self: *Self, a: []const Middleware(Ctx), b: []const Middleware(Ctx)) []const Middleware(Ctx) {
            if (a.len == 0) return b;
            if (b.len == 0) return a;
            const merged = self.arena.allocator().alloc(Middleware(Ctx), a.len + b.len) catch @panic("OOM");
            @memcpy(merged[0..a.len], a);
            @memcpy(merged[a.len..], b);
            return merged;
        }

        pub const Group = struct {
            router: *Self,
            prefix: []const u8,
            /// The group's own and its parents', not the router's, which
            /// are added at registration.
            middlewares: []const Middleware(Ctx),

            /// A group inside this one: the prefixes join, and its
            /// middlewares run after this group's.
            pub fn group(g: Group, prefix: ?[]const u8, middlewares: []const Middleware(Ctx)) Group {
                return .{
                    .router = g.router,
                    .prefix = g.concatPath(trimPrefix(prefix)),
                    .middlewares = g.router.concatMiddlewares(g.middlewares, middlewares),
                };
            }

            fn mergeMiddlewares(g: Group) []const Middleware(Ctx) {
                return g.router.concatMiddlewares(g.router.middlewares, g.middlewares);
            }

            fn concatPath(g: Group, path: []const u8) []const u8 {
                const sep = if (path.len > 0 and path[0] != '/') "/" else "";
                return std.fmt.allocPrint(g.router.arena.allocator(), "{s}{s}{s}", .{ g.prefix, sep, path }) catch @panic("OOM");
            }

            fn register(g: Group, method: ?Method, path: []const u8, handler: *const Handler) void {
                g.router.insertRoute(g.concatPath(path), method, handler, g.mergeMiddlewares(), null) catch @panic("OOM");
            }

            pub fn get(g: Group, path: []const u8, comptime handler: anytype) void {
                g.register(.get, path, wrap(handler));
            }

            pub fn head(g: Group, path: []const u8, comptime handler: anytype) void {
                g.register(.head, path, wrap(handler));
            }

            pub fn post(g: Group, path: []const u8, comptime handler: anytype) void {
                g.register(.post, path, wrap(handler));
            }

            pub fn put(g: Group, path: []const u8, comptime handler: anytype) void {
                g.register(.put, path, wrap(handler));
            }

            pub fn delete(g: Group, path: []const u8, comptime handler: anytype) void {
                g.register(.delete, path, wrap(handler));
            }

            pub fn patch(g: Group, path: []const u8, comptime handler: anytype) void {
                g.register(.patch, path, wrap(handler));
            }

            pub fn options(g: Group, path: []const u8, comptime handler: anytype) void {
                g.register(.options, path, wrap(handler));
            }

            pub fn query(g: Group, path: []const u8, comptime handler: anytype) void {
                g.register(.query, path, wrap(handler));
            }

            pub fn any(g: Group, path: []const u8, comptime handler: anytype) void {
                g.register(null, path, wrap(handler));
            }

            pub fn static(g: Group, prefix: []const u8, dir: std.Io.Dir, opts: StaticOptions) void {
                g.router.addStatic(g.concatPath(prefix), dir, opts, g.mergeMiddlewares());
            }

            pub fn embedded(g: Group, path: []const u8, data: []const u8, opts: EmbeddedOptions) void {
                g.router.addEmbedded(g.concatPath(path), data, opts, g.mergeMiddlewares());
            }
        };

        fn parseQueryString(req: *Request, query_string: []const u8) !void {
            if (query_string.len == 0) return;

            // Count '&' to estimate capacity (upper bound on number of key-value pairs)
            // Number of segments = ampersands + 1
            const ampersand_count = std.mem.count(u8, query_string, "&");
            const max_params = @min(ampersand_count + 1, req.config.max_query_count);

            // Pre-allocate capacity for the query hashmap
            try req.query.map.ensureTotalCapacity(req.arena, @intCast(max_params));

            var it = std.mem.splitScalar(u8, query_string, '&');
            while (it.next()) |pair| {
                if (pair.len == 0) continue;

                // Check query count limit
                if (req.query.count() >= req.config.max_query_count) {
                    return error.TooManyQueryParams;
                }

                if (std.mem.indexOfScalar(u8, pair, '=')) |sep| {
                    const key = try Request.urlUnescape(req.arena, pair[0..sep]);
                    const value = try Request.urlUnescape(req.arena, pair[sep + 1 ..]);
                    req.query.map.putAssumeCapacity(key, value);
                } else {
                    const key = try Request.urlUnescape(req.arena, pair);
                    req.query.map.putAssumeCapacity(key, "");
                }
            }
        }
    };
}

/// Whether some request path matches both, and `method_path` matches some
/// path `any_path` doesn't. Segments are literals, `:param` matching one
/// segment, and `*wildcard` matching one or more.
fn conflicts(method_path: []const u8, any_path: []const u8) bool {
    var it1 = std.mem.tokenizeScalar(u8, method_path, '/');
    var it2 = std.mem.tokenizeScalar(u8, any_path, '/');
    var more_general = false;
    while (true) {
        const s1 = it1.next() orelse return more_general and it2.next() == null;
        const s2 = it2.next() orelse return false;
        if (s1[0] == '*') return s2[0] != '*' or more_general;
        if (s2[0] == '*') return more_general;
        if (s1[0] == ':') {
            if (s2[0] != ':') more_general = true;
        } else if (s2[0] != ':' and !staticEql(s1, s2)) {
            return false;
        }
    }
}

/// Whether two static segments of route paths match the same request
/// segment, once decoded.
fn staticEql(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (decodedByte(a, &i) != decodedByte(b, &j)) return false;
    }
    return i == a.len and j == b.len;
}

fn decodedByte(s: []const u8, i: *usize) u8 {
    var out: [1]u8 = undefined;
    if (s[i.*] == '%') {
        if (Request.unescapeSegment(&out, s[i.*..@min(i.* + 3, s.len)])) |_| {
            i.* += 3;
            return out[0];
        } else |_| {}
    }
    i.* += 1;
    return s[i.* - 1];
}

// Tests
const TestRouter = Router(TestContext);

const TestContext = struct {
    called: bool = false,
};

fn testHandler(ctx: *TestContext, req: *Request, res: *Response) !void {
    _ = req;
    _ = res;
    ctx.called = true;
}

fn testHandler2(ctx: *TestContext, req: *Request, res: *Response) !void {
    _ = req;
    _ = res;
    _ = ctx;
}

fn split(req: *Request) !*Request {
    try req.splitTarget();
    return req;
}

test "Router: register and find GET route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler);
}

test "Router: register and find POST route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.post("/posts", testHandler);

    var req = Request{
        .method = .post,
        .url = "/posts",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler);
}

test "Router: method mismatch returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users", testHandler);

    var req = Request{
        .method = .post,
        .url = "/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler == null);
}

test "Router: path mismatch returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users", testHandler);

    var req = Request{
        .method = .get,
        .url = "/posts",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler == null);
}

test "Router: parameterized routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/123",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler);
}

test "Router: multiple routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users", testHandler);
    router.post("/users", testHandler2);
    router.get("/posts", testHandler2);

    // Find first route
    var req1 = Request{
        .method = .get,
        .url = "/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    const handler1 = try router.findHandler(try split(&req1));
    try std.testing.expect(handler1 != null);
    try std.testing.expect(handler1.?.action == testHandler);

    // Find second route
    var req2 = Request{
        .method = .post,
        .url = "/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    const handler2 = try router.findHandler(try split(&req2));
    try std.testing.expect(handler2 != null);
    try std.testing.expect(handler2.?.action == testHandler2);

    // Find third route
    var req3 = Request{
        .method = .get,
        .url = "/posts",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    const handler3 = try router.findHandler(try split(&req3));
    try std.testing.expect(handler3 != null);
    try std.testing.expect(handler3.?.action == testHandler2);
}

test "Router: all HTTP methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.any("/resource", testHandler);

    for ([_]Method{ .get, .head, .post, .query, .trace, .propfind }) |method| {
        var req = Request{
            .method = method,
            .url = "/resource",
            .arena = arena.allocator(),
            .parser = undefined,
            .transport = undefined,
        };
        const handler = try router.findHandler(try split(&req));
        try std.testing.expect(handler != null);
    }
}

test "Router: extract single parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/123",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("123", id.?);
}

test "Router: the matched route is on the request, by its pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    const api = router.group("/api", &.{});
    api.get("/users/:id", testHandler);

    var req = Request{
        .method = .get,
        .url = "/api/users/123",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    _ = try router.findHandler(try split(&req));
    try std.testing.expectEqualStrings("/api/users/:id", req.route.?.path);

    req.url = "/nowhere";
    _ = try router.findHandler(try split(&req));
    try std.testing.expectEqual(null, req.route);
}

test "Router: extract multiple parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:userId/posts/:postId", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/456/posts/789",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    const userId = req.params.get("userId");
    try std.testing.expect(userId != null);
    try std.testing.expectEqualStrings("456", userId.?);

    const postId = req.params.get("postId");
    try std.testing.expect(postId != null);
    try std.testing.expectEqualStrings("789", postId.?);
}

test "Router: mixed static and parameter segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/api/v1/users/:id/profile", testHandler);

    var req = Request{
        .method = .get,
        .url = "/api/v1/users/abc123/profile",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("abc123", id.?);
}

test "Router: static route has precedence over param route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    // Register static route first, then param route (reversed order)
    router.get("/users/new", testHandler2);
    router.get("/users/:id", testHandler);

    // Should match static route, not param route
    var req = Request{
        .method = .get,
        .url = "/users/new",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler2);

    // Params should be empty (no :id captured)
    try std.testing.expect(req.params.get("id") == null);
}

test "Router: wildcard route basic matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/files/*path", testHandler);

    var req = Request{
        .method = .get,
        .url = "/files/document.txt",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler);
}

test "Router: wildcard captures remaining path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/files/*path", testHandler);

    var req = Request{
        .method = .get,
        .url = "/files/path/to/file.txt",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    const path = req.params.get("path");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("path/to/file.txt", path.?);
}

test "Router: static route has precedence over wildcard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/files/*path", testHandler);
    router.get("/files/config.json", testHandler2);

    var req = Request{
        .method = .get,
        .url = "/files/config.json",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler2);

    // Wildcard param should not be captured
    try std.testing.expect(req.params.get("path") == null);
}

test "Router: param route has precedence over wildcard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/api/*catchall", testHandler);
    router.get("/api/:id", testHandler2);

    var req = Request{
        .method = .get,
        .url = "/api/123",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler2);

    // Should capture :id param, not wildcard
    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("123", id.?);
    try std.testing.expect(req.params.get("catchall") == null);
}

test "Router: wildcard with multiple segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/assets/*filepath", testHandler);

    var req = Request{
        .method = .get,
        .url = "/assets/images/icons/logo.png",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    const filepath = req.params.get("filepath");
    try std.testing.expect(filepath != null);
    try std.testing.expectEqualStrings("images/icons/logo.png", filepath.?);
}

test "Router: wildcard with prefix path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/api/v1/files/*path", testHandler);

    var req = Request{
        .method = .get,
        .url = "/api/v1/files/docs/readme.md",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    const path = req.params.get("path");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("docs/readme.md", path.?);
}

test "Router: static route with query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/profile", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/profile?debug=true&page=1",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler);

    // Query parameters should be parsed
    try std.testing.expectEqualStrings("true", req.query.get("debug").?);
    try std.testing.expectEqualStrings("1", req.query.get("page").?);
}

test "Router: param route with query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/123?format=json",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler);

    // Parameter should not include query string
    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("123", id.?);

    // Query parameters should be parsed
    try std.testing.expectEqualStrings("json", req.query.get("format").?);
}

test "Router: multiple params with query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:userId/posts/:postId", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/456/posts/789?include=comments&sort=date",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    // Parameters should not include query string
    const userId = req.params.get("userId");
    try std.testing.expect(userId != null);
    try std.testing.expectEqualStrings("456", userId.?);

    const postId = req.params.get("postId");
    try std.testing.expect(postId != null);
    try std.testing.expectEqualStrings("789", postId.?);

    // Query parameters should be parsed
    try std.testing.expectEqualStrings("comments", req.query.get("include").?);
    try std.testing.expectEqualStrings("date", req.query.get("sort").?);
}

test "Router: wildcard route with query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/files/*path", testHandler);

    var req = Request{
        .method = .get,
        .url = "/files/docs/readme.md?download=true",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    // Wildcard should not include query string
    const path = req.params.get("path");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("docs/readme.md", path.?);

    // Query parameters should be parsed
    try std.testing.expectEqualStrings("true", req.query.get("download").?);
}

test "Router: empty query string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/123?",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("123", id.?);

    // Empty query parameters
    try std.testing.expectEqual(0, req.query.count());
}

test "Router: no query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/123",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("123", id.?);

    // No query parameters
    try std.testing.expectEqual(0, req.query.count());
}

test "Router: URL encoded query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/search", testHandler);

    var req = Request{
        .method = .get,
        .url = "/search?q=hello+world&tag=foo%20bar&special=%21%40%23%24",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    // URL decoding: + -> space, %20 -> space, %XX -> byte
    try std.testing.expectEqualStrings("hello world", req.query.get("q").?);
    try std.testing.expectEqualStrings("foo bar", req.query.get("tag").?);
    try std.testing.expectEqualStrings("!@#$", req.query.get("special").?);
}

test "Router: query parameter without value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/items", testHandler);

    var req = Request{
        .method = .get,
        .url = "/items?featured&sort=name",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    // Parameters without values should have empty string value
    try std.testing.expectEqualStrings("", req.query.get("featured").?);
    try std.testing.expectEqualStrings("name", req.query.get("sort").?);
}

test "Router: query with empty key-value pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/test", testHandler);

    var req = Request{
        .method = .get,
        .url = "/test?a=1&&b=2&",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };

    const handler = try router.findHandler(try split(&req));
    try std.testing.expect(handler != null);

    // Should handle double && and trailing &
    try std.testing.expectEqualStrings("1", req.query.get("a").?);
    try std.testing.expectEqualStrings("2", req.query.get("b").?);
    try std.testing.expectEqual(2, req.query.count());
}

// Group tests

const TestVoidRouter = Router(void);

fn voidHandler1(req: *Request, res: *Response) !void {
    _ = req;
    _ = res;
}

fn voidHandler2(req: *Request, res: *Response) !void {
    _ = req;
    _ = res;
}

test "Group: prefix concatenation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    const api = router.group("/api/v1", &.{});
    api.get("/users", testHandler);
    api.post("/users", testHandler2);

    var req1 = Request{
        .method = .get,
        .url = "/api/v1/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    const route1 = try router.findHandler(try split(&req1));
    try std.testing.expect(route1 != null);
    try std.testing.expect(route1.?.action == testHandler);

    var req2 = Request{
        .method = .post,
        .url = "/api/v1/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    const route2 = try router.findHandler(try split(&req2));
    try std.testing.expect(route2 != null);
    try std.testing.expect(route2.?.action == testHandler2);
}

test "Group: routes without group middleware get global middlewares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestVoidRouter.init(std.testing.allocator);
    defer router.deinit();

    const TestMw = struct {
        id: u8,
        pub fn execute(_: *const @This(), _: *Request, _: *Response, _: *@import("middleware.zig").Executor(void)) !void {}
    };

    var mw1 = TestMw{ .id = 1 };
    var mw2 = TestMw{ .id = 2 };
    router.middlewares = &.{ Middleware(void).init(&mw1), Middleware(void).init(&mw2) };

    router.get("/direct", voidHandler1);

    var req = Request{
        .method = .get,
        .url = "/direct",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    const route = try router.findHandler(try split(&req));
    try std.testing.expect(route != null);
    try std.testing.expectEqual(2, route.?.middlewares.len);
}

test "Group: group middlewares appended after global" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestVoidRouter.init(std.testing.allocator);
    defer router.deinit();

    const TestMw = struct {
        id: u8,
        pub fn execute(_: *const @This(), _: *Request, _: *Response, _: *@import("middleware.zig").Executor(void)) !void {}
    };

    var mw_global = TestMw{ .id = 1 };
    var mw_group = TestMw{ .id = 2 };
    router.middlewares = &.{Middleware(void).init(&mw_global)};

    const api = router.group("/api", &.{Middleware(void).init(&mw_group)});
    api.get("/users", voidHandler1);

    var req = Request{
        .method = .get,
        .url = "/api/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    const route = try router.findHandler(try split(&req));
    try std.testing.expect(route != null);
    // Should have global + group middlewares
    try std.testing.expectEqual(2, route.?.middlewares.len);
    // Global middleware should come first
    try std.testing.expect(route.?.middlewares[0].ptr == @as(*anyopaque, @ptrCast(@constCast(&mw_global))));
    try std.testing.expect(route.?.middlewares[1].ptr == @as(*anyopaque, @ptrCast(@constCast(&mw_group))));
}

test "Group: no global middlewares, only group middlewares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestVoidRouter.init(std.testing.allocator);
    defer router.deinit();

    const TestMw = struct {
        id: u8,
        pub fn execute(_: *const @This(), _: *Request, _: *Response, _: *@import("middleware.zig").Executor(void)) !void {}
    };

    var mw_group = TestMw{ .id = 1 };
    const api = router.group("/api", &.{Middleware(void).init(&mw_group)});
    api.get("/users", voidHandler1);

    var req = Request{
        .method = .get,
        .url = "/api/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    const route = try router.findHandler(try split(&req));
    try std.testing.expect(route != null);
    try std.testing.expectEqual(1, route.?.middlewares.len);
}

test "Group: prefix and path are joined by exactly one slash" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var router: TestVoidRouter = .init(std.testing.allocator);
    defer router.deinit();

    router.group(null, &.{}).get("/a", voidHandler1);
    router.group("/", &.{}).get("/b", voidHandler1);
    router.group("/api/", &.{}).get("/c", voidHandler1);
    router.group("/api/", &.{}).get("d", voidHandler1);
    router.group("/x", &.{}).group("y", &.{}).get("z", voidHandler1);

    for ([_][]const u8{ "/a", "/b", "/api/c", "/api/d", "/x/y/z" }) |url| {
        var req: Request = .{
            .method = .get,
            .url = url,
            .arena = arena.allocator(),
            .parser = undefined,
            .transport = undefined,
        };
        const route = (try router.findHandler(try split(&req))).?;
        try std.testing.expectEqualStrings(url, route.info.path);
    }
}

test "Group: nested groups join prefixes and run middlewares outermost first" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var router: TestVoidRouter = .init(std.testing.allocator);
    defer router.deinit();

    const TestMw = struct {
        id: u8,
        pub fn execute(_: *const @This(), _: *Request, _: *Response, _: *@import("middleware.zig").Executor(void)) !void {}
    };

    var mw_global: TestMw = .{ .id = 1 };
    var mw_outer: TestMw = .{ .id = 2 };
    var mw_inner: TestMw = .{ .id = 3 };

    const api = router.group("/api", &.{.init(&mw_outer)});
    const v1 = api.group("/v1", &.{.init(&mw_inner)});
    // Router middlewares set after the groups were made still apply.
    router.middlewares = &.{.init(&mw_global)};
    v1.get("/users", voidHandler1);

    var req: Request = .{
        .method = .get,
        .url = "/api/v1/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    const route = (try router.findHandler(try split(&req))).?;
    try std.testing.expectEqual(3, route.middlewares.len);
    for (route.middlewares, [_]*TestMw{ &mw_global, &mw_outer, &mw_inner }) |mw, want| {
        try std.testing.expect(mw.ptr == @as(*anyopaque, want));
    }
}

test "Group: direct routes have no middlewares when none set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestVoidRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/health", voidHandler1);

    var req = Request{
        .method = .get,
        .url = "/health",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    const route = try router.findHandler(try split(&req));
    try std.testing.expect(route != null);
    try std.testing.expectEqual(0, route.?.middlewares.len);
}

test "Group: any method registers all methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    const api = router.group("/api", &.{});
    api.any("/resource", testHandler);

    for ([_]Method{ .get, .head, .post, .query, .trace, .propfind }) |method| {
        var req = Request{
            .method = method,
            .url = "/api/resource",
            .arena = arena.allocator(),
            .parser = undefined,
            .transport = undefined,
        };
        const route = try router.findHandler(try split(&req));
        try std.testing.expect(route != null);
    }
}

test "Router: QUERY route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.query("/search", testHandler);
    router.group("/api", &.{}).query("/search", testHandler2);

    var req = Request{
        .method = .query,
        .url = "/search",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    try std.testing.expectEqual(&testHandler, (try router.findHandler(try split(&req))).?.action);
    req.url = "/api/search";
    try std.testing.expectEqual(&testHandler2, (try router.findHandler(try split(&req))).?.action);

    req.method = .get;
    try std.testing.expect(try router.findHandler(try split(&req)) == null);
}

test "Router: any() comes after the method's own routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/x", testHandler);
    router.any("/x", testHandler2);
    router.any("/users/:id", testHandler2);
    router.get("/users/me", testHandler);

    const cases = [_]struct { Method, []const u8, *const TestRouter.Handler }{
        .{ .get, "/x", testHandler },
        .{ .head, "/x", testHandler },
        .{ .post, "/x", testHandler2 },
        .{ .get, "/users/me", testHandler },
        .{ .get, "/users/1", testHandler2 },
        .{ .post, "/users/me", testHandler2 },
    };
    for (cases) |case| {
        var req = Request{
            .method = case[0],
            .url = case[1],
            .arena = arena.allocator(),
            .parser = undefined,
            .transport = undefined,
        };
        try std.testing.expectEqual(case[2], (try router.findHandler(try split(&req))).?.action);
    }
}

test "Router: a method route conflicts with a more specific any() route" {
    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();
    router.get("/users/:id", testHandler);
    router.get("/a/:x", testHandler);
    router.any("/b/:y", testHandler2);
    const c1 = router.findConflict("/users/me", null).?;
    try std.testing.expectEqualStrings("/users/:id", c1.method_path);

    var router2 = TestRouter.init(std.testing.allocator);
    defer router2.deinit();
    router2.any("/users/me", testHandler2);
    const c2 = router2.findConflict("/users/:id", .get).?;
    try std.testing.expectEqualStrings("/users/me", c2.any_path);

    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "/x", "/x", false },
        .{ "/users/me", "/users/:id", false },
        .{ "/users/:id", "/users/me", true },
        .{ "/a/:x", "/b/:y", false },
        .{ "/:x/b", "/a/:y", true },
        .{ "/files/*p", "/files/a", true },
        .{ "/files/a/b", "/files/*p", false },
        .{ "/files/*p", "/files/*q", false },
        .{ "/files", "/files/*p", false },
        .{ "/*", "/a/*p", true },
        .{ "/a/*p", "/*", false },
        .{ "/:x/c%20d", "/y/c d", true },
        .{ "/:x/c%2fd", "/y/c/d", false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case[2], conflicts(case[0], case[1]));
    }
}

test "Router: a GET route answers HEAD" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users", testHandler);

    var req = Request{
        .method = .head,
        .url = "/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    try std.testing.expectEqual(&testHandler, (try router.findHandler(try split(&req))).?.action);

    // The fallback is HEAD's alone; nothing else borrows from GET.
    req.method = .post;
    try std.testing.expect(try router.findHandler(try split(&req)) == null);
    req.url = "/nothing";
    req.method = .head;
    try std.testing.expect(try router.findHandler(try split(&req)) == null);
}

test "Router: an explicit HEAD route wins over the GET one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users", testHandler);
    router.head("/users", testHandler2);

    var req = Request{
        .method = .head,
        .url = "/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    try std.testing.expectEqual(&testHandler2, (try router.findHandler(try split(&req))).?.action);

    req.method = .get;
    try std.testing.expectEqual(&testHandler, (try router.findHandler(try split(&req))).?.action);
}

test "Router: HEAD falls back per path, not per tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    // A HEAD tree exists because of /other, but /users is not in it.
    router.head("/other", testHandler2);
    router.get("/users", testHandler);

    var req = Request{
        .method = .head,
        .url = "/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    try std.testing.expectEqual(&testHandler, (try router.findHandler(try split(&req))).?.action);
}

test "Router: HEAD falling back to GET still captures path params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);

    var req = Request{
        .method = .head,
        .url = "/users/42",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    try std.testing.expect(try router.findHandler(try split(&req)) != null);
    try std.testing.expectEqualStrings("42", req.params.get("id").?);
}

test "Router: a route's path is decoded segment by segment, like a request's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/a%2fb", testHandler);
    router.get("/c%20d", testHandler2);

    var req = Request{
        .method = .get,
        .url = "/a%2Fb",
        .arena = arena.allocator(),
        .parser = undefined,
        .transport = undefined,
    };
    try std.testing.expectEqual(&testHandler, (try router.findHandler(try split(&req))).?.action);
    req.url = "/a/b";
    try std.testing.expect(try router.findHandler(try split(&req)) == null);
    req.url = "/c d";
    try std.testing.expectEqual(&testHandler2, (try router.findHandler(try split(&req))).?.action);
}
