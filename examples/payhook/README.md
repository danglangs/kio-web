# payhook

A payment provider (Stripe-like) POSTs webhooks; payhook verifies them, stores each event once, and tells a team chat (Slack-like incoming webhook). A kio-web app in one file ([app.kio](app.kio)); its authority is five grants, and none of them can leak a key:

| Grant | Type | Used for |
|---|---|---|
| `stripe` | `Hmac` | `verify` only (`:verify`, so the program cannot mint signatures); the signing secret never enters the program |
| `now` | `Clock` | the 300 s skew check and `created_ms` |
| `db` | `Db` | SQLite: events, idempotency, pending messages |
| `log` | `Log` | one line per accepted event |
| `slack` | `Http` | `POST /hook` on the chat host; the operator injects `Authorization` with `--http-header`, so the program never sets or sees it |

## Run

```
STRIPE_WHSEC=whsec_... CHAT_AUTH='Bearer xoxb-...' \
kio run app.kio \
    --hmac stripe=env:STRIPE_WHSEC:verify \
    --clock now \
    --db db=payhook.db \
    --log log=payhook.log \
    --http slack=https://chat.example --http-methods slack=POST \
    --http-header slack=Authorization:env:CHAT_AUTH \
    --timeout 20 --audit audit.jsonl \
    --listen 127.0.0.1:8080
```

Copy `web.kio` and `api.kio` from the kio-web root beside `app.kio` first (`test.sh` does). `--timeout 20` leaves room for the retries a request makes after it answers (each chat post is cut off at 2 s).

## Behaviour

| Request | Answer |
|---|---|
| `GET /health` | 200 `ok` |
| `POST /stripe`, good signature, new event | 200 `{"received":true}` |
| same event id again (any body, any valid signature) | 200 `{"duplicate":true}`, no second message |
| bad or missing `Stripe-Signature`, a timestamp more than 300 s from the clock either way, no `t=`, bad hex | 400 `{"error":..}` |
| signed body that is not JSON, lacks a string `id` or `type`, or (for the two notifying types) lacks `data.object.{amount,currency,customer}` (amount a non-negative integer of cents) | 400 |
| database failure | 500, so the provider retries |

`Stripe-Signature: t=<unix s>,v1=<hex>[,v1=<hex>..]`: any `v1` may equal HMAC-SHA256 of `"<t>.<raw body>"` (key rotation). The signature is checked before the body is read; then the clock.

`payment_intent.succeeded` posts `{"text":"Payment succeeded: $12.34 USD from cus_x"}`, `charge.refunded` `{"text":"Refund: $12.34 USD to cus_x"}`; other types are stored and answered 200 with no message.

**Delivery.** An event is a row in `events` (`id` is the primary key: a replay violates it, which is the idempotency check) with a `status`: `stored` (no message), `pending`, `sent` or `failed`, and an `attempts` count. The post happens after Stripe has its 200, so a slow or failing chat never costs a provider retry. A non-2xx answer, a timeout (2 s) or a refused connection leaves the event `pending`. After answering any request, health checks and replays included, the app retries up to 5 pending events, oldest first; a third failed attempt marks the event `failed` for good. An attempt is claimed with a conditional `UPDATE ... SET attempts = attempts + 1 WHERE attempts = ?` before the post, so concurrent requests never send a message twice or pass three attempts, even when a run dies mid-attempt (the event then stays `pending` with its attempt counted).

The log has `<id> <type> <outcome>` per accepted event (`req N: ` first under `--listen`): `stored`, `duplicate`, `notified`, `pending`; a retry that succeeds logs `retried`, one that gives up `failed`. Rejected requests log nothing.

```
$ cat payhook.log
req 1: evt_1 payment_intent.succeeded notified
req 2: evt_1 payment_intent.succeeded duplicate
```

## Built in five steps

Each step is one commit with its authority diff (`kio check app.kio --base <previous app.kio>`) in [steps/](steps). A reviewer approving a step reads exactly this:

**Step 1, receive and health** ([step1.diff](steps/step1.diff); no base, so the report, less the `web::` helpers): no grant beyond the socket.

```
main              : req body header_names header_values method target, res send
```

**Step 2, verify signatures** ([step2.diff](steps/step2.diff)): the program can verify, and read the clock.

```
+ stripe: Hmac (verify)
+ now: Clock (now_ms)
authority added (exit 3); --detail lists each function
```

