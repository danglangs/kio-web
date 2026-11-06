#!/bin/sh
# Serve the notes app on a free port and exercise every route with curl. KIO=path/to/kio.
set -e
KIO=${KIO:-kio}
cd "$(dirname "$0")"
cp ../../web.kio ../../json.kio .
data=$(mktemp -d)
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
"$KIO" run app.kio --dir notes="$data" --listen 127.0.0.1:$port >/dev/null 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; wait $pid 2>/dev/null; rm -rf "$data" web.kio json.kio' EXIT
for i in $(seq 50); do
    curl -s -o /dev/null http://127.0.0.1:$port/ && break
    sleep 0.3
done
n=0
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
check POST /notes '{"title":"b \"q\"","body":"second"}' 201 '"id":2'
check GET /notes/2 "" 200 'b \"q\"'
check GET /notes "" 200 '"body":"first"'
check GET /notes/9 "" 404 'no note 9'
check GET /notes/x "" 400 'integer'
check POST /notes '{"title":"a"' 400 'at byte'
check POST /notes '{"title":"a"}' 400 'field \"body'
check POST /notes '{"title":1,"body":"x"}' 400 'field \"title'
check PUT /notes/1 '{}' 501 'no `overwrite`'
check DELETE /notes/1 "" 501 'no `delete`'
check GET /nope "" 404 'not found'
echo "notes ok ($n checks)"
