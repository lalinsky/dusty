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
    query: std.StringHashMapUnmanaged([]const u8) = .{},
    arena: std.mem.Allocator,

    // Body reading support
    parser: *RequestParser,
    conn: *std.Io.Reader,
    body_reader_buffer: [1024]u8 = undefined,

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
        return .{
            .req = self,
            .interface = .{
                .vtable = &.{
                    .stream = BodyReader.stream,
                },
                .buffer = &self.body_reader_buffer,
                .seek = 0,
                .end = 0,
            },
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

pub const BodyReader = struct {
    req: *Request,
    interface: std.Io.Reader,

    fn stream(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *BodyReader = @alignCast(@fieldParentPtr("interface", io_r));

        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;

        const conn = self.req.conn;
        const parser = self.req.parser;

        // Check if body is already complete
        if (parser.isBodyComplete()) {
            return error.EndOfStream;
        }

        // Setup destination for onBody callback (resets body_dest_pos to 0)
        parser.prepareBodyRead(dest);

        // Loop until we have body bytes, body is complete, or error occurs
        // This handles cases where parser consumes framing data (chunk headers)
        // but doesn't produce body bytes yet - we must not return 0 mid-body
        while (true) {
            // If we have body bytes, return them
            if (parser.state.body_dest_pos > 0) {
                w.advance(parser.state.body_dest_pos);
                return parser.state.body_dest_pos;
            }

            // Check if body is complete
            if (parser.isBodyComplete()) {
                return error.EndOfStream;
            }

            // Ensure connection buffer has data
            if (conn.bufferedLen() == 0) {
                conn.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        // Connection closed - call finish() to complete the message
                        parser.finish() catch {
                            // finish() failed - message was not complete
                            return error.ReadFailed;
                        };

                        // Check if body is now complete after finish()
                        if (parser.isBodyComplete()) {
                            return error.EndOfStream;
                        }

                        // Message not complete despite EOF
                        return error.ReadFailed;
                    },
                    else => return error.ReadFailed,
                };
            }

            // Get buffered data
            const buffered = conn.buffered();
            if (buffered.len == 0) {
                // Shouldn't happen after successful fillMore
                return error.EndOfStream;
            }

            // Feed data to parser (may consume framing data without producing body bytes)
            if (parser.feed(buffered)) {
                // Not paused - consumed all bytes
                conn.toss(buffered.len);
            } else |err| {
                switch (err) {
                    // Paused means onMessageComplete was called
                    error.Paused => {
                        const consumed = parser.getConsumedBytes(buffered.ptr);
                        conn.toss(consumed);
                    },
                    else => return error.ReadFailed,
                }
            }

            // Continue loop to check if we got body bytes now
        }
    }
};
