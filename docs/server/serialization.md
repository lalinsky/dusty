# Serialization

`res.encode` writes a value as the body with a serializer's write-to-writer function. It tells the
function's parameters apart by type, so most libraries work with it as they are. We recommend
[json.zig](https://github.com/lalinsky/json.zig) for JSON and
[msgpack.zig](https://github.com/lalinsky/msgpack.zig) for MessagePack. Both are specialized to
your types at compile time.

```zig
const json = @import("json");
const msgpack = @import("msgpack");

fn updateUser(req: *http.Request, res: *http.Response) !void {
    const input = try json.decodeFromSliceLeaky(UserInput, req.arena, try req.body() orelse "", .{});
    const user = try saveUser(input);
    try res.encode(.json, json.encode, user);
}

fn getUser(id: http.Param("id", u64), res: *http.Response) !void {
    const user = try loadUser(id.value);
    try res.encode(.msgpack, msgpack.encode, user);
}
```

The function gets the `*std.Io.Writer` for the body, the value, and, if it asks for one, a
`std.mem.Allocator`, which is the request's arena. That also fits
[serde.zig](https://github.com/OrlovEvgeny/serde.zig)'s `toWriter`. If the encoding fails, what it
wrote so far is thrown away, and the handler can still send something else.

Unlike `std.json`, json.zig leaves out optional fields that are null, unless the type says
otherwise.

## std.json

`res.json(value, .{})` and `req.json(T)` use `std.json`, so they work without another dependency,
and take any type, `std.json.Value` included. json.zig is considerably faster at both encoding and
decoding. `req.json` returns null when the request has no body.
