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

const request_timeout: std.Io.Duration = .fromSeconds(max_delay_seconds + 20);
const keepalive_timeout: std.Io.Duration = .fromSeconds(60);

/// Answers with a plain-text message in place of the endpoint's usual
/// body. The message is comptime so the trailing newline -- which keeps it
/// readable when a client prints the body raw -- can be appended without
/// allocating.
fn fail(res: *Response, status: http.Status, comptime message: []const u8) void {
    res.status = status;
    res.content_type = .text;
    res.body = message ++ "\n";
}

/// An address without its port, which is the origin httpbin reports.
/// `IpAddress.format` always writes one, and std has no portless
/// formatter for IPv4.
const Origin = struct {
    address: std.Io.net.IpAddress,

    pub fn format(self: Origin, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.address) {
            .ip4 => |a| try w.print("{d}.{d}.{d}.{d}", .{
                a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3],
            }),
            .ip6 => |a| try w.print("{f}", .{std.Io.net.Ip6Address.Unresolved{
                .bytes = a.bytes,
                .interface_name = null,
            }}),
        }
    }
};

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
    /// Only /anything reports it, so it is opt in rather than always on.
    with_method: bool,
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
        try w.objectField(entry.key);
        try w.write(entry.value);
    }
    try w.endObject();

    try w.objectField("url");
    try w.write(try absoluteUrl(req, res));
    try w.objectField("origin");
    // `print` writes raw, so the quotes are ours; an address only ever
    // formats as digits and separators, which need no escaping.
    try w.print("\"{f}\"", .{Origin{ .address = req.remote_address }});

    if (with_method) {
        try w.objectField("method");
        try w.write(req.method.name());
    }

    if (body) |data| {
        try w.objectField("data");
        try w.write(data);

        // Only parsed when the body says it is a form, as httpbin does.
        try w.objectField("form");
        try w.beginObject();
        if (req.content_type == .form) {
            var form = std.mem.splitScalar(u8, data, '&');
            while (form.next()) |pair| {
                if (pair.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                // A bad %XX is the client's problem, not a reason to drop
                // the request: propagating here would leave the connection
                // closed with no response at all, since nothing has been
                // flushed yet. Skip the pair and answer with the rest.
                const key = Request.urlUnescape(res.arena, pair[0..eq]) catch continue;
                const value = Request.urlUnescape(res.arena, pair[eq + 1 ..]) catch continue;
                try w.objectField(key);
                try w.write(value);
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

fn parseJson(arena: std.mem.Allocator, req: *Request, data: []const u8) ?std.json.Value {
    if (req.content_type != .json) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, data, .{}) catch return null;
    return parsed.value;
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
    return describe(req, res, null, false);
}

/// Shared by the methods that carry a body: post, put, patch, delete.
fn handleWithBody(req: *Request, res: *Response) !void {
    return describeWithBody(req, res, false);
}

fn describeWithBody(req: *Request, res: *Response, with_method: bool) !void {
    // Read the body first. Serialising as we go would leave a half written
    // object in the response buffer if this failed, and that fragment
    // would then be sent as the body of the 500.
    const data = (try req.body()) orelse "";
    return describe(req, res, data, with_method);
}

/// Sends the description through the collecting writer: nothing reaches
/// the connection until the response is complete, so the headers stay
/// open.
fn describe(req: *Request, res: *Response, data: ?[]const u8, with_method: bool) !void {
    res.content_type = .json;
    var body = res.writer();
    var w: std.json.Stringify = .{ .writer = &body.interface, .options = .{} };
    try writeDescription(&w, req, res, null, data, with_method);
    try body.end();
}

/// Answers whatever the request method was. Unlike the others this always
/// reports the full shape, including `method` and the body fields, so a
/// GET here still carries an empty `data`/`form`/`json`/`files`.
fn handleAnything(req: *Request, res: *Response) !void {
    return describeWithBody(req, res, true);
}

fn handleHeaders(req: *Request, res: *Response) !void {
    res.content_type = .json;
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
}

fn handleIp(req: *Request, res: *Response) !void {
    const address = try std.fmt.allocPrint(res.arena, "{f}", .{Origin{ .address = req.remote_address }});
    try res.json(.{ .origin = address }, .{});
}

fn handleUserAgent(req: *Request, res: *Response) !void {
    try res.json(.{ .user_agent = req.headers.get("User-Agent") orelse "" }, .{});
}

fn handleStatus(req: *Request, res: *Response) !void {
    const code = req.params.getInt(u16, "code") orelse
        return fail(res, .bad_request, "Invalid status code");
    res.status = http.Status.fromCode(code) catch
        return fail(res, .bad_request, "Unsupported status code");
}

/// Sized up front, so this takes the writer's identity path: the body is
/// streamed with the declared Content-Length and no chunk framing.
fn handleBytes(req: *Request, res: *Response) !void {
    const n = @min(req.params.getInt(usize, "n") orelse
        return fail(res, .bad_request, "Invalid count"), max_bytes);

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
    const n = @min(req.params.getInt(usize, "n") orelse
        return fail(res, .bad_request, "Invalid count"), max_bytes);
    try res.header("Content-Type", "application/octet-stream");

    var buf: [4096]u8 = undefined;
    var body = try res.stream(&buf);
    try writeBytes(&body.interface, req, n);
    try body.end();
}

fn writeBytes(w: *std.Io.Writer, req: *Request, n: usize) !void {
    // Deterministic only when asked, as httpbin does: a client uses ?seed
    // to fetch the same bytes twice, and expects fresh bytes without it.
    const seed: u64 = req.query.getInt(u64, "seed") orelse seed: {
        var value: u64 = undefined;
        req.io.random(std.mem.asBytes(&value));
        break :seed value;
    };

    var prng: std.Random.DefaultPrng = .init(seed);
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
    const n = @min(req.params.getInt(usize, "n") orelse
        return fail(res, .bad_request, "Invalid count"), max_stream_lines);
    res.content_type = .json;

    var buf: [4096]u8 = undefined;
    var body = try res.stream(&buf);
    for (0..n) |i| {
        // A fresh serialiser per line: each line is its own JSON document,
        // and Stringify refuses to start a second one.
        var w: std.json.Stringify = .{ .writer = &body.interface, .options = .{} };
        try writeDescription(&w, req, res, i, null, false);
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
    const requested = req.params.getFloat(f64, "seconds") orelse
        return fail(res, .bad_request, "Invalid delay");
    const seconds = @min(@max(requested, 0), @as(f64, max_delay_seconds));
    // Cancellable: a request timeout or a shutdown surfaces here as
    // error.Canceled rather than holding the connection open.
    try req.io.sleep(.fromNanoseconds(@intFromFloat(seconds * std.time.ns_per_s)), .real);
    // Registered for every method, and httpbin reflects the body here the
    // same way /post does.
    return describeWithBody(req, res, false);
}

fn handleCookies(req: *Request, res: *Response) !void {
    res.content_type = .json;
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

/// RFC 6265 cookie-octet, plus space and comma because `serializeCookie`
/// quotes those. Everything else -- notably `;` -- would end the value and
/// start an attribute, which is the same injection the name check blocks.
fn isCookieValue(value: []const u8) bool {
    for (value) |c| {
        if (c < 0x20 or c >= 0x7f) return false;
        if (std.mem.indexOfScalar(u8, ";\\\"", c) != null) return false;
    }
    return true;
}

fn handleCookiesSet(req: *Request, res: *Response) !void {
    // Check the whole batch first. Setting as we go meant a bad entry
    // answered 400 with the Set-Cookie headers of the entries before it
    // still attached, so the client was told no and handed cookies anyway.
    var check = req.query.iterator();
    while (check.next()) |entry| {
        if (!isCookieName(entry.key)) return fail(res, .bad_request, "Invalid cookie name");
        if (!isCookieValue(entry.value)) return fail(res, .bad_request, "Invalid cookie value");
    }

    var it = req.query.iterator();
    while (it.next()) |entry| {
        try res.setCookie(entry.key, entry.value, .{ .path = "/" });
    }
    res.status = .found;
    try res.header("Location", "/cookies");
}

const default_port = 8080;

const Options = struct {
    /// -l ADDR
    listen: std.Io.net.IpAddress = .{ .ip4 = .loopback(default_port) },
};

/// The value following a flag, or an error naming the flag that is
/// missing one.
fn flagValue(args: *std.process.Args.Iterator, flag: []const u8) ![]const u8 {
    return args.next() orelse {
        std.log.err("{s} needs a value", .{flag});
        return error.InvalidArgument;
    };
}

/// Values are parsed here rather than carried out as text, because the
/// iterator owns the strings and frees them when this returns.
fn parseArgs(init: std.process.Init) !Options {
    var opts: Options = .{};

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next(); // argv0
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-l")) {
            // IPv6 has to be bracketed -- `[::1]:8080` -- since the
            // address itself is full of colons.
            const text = try flagValue(&args, arg);
            opts.listen = std.Io.net.IpAddress.parseLiteral(text) catch |err| {
                std.log.err("{s} {s}: {t}", .{ arg, text, err });
                return error.InvalidArgument;
            };
            // An address given without a port parses as port 0, which
            // would listen on whatever the kernel handed out.
            if (opts.listen.getPort() == 0) opts.listen.setPort(default_port);
        } else {
            std.log.warn("ignoring unknown argument: {s}", .{arg});
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    // Options:
    //   -l ADDR   address to listen on (default: 127.0.0.1:8080)
    const opts = try parseArgs(init);

    var rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
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

    std.log.info("httpbin on http://{f}", .{opts.listen});
    try server.listen(.{ .ip = opts.listen });
}
