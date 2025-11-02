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

    pub fn reader(self: *Request, buffer: []u8) BodyReader {
        return .{
            .req = self,
            .interface = .{
                .vtable = &.{
                    .stream = BodyReader.stream,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }
};

pub const BodyReader = struct {
    req: *Request,
    interface: std.Io.Reader,

    fn stream(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *BodyReader = @alignCast(@fieldParentPtr("interface", io_r));

        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;

        const conn = self.req.conn;
        const parser = self.req.parser;

        if (parser.isBodyComplete()) {
            return error.EndOfStream;
        }

        // Setup destination for onBody callback
        parser.prepareBodyRead(dest);

        // We got some data just from resuming
        if (parser.state.body_dest_pos > 0) {
            w.advance(parser.state.body_dest_pos);
            return parser.state.body_dest_pos;
        }

        // Make sure we have something in the buffer
        if (conn.bufferedLen() == 0) {
            try conn.fillMore();
        }

        // How much data is buffered
        const buffered = conn.buffered();
        if (buffered.len == 0) return error.EndOfStream;
        const n = @min(dest.len, buffered.len);

        if (parser.feed(buffered[0..n])) {
            conn.toss(n);
        } else |err| {
            switch (err) {
                error.Paused => {
                    const consumed = parser.getConsumedBytes(buffered.ptr);
                    conn.toss(consumed);
                },
                else => return error.ReadFailed,
            }
        }

        w.advance(parser.state.body_dest_pos);
        return parser.state.body_dest_pos;
    }
};
