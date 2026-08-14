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

/// What `std.debug` writes through -- `std.debug.print`, panics, stack
/// traces, and every `std.log` line. Left alone std stands up a second,
/// blocking `Io` of its own beside the runtime. This is the same zio
/// `Io` the server itself runs on, so a log line written from a handler
/// goes through the event loop rather than parking its executor on
/// stderr.
///
/// It needs no runtime of its own: zio finds the executor on the thread,
/// and an operation with no task behind it runs as a blocking syscall
/// instead -- which covers both logging before the runtime starts and
/// logging while a panic unwinds, since the panic handler drops the
/// current task for exactly that reason.
pub const std_options_debug_io = zio.debug_io;

/// httpbin caps these so a stray URL cannot ask for unbounded work.
const max_bytes = 100 * 1024;
const max_stream_lines = 100;
const max_delay_seconds = 10;

const request_timeout: std.Io.Duration = .fromSeconds(max_delay_seconds + 20);
const keepalive_timeout: std.Io.Duration = .fromSeconds(60);

/// The context. It carries no state -- httpbin has none -- and exists so
/// the server can reach `notFound` and `uncaughtError`, which dusty only
/// looks for on a context type.
const Ctx = struct {
    /// Answers a route that does not exist. The default is plain text,
    /// which would be the one response here that a JSON client cannot
    /// read.
    pub fn notFound(_: *Ctx, _: *Request, res: *Response) !void {
        fail(res, .not_found, "Not Found");
    }

    /// Answers a handler that failed. Returns void, so there is nothing to
    /// report a failure of its own to -- `fail` has to be infallible.
    pub fn uncaughtError(_: *Ctx, _: *Request, res: *Response, err: anyerror) void {
        // The name goes to the log rather than the response: it names an
        // internal failure, and the client can do nothing with it.
        std.log.err("unhandled error: {t}", .{err});
        fail(res, .internal_server_error, "Internal Server Error");
    }
};

/// Answers with an error in the same shape as every other response,
/// rather than the plain text the library falls back to.
///
/// Infallible, because the paths that need it -- `uncaughtError`, and
/// handlers that have already given up -- have nowhere to report a second
/// failure. Serializing loses only if the arena is exhausted, and the
/// plain-text fallback needs no allocation at all.
fn fail(res: *Response, status: http.Status, comptime message: []const u8) void {
    res.status = status;
    res.json(.{ .@"error" = message, .status = @intFromEnum(status) }, .{}) catch {
        res.content_type = .text;
        res.body = message ++ "\n";
    };
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
    form: ?http.Params = null,
    json: ?std.json.Value = null,
    files: ?struct {} = null,
    id: ?usize = null,

    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
};

/// What varies between the endpoints that answer a description.
const Describe = struct {
    body: ?[]const u8 = null,
    with_method: bool = false,
    id: ?usize = null,
};

