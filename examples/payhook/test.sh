#!/bin/sh
# payhook step 1: serve the app on a free port and exercise receive and health. KIO=path/to/kio.
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

start() {
    "$KIO" run app.kio --audit "$store/audit.log" --listen 127.0.0.1:$port >/dev/null 2>>"$store/stderr" &
    pid=$!
    for i in $(seq 50); do
        curl -s -o /dev/null $base/health && return
        sleep 0.3
    done
    echo "server did not start"; exit 1
}

n=0
# check METHOD PATH BODY EXPECTED-STATUS EXPECTED-BODY-SUBSTRING
check() {
    out=$(curl -s -w ' %{http_code}' -X "$1" ${3:+-d "$3"} $base$2)
    case "$out" in
    *"$5"*" $4") ;;
    *) echo "FAIL $1 $2 $3: want $4 containing $5, got $out"; exit 1 ;;
    esac
    n=$((n + 1))
}

start
check GET /health "" 200 'ok'
check POST /health "" 404 'not found'
check GET /nope "" 404 'not found'
check GET /stripe "" 404 'not found'
check POST /stripe '{"id":"evt_1","type":"payment_intent.succeeded","created":1,"data":{"object":{}}}' 200 '{"received":true}'
check POST /stripe '{"id":"evt_2","type":"other.thing"}' 200 '{"received":true}'
check POST /stripe '{"id":' 400 'at byte'
check POST /stripe '' 400 'error'
check POST /stripe '[1]' 400 'field \"id\"'
check POST /stripe '{"id":5,"type":"x"}' 400 'field \"id\"'
check POST /stripe '{"id":"evt_3"}' 400 'field \"type\"'
echo "payhook step 1 ok ($n checks)"
status=0
