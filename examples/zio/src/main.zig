//! An httpbin-shaped server, used to exercise dusty against off-the-shelf
//! HTTP clients and to give the test suite something to talk to that is not
//! a third party service.
//!
//! The endpoints follow the behaviour documented at https://httpbin.org;
//! the responses are built here rather than copied, so they match in shape
//! rather than byte for byte.
const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

const Request = http.Request;
const Response = http.Response;

/// httpbin caps these so a stray URL cannot ask for unbounded work.
const max_bytes = 100 * 1024;
const max_stream_lines = 100;
const max_delay_seconds = 10;

fn pathParamInt(req: *Request, name: []const u8, comptime T: type) ?T {
    const raw = req.params.get(name) orelse return null;
    return std.fmt.parseInt(T, raw, 10) catch null;
}

fn queryInt(req: *Request, name: []const u8, comptime T: type, default: T) T {
    const raw = req.query.get(name) orelse return default;
    return std.fmt.parseInt(T, raw, 10) catch default;
}

fn origin(req: *Request) []const u8 {
    return req.headers.get("X-Forwarded-For") orelse "127.0.0.1";
}

/// httpbin reports an absolute URL, and clients parse it for the host, so
/// rebuild one from the Host header rather than echoing the path.
fn absoluteUrl(req: *Request, res: *Response) ![]const u8 {
    return std.fmt.allocPrint(res.arena, "http://{s}{s}", .{
        req.headers.get("Host") orelse "localhost",
        req.url,
    });
}

/// Writes the fields httpbin answers with. `body` is the request body for
/// the methods that carry one, which adds `data`, `form`, `json` and
/// `files` the way `get_dict` does. Written straight out rather than built
/// as a tree, so the streaming endpoints can emit one of these per line.
fn writeDescription(
    w: *std.json.Stringify,
    req: *Request,
    res: *Response,
    id: ?usize,
    body: ?[]const u8,
) !void {
    try w.beginObject();

    try w.objectField("headers");
    try w.beginObject();
    var it = req.headers.iterator();
    while (it.next()) |entry| {
        try w.objectField(entry.key);
        try w.write(entry.value);
    }
    try w.endObject();

    try w.objectField("args");
    try w.beginObject();
    var q = req.query.iterator();
    while (q.next()) |entry| {
        try w.objectField(entry.key_ptr.*);
        try w.write(entry.value_ptr.*);
    }
    try w.endObject();

    try w.objectField("url");
    try w.write(try absoluteUrl(req, res));
    try w.objectField("origin");
    try w.write(origin(req));

    if (body) |data| {
        try w.objectField("data");
        try w.write(data);

        // Only parsed when the body says it is a form, as httpbin does.
        try w.objectField("form");
        try w.beginObject();
        if (isFormEncoded(req)) {
            var form = std.mem.splitScalar(u8, data, '&');
            while (form.next()) |pair| {
                if (pair.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                try w.objectField(try Request.urlUnescape(res.arena, pair[0..eq]));
                try w.write(try Request.urlUnescape(res.arena, pair[eq + 1 ..]));
            }
        }
        try w.endObject();

        // `json` is the parsed body when it is JSON, and null otherwise --
        // clients assert on it to check a POST round-tripped.
        try w.objectField("json");
        if (parseJson(res.arena, req, data)) |parsed| {
            try w.write(parsed);
        } else {
            try w.write(null);
        }

        // Multipart is not handled here, but the key has to exist.
        try w.objectField("files");
        try w.beginObject();
        try w.endObject();
    }

    if (id) |i| {
        try w.objectField("id");
        try w.write(i);
    }

    try w.endObject();
}

fn isFormEncoded(req: *Request) bool {
    const ct = req.headers.get("Content-Type") orelse return false;
    return std.mem.startsWith(u8, ct, "application/x-www-form-urlencoded");
}

fn parseJson(arena: std.mem.Allocator, req: *Request, data: []const u8) ?std.json.Value {
    const ct = req.headers.get("Content-Type") orelse return null;
    if (!std.mem.startsWith(u8, ct, "application/json")) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, data, .{}) catch return null;
    return parsed.value;
}

