const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");
const json = @import("json");
const pg = @import("pg");
const templates = @import("templates/todo.zig");

const Todo = templates.Todo;
const Filter = templates.Filter;

const schema = [_][]const u8{
    \\CREATE TABLE IF NOT EXISTS todos (
    \\    id serial PRIMARY KEY,
    \\    title text NOT NULL,
    \\    done boolean NOT NULL DEFAULT false
    \\)
    ,
    \\CREATE OR REPLACE FUNCTION notify_todos() RETURNS trigger LANGUAGE plpgsql AS $$
    \\BEGIN
    \\    PERFORM pg_notify('todos', '');
    \\    RETURN NULL;
    \\END
    \\$$
    ,
    \\CREATE OR REPLACE TRIGGER todos_changed
    \\AFTER INSERT OR UPDATE OR DELETE ON todos
    \\FOR EACH STATEMENT EXECUTE FUNCTION notify_todos()
    ,
};

/// A version number bumped on every change, which any number of tasks can
/// wait to move past the version they last saw.
const Changes = struct {
    version: std.atomic.Value(u32),

    /// Starts at a random version, so a page rendered before a restart
    /// doesn't look current to the new process.
    fn init(io: std.Io) Changes {
        var start: u32 = undefined;
        io.random(std.mem.asBytes(&start));
        return .{ .version = .init(start) };
    }

    fn current(self: *const Changes) u32 {
        return self.version.load(.acquire);
    }

    fn bump(self: *Changes, io: std.Io) void {
        _ = self.version.fetchAdd(1, .release);
        io.futexWake(u32, &self.version.raw, std.math.maxInt(u32));
    }

    /// Returns the current version once it differs from `seen`, or `seen`
    /// itself if the timeout passes first.
    fn wait(self: *Changes, io: std.Io, seen: u32, timeout: std.Io.Duration) std.Io.Cancelable!u32 {
        try io.futexWaitTimeout(u32, &self.version.raw, seen, .{
            .duration = .{ .raw = timeout, .clock = .awake },
        });
        return self.current();
    }
};

const App = struct {
    pool: *pg.Pool,
    changes: Changes,

    fn queryTodos(self: *App, arena: std.mem.Allocator, sql: []const u8, args: anytype) ![]Todo {
        var result = try self.pool.query(sql, args);
        defer result.deinit();

        var list: std.ArrayList(Todo) = .empty;
        while (try result.next()) |row| {
            try list.append(arena, .{
                .id = try row.get(i32, 0),
                .title = try arena.dupe(u8, try row.get([]const u8, 1)),
                .done = try row.get(bool, 2),
            });
        }
        return list.items;
    }

    fn queryTodo(self: *App, arena: std.mem.Allocator, sql: []const u8, args: anytype) !?Todo {
        const list = try self.queryTodos(arena, sql, args);
        return if (list.len > 0) list[0] else null;
    }

    fn search(self: *App, arena: std.mem.Allocator, filter: Filter, q: []const u8) ![]Todo {
        return self.queryTodos(arena,
            \\SELECT id, title, done FROM todos
            \\WHERE ($1 = 'all' OR done = ($1 = 'completed'))
            \\  AND strpos(lower(title), lower($2)) > 0
            \\ORDER BY id
        , .{ @tagName(filter), q });
    }

    fn countActive(self: *App) !i64 {
        // Not `pool.row`, whose deinit can fail and so can't be deferred.
        var result = try self.pool.query("SELECT count(*) FROM todos WHERE NOT done", .{});
        defer result.deinit();
        const row = try result.next() orelse return error.NoRows;
        const count = try row.get(i64, 0);
        try result.drain();
        return count;
    }
};

fn index(app: *App, req: *http.Request, res: *http.Response) !void {
    // htmx sends "partial" when it swaps into an element, and "full" for
    // boosted navigation, which replaces the whole body.
    const partial = std.mem.eql(u8, req.headers.get("HX-Request-Type") orelse "", "partial");
    try res.header("Vary", "HX-Request-Type");
    if (partial) return renderList(app, req, res);

    // Read before the query, so a change made while it runs is not missed.
    const version = app.changes.current();
    const filter, const q = try listParams(req);
    const todos = try app.search(req.arena, filter, q);
    try res.render(.html, templates.Page, .{ filter, q, todos, try app.countActive(), version });
}

fn create(app: *App, req: *http.Request, res: *http.Response) !void {
    const form = try req.formData();
    const title = std.mem.trim(u8, form.get("title") orelse "", &std.ascii.whitespace);
    if (title.len > 0) {
        _ = try app.pool.exec("INSERT INTO todos (title) VALUES ($1)", .{title});
    }
    // The whole list, since the new item may not match the filter or search.
    try renderList(app, req, res);
}

fn toggle(app: *App, req: *http.Request, res: *http.Response) !void {
    const id = req.params.getInt(i32, "id") orelse return notFound(res);
    const todo = try app.queryTodo(req.arena, "UPDATE todos SET done = NOT done WHERE id = $1 RETURNING id, title, done", .{id}) orelse return notFound(res);
    try res.render(.html, templates.TodoItemWithCount, .{ todo, try app.countActive() });
}

fn edit(app: *App, req: *http.Request, res: *http.Response) !void {
    const id = req.params.getInt(i32, "id") orelse return notFound(res);
    const todo = try app.queryTodo(req.arena, "SELECT id, title, done FROM todos WHERE id = $1", .{id}) orelse return notFound(res);
    try res.render(.html, templates.TodoEdit, .{todo});
}

