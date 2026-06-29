//! HTTP/2 client support, built on the vendored nghttp2 (src/nghttp2). nghttp2
//! is a pure, I/O-free protocol state machine: we feed it bytes read from the
//! socket via `nghttp2_session_mem_recv2`, it invokes our callbacks to surface
//! headers/data/stream events, and we pull bytes to write via
//! `nghttp2_session_mem_send2`.
//!
//! This file is only compiled when the `use_http2` build option is set; callers
//! must guard `@import("http2.zig")` behind `build_options.use_http2` so the
//! `nghttp2` module (and this file) are never analyzed in builds without it.

const std = @import("std");

const http = @import("http.zig");
const Method = http.Method;
const Status = http.Status;
const Headers = http.Headers;
const ContentType = http.ContentType;
const ContentEncoding = http.ContentEncoding;
const ParsedResponse = @import("parser.zig").ParsedResponse;

const c = @import("nghttp2");

const log = std.log.scoped(.dusty_h2);

pub const Http2Error = error{
    /// Failed to allocate/initialize an nghttp2 session or callbacks.
    Http2Init,
    /// nghttp2 reported a protocol/session error while processing frames.
    Http2Protocol,
    /// The peer reset our stream (RST_STREAM with a non-zero error code).
    Http2StreamReset,
    /// The peer closed the stream before a complete response was received.
    Http2IncompleteResponse,
    /// Response body exceeded the configured maximum size.
    ResponseTooLarge,
};

/// The pieces of a request needed to build the HTTP/2 HEADERS frame.
pub const RequestInfo = struct {
    method: Method,
    /// ":authority" pseudo-header, e.g. "example.com" or "example.com:8443".
    authority: []const u8,
    /// ":path" pseudo-header, e.g. "/index.html?q=1". Must be non-empty.
    path: []const u8,
    /// ":scheme" pseudo-header, normally "https".
    scheme: []const u8 = "https",
    /// Optional request body (fully buffered; sent via a DATA provider).
    body: ?[]const u8 = null,
    /// Optional user-supplied headers (names are lower-cased for h2).
    headers: ?*const Headers = null,
};

/// Per-request stream state, referenced from nghttp2 callbacks via the stream's
/// user data pointer.
const Stream = struct {
    arena: std.mem.Allocator,
    parsed: *ParsedResponse,
    body: std.ArrayListUnmanaged(u8) = .empty,
    max_body: usize,
    /// Set if the body exceeded max_body; further data is dropped.
    too_large: bool = false,
    /// Set by on_stream_close once the stream is fully finished.
    done: bool = false,
    /// RST_STREAM / abnormal close error code (0 == NO_ERROR/clean).
    close_error: u32 = 0,
    /// Set if a callback hit an allocation failure (aborts the session).
    alloc_failed: bool = false,

    // Request body provider state.
    req_body: []const u8 = &.{},
    req_sent: usize = 0,
};