fn describe(req: *Request, res: *Response, opts: Describe) !Description {
    var desc: Description = .{
        .headers = req.headers,
        .args = req.query,
        .url = try absoluteUrl(req, res),
        .origin = .{ .address = req.remote_address },
        .method = if (opts.with_method) req.method.name() else null,
        .id = opts.id,
    };
    if (opts.body) |data| {
        desc.data = data;
        desc.form = if (req.content_type == .form) .{ .map = (try req.formData()).* } else .{};
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

fn handleIndex(_: *Ctx, _: *Request, res: *Response) !void {
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

fn handleGet(_: *Ctx, req: *Request, res: *Response) !void {
    try res.json(try describe(req, res, .{}), Description.options);
}

/// Shared by the methods that carry a body: post, put, patch, delete.
fn handleWithBody(_: *Ctx, req: *Request, res: *Response) !void {
    return sendDescription(req, res, false);
}

fn sendDescription(req: *Request, res: *Response, with_method: bool) !void {
    // Read the body first. Serialising as we go would leave a half written
    // object in the response buffer if this failed, and that fragment
    // would then be sent as the body of the 500.
    const data = (try req.body()) orelse "";
    const desc = describe(req, res, .{ .body = data, .with_method = with_method }) catch |err| switch (err) {
        // A body that does not parse is the client's mistake, not ours.
        error.InvalidEscapeSequence, error.TooManyFormFields => return fail(res, .bad_request, "Invalid form body"),
        else => |e| return e,
    };
    try res.json(desc, Description.options);
}

/// Answers whatever the request method was. Unlike the others this always
/// reports the full shape, including `method` and the body fields, so a
/// GET here still carries an empty `data`/`form`/`json`/`files`.
fn handleAnything(_: *Ctx, req: *Request, res: *Response) !void {
    return sendDescription(req, res, true);
}

fn handleHeaders(_: *Ctx, req: *Request, res: *Response) !void {
    try res.json(.{ .headers = req.headers }, .{});
}

fn handleIp(_: *Ctx, req: *Request, res: *Response) !void {
    try res.json(.{ .origin = Origin{ .address = req.remote_address } }, .{});
}

fn handleUserAgent(_: *Ctx, req: *Request, res: *Response) !void {
    try res.json(.{ .user_agent = req.headers.get("User-Agent") orelse "" }, .{});
}

fn handleStatus(_: *Ctx, req: *Request, res: *Response) !void {
    const code = req.params.getInt(u16, "code") orelse
        return fail(res, .bad_request, "Invalid status code");
    res.status = http.Status.fromCode(code) catch
        return fail(res, .bad_request, "Unsupported status code");
}

/// Sized up front, so this takes the writer's identity path: the body is
/// streamed with the declared Content-Length and no chunk framing.
fn handleBytes(_: *Ctx, req: *Request, res: *Response) !void {
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
fn handleStreamBytes(_: *Ctx, req: *Request, res: *Response) !void {
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
fn handleStream(_: *Ctx, req: *Request, res: *Response) !void {
    const n = @min(req.params.getInt(usize, "n") orelse
        return fail(res, .bad_request, "Invalid count"), max_stream_lines);
    res.content_type = .json;

    var buf: [4096]u8 = undefined;
    var body = try res.stream(&buf);
    for (0..n) |i| {
        // A fresh serialiser per line: each line is its own JSON document,
        // and Stringify refuses to start a second one.
        var w: std.json.Stringify = .{ .writer = &body.interface, .options = Description.options };
        try w.write(try describe(req, res, .{ .id = i }));
        try body.interface.writeByte('\n');
        // Each line goes out as its own chunk, so the client sees the
        // response arrive in pieces.
        try body.interface.flush();
    }
    try body.end();
}

fn handleDelay(_: *Ctx, req: *Request, res: *Response) !void {
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

fn handleCookies(_: *Ctx, req: *Request, res: *Response) !void {
    try res.json(.{ .cookies = req.cookies() }, .{});
}

fn handleCookiesSet(_: *Ctx, req: *Request, res: *Response) !void {
    // Check the whole batch first. Setting as we go meant a bad entry
    // answered 400 with the Set-Cookie headers of the entries before it
    // still attached, so the client was told no and handed cookies anyway.
    var check = req.query.iterator();
    while (check.next()) |entry| {
        http.validateCookieName(entry.key) catch return fail(res, .bad_request, "Invalid cookie name");
        http.validateCookieValue(entry.value) catch return fail(res, .bad_request, "Invalid cookie value");
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

    var ctx: Ctx = .{};
    var server = http.Server(Ctx).init(init.gpa, rt.io(), .{
        .timeout = .{
            .request = request_timeout,
            .keepalive = keepalive_timeout,
        },
    }, &ctx);
    defer server.deinit();

    // A GET route answers HEAD too, so these need registering once.
    server.router.get("/", handleIndex);
    server.router.get("/get", handleGet);
    server.router.get("/headers", handleHeaders);
    server.router.get("/ip", handleIp);
    server.router.get("/user-agent", handleUserAgent);
    server.router.get("/bytes/:n", handleBytes);
    server.router.get("/stream-bytes/:n", handleStreamBytes);
    server.router.get("/stream/:n", handleStream);
    server.router.get("/cookies", handleCookies);
    server.router.get("/cookies/set", handleCookiesSet);

    // httpbin answers these for every method.
    const any_method = .{
        .{ "/status/:code", handleStatus },
        .{ "/delay/:seconds", handleDelay },
        .{ "/anything", handleAnything },
    };
    inline for (any_method) |route| {
        server.router.get(route[0], route[1]);
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
