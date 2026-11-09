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
| `query(r)`, `decode(s)` | query parameters, percent-decoded |
| `header(r, name)` | a header value; names are lowercase |
| `text`, `json`, `respond`, `not_found` | build responses |
| `json_str(s)` | a JSON string literal |
| `file(dir, name)` | serve a file from a granted `Dir` |

## JSON

Copy [json.kio](json.kio) beside your app and write `mod json;`. It decodes into a `Json` tree: `Null`, `Bool`, `Num(Int)`, `Str`, `Arr(List<Json>)`, `Obj(Map<Str, Json>)`.

```rust
mod json;

// The "name" field of a JSON body, or "anonymous".
fn name(body: Str) -> Str {
    match json::parse(body) {
        Ok(j) => json::as_str(json::get(j, "name").unwrap_or(json::Json::Null)).unwrap_or("anonymous"),
        Err(_) => "anonymous",
    }
}
```

| Function | Does |
|---|---|
| `parse(s)` | `Ok(Json)`, or `Err` naming what was expected and the byte offset, as `expected ',' or '}' at byte 17` |
| `encode(j)` | compact text, keys in `Map` order; `parse(encode(j))` gives `j` back |
| `get(j, key)`, `at(j, i)` | an object field, an array element |
| `as_str`, `as_int`, `as_bool`, `as_list` | the payload, if `j` has that type |

Numbers are integers; `1.5` and `2e3` are errors. Nesting deeper than 64 is an error. A repeated key keeps the last value.

Parsing time is linear in the input (kiolang P2a or later): 10 KB parses in 0.08 s and needs `--fuel 600000000`, 100 KB in 0.6 s and needs `--fuel 6000000000`.

## API helpers

Copy [api.kio](api.kio) too and declare `mod web; mod json; mod api;`. It builds on both, which stay independent of each other: an app that uses only web.kio needs neither json.kio nor api.kio.

| Function | Does |
|---|---|
| `json(status, j)` | respond with `Json` `j` encoded as `application/json` |
| `error(status, msg)` | respond with `{"error": msg}` |
| `body(r)` | the request body as `Ok(Json)`, or `Err(response)`, a 400 carrying the parse message |
| `str_field(j, key)`, `int_field(j, key)` | an object field, if present with that type |
| `str_fields(r, keys)` | the body's string fields in order as `Ok(List<Str>)`, or a 400 naming the bad JSON or missing field |

```rust
fn create(r: web::Request) -> web::Response {
    let j = match api::body(r) { Ok(j) => j, Err(e) => return e };
    match api::str_field(j, "title") {
        Some(t) => api::json(201, json::Json::Str(t)),
        None => api::error(400, "missing string field \"title\""),
    }
}
```

Two full apps are built this way: [examples/notes](examples/notes) stores notes as files in a `Dir` (list, create, write, remove), and [examples/kvnotes](examples/kvnotes) is the same API over a `Kv` with a `swap`-based id counter.

## Test

```
KIO=../kiolang/target/release/kio ./test.sh
```

## License

MIT or Apache-2.0, as kiolang.
