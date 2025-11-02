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
