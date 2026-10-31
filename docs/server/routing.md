# Routing

Every server has a [router](../../apidocs/#http.Router), `server.router`. You register a handler for a method and a path, and the
router picks a handler for each request.

```zig
--8<-- "examples/routing.zig:routes"
```

The handlers for these routes:

```zig
--8<-- "examples/routing.zig:handlers"
```

There is a function for each method: `get`, `head`, `post`, `put`, `delete`, `patch`, `options` and
`query`. A request whose method has no route for its path gets a 404, even if other methods have
routes there. An [`any` route](#other-routes) can answer it instead. A `HEAD` request with no route
of its own is answered by the `GET` route, without the body.

Empty segments in the request path are skipped, so `/users/` and `//users` both match `/users`.

## Path Parameters

A segment starting with `:` matches any single segment of the request path. To get the value, the
handler takes an [`http.Param`](../../apidocs/#http.Param) with the parameter's name and the type to parse it as. `getUser` takes
`http.Param("id", u64)`, and `id.value` is the number. If the value doesn't parse, the route
doesn't match, so `/users/abc` gets a 404.

`http.Param` can parse these types:

- Integers
- Enums, from the tag name
- `bool`, from `true` or `false`
- `[]const u8`, the decoded string
- Any type with `pub fn parseParam([]const u8) ?T`

An enum limits a segment to a fixed set of values:

```zig
--8<-- "examples/routing.zig:enum"
```

With `server.router.get("/docs/:lang", getDocs)`, `/docs/de` works and `/docs/fr` is a 404.

For anything else, write a type with `parseParam`. It returns null for a value it doesn't accept:

```zig
--8<-- "examples/routing.zig:slug"
```

The name in `http.Param` has to be in the route's path. If it isn't, or a handler takes the same
name twice, you get a compile error.

You can also read the parameters from the request, as strings. With
`server.router.get("/orders/:id", getOrder)`:

```zig
--8<-- "examples/routing.zig:raw"
```

[`req.params.get`](../../apidocs/#http.Params) returns null for a name the route doesn't have, which is why there is a `.?`.
Here the route matches any value of `:id`, and the handler gets it without parsing. This is what
`http.Param` with `[]const u8` gives you too. `req.params` is handy when the code that reads the
parameter only has the request, like [middleware](middleware.md).

## Wildcards

A segment starting with `*` matches the rest of the path:

```zig
--8<-- "examples/routing.zig:wildcard_route"
```

```zig
--8<-- "examples/routing.zig:wildcard"
```

`/files/a/b.txt` gives `path` the value `a/b.txt`. A wildcard needs at least one segment, so `/files`
doesn't match this route.

## Which Route Wins

When more than one route could match a request, a literal segment wins over a parameter, and a
parameter wins over a wildcard. The order the routes were registered in doesn't matter. In the first
example, `/users/me` goes to `getCurrentUser`, even though `/users/:id` was registered before it.

The router compares one segment at a time. If the more specific choice doesn't match the rest of
the path, the router goes back and tries the less specific one.

## Percent-Encoding

The request path is split into segments at each `/`, and then each segment is decoded. A `%2F` is
a slash inside one segment, and doesn't split it in two. `/files/a%2Fb` gives the wildcard above
the value `a/b`.

## Middleware

[Middleware](middleware.md) runs around the handlers. You create it with `server.middleware`, from
its type and its configuration, and attach it to the router:

```zig
--8<-- "examples/routing.zig:middleware"
```

A route gets the router's middleware when it's registered, so set `server.router.middlewares`
before registering the routes. Routes registered before that don't get it. For middleware on only
some of the routes, use a group.

## Groups

A group puts a prefix and middleware in front of a set of routes:

```zig
--8<-- "examples/routing.zig:group"
```

This registers `GET /api/v1/status`. The second argument is the group's own middleware, which runs
after the router's. This group doesn't have any.

A group can have groups of its own, with `api.group("/admin", ...)`. Their prefixes are joined,
and the inner group's middleware runs after the outer group's. `group(null, ...)` adds middleware
without a prefix, which is also how you attach middleware to a single route.

## Other Routes

`any` registers a route that matches every method:

```zig
--8<-- "examples/routing.zig:any"
```

The router tries `any` routes last, when nothing registered for the request's method matches. Here
it answers requests that no other route takes, so a `DELETE /users` gets this handler.

`router.static` serves a directory of files, and `router.embedded` serves a file compiled into the
binary. See [Static Files and Assets](static-files.md).

## Conflicts

Some combinations of routes can't be told apart, and registering the second route of such a
pair panics:

- Two routes for the same method that match the same paths, like `/users/:id` registered twice.
- A route for one method and an `any` route that both match some path, when the method's route is
  not the more specific one. `GET /users/:id` and `any("/users/me")` can't be registered together.
  `/users/me` matches both, and the `GET` route is the less specific one.

## The Matched Route

`req.route` is the route that matched, or null if none did. It's an
[`http.RouteInfo`](../../apidocs/#http.RouteInfo), and `req.route.?.path` is the pattern the route
was registered with, group prefix included, like `/users/:id`. Use it in logs and metrics instead
of the request path, which would give a separate entry for every user.

## Next Steps

- [Middleware](middleware.md) covers writing middleware and the ones that come with Dusty.
- [Handlers](handlers.md) lists everything a handler can take, including query parameters and
  headers.