/// Sends a JSON body through the collecting writer: nothing reaches the
/// connection until the response is complete, so the headers stay open.
fn sendJson(res: *Response, req: *Request, extra: ?struct { key: []const u8, value: []const u8 }) !void {
    var body = res.writer();
    var w: std.json.Stringify = .{ .writer = &body.interface, .options = .{} };
    if (extra) |e| {
        // One extra field, written by wrapping the description.
        try w.beginObject();
        try w.objectField(e.key);
        try w.write(e.value);
        try w.endObject();
    } else {
        try writeDescription(&w, req, res, null, null);
    }
    try body.end();
    try res.header("Content-Type", "application/json");
}

fn handleIndex(_: *Request, res: *Response) !void {
    res.content_type = .text;
    res.body =
        \\dusty httpbin
        \\
        \\  /get                 request, reflected as JSON
        \\  /post                same, for POST, including the body
        \\  /headers             request headers
        \\  /ip                  origin address
        \\  /user-agent          User-Agent header
        \\  /status/:code        respond with the given status
        \\  /bytes/:n            n bytes, with a Content-Length
        \\  /stream/:n           n JSON lines, chunked
        \\  /stream-bytes/:n     n bytes, chunked
        \\  /delay/:seconds      respond after a delay
        \\  /cookies             cookies sent by the client
        \\  /cookies/set         set cookies from the query string
        \\
    ;
}

fn handleGet(req: *Request, res: *Response) !void {
    try sendJson(res, req, null);
}

/// Shared by the methods that carry a body: post, put, patch, delete.
fn handleWithBody(req: *Request, res: *Response) !void {
    // Read the body first. Serialising as we go would leave a half written
    // object in the response buffer if this failed, and that fragment
    // would then be sent as the body of the 500.
    const data = (try req.body()) orelse "";

    var body = res.writer();
    var w: std.json.Stringify = .{ .writer = &body.interface, .options = .{} };
    try writeDescription(&w, req, res, null, data);
    try body.end();
    try res.header("Content-Type", "application/json");
}

/// Answers whatever the request method was, like httpbin's /anything.
fn handleAnything(req: *Request, res: *Response) !void {
    if (req.method == .get or req.method == .head) return handleGet(req, res);
    return handleWithBody(req, res);
}

fn handleHeaders(req: *Request, res: *Response) !void {
    var body = res.writer();
    var w: std.json.Stringify = .{ .writer = &body.interface, .options = .{} };
    try w.beginObject();
    try w.objectField("headers");
    try w.beginObject();
    var it = req.headers.iterator();
    while (it.next()) |entry| {
        try w.objectField(entry.key);
        try w.write(entry.value);
    }
    try w.endObject();
    try w.endObject();
    try body.end();
    try res.header("Content-Type", "application/json");
}

fn handleIp(req: *Request, res: *Response) !void {
    try sendJson(res, req, .{ .key = "origin", .value = origin(req) });
}

fn handleUserAgent(req: *Request, res: *Response) !void {
    try sendJson(res, req, .{ .key = "user-agent", .value = req.headers.get("User-Agent") orelse "" });
}

/// `http.Status` is an exhaustive enum, so `@enumFromInt` on a value it
/// does not name is illegal behaviour: a panic in Debug, worse in
/// ReleaseFast. The code comes straight from the URL, so it has to be
/// checked against the set before converting.
fn statusFromCode(code: u16) ?http.Status {
    inline for (@typeInfo(http.Status).@"enum".fields) |f| {
        if (f.value == code) return @field(http.Status, f.name);
    }
    return null;
}

fn handleStatus(req: *Request, res: *Response) !void {
    const code = pathParamInt(req, "code", u16) orelse {
        res.status = .bad_request;
        res.content_type = .text;
        res.body = "Invalid status code\n";
        return;
    };
    res.status = statusFromCode(code) orelse {
        res.status = .bad_request;
        res.content_type = .text;
        res.body = "Unsupported status code\n";
        return;
    };
}

/// Sized up front, so this takes the writer's identity path: the body is
/// streamed with the declared Content-Length and no chunk framing.
fn handleBytes(req: *Request, res: *Response) !void {
    const n = @min(pathParamInt(req, "n", usize) orelse 0, max_bytes);

    var len_buf: [24]u8 = undefined;
    try res.header("Content-Length", try std.fmt.bufPrint(&len_buf, "{d}", .{n}));
    try res.header("Content-Type", "application/octet-stream");

    var buf: [4096]u8 = undefined;
    var body = try res.stream(&buf);
    try writeBytes(&body.interface, req, n);
    try body.end();
}

