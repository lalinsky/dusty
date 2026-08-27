const std = @import("std");
const http = @import("http.zig");
const Request = @import("request.zig").Request;
pub const WebSocket = @import("websocket.zig").WebSocket;
pub const CookieOpts = @import("cookie.zig").CookieOpts;
const serializeCookie = @import("cookie.zig").serializeCookie;
const Connection = @import("server.zig").Connection;

var no_buf: [0]u8 = .{};

pub const EventWriter = struct {
    body: *StreamingBodyWriter,
    line_in_progress: bool,
    interface: std.Io.Writer,
    /// The real cause behind the generic `error.WriteFailed` that the
    /// `std.Io.Writer` interface has to return. An event long enough to
    /// outgrow the stream's buffer reaches the connection while it is
    /// being written, so a caller filling one from a template finds out
    /// here what went wrong rather than only that something did.
    ///
    /// Everything here writes through the stream underneath, so this is
    /// that writer's answer carried up rather than a second one.
    err: ?Error = null,

    /// What the stream underneath can fail with.
    pub const Error = StreamingBodyWriter.Error;

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *EventWriter = @fieldParentPtr("interface", w);
        const total = writeSegments(self, data, splat) catch |err| switch (err) {
            error.WriteFailed => {
                self.err = self.body.err;
                return error.WriteFailed;
            },
        };
        return w.consume(total);
    }

    fn writeSegments(self: *EventWriter, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |segment| {
            try writeLines(self, segment);
            total += segment.len;
        }
        if (splat > 0) {
            try writeLines(self, data[data.len - 1]);
            total += data[data.len - 1].len;
        }
        return total;
    }

    fn writeLines(self: *EventWriter, bytes: []const u8) std.Io.Writer.Error!void {
        const out = &self.body.interface;
        var rest = bytes;
        while (std.mem.findScalar(u8, rest, '\n')) |idx| {
            if (!self.line_in_progress) try out.writeAll("data: ");
            const line_end = if (idx > 0 and rest[idx - 1] == '\r') idx - 1 else idx;
            try out.writeAll(rest[0..line_end]);
            try out.writeAll("\n");
            self.line_in_progress = false;
            rest = rest[idx + 1 ..];
        }
        if (rest.len > 0) {
            if (!self.line_in_progress) {
                try out.writeAll("data: ");
                self.line_in_progress = true;
            }
            try out.writeAll(rest);
        }
    }

    /// Closes the event and puts it on the wire. Must be called before the
    /// stream is used again.
    pub fn end(self: *EventWriter) Error!void {
        self.finish() catch |err| switch (err) {
            // Nothing to store: `err` is for the cause `drain` cannot
            // return, and this one goes back to the caller.
            error.WriteFailed => return self.body.err orelse error.Unexpected,
        };
    }

    fn finish(self: *EventWriter) std.Io.Writer.Error!void {
        try self.interface.flush();
        const out = &self.body.interface;
        if (self.line_in_progress) try out.writeAll("\n");
        try out.writeAll("\n");
        return out.flush();
    }
};

/// A Server-Sent Events body. The length is not known up front, so the
/// body is chunked: one chunk per event, and a terminator at the end. The
/// peer can then tell a stream that finished from one that was cut, and
/// the connection outlives the stream.
pub const EventStream = struct {
    body: StreamingBodyWriter,

    /// What sending an event can fail with.
    pub const Error = StreamingBodyWriter.Error || error{InvalidEventField};

    pub const Options = struct {
        event: ?[]const u8 = null,
        id: ?[]const u8 = null,
        retry: ?u32 = null,

        /// A CR or LF in either field would close the line early and let
        /// whoever supplied it write the rest of the event itself.
        fn validate(self: Options) error{InvalidEventField}!void {
            if (self.event) |e| if (std.mem.indexOfAny(u8, e, "\r\n") != null) return error.InvalidEventField;
            if (self.id) |id| if (std.mem.indexOfAny(u8, id, "\r\n") != null) return error.InvalidEventField;
        }
    };

    /// Opens an event whose data is written as it is produced. Call `end`
    /// on the result before touching the stream again.
    pub fn startSend(self: *EventStream, opts: Options) Error!EventWriter {
        try opts.validate();
        try self.body.res.resolve(sendFields(&self.body.interface, opts));
        return .{
            .body = &self.body,
            .line_in_progress = false,
            // Unbuffered: the stream underneath is the buffer, and holding
            // bytes here would only copy them twice.
            .interface = .{ .buffer = &no_buf, .vtable = &.{ .drain = &EventWriter.drain } },
        };
    }

    /// Sends one complete event.
    pub fn send(self: *EventStream, data: []const u8, opts: Options) Error!void {
        try opts.validate();
        return self.body.res.resolve(sendEvent(&self.body.interface, data, opts));
    }

    /// The fields that precede the data. Reports the sentinel, as anything
    /// writing to a `std.Io.Writer` does; the public entry points resolve it.
    fn sendFields(w: *std.Io.Writer, opts: Options) std.Io.Writer.Error!void {
        if (opts.event) |e| try w.print("event: {s}\n", .{e});
        if (opts.id) |id| try w.print("id: {s}\n", .{id});
        if (opts.retry) |r| try w.print("retry: {d}\n", .{r});
    }

    fn sendEvent(w: *std.Io.Writer, data: []const u8, opts: Options) std.Io.Writer.Error!void {
        try sendFields(w, opts);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const stripped = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
            try w.print("data: {s}\n", .{stripped});
        }
        try w.writeAll("\n");
        // One event, one write: an event held back is an event the peer
        // has not had, and the next one may be a long way off.
        return w.flush();
    }
};

