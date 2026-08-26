const std = @import("std");
const Transport = @import("transport.zig").Transport;

/// An established WebSocket connection (RFC 6455). Obtained from
/// `Response.upgradeWebSocket` on the server side and `Client.connectWebSocket`
/// on the client side; call `deinit` when done.
///
/// One task may call `receive`; any number of tasks may send concurrently.
pub const WebSocket = struct {
    io: std.Io,
    /// The connection underneath, and the only thing that knows why a frame
    /// failed to go out or come in. Shared with both ends of the library,
    /// which hold unrelated `Connection` types.
    transport: Transport,
    msg_arena: std.heap.ArenaAllocator,
    is_client: bool = false,
    prng: std.Random.DefaultPrng,
    max_message_size: usize = default_max_message_size,
    closed: bool = false,
    auto_responded: bool = false,
    fragmented_type: ?MessageType = null,
    fragmented_data: std.ArrayListUnmanaged(u8) = .empty,
    write_mutex: std.Io.Mutex = .init,

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
        ReservedFlags,
        LargeControlFrame,
        InvalidOpcode,
        UnexpectedContinuation,
        NestedFragment,
        InvalidUtf8,
        MessageTooLarge,
        UnmaskedClientFrame,
        MaskedServerFrame,
    };

    const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    pub fn init(io: std.Io, transport: Transport, gpa: std.mem.Allocator, seed: u64) WebSocket {
        return .{
            .io = io,
            .transport = transport,
            .msg_arena = std.heap.ArenaAllocator.init(gpa),
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Free resources. Must be called when done with the WebSocket.
    pub fn deinit(self: *WebSocket) void {
        self.msg_arena.deinit();
    }

    /// Receive next message. Blocks until message arrives.
    /// Ping frames are handled automatically (pong sent).
    /// Pong frames are ignored.
    /// The returned message data is valid until the next call to receive().
    pub fn receive(self: *WebSocket) !Message {
        return self.receiveFrame() catch |err| switch (err) {
            // The reads inside can only report the sentinel; the transport
            // knows what actually happened.
            error.ReadFailed => self.transport.getReadError() orelse error.Unexpected,
            else => |e| e,
        };
    }

    fn receiveFrame(self: *WebSocket) !Message {
        _ = self.msg_arena.reset(.retain_capacity);
        self.fragmented_data = .empty;
        self.auto_responded = false;
        self.fragmented_type = null;
        while (true) {
            const frame = try self.readFrame();

            switch (frame.opcode) {
                .ping => {
                    // Auto-respond with pong
                    try self.writeFrame(.pong, frame.payload, true);
                    self.auto_responded = true;
                    continue;
                },
                .pong => {
                    // Ignore pong frames
                    continue;
                },
                .close => {
                    var close_code: ?CloseCode = null;
                    var reason: []const u8 = "";
                    if (frame.payload.len >= 2) {
                        const code = std.mem.readInt(u16, frame.payload[0..2], .big);
                        close_code = @enumFromInt(code);
                        reason = frame.payload[2..];
                    }
                    // Echo close frame back
                    try self.writeClose(close_code orelse .normal, reason);
                    self.auto_responded = true;
                    return .{ .type = .close, .data = reason, .close_code = close_code };
                },
                .continuation => {
                    if (self.fragmented_type == null) {
                        return Error.UnexpectedContinuation;
                    }
                    if (self.fragmented_data.items.len + frame.payload.len > self.max_message_size) {
                        return Error.MessageTooLarge;
                    }
                    try self.fragmented_data.appendSlice(self.msg_arena.allocator(), frame.payload);
                    if (frame.fin) {
                        const msg_type = self.fragmented_type.?;
                        const data = try self.fragmented_data.toOwnedSlice(self.msg_arena.allocator());
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
                        try self.fragmented_data.appendSlice(self.msg_arena.allocator(), frame.payload);
                    }
                },
                _ => return Error.InvalidOpcode,
            }
        }
    }

    /// Send a text or binary message
    pub fn send(self: *WebSocket, msg_type: MessageType, data: []const u8) !void {
        if (msg_type != .text and msg_type != .binary) return Error.InvalidOpcode;
        try self.writeFrame(msg_type, data, true);
    }

    /// Send a ping frame
    pub fn ping(self: *WebSocket, data: []const u8) !void {
        if (data.len > 125) return Error.LargeControlFrame;
        try self.writeFrame(.ping, data, true);
    }

    /// Send close frame and mark connection as closed. Does nothing if a close
    /// frame has already been sent.
    pub fn close(self: *WebSocket, code: CloseCode, reason: []const u8) !void {
        return self.writeClose(code, reason);
    }

    const Frame = struct {
        fin: bool,
        opcode: MessageType,
        payload: []const u8,
    };

    fn readFrame(self: *WebSocket) !Frame {
        // Read first 2 bytes (header)
        var header: [2]u8 = undefined;
        try self.transport.reader.readSliceAll(&header);

        const fin = (header[0] & 0x80) != 0;
        // RSV1, RSV2, RSV3 must be 0 (we don't support extensions)
        if (header[0] & 0x70 != 0) {
            return Error.ReservedFlags;
        }
        const opcode: MessageType = @enumFromInt(@as(u4, @truncate(header[0] & 0x0F)));
        const masked = (header[1] & 0x80) != 0;

        // RFC 6455 §5.1: server MUST close on unmasked frame from client;
        // client MUST close on masked frame from server.
        if (!self.is_client and !masked) return Error.UnmaskedClientFrame;
        if (self.is_client and masked) return Error.MaskedServerFrame;

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
            try self.transport.reader.readSliceAll(&len_buf);
            payload_len = std.mem.readInt(u16, &len_buf, .big);
        } else if (payload_len == 127) {
            var len_buf: [8]u8 = undefined;
            try self.transport.reader.readSliceAll(&len_buf);
            payload_len = std.mem.readInt(u64, &len_buf, .big);
        }

        // Read masking key if present (client -> server messages are masked)
        var mask_key: [4]u8 = undefined;
        if (masked) {
            try self.transport.reader.readSliceAll(&mask_key);
        }

        // Read payload
        if (payload_len > self.max_message_size) {
            return Error.MessageTooLarge;
        }
        const payload = try self.msg_arena.allocator().alloc(u8, @intCast(payload_len));
        try self.transport.reader.readSliceAll(payload);

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

    /// Turns the sentinel a `std.Io.Writer` reports into the cause the
    /// transport recorded. Every frame leaves through here.
    fn resolveWrite(self: *WebSocket, result: std.Io.Writer.Error!void) !void {
        result catch |err| switch (err) {
            error.WriteFailed => return self.transport.getWriteError() orelse error.Unexpected,
        };
    }

    fn writeFrame(self: *WebSocket, opcode: MessageType, data: []const u8, fin: bool) !void {
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed) return error.EndOfStream;
        return self.resolveWrite(self.writeFrameLocked(opcode, data, fin));
    }

    fn writeFrameLocked(self: *WebSocket, opcode: MessageType, data: []const u8, fin: bool) std.Io.Writer.Error!void {
        // A half-written frame leaves the peer unable to find the next frame
        // boundary.
        errdefer self.closed = true;

        // First byte: FIN + opcode
        const byte0: u8 = (@as(u8, if (fin) 0x80 else 0x00)) | @intFromEnum(opcode);
        try self.transport.writer.writeByte(byte0);

        // Second byte: mask bit + payload length
        const mask_bit: u8 = if (self.is_client) 0x80 else 0x00;
        if (data.len < 126) {
            try self.transport.writer.writeByte(mask_bit | @as(u8, @intCast(data.len)));
        } else if (data.len <= 65535) {
            try self.transport.writer.writeByte(mask_bit | 126);
            var len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_buf, @intCast(data.len), .big);
            try self.transport.writer.writeAll(&len_buf);
        } else {
            try self.transport.writer.writeByte(mask_bit | 127);
            var len_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_buf, @intCast(data.len), .big);
            try self.transport.writer.writeAll(&len_buf);
        }

        if (self.is_client) {
            // Client frames must be masked (RFC 6455)
            var mask_key: [4]u8 = undefined;
            self.prng.random().bytes(&mask_key);
            try self.transport.writer.writeAll(&mask_key);

            // XOR payload with mask key
            for (data, 0..) |byte, i| {
                try self.transport.writer.writeByte(byte ^ mask_key[i % 4]);
            }
        } else {
            try self.transport.writer.writeAll(data);
        }
        try self.transport.writer.flush();
    }

    fn writeClose(self: *WebSocket, code: CloseCode, reason: []const u8) !void {
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed) return;
        self.closed = true;

        var buf: [127]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], @intFromEnum(code), .big);
        const reason_len = @min(reason.len, 123);
        @memcpy(buf[2..][0..reason_len], reason[0..reason_len]);
        try self.resolveWrite(self.writeFrameLocked(.close, buf[0 .. 2 + reason_len], true));
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

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
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

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();

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

