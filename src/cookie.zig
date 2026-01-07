// Cookie parsing and serialization.
// Based on http.zig by Karl Seguin, MIT License.
// Copyright (c) 2024 Karl Seguin.

const std = @import("std");

/// Cookie parser for reading cookies from a request.
/// Lazily parses the Cookie header on demand.
pub const Cookie = struct {
    header: []const u8,

    pub fn get(self: Cookie, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.header, ';');
        while (it.next()) |kv| {
            const trimmed = std.mem.trimLeft(u8, kv, " ");
            if (name.len >= trimmed.len) {
                // need at least an '=' beyond the name
                continue;
            }

            if (!std.mem.startsWith(u8, trimmed, name)) {
                continue;
            }
            if (trimmed[name.len] != '=') {
                continue;
            }
            return trimmed[name.len + 1 ..];
        }
        return null;
    }
};

/// Options for setting a cookie in a response.
pub const CookieOpts = struct {
    path: []const u8 = "",
    domain: []const u8 = "",
    max_age: ?i32 = null,
    secure: bool = false,
    http_only: bool = false,
    partitioned: bool = false,
    same_site: ?SameSite = null,

    pub const SameSite = enum {
        lax,
        strict,
        none,
    };
};

/// Serialize a cookie name/value pair with options into a Set-Cookie header value.
pub fn serializeCookie(arena: std.mem.Allocator, name: []const u8, value: []const u8, opts: CookieOpts) ![]u8 {
    // Estimate length: name=value + attributes (110 is typical for cookie attributes per Go's implementation)
    const estimated_len = name.len + value.len + opts.path.len + opts.domain.len + 110;
    var buf = std.ArrayListUnmanaged(u8){};

    try buf.ensureTotalCapacity(arena, estimated_len);
    buf.appendSliceAssumeCapacity(name);
    buf.appendAssumeCapacity('=');

    // Quote values containing spaces or commas
    if (std.mem.indexOfAny(u8, value, ", ") != null) {
        buf.appendAssumeCapacity('"');
        buf.appendSliceAssumeCapacity(value);
        buf.appendAssumeCapacity('"');
    } else {
        buf.appendSliceAssumeCapacity(value);
    }

    if (opts.path.len != 0) {
        buf.appendSliceAssumeCapacity("; Path=");
        buf.appendSliceAssumeCapacity(opts.path);
    }

    if (opts.domain.len != 0) {
        buf.appendSliceAssumeCapacity("; Domain=");
        buf.appendSliceAssumeCapacity(opts.domain);
    }

    if (opts.max_age) |ma| {
        try buf.appendSlice(arena, "; Max-Age=");
        var int_buf: [20]u8 = undefined;
        const int_str = try std.fmt.bufPrint(&int_buf, "{d}", .{ma});
        try buf.appendSlice(arena, int_str);
    }

    if (opts.http_only) {
        try buf.appendSlice(arena, "; HttpOnly");
    }
    if (opts.secure) {
        try buf.appendSlice(arena, "; Secure");
    }
    if (opts.partitioned) {
        try buf.appendSlice(arena, "; Partitioned");
    }

    if (opts.same_site) |ss| switch (ss) {
        .lax => try buf.appendSlice(arena, "; SameSite=Lax"),
        .strict => try buf.appendSlice(arena, "; SameSite=Strict"),
        .none => try buf.appendSlice(arena, "; SameSite=None"),
    };

    return buf.items;
}

// Tests

test "Cookie.get: no cookies" {
    const cookies = Cookie{ .header = "" };
    try std.testing.expectEqual(null, cookies.get(""));
    try std.testing.expectEqual(null, cookies.get("auth"));
}

test "Cookie.get: empty cookie header" {
    const cookies = Cookie{ .header = "" };
    try std.testing.expectEqual(null, cookies.get(""));
    try std.testing.expectEqual(null, cookies.get("auth"));
}

test "Cookie.get: single cookie" {
    const cookies = Cookie{ .header = "auth=hello" };
    try std.testing.expectEqual(null, cookies.get(""));
    try std.testing.expectEqualStrings("hello", cookies.get("auth").?);
    try std.testing.expectEqual(null, cookies.get("world"));
}

test "Cookie.get: multiple cookies with space after semicolon" {
    const cookies = Cookie{ .header = "Name=leto; power=9000" };
    try std.testing.expectEqual(null, cookies.get(""));
    try std.testing.expectEqual(null, cookies.get("name")); // case-sensitive
    try std.testing.expectEqualStrings("leto", cookies.get("Name").?);
    try std.testing.expectEqualStrings("9000", cookies.get("power").?);
}

test "Cookie.get: multiple cookies without space after semicolon" {
    const cookies = Cookie{ .header = "Name=Ghanima;id=Name" };
    try std.testing.expectEqual(null, cookies.get(""));
    try std.testing.expectEqual(null, cookies.get("name")); // case-sensitive
    try std.testing.expectEqualStrings("Ghanima", cookies.get("Name").?);
    try std.testing.expectEqualStrings("Name", cookies.get("id").?);
}

test "serializeCookie: basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try serializeCookie(arena.allocator(), "c-n", "c-v", .{});
    try std.testing.expectEqualStrings("c-n=c-v", result);
}

test "serializeCookie: value with comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try serializeCookie(arena.allocator(), "c-n2", "c,v", .{});
    try std.testing.expectEqualStrings("c-n2=\"c,v\"", result);
}

test "serializeCookie: value with space" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try serializeCookie(arena.allocator(), "name", "hello world", .{});
    try std.testing.expectEqualStrings("name=\"hello world\"", result);
}

test "serializeCookie: all options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try serializeCookie(arena.allocator(), "cookie_name", "cookie value", .{
        .path = "/auth/",
        .domain = "www.example.com",
        .max_age = 9001,
        .secure = true,
        .http_only = true,
        .partitioned = true,
        .same_site = .lax,
    });
    try std.testing.expectEqualStrings(
        "cookie_name=\"cookie value\"; Path=/auth/; Domain=www.example.com; Max-Age=9001; HttpOnly; Secure; Partitioned; SameSite=Lax",
        result,
    );
}

test "serializeCookie: same_site strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try serializeCookie(arena.allocator(), "sess", "abc", .{ .same_site = .strict });
    try std.testing.expectEqualStrings("sess=abc; SameSite=Strict", result);
}

test "serializeCookie: same_site none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try serializeCookie(arena.allocator(), "sess", "abc", .{ .same_site = .none });
    try std.testing.expectEqualStrings("sess=abc; SameSite=None", result);
}

test "serializeCookie: negative max_age" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try serializeCookie(arena.allocator(), "sess", "abc", .{ .max_age = -1 });
    try std.testing.expectEqualStrings("sess=abc; Max-Age=-1", result);
}
