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

    /// Without this it would serialize as the `IpAddress` union rather
    /// than as the string it prints. Raw, because the quotes are the only
    /// escaping an address can need.
    pub fn jsonStringify(self: Origin, jw: anytype) !void {
        try jw.beginWriteRaw();
        try jw.writer.print("\"{f}\"", .{self});
        jw.endWriteRaw();
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

/// The shape httpbin answers with. The optional fields are left out
/// entirely when null, so `/get` carries no `data` and only `/anything`
/// reports a `method`; `json` is the exception, and is written as JSON
/// null whenever there was a body to parse.
const Description = struct {
    headers: http.Headers,
    args: http.Params,
    url: []const u8,
    origin: Origin,
    method: ?[]const u8 = null,
    data: ?[]const u8 = null,
    form: ?Form = null,
    json: ?std.json.Value = null,
    files: ?struct {} = null,
    id: ?usize = null,

    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
};

/// The body read as a form, when it says it is one. Serialized straight
/// from the raw body, so nothing is built up first.
const Form = struct {
    arena: std.mem.Allocator,
    data: []const u8,
    encoded: bool,

    pub fn jsonStringify(self: Form, jw: anytype) !void {
        try jw.beginObject();
        if (self.encoded) {
            var it = std.mem.splitScalar(u8, self.data, '&');
            while (it.next()) |pair| {
                if (pair.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                // A bad %XX is the client's problem, not a reason to fail
                // the response. Skip the pair and answer with the rest.
                const key = Request.urlUnescape(self.arena, pair[0..eq]) catch continue;
                const value = Request.urlUnescape(self.arena, pair[eq + 1 ..]) catch continue;
                try jw.objectField(key);
                try jw.write(value);
            }
        }
        try jw.endObject();
    }
};

fn describe(req: *Request, res: *Response, body: ?[]const u8, with_method: bool, id: ?usize) !Description {
    var desc: Description = .{
        .headers = req.headers,
        .args = req.query,
        .url = try absoluteUrl(req, res),
        .origin = .{ .address = req.remote_address },
        .method = if (with_method) req.method.name() else null,
        .id = id,
    };
    if (body) |data| {
        desc.data = data;
        desc.form = .{ .arena = res.arena, .data = data, .encoded = req.content_type == .form };
        // Present but null when the body was not JSON, which is what a
        // client checks to see whether its POST round-tripped.
        desc.json = parseJson(res.arena, req, data) orelse .null;
        desc.files = .{};
    }
    return desc;
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
    try res.json(try describe(req, res, null, false, null), Description.options);
}

/// Shared by the methods that carry a body: post, put, patch, delete.
fn handleWithBody(req: *Request, res: *Response) !void {
    return sendDescription(req, res, false);
}

fn sendDescription(req: *Request, res: *Response, with_method: bool) !void {
    // Read the body first. Serialising as we go would leave a half written
    // object in the response buffer if this failed, and that fragment
    // would then be sent as the body of the 500.
    const data = (try req.body()) orelse "";
    try res.json(try describe(req, res, data, with_method, null), Description.options);
}

/// Answers whatever the request method was. Unlike the others this always
/// reports the full shape, including `method` and the body fields, so a
/// GET here still carries an empty `data`/`form`/`json`/`files`.
fn handleAnything(req: *Request, res: *Response) !void {
    return sendDescription(req, res, true);
}

fn handleHeaders(req: *Request, res: *Response) !void {
    try res.json(.{ .headers = req.headers }, .{});
}

fn handleIp(req: *Request, res: *Response) !void {
    try res.json(.{ .origin = Origin{ .address = req.remote_address } }, .{});
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
        var w: std.json.Stringify = .{ .writer = &body.interface, .options = Description.options };
        try w.write(try describe(req, res, null, false, i));
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
    return sendDescription(req, res, false);
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
