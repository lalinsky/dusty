# Static Files and Assets

Dusty serves files from a directory on disk, and files compiled into the binary, either one at a
time or a whole directory of assets with cache-busting URLs.

## Files from a Directory

`router.static` serves a directory under a prefix:

```zig
--8<-- "examples/static_files.zig:static"
```

A request for `/static/style.css` gets `style.css` from the directory, with the content type from
its extension. A request for the directory gets its `index.html`. `/static` redirects to `/static/`.
The directory has to stay open while the server runs.

A path with `..` in it gets a 404. So does a dotfile like `/static/.env`, unless you set
`.hide_dotfiles = false`.

Responses have `ETag` and `Last-Modified` headers. A conditional request for an unchanged file gets
a 304, and a `Range` request gets the part it asked for. `.cache_control` is sent as
`Cache-Control`.

With `.precompressed = &.{ .br, .gzip }`, a compressed copy next to a file, like `style.css.br`, is
sent in place of `style.css` to clients that accept it. The plain file has to exist too.

See [`http.StaticOptions`](../../apidocs/#http.StaticOptions) for the other options.

## Embedded Files

`router.embedded` serves one file that is compiled into the binary, usually with `@embedFile`:

```zig
--8<-- "examples/static_files.zig:embedded"
```

The content type comes from the path's extension, unless `.content_type` says otherwise. The
`ETag` is a hash of the content. Compressed copies can be passed as `.br`, `.zstd` and `.gzip`.

## Assets

`addAssets` in `build.zig` turns a directory into a module that embeds its files. This is from
[examples/todo](https://github.com/lalinsky/dusty/tree/main/examples/todo):

```zig
--8<-- "examples/todo/build.zig:assets"
```

Here `dusty` is `@import("dusty")` at the top of `build.zig`, and `dusty_dep` is the dependency from
`b.dependency("dusty", ...)`. The files are served under `/assets`. Set `.prefix` to change that.

Templates link to the files with `assets.url`, which adds a hash of the content to the URL, like
`/assets/app.css?v=6ec8ea7d`:

```zig
--8<-- "examples/todo/src/templates/todo.zt:layout"
```

A name that isn't in the directory is a compile error.

`assets.register` adds the routes that serve them:

```zig
--8<-- "examples/todo/src/main.zig:register"
```

A request with the current hash is answered with `Cache-Control: public, max-age=31536000,
immutable`, so browsers keep it for good. When the file changes, so does its URL. Any other request
gets the current file with `no-cache`, so a page that was open during a deploy still gets its
styles. A compressed copy next to a file, like `app.css.br`, is served to clients that accept it.

## Next Steps

- [Templating](templating.md) covers the templates that link to the assets.
- [Deployment](deployment.md) covers running the server in production.
