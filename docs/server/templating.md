# Templating

!!! warning "Draft"

    This page is a draft. Still to cover:

    - Compiled example project for zt, so the snippets are checked
    - Layouts and components in zt, HTML escaping
    - Using `assets.url` from templates
    - Walkthrough of examples/todo with htmx

Dusty has no templating language of its own. `res.render` works with anything that writes to a
`*std.Io.Writer`, and we recommend [zt](https://github.com/lalinsky/zt), which compiles templates to
Zig at build time.

Add it to the project, and generate the templates in `build.zig`:

```sh
$ zig fetch --save "git+https://github.com/lalinsky/zt#v0.2.1"
```

```zig
const zt = @import("zt");

const zt_dep = b.dependency("zt", .{
    .target = target,
    .optimize = optimize,
});
const templates = zt.addTemplates(b, zt_dep, &.{
    b.path("src/templates/pages.zt"),
});

exe.root_module.addImport("zt", zt_dep.module("zt"));
exe.step.dependOn(templates);
```

A template in `src/templates/pages.zt`:

```zig
pub templ UserPage(name: []const u8, admin: bool) {
    <html>
        <body>
            <h1>Hello, {name}</h1>
            if (admin) {
                <p>You are an admin.</p>
            }
        </body>
    </html>
}
```

zt turns it into `src/templates/pages.zig`, and the handler renders it with the arguments as a
tuple:

```zig
const pages = @import("templates/pages.zig");

fn showUser(name: http.Param("name", []const u8), res: *http.Response) !void {
    try res.render(.html, pages.UserPage, .{ name.value, false });
}
```

If the template fails halfway, what it wrote so far is thrown away, and the handler can still send
something else.

`res.render` also takes a plain function whose last parameter is the `*std.Io.Writer`. For
something small, `res.print(.html, "<p>Hello, {s}</p>", .{name})` is enough.

Templates link to [assets](static-files.md) with `assets.url("app.css")`.
[examples/todo](https://github.com/lalinsky/dusty/tree/main/examples/todo) is a complete app built
with zt, [pg.zig](https://github.com/lalinsky/pg.zig) and [htmx](https://htmx.org).