/// Collects a response body without touching the connection.
///
/// The headers are not sent until the whole response is, so middleware
/// running after the handler can still change them, and the body is sent
/// with a `Content-Length`. Storage comes from the response's arena, so
/// there is no size to pick and nothing for the caller to own.
///
/// This exists as a wrapper rather than a bare `std.Io.Writer` so that a
/// failure has somewhere to say what it was: the interface can only
/// report `WriteFailed`.
///
/// Use `StreamingBodyWriter` when the body should go out as it is
/// produced. Either way, `end` must be called before the handler returns.
pub const BodyWriter = struct {
    res: *Response,
    interface: std.Io.Writer,
    /// The real cause behind the generic `error.WriteFailed`. Nothing here
    /// talks to the connection, so this only ever holds an allocation
    /// failure.
    err: ?Error = null,

    pub const Error = std.mem.Allocator.Error;

    fn init(res: *Response) BodyWriter {
        return .{
            .res = res,
            // Unbuffered: the response's own storage is the buffer, so
            // holding bytes here would only copy them twice.
            .interface = .{ .buffer = &no_buf, .vtable = &.{ .drain = BodyWriter.drain } },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BodyWriter = @alignCast(@fieldParentPtr("interface", w));
        const out = &self.res.buffer.writer;
        var total: usize = 0;
        // Allocating's writer only fails by running out of memory.
        for (data[0 .. data.len - 1]) |bytes| {
            out.writeAll(bytes) catch return self.fail();
            total += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            out.writeAll(pattern) catch return self.fail();
            total += pattern.len;
        }
        return w.consume(total);
    }

    fn fail(self: *BodyWriter) std.Io.Writer.Error {
        self.err = error.OutOfMemory;
        return error.WriteFailed;
    }

    /// Marks the body complete. It is sent with the rest of the response,
    /// once the headers have settled.
    pub fn end(self: *BodyWriter) Error!void {
        // Idempotent, so `defer body.end() catch {}` alongside an explicit
        // `end` on the success path is harmless rather than a second body.
        if (!self.res.body_writer_open) return;
        self.res.body_writer_open = false;
        self.interface.flush() catch |err| switch (err) {
            error.WriteFailed => return self.err orelse error.OutOfMemory,
        };
    }
};

/// Writes a response body straight to the connection as it is produced.
///
/// The headers are sent when this is created, so nothing can change them
/// afterwards -- `Response.header` and `Response.setCookie` will report
/// `error.HeadersAlreadySent`. Use `BodyWriter` unless the body really
/// should go out incrementally.
///
/// Framing is decided once, at construction: chunked, unless a
/// `Content-Length` header already says how long the body will be, in
/// which case it is streamed as-is.
pub const StreamingBodyWriter = struct {
    res: *Response,
    interface: std.Io.Writer,
    /// The real cause behind the generic `error.WriteFailed` that the
    /// `std.Io.Writer` interface has to return. Recorded when a write
    /// fails, so a handler that catches one can find out what happened
    /// instead of being told only that it did.
    err: ?Error = null,
    /// Everything a write to the connection can fail with, resolved to its
    /// cause rather than the `std.Io.Writer` sentinel.
    pub const Error = Response.SendError;

    fn init(res: *Response, buf: []u8) StreamingBodyWriter {
        return .{
            .res = res,
            .interface = .{ .buffer = buf, .vtable = &.{ .drain = StreamingBodyWriter.drain } },
        };
    }

    /// Runs `result`, storing what actually went wrong. `drain` is the one
    /// path that cannot hand the cause back -- the `std.Io.Writer` vtable
    /// fixes its error set -- so this is the one place `err` is written.
    fn record(self: *StreamingBodyWriter, result: std.Io.Writer.Error!void) std.Io.Writer.Error!void {
        self.res.resolve(result) catch |cause| {
            self.err = cause;
            return error.WriteFailed;
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *StreamingBodyWriter = @alignCast(@fieldParentPtr("interface", w));
        const pending = w.buffered();
        const total = pending.len + std.Io.Writer.countSplat(data, splat);
        // A zero length chunk is the terminator, so an empty drain must
        // send nothing rather than ending the body early.
        if (total == 0) return 0;

        // A HEAD reports the length its GET would have and sends none of
        // it. The handler still writes, and is still charged for what it
        // wrote, so a declared Content-Length is checked the same way.
        if (self.res.head) {
            self.res.body_sent += total;
            return w.consume(total);
        }

        try self.record(if (self.res.chunked)
            self.writeChunk(pending, data, splat, total)
        else
            self.writeBody(pending, data, splat));
        self.res.body_sent += total;
        return w.consume(total);
    }

    fn writeParts(
        out: *std.Io.Writer,
        pending: []const u8,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!void {
        try out.writeAll(pending);
        for (data[0 .. data.len - 1]) |bytes| try out.writeAll(bytes);
        const pattern = data[data.len - 1];
        for (0..splat) |_| try out.writeAll(pattern);
    }

    /// Streams the body as-is, for a declared Content-Length.
    fn writeBody(
        self: *StreamingBodyWriter,
        pending: []const u8,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!void {
        const out = self.res.conn.writer;
        try writeParts(out, pending, data, splat);
        try out.flush();
    }

    fn writeChunk(
        self: *StreamingBodyWriter,
        pending: []const u8,
        data: []const []const u8,
        splat: usize,
        total: usize,
    ) std.Io.Writer.Error!void {
        // 16 hex digits covers any usize, plus the CRLF.
        var size_buf: [18]u8 = undefined;
        const size = std.fmt.bufPrint(&size_buf, "{x}\r\n", .{total}) catch unreachable;

        const out = self.res.conn.writer;
        try out.writeAll(size);
        try writeParts(out, pending, data, splat);
        try out.writeAll("\r\n");
        try out.flush();
    }

    /// Finishes the body: flushes what is left and, for a chunked body,
    /// writes the terminator. Must be called before the handler returns.
    pub fn end(self: *StreamingBodyWriter) (Error || error{ContentLengthMismatch})!void {
        const res = self.res;
        // Idempotent: a second `end` must not write a second terminator,
        // which the peer would read as the start of the next message.
        if (!res.body_writer_open) return;
        res.body_writer_open = false;
        // From here the bytes already sent are the response, whatever
        // happens next, so `write` must not add a terminator or a body to
        // them.
        res.written = true;
        // If this does not finish cleanly the body is not framed the way
        // its headers promised, and the connection cannot carry another
        // response.
        errdefer res.keepalive = false;

        try res.resolve(self.interface.flush());
        if (res.chunked and !res.head) try res.resolve(res.conn.writer.writeAll("0\r\n\r\n"));
        try res.resolve(res.conn.writer.flush());
        // Sending the wrong number of bytes for a declared length leaves
        // the connection out of sync and the client waiting.
        if (res.content_length) |declared| {
            if (res.body_sent != declared) return error.ContentLengthMismatch;
        }
    }
};

pub const Response = struct {
    status: http.Status = .ok,
    body: []const u8 = "",
    headers: http.Headers = .{},
    content_type: ?http.ContentType = null,
    arena: std.mem.Allocator,
    buffer: std.Io.Writer.Allocating,
    conn: *Connection,
    written: bool = false,
    headers_written: bool = false,
    keepalive: bool = true,
    chunked: bool = false,
    streaming: bool = false,
    /// The request was a HEAD, so the headers go out describing the body
    /// a GET would have sent, and the body itself does not. Set by the
    /// server; a handler writes its body either way and does not have to
    /// know.
    head: bool = false,
    /// A body writer was handed out and has not been ended yet.
    body_writer_open: bool = false,
    /// Length declared before streaming, if any. On the response rather
    /// than the writer so that `write` can still tell whether the body
    /// that went out matched it, even if the writer was abandoned.
    content_length: ?usize = null,
    /// Body bytes handed to the connection by a streaming writer.
    body_sent: usize = 0,

    /// What shaping a header can fail with. Nothing here touches the
    /// connection: a header set after the headers went out, a name or value
    /// that would not survive the wire, one header too many.
    pub const HeaderError = error{
        HeadersAlreadySent,
        InvalidHeaderName,
        InvalidHeaderValue,
        TooManyHeaders,
    };

    /// What sending bytes to the peer can fail with, resolved to the cause
    /// the connection recorded. `error.WriteFailed` is the `std.Io.Writer`
    /// vtable's sentinel and says nothing a caller can act on, so it does
    /// not appear here; a writer that failed without recording a cause --
    /// a fixed buffer running out, say -- comes back as `Unexpected`.
    pub const SendError = Connection.WriteError || error{Unexpected};

    /// What `writeHeader` and `write` can fail with.
    pub const WriteError = HeaderError || SendError;

    pub fn init(arena: std.mem.Allocator, conn: *Connection, max_headers: usize) !Response {
        return .{
            .arena = arena,
            .buffer = .init(arena),
            .conn = conn,
            .headers = try http.Headers.init(arena, max_headers),
        };
    }

    pub fn header(self: *Response, name: []const u8, value: []const u8) HeaderError!void {
        // Not a programmer error: middleware that runs after the handler
        // cannot know whether the handler chose to stream.
        if (self.headers_written) return error.HeadersAlreadySent;
        try http.validateHeaderName(name);
        try http.validateHeaderValue(value);
        try self.headers.put(name, value);
    }

    /// A writer that collects the body without touching the connection.
    /// The headers are not sent until the whole response is, so anything
    /// running after the handler can still change them.
    ///
    /// Call `end` on the result before returning from the handler.
    pub fn writer(self: *Response) BodyWriter {
        self.startBody();
        return .init(self);
    }

    /// A writer that sends the headers now and streams the body as it is
    /// written. Chunked, unless a `Content-Length` header says how long the
    /// body will be, in which case it is streamed as-is.
    ///
    /// The headers are on the wire when this returns, so nothing can change
    /// them afterwards. Call `end` on the result before returning.
    pub fn stream(self: *Response, buf: []u8) !StreamingBodyWriter {
        self.startBody();
        if (self.headers.get("Content-Length")) |v| {
            self.content_length = std.fmt.parseInt(usize, v, 10) catch return error.InvalidContentLength;
        } else {
            self.chunked = true;
        }
        try self.writeHeader();
        return .init(self, buf);
    }

    fn startBody(self: *Response) void {
        std.debug.assert(!self.body_writer_open); // one body writer per response
        std.debug.assert(!self.headers_written); // body cannot start after the headers
        std.debug.assert(self.body.len == 0 and self.buffer.writer.end == 0); // body already set
        self.body_writer_open = true;
    }

    pub fn clearWriter(self: *Response) void {
        _ = self.buffer.writer.consumeAll();
    }

    /// Throws away a body that was started but never finished, so a
    /// replacement can be written in its place. `write` prefers the
    /// buffer over `body`, so without this an error response would be
    /// sent with whatever the failed handler had produced so far.
    ///
    /// Only usable while the headers are still open; once they are on the
    /// wire the framing is already promised and the body cannot be
    /// swapped.
    pub fn resetBody(self: *Response) void {
        std.debug.assert(!self.headers_written);
        self.clearWriter();
        self.body = "";
        self.body_writer_open = false;
        // Everything that described the old body has to go with it.
        // `content_type` is the usual way to set one, but a handler can
        // write either header directly, and then a stale Content-Length
        // is worse than a stale type: `writeHeader` leaves a length that
        // is already set alone, so the peer would be told to read a body
        // of the wrong size and the connection would fall out of step.
        self.content_type = null;
        _ = self.headers.remove("Content-Type");
        _ = self.headers.remove("Content-Length");
    }

    pub fn json(self: *Response, value: anytype, options: std.json.Stringify.Options) !void {
        const json_formatter = std.json.fmt(value, options);
        try json_formatter.format(&self.buffer.writer);
        try self.header("Content-Type", "application/json; charset=UTF-8");
    }

    pub fn setCookie(self: *Response, name: []const u8, value: []const u8, opts: CookieOpts) !void {
        if (self.headers_written) return error.HeadersAlreadySent;
        const serialized = try serializeCookie(self.arena, name, value, opts);
        try http.validateHeaderValue(serialized);
        try self.headers.add("Set-Cookie", serialized);
    }

    /// Opens a Server-Sent Events body.
    ///
    /// `buf` is what an event is assembled in before it goes at the
    /// connection, and since the body is chunked it is also the chunk size.
    /// One write per event is the point, so size it so an ordinary event
    /// does not split across two.
    pub fn startEventStream(self: *Response, buf: []u8) !EventStream {
        try self.header("Content-Type", "text/event-stream");
        try self.header("Cache-Control", "no-cache");
        // Chunked, like any other body of unknown length. An event stream
        // could be delimited by closing the connection instead, but then a
        // peer cannot tell a stream that ended from one that was cut, and
        // the connection is spent either way.
        //
        // A HEAD gets the headers an event stream would have opened with
        // and none of the events; the body writer already drops what it is
        // given for a HEAD, so no send has to ask.
        return .{ .body = try self.stream(buf) };
    }

    /// Upgrade HTTP connection to WebSocket.
    /// Returns null if request is not a valid WebSocket upgrade request.
    pub fn upgradeWebSocket(self: *Response, req: *Request) !?WebSocket {
        // Validate upgrade headers
        const upgrade = req.headers.get("Upgrade") orelse return null;
        if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return null;

        const connection = req.headers.get("Connection") orelse return null;
        if (std.ascii.indexOfIgnoreCase(connection, "upgrade") == null) return null;

        const version = req.headers.get("Sec-WebSocket-Version") orelse return null;
        if (!std.mem.eql(u8, version, "13")) return null;

        const key = req.headers.get("Sec-WebSocket-Key") orelse return null;

        // Compute accept key
        var accept_key: [28]u8 = undefined;
        WebSocket.computeAcceptKey(key, &accept_key);

        // Send 101 Switching Protocols response
        self.status = .switching_protocols;
        try self.header("Upgrade", "websocket");
        try self.header("Connection", "Upgrade");
        try self.header("Sec-WebSocket-Accept", &accept_key);
        self.streaming = true;
        try self.writeHeader();

        var seed: u64 = undefined;
        req.io.random(std.mem.asBytes(&seed));
        return WebSocket.init(req.io, self.conn.transport(), self.arena, seed);
    }

    /// Turns the sentinel a `std.Io.Writer` reports into the cause the
    /// connection recorded. The one place that answer is worked out: every
    /// public entry point on the response and on the body writers over it
    /// funnels its writes through here, so the sentinel never reaches a
    /// caller. Only a `drain`, whose error set the vtable fixes, cannot --
    /// which is what the writers' `err` fields are for.
    fn resolve(self: *Response, result: std.Io.Writer.Error!void) SendError!void {
        result catch |err| switch (err) {
            error.WriteFailed => return self.conn.getWriteError() orelse error.Unexpected,
        };
    }

    /// Settles the headers: applies `content_type` and marks them sent.
    /// Returns whether they still have to go on the wire -- false once
    /// something else has already put them there.
    fn prepareHeader(self: *Response) HeaderError!bool {
        if (self.headers_written) return false;

        // Set the Content-Type header. Before the flag, so it goes through
        // the same door as every other header rather than around it.
        if (self.content_type) |content_type| {
            try self.header("Content-Type", content_type.toContentType());
        }
        self.headers_written = true;
        return true;
    }

    pub fn writeHeader(self: *Response) WriteError!void {
        if (!try self.prepareHeader()) return;
        return self.resolve(self.sendHeaderAlone(self.conn.writer));
    }

    /// The headers with nothing behind them. `write` sends them with a body
    /// and flushes once for both; everything else -- a streaming body, an
    /// event stream, a WebSocket -- has nothing queued, and the headers
    /// must not wait in the buffer for a body that may be seconds away, or
    /// that is the peer's turn to send.
    fn sendHeaderAlone(self: *Response, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.sendHeader(w);
        return w.flush();
    }

    /// The header block on the wire. Reports the sentinel, as anything
    /// writing to a `std.Io.Writer` does; the public entry point resolves it.
    fn sendHeader(self: *Response, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // Write status line
        try w.print("HTTP/1.1 {d} {f}\r\n", .{ @intFromEnum(self.status), self.status });

        // Write headers
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            try w.print("{s}: {s}\r\n", .{ entry.key, entry.value });
        }

        // Write Connection header based on keepalive
        if (!self.keepalive) {
            try w.writeAll("Connection: close\r\n");
        }

        // Write Transfer-Encoding or Content-Length
        if (self.chunked) {
            try w.writeAll("Transfer-Encoding: chunked\r\n");
        } else if (!self.streaming) {
            // Write Content-Length if not manually set (skip for streaming responses like SSE)
            const has_content_length = self.headers.get("Content-Length") != null;
            if (!has_content_length) {
                const buffer_end = self.buffer.writer.end;
                const body_len = if (buffer_end > 0) buffer_end else self.body.len;
                try w.print("Content-Length: {d}\r\n", .{body_len});
            }
        }

        // End of headers (applies to both chunked and non-chunked)
        try w.writeAll("\r\n");
    }

    pub fn write(self: *Response) WriteError!void {
        if (self.written) {
            return;
        }
        // A handler that failed part way through may never have called
        // `end`. Its buffer is gone, so whatever it held is lost either
        // way; recover rather than take the process down, and make sure a
        // started body is still framed correctly.
        if (self.body_writer_open) {
            self.body_writer_open = false;
            // Streaming under way with a declared length: whatever the
            // writer still held is gone with the handler's buffer, so the
            // body is short. Nothing can make it match the length we
            // promised, and the connection must not be reused -- the peer
            // would read the next response as this body. A chunked body
            // needs no such care: `sendBody` terminates it, and a
            // truncated but well framed body is one the peer can finish.
            if (self.headers_written and !self.chunked) {
                if (self.content_length) |declared| {
                    if (self.body_sent != declared) self.keepalive = false;
                }
            }
            // If nothing was sent yet, a buffered body lives in the arena
            // and is still good, so leave it be: an error handler that
            // built a replacement has already cleared it.
        }
        self.written = true;

        // Already false for a chunked response: the streaming writer
        // settled the headers when it sent them.
        const send_header = try self.prepareHeader();
        return self.resolve(self.sendBody(self.conn.writer, send_header));
    }

    /// Whatever this response still owes the peer, on the wire. Reports the
    /// sentinel, as anything writing to a `std.Io.Writer` does; `write`
    /// resolves it.
    fn sendBody(self: *Response, w: *std.Io.Writer, send_header: bool) std.Io.Writer.Error!void {
        if (self.chunked) {
            // A streaming writer sent the headers; all that is left is the
            // terminator, which is body framing and so is not sent for a
            // HEAD either.
            if (!self.head) try w.writeAll("0\r\n\r\n");
            return w.flush();
        }

        if (send_header) try self.sendHeader(w);

        // Write body (either from buffer or body field). A HEAD response
        // has already reported its length and must stop here.
        if (!self.head) {
            const buffered = self.buffer.writer.buffered();
            const body = if (buffered.len > 0) buffered else self.body;
            try w.writeAll(body);
        }

        return w.flush();
    }
};

test "Response: body used when buffer is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.body = "body content";

    // Don't write to buffer
    const buffered = response.buffer.writer.buffered();
    try std.testing.expectEqualStrings("", buffered);
    try std.testing.expect(buffered.len == 0);

    // Body should be used
    try std.testing.expectEqualStrings("body content", response.body);
}

test "Response: write() with body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.body = "Hello World";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 11") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Hello World") != null);
}

