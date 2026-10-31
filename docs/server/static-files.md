# Static Files and Assets

!!! warning "Draft"

    This page is a draft. Still to cover:

    - `StaticOptions`: `index`, `precompressed`, `hide_dotfiles`, `resolve_beneath`
    - Path traversal protection
    - `embedded` options
    - `addAssets` setup in `build.zig`, `assets.url` and `assets.register`
    - Caching: `ETag`, `Last-Modified`, `Cache-Control`

`router.static` serves a directory from disk under a prefix:

```zig
server.router.static("/static", dir, .{
    .precompressed = &.{ .br, .gzip },
});
```

Responses have an `ETag` and `Last-Modified`, and conditional and `Range` requests are handled. With
`.precompressed`, a compressed copy like `app.css.br` is sent in place of `app.css` to clients that
accept it. The plain file has to exist too.

`router.embedded` serves a single file compiled into the binary, and `addAssets` in `build.zig`
embeds a whole directory. `assets.url("app.css")` gives a URL with a hash of the content in it, and
a request for that URL is answered with `Cache-Control: public, max-age=31536000, immutable`.
`assets.register(&server.router)` serves the whole bundle.
