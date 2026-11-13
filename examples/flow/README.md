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

# F1.2, Worker

`kio run worker.kio` is one pass: it claims each due job with a lease, `POST`s its stored body to the destination, then marks it `done`, or schedules a retry with exponential backoff (1 s, 2 s, 4 s, ..), or marks it `dead` after 5 attempts. It prints how many jobs it attempted. kio has no sleep, so polling is running it again (cron, or a shell loop).

**Delivery contract: at least once, deduplicated by the destination.** A lease cannot make an outside effect happen exactly once: the worker may POST, die before recording `done`, and the job is retried when the lease expires. So every attempt of one job sends the same `Idempotency-Key: <event id>` header, and the destination must apply a key once. This is not exactly-once; the guarantee is only as good as the destination's dedup.

| Transition | Rule |
|---|---|
| pending / retry -> claimed | one conditional `UPDATE` (job still due, attempts still as seen): `attempts += 1`, `lease = attempts`, `lease_until = now + 3 s`. 1 row changed means this worker holds it |
| claimed -> done / retry / dead | `WHERE id = ? AND lease = ? AND state = 'claimed'`: a worker whose lease was taken over changes nothing |
| retry | `next_ms = now + 1 s * 2^(attempts-1)`; dead instead when `attempts >= 5` |
| claimed, lease expired | claimable again; dead (by the next claim) if `attempts >= 5` |