test "Response: write() only writes once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.body = "First";

    try response.write();
    const first_len = conn_writer.end;

    // Try writing again with different body
    response.body = "Second";
    try response.write();

    // Should still be the same length (no second write)
    try std.testing.expectEqual(first_len, conn_writer.end);
}

test "Response: writeHeader() basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.status = .created;
    try response.header("X-Custom", "value");
    response.body = "Hello";

    try response.writeHeader();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 201") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Custom: value") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5") != null);
    // Body should not be written yet
    try std.testing.expect(std.mem.indexOf(u8, written, "Hello") == null);
}

test "Response: writeHeader() only writes once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.body = "Test";

    try response.writeHeader();
    const first_len = conn_writer.end;

    // Try writing header again with different status
    response.status = .bad_request;
    try response.writeHeader();

    // Should still be the same length (no second write)
    try std.testing.expectEqual(first_len, conn_writer.end);
}

test "Response: write() after writeHeader() doesn't duplicate headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.body = "Body content";

    // Write headers first
    try response.writeHeader();
    const header_len = conn_writer.end;

    // Now write the full response (should only add body)
    try response.write();
    const full_len = conn_writer.end;

    // Check that body was added
    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Body content") != null);

    // Length should have increased by body length only
    try std.testing.expect(full_len > header_len);
    try std.testing.expectEqual(header_len + "Body content".len, full_len);
}