test "WebSocket: writeClose" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed("");

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    try ws.writeClose(.normal, "goodbye");

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

test "WebSocket: readFrame unmasked (client mode)" {

    // A simple unmasked text frame with "Hi" — only valid server-to-client.
    const frame_data = [_]u8{
        0x81, // FIN + text
        0x02, // length = 2
        'H',
        'i',
    };
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    ws.is_client = true;
    const frame = try ws.readFrame();

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(.text, frame.opcode);
    try std.testing.expectEqualStrings("Hi", frame.payload);
}

test "WebSocket: readFrame rejects unmasked client frame (server mode)" {
    const frame_data = [_]u8{ 0x81, 0x02, 'H', 'i' };
    var reader: std.Io.Reader = .fixed(&frame_data);
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    // is_client = false (default) — must reject unmasked input per RFC 6455 §5.1.
    try std.testing.expectError(WebSocket.Error.UnmaskedClientFrame, ws.readFrame());
}

test "WebSocket: readFrame rejects masked server frame (client mode)" {
    const frame_data = [_]u8{
        0x81, 0x82, // FIN + text, masked + length = 2
        0x12, 0x34, 0x56, 0x78, // mask key
        0x5A, 0x5D, // masked payload
    };
    var reader: std.Io.Reader = .fixed(&frame_data);
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    ws.is_client = true;
    try std.testing.expectError(WebSocket.Error.MaskedServerFrame, ws.readFrame());
}

