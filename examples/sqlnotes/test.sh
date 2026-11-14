#!/bin/sh
# Serve the sqlnotes app on a free port over a database file, exercise every route with curl,
# then restart it and check the notes survived. KIO=path/to/kio.
set -e
status=1
KIO=${KIO:-kio}
cd "$(dirname "$0")"
data=$(mktemp -d)  # the database, and scratch for concurrent responses
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
"$KIO" check app.kio >/dev/null || { echo "app.kio does not check"; "$KIO" check app.kio; exit 1; }
pid=
trap 'kill $pid 2>/dev/null; wait $pid 2>/dev/null || true; rm -rf "$data"; exit $status' EXIT
serve() {
    "$KIO" run app.kio --db notes="$data/notes.db" --listen 127.0.0.1:$port >/dev/null 2>&1 &
    pid=$!
    for i in $(seq 50); do
        curl -s -o /dev/null http://127.0.0.1:$port/ && break
        sleep 0.3
    done
}
serve
n=0
pids=
# check METHOD PATH BODY EXPECTED-STATUS EXPECTED-BODY-SUBSTRING
check() {
    out=$(curl -s -w ' %{http_code}' -X "$1" ${3:+-d "$3"} http://127.0.0.1:$port$2)
    case "$out" in
    *"$5"*" $4") ;;
    *) echo "FAIL $1 $2: want $4 containing $5, got $out"; exit 1 ;;
    esac
    n=$((n + 1))
}
check GET /notes "" 200 '[]'
check POST /notes '{"title":"a","body":"first"}' 201 '"id":1'
check POST /notes '{"title":"b \"q\"; DROP TABLE notes; --","body":"second"}' 201 '"id":2'
check GET /notes/2 "" 200 'DROP TABLE notes'
check GET /notes "" 200 '"body":"first"'
check GET /notes/9 "" 404 'no note 9'
check GET /notes/x "" 400 'integer'
check POST /notes '{"title":"a"' 400 'at byte'
check POST /notes '{"title":"a"}' 400 'field \"body'
check POST /notes '{"title":1,"body":"x"}' 400 'field \"title'
check PUT /notes/1 '{"title":"a2","body":"edited"}' 200 '"body":"edited"'
check GET /notes/1 "" 200 '"title":"a2"'
check PUT /notes/9 '{"title":"a","body":"b"}' 404 'no note 9'
check PUT /notes/1 '{"title":"a"}' 400 'field \"body'
check PUT /notes/1 '{"title":' 400 'at byte'
check DELETE /notes/1 "" 204 ''
check GET /notes/1 "" 404 'no note 1'
check DELETE /notes/1 "" 404 'no note 1'
check POST /notes '{"title":"c","body":"third"}' 201 '"id":3'
check GET /notes "" 200 '"id":2'
check GET '/notes?limit=1' "" 200 '"id":2'
check GET '/notes?offset=1&limit=1' "" 200 '"id":3'
check GET '/notes?limit=x' "" 400 'integer'
check GET /nope "" 404 'not found'
# Racing POSTs must all get distinct ids.
for i in 1 2 3 4 5 6 7 8; do
    curl -s -X POST -d '{"title":"r","body":"x"}' http://127.0.0.1:$port/notes >"$data/r.$i" &
    pids="$pids $!"
done
wait $pids
ids=$(cat "$data"/r.[1-8] | grep -o '"id":[0-9]*' | sort -u | wc -l)
[ "$ids" -eq 8 ] || { echo "FAIL concurrent POST: $ids distinct ids, want 8"; exit 1; }
n=$((n + 1))
# The file keeps the notes across a restart.
kill $pid; wait $pid 2>/dev/null || true
serve
check GET /notes/2 "" 200 '"id":2'
check GET '/notes?offset=9' "" 200 '"id":11'
echo "sqlnotes ok ($n checks)"
status=0