test "Response: keepalive defaults to true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try std.testing.expectEqual(true, response.keepalive);

    response.body = "test";
    try response.write();

    const written = conn_writer.buffered();
    // Should not have Connection: close header when keepalive is true
    try std.testing.expect(std.mem.indexOf(u8, written, "Connection: close") == null);
}

test "Response: Connection close header when keepalive is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.keepalive = false;
    response.body = "test";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Connection: close") != null);
}

test "Response: chunked flag defaults to false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    const response = try Response.init(arena.allocator(), &connection, 32);
    try std.testing.expectEqual(false, response.chunked);
}

test "BodyWriter: sends nothing until the response is written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body = response.writer();
    try body.interface.writeAll("Hello, ");
    try body.interface.writeAll("World!");
    try body.end();

    // The headers are still open: nothing has gone out yet.
    try std.testing.expectEqual(@as(usize, 0), conn_writer.end);
    try std.testing.expect(!response.headers_written);
    try response.header("X-Late", "still allowed");

    try response.write();
    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 13") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Late: still allowed") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "Hello, World!"));
    try std.testing.expect(!response.chunked);
}

test "BodyWriter: a body larger than one write still arrives whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body = response.writer();
    for (0..100) |i| try body.interface.print("{d},", .{i});
    try body.end();
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, written, "97,98,99,"));
    try std.testing.expect(!response.chunked);
}

