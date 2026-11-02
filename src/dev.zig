//! Reloads open pages after the server restarts, while it runs under
//! `addRunServer` from build.zig, which sets `DUSTY_DEV`. Otherwise it's all
//! off: `register` adds no route and `script` is empty.
//!
//! ```zig
//! http.dev.init(io, init.environ_map);
//! http.dev.register(&server.router);
//! ```
//!
//! and in the page layout, `{!http.dev.script()}` before `</body>`.

const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const reload_path = "/_dusty/reload";

var enabled = false;
var script_buf: [script_template.len + 16]u8 = undefined;
var script_len: usize = 0;

// Each process has its own id, so a page can tell that the server it
// reconnected to is not the one that rendered it.
var boot_id: [16]u8 = undefined;

const script_template =
    \\<script data-boot="{s}">
    \\(() => {{
    \\    if (window.dustyReload) return;
    \\    window.dustyReload = true;
    \\    const boot = document.currentScript.dataset.boot;
    \\    let events = null;
    \\    const connect = () => {{
    \\        events = new EventSource("
++ reload_path ++
    \\");
    \\        events.addEventListener("boot", (e) => {{
    \\            if (e.data !== boot) location.reload();
    \\        }});
    \\    }};
    \\    // Hidden tabs let go of their connection, since browsers allow only
    \\    // a few per host over HTTP/1.1.
    \\    document.addEventListener("visibilitychange", () => {{
    \\        if (document.hidden) {{
    \\            events?.close();
    \\            events = null;
    \\        }} else if (!events) {{
    \\            connect();
    \\        }}
    \\    }});
    \\    if (!document.hidden) connect();
    \\}})();
    \\</script>
;

/// Turns reloading on if `DUSTY_DEV` is set. Call it before `register` and
/// before serving anything.
pub fn init(io: std.Io, environ_map: *const std.process.Environ.Map) void {
    if (environ_map.get("DUSTY_DEV") == null) return;
    var bytes: [boot_id.len / 2]u8 = undefined;
    io.random(&bytes);
    boot_id = std.fmt.bytesToHex(bytes, .lower);
    script_len = (std.fmt.bufPrint(&script_buf, script_template, .{&boot_id}) catch unreachable).len;
    enabled = true;
}

/// Adds the route the pages listen on, when reloading is on.
pub fn register(router: anytype) void {
    if (enabled) router.get(reload_path, reload);
}

/// The script that reloads the page, or nothing when reloading is off.
pub fn script() []const u8 {
    return script_buf[0..script_len];
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
