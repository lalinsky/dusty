const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");
const pg = @import("pg");
const templates = @import("templates/fortunes.zig");

var dataset: ?[]const DatasetItem = null;
var pool: ?*pg.Pool = null;

const Rating = struct { score: i64, count: i64 };

const DatasetItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

const ResponseItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
    total: i64,
};

fn loadDataset(allocator: std.mem.Allocator, io: std.Io) void {
    const file = std.Io.Dir.cwd().openFile(io, "/data/dataset.json", .{}) catch return;
    defer file.close(io);

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var json_reader: std.json.Reader = .init(allocator, &reader.interface);
    dataset = std.json.parseFromTokenSourceLeaky([]const DatasetItem, allocator, &json_reader, .{ .allocate = .alloc_always }) catch return;
}

fn baseline(req: *http.Request, res: *http.Response) !void {
    var sum: i64 = 0;
    var it = req.query.iterator();
    while (it.next()) |entry| {
        sum += std.fmt.parseInt(i64, entry.value, 10) catch 0;
    }
    if (req.method == .post) {
        if (try req.body()) |b| {
            sum += std.fmt.parseInt(i64, b, 10) catch 0;
        }
    }
    try res.print(.text, "{d}", .{sum});
}

fn pipeline(res: *http.Response) !void {
    res.content_type = .text;
    res.body = "ok";
}

fn delay(req: *http.Request, ms: http.Path("ms", u32), res: *http.Response) !void {
    if (ms.value > 0) {
        try req.io.sleep(.fromMilliseconds(ms.value), .awake);
    }
    try res.print(.text, "{d}", .{ms.value});
}

fn jsonItems(
    req: *http.Request,
    count_param: http.Path("count", usize),
    m_param: http.Query("m", ?i64),
    res: *http.Response,
) !void {
    const items = dataset orelse {
        res.status = .service_unavailable;
        return;
    };

    const count = count_param.value;
    if (count < 1 or count > items.len) {
        res.status = .bad_request;
        return;
    }

    const m: i64 = m_param.value orelse 1;

    const resp_items = try req.arena.alloc(ResponseItem, count);
    for (items[0..count], 0..) |item, i| {
        resp_items[i] = .{
            .id = item.id,
            .name = item.name,
            .category = item.category,
            .price = item.price,
            .quantity = item.quantity,
            .active = item.active,
            .tags = item.tags,
            .rating = item.rating,
            .total = item.price * item.quantity * m,
        };
    }

    const payload = .{ .items = resp_items, .count = count };

    res.compress = true;
    try res.json(payload, .{});
}

const DbItem = struct {
    id: i32,
    name: []const u8,
    category: []const u8,
    price: i32,
    quantity: i32,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

const DbResponse = struct {
    items: []const DbItem,
    count: usize,
};

const empty_db_response: DbResponse = .{ .items = &.{}, .count = 0 };

fn asyncDb(
    req: *http.Request,
    min_param: http.Query("min", ?i32),
    max_param: http.Query("max", ?i32),
    limit_param: http.Query("limit", ?i32),
    res: *http.Response,
) !void {
    const p = pool orelse return res.json(empty_db_response, .{});

    const min = min_param.value orelse 10;
    const max = max_param.value orelse 50;
    const limit = std.math.clamp(limit_param.value orelse 50, 1, 50);

    var result = p.queryOpts(
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
        .{ min, max, limit },
        .{ .cache_name = "async_db" },
    ) catch return res.json(empty_db_response, .{});
    defer result.deinit();

    var items: std.ArrayList(DbItem) = .empty;
    while (try result.next()) |row| {
        const tags_json = try row.get([]const u8, 6);
        const tags = std.json.parseFromSliceLeaky([]const []const u8, req.arena, tags_json, .{ .allocate = .alloc_always }) catch &.{};

        try items.append(req.arena, DbItem{
            .id = try row.get(i32, 0),
            .name = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .category = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            .price = try row.get(i32, 3),
            .quantity = try row.get(i32, 4),
            .active = try row.get(bool, 5),
            .tags = tags,
            .rating = .{
                .score = try row.get(i32, 7),
                .count = try row.get(i32, 8),
            },
        });
    }

    try res.json(DbResponse{ .items = items.items, .count = items.items.len }, .{});
}

const Fortune = templates.Fortune;

fn fortuneLessThan(_: void, a: Fortune, b: Fortune) bool {
    return std.mem.lessThan(u8, a.message, b.message);
}

fn fortunes(req: *http.Request, res: *http.Response) !void {
    const p = pool orelse {
        res.status = .service_unavailable;
        return;
    };

    var result = try p.queryOpts("SELECT id, message FROM fortune", .{}, .{ .cache_name = "fortunes" });
    defer result.deinit();

    var list: std.ArrayList(Fortune) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .id = try row.get(i32, 0),
            .message = try req.arena.dupe(u8, try row.get([]const u8, 1)),
        });
    }
    try list.append(req.arena, .{ .id = 0, .message = "Additional fortune added at request time." });
    std.mem.sort(Fortune, list.items, {}, fortuneLessThan);

    try res.render(.html, templates.FortunesPage, .{list.items});
}

