const std = @import("std");

pub const WebSocket = struct {
    conn: *std.Io.Writer,
    reader: *std.Io.Reader,
    arena: std.mem.Allocator,
    max_message_size: usize = default_max_message_size,
    closed: bool = false,
    fragmented_type: ?MessageType = null,
    fragmented_data: std.ArrayListUnmanaged(u8) = .{},

    pub const default_max_message_size: usize = 16 * 1024 * 1024; // 16MB

    pub const MessageType = enum(u4) {
        continuation = 0x0,
        text = 0x1,
        binary = 0x2,
        close = 0x8,
        ping = 0x9,
        pong = 0xA,
        _, // Allow unknown opcodes
    };

    pub const Message = struct {
        type: MessageType,
        data: []const u8,
        close_code: ?CloseCode = null,
    };

    pub const CloseCode = enum(u16) {
        normal = 1000,
        going_away = 1001,
        protocol_error = 1002,
        unsupported = 1003,
        no_status = 1005,
        abnormal = 1006,
        invalid_payload = 1007,
        policy_violation = 1008,
        too_large = 1009,
        mandatory_extension = 1010,
        internal_error = 1011,
        _,
    };

    pub const Error = error{
        ConnectionClosed,
        ReservedFlags,
        LargeControlFrame,
        InvalidOpcode,
        UnexpectedContinuation,
        NestedFragment,
        InvalidUtf8,
        MessageTooLarge,
        ReadFailed,
    };

    const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    pub fn init(conn: *std.Io.Writer, reader: *std.Io.Reader, arena: std.mem.Allocator) WebSocket {
        return .{
            .conn = conn,
            .reader = reader,
            .arena = arena,
        };
    }

    pub fn deinit(self: *WebSocket) void {
        self.fragmented_data.deinit(self.arena);
    }

    /// Receive next message. Blocks until message arrives.
    /// Ping frames are handled automatically (pong sent).
    /// Pong frames are ignored.
    pub fn receive(self: *WebSocket) !Message {
        while (true) {
            const frame = try self.readFrame();

            switch (frame.opcode) {
                .ping => {
                    // Auto-respond with pong
                    try self.writeFrame(.pong, frame.payload, true);
                    continue;
                },
                .pong => {
                    // Ignore pong frames
                    continue;
                },
                .close => {
                    self.closed = true;
                    var close_code: ?CloseCode = null;
                    var reason: []const u8 = "";
                    if (frame.payload.len >= 2) {
                        const code = std.mem.readInt(u16, frame.payload[0..2], .big);
                        close_code = @enumFromInt(code);
                        reason = frame.payload[2..];
                    }
                    // Echo close frame back
                    try self.writeCloseFrame(close_code orelse .normal, reason);
                    return .{ .type = .close, .data = reason, .close_code = close_code };
                },
                .continuation => {
                    if (self.fragmented_type == null) {
                        return Error.UnexpectedContinuation;
                    }
                    if (self.fragmented_data.items.len + frame.payload.len > self.max_message_size) {
                        return Error.MessageTooLarge;
                    }
                    try self.fragmented_data.appendSlice(self.arena, frame.payload);
                    if (frame.fin) {
                        const msg_type = self.fragmented_type.?;
                        const data = try self.fragmented_data.toOwnedSlice(self.arena);
                        self.fragmented_type = null;
                        if (msg_type == .text and !std.unicode.utf8ValidateSlice(data)) {
                            return Error.InvalidUtf8;
                        }
                        return .{ .type = msg_type, .data = data };
                    }
                },
                .text, .binary => {
                    if (frame.fin) {
                        // Complete message in single frame
                        if (frame.opcode == .text and !std.unicode.utf8ValidateSlice(frame.payload)) {
                            return Error.InvalidUtf8;
                        }
                        return .{ .type = frame.opcode, .data = frame.payload };
                    } else {
                        // Start of fragmented message
                        if (self.fragmented_type != null) {
                            return Error.NestedFragment;
                        }
                        if (frame.payload.len > self.max_message_size) {
                            return Error.MessageTooLarge;
                        }
                        self.fragmented_type = frame.opcode;
                        self.fragmented_data.clearRetainingCapacity();
                        try self.fragmented_data.appendSlice(self.arena, frame.payload);
                    }
                },
                _ => return Error.InvalidOpcode,
            }
        }
    }

    /// Send a text or binary message
    pub fn send(self: *WebSocket, msg_type: MessageType, data: []const u8) !void {
        if (self.closed) return Error.ConnectionClosed;
        if (msg_type != .text and msg_type != .binary) return Error.InvalidOpcode;
        try self.writeFrame(msg_type, data, true);
    }

    /// Send JSON as text frame
    pub fn sendJson(self: *WebSocket, value: anytype, options: std.json.Stringify.Options) !void {
        if (self.closed) return Error.ConnectionClosed;

        var list: std.ArrayListUnmanaged(u8) = .{};
        const json_formatter = std.json.fmt(value, options);
        try json_formatter.format(list.writer(self.arena).any());
        try self.writeFrame(.text, list.items, true);
    }

    /// Send a ping frame
    pub fn ping(self: *WebSocket, data: []const u8) !void {
        if (self.closed) return Error.ConnectionClosed;
        if (data.len > 125) return Error.LargeControlFrame;
        try self.writeFrame(.ping, data, true);
    }

    /// Send close frame and mark connection as closed
    pub fn close(self: *WebSocket, code: CloseCode, reason: []const u8) !void {
        if (self.closed) return;
        self.closed = true;
        try self.writeCloseFrame(code, reason);
    }

    const Frame = struct {
        fin: bool,
        opcode: MessageType,
        payload: []const u8,
    };

    fn readExact(self: *WebSocket, dest: []u8) !void {
        var filled: usize = 0;
        while (filled < dest.len) {
            const buffered = self.reader.buffered();
            if (buffered.len > 0) {
                const to_copy = @min(buffered.len, dest.len - filled);
                @memcpy(dest[filled..][0..to_copy], buffered[0..to_copy]);
                self.reader.toss(to_copy);
                filled += to_copy;
            } else {
                self.reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return Error.ConnectionClosed,
                    else => return Error.ReadFailed,
                };
            }
        }
    }

    fn readFrame(self: *WebSocket) !Frame {
        // Read first 2 bytes (header)
        var header: [2]u8 = undefined;
        try self.readExact(&header);

        const fin = (header[0] & 0x80) != 0;
        // RSV1, RSV2, RSV3 must be 0 (we don't support extensions)
        if (header[0] & 0x70 != 0) {
            return Error.ReservedFlags;
        }
        const opcode: MessageType = @enumFromInt(@as(u4, @truncate(header[0] & 0x0F)));
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        // Control frames (close, ping, pong) must have payload <= 125 bytes
        const is_control = switch (opcode) {
            .close, .ping, .pong => true,
            else => false,
        };
        if (is_control and payload_len > 125) {
            return Error.LargeControlFrame;
        }

        // Extended payload length
        if (payload_len == 126) {
            var len_buf: [2]u8 = undefined;
            try self.readExact(&len_buf);
            payload_len = std.mem.readInt(u16, &len_buf, .big);
        } else if (payload_len == 127) {
            var len_buf: [8]u8 = undefined;
            try self.readExact(&len_buf);
            payload_len = std.mem.readInt(u64, &len_buf, .big);
        }

        // Read masking key if present (client -> server messages are masked)
        var mask_key: [4]u8 = undefined;
        if (masked) {
            try self.readExact(&mask_key);
        }

        // Read payload
        if (payload_len > self.max_message_size) {
            return Error.MessageTooLarge;
        }
        const payload = try self.arena.alloc(u8, @intCast(payload_len));
        try self.readExact(payload);

        // Unmask if needed
        if (masked) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= mask_key[i % 4];
            }
        }

        return .{
            .fin = fin,
            .opcode = opcode,
            .payload = payload,
        };
    }

    fn writeFrame(self: *WebSocket, opcode: MessageType, data: []const u8, fin: bool) !void {
        // First byte: FIN + opcode
        const byte0: u8 = (@as(u8, if (fin) 0x80 else 0x00)) | @intFromEnum(opcode);
        try self.conn.writeByte(byte0);

        // Second byte + extended length (server -> client is NOT masked)
        if (data.len < 126) {
            try self.conn.writeByte(@intCast(data.len));
        } else if (data.len <= 65535) {
            try self.conn.writeByte(126);
            var len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_buf, @intCast(data.len), .big);
            try self.conn.writeAll(&len_buf);
        } else {
            try self.conn.writeByte(127);
            var len_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_buf, @intCast(data.len), .big);
            try self.conn.writeAll(&len_buf);
        }

        // Payload (unmasked for server -> client)
        try self.conn.writeAll(data);
        try self.conn.flush();
    }

    fn writeCloseFrame(self: *WebSocket, code: CloseCode, reason: []const u8) !void {
        var buf: [127]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], @intFromEnum(code), .big);
        const reason_len = @min(reason.len, 123);
        @memcpy(buf[2..][0..reason_len], reason[0..reason_len]);
        try self.writeFrame(.close, buf[0 .. 2 + reason_len], true);
    }

    /// Compute Sec-WebSocket-Accept value from client key
    pub fn computeAcceptKey(client_key: []const u8, out: *[28]u8) void {
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(client_key);
        hasher.update(GUID);
        const hash = hasher.finalResult();
        _ = std.base64.standard.Encoder.encode(out, &hash);
    }
};

