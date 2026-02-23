const std = @import("std");
const zio = @import("zio");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const CookieOpts = @import("../cookie.zig").CookieOpts;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const base64url = std.base64.url_safe_no_pad;
const log = std.log.scoped(.dusty);

pub const max_entries = 16;

pub const SessionData = struct {
    entries: [max_entries]Entry = undefined,
    len: usize = 0,
    modified: bool = false,

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn get(self: *const SessionData, key: []const u8) ?[]const u8 {
        for (self.entries[0..self.len]) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn set(self: *SessionData, key: []const u8, value: []const u8) error{ SessionFull, InvalidSessionData }!void {
        if (std.mem.indexOfScalar(u8, key, 0) != null or
            std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSessionData;
        for (self.entries[0..self.len]) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                entry.value = value;
                self.modified = true;
                return;
            }
        }
        if (self.len >= max_entries) return error.SessionFull;
        self.entries[self.len] = .{ .key = key, .value = value };
        self.len += 1;
        self.modified = true;
    }

    pub fn remove(self: *SessionData, key: []const u8) void {
        for (self.entries[0..self.len], 0..) |entry, i| {
            if (std.mem.eql(u8, entry.key, key)) {
                self.entries[i] = self.entries[self.len - 1];
                self.len -= 1;
                self.modified = true;
                return;
            }
        }
    }

    pub fn clear(self: *SessionData) void {
        self.len = 0;
        self.modified = true;
    }

    pub fn items(self: *const SessionData) []const Entry {
        return self.entries[0..self.len];
    }
};

pub const Config = struct {
    secret_key: []const u8,
    cookie_name: []const u8 = "session",
    max_age: ?zio.Duration = null,
    cookie_opts: CookieOpts = .{
        .path = "/",
        .http_only = true,
        .secure = true,
        .same_site = .lax,
    },
};

config: Config,

const Session = @This();

pub fn init(config: Config) !Session {
    return .{ .config = config };
}

pub fn execute(self: *const Session, req: *Request, res: *Response, executor: anytype) !void {
    const cookie_value = req.cookies().get(self.config.cookie_name);
    if (cookie_value) |raw| {
        self.load(req.arena, &req.session, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| log.debug("session load failed: {}", .{e}),
        };
    }

    try executor.next();

    // Re-sign if modified, or if max_age is set and session has data (sliding expiry)
    const should_set = req.session.modified or (self.config.max_age != null and req.session.len > 0);

    if (should_set) {
        if (req.session.len == 0) {
            // Session was cleared — delete the cookie
            var delete_opts = self.config.cookie_opts;
            delete_opts.max_age = .zero;
            try res.setCookie(self.config.cookie_name, "", delete_opts);
        } else {
            const signed = try self.signSession(req.arena, &req.session, .now(.realtime));
            var opts = self.config.cookie_opts;
            if (self.config.max_age) |ma| {
                opts.max_age = ma;
            }
            try res.setCookie(self.config.cookie_name, signed, opts);
        }
    }
}

const Header = packed struct(u64) {
    version: u8 = 1,
    _reserved: u24 = 0,
    expires_at: u32 = 0,
};

const header_size = @sizeOf(Header);
const sig_size = HmacSha256.mac_length;
const overhead = header_size + sig_size;

/// Load a signed cookie value into a SessionData.
/// Decodes the base64, verifies HMAC, then parses entries.
/// Format: base64url([Header: 8 bytes][signature: 32 bytes][key\0value\0...])
fn load(self: *const Session, arena: std.mem.Allocator, session: *SessionData, raw: []const u8) !void {
    const decoded_len = base64url.Decoder.calcSizeForSlice(raw) catch return error.InvalidEncoding;
    if (decoded_len < overhead) return error.InvalidEncoding;
    const decoded = try arena.alloc(u8, decoded_len);
    base64url.Decoder.decode(decoded, raw) catch return error.InvalidEncoding;

    // Read and check header
    const header: Header = @bitCast(std.mem.readInt(u64, decoded[0..header_size], .little));
    if (header.version != 1) return error.UnsupportedVersion;

    // Verify signature (covers header + payload)
    const sig = decoded[header_size..][0..sig_size];
    const payload = decoded[overhead..];

    var mac = HmacSha256.init(self.config.secret_key);
    mac.update(decoded[0..header_size]);
    mac.update(payload);
    var expected: [sig_size]u8 = undefined;
    mac.final(&expected);
    if (!std.crypto.timing_safe.eql([sig_size]u8, sig.*, expected)) return error.InvalidSignature;

    // Check expiry
    if (header.expires_at != 0) {
        const now: u32 = @intCast(zio.Timestamp.now(.realtime).toNanoseconds() / 1_000_000_000);
        if (header.expires_at < now) return error.Expired;
    }

    // Parse null-separated key\0value pairs
    var it = std.mem.splitScalar(u8, payload, 0);
    while (session.len < max_entries) {
        const key = it.next() orelse break;
        const val = it.next() orelse break;
        session.entries[session.len] = .{ .key = key, .value = val };
        session.len += 1;
    }
}