fn streamFor(session: ?*c.nghttp2_session, stream_id: i32) ?*Stream {
    const ptr = c.nghttp2_session_get_stream_user_data(session, stream_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn onHeader(
    session: ?*c.nghttp2_session,
    frame: [*c]const c.nghttp2_frame,
    name: [*c]const u8,
    namelen: usize,
    value: [*c]const u8,
    valuelen: usize,
    flags: u8,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = flags;
    _ = user_data;
    const s = streamFor(session, frame.*.hd.stream_id) orelse return 0;
    const n = name[0..namelen];
    const v = value[0..valuelen];

    // Pseudo-headers (":status", etc.) are not stored as regular headers.
    if (n.len > 0 and n[0] == ':') {
        if (std.mem.eql(u8, n, ":status")) {
            const code = std.fmt.parseInt(u16, v, 10) catch return 0;
            // Status is an exhaustive enum; map unknown codes defensively rather
            // than risk illegal behavior from a bare @enumFromInt.
            if (std.enums.fromInt(Status, code)) |st| s.parsed.status = st;
        }
        return 0;
    }

    // Regular header: nghttp2's buffers are only valid during this callback, so
    // copy into the response arena before storing.
    const name_copy = s.arena.dupe(u8, n) catch {
        s.alloc_failed = true;
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    };
    const value_copy = s.arena.dupe(u8, v) catch {
        s.alloc_failed = true;
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    };
    // Ignore overflow past max_header_count (matches HTTP/1.1 leniency).
    s.parsed.headers.add(name_copy, value_copy) catch {};
    return 0;
}

fn onDataChunk(
    session: ?*c.nghttp2_session,
    flags: u8,
    stream_id: i32,
    data: [*c]const u8,
    len: usize,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = flags;
    _ = user_data;
    const s = streamFor(session, stream_id) orelse return 0;
    if (s.too_large) return 0;
    if (s.body.items.len + len > s.max_body) {
        s.too_large = true;
        return 0;
    }
    s.body.appendSlice(s.arena, data[0..len]) catch {
        s.alloc_failed = true;
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    };
    return 0;
}

fn onStreamClose(
    session: ?*c.nghttp2_session,
    stream_id: i32,
    error_code: u32,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = user_data;
    const s = streamFor(session, stream_id) orelse return 0;
    s.close_error = error_code;
    s.done = true;
    return 0;
}

fn readReqBody(
    session: ?*c.nghttp2_session,
    stream_id: i32,
    buf: [*c]u8,
    length: usize,
    data_flags: [*c]u32,
    source: [*c]c.nghttp2_data_source,
    user_data: ?*anyopaque,
) callconv(.c) isize {
    _ = session;
    _ = stream_id;
    _ = user_data;
    const s: *Stream = @ptrCast(@alignCast(source.*.ptr.?));
    const remaining = s.req_body[s.req_sent..];
    const n = @min(length, remaining.len);
    if (n > 0) @memcpy(buf[0..n], remaining[0..n]);
    s.req_sent += n;
    if (s.req_sent == s.req_body.len) {
        data_flags.* |= @as(u32, @intCast(c.NGHTTP2_DATA_FLAG_EOF));
    }
    return @intCast(n);
}

fn addNv(
    list: *std.ArrayListUnmanaged(c.nghttp2_nv),
    arena: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
) !void {
    // nghttp2 copies name/value during submit_request (default NV flags), so the
    // arena copies only need to outlive that call.
    const n = try arena.dupe(u8, name);
    const v = try arena.dupe(u8, value);
    try list.append(arena, .{
        .name = n.ptr,
        .value = v.ptr,
        .namelen = n.len,
        .valuelen = v.len,
        .flags = @as(u8, @intCast(c.NGHTTP2_NV_FLAG_NONE)),
    });
}

/// Headers that must not be forwarded as HTTP/2 fields (carried as pseudo-headers
/// or forbidden by RFC 9113 §8.2.2).
fn isSkippedHeader(name: []const u8) bool {
    const skip = [_][]const u8{
        "host",              "connection", "keep-alive", "proxy-connection",
        "transfer-encoding", "upgrade",    "te",
    };
    for (skip) |s| {
        if (std.ascii.eqlIgnoreCase(name, s)) return true;
    }
    return false;
}

/// Perform a single HTTP/2 request over an already-established (ALPN-negotiated)
/// connection and return the fully-buffered response body. Status and headers
/// are written into `parsed`. Drives the nghttp2 session synchronously: this
/// owns the reader/writer for the duration of the call (one request at a time).
pub fn fetchBuffered(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    arena: std.mem.Allocator,
    info: RequestInfo,
    parsed: *ParsedResponse,
    max_body: usize,
    max_header_count: usize,
) (Http2Error || error{ ReadFailed, WriteFailed })![]const u8 {
    parsed.headers = Headers.init(arena, max_header_count) catch return error.Http2Init;
    parsed.version_major = 2;
    parsed.version_minor = 0;

    var callbacks: ?*c.nghttp2_session_callbacks = null;
    if (c.nghttp2_session_callbacks_new(&callbacks) != 0) return error.Http2Init;
    defer c.nghttp2_session_callbacks_del(callbacks);
    c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
    c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onDataChunk);
    c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onStreamClose);

    var stream: Stream = .{
        .arena = arena,
        .parsed = parsed,
        .max_body = max_body,
        .req_body = info.body orelse &.{},
    };

    var session: ?*c.nghttp2_session = null;
    if (c.nghttp2_session_client_new(&session, callbacks, null) != 0) return error.Http2Init;
    defer c.nghttp2_session_del(session);

    // Client connection preface: SETTINGS is mandatory and must be the first
    // frame. Disable server push (we don't support it) and advertise a 1 MiB
    // stream window.
    const iv = [_]c.nghttp2_settings_entry{
        .{ .settings_id = @intCast(c.NGHTTP2_SETTINGS_ENABLE_PUSH), .value = 0 },
        .{ .settings_id = @intCast(c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE), .value = 1 << 20 },
    };
    if (c.nghttp2_submit_settings(session, @intCast(c.NGHTTP2_FLAG_NONE), &iv, iv.len) != 0) {
        return error.Http2Init;
    }

    // Build the request header list (pseudo-headers first, then user headers).
    var nva: std.ArrayListUnmanaged(c.nghttp2_nv) = .empty;
    addNv(&nva, arena, ":method", info.method.name()) catch return error.Http2Init;
    addNv(&nva, arena, ":scheme", info.scheme) catch return error.Http2Init;
    addNv(&nva, arena, ":authority", info.authority) catch return error.Http2Init;
    addNv(&nva, arena, ":path", info.path) catch return error.Http2Init;
    if (info.headers) |hs| {
        for (hs.keys[0..hs.len], hs.values[0..hs.len]) |k, v| {
            if (isSkippedHeader(k)) continue;
            const lower = std.ascii.allocLowerString(arena, k) catch return error.Http2Init;
            addNv(&nva, arena, lower, v) catch return error.Http2Init;
        }
    }

    // Attach a DATA provider only when there is a request body.
    var data_prd: c.nghttp2_data_provider = .{
        .source = .{ .ptr = &stream },
        .read_callback = readReqBody,
    };
    const prd_ptr: [*c]const c.nghttp2_data_provider = if (info.body != null) &data_prd else null;

    const stream_id = c.nghttp2_submit_request(session, null, nva.items.ptr, nva.items.len, prd_ptr, &stream);
    if (stream_id < 0) {
        log.debug("nghttp2_submit_request failed: {s}", .{c.nghttp2_strerror(stream_id)});
        return error.Http2Protocol;
    }

    try drive(session, &stream, reader, writer);

    if (stream.alloc_failed) return error.Http2Init;
    if (stream.too_large) return error.ResponseTooLarge;
    if (stream.close_error != 0) return error.Http2StreamReset;

    // Derive content metadata exactly like the HTTP/1.1 parser does.
    if (parsed.headers.get("Content-Type")) |ct| parsed.content_type = ContentType.fromContentType(ct);
    if (parsed.headers.get("Content-Encoding")) |ce| parsed.content_encoding = ContentEncoding.fromString(ce);

    return stream.body.items;
}

