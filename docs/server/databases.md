# Databases

Dusty doesn't come with a database layer. You use a client library for your database, create its
connection pool when the program starts, and keep the pool in the app, where every handler can
reach it.

The examples on this page use PostgreSQL with [pg.zig](https://github.com/lalinsky/pg.zig), and
come from [examples/todo](https://github.com/lalinsky/dusty/tree/main/examples/todo). Other
[database clients](#database-clients) fit in the same way.

## Setup

Add pg.zig to the project:

```sh
$ zig fetch --save "git+https://github.com/lalinsky/pg.zig#v2026.10.25.0"
```

And import the module in `build.zig`:

```zig
const pg = b.dependency("pg", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pg", pg.module("pg"));
```

## The Pool in the App

The app holds the pool:

```zig
const App = struct {
    pool: *pg.Pool,
};
```

`main` creates the pool with the same `io` as the server:

```zig
--8<-- "examples/todo/src/main.zig:pool"
```

And then the app and the server:

```zig
var app: App = .{ .pool = pool };

var server = http.Server(App).init(init.gpa, io, .{}, &app);
defer server.deinit();
```

With the same `io`, the database calls run on the same I/O as the server. On
[zio](deployment.md#running-on-zio), a handler waiting for the database doesn't block a thread. The
pool is created before the server, so it's closed after the server.

## Queries in Handlers

A handler takes `*App` and runs its queries on `app.pool`:

```zig
fn listTodos(app: *App, res: *http.Response) !void {
    var result = try app.pool.query("SELECT id, title FROM todos ORDER BY id", .{});
    defer result.deinit();

    var body = res.writer();
    while (try result.next()) |row| {
        const id = try row.get(i32, 0);
        const title = try row.get([]const u8, 1);
        try body.interface.print("{d}: {s}\n", .{ id, title });
    }
    try body.end();
    res.content_type = .text;
}
```

All requests share the one pool, and they can run at the same time. Each query takes a connection
from the pool and gives it back when it's done. When all the connections are busy, a query waits
until one is free, and after 10 seconds it fails with `error.Timeout`. Make the pool about as big as
the number of requests you expect to use the database at once.

See the [pg.zig documentation](https://github.com/lalinsky/pg.zig) for the rest of its API.

## Errors

A query error that the handler returns becomes a 500, like any other error. A handler can return
`error.NotFound` when the row it's looking for doesn't exist:

```zig
--8<-- "examples/todo/src/main.zig:exec"
```

See [Handlers](handlers.md#errors) for how errors become responses, and how to change the error
pages.

## Queries in the App

As the app grows, you can move the queries into methods on the app, and keep the handlers short.
The todo app has a method that reads to-dos into a list:

```zig
--8<-- "examples/todo/src/main.zig:query"
```

The caller passes `req.arena`, so the list lives until the response is sent. The title is copied,
because a string from `row.get` is only valid until the next row. `queryTodo` returns the first
to-do from the same list, and a handler loads a to-do with one call:

```zig
--8<-- "examples/todo/src/main.zig:edit"
```

## Database Clients

These clients use `std.Io`:

- [pg.zig](https://github.com/lalinsky/pg.zig) for PostgreSQL
- [myzql](https://github.com/speed2exe/myzql) for MySQL
- [redis.zig](https://github.com/lalinsky/redis.zig) for Redis
- [memcached.zig](https://github.com/lalinsky/memcached.zig) for Memcached

## Next Steps

- [Deployment](deployment.md) covers running the server and the database client on zio.
- [Handlers](handlers.md) covers how errors become responses.
