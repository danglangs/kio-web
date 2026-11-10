#!/bin/sh
# payhook step 3: receive, health, signature checks, storage and replays. The key is in the environment, the clock is
# fixed, requests are signed with sign.py (Python hmac). KIO=path/to/kio.
set -e
status=1
KIO=${KIO:-kio}
cd "$(dirname "$0")"
cp ../../web.kio ../../api.kio .
store=$(mktemp -d)
pid=
trap 'for p in $pid; do kill $p 2>/dev/null; wait $p 2>/dev/null || true; done; rm -rf "$store" web.kio api.kio; exit $status' EXIT
"$KIO" check app.kio >/dev/null || { echo "app.kio does not check"; "$KIO" check app.kio; exit 1; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
port=$(free_port)
base=http://127.0.0.1:$port
key=whsec_test_$$_0123456789abcdef
export PAYHOOK_WHSEC=$key
now_s=1794225600  # 2026-11-09T12:00:00Z, the fixed clock

start() {
    "$KIO" run app.kio --hmac stripe=env:PAYHOOK_WHSEC:verify --clock now=fixed:${now_s}000 \
        --db db="$store/payhook.db" --log log="$store/app.log" --audit "$store/audit.log" --listen 127.0.0.1:$port >/dev/null 2>>"$store/stderr" &
    pid=$!
    for i in $(seq 50); do
        curl -s -o /dev/null $base/health && return
        sleep 0.3
    done
    echo "server did not start"; exit 1
}

stop() { kill $pid; wait $pid 2>/dev/null || true; pid=; }
# rows [WHERE]: the events table as `id|kind|status|attempts|created_ms|text` lines, by arrival.
rows() { python3 -c 'import sqlite3,sys; [print("|".join(map(str,r))) for r in sqlite3.connect(sys.argv[1]).execute("SELECT id,kind,status,attempts,created_ms,text FROM events ORDER BY rowid")]' "$store/payhook.db"; }

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
[ "$(rows | sed -n 1p)" = "evt_1|payment_intent.succeeded|pending|0|${now_s}000|Payment succeeded: \$12.34 USD from cus_x" ] || { echo "FAIL evt_1 row"; rows; exit 1; }
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
[ "$got" = "evt_1 payment_intent.succeeded pending
evt_2 other.thing stored" ] || { echo "FAIL log start:"; cat "$store/app.log"; exit 1; }
for line in 'evt_a payment_intent.succeeded pending' 'evt_b charge.refunded pending' 'evt_f customer.created stored' \
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
! grep -qv '^req [0-9]*: evt_[a-z0-9]* [a-z_.]* \(stored\|pending\|duplicate\)$' "$store/app.log" || { echo "FAIL log has other lines"; cat "$store/app.log"; exit 1; }
n=$((n + 7))
# The key never reaches the audit log or stderr; every verify is audited.
for f in "$store/audit.log" "$store/stderr"; do
    ! grep -q "$key" "$f" || { echo "FAIL the key is in $f"; exit 1; }
done
grep -q '"method":"verify"' "$store/audit.log" || { echo "FAIL audit lacks verify"; exit 1; }
grep -q '"cap":"db"' "$store/audit.log" || { echo "FAIL audit lacks db"; exit 1; }
n=$((n + 3))
echo "payhook step 3 ok ($n checks)"
status=0
