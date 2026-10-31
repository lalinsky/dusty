# Serialization

[`res.encode`](../../apidocs/#http.Response.encode) writes a value as the response body, using a
serializer's function that writes to a `std.Io.Writer`. We recommend
[json.zig](https://github.com/lalinsky/json.zig) for JSON and
[msgpack.zig](https://github.com/lalinsky/msgpack.zig) for MessagePack. Both generate the code for
your types at compile time.

Add them to the project:

```sh
$ zig fetch --save "git+https://github.com/lalinsky/json.zig#v0.2.0"
$ zig fetch --save "git+https://github.com/lalinsky/msgpack.zig#v0.10.0"
```

And import the modules in `build.zig`, the same way as Dusty:

```zig
const json = b.dependency("json", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("json", json.module("json"));

const msgpack = b.dependency("msgpack", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("msgpack", msgpack.module("msgpack"));
```

## Encoding

This handler from [examples/todo](https://github.com/lalinsky/dusty/tree/main/examples/todo) sends
the list of to-dos as JSON:

```zig
--8<-- "examples/todo/src/main.zig:api"
```

The first argument is the content type, then the encode function, then the value. `res.encode` tells
the function's parameters apart by their types. It passes the `*std.Io.Writer` for the body, the
value, and a `std.mem.Allocator` if the function takes one. json.zig's and msgpack.zig's `encode`
work as they are. So does [serde.zig](https://github.com/OrlovEvgeny/serde.zig)'s `toWriter`.

If encoding fails, what it wrote is thrown away. The handler can still send something else.

## Decoding

To decode a JSON body, pass it to json.zig's `decodeFromSliceLeaky` with `req.arena` as the
allocator:

```zig
const UserInput = struct {
    name: []const u8,
    email: ?[]const u8 = null,
};

fn updateUser(id: http.Param("id", u64), req: *http.Request, res: *http.Response) !void {
    const body = try req.body() orelse "";
    const input = json.decodeFromSliceLeaky(UserInput, req.arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            res.status = .bad_request;
            return res.print(.text, "Invalid JSON: {t}\n", .{err});
        },
    };
    const user = try saveUser(id.value, input);
    try res.encode(.json, json.encode, user);
}
```

A body that isn't valid JSON, or doesn't match the type, gets a 400 with the reason. Unknown fields
are rejected by default. The json.zig documentation shows how to skip them.

## JSON or MessagePack

A handler can pick the format from the request's `Accept` header:

```zig
fn getUser(
    id: http.Param("id", u64),
    accept: http.Header("Accept", ?[]const u8),
    res: *http.Response,
) !void {
    const user = try loadUser(id.value);
    const wants_msgpack = std.mem.indexOf(u8, accept.value orelse "", "msgpack") != null;
    if (wants_msgpack) {
        try res.encode(.msgpack, msgpack.encode, user);
    } else {
        try res.encode(.json, json.encode, user);
    }
}
```

`.msgpack` sends the body as `application/vnd.msgpack`.

## std.json

`res.json(value, .{})` and `req.json(T)` use `std.json`, so they work without another dependency.
They also work with `std.json.Value`, which json.zig doesn't have. json.zig is much faster,
especially at decoding. Unlike `std.json`, it leaves out optional fields that are null.

## Next Steps

- [Requests](requests.md) covers reading the body in other ways.
- [Middleware](middleware.md) covers code that runs around the handlers.