Schema (F1.1's table, three columns added with defaults): `lease`, `lease_until`, `next_ms`. An F1.1 database made before F1.2 has no migration. Files: [worker.kio](worker.kio) (`main`, `deliver`), [flow.kio](flow.kio) (`claim`, `try_claim`, `finish`, `backoff_ms`, `headers`: plain values and `Db`, so tests drive them), [worker.grants](worker.grants), [dest.py](dest.py) (stand-in destination for `test.sh`).

The worker holds `db`, `now`, and `dest: Http` (POST only, `Authorization` injected by `--http-header dest=Authorization:env:DEST_AUTH`; the program never holds it). It has no `Incoming`, `Outgoing` or `Hmac`.

## Authority

`kio check worker.kio --grants worker.grants` (kio-web's `web::`/`api::` lines omitted; the report lists every function, ingest's included, though the worker never calls them):

```
deliver           : dest send POST
flow::accepted    : none
flow::backoff_ms  : none
flow::claim       : db exec query
flow::finish      : db exec
flow::headers     : none
flow::ingest      : key verify, db exec
flow::init        : db exec
flow::int_of      : none
flow::jobs        : db query
flow::rows        : db query
flow::store       : db exec
flow::text_of     : none
flow::try_claim   : db exec query
main              : db exec query, now now_ms, dest send POST
tests::add        : db exec
tests::body_of    : none
tests::claimed    : db exec query
tests::clamp      : none
tests::due        : none
tests::find       : none
tests::gen_body   : none
tests::job_line   : db query
tests::key_of     : none
tests::mline      : none
tests::sig_of     : key sign
tests::signed     : key sign verify, db exec
tests::step       : db exec query
tests::take       : none
```

`kio check worker.kio --base app.kio` (the worker against the F1.1 server; they are different programs, so this reads as the move from one to the other):

```
~ db: Db (+query)
+ dest: Http (send POST)
- req: Incoming (body header_names header_values method target)
- res: Outgoing (send)
- key: Hmac (verify)
authority added (exit 3); --detail lists each function
```

## Tests

`FLOW_KEY=test-key kio test worker.kio --grants test.grants` (also `kio test app.kio`, which runs the same file). New: six example tests (one per transition and the stale, limit and key cases) and two properties against a reference model in [tests.kio](tests.kio):

- `db_equals_model_and_nothing_is_stranded`: a generated list of `Ingest`, `Claim`, `Poach` (a claim of a given job and attempt count, taken or stale), `Work(job, ok, crash)` (`Crash::Never | BeforePost | AfterPost`; works on any earlier claim, so late and stale workers are included) and `Advance` (0-3 s against a 1 s lease) and a limit of 1-4. After every operation the `Db` rows equal the model's, attempts are at most the limit, and a done job's id is among the keys posted (the key is read from the real request headers). Then the clock passes every lease and backoff and the worker drains: every job is `done` or `dead`.
- `stale_completion_changes_nothing`: a finish under an old lease, at any later time, with either result, leaves every row as it was.

```
ok   tests::a_claim_needs_the_job_still_due_and_unchanged
ok   tests::any_signed_bytes_get_an_answer  (100 cases compiled; seed 1)
ok   tests::bad_signature_beats_bad_json
ok   tests::bad_signature_is_401_and_never_inserts
ok   tests::bad_signature_never_inserts  (100 cases compiled; seed 1; 5 discarded)
ok   tests::db_equals_model_and_nothing_is_stranded  (100 cases compiled; seed 1)
ok   tests::every_attempt_carries_the_event_id_as_the_key
ok   tests::expired_lease_at_the_limit_is_dead_not_stranded
ok   tests::expired_lease_is_reclaimed_and_the_old_worker_changes_nothing
ok   tests::failure_retries_with_doubling_backoff_then_dies
ok   tests::malformed_json_is_400
ok   tests::missing_signature_is_401
ok   tests::new_event_is_202_and_a_pending_row
ok   tests::pending_claim_done
ok   tests::repeated_id_is_200_and_changes_nothing
ok   tests::replay_equals_each_distinct_event_once  (100 cases compiled; seed 1)
ok   tests::signed_non_utf8_body_is_400
ok   tests::stale_completion_changes_nothing  (100 cases compiled; seed 1)
18 passed, 0 failed
```

`./test.sh` adds 34 worker checks to F1.1's 27, against `dest.py` (logs every request, dedups by `Idempotency-Key`, needs the injected `Authorization`): the first pass delivers three stored jobs once each with the stored body and the granted key; a 500 retries after 1 s, again after 2 s, not before, and a retry that succeeds is `done` (3 posts, applied once); **SIGKILL of the worker while the destination holds the reply**, restart inside the lease (nothing is claimable), restart after it: the destination saw the event twice with the same key and applied it once; **two workers on one database** and ten jobs: each job is posted once and both workers did work. Dead-after-5 is tested in `kio test` only (it would take 15 s of backoff here).

## Mutation checks

Each applied alone to `flow.kio`, then reverted. All were caught.

| Mutation | Caught by |
|---|---|
| 1. drop `AND lease = ?` from the done update | `stale_completion_changes_nothing`, `db_equals_model..`, `expired_lease_is_reclaimed_and_the_old_worker_changes_nothing` |
| 2. drop the `Idempotency-Key` header | `every_attempt_carries_the_event_id_as_the_key`, `db_equals_model..` (the posted-key check); `test.sh` ("e1 body": the destination logged no key) |
| 3. claim `UPDATE` without its `WHERE` conditions | `a_claim_needs_the_job_still_due_and_unchanged`, `db_equals_model..` (`Poach`); `test.sh` with the kio tests off ("all attempted once between them": 11, not 10, so two workers did take one job) |
| 4. off-by-one on the limit: `>` for `>=` when failing | `failure_retries_with_doubling_backoff_then_dies`, `db_equals_model..`; `<=` for `<` in the claim `UPDATE`: `a_claim_needs_..`, `db_equals_model..` |

A fifth, `<=` for `<` only in the claim's `SELECT`, is not caught and cannot matter: `try_claim` re-checks the limit.

## Friction

1. **No sleep, so no worker loop.** `Clock` only reads; the "worker" is a single pass that returns, and polling is outside kio. Workaround: `main` drains the due jobs (capped at 500 per pass, the host-call limit is 10,000) and `test.sh` sleeps between passes. Wanted: `now.sleep_ms(n)` as a `Clock` method (still a grant), or a run mode that repeats `main`.
2. **A claim that says which row it took.** `exec` returns only the rows changed, and the docs do not say whether `RETURNING` works through `query` (I did not try), so a claim is a `SELECT` of up to 5 candidates plus one conditional `UPDATE` each, then a `SELECT` of the body. Correct (the `UPDATE` is the claim), but three statements where one `UPDATE .. RETURNING` would do. Wanted: `exec` that can return rows, or documented `RETURNING` through `query`.
3. **No way to interleave two workers in a kio test.** The race fenced by the conditional `UPDATE` cannot be reproduced from one test (one connection, no scheduler). Workaround: `try_claim` is `pub` and tests call it with a stale `seen` (the `Poach` op); the real two-process race is only in `test.sh`. Wanted: a test helper that runs two functions against one `Db` with a chosen interleaving.
4. **Mutations are slow to confirm when a property fails.** A failing case is shrunk by compiled reruns; a mutation that fails many cases took 1-3 minutes of the 100-case run plus shrinking (`kio test` on two roots runs the worker properties twice). Workaround: `--filter`.
5. **`test.sh` removes `web.kio`/`api.kio` on exit**, so a `kio test worker.kio` run right after fails "cannot read web.kio" (F1.1's friction 2 again; it cost me a wrong mutation table before I noticed).
6. **A tests module that needs `web::` forces the worker root to declare `mod web; mod api;`** though it never serves HTTP: `flow.kio` holds both ingest and worker functions, so `worker.kio` carries ingest's `key verify` in the report (unreached, but listed). Workaround: none; splitting `flow.kio` would need tests to name both halves.
7. **No integer power or shift:** backoff is a loop doubling `d` (`for _i in 1..attempts`).
8. **An event id with a CR/LF or non-ASCII byte** is `HttpErr::Invalid` as a header, so such a job is retried to `dead`; F1.1 accepts any string id. Not fixed: validating ids belongs in ingest (a new 400), which F1.1's contract does not have.

`kio check` errors hit: 0. Failures along the way were `kio test` assertions that were my own mistakes (the model's `next_ms` for a dead job, and `add` asserting a new id in a property that repeats ids); both were clear. A mutation run once failed silently into the wrong table because of friction 5.
