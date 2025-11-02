const std = @import("std");
const http = @import("http.zig");

pub const Response = struct {
    status: http.Status = .ok,
    body: []const u8 = "",
    headers: http.Headers = .{},
    arena: std.mem.Allocator,

    pub fn header(self: *Response, name: []const u8, value: []const u8) !void {
        try self.headers.put(self.arena, name, value);
    }
};
