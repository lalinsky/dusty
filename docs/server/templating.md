# Templating

Dusty has no templating language of its own. [`res.render`](../../apidocs/#http.Response.render)
takes a zt template or any function that writes to a `*std.Io.Writer`. We recommend
[zt](https://github.com/lalinsky/zt), which compiles templates to Zig at build time.

The examples on this page come from
[examples/todo](https://github.com/lalinsky/dusty/tree/main/examples/todo), a to-do list app built
with zt, [pg.zig](https://github.com/lalinsky/pg.zig) and [htmx](https://htmx.org).

## Setup

Add zt to the project:

```sh
$ zig fetch --save "git+https://github.com/lalinsky/zt#v0.2.1"
```

Then generate the templates in `build.zig`, and give the executable the `zt` module:

```zig
const zt = @import("zt");

const zt_dep = b.dependency("zt", .{
    .target = target,
    .optimize = optimize,
});
const templates = zt.addTemplates(b, zt_dep, &.{
    b.path("src/templates/todo.zt"),
});

exe.root_module.addImport("zt", zt_dep.module("zt"));
exe.step.dependOn(templates);
```

zt turns each `.zt` file into a `.zig` file next to it, here `src/templates/todo.zig`.

## Templates

A template is a `templ` declaration with parameters and an HTML body. Values go in with `{...}`.
`for` and `if` work like they do in Zig. `@TodoItem(todo)` includes another template:

```zig
--8<-- "examples/todo/src/templates/todo.zt:items"
```

Text from `{...}` is HTML-escaped, so a to-do titled `<script>` shows up as text. An attribute set
to `null`, like `class` on a to-do that isn't done, is left out.

A layout puts other content inside it with `@children`:

```zig
--8<-- "examples/todo/src/templates/todo.zt:layout"
```

A page wraps its content in `@Layout("Todos") { ... }`. What's in the braces goes where `@children`
is. See the [zt documentation](https://github.com/lalinsky/zt) for the rest of the language.

## Rendering

The handler imports the generated file:

```zig
const templates = @import("templates/todo.zig");
```

Then it passes a template and its arguments, as a tuple, to `res.render`:

```zig
--8<-- "examples/todo/src/main.zig:edit"
```

The first argument is the content type. If the template returns an error, its output is thrown away.
The handler can still send a different response.

`res.render` works with any function whose last parameter is a `*std.Io.Writer`. It calls the
function with the arguments from the tuple, followed by the writer. A type with a
`render(args, writer)` function works too. So you can also write templates by hand, or use another
template library that writes to a `std.Io.Writer`.

## Next Steps

- [Static Files and Assets](static-files.md) covers `assets.url` and serving the files.
- [Server-Sent Events](sse.md) covers pushing updates to the page, which the todo example uses to
  keep several tabs in sync.