test "StreamingBodyWriter: sends the headers immediately and chunks the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body_buf: [1024]u8 = undefined;
    var body = try response.stream(&body_buf);
    try std.testing.expect(response.headers_written);
    // Too late for anyone to change them now.
    try std.testing.expectError(error.HeadersAlreadySent, response.header("X-Late", "no"));

    try body.interface.writeAll("first");
    try body.interface.flush();
    try body.interface.writeAll("second");
    try body.end();

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\nfirst\r\n" ++
            "6\r\nsecond\r\n" ++
            "0\r\n\r\n",
        conn_writer.buffered(),
    );
}

test "StreamingBodyWriter: writes between flushes are framed as one chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body_buf: [1024]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("aaa");
    try body.interface.writeAll("bbb");
    try body.interface.print("{d}", .{42});
    try body.end();

    // One chunk for all three writes, not three.
    try std.testing.expect(std.mem.endsWith(u8, conn_writer.buffered(), "8\r\naaabbb42\r\n0\r\n\r\n"));
}

test "StreamingBodyWriter: an empty flush does not terminate the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body_buf: [1024]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("first");
    try body.interface.flush();
    // Nothing buffered: a zero length chunk here would end the body early.
    try body.interface.flush();
    try body.interface.writeAll("second");
    try body.end();

    try std.testing.expect(std.mem.endsWith(
        u8,
        conn_writer.buffered(),
        "5\r\nfirst\r\n6\r\nsecond\r\n0\r\n\r\n",
    ));
}

test "StreamingBodyWriter: a declared Content-Length streams without chunk framing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try response.header("Content-Length", "11");

    var body_buf: [4]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hello ");
    try body.interface.writeAll("world");
    try body.end();

    try std.testing.expect(!response.chunked);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 11\r\n" ++
            "\r\n" ++
            "hello world",
        conn_writer.buffered(),
    );
}

test "StreamingBodyWriter: reports a body that does not match the declared length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try response.header("Content-Length", "11");

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("short");
    try std.testing.expectError(error.ContentLengthMismatch, body.end());
}

test "StreamingBodyWriter: rejects a Content-Length it cannot parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    // A proxy can forward whatever an upstream sent.
    try response.header("Content-Length", "99999999999999999999999999");

    var body_buf: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidContentLength, response.stream(&body_buf));
}

test "StreamingBodyWriter: stream reports the real error, not error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Too small to hold the headers, so streaming fails at the start.
    var buf: [4]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response.init(arena.allocator(), &connection, 32);
    var body_buf: [64]u8 = undefined;
    try std.testing.expectError(error.ConnectionResetByPeer, response.stream(&body_buf));
}

test "StreamingBodyWriter: end reports the real error, not error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // What a successful stream puts on the wire before `end` appends the
    // terminator. The failing pass below gets exactly that much room, so the
    // terminator is the first write with nowhere to go.
    const upto_end = blk: {
        var buf: [1024]u8 = undefined;
        var conn_writer: std.Io.Writer = .fixed(&buf);

        var connection: Connection = undefined;
        connection.initWriterForTesting(&conn_writer);

        var response = try Response.init(arena.allocator(), &connection, 32);
        var body_buf: [64]u8 = undefined;
        var body = try response.stream(&body_buf);
        try body.interface.writeAll("hello");
        try body.interface.flush();
        break :blk conn_writer.end;
    };

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(buf[0..upto_end]);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response.init(arena.allocator(), &connection, 32);
    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hello");
    try body.interface.flush();

    try std.testing.expectError(error.ConnectionResetByPeer, body.end());
    // A body that could not be framed as promised cannot share the connection.
    try std.testing.expectEqual(false, response.keepalive);
}

test "Response: write reports the real error, not error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Too small to hold the status line, so the first write has nowhere to go.
    var buf: [4]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.body = "hello";

    try std.testing.expectError(error.ConnectionResetByPeer, response.write());
}