/// Serialize session entries, sign, and base64-encode.
/// Format: base64url([Header: 8 bytes][signature: 32 bytes][key\0value\0...])
fn signSession(self: *const Session, arena: std.mem.Allocator, session: *const SessionData, now: zio.Timestamp) ![]const u8 {
    // Calculate payload size
    var payload_size: usize = 0;
    for (session.items()) |entry| {
        payload_size += entry.key.len + 1 + entry.value.len + 1;
    }

    // Build raw buffer: [header][signature][payload]
    const raw = try arena.alloc(u8, overhead + payload_size);

    // Write header
    const expires_at: u32 = if (self.config.max_age) |ma| blk: {
        const expires_s = now.addDuration(ma).toNanoseconds() / 1_000_000_000;
        break :blk @min(expires_s, std.math.maxInt(u32));
    } else 0;

    const header = Header{ .expires_at = expires_at };
    std.mem.writeInt(u64, raw[0..header_size], @bitCast(header), .little);

    // Write payload
    var pos: usize = overhead;
    for (session.items()) |entry| {
        @memcpy(raw[pos..][0..entry.key.len], entry.key);
        pos += entry.key.len;
        raw[pos] = 0;
        pos += 1;
        @memcpy(raw[pos..][0..entry.value.len], entry.value);
        pos += entry.value.len;
        raw[pos] = 0;
        pos += 1;
    }

    // Sign header + payload
    const payload = raw[overhead..];
    var mac = HmacSha256.init(self.config.secret_key);
    mac.update(raw[0..header_size]);
    mac.update(payload);
    mac.final(raw[header_size..][0..sig_size]);

    // Base64-encode
    const enc_len = base64url.Encoder.calcSize(raw.len);
    const buf = try arena.alloc(u8, enc_len);
    return base64url.Encoder.encode(buf, raw);
}

// Tests

const testing = std.testing;

test "SessionData: get and set" {
    var s = SessionData{};
    try s.set("user_id", "42");
    try s.set("name", "alice");

    try testing.expectEqualStrings("42", s.get("user_id").?);
    try testing.expectEqualStrings("alice", s.get("name").?);
    try testing.expect(s.get("missing") == null);
    try testing.expect(s.modified);
}

test "SessionData: set overwrites existing key" {
    var s = SessionData{};
    try s.set("key", "old");
    try s.set("key", "new");

    try testing.expectEqualStrings("new", s.get("key").?);
    try testing.expectEqual(1, s.len);
}

test "SessionData: remove" {
    var s = SessionData{};
    try s.set("a", "1");
    try s.set("b", "2");
    try s.set("c", "3");

    s.modified = false;
    s.remove("b");

    try testing.expect(s.modified);
    try testing.expectEqual(2, s.len);
    try testing.expectEqualStrings("1", s.get("a").?);
    try testing.expectEqualStrings("3", s.get("c").?);
    try testing.expect(s.get("b") == null);
}

test "SessionData: remove nonexistent is no-op" {
    var s = SessionData{};
    try s.set("a", "1");
    s.modified = false;

    s.remove("missing");
    try testing.expect(!s.modified);
    try testing.expectEqual(1, s.len);
}

test "SessionData: full capacity" {
    const keys = [max_entries][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p" };
    var s = SessionData{};
    for (keys) |key| {
        try s.set(key, "v");
    }
    try testing.expectEqual(max_entries, s.len);
    try testing.expectError(error.SessionFull, s.set("overflow", "x"));
}

test "Session: sign and load round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session = Session{ .config = .{
        .secret_key = "test-secret-key-that-is-long-enough",
        .cookie_name = "session",
    } };

    var s = SessionData{};
    try s.set("user_id", "42");
    try s.set("role", "admin");

    const signed = try session.signSession(arena.allocator(), &s, .now(.realtime));

    var s2 = SessionData{};
    try session.load(arena.allocator(), &s2, signed);

    try testing.expectEqualStrings("42", s2.get("user_id").?);
    try testing.expectEqualStrings("admin", s2.get("role").?);
    try testing.expect(!s2.modified);
}

