#!/bin/sh
# payhook step 5: receive, health, signature checks, storage, replays, the chat message and its
# retries. The key is in the environment, the clock is fixed, requests are signed with sign.py (Python hmac). KIO=path/to/kio.
set -e
status=1
KIO=${KIO:-kio}
cd "$(dirname "$0")"
store=$(mktemp -d)
pid=
hook=
trap 'for p in $pid $hook; do kill $p 2>/dev/null; wait $p 2>/dev/null || true; done; rm -rf "$store"; exit $status' EXIT
"$KIO" check app.kio --grants app.grants >/dev/null || { echo "app.kio does not check with app.grants"; "$KIO" check app.kio --grants app.grants; exit 1; }
# app.grants less the lines the test replaces (the fixed clock, the chat stand-in, paths, the port):
# the key's and the chat's grants come from app.grants as in production.
grep -v -e '^--clock ' -e '^--db ' -e '^--log ' -e '^--http ' -e '^--audit ' -e '^--listen ' app.grants >"$store/test.grants"
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
port=$(free_port)
base=http://127.0.0.1:$port
key=whsec_test_$$_0123456789abcdef
export STRIPE_WHSEC=$key
now_s=1794225600  # 2026-11-09T12:00:00Z, the fixed clock
# The chat stand-in: hook.py checks the Authorization the host injects and can be told to fail.
hook_port=$(free_port)
hook_url=http://127.0.0.1:$hook_port
events=$store/chat
: >"$events"
hook_key=chat-key-$$-5e1d9a07c3b2
printf 'Bearer %s\n' "$hook_key" >"$store/chat_auth"
export CHAT_AUTH="Bearer $hook_key"
python3 hook.py "$hook_port" "$events" "$store/chat_auth" &
hook=$!
for i in $(seq 50); do
    curl -s -o /dev/null -X POST -d ok $hook_url/_mode && break
    sleep 0.1
done
mode() { curl -s -o /dev/null -X POST -d "$1" $hook_url/_mode; }

start() {
    "$KIO" run app.kio --grants "$store/test.grants" --clock now=fixed:${now_s}000 \
        --db db="$store/payhook.db" --log log="$store/app.log" --http slack=$hook_url \
        --audit "$store/audit.log" --listen 127.0.0.1:$port >/dev/null 2>>"$store/stderr" &
    pid=$!
    for i in $(seq 50); do
        curl -s -o /dev/null $base/health && return
        sleep 0.3
    done
    echo "server did not start"; exit 1
}

row() { rows | sed -n "${1}p"; }
stop() { kill $pid; wait $pid 2>/dev/null || true; pid=; }
# rows: the events table as `id|kind|status|attempts|created_ms|text` lines, by arrival.
rows() { python3 db.py "$store/payhook.db" "SELECT id,kind,status,attempts,created_ms,text FROM events ORDER BY rowid"; }
# state ID: `status|attempts` of one event.
state() { python3 db.py "$store/payhook.db" "SELECT status,attempts FROM events WHERE id='$1'"; }

# wait_for WHAT EXPECTED CMD..: CMD's output is EXPECTED within 8 s (the chat is told after the answer).
wait_for() {
    what=$1; want=$2; shift 2
    for i in $(seq 80); do
        got=$("$@")
        [ "$got" = "$want" ] && { n=$((n + 1)); return; }
        sleep 0.1
    done
    echo "FAIL $what: want '$want', got '$got'"; exit 1
}
chat() { cat "$events"; }
n=0
# check METHOD PATH BODY EXPECTED-STATUS EXPECTED-BODY-SUBSTRING [SIGNATURE-HEADER]
check() {
    out=$(curl -s -w ' %{http_code}' -X "$1" ${3:+-d "$3"} ${6:+-H "Stripe-Signature: $6"} $base$2)
    case "$out" in
    *"$5"*" $4") ;;
    *) echo "FAIL $1 $2 $3 [$6]: want $4 containing $5, got $out"; exit 1 ;;
    esac
    n=$((n + 1))
}
sig() { python3 sign.py "${3:-$key}" "${2:-$now_s}" "$1"; }
# stripe BODY STATUS SUBSTR [TS]: POST /stripe signed at TS (default: now).
stripe() { check POST /stripe "$1" "$2" "$3" "$(sig "$1" "${4:-$now_s}")"; }
ev='{"id":"evt_1","type":"payment_intent.succeeded","created":1794225600,"data":{"object":{"amount":1234,"currency":"usd","customer":"cus_x"}}}'

