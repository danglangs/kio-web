#!/bin/sh
# payhook step 2: receive, health and signature checks. The key is in the environment, the clock is
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
        --audit "$store/audit.log" --listen 127.0.0.1:$port >/dev/null 2>>"$store/stderr" &
    pid=$!
    for i in $(seq 50); do
        curl -s -o /dev/null $base/health && return
        sleep 0.3
    done
    echo "server did not start"; exit 1
}

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
# Skew: 300 s either way is accepted, 301 is not.
stripe "$ev" 200 '{"received":true}' $((now_s - 300))
stripe "$ev" 200 '{"received":true}' $((now_s + 300))
stripe "$ev" 400 'tolerance' $((now_s - 301))
stripe "$ev" 400 'tolerance' $((now_s + 301))
stripe "$ev" 400 'tolerance' 0
# Several v1 entries: any one may match (key rotation).
good=$(sig "$ev")
bad="t=$now_s,v1=$(printf '0%.0s' $(seq 64))"
check POST /stripe "$ev" 200 '{"received":true}' "$bad,v1=${good#*v1=}"
check POST /stripe "$ev" 200 '{"received":true}' "$good,v1=$(printf '0%.0s' $(seq 64))"
check POST /stripe "$ev" 200 '{"received":true}' "t=$now_s, v1=${good#*v1=}"
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
# The key never reaches the audit log or stderr; every verify is audited.
for f in "$store/audit.log" "$store/stderr"; do
    ! grep -q "$key" "$f" || { echo "FAIL the key is in $f"; exit 1; }
done
grep -q '"method":"verify"' "$store/audit.log" || { echo "FAIL audit lacks verify"; exit 1; }
n=$((n + 2))
echo "payhook step 2 ok ($n checks)"
status=0