fn wsEcho(req: *http.Request, res: *http.Response) !void {
    var ws = try res.upgradeWebSocket(req) orelse {
        res.status = .not_found;
        return;
    };
    defer ws.deinit();
    ws.autoflush = false;
    while (true) {
        for (try ws.receiveMany()) |msg| {
            switch (msg.type) {
                .text, .binary => try ws.send(msg.type, msg.data),
                .close => return,
                else => {},
            }
        }
        try ws.flush();
    }
}

fn echoBody(req: *http.Request, res: *http.Response) !void {
    const body = try req.body() orelse "";
    try res.header("Content-Type", "application/octet-stream");
    res.body = body;
}

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();

    loadDataset(init.arena.allocator(), rt.io());

    if (init.environ_map.get("DATABASE_URL")) |url| {
        const uri = std.Uri.parse(url) catch @panic("invalid DATABASE_URL");
        const max_conn = if (init.environ_map.get("DATABASE_MAX_CONN")) |v|
            std.fmt.parseInt(u16, v, 10) catch 256
        else
            256;
        pool = pg.Pool.initUri(rt.io(), init.gpa, uri, .{
            .size = max_conn,
            .connect_on_init_count = 1,
        }) catch null;
    }

    const cert_path = init.environ_map.get("TLS_CERT") orelse "/certs/server.crt";
    const key_path = init.environ_map.get("TLS_KEY") orelse "/certs/server.key";
    const have_certs = blk: {
        std.Io.Dir.cwd().access(rt.io(), cert_path, .{}) catch break :blk false;
        std.Io.Dir.cwd().access(rt.io(), key_path, .{}) catch break :blk false;
        break :blk true;
    };
    const listeners = [_]http.Listener{
        .{ .address = .{ .ip = try std.Io.net.IpAddress.parse("0.0.0.0", 8080) } },
        .{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("0.0.0.0", 8081) },
            .tls = .{
                .certificate = .{ .file = .{ .cert_path = cert_path, .key_path = key_path } },
                .alpn_protocols = &.{"http/1.1"},
            },
        },
    };
    var server = http.Server(void).init(init.gpa, rt.io(), .{
        .listeners = if (have_certs) &listeners else listeners[0..1],
        .max_connections = 65_536,
    }, {});
    defer server.deinit();

    server.router.get("/baseline11", baseline);
    server.router.post("/baseline11", baseline);
    server.router.get("/baseline2", baseline);
    server.router.post("/baseline2", baseline);
    server.router.get("/pipeline", pipeline);
    server.router.get("/delay/:ms", delay);
    server.router.get("/json/:count", jsonItems);
    server.router.post("/echo", echoBody);
    server.router.get("/ws", wsEcho);
    server.router.get("/async-db", asyncDb);
    server.router.get("/fortunes", fortunes);

    // Mounted by the harness; absent when the server is run on its own.
    const static_dir: ?std.Io.Dir = std.Io.Dir.cwd().openDir(rt.io(), "/data/static", .{}) catch null;
    defer if (static_dir) |dir| dir.close(rt.io());
    if (static_dir) |dir| {
        server.router.static("/static", dir, .{ .precompressed = &.{ .br, .gzip } });
    }

    try server.run();
}