// Tests
test "WebSocket: computeAcceptKey" {
    // Test vector from RFC 6455
    var accept: [28]u8 = undefined;
    WebSocket.computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &accept);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "WebSocket: writeFrame text" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed("");

    var ws = WebSocket.init(&conn_writer, &reader, std.testing.allocator);
    try ws.writeFrame(.text, "Hello", true);

    const written = conn_writer.buffered();
    // FIN + text opcode
    try std.testing.expectEqual(0x81, written[0]);
    // Length = 5
    try std.testing.expectEqual(5, written[1]);
    // Payload
    try std.testing.expectEqualStrings("Hello", written[2..7]);
}

test "WebSocket: writeFrame binary with medium length" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed("");

    var ws = WebSocket.init(&conn_writer, &reader, std.testing.allocator);

    const payload = "x" ** 200;
    try ws.writeFrame(.binary, payload, true);

    const written = conn_writer.buffered();
    // FIN + binary opcode
    try std.testing.expectEqual(0x82, written[0]);
    // Extended length indicator
    try std.testing.expectEqual(126, written[1]);
    // 2-byte length
    try std.testing.expectEqual(200, std.mem.readInt(u16, written[2..4], .big));
}

test "WebSocket: writeCloseFrame" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed("");

    var ws = WebSocket.init(&conn_writer, &reader, std.testing.allocator);
    try ws.writeCloseFrame(.normal, "goodbye");

    const written = conn_writer.buffered();
    // FIN + close opcode
    try std.testing.expectEqual(0x88, written[0]);
    // Length = 2 (code) + 7 (reason)
    try std.testing.expectEqual(9, written[1]);
    // Close code 1000
    try std.testing.expectEqual(1000, std.mem.readInt(u16, written[2..4], .big));
    // Reason
    try std.testing.expectEqualStrings("goodbye", written[4..11]);
}

