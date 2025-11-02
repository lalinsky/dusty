const std = @import("std");

const http = @import("http.zig");
const RequestParser = @import("parser.zig").RequestParser;

pub const Request = struct {
    method: http.Method = undefined,
    url: []const u8 = "",
    version_major: u8 = 0,
    version_minor: u8 = 0,
    headers: http.Headers = .{},
    params: std.StringHashMapUnmanaged([]const u8) = .{},
    arena: std.mem.Allocator,

    // Body reading support
    parser: *RequestParser,
    conn: *std.Io.Reader,

    pub fn reset(self: *Request) void {
        const arena = self.arena;
        const parser = self.parser;
        const conn = self.conn;
        self.* = .{
            .arena = arena,
            .parser = parser,
            .conn = conn,
        };
    }

    pub fn reader(self: *Request) BodyReader {
        return .{ .req = self };
    }
};

pub const BodyReader = struct {
    req: *Request,

    pub fn read(self: *BodyReader, dest: []u8) !usize {
        if (dest.len == 0) return 0;

        const conn = self.req.conn;
        const parser = self.req.parser;

        if (parser.isBodyComplete()) return 0;

        // Setup destination for onBody callback
        parser.prepareBodyRead(dest);

        // We got some data just from resuming
        if (parser.state.body_dest_pos > 0) {
            return parser.state.body_dest_pos;
        }

        // Make sure we have something in the buffer
        if (conn.bufferedLen() == 0) {
            try conn.fillMore();
        }

        // How much do
        const buffered = conn.buffered();
        if (buffered.len == 0) return 0;
        const n = @min(dest.len, buffered.len);

        if (parser.feed(buffered[0..n])) {
            conn.toss(n);
        } else |err| {
            switch (err) {
                error.Paused => {
                    const consumed = parser.getConsumedBytes(buffered.ptr);
                    conn.toss(consumed);
                },
                else => return err,
            }
        }

        return parser.state.body_dest_pos;
    }

    pub fn readAll(self: *BodyReader, dest: []u8) !usize {
        var total: usize = 0;
        while (total < dest.len) {
            const n = try self.read(dest[total..]);
            if (n == 0) break;
            total += n;
        }
        return total;
    }
};