test "WebSocket: readFrame masked" {

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

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    const frame = try ws.readFrame();

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(.text, frame.opcode);
    try std.testing.expectEqualStrings("Hi", frame.payload);
}

test "WebSocket: receive handles ping automatically" {

    // Masked ping + masked text (client->server frames per RFC 6455).
    // Mask key: 0x00, 0x00, 0x00, 0x00 — payload bytes therefore equal plaintext.
    const frame_data = [_]u8{
        // Ping frame: FIN+ping, mask+len=4, mask key, masked payload
        0x89, 0x84, 0x00, 0x00, 0x00, 0x00, 'p', 'i', 'n', 'g',
        // Text frame: FIN+text, mask+len=5, mask key, masked payload
        0x81, 0x85, 0x00, 0x00, 0x00, 0x00, 'H', 'e', 'l', 'l',
        'o',
    };
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
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

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    try std.testing.expectError(WebSocket.Error.ReservedFlags, ws.readFrame());
}

test "WebSocket: readFrame rejects large control frame" {

    // Ping frame with 126-byte payload (uses extended length).
    // Test the size limit independent of masking — use client mode so the
    // unmasked frame is otherwise valid.
    const frame_data = [_]u8{
        0x89, // FIN + ping
        126, // extended length indicator
        0x00, 0x7E, // 126 bytes
    } ++ [_]u8{0} ** 126;
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    ws.is_client = true;
    try std.testing.expectError(WebSocket.Error.LargeControlFrame, ws.readFrame());
}

test "WebSocket: writeFrame masked (client mode)" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed("");

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    ws.is_client = true;
    try ws.writeFrame(.text, "Hello", true);

    const written = conn_writer.buffered();
    // FIN + text opcode
    try std.testing.expectEqual(0x81, written[0]);
    // Mask bit set + length = 5
    try std.testing.expectEqual(0x85, written[1]);
    // Bytes 2-5 are the mask key
    const mask_key = written[2..6];
    // Bytes 6-10 are the masked payload
    const masked_payload = written[6..11];
    // Unmask and verify
    var unmasked: [5]u8 = undefined;
    for (&unmasked, 0..) |*byte, i| {
        byte.* = masked_payload[i] ^ mask_key[i % 4];
    }
    try std.testing.expectEqualStrings("Hello", &unmasked);
    // Total length: 1 (header) + 1 (len) + 4 (mask) + 5 (payload) = 11
    try std.testing.expectEqual(11, written.len);
}