test "Session: sign and load round-trip with max_age" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session = Session{ .config = .{
        .secret_key = "test-secret-key-that-is-long-enough",
        .cookie_name = "session",
        .max_age = .fromSeconds(3600),
    } };

    var s = SessionData{};
    try s.set("user_id", "42");

    const signed = try session.signSession(arena.allocator(), &s, .now(.realtime));

    var s2 = SessionData{};
    try session.load(arena.allocator(), &s2, signed);

    try testing.expectEqualStrings("42", s2.get("user_id").?);
}

test "Session: load rejects expired session" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session = Session{ .config = .{
        .secret_key = "test-secret-key-that-is-long-enough",
        .cookie_name = "session",
        .max_age = .fromSeconds(3600),
    } };

    var s = SessionData{};
    try s.set("user_id", "42");

    // Sign with a timestamp far in the past so expires_at is already passed
    const signed = try session.signSession(arena.allocator(), &s, .fromNanoseconds(1000 * 1_000_000_000));

    var s2 = SessionData{};
    try testing.expectError(error.Expired, session.load(arena.allocator(), &s2, signed));
}

test "Session: load rejects tampered payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session = Session{ .config = .{
        .secret_key = "test-secret-key-that-is-long-enough",
        .cookie_name = "session",
    } };

    var s = SessionData{};
    try s.set("user_id", "42");
    const signed = try session.signSession(arena.allocator(), &s, .now(.realtime));

    var tampered = try arena.allocator().dupe(u8, signed);
    // Tamper near the end (payload region) to avoid corrupting the header/version
    const idx = tampered.len - 1;
    tampered[idx] = if (tampered[idx] == 'A') 'B' else 'A';

    var s2 = SessionData{};
    try testing.expectError(error.InvalidSignature, session.load(arena.allocator(), &s2, tampered));
}

test "Session: load rejects wrong key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session1 = Session{ .config = .{ .secret_key = "key-one", .cookie_name = "s" } };
    const session2 = Session{ .config = .{ .secret_key = "key-two", .cookie_name = "s" } };

    var s = SessionData{};
    try s.set("data", "test");
    const signed = try session1.signSession(arena.allocator(), &s, .now(.realtime));

    var s2 = SessionData{};
    try testing.expectError(error.InvalidSignature, session2.load(arena.allocator(), &s2, signed));
}

test "Session: load rejects garbage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session = Session{ .config = .{ .secret_key = "key", .cookie_name = "s" } };

    var s = SessionData{};
    try testing.expectError(error.InvalidEncoding, session.load(arena.allocator(), &s, ""));

    s = .{};
    try testing.expectError(error.InvalidEncoding, session.load(arena.allocator(), &s, "!!!invalid-base64!!!"));

    s = .{};
    try testing.expectError(error.InvalidEncoding, session.load(arena.allocator(), &s, "AAAA"));
}

test "Session: empty session round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session = Session{ .config = .{ .secret_key = "key", .cookie_name = "s" } };

    var s = SessionData{};
    const signed = try session.signSession(arena.allocator(), &s, .now(.realtime));

    var s2 = SessionData{};
    try session.load(arena.allocator(), &s2, signed);
    try testing.expectEqual(0, s2.len);
}

test "SessionData: set rejects null bytes in key" {
    var s = SessionData{};
    try testing.expectError(error.InvalidSessionData, s.set("bad\x00key", "value"));
    try testing.expectEqual(0, s.len);
}

test "SessionData: set rejects null bytes in value" {
    var s = SessionData{};
    try testing.expectError(error.InvalidSessionData, s.set("key", "bad\x00value"));
    try testing.expectEqual(0, s.len);
}

test "SessionData: clear" {
    var s = SessionData{};
    try s.set("a", "1");
    try s.set("b", "2");
    s.modified = false;

    s.clear();
    try testing.expect(s.modified);
    try testing.expectEqual(0, s.len);
    try testing.expect(s.get("a") == null);
}