test "WebSocket: readFrame unmasked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A simple unmasked text frame with "Hi"
    const frame_data = [_]u8{
        0x81, // FIN + text
        0x02, // length = 2
        'H',
        'i',
    };
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(&conn_writer, &reader, arena.allocator());
    const frame = try ws.readFrame();

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(.text, frame.opcode);
    try std.testing.expectEqualStrings("Hi", frame.payload);
}

test "WebSocket: readFrame masked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A masked text frame with "Hi"
    // Mask key: 0x12, 0x34, 0x56, 0x78
    // 'H' ^ 0x12 = 0x5A, 'i' ^ 0x34 = 0x5D
    const frame_data = [_]u8{
        0x81, // FIN + text
        0x82, // masked + length = 2
        0x12, 0x34, 0x56, 0x78, // mask key
        0x5A, 0x5D, // masked payload
    };
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(&conn_writer, &reader, arena.allocator());
    const frame = try ws.readFrame();

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(.text, frame.opcode);
    try std.testing.expectEqualStrings("Hi", frame.payload);
}

test "WebSocket: receive handles ping automatically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Ping frame followed by text frame
    const frame_data = [_]u8{
        // Ping frame
        0x89, 0x04, 'p', 'i', 'n', 'g',
        // Text frame
        0x81, 0x05, 'H', 'e', 'l', 'l',
        'o',
    };
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(&conn_writer, &reader, arena.allocator());
    const msg = try ws.receive();

    // Should skip ping and return text message
    try std.testing.expectEqual(.text, msg.type);
    try std.testing.expectEqualStrings("Hello", msg.data);

    // Check that pong was sent
    const written = conn_writer.buffered();
    try std.testing.expectEqual(0x8A, written[0]); // FIN + pong
    try std.testing.expectEqual(4, written[1]); // length
    try std.testing.expectEqualStrings("ping", written[2..6]);
}

test "WebSocket: readFrame rejects RSV bits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Frame with RSV1 bit set (0x40)
    const frame_data = [_]u8{
        0xC1, // FIN + RSV1 + text opcode
        0x02,
        'H',
        'i',
    };
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(&conn_writer, &reader, arena.allocator());
    try std.testing.expectError(WebSocket.Error.ReservedFlags, ws.readFrame());
}

test "WebSocket: readFrame rejects large control frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Ping frame with 126-byte payload (uses extended length)
    const frame_data = [_]u8{
        0x89, // FIN + ping
        126, // extended length indicator
        0x00, 0x7E, // 126 bytes
    } ++ [_]u8{0} ** 126;
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(&conn_writer, &reader, arena.allocator());
    try std.testing.expectError(WebSocket.Error.LargeControlFrame, ws.readFrame());
}