test "Response: writeHeader reports the real error, not error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [4]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response.init(arena.allocator(), &connection, 32);
    try std.testing.expectError(error.ConnectionResetByPeer, response.writeHeader());
}

test "Response: a write that recorded no cause reports Unexpected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The buffer fills with nothing behind it to blame, so there is no
    // cause to resolve to.
    var buf: [4]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.body = "hello";

    try std.testing.expectError(error.Unexpected, response.write());
}

test "Response: no std.Io.Writer sentinel escapes the public write API" {
    // `error.WriteFailed` says only that a write failed, which the caller
    // already knew when it called us. Everything below reaches the
    // connection, and none of it may report the sentinel.
    const ErrorSetOf = struct {
        fn f(comptime func: anytype) type {
            return @typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.error_set;
        }
    }.f;
    inline for (.{
        Response.WriteError,
        ErrorSetOf(Response.writeHeader),
        ErrorSetOf(Response.write),
        ErrorSetOf(Response.stream),
        ErrorSetOf(Response.startEventStream),
        ErrorSetOf(Response.upgradeWebSocket),
        EventStream.Error,
        EventWriter.Error,
    }) |Set| {
        inline for (@typeInfo(Set).error_set.?) |e| {
            try std.testing.expect(!std.mem.eql(u8, e.name, "WriteFailed"));
        }
    }
}

test "BodyWriter: end is idempotent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body = response.writer();
    try body.interface.writeAll("hello");
    try body.end();
    // The `defer body.end() catch {}` that pairs with the line above.
    try body.end();
    try response.write();

    try std.testing.expect(std.mem.endsWith(u8, conn_writer.buffered(), "\r\n\r\nhello"));
}

test "StreamingBodyWriter: end does not write a second terminator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hello");
    try body.end();
    try body.end();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, written, "5\r\nhello\r\n0\r\n\r\n"));
    // Exactly one terminator.
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOfPos(u8, written, std.mem.indexOf(u8, written, "0\r\n\r\n").? + 1, "0\r\n\r\n"),
    );
}

test "Response: an abandoned buffered body is still sent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body = response.writer();
    try body.interface.writeAll("hello");
    // Handler returns without calling end.
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "hello"));
}

test "Response: an abandoned short body closes the connection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try response.header("Content-Length", "11");

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hello world");
    // Handler returns without end, so the body never leaves its buffer.
    try response.write();

    try std.testing.expectEqual(@as(usize, 0), response.body_sent);
    // The peer would read the next response as this body, so the
    // connection must not be reused.
    try std.testing.expect(!response.keepalive);
}

test "Response: an abandoned chunked body is still terminated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hello");
    try body.interface.flush();
    // Handler returns without end.
    try response.write();

    // Truncated, but framed: the peer knows where the body ended.
    try std.testing.expect(std.mem.endsWith(u8, conn_writer.buffered(), "0\r\n\r\n"));
    try std.testing.expect(response.keepalive);
}

test "StreamingBodyWriter: a failed end does not let write add to the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try response.header("Content-Length", "11");

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    // What an error handler would leave behind after the body started.
    response.body = "error body";
    try body.interface.writeAll("short");
    try std.testing.expectError(error.ContentLengthMismatch, body.end());

    const after_end = conn_writer.end;
    // The `catch {}` half of `defer body.end() catch {}`: the response is
    // finished either way, so this must add nothing.
    try response.write();
    try std.testing.expectEqual(after_end, conn_writer.end);
    try std.testing.expect(!response.keepalive);
}

test "StreamingBodyWriter: a failed end does not leave a second terminator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hello");
    try body.end();

    const written = conn_writer.buffered();
    try response.write();
    // Already finished, so nothing more goes out.
    try std.testing.expectEqualStrings(written, conn_writer.buffered());
}

test "Response: json() with simple object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try response.json(.{ .name = "Alice", .age = 30 }, .{});

    const buffered = response.buffer.writer.buffered();
    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", buffered);

    // Check that Content-Type was set
    const content_type = response.headers.get("Content-Type");
    try std.testing.expect(content_type != null);
    try std.testing.expectEqualStrings("application/json; charset=UTF-8", content_type.?);
}

test "Response: json() writes complete response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.status = .created;
    try response.json(.{ .id = 123, .message = "Created" }, .{});
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 201") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Type: application/json; charset=UTF-8") != null);
    // Check the actual JSON content length: {"id":123,"message":"Created"}
    const expected_json = "{\"id\":123,\"message\":\"Created\"}";
    try std.testing.expect(std.mem.indexOf(u8, written, expected_json) != null);

    // Build expected content-length string
    var cl_buf: [32]u8 = undefined;
    const cl_str = try std.fmt.bufPrint(&cl_buf, "Content-Length: {d}", .{expected_json.len});
    try std.testing.expect(std.mem.indexOf(u8, written, cl_str) != null);
}

test "Response: json() with array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    try response.json(items, .{});

    const buffered = response.buffer.writer.buffered();
    try std.testing.expectEqualStrings("[1,2,3,4,5]", buffered);
}

test "Response: json() with nested object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try response.json(.{
        .user = .{
            .name = "Bob",
            .id = 42,
        },
        .active = true,
    }, .{});

    const buffered = response.buffer.writer.buffered();
    try std.testing.expectEqualStrings("{\"user\":{\"name\":\"Bob\",\"id\":42},\"active\":true}", buffered);
}

/// An event stream over a fixed buffer. Built in place: the response points
/// at the connection and the stream at the response, so none of it can be
/// moved once it exists. `events` is what a test is actually after -- what
/// went out behind the headers.
const TestEventStream = struct {
    arena: std.heap.ArenaAllocator,
    conn_writer: std.Io.Writer,
    connection: Connection,
    response: Response,
    stream: EventStream,
    header_end: usize,
    decoded: [1024]u8,
    event_buf: [4096]u8 = undefined,

    fn init(self: *TestEventStream, buf: []u8) !void {
        self.arena = .init(std.testing.allocator);
        self.conn_writer = .fixed(buf);
        self.connection.initWriterForTesting(&self.conn_writer);
        self.response = try Response.init(self.arena.allocator(), &self.connection, 32);
        self.stream = try self.response.startEventStream(&self.event_buf);
        self.header_end = self.conn_writer.end;
    }

    fn deinit(self: *TestEventStream) void {
        self.arena.deinit();
    }

    /// What went out behind the headers, still chunk-framed.
    fn raw(self: *TestEventStream) []const u8 {
        return self.conn_writer.buffered()[self.header_end..];
    }

    /// The events with the chunk framing peeled off, so a test about how an
    /// event is formatted does not have to spell out chunk sizes. That the
    /// framing is there at all is asserted on its own, below.
    fn events(self: *TestEventStream) ![]const u8 {
        var rest = self.raw();
        var n: usize = 0;
        while (rest.len > 0) {
            const size_end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.TruncatedChunk;
            const size = try std.fmt.parseInt(usize, rest[0..size_end], 16);
            if (size == 0) break;
            const body = rest[size_end + 2 ..];
            if (body.len < size + 2) return error.TruncatedChunk;
            @memcpy(self.decoded[n..][0..size], body[0..size]);
            n += size;
            rest = body[size + 2 ..];
        }
        return self.decoded[0..n];
    }
};