fn update(app: *App, req: *http.Request, res: *http.Response) !void {
    const id = req.params.getInt(i32, "id") orelse return notFound(res);
    const form = try req.formData();
    const title = std.mem.trim(u8, form.get("title") orelse "", &std.ascii.whitespace);

    // An emptied title keeps the old one.
    _ = try app.pool.exec("UPDATE todos SET title = COALESCE(NULLIF($2, ''), title) WHERE id = $1", .{ id, title });
    // The whole list, since changes from other tabs are not reloaded while
    // editing. It's also right when the item was deleted meanwhile.
    try renderList(app, req, res);
}

fn delete(app: *App, req: *http.Request, res: *http.Response) !void {
    const id = req.params.getInt(i32, "id") orelse return notFound(res);
    const deleted = try app.pool.exec("DELETE FROM todos WHERE id = $1", .{id});
    if (deleted != 1) return notFound(res);
    try res.render(.html, templates.Count, .{ try app.countActive(), true });
}

fn api(app: *App, req: *http.Request, res: *http.Response) !void {
    const todos = try app.queryTodos(req.arena, "SELECT id, title, done FROM todos ORDER BY id", .{});
    try res.encode(.json, json.encode, todos);
}

fn events(app: *App, req: *http.Request, res: *http.Response) !void {
    req.setTimeout(.none);

    var buf: [256]u8 = undefined;
    var stream = try res.startEventStream(&buf);

    // Event ids are versions. A page connects with the version it was
    // rendered at, and htmx reconnects with the last id it saw after its tab
    // was hidden. Either one being stale means the tab missed changes.
    var seen = app.changes.current();
    const since = req.headers.get("Last-Event-ID") orelse req.query.get("since") orelse "";
    const last_seen = std.fmt.parseInt(u32, since, 10) catch seen;
    try sendVersion(&stream, if (last_seen != seen) "changed" else "ping", seen);

    while (true) {
        const current = try app.changes.wait(req.io, seen, .fromSeconds(30));
        if (current == seen) {
            // A client that went away is only noticed on a write.
            try sendVersion(&stream, "ping", seen);
            continue;
        }
        seen = current;
        try sendVersion(&stream, "changed", seen);
    }
}

fn sendVersion(stream: *http.EventStream, event: []const u8, version: u32) !void {
    var buf: [10]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{d}", .{version}) catch unreachable;
    try stream.send("", .{ .event = event, .id = id });
}

fn renderList(app: *App, req: *http.Request, res: *http.Response) !void {
    const filter, const q = try listParams(req);
    const todos = try app.search(req.arena, filter, q);
    try res.render(.html, templates.TodoList, .{ todos, try app.countActive() });
}

/// The list's filter and search, which htmx sends in the query string of a
/// GET and in the body of the other methods.
fn listParams(req: *http.Request) !struct { Filter, []const u8 } {
    const filter, const q = if (req.method == .get)
        .{ req.query.get("filter"), req.query.get("q") }
    else blk: {
        const form = try req.formData();
        break :blk .{ form.get("filter"), form.get("q") };
    };
    return .{ std.meta.stringToEnum(Filter, filter orelse "") orelse .all, q orelse "" };
}

fn notFound(res: *http.Response) void {
    res.status = .not_found;
}

/// Bumps `app.changes` on every Postgres notification, reconnecting when the
/// listening connection is lost.
fn listen(app: *App, io: std.Io) !void {
    while (true) {
        watch(app, io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => std.log.err("listening for changes failed: {t}", .{err}),
        };
        try io.sleep(.fromSeconds(1), .awake);
    }
}

fn watch(app: *App, io: std.Io) !void {
    var listener = try app.pool.newListener();
    defer listener.deinit();

    try listener.listen("todos", .{});
    // Whatever changed while we were not listening.
    app.changes.bump(io);

    while (listener.next()) |_| {
        app.changes.bump(io);
    }
    return switch (listener.err orelse return error.ListenerClosed) {
        .err => |err| err,
        .pg => |pg_err| {
            std.log.err("postgres: {s}", .{pg_err.message});
            return error.PG;
        },
    };
}

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    const url = init.environ_map.get("DATABASE_URL") orelse "postgres://todo:todo@127.0.0.1:5432/todo";
    const pool = try pg.Pool.initUri(io, init.gpa, try std.Uri.parse(url), .{ .size = 16 });
    defer pool.deinit();

    for (schema) |sql| {
        _ = try pool.exec(sql, .{});
    }

    var app: App = .{ .pool = pool, .changes = .init(io) };

    var public = try std.Io.Dir.cwd().openDir(io, "public", .{});
    defer public.close(io);

    const addr: http.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) };
    var server = http.Server(App).init(init.gpa, io, .{
        .listeners = &.{.{ .address = addr }},
    }, &app);
    defer server.deinit();

    server.router.get("/", index);
    server.router.post("/todos", create);
    server.router.patch("/todos/:id/toggle", toggle);
    server.router.get("/todos/:id/edit", edit);
    server.router.put("/todos/:id", update);
    server.router.delete("/todos/:id", delete);
    server.router.get("/events", events);
    server.router.get("/api/todos", api);
    server.router.static("/assets", public, .{});

    var listen_task = try io.concurrent(listen, .{ &app, io });
    defer listen_task.cancel(io) catch {};

    std.log.info("Todo app running at http://127.0.0.1:8080", .{});
    try server.run();
}
