# Handlers

!!! warning "Draft"

    This page is a draft. Still to cover:

    - Full list of what a handler can take, and custom injected types
    - App state is shared by all connections at once, so it has to be safe for concurrent use
    - Signatures of `uncaughtError` and `notFound`
    - `req.setTimeout` for handlers that need longer than the request timeout

A handler is a function that gets the request and fills in the response:

```zig
fn getUser(app: *App, req: *http.Request, res: *http.Response) !void {
    ...
}
```

It declares only the parameters it uses, in any order, and each one is filled in by its type:
`*App` (the pointer you passed to `http.Server(App).init`), `*http.Request`, `*http.Response` and
`*App.RequestContext`. The return type is `void` or `!void`.

An error from a handler becomes a 500. Errors reading the body become a 400, 413 or 415, and
`error.NotFound` gives the same 404 as a path with no route. To answer errors yourself, declare
`uncaughtError` on the app, and declare `notFound` to replace the default 404.
