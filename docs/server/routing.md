# Routing

!!! warning "Draft"

    This page is a draft. Still to cover:

    - `http.Param` types: integers, enums, `bool`, `[]const u8`, custom `parseParam`
    - A value that doesn't parse means no match, so another route or a 404
    - Conflicting routes panic at startup
    - All the method functions, including `query`, and `any`
    - Nested groups and `Group(prefix)`
    - URL decoding of path segments, trailing slashes

Every server has a router, `server.router`. You register a handler for a method and a path, and
the router picks one for each request.

```zig
server.router.get("/users", listUsers);
server.router.post("/users", createUser);
server.router.get("/users/:id", getUser);
server.router.get("/files/*path", getFile);
```

`:id` matches any single path segment, and the handler gets it with `req.params.get("id")`.
`*path` matches the rest of the path. When more than one
route could match, a literal segment wins over a parameter, and a parameter wins over a wildcard.

A HEAD request with no route of its own is answered by the GET route, without the body. Routes
registered with `any` match every method, and are tried when nothing else matches.

A group puts a prefix and middleware in front of a set of routes:

```zig
const api = server.router.group("/api", &.{auth});
api.get("/users", listUsers);
```

`group(null, ...)` adds middleware without a prefix, and a group can have groups of its own.
