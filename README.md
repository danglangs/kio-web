# kio-web

A small web framework written in [kio](https://github.com/danglangs/kiolang), a capability-typed language for code that AI agents write.

The kio host accepts connections and hands each request to a fresh sandbox as raw parts: a capability `Incoming` with the method, target, headers and body, and `Outgoing` to send the response. kio-web defines `Request`, `Response` and the helpers on top, as axum does over hyper. A handler can touch only what its signature names, and kio's report says what that is:

```rust
mod web;

fn main(req: Incoming, res: Outgoing, public: Dir) -> Result<(), WebErr> {
    let r = web::request(req);
    let out = match web::route(r, "GET", "/hello/:name") {
        Some(p) => web::json(200, "{\"hello\": " + web::json_str(p.get(":name").unwrap_or("")) + "}"),
        None => web::file(public, r.path),
    };
    web::send(res, out)
}
```

```
main : req body header_names header_values method target, res send, public read
```

**Status:** the library and its tests run today. Serving needs `kio run --listen`, kiolang web task W7.

## Use

kio has no package manager: copy [web.kio](web.kio) beside your app and write `mod web;`.

| Function | Does |
|---|---|
| `request(req)`, `send(res, r)` | convert between the host's raw parts and `Request` / `Response` |
| `route(r, method, pattern)` | match `"/hello/:name"`; `Some(params)` keyed by `":name"` |
| `get`, `post`, `put`, `delete`, `dispatch(routes, r)`, `param(m, name)` | a route table; see Routing |
| `query(r)`, `decode(s)` | query parameters, percent-decoded |
| `header(r, name)` | a header value; names are lowercase |
| `text`, `json`, `html`, `respond`, `not_found`, `redirect(status, location)` | build responses |
| `html_escape(s)` | `s` safe in HTML text and quoted attributes (`& < > " '`) |
| `json_str(s)` | a JSON string literal |
| `file(dir, name)` | serve a file from a granted `Dir` |
| `upgrade(msg)`, `bearer(msg)` | a WebSocket's upgrade request as a `Request`; its `authorization: Bearer` token; see WebSockets |

## Routing

`dispatch` replaces a chain of `if let Some(p) = web::route(..)`. A table is a `List<web::Route<A>>` of the app's own action values; `dispatch` returns the first match as `Option<Matched<A>>`, with `m.action` and the path parameters (`web::param(m, "id")`).

```rust
enum Act { List, Show }

fn handle(r: web::Request, notes: Dir) -> web::Response {
    let routes = [web::get("/notes", Act::List), web::get("/notes/:id", Act::Show)];
    match web::dispatch(routes, r) {
        Some(m) => match m.action {
            Act::List => list(notes),
            Act::Show => show(notes, web::param(m, "id")),
        },
        None => web::not_found(),
    }
}
```

**Why the table holds an enum, not handlers.** kio's rule 1: a function value or closure cannot take, capture or return a capability, so `Route { handler: fn(Request) -> Response }` cannot hold a handler that needs the app's `Dir` or `Kv`. The table is pure data and `handle` calls the named function, passing only the capability it needs. The authority report stays exact: `list` shows `notes list read`, `show` shows `notes read`, and `routes`/`dispatch` show none. Handlers that need no capability could be function values, but one mixed style would split the table, so the examples use one enum.

## JSON

`Json` is built into kio (see kio's language.md): `Null`, `Bool(Bool)`, `Num(Int)`, `Float(Float)`, `Str(Str)`, `Arr(List<Json>)`, `Obj(Map<Str, Json>)`. No `mod json;` and no file to copy.

```rust
// The "name" field of a JSON body, or "anonymous".
fn name(body: Str) -> Str {
    match body.parse_json() {
        Ok(j) => j.get("name").and_then(|n| n.as_str()).unwrap_or("anonymous"),
        Err(_) => "anonymous",
    }
}
```

`s.parse_json()` gives `Result<Json, Str>`; `j.to_json()` gives compact text; `get`, `at`, `as_str`, `as_int`, `as_float`, `as_bool`, `as_list`, `as_map` return `Option`.

Migrating from json.kio (removed): delete `mod json;` and the copy of json.kio, then `json::parse(s)` is `s.parse_json()`, `json::encode(j)` is `j.to_json()`, `json::Json::X` is `Json::X`, `json::get(j, k)` is `j.get(k)`, and `json::as_str(x)` is `x.as_str()` (likewise the other accessors). Nesting limit is now 128 (was 64).

## API helpers

Copy [api.kio](api.kio) too and declare `mod web; mod api;`. It builds on web.kio and the built-in `Json`; an app that uses only web.kio does not need api.kio.

| Function | Does |
|---|---|
| `json(status, j)` | respond with `Json` `j` encoded as `application/json` |
| `error(status, msg)` | respond with `{"error": msg}` |
| `body(r)` | the request body as `Ok(Json)`, or `Err(response)`, a 400 carrying the parse message |
| `str_field(j, key)`, `int_field(j, key)` | an object field, if present with that type |
| `int_param(s, what)` | `s` as `Ok(Int)`, or a 400 saying `what` must be an integer |
| `first(xs)`, `flatten(opts)` | the first element; the present values of a `List<Option<T>>` |
| `page(xs, r)` | `Page<T> { items, total, offset }` from the query's `offset` and `limit` |
| `str_fields(r, keys)` | the body's string fields in order as `Ok(List<Str>)`, or a 400 naming the bad JSON or missing field |

```rust
fn create(r: web::Request) -> web::Response {
    let j = match api::body(r) { Ok(j) => j, Err(e) => return e };
    match api::str_field(j, "title") {
        Some(t) => api::json(201, Json::Str(t)),
        None => api::error(400, "missing string field \"title\""),
    }
}
```

Three full apps are built this way: [examples/notes](examples/notes) stores notes as files in a `Dir` (list, create, write, remove), [examples/kvnotes](examples/kvnotes) is the same API over a `Kv` with a `swap`-based id counter, and [examples/links](examples/links) is a link shortener: bearer-token auth, redirects that count hits, an HTML page, static files, and a `Kv` file that survives restarts.

## WebSockets

A WebSocket server's `main` takes `msg: WsMessage, conn: WsSend` (kio runs it once per event: open, each message, close). Every event of a connection sees the same upgrade request, so `web::upgrade(msg)` routes it with `route` or `dispatch`, and `web::bearer(msg)` reads its token:

```rust
fn main(msg: WsMessage, conn: WsSend, auth: Kv, counts: Kv) -> Result<(), WsErr> {
    if msg.kind() == "close" { return forget(msg, counts); }
    if !authorized(msg, auth) { return conn.close(4401); }
    match web::dispatch(routes(), web::upgrade(msg)) {
        Some(m) => match m.action { Act::Echo => echo(msg, conn), Act::Count => count(msg, conn, counts) },
        None => conn.close(4404),
    }
}
```

The upgrade is answered before `main` runs, so a refused client is closed (here 4401) on its `open` event; its later messages are refused the same way. [examples/ws](examples/ws) is the full app: `/echo` and a per-connection `/count`, for clients whose token matches one stored in a `Kv` by a separate program.

## Test

```
KIO=../kiolang/target/release/kio ./test.sh
```

## License

MIT or Apache-2.0, as kiolang.
