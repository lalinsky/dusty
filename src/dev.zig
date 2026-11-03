//! Reloads open pages after the server restarts, while it runs under
//! `addRunServer` from build.zig, which sets `DUSTY_DEV`. Otherwise it's all
//! off: `register` adds no routes and `script` writes nothing.
//!
//! ```zig
//! http.dev.init(io, init.environ_map);
//! http.dev.register(&server.router);
//! ```
//!
//! and in the page layout, `{http.dev.script(.{})}` before `</body>`.

const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const reload_path = "/_dusty/reload";
pub const script_path = "/_dusty/reload.js";

var enabled = false;

// Each process has its own id, so a page can tell that the server it
// reconnected to is not the one that rendered it.
var boot_id: [16]u8 = undefined;

// Served as a file rather than inline, so a Content-Security-Policy that
// allows 'self' allows it without a nonce.
const script_js =
    \\(() => {
    \\    if (window.dustyReload) return;
    \\    window.dustyReload = true;
    \\    const boot = document.currentScript.dataset.boot;
    \\    let events = null;
    \\    const connect = () => {
    \\        events = new EventSource("
++ reload_path ++
    \\");
    \\        events.addEventListener("boot", (e) => {
    \\            if (e.data !== boot) location.reload();
    \\        });
    \\    };
    \\    // Hidden tabs let go of their connection, since browsers allow only
    \\    // a few per host over HTTP/1.1.
    \\    document.addEventListener("visibilitychange", () => {
    \\        if (document.hidden) {
    \\            events?.close();
    \\            events = null;
    \\        } else if (!events) {
    \\            connect();
    \\        }
    \\    });
    \\    if (!document.hidden) connect();
    \\})();
    \\
;

/// Turns reloading on if `DUSTY_DEV` is set. Call it before `register` and
/// before serving anything.
pub fn init(io: std.Io, environ_map: *const std.process.Environ.Map) void {
    if (environ_map.get("DUSTY_DEV") == null) return;
    var bytes: [boot_id.len / 2]u8 = undefined;
    io.random(&bytes);
    boot_id = std.fmt.bytesToHex(bytes, .lower);
    enabled = true;
}

/// Adds the routes the pages load the script from and listen on, when
/// reloading is on.
pub fn register(router: anytype) void {
    if (!enabled) return;
    router.get(script_path, serveScript);
    router.get(reload_path, reload);
}

pub const ScriptOptions = struct {
    /// Put on the `<script>` tag, for a Content-Security-Policy that
    /// allows scripts by nonce.
    nonce: ?[]const u8 = null,
};

/// The `<script>` tag that reloads the page, or nothing when reloading is
/// off. Write it with `{f}`, or in a zt template with `{...}`.
pub fn script(options: ScriptOptions) Script {
    return .{ .options = options };
}

pub const Script = struct {
    options: ScriptOptions,

    pub fn formatHtml(self: Script, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!enabled) return;
        try w.writeAll("<script src=\"" ++ script_path ++ "\" defer");
        if (self.options.nonce) |nonce| {
            try w.writeAll(" nonce=\"");
            try writeAttribute(w, nonce);
            try w.writeAll("\"");
        }
        try w.print(" data-boot=\"{s}\"></script>", .{&boot_id});
    }

    pub fn format(self: Script, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.formatHtml(w);
    }
};

fn writeAttribute(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

fn serveScript(res: *Response) !void {
    try res.print(.js, "{s}", .{script_js});
}

fn reload(req: *Request, res: *Response) !void {
    req.setTimeout(.none);

    var buf: [128]u8 = undefined;
    var stream = try res.startEventStream(&buf);
    // Reconnects soon after the old process is gone.
    try stream.send(&boot_id, .{ .event = "boot", .retry = 200 });
    while (true) {
        try req.io.sleep(.fromSeconds(30), .awake);
        // A page that went away is only noticed on a write.
        try stream.send("", .{ .event = "ping" });
    }
}
