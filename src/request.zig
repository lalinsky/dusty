const std = @import("std");

const http = @import("http.zig");

pub const Request = struct {
    method: http.Method = undefined,
    url: []const u8 = "",
    version_major: u8 = 0,
    version_minor: u8 = 0,
    headers: http.Headers = .{},
    params: std.StringHashMapUnmanaged([]const u8) = .{},
    query: std.StringHashMapUnmanaged([]const u8) = .{},
    arena: std.mem.Allocator = undefined,

    pub fn reset(self: *Request) void {
        const arena = self.arena;
        self.* = .{
            .arena = arena,
        };
    }

    /// Unescape a URL-encoded string
    /// Converts %XX hex sequences to bytes and + to space
    pub fn urlUnescape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var has_plus = false;
        var unescaped_len = input.len;

        var in_i: usize = 0;
        while (in_i < input.len) {
            const b = input[in_i];
            if (b == '%') {
                if (in_i + 2 >= input.len or !std.ascii.isHex(input[in_i + 1]) or !std.ascii.isHex(input[in_i + 2])) {
                    return error.InvalidEscapeSequence;
                }
                in_i += 3;
                unescaped_len -= 2;
            } else if (b == '+') {
                has_plus = true;
                in_i += 1;
            } else {
                in_i += 1;
            }
        }

        // no encoding, and no plus. nothing to unescape
        if (unescaped_len == input.len and !has_plus) {
            return input;
        }

        const out = try allocator.alloc(u8, unescaped_len);

        in_i = 0;
        for (0..unescaped_len) |i| {
            const b = input[in_i];
            if (b == '%') {
                out[i] = decodeHex(input[in_i + 1]) << 4 | decodeHex(input[in_i + 2]);
                in_i += 3;
            } else if (b == '+') {
                out[i] = ' ';
                in_i += 1;
            } else {
                out[i] = b;
                in_i += 1;
            }
        }

        return out;
    }

    fn decodeHex(c: u8) u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'A'...'F' => c - 'A' + 10,
            'a'...'f' => c - 'a' + 10,
            else => 0,
        };
    }
};