/// The synchronous send/recv loop: flush everything nghttp2 wants to send, then
/// read and feed bytes, until the stream completes.
fn drive(
    session: ?*c.nghttp2_session,
    stream: *Stream,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) (Http2Error || error{ ReadFailed, WriteFailed })!void {
    while (true) {
        // Send: drain all pending output frames.
        while (c.nghttp2_session_want_write(session) != 0) {
            var data: [*c]const u8 = undefined;
            const n = c.nghttp2_session_mem_send2(session, &data);
            if (n < 0) return error.Http2Protocol;
            if (n == 0) break;
            writer.writeAll(data[0..@intCast(n)]) catch return error.WriteFailed;
        }
        writer.flush() catch return error.WriteFailed;

        if (stream.done) return;
        if (stream.alloc_failed) return;

        if (c.nghttp2_session_want_read(session) == 0 and c.nghttp2_session_want_write(session) == 0) {
            // Session is idle but the stream never completed.
            return error.Http2IncompleteResponse;
        }

        // Receive: feed buffered bytes to nghttp2, or block for more.
        const buffered = reader.buffered();
        if (buffered.len > 0) {
            const rv = c.nghttp2_session_mem_recv2(session, buffered.ptr, buffered.len);
            if (rv < 0) {
                log.debug("nghttp2_session_mem_recv2 failed: {s}", .{c.nghttp2_strerror(@intCast(rv))});
                return error.Http2Protocol;
            }
            reader.toss(@intCast(rv));
        } else {
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    if (stream.done) return;
                    return error.Http2IncompleteResponse;
                },
                else => return error.ReadFailed,
            };
        }
    }
}