test "EventStream: send with data only" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("hello world", .{});

    const written = try t.events();
    try std.testing.expectEqualStrings("data: hello world\n\n", written);
}

test "EventStream: send with event name" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("payload", .{ .event = "update" });

    const written = try t.events();
    try std.testing.expectEqualStrings("event: update\ndata: payload\n\n", written);
}

test "EventStream: send with all options" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("payload", .{ .event = "update", .id = "42", .retry = 5000 });

    const written = try t.events();
    try std.testing.expectEqualStrings("event: update\nid: 42\nretry: 5000\ndata: payload\n\n", written);
}

test "EventStream: multiple sends" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("first", .{});
    try t.stream.send("second", .{ .event = "msg" });

    const written = try t.events();
    try std.testing.expectEqualStrings("data: first\n\nevent: msg\ndata: second\n\n", written);
}

test "Response: startEventStream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    var event_buf: [4096]u8 = undefined;
    var stream = try response.startEventStream(&event_buf);

    try stream.send("connected", .{});

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Type: text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Cache-Control: no-cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "data: connected\n\n") != null);
    // The stream has no length to declare, so it is chunked -- which is
    // what lets the peer tell a stream that ended from one that was cut,
    // and lets the connection outlive it.
    try std.testing.expect(std.mem.indexOf(u8, written, "Transfer-Encoding: chunked") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length") == null);
    try std.testing.expectEqual(true, response.keepalive);
}

test "EventStream: each event is one chunk" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("hi", .{});
    try t.stream.send("there", .{ .event = "msg" });

    // One chunk per event, so a peer sees each one whole and as soon as it
    // is sent rather than when the buffer happens to fill.
    try std.testing.expectEqualStrings(
        "a\r\ndata: hi\n\n\r\n" ++
            "18\r\nevent: msg\ndata: there\n\n\r\n",
        t.raw(),
    );
}

test "EventStream: send reports the real error, not error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // What opening the stream puts on the wire. The failing pass below gets
    // exactly that much room, so the first event has nowhere to go.
    const header_len = blk: {
        var probe: [1024]u8 = undefined;
        var probe_writer: std.Io.Writer = .fixed(&probe);
        var probe_conn: Connection = undefined;
        probe_conn.initWriterForTesting(&probe_writer);
        var probe_res = try Response.init(arena.allocator(), &probe_conn, 32);
        var event_buf: [4096]u8 = undefined;
        _ = try probe_res.startEventStream(&event_buf);
        break :blk probe_writer.end;
    };

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(buf[0..header_len]);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response.init(arena.allocator(), &connection, 32);
    var event_buf: [4096]u8 = undefined;
    var stream = try response.startEventStream(&event_buf);

    try std.testing.expectError(error.ConnectionResetByPeer, stream.send("hello", .{}));
    try std.testing.expectEqual(error.ConnectionResetByPeer, stream.body.err.?);
}

test "EventWriter: end reports the real error, not error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const header_len = blk: {
        var probe: [1024]u8 = undefined;
        var probe_writer: std.Io.Writer = .fixed(&probe);
        var probe_conn: Connection = undefined;
        probe_conn.initWriterForTesting(&probe_writer);
        var probe_res = try Response.init(arena.allocator(), &probe_conn, 32);
        var event_buf: [4096]u8 = undefined;
        _ = try probe_res.startEventStream(&event_buf);
        break :blk probe_writer.end;
    };

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(buf[0..header_len]);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response.init(arena.allocator(), &connection, 32);
    var event_buf: [4096]u8 = undefined;
    var stream = try response.startEventStream(&event_buf);

    // The event is held in the stream's buffer, so nothing reaches the
    // connection until `end` closes it.
    var w = try stream.startSend(.{});
    try w.interface.writeAll("hello");
    try std.testing.expectError(error.ConnectionResetByPeer, w.end());
}

test "EventWriter: an event too long for the buffer reports the real error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const header_len = blk: {
        var probe: [1024]u8 = undefined;
        var probe_writer: std.Io.Writer = .fixed(&probe);
        var probe_conn: Connection = undefined;
        probe_conn.initWriterForTesting(&probe_writer);
        var probe_res = try Response.init(arena.allocator(), &probe_conn, 32);
        var event_buf: [4096]u8 = undefined;
        _ = try probe_res.startEventStream(&event_buf);
        break :blk probe_writer.end;
    };

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(buf[0..header_len]);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response.init(arena.allocator(), &connection, 32);
    var event_buf: [4096]u8 = undefined;
    var stream = try response.startEventStream(&event_buf);
    var w = try stream.startSend(.{});

    // Longer than the stream holds, so it reaches the connection while it
    // is still being written rather than at `end`. That is what a caller
    // filling an event from a template does, and the interface can only
    // tell them the sentinel.
    const long = try arena.allocator().alloc(u8, event_buf.len + 1);
    @memset(long, 'x');

    try std.testing.expectError(error.WriteFailed, w.interface.writeAll(long));
    try std.testing.expectEqual(error.ConnectionResetByPeer, w.err.?);
    // The stream underneath resolved it, and both copies agree.
    try std.testing.expectEqual(error.ConnectionResetByPeer, stream.body.err.?);
}

test "Response: setCookie basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try response.setCookie("session", "abc123", .{});
    response.body = "OK";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Set-Cookie: session=abc123\r\n") != null);
}

test "Response: setCookie with options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try response.setCookie("auth", "token123", .{
        .path = "/",
        .http_only = true,
        .secure = true,
        .same_site = .strict,
    });
    response.body = "OK";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Set-Cookie: auth=token123; Path=/; HttpOnly; Secure; SameSite=Strict\r\n") != null);
}