/// Collects everything written, suspending on each drain so another task gets
/// a chance to write into the middle of a frame.
const InterleaveProbe = struct {
    interface: std.Io.Writer,
    io: std.Io,
    out: std.ArrayListUnmanaged(u8) = .empty,
    gpa: std.mem.Allocator,
    buf: [8]u8 = undefined,

    fn init(gpa: std.mem.Allocator, io: std.Io) InterleaveProbe {
        return .{
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = &.{},
            },
            .io = io,
            .gpa = gpa,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *InterleaveProbe = @alignCast(@fieldParentPtr("interface", w));
        self.io.sleep(.fromNanoseconds(1), .awake) catch {};
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.out.appendSlice(self.gpa, bytes) catch return error.WriteFailed;
            n += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            self.out.appendSlice(self.gpa, pattern) catch return error.WriteFailed;
            n += pattern.len;
        }
        return n;
    }
};

test "WebSocket: concurrent sends do not interleave within a frame" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var probe = InterleaveProbe.init(gpa, io);
    defer probe.out.deinit(gpa);
    var reader: std.Io.Reader = .fixed("");

    var ws = WebSocket.init(io, .{ .writer = &probe.interface, .reader = &reader }, gpa, 0);
    defer ws.deinit();

    const a = "a" ** 300;
    const b = "b" ** 300;

    var fa = try io.concurrent(struct {
        fn run(s: *WebSocket, payload: []const u8) !void {
            try s.send(.text, payload);
        }
    }.run, .{ &ws, a });
    var fb = try io.concurrent(struct {
        fn run(s: *WebSocket, payload: []const u8) !void {
            try s.send(.text, payload);
        }
    }.run, .{ &ws, b });
    try fa.await(io);
    try fb.await(io);

    // Each payload goes out in one write, so it stays contiguous even when
    // interleaved; only the header gets separated from it. Compare whole frames.
    const header = [_]u8{ 0x80 | @as(u8, @intFromEnum(WebSocket.MessageType.text)), 126, 0x01, 0x2C };
    const frame_a = header ++ a.*;
    const frame_b = header ++ b.*;
    const written = probe.out.items;
    const ab = frame_a ++ frame_b;
    const ba = frame_b ++ frame_a;
    if (!std.mem.eql(u8, written, &ab) and !std.mem.eql(u8, written, &ba)) {
        return error.FrameInterleaved;
    }
}

test "WebSocket: send reports the real error, not error.WriteFailed" {
    // Too small to hold the frame, so the payload has nowhere to go.
    var buf: [4]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed("");

    // No socket, but something beneath the writer that recorded a cause --
    // which is all the transport is consulted for.
    var tcp_writer: std.Io.net.Stream.Writer = undefined;
    tcp_writer.err = error.ConnectionResetByPeer;

    var ws = WebSocket.init(std.testing.io, .{
        .writer = &conn_writer,
        .reader = &reader,
        .tcp_writer = &tcp_writer,
    }, std.testing.allocator, 0);
    defer ws.deinit();

    try std.testing.expectError(error.ConnectionResetByPeer, ws.send(.text, "x" ** 64));
}

test "WebSocket: no std.Io sentinel escapes its public API" {
    // `ReadFailed`/`WriteFailed` say only that a read or write failed, which
    // the caller knew when it called. Neither may leave these.
    const ErrorSetOf = struct {
        fn f(comptime func: anytype) type {
            return @typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.error_set;
        }
    }.f;
    inline for (.{
        ErrorSetOf(WebSocket.send),
        ErrorSetOf(WebSocket.ping),
        ErrorSetOf(WebSocket.close),
        ErrorSetOf(WebSocket.receive),
    }) |Set| {
        inline for (@typeInfo(Set).error_set.?) |e| {
            try std.testing.expect(!std.mem.eql(u8, e.name, "WriteFailed"));
            try std.testing.expect(!std.mem.eql(u8, e.name, "ReadFailed"));
        }
    }
}