start
check GET /health "" 200 'ok'
check POST /health "" 404 'not found'
check GET /nope "" 404 'not found'
check GET /stripe "" 404 'not found'
# Valid signatures.
stripe "$ev" 200 '{"received":true}'
stripe '{"id":"evt_2","type":"other.thing"}' 200 '{"received":true}'
# (evt_1 is stored by the first request above: later accepted ones are replays, also 200.)
# Skew: 300 s either way is accepted, 301 is not.
stripe "$ev" 200 'true}' $((now_s - 300))
stripe "$ev" 200 'true}' $((now_s + 300))
stripe "$ev" 400 'tolerance' $((now_s - 301))
stripe "$ev" 400 'tolerance' $((now_s + 301))
stripe "$ev" 400 'tolerance' 0
# Several v1 entries: any one may match (key rotation).
good=$(sig "$ev")
bad="t=$now_s,v1=$(printf '0%.0s' $(seq 64))"
check POST /stripe "$ev" 200 'true}' "$bad,v1=${good#*v1=}"
check POST /stripe "$ev" 200 'true}' "$good,v1=$(printf '0%.0s' $(seq 64))"
check POST /stripe "$ev" 200 'true}' "t=$now_s, v1=${good#*v1=}"
check POST /stripe "$ev" 400 'bad signature' "$bad,v1=ab"
# Bad signatures: wrong key, tampered body, tampered timestamp, malformed headers, none.
check POST /stripe "$ev" 400 'bad signature' "$(sig "$ev" $now_s wrong-key)"
check POST /stripe "${ev}x" 400 'bad signature' "$good"
check POST /stripe "$ev" 400 'bad signature' "t=$((now_s + 1)),v1=${good#*v1=}"
check POST /stripe "$ev" 400 'bad signature' "t=$now_s,v1=zz${good#*v1=}"
check POST /stripe "$ev" 400 'bad signature' "t=$now_s,v1="
check POST /stripe "$ev" 400 'bad signature' "t=$now_s,v1=${good#*v1=}00"
check POST /stripe "$ev" 400 'bad signature' "t=$now_s,v1=$(printf '%s' "${good#*v1=}" | tr 'a-f0-9' 'A-F0-9' | sed 's/^./Z/')"
check POST /stripe "$ev" 400 'no timestamp' "v1=${good#*v1=}"
check POST /stripe "$ev" 400 'no timestamp' "t=abc,v1=${good#*v1=}"
check POST /stripe "$ev" 400 'no timestamp' garbage
check POST /stripe "$ev" 400 'missing Stripe-Signature'
check POST /stripe "" 400 'missing Stripe-Signature'
# A body signed with the wrong key is refused before it is read as JSON.
check POST /stripe '{"id":' 400 'bad signature' "$(sig '{"id":' $now_s wrong-key)"
# Signed but not an event.
stripe '{"id":' 400 'at byte'
stripe '[1]' 400 'field \"id\"'
stripe '{"id":5,"type":"x"}' 400 'field \"id\"'
stripe '{"id":"evt_3"}' 400 'field \"type\"'
# Storage and replays. Everything so far used evt_1, evt_2 and no others.
[ "$(rows | wc -l | tr -d ' ')" = 2 ] || { echo "FAIL want 2 stored events"; rows; exit 1; }
wait_for 'evt_1 is sent' "evt_1|payment_intent.succeeded|sent|1|${now_s}000|Payment succeeded: \$12.34 USD from cus_x" row 1
[ "$(rows | sed -n 1p)" = "evt_1|payment_intent.succeeded|sent|1|${now_s}000|Payment succeeded: \$12.34 USD from cus_x" ] || { echo "FAIL evt_1 row"; rows; exit 1; }
[ "$(rows | sed -n 2p)" = "evt_2|other.thing|stored|0|${now_s}000|" ] || { echo "FAIL evt_2 row"; rows; exit 1; }
n=$((n + 3))
stripe "$ev" 200 '{"duplicate":true}'
stripe "$ev" 200 '{"duplicate":true}' $((now_s - 100))
stripe '{"id":"evt_2","type":"other.thing"}' 200 '{"duplicate":true}'
# A replay with a different body but the same id is still a replay; the first copy stays.
stripe '{"id":"evt_1","type":"charge.refunded","data":{"object":{"amount":1,"currency":"usd","customer":"cus_z"}}}' 200 '{"duplicate":true}'
[ "$(rows | wc -l | tr -d ' ')" = 2 ] || { echo "FAIL replays added rows"; rows; exit 1; }
# A replay needs a good signature too.
check POST /stripe "$ev" 400 'bad signature' "$(sig "$ev" $now_s wrong-key)"
# Amounts: cents are padded, the currency upper-cased; the refund wording differs.
stripe '{"id":"evt_a","type":"payment_intent.succeeded","data":{"object":{"amount":5,"currency":"eur","customer":"cus_a"}}}' 200 'received'
stripe '{"id":"evt_b","type":"charge.refunded","data":{"object":{"amount":100,"currency":"usd","customer":"cus_b"}}}' 200 'received'
stripe '{"id":"evt_c","type":"payment_intent.succeeded","data":{"object":{"amount":0,"currency":"usd","customer":"cus_c"}}}' 200 'received'
stripe '{"id":"evt_d","type":"charge.refunded","data":{"object":{"amount":99999,"currency":"jpy","customer":"cus_d"}}}' 200 'received'
wait_for 'evt_d is sent' 'sent|1' state evt_d
[ "$(rows | sed -n 3p | cut -d'|' -f6)" = 'Payment succeeded: $0.05 EUR from cus_a' ] || { echo "FAIL evt_a text"; rows; exit 1; }
[ "$(rows | sed -n 4p | cut -d'|' -f6)" = 'Refund: $1.00 USD to cus_b' ] || { echo "FAIL evt_b text"; rows; exit 1; }
[ "$(rows | sed -n 5p | cut -d'|' -f6)" = 'Payment succeeded: $0.00 USD from cus_c' ] || { echo "FAIL evt_c text"; rows; exit 1; }
[ "$(rows | sed -n 6p | cut -d'|' -f6)" = 'Refund: $999.99 JPY to cus_d' ] || { echo "FAIL evt_d text"; rows; exit 1; }
n=$((n + 6))
# A notifying type needs its fields: 400, nothing stored. Other types need none.
stripe '{"id":"evt_e","type":"charge.refunded"}' 400 'data.object'
stripe '{"id":"evt_e","type":"charge.refunded","data":{"object":{"currency":"usd","customer":"c"}}}' 400 'amount'
stripe '{"id":"evt_e","type":"charge.refunded","data":{"object":{"amount":-5,"currency":"usd","customer":"c"}}}' 400 'negative'
stripe '{"id":"evt_e","type":"charge.refunded","data":{"object":{"amount":5,"customer":"c"}}}' 400 'currency'
stripe '{"id":"evt_e","type":"charge.refunded","data":{"object":{"amount":5,"currency":"usd"}}}' 400 'customer'
stripe '{"id":"evt_f","type":"customer.created"}' 200 'received'
[ "$(rows | wc -l | tr -d ' ')" = 7 ] || { echo "FAIL want 7 rows"; rows; exit 1; }
# Concurrent replays of one new event: exactly one is new.
body='{"id":"evt_race","type":"other.thing"}'
hdr=$(sig "$body")
pids=
for i in $(seq 10); do
    curl -s -o "$store/race.$i" -d "$body" -H "Stripe-Signature: $hdr" $base/stripe &
    pids="$pids $!"
done
wait $pids
[ "$(cat "$store"/race.* | grep -o '{"received":true}' | wc -l | tr -d ' ')" = 1 ] || { echo "FAIL race: not exactly one new"; cat "$store"/race.*; exit 1; }
[ "$(cat "$store"/race.* | grep -o '{"duplicate":true}' | wc -l | tr -d ' ')" = 9 ] || { echo "FAIL race: not nine duplicates"; cat "$store"/race.*; exit 1; }
n=$((n + 2))
# The store survives a restart: a replay after it is still a duplicate.
stop
start
stripe "$ev" 200 '{"duplicate":true}'
stripe '{"id":"evt_g","type":"other.thing"}' 200 'received'
# The log: one line per accepted event, in the form `<id> <type> <outcome>` (under --listen `req N: ` first).
got=$(sed 's/^req [0-9]*: //' "$store/app.log" | head -2)
[ "$got" = "evt_1 payment_intent.succeeded notified
evt_2 other.thing stored" ] || { echo "FAIL log start:"; cat "$store/app.log"; exit 1; }
for line in 'evt_a payment_intent.succeeded notified' 'evt_b charge.refunded notified' 'evt_f customer.created stored' \
    'evt_1 charge.refunded duplicate' 'evt_2 other.thing duplicate' 'evt_g other.thing stored'; do
    grep -qx "req [0-9]*: $line" "$store/app.log" || { echo "FAIL log lacks $line"; cat "$store/app.log"; exit 1; }
done
[ "$(grep -c ' evt_race other.thing stored$' "$store/app.log")" = 1 ] || { echo "FAIL log race stored"; exit 1; }
[ "$(grep -c ' evt_race other.thing duplicate$' "$store/app.log")" = 9 ] || { echo "FAIL log race duplicates"; exit 1; }
# The restarted server logged the replay first (the log is appended to, and requests number from 1 again).
[ "$(tail -2 "$store/app.log" | sed 's/^req [0-9]*: //')" = "evt_1 payment_intent.succeeded duplicate
evt_g other.thing stored" ] || { echo "FAIL log after restart"; cat "$store/app.log"; exit 1; }
# Nothing rejected or unknown is logged.
! grep -q 'evt_e\|evt_3' "$store/app.log" || { echo "FAIL log has a rejected event"; exit 1; }
# Rejected requests are not logged: every line is `<id> <type> <outcome>`.
! grep -qv '^req [0-9]*: evt_[a-z0-9]* [a-z_.]* \(stored\|notified\|pending\|duplicate\)$' "$store/app.log" || { echo "FAIL log has other lines"; cat "$store/app.log"; exit 1; }
n=$((n + 7))
# The chat: one message per new notifying event (evt_1, a, b, c, d), none for replays, none for
# other types, each with the Authorization the host injects (the stand-in answers 401 without it).
wait_for 'five chat messages' 5 sh -c "grep -c . '$events'"
for line in 'OK	{"text":"Payment succeeded: $12.34 USD from cus_x"}' 'OK	{"text":"Payment succeeded: $0.05 EUR from cus_a"}' \
    'OK	{"text":"Refund: $1.00 USD to cus_b"}' 'OK	{"text":"Payment succeeded: $0.00 USD from cus_c"}' 'OK	{"text":"Refund: $999.99 JPY to cus_d"}'; do
    grep -qxF "$line" "$events" || { echo "FAIL chat lacks: $line"; chat; exit 1; }
done
[ "$(grep -c . "$events")" = 5 ] || { echo "FAIL extra chat messages"; chat; exit 1; }
n=$((n + 6))
# ok_ev ID TYPE CENTS CUSTOMER: a signed new notifying event, answered 200 {"received":true}.
ev_of() { printf '{"id":"%s","type":"%s","data":{"object":{"amount":%s,"currency":"usd","customer":"%s"}}}' "$1" "$2" "$3" "$4"; }
new_event() { stripe "$(ev_of "$@")" 200 '{"received":true}'; }
# posts TEXT-PATTERN: how many chat posts (any result) carry that text.
posts() { grep -c "$1" "$events" || true; }
log_has() { grep -c "^req [0-9]*: $1\$" "$store/app.log" || true; }

# A failing chat does not fail Stripe's request: 200, the event stays pending with the attempt counted.
mode 500
new_event evt_r1 payment_intent.succeeded 2500 cus_1
wait_for 'evt_r1: one failed attempt' 'pending|1' state evt_r1
wait_for 'evt_r1 post' 1 posts 'FAIL500.*\$25.00 USD from cus_1'
wait_for 'log: evt_r1 pending' 1 log_has 'evt_r1 payment_intent.succeeded pending'
# The next request, any request, retries it: a health check here (attempt 2, fails again).
check GET /health "" 200 ok
wait_for 'evt_r1: two failed attempts' 'pending|2' state evt_r1
# The next request retries it a third time and, it failing, marks it failed for good. The new event
# gets its own first attempt in the same request.
new_event evt_r2 charge.refunded 700 cus_2
wait_for 'evt_r1: failed after 3 attempts' 'failed|3' state evt_r1
wait_for 'evt_r2: one failed attempt' 'pending|1' state evt_r2
wait_for 'log: evt_r1 failed' 1 log_has 'evt_r1 payment_intent.succeeded failed'
[ "$(posts 'FAIL500.*\$25.00 USD from cus_1')" = 3 ] || { echo "FAIL evt_r1 was not tried exactly 3 times"; chat; exit 1; }
# Even a 404 retries: evt_r2's second and third attempts.
check GET /nope "" 404 'not found'
wait_for 'evt_r2: two failed attempts' 'pending|2' state evt_r2
check GET /nope "" 404 'not found'
wait_for 'evt_r2: failed after 3 attempts' 'failed|3' state evt_r2
[ "$(posts 'FAIL500.*\$7.00 USD to cus_2')" = 3 ] || { echo "FAIL evt_r2 was not tried exactly 3 times"; chat; exit 1; }
# A failed event is final: replays answer duplicate, nothing is sent again, even with the chat back.
mode ok
before=$(grep -c . "$events")
stripe "$(ev_of evt_r1 payment_intent.succeeded 2500 cus_1)" 200 '{"duplicate":true}'
check GET /health "" 200 ok
sleep 1
[ "$(grep -c . "$events")" = "$before" ] || { echo "FAIL a failed event was sent again"; chat; exit 1; }
[ "$(state evt_r1)" = 'failed|3' ] && [ "$(state evt_r2)" = 'failed|3' ] || { echo "FAIL failed events changed"; exit 1; }
n=$((n + 6))
# Recovery: the chat is back before the third attempt. Attempt 2 succeeds, on the next request.
mode 500
new_event evt_r3 payment_intent.succeeded 1999 cus_3
wait_for 'evt_r3: one failed attempt' 'pending|1' state evt_r3
mode ok
check GET /health "" 200 ok
wait_for 'evt_r3: sent on attempt 2' 'sent|2' state evt_r3
wait_for 'log: evt_r3 retried' 1 log_has 'evt_r3 payment_intent.succeeded retried'
check GET /health "" 200 ok
sleep 1
[ "$(posts 'OK.*\$19.99 USD from cus_3')" = 1 ] || { echo "FAIL evt_r3 not sent exactly once"; chat; exit 1; }
# A replay (a duplicate) is a request too: it retries pending events.
mode 500
new_event evt_r4 charge.refunded 5 cus_4
wait_for 'evt_r4: one failed attempt' 'pending|1' state evt_r4
mode ok
stripe "$(ev_of evt_r3 payment_intent.succeeded 1999 cus_3)" 200 '{"duplicate":true}'
wait_for 'evt_r4: sent by the replay request' 'sent|2' state evt_r4
n=$((n + 1))
# A hanging chat: the answer is not delayed, the app gives up after 2 s, the event stays pending.
mode hang
t0=$(date +%s)
new_event evt_r5 payment_intent.succeeded 100 cus_5
[ $(($(date +%s) - t0)) -le 1 ] || { echo "FAIL the answer waited for the chat"; exit 1; }
wait_for 'evt_r5: one timed-out attempt' 'pending|1' state evt_r5
mode ok
check GET /health "" 200 ok
wait_for 'evt_r5: sent on attempt 2' 'sent|2' state evt_r5
n=$((n + 1))
# Pending events survive a restart and are retried by its first request (the start probe).
mode 500
new_event evt_r6 charge.refunded 1234 cus_6
wait_for 'evt_r6: one failed attempt' 'pending|1' state evt_r6
mode ok
stop
start
wait_for 'evt_r6: sent after the restart' 'sent|2' state evt_r6
# Every post carried the Authorization the host injected (the stand-in answers 401 without it).

# Without a Authorization the stand-in would have written UNAUTH: the host injected it every time.
! grep -q UNAUTH "$events" || { echo "FAIL a chat post lacked the injected Authorization"; chat; exit 1; }
! grep -q BADPATH "$events" || { echo "FAIL a chat post went to another path"; chat; exit 1; }
grep -q '"injected":\["authorization"\]' "$store/audit.log" || { echo "FAIL audit lacks injected"; exit 1; }
n=$((n + 3))
for f in "$store/audit.log" "$store/app.log" "$store/stderr"; do
    ! grep -q "$hook_key" "$f" || { echo "FAIL the chat key is in $f"; exit 1; }
done
n=$((n + 1))
# The key never reaches the audit log or stderr; every verify is audited.
for f in "$store/audit.log" "$store/stderr"; do
    ! grep -q "$key" "$f" || { echo "FAIL the key is in $f"; exit 1; }
done
grep -q '"method":"verify"' "$store/audit.log" || { echo "FAIL audit lacks verify"; exit 1; }
grep -q '"cap":"db"' "$store/audit.log" || { echo "FAIL audit lacks db"; exit 1; }
n=$((n + 3))
echo "payhook step 5 ok ($n checks)"
status=0