test "Response: header() rejects CRLF in value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try std.testing.expectError(error.InvalidHeaderValue, response.header("Location", "/ok\r\nX-Evil: 1"));
    try std.testing.expectError(error.InvalidHeaderValue, response.header("X-Foo", "bar\nbaz"));
    try std.testing.expectError(error.InvalidHeaderValue, response.header("X-Foo", "bar\x00baz"));
}

test "Response: header() rejects invalid name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try std.testing.expectError(error.InvalidHeaderName, response.header("", "value"));
    try std.testing.expectError(error.InvalidHeaderName, response.header("X-Bad\r\n", "value"));
    try std.testing.expectError(error.InvalidHeaderName, response.header("X: Bad", "value"));
    try std.testing.expectError(error.InvalidHeaderName, response.header("X Bad", "value"));
}

test "Response: setCookie rejects a value that would inject a header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    // Caught as a bad cookie value now, which is the earlier and narrower
    // of the two checks -- CRLF is not a cookie-octet in the first place.
    try std.testing.expectError(error.InvalidCookieValue, response.setCookie("session", "abc\r\nSet-Cookie: evil=1", .{}));
    try std.testing.expectError(error.InvalidCookieName, response.setCookie("a;Path=/", "v", .{}));
}

test "EventStream: rejects newline in event and id fields" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try std.testing.expectError(error.InvalidEventField, t.stream.send("ok", .{ .event = "bad\nevent" }));
    try std.testing.expectError(error.InvalidEventField, t.stream.send("ok", .{ .id = "bad\rid" }));
}

test "EventStream: multi-line data splits into multiple data lines" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("line1\nline2", .{});

    const written = try t.events();
    try std.testing.expectEqualStrings("data: line1\ndata: line2\n\n", written);
}

test "EventStream: CRLF line endings stripped in data" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("line1\r\nline2", .{});

    const written = try t.events();
    try std.testing.expectEqualStrings("data: line1\ndata: line2\n\n", written);
}

test "EventWriter: basic write" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.writeAll("hello");
    try ew.end();

    try std.testing.expectEqualStrings("data: hello\n\n", try t.events());
}

test "EventWriter: multi-line" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.writeAll("line1\nline2");
    try ew.end();

    try std.testing.expectEqualStrings("data: line1\ndata: line2\n\n", try t.events());
}

test "EventWriter: print" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.print("count: {d}", .{42});
    try ew.end();

    try std.testing.expectEqualStrings("data: count: 42\n\n", try t.events());
}

test "EventWriter: with options" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{ .event = "update", .id = "42" });
    try ew.interface.writeAll("payload");
    try ew.end();

    try std.testing.expectEqualStrings("event: update\nid: 42\ndata: payload\n\n", try t.events());
}

test "EventWriter: multiple writes merged into one event" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.writeAll("foo");
    try ew.interface.writeAll("bar");
    try ew.end();

    try std.testing.expectEqualStrings("data: foobar\n\n", try t.events());
}

test "EventWriter: writeByte" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.writeByte('A');
    try ew.interface.writeByte('B');
    try ew.interface.writeByte('C');
    try ew.end();

    try std.testing.expectEqualStrings("data: ABC\n\n", try t.events());
}

test "EventWriter: splatBytesAll" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.splatBytesAll("ab", 3);
    try ew.end();

    try std.testing.expectEqualStrings("data: ababab\n\n", try t.events());
}

test "Response: resetBody replaces a half written body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.content_type = .json;
    var body = response.writer();
    try body.interface.writeAll("{\"half\":");
    // The handler fails here, without ever calling `end`.

    response.resetBody();
    response.status = .internal_server_error;
    response.content_type = .text;
    response.body = "500 Internal Server Error\n";
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "500") != null);
    // The fragment must not survive as the body, nor its length as the
    // Content-Length, nor its content type as the type.
    try std.testing.expect(std.mem.indexOf(u8, written, "half") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "application/json") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 26") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "500 Internal Server Error\n"));
}

test "Response: resetBody drops the headers that described the old body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    // Set directly rather than through `content_type`, which is the case
    // clearing that field alone does not cover.
    try response.header("Content-Type", "application/json");
    try response.header("Content-Length", "8");
    try response.header("X-Request-Id", "abc");
    var body = response.writer();
    try body.interface.writeAll("{\"half\":");

    response.resetBody();
    response.status = .internal_server_error;
    response.body = "oops\n";
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "application/json") == null);
    // The stale length is the dangerous one: `writeHeader` leaves a length
    // that is already set alone, so the peer would read 8 bytes of a 5
    // byte body and take the rest from the next response.
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 8") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5") != null);
    // Headers that say nothing about the body are left alone.
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Request-Id: abc") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "oops\n"));
}

test "Response: a HEAD reports the length but sends no body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.head = true;
    response.content_type = .text;
    response.body = "hello";
    try response.write();

    const written = conn_writer.buffered();
    // The headers are the ones a GET would have got.
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "text/plain") != null);
    // The body is not.
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "hello") == null);
}

test "Response: a HEAD sends no body written through the writer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.head = true;
    var body = response.writer();
    try body.interface.writeAll("hello");
    try body.end();
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "hello") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
}

test "Response: a streamed HEAD sends the framing headers and nothing after" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.head = true;

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("first");
    try body.interface.flush();
    try body.interface.writeAll("second");
    try body.end();

    // Chunked is what a GET would have been, so it is still announced --
    // but no chunk and no terminator follow it.
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
        conn_writer.buffered(),
    );
}

test "Response: a streamed HEAD still checks a declared length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.head = true;
    try response.header("Content-Length", "5");

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    // The handler wrote what a GET would have, and is held to the length
    // it promised even though none of it went out.
    try body.interface.writeAll("hello");
    try body.end();

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n",
        conn_writer.buffered(),
    );
}

test "Response: a HEAD event stream sends the headers and no events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.head = true;

    var event_buf: [4096]u8 = undefined;
    var stream = try response.startEventStream(&event_buf);
    try stream.send("hello", .{});
    var w = try stream.startSend(.{ .event = "tick" });
    try w.interface.writeAll("more");
    try w.end();

    // The headers a GET would have opened the stream with, and nothing
    // after them.
    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "text/event-stream") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "hello") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "tick") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "data:") == null);
}