/// Same bytes, but no length up front, so this one is chunked.
fn handleStreamBytes(req: *Request, res: *Response) !void {
    const n = @min(pathParamInt(req, "n", usize) orelse 0, max_bytes);
    try res.header("Content-Type", "application/octet-stream");

    var buf: [4096]u8 = undefined;
    var body = try res.stream(&buf);
    try writeBytes(&body.interface, req, n);
    try body.end();
}

fn writeBytes(w: *std.Io.Writer, req: *Request, n: usize) !void {
    // Deterministic only when asked, as httpbin does: a client uses ?seed
    // to fetch the same bytes twice, and expects fresh bytes without it.
    var prng: std.Random.DefaultPrng = .init(if (req.query.get("seed")) |_|
        queryInt(req, "seed", u64, 0)
    else
        @as(u64, @bitCast(@as(i64, @truncate(std.Io.Timestamp.now(req.io, .real).nanoseconds)))) ^ n);
    const rand = prng.random();
    var chunk: [1024]u8 = undefined;
    var left = n;
    while (left > 0) {
        const take = @min(left, chunk.len);
        rand.bytes(chunk[0..take]);
        try w.writeAll(chunk[0..take]);
        left -= take;
    }
}

/// One JSON object per line, flushed as it goes, so a client sees the
/// response arrive in pieces rather than all at once.
fn handleStream(req: *Request, res: *Response) !void {
    const n = @min(pathParamInt(req, "n", usize) orelse 1, max_stream_lines);
    try res.header("Content-Type", "application/json");

    var buf: [4096]u8 = undefined;
    var body = try res.stream(&buf);
    for (0..n) |i| {
        // A fresh serialiser per line: each line is its own JSON document,
        // and Stringify refuses to start a second one.
        var w: std.json.Stringify = .{ .writer = &body.interface, .options = .{} };
        try writeDescription(&w, req, res, i, null);
        try body.interface.writeByte('\n');
        // Each line goes out as its own chunk, so the client sees the
        // response arrive in pieces.
        try body.interface.flush();
    }
    try body.end();
}

fn handleDelay(req: *Request, res: *Response) !void {
    // httpbin accepts fractions here, and clients use them to keep tests
    // quick.
    const raw = req.params.get("seconds") orelse "0";
    const requested = std.fmt.parseFloat(f64, raw) catch {
        res.status = .bad_request;
        res.content_type = .text;
        res.body = "Invalid delay\n";
        return;
    };
    const seconds = @min(@max(requested, 0), @as(f64, max_delay_seconds));
    // Cancellable: a request timeout or a shutdown surfaces here as
    // error.Canceled rather than holding the connection open.
    try std.Io.sleep(req.io, .fromNanoseconds(@intFromFloat(seconds * std.time.ns_per_s)), .real);
    try sendJson(res, req, null);
}

fn handleCookies(req: *Request, res: *Response) !void {
    var body = res.writer();
    var w: std.json.Stringify = .{ .writer = &body.interface, .options = .{} };
    try w.beginObject();
    // TODO(#123): dusty's Cookie only supports lookup by name, so the jar
    // cannot be enumerated. Splitting the raw header keeps the response
    // shape a client expects until it can.
    try w.objectField("cookies");
    try w.beginObject();
    var it = std.mem.splitScalar(u8, req.headers.get("Cookie") orelse "", ';');
    while (it.next()) |pair| {
        const kv = std.mem.trim(u8, pair, " ");
        if (kv.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        try w.objectField(kv[0..eq]);
        try w.write(kv[eq + 1 ..]);
    }
    try w.endObject();
    try w.endObject();
    try body.end();
    try res.header("Content-Type", "application/json");
}

/// RFC 6265 cookie-name: a token, so no separators and no controls. The
/// name here comes from the query string, and `setCookie` only checks the
/// serialised result for CRLF -- a name containing `;` would otherwise
/// smuggle in its own attributes.
fn isCookieName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c <= 0x20 or c >= 0x7f) return false;
        if (std.mem.indexOfScalar(u8, "()<>@,;:\\\"/[]?={}", c) != null) return false;
    }
    return true;
}

