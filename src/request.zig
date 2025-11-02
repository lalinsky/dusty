const std = @import("std");

const http = @import("http.zig");

pub const Request = struct {
    method: http.Method = undefined,
    url: []const u8 = "",
    version_major: u8 = 0,
    version_minor: u8 = 0,
    headers: http.Headers = .{},
    params: std.StringHashMapUnmanaged([]const u8) = .{},
    query: []const u8 = "",
    arena: std.mem.Allocator = undefined,

    pub fn reset(self: *Request) void {
        const arena = self.arena;
        self.* = .{
            .arena = arena,
        };
    }
};
