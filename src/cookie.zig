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
            const trimmed = std.mem.trimStart(u8, kv, &.{' '});
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

    pub fn iterator(self: Cookie) Iterator {
        return .{ .rest = self.header };
    }

    /// Yields the same `Entry` shape as `Headers.Iterator`, so a loop over
    /// either reads the same.
    pub const Iterator = struct {
        rest: []const u8,

        pub const Entry = struct {
            name: []const u8,
            value: []const u8,
        };

        pub fn next(self: *Iterator) ?Entry {
            while (self.rest.len > 0) {
                const pair = if (std.mem.indexOfScalar(u8, self.rest, ';')) |end| blk: {
                    defer self.rest = self.rest[end + 1 ..];
                    break :blk self.rest[0..end];
                } else blk: {
                    defer self.rest = "";
                    break :blk self.rest;
                };

                const trimmed = std.mem.trim(u8, pair, " ");
                // A pair with no `=` is not a cookie; skipping it is what
                // `get` does by never matching it.
                const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
                if (eq == 0) continue; // no name
                return .{ .name = trimmed[0..eq], .value = trimmed[eq + 1 ..] };
            }
            return null;
        }
    };

    /// Serializes as a JSON object of name to value.
    pub fn jsonStringify(self: Cookie, jw: anytype) !void {
        try jw.beginObject();
        var it = self.iterator();
        while (it.next()) |entry| {
            try jw.objectField(entry.name);
            try jw.write(entry.value);
        }
        try jw.endObject();
    }
};

/// Options for setting a cookie in a response.
pub const CookieOpts = struct {
    path: []const u8 = "",
    domain: []const u8 = "",
    max_age: ?std.Io.Duration = null,
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

/// RFC 6265 cookie-name, which is a token: no separators and no controls.
/// `serializeCookie` writes the name verbatim, so a name carrying a `;`
/// would smuggle in attributes of its own.
pub fn validateCookieName(name: []const u8) error{InvalidCookieName}!void {
    if (name.len == 0) return error.InvalidCookieName;
    for (name) |c| {
        if (c <= 0x20 or c >= 0x7f) return error.InvalidCookieName;
        if (std.mem.indexOfScalar(u8, "()<>@,;:\\\"/[]?={}", c) != null) return error.InvalidCookieName;
    }
}

/// RFC 6265 cookie-octet, plus the space and comma that `serializeCookie`
/// quotes. A `;` would end the value and start an attribute, and a quote
/// would break the quoting it does.
pub fn validateCookieValue(value: []const u8) error{InvalidCookieValue}!void {
    for (value) |c| {
        if (c < 0x20 or c >= 0x7f) return error.InvalidCookieValue;
        if (std.mem.indexOfScalar(u8, ";\\\"", c) != null) return error.InvalidCookieValue;
    }
}

/// Serialize a cookie name/value pair with options into a Set-Cookie header value.
pub fn serializeCookie(arena: std.mem.Allocator, name: []const u8, value: []const u8, opts: CookieOpts) ![]u8 {
    try validateCookieName(name);
    try validateCookieValue(value);
    // Estimate length: name=value + attributes (110 is typical for cookie attributes per Go's implementation)
    const estimated_len = name.len + value.len + opts.path.len + opts.domain.len + 110;
    var buf = std.ArrayListUnmanaged(u8).empty;

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
        const int_str = try std.fmt.bufPrint(&int_buf, "{d}", .{ma.toSeconds()});
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
        .max_age = .fromSeconds(9001),
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

test "serializeCookie: zero max_age deletes cookie" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try serializeCookie(arena.allocator(), "sess", "abc", .{ .max_age = .zero });
    try std.testing.expectEqualStrings("sess=abc; Max-Age=0", result);
}

fn expectCookieJson(expected: []const u8, header: []const u8) !void {
    var buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try std.json.Stringify.value(Cookie{ .header = header }, .{}, &out);
    try std.testing.expectEqualStrings(expected, out.buffered());
}

test "Cookie: iterator" {
    var it = (Cookie{ .header = "a=1; b=2;c=3" }).iterator();
    try std.testing.expectEqualStrings("a", it.next().?.name);
    try std.testing.expectEqualStrings("2", it.next().?.value);
    try std.testing.expectEqualStrings("c", it.next().?.name);
    try std.testing.expectEqual(@as(?Cookie.Iterator.Entry, null), it.next());
}

test "Cookie: iterator agrees with get" {
    const jar: Cookie = .{ .header = "session=abc; theme=dark" };
    var it = jar.iterator();
    while (it.next()) |entry| {
        try std.testing.expectEqualStrings(jar.get(entry.name).?, entry.value);
    }
}

test "Cookie: iterator skips what get would never match" {
    // No `=` at all, and an empty name: `get` cannot return either, so
    // neither can the iterator.
    var it = (Cookie{ .header = "novalue; =orphan; ok=1" }).iterator();
    const entry = it.next().?;
    try std.testing.expectEqualStrings("ok", entry.name);
    try std.testing.expectEqualStrings("1", entry.value);
    try std.testing.expectEqual(@as(?Cookie.Iterator.Entry, null), it.next());
}

test "Cookie: jsonStringify" {
    try expectCookieJson(
        \\{"a":"1","b":"2"}
    , "a=1; b=2");
    try expectCookieJson("{}", "");
    // An empty value is a cookie; the name alone is not.
    try expectCookieJson(
        \\{"a":""}
    , "a=");
}
