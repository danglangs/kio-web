#!/bin/sh
# Run the kio-web tests and the examples. Needs `kio` on PATH, or KIO=path/to/kio.
set -e
KIO=${KIO:-kio}
cd "$(dirname "$0")"
for dir in tests examples/hello; do cp web.kio "$dir/web.kio"; done
cp api.kio http.kio tests/
server=
trap 'if [ -n "$server" ]; then kill $server 2>/dev/null; wait $server 2>/dev/null || true; fi; rm -f tests/web.kio tests/api.kio tests/http.kio examples/hello/web.kio' EXIT
for t in web api; do
    out=$("$KIO" run tests/${t}_test.kio | tail -1)
    [ "$out" = "0" ] || { echo "$t tests failed: check $out"; exit 1; }
done
# http.kio against a local JSON server.
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 tests/http_server.py "$port" &
server=$!
for i in $(seq 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/json" && break
    sleep 0.1
done
out=$("$KIO" run tests/http_test.kio --http api=http://127.0.0.1:$port --http-methods api=POST,PUT,DELETE | tail -1)
[ "$out" = "0" ] || { echo "http tests failed: check $out"; exit 1; }
"$KIO" check examples/hello/app.kio
KIO="$KIO" examples/notes/test.sh
KIO="$KIO" examples/kvnotes/test.sh
KIO="$KIO" examples/sqlnotes/test.sh
KIO="$KIO" examples/ws/test.sh
KIO="$KIO" examples/links/test.sh
KIO="$KIO" examples/payhook/test.sh
echo ok
