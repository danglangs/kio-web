# flow

A durable workflow service in kio-web, built in steps. **F1.1, Ingest** is the front door: `POST /events` takes a signed JSON event and stores it as a job for the worker step to pick up later.

| Request | Answer |
|---|---|
| `POST /events`, good `X-Signature`, new `id` | 202 `{"accepted":true}`, after the row is committed: `jobs(id, body, state='pending', attempts=0, received_ms)` |
| same `id` again (any body) | 200 `{"duplicate":true}`, nothing changes, the first body stays |
| `X-Signature` missing, not hex, or not the HMAC-SHA256 hex of the raw body | 401, nothing parsed or stored |
| signed, but not JSON, not UTF-8, or no string `id` | 400 |
| database failure | 500 |
| any other route or method | 404 |

Files: [app.kio](app.kio) (`main`, 23 lines), [flow.kio](flow.kio) (`ingest`, the handler: capabilities plus plain values, so tests call it), [tests.kio](tests.kio) (kio tests and properties), [test.sh](test.sh) (end to end over HTTP), [app.grants](app.grants), [test.grants](test.grants).

## Authority

`kio check app.kio` (the `web::` and `api::` lines are kio-web's library, `none` or request/response plumbing; the lines that matter are `flow::`, `main`, `tests::`):

```
api::body         : none
api::count        : none
api::error        : none
api::first        : none
api::flatten      : none
api::int_field    : none
api::int_param    : none
api::json         : none
api::page         : none
api::str_field    : none
api::str_fields   : none
flow::accepted    : none
flow::ingest      : key verify, db exec
flow::int_of      : none
flow::rows        : db query
flow::store       : db exec
flow::text_of     : none
main              : req body header_names header_values method target, res send, key verify, now now_ms, db exec
tests::body_of    : none
tests::gen_body   : none
tests::sig_of     : key sign
tests::signed     : key sign verify, db exec
web::bearer       : none
web::ctype        : none
web::decode       : none
web::delete       : none
web::digit        : none
web::dispatch     : none
web::dispatch_as  : none
web::file         : files read
web::get          : none
web::header       : none
web::hex          : none
web::html         : none
web::html_escape  : none
web::json         : none
web::json_str     : none
web::not_found    : none
web::param        : none
web::post         : none
web::protected    : none
web::put          : none
web::query        : none
web::redirect     : none
web::request      : req body header_names header_values method target
web::respond      : none
web::route        : none
web::send         : res send
web::strip_slash  : none
web::text         : none
web::unauthorized : none
web::upgrade      : msg target
web::ws_bearer    : msg header
```

`main` can `verify` with `key` (never `sign`: the grant is `:verify`), run `exec` on `db` (create the table, insert), and read the clock. It cannot read jobs back (`query` is only in `flow::rows`, used by tests). `tests::sig_of` is the only `sign`; it is test code, and `kio run` refuses a program whose `main` could call `sign` on a `:verify` grant.

## Run

```
cp ../../web.kio ../../api.kio .      # mod web; mod api; load files beside app.kio
FLOW_KEY=<secret> kio run app.kio --grants app.grants
curl -X POST localhost:8080/events -H "X-Signature: $(python3 sign.py "$FLOW_KEY" "$body")" -d "$body"
```

`app.grants` holds `--hmac key=env:FLOW_KEY:verify`, `--clock now`, `--db db=flow.db`, `--timeout 20`, `--listen 127.0.0.1:8080`. `kio check app.kio --grants app.grants` binds them without running.

## Tests

```
FLOW_KEY=test-key kio test app.kio --grants test.grants
```

`test.grants` is `--hmac key=env:FLOW_KEY` without `:verify`, so tests can sign. Example tests: each answer above, plus bad signature beats bad JSON and a signed non-UTF-8 body. Properties:

- `replay_equals_each_distinct_event_once`: a generated list of events over 4 ids (so repeats are common) goes into one `Db`; each distinct id (first occurrence) goes into a second `Db`; the answers are 202 then 200 and the two tables' rows are equal.
- `bad_signature_never_inserts`: a one-character-tampered signature, arbitrary text, and a valid signature of a different body all give 401 and zero rows.
- `any_signed_bytes_get_an_answer`: any signed bytes give 400 or 202, never a stopped run.

Mutation check (done by hand): dropping `verify` fails three tests including the property; `INSERT OR REPLACE` for `INSERT OR IGNORE` fails the replay property.

```
ok   tests::any_signed_bytes_get_an_answer  (100 cases compiled; seed 1)
ok   tests::bad_signature_beats_bad_json
ok   tests::bad_signature_is_401_and_never_inserts
ok   tests::bad_signature_never_inserts  (100 cases compiled; seed 1; 5 discarded)
ok   tests::malformed_json_is_400
ok   tests::missing_signature_is_401
ok   tests::new_event_is_202_and_a_pending_row
ok   tests::repeated_id_is_200_and_changes_nothing
ok   tests::replay_equals_each_distinct_event_once  (100 cases compiled; seed 1)
ok   tests::signed_non_utf8_body_is_400
10 passed, 0 failed
```

`KIO=path/to/kio ./test.sh` runs check, `kio test`, then starts the server and makes 27 HTTP checks: every answer above, replays keep the first body, forged signatures on malformed JSON are 401, the row is visible to another process (Python sqlite3) as soon as the 202 arrives, and rows survive a restart.

## Friction

Every place kio made this harder than it should be, and what I did.

1. **A signed non-UTF-8 body stopped the run.** `Bytes.to_str` had no checked form, so the client got a 500 with an empty body. Workaround was a 28-line `valid_utf8` in `flow.kio`. **Resolved** by kio L27 (v0.1.1): `body.try_to_str()` returns `None`, answered 400; the property that feeds arbitrary signed bytes still runs.
2. **`mod` loads files only from beside the root.** `web.kio` and `api.kio` must be copied next to `app.kio` (`test.sh` does, and deletes them); `kio test`/`kio check` fail with "cannot read web.kio" until then. Workaround: `cp`, and a `.gitignore`.
3. **Tests make the authority report noisy and the module list longer.** Tests must be in a module declared by the root (`mod tests;`) to be found without being in `main`'s file; the report then lists test helpers (`tests::sig_of : key sign`) beside real authority, and 40 lines of unused `web::`/`api::` functions drown the 8 that matter. Workaround: none; read the `flow::` and `main` lines. Wanted: a report that leaves out functions `main` cannot reach, or tests' helpers marked.
4. **`:verify` and tests need two grants files.** A test cannot sign with the production grant, which is the point, but there is no way to say "this grant, but signing, for tests" in `app.grants`. Workaround: `test.grants` with the same key variable minus `:verify`, kept in sync by hand. The key also has to be in the environment for `kio test`.
5. **"Answered after commit" cannot be tested in kio.** A test sees one connection and no clock between `exec` and the reply, so it can show the row exists when `ingest` returns, not that the 202 was sent after it. Workaround: `test.sh` reads the file with another process the moment the 202 arrives; the ordering itself is by construction (`main` sends after `ingest` returns, and `INSERT` is one autocommitted statement per the docs).
6. **No `\u{..}` escape in `Str` literals** ("unknown escape `\u`", hint lists `\n \r \t \0 \" \\`). Workaround: literal UTF-8 characters in the source.
7. **No JSON object literal or builder.** Building `{"id":..,"note":..}` is `Map::new()`, an `insert` per field, `Json::Obj(..).to_json()`: five lines for two fields (`accepted`, `gen_body`).
8. **`--listen` and `--db` in the grants file cannot be overridden on the command line** ("given in app.grants:6 and on the command line"). `test.sh` has to `grep -v` those lines out into a copy, as payhook's does, to pick a free port and a temp database.
9. **Mutating one character of a `Str` means `slice` three ways** (`s.slice(0, i) + c + s.slice(i + 1, n)`), used to tamper a signature in the property. No `replace_at`.
10. **A route with one fixed action is awkward in `web::dispatch`**: `enum Act { Ingest }` and `Some(_) =>` exist only to satisfy the generic router.
11. **Formatting rows for comparison is `+` chains** (`text_of(r[0]) + "|" + ..`), since there is no `format!` and no way to compare `List<List<SqlValue>>` rows readably in `assert_eq` output except by joining them.

`kio check` errors hit: 1 (the `\u` escape, item 6; its hint was clear). Other stops were not check errors: `kio test` and `kio run` failing on a missing `web.kio` (item 2, my own `cd`/copy mistakes, the message said exactly what was missing) and the `--listen` given twice (item 8, clear hint). Nothing confused me; the first `kio check` of the whole program passed with no errors, and the first `kio test` run passed 8 of 8, so I verified the tests by mutation instead of trusting them.
