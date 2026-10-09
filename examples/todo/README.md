# Todo app

A small web app built with dusty, [zt](https://github.com/lalinsky/zt) templates,
[pg.zig](https://github.com/lalinsky/pg.zig) and [htmx](https://htmx.org) 4. The page is
rendered on the server and htmx swaps in HTML fragments, so it behaves like a single-page app
without any application JavaScript.

Changes are pushed to every open tab: a Postgres trigger runs `NOTIFY todos` on each change,
the server holds one `LISTEN` connection, and each browser is subscribed to `/events`, an SSE
stream that tells htmx to reload the list.

## Running

```sh
docker compose up -d
zig build run
```

Then open http://127.0.0.1:8080 in two windows. The server connects to
`postgres://todo:todo@127.0.0.1:5432/todo` unless `DATABASE_URL` says otherwise, and creates
its table on startup, which needs Postgres 14 or newer.

## What it shows

- `res.render` with zt: `GET /` renders the whole page, or only the list when htmx asks for a
  fragment (`HX-Request-Type: partial`). Boosted navigation asks for the whole page.
- Adding or renaming a todo answers with the whole list, filtered and searched like the page.
  Toggling answers with just that item, deleting with nothing, and both update the item counter
  out of band.
- `router.embedded` for the stylesheet, compiled into the binary with `@embedFile`.
- `res.startEventStream` waiting on a change counter that the `LISTEN` task bumps.
- `res.encode` with json.zig for `GET /api/todos`.