fn handleCookiesSet(req: *Request, res: *Response) !void {
    var it = req.query.iterator();
    while (it.next()) |entry| {
        if (!isCookieName(entry.key_ptr.*)) {
            res.status = .bad_request;
            res.content_type = .text;
            res.body = "Invalid cookie name\n";
            return;
        }
        try res.setCookie(entry.key_ptr.*, entry.value_ptr.*, .{ .path = "/" });
    }
    res.status = .found;
    try res.header("Location", "/cookies");
}

/// Parses `--<name>=<uint>` and returns the value, or null if `arg` doesn't
/// match the flag or the value doesn't parse.
fn uintFlag(arg: []const u8, comptime name: []const u8) ?u64 {
    const prefix = "--" ++ name ++ "=";
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    return std.fmt.parseUnsigned(u64, arg[prefix.len..], 10) catch null;
}

pub fn main(init: std.process.Init) !void {
    // Options (all optional):
    //   --port=N                listen port (default: 8080)
    //   --threads=N             executor threads (default: auto = all cores)
    //   --request-timeout=SECS  max time to receive a request (default: none)
    //   --keepalive-timeout=SECS max idle time on a keepalive connection (default: none)
    var port: u16 = 8080;
    var threads: usize = 0; // 0 = auto
    var request_timeout: ?std.Io.Duration = null;
    var keepalive_timeout: ?std.Io.Duration = null;
    {
        var args = try init.minimal.args.iterateAllocator(init.gpa);
        defer args.deinit();
        _ = args.next(); // argv0
        while (args.next()) |arg| {
            if (uintFlag(arg, "port")) |v| {
                port = @intCast(v);
            } else if (uintFlag(arg, "threads")) |v| {
                threads = @intCast(v);
            } else if (uintFlag(arg, "request-timeout")) |v| {
                request_timeout = .fromSeconds(@intCast(v));
            } else if (uintFlag(arg, "keepalive-timeout")) |v| {
                keepalive_timeout = .fromSeconds(@intCast(v));
            } else {
                std.log.warn("ignoring unknown argument: {s}", .{arg});
            }
        }
    }

    var rt = if (threads == 0)
        try zio.Runtime.init(init.gpa, .{ .executors = .auto })
    else
        try zio.Runtime.init(init.gpa, .{ .executors = .exact(@intCast(threads)) });
    defer rt.deinit();

    var server = http.Server(void).init(init.gpa, rt.io(), .{
        .timeout = .{
            .request = request_timeout,
            .keepalive = keepalive_timeout,
        },
    }, {});
    defer server.deinit();

    // GET and HEAD together: Flask derives HEAD from GET, dusty treats it
    // as its own method, so every readable route needs both.
    const readable = .{
        .{ "/", handleIndex },
        .{ "/get", handleGet },
        .{ "/headers", handleHeaders },
        .{ "/ip", handleIp },
        .{ "/user-agent", handleUserAgent },
        .{ "/bytes/:n", handleBytes },
        .{ "/stream-bytes/:n", handleStreamBytes },
        .{ "/stream/:n", handleStream },
        .{ "/cookies", handleCookies },
        .{ "/cookies/set", handleCookiesSet },
    };
    inline for (readable) |route| {
        server.router.get(route[0], route[1]);
        server.router.head(route[0], route[1]);
    }

    // httpbin answers these for every method.
    const any_method = .{
        .{ "/status/:code", handleStatus },
        .{ "/delay/:seconds", handleDelay },
        .{ "/anything", handleAnything },
    };
    inline for (any_method) |route| {
        server.router.get(route[0], route[1]);
        server.router.head(route[0], route[1]);
        server.router.post(route[0], route[1]);
        server.router.put(route[0], route[1]);
        server.router.patch(route[0], route[1]);
        server.router.delete(route[0], route[1]);
    }

    server.router.post("/post", handleWithBody);
    server.router.put("/put", handleWithBody);
    server.router.patch("/patch", handleWithBody);
    server.router.delete("/delete", handleWithBody);

    const addr: http.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", port) };
    std.log.info("httpbin on http://127.0.0.1:{d} (threads={d})", .{ port, threads });
    try server.listen(addr);
}