**Step 3, store and dedupe** ([step3.diff](steps/step3.diff)): a database and a log.

```
+ db: Db (exec)
+ log: Log (write)
authority added (exit 3); --detail lists each function
```

**Step 4, notify chat** ([step4.diff](steps/step4.diff)): one outbound host, `send_all` only.

```
+ slack: Http (send_all)
authority added (exit 3); --detail lists each function
```

**Step 5, retry pending** ([step5.diff](steps/step5.diff)): no new grant; `main` gains `db query`, and one helper does the retrying.

```
~ db: Db (+query)
authority added (exit 3); --detail lists each function
```

The final report, less the `web::` helpers and the functions with no authority:

```
check_signature : stripe verify
deliver         : db exec, slack send_all
main            : req body header_names header_values method target, res send, stripe verify, now now_ms, db exec query, log write, slack send_all
retry_pending   : db exec query, slack send_all, log write
store           : db exec
```

The program can verify but not sign, POST to one host and path family but not GET or DELETE, write one database and one log, and reach no file, other host, randomness or clock it was not handed.

## Audit log

One request (`--audit`): a signed new event, answered, then delivered to the chat (fields trimmed). Neither key appears; the log names the injected header.

```
{"req":1,"cap":"now","method":"now_ms","result":"ok","now":1794225600000}
{"req":1,"cap":"stripe","kind":"Hmac","method":"verify","bytes":182,"result":"true","len":150}
{"req":1,"cap":"db","method":"exec","arg":"INSERT INTO events (id, kind, text, status, attempts, created_ms) VALUES (?, ?, ?, ?, 0, ?)","params":5,"changes":1}
{"req":1,"cap":"db","method":"exec","arg":"UPDATE events SET attempts = attempts + 1 WHERE id = ? AND status = 'pending' AND attempts = ?","params":2,"changes":1}
{"req":1,"cap":"slack","kind":"Http","method":"send","arg":"/hook","http":"POST","headers":["content-type"],"injected":["authorization"],"sent":51,"status":200}
{"req":1,"cap":"db","method":"exec","arg":"UPDATE events SET status = 'sent' WHERE id = ?","params":1,"changes":1}
{"req":1,"cap":"log","method":"write","bytes":39,"result":"ok"}
{"req":1,"cap":"db","method":"query","arg":"SELECT id, kind, text, attempts FROM events WHERE status = 'pending' AND attempts < ? AND ..","params":3,"rows":0}
{"req":1,"event":"end","outcome":"ok","calls":15,"after_send":5}
```

## Test

```
KIO=path/to/kio ./examples/payhook/test.sh      # from the kio-web root
```

`test.sh` starts [hook.py](hook.py), a stand-in chat webhook that checks the injected `Authorization` and can be told to answer 500 or hang; signs requests with [sign.py](sign.py) (Python `hmac`); fixes the clock; and checks: health and routing; signatures (valid, several `v1`, wrong key, tampered body or timestamp, malformed headers, skew exactly 300 and 301 s either way); idempotency (replays, a replay with another body, 10 concurrent copies of one event, a replay after a restart); the message for each type and amount; no message for other types or replays; the chat failing (500, timeout), retries triggered by a health check, a 404 and a replay, the third failure marking `failed`, nothing sent after that, recovery, pending events surviving a restart; the log lines; and that neither key reaches the audit log, the log or stderr. [db.py](db.py) reads the database for the assertions.

## Reviewing it by authority (pilot notes)

payhook was written by a coding agent that read only kio's docs and kio-web; a reviewer then approved each step from its authority diff and the tests, without reading `app.kio`.

| Step | What the reviewer approved | Matches the brief? |
|---|---|---|
| 2 | `stripe: Hmac` used only to `verify`; a `Clock` | Yes: no `sign`, and the run grants `:verify` |
| 3 | a `Db` (`exec`), a `Log` | Yes |
| 4 | `slack: Http`, `send_all` only | Yes: one host, its key injected |
| 5 | `db query` | Yes: reading pending events back |

What the diffs answered: which outside systems the code can touch, and how (verify, never sign; POST to one host). What they could not: whether the signature result is acted on, what text goes to the chat, and which rows the SQL touches. The tests carried those (124 checks). One gap neither caught: a run that dies during an event's third attempt leaves it `pending` with `attempts = 3`, never retried or marked failed.
