const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Method = @import("http.zig").Method;

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

    // Handler (opaque pointer) - only set on terminal nodes
    handler: ?*const anyopaque,
};

pub fn Router(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        pub const Handler = fn (*Ctx, *Request, *Response) anyerror!void;

        arena: std.heap.ArenaAllocator,
        // Each HTTP method has its own radix tree
        trees: [256]?*Node,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .trees = [_]?*Node{null} ** 256,
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

        fn insert(self: *Self, path: []const u8, method: Method, handler: *const Handler) !void {
            const method_idx = @intFromEnum(method);
            std.debug.assert(method_idx < 256);

            // Get or create root for this method
            if (self.trees[method_idx] == null) {
                const root = try self.arena.allocator().create(Node);
                root.* = Node{
                    .segment = "",
                    .kind = .static,
                    .param_name = null,
                    .static_children = null,
                    .param_child = null,
                    .wildcard_child = null,
                    .next_sibling = null,
                    .handler = null,
                };
                self.trees[method_idx] = root;
            }

            var current = self.trees[method_idx].?;

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

                // Find or create child
                var child = findChild(current, segment, kind);
                if (child == null) {
                    const new_node = try self.arena.allocator().create(Node);
                    new_node.* = Node{
                        .segment = try self.arena.allocator().dupe(u8, segment),
                        .kind = kind,
                        .param_name = if (param_name) |name| try self.arena.allocator().dupe(u8, name) else null,
                        .static_children = null,
                        .param_child = null,
                        .wildcard_child = null,
                        .next_sibling = null,
                        .handler = null,
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

            // Store handler as opaque pointer
            current.handler = @ptrCast(handler);
        }

        fn matchRecursive(node: *Node, req: *Request, segments: []const []const u8, segment_offsets: []const usize, index: usize) !?*Node {
            // Terminal case: consumed all segments
            if (index >= segments.len) {
                // Only return node if it has a handler registered
                if (node.handler == null) return null;
                return node;
            }

            const current_segment = segments[index];

            // Check children in precedence order: static > param > wildcard

            // 1. Try static children first (highest precedence)
            var static_child = node.static_children;
            while (static_child) |c| {
                if (std.mem.eql(u8, c.segment, current_segment)) {
                    const result = try matchRecursive(c, req, segments, segment_offsets, index + 1);
                    if (result != null) return result;
                }
                static_child = c.next_sibling;
            }

            // 2. Try param child (medium precedence)
            if (node.param_child) |c| {
                try req.params.put(req.arena, c.param_name.?, current_segment);
                const result = try matchRecursive(c, req, segments, segment_offsets, index + 1);
                if (result != null) return result;
                _ = req.params.remove(c.param_name.?); // backtrack
            }

            // 3. Try wildcard child (lowest precedence)
            if (node.wildcard_child) |c| {
                // Capture remaining path from original URL
                const remaining = req.url[segment_offsets[index]..];
                try req.params.put(req.arena, c.param_name.?, remaining);
                return c;
            }

            return null;
        }

        pub fn findHandler(self: *const Self, req: *Request) !?*const Handler {
            // Get the tree for this method
            const method_idx = @intFromEnum(req.method);
            std.debug.assert(method_idx < 256);
            const root = self.trees[method_idx] orelse return null;

            // Count segments (max possible is number of '/' + 1)
            const max_segments = std.mem.count(u8, req.url, "/") + 1;

            // Pre-allocate exact capacity needed
            var segments = try std.ArrayList([]const u8).initCapacity(req.arena, max_segments);
            defer segments.deinit(req.arena);

            var offsets = try std.ArrayList(usize).initCapacity(req.arena, max_segments);
            defer offsets.deinit(req.arena);

            // Split path into segments and track their offsets
            var offset: usize = 0;
            var iter = std.mem.splitScalar(u8, req.url, '/');
            while (iter.next()) |segment| {
                if (segment.len > 0) {
                    segments.appendAssumeCapacity(segment);
                    offsets.appendAssumeCapacity(offset);
                }
                offset += segment.len + 1; // +1 for the '/'
            }

            const node = try matchRecursive(root, req, segments.items, offsets.items, 0);
            if (node) |n| {
                if (n.handler) |opaque_handler| {
                    return @ptrCast(@alignCast(opaque_handler));
                }
            }
            return null;
        }

        pub fn get(self: *Self, path: []const u8, handler: Handler) void {
            self.insert(path, .get, handler) catch @panic("OOM");
        }

        pub fn head(self: *Self, path: []const u8, handler: Handler) void {
            self.insert(path, .head, handler) catch @panic("OOM");
        }

        pub fn post(self: *Self, path: []const u8, handler: Handler) void {
            self.insert(path, .post, handler) catch @panic("OOM");
        }

        pub fn put(self: *Self, path: []const u8, handler: Handler) void {
            self.insert(path, .put, handler) catch @panic("OOM");
        }

        pub fn delete(self: *Self, path: []const u8, handler: Handler) void {
            self.insert(path, .delete, handler) catch @panic("OOM");
        }
    };
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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.? == testHandler);
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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.? == testHandler);
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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.? == testHandler);
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
        .conn = undefined,
    };
    const handler1 = try router.findHandler(&req1);
    try std.testing.expect(handler1 != null);
    try std.testing.expect(handler1.? == testHandler);

    // Find second route
    var req2 = Request{
        .method = .post,
        .url = "/users",
        .arena = arena.allocator(),
        .parser = undefined,
        .conn = undefined,
    };
    const handler2 = try router.findHandler(&req2);
    try std.testing.expect(handler2 != null);
    try std.testing.expect(handler2.? == testHandler2);

    // Find third route
    var req3 = Request{
        .method = .get,
        .url = "/posts",
        .arena = arena.allocator(),
        .parser = undefined,
        .conn = undefined,
    };
    const handler3 = try router.findHandler(&req3);
    try std.testing.expect(handler3 != null);
    try std.testing.expect(handler3.? == testHandler2);
}

test "Router: all HTTP methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/resource", testHandler);
    router.post("/resource", testHandler);
    router.put("/resource", testHandler);
    router.delete("/resource", testHandler);
    router.head("/resource", testHandler);

    const methods = [_]Method{ .get, .post, .put, .delete, .head };
    for (methods) |method| {
        var req = Request{
            .method = method,
            .url = "/resource",
            .arena = arena.allocator(),
            .parser = undefined,
            .conn = undefined,
        };
        const handler = try router.findHandler(&req);
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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("123", id.?);
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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.? == testHandler2);

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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.? == testHandler);
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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.? == testHandler2);

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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.? == testHandler2);

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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
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
        .conn = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    const path = req.params.get("path");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("docs/readme.md", path.?);
}
