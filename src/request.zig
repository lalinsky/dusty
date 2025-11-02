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
    arena: std.mem.Allocator = undefined,

    // Body reading support
    parser: ?*RequestParser = null,
    stream_reader: ?*std.Io.Reader = null,
    body_read_buffer: ?[]u8 = null,

    pub fn reset(self: *Request) void {
        const arena = self.arena;
        self.* = .{
            .arena = arena,
        };
    }

    pub fn bodyReader(self: *Request) !BodyReader {
        return BodyReader{
            .parser = self.parser orelse return error.NoParser,
            .stream_reader = self.stream_reader orelse return error.NoStreamReader,
            .socket_buffer = self.body_read_buffer orelse return error.NoBuffer,
        };
    }
};

pub const BodyReader = struct {
    parser: *RequestParser,
    stream_reader: *std.Io.Reader,
    socket_buffer: []u8, // Buffer for socket reads

    pub fn read(self: *BodyReader, dest: []u8) !usize {
        if (dest.len == 0) return 0;
        if (self.parser.isBodyComplete()) return 0;

        // Setup destination for onBody callback
        self.parser.prepareBodyRead(dest);

        // Check if there's buffered data first
        const buffered = self.stream_reader.buffered();
        std.log.info("BodyReader.read: buffered.len={d}, dest.len={d}, isBodyComplete={}", .{ buffered.len, dest.len, self.parser.isBodyComplete() });
        if (buffered.len > 0) {
            std.log.info("BodyReader.read: feeding buffered data", .{});
            self.parser.feed(buffered) catch |err| switch (err) {
                error.Paused => {}, // Expected when body chunk is read
                else => return err,
            };
            const consumed = self.parser.getConsumedBytes(buffered.ptr);
            std.log.info("BodyReader.read: consumed={d}, copied={d}", .{ consumed, self.parser.state.body_dest_pos });
            self.stream_reader.toss(consumed);
            return self.parser.state.body_dest_pos;
        }

        // Read fresh data from socket
        std.log.info("BodyReader.read: calling fillMore", .{});
        _ = try self.stream_reader.fillMore();
        const fresh = self.stream_reader.buffered();
        std.log.info("BodyReader.read: fresh.len={d}", .{fresh.len});
        if (fresh.len == 0) return 0;

        self.parser.feed(fresh) catch |err| switch (err) {
            error.Paused => {}, // Expected when body chunk is read
            else => return err,
        };
        const consumed = self.parser.getConsumedBytes(fresh.ptr);
        std.log.info("BodyReader.read: consumed={d}, copied={d}", .{ consumed, self.parser.state.body_dest_pos });
        self.stream_reader.toss(consumed);

        return self.parser.state.body_dest_pos;
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
