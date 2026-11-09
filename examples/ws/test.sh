#!/bin/sh
# Store a token, serve the ws app on a free port, and exercise it with client.py. KIO=path/to/kio.
set -e
status=1
KIO=${KIO:-kio}
cd "$(dirname "$0")"
cp ../../web.kio .
secret=$(mktemp -d)  # the token file; the store must be outside any granted Dir
store=$(mktemp -d)
pid=
trap 'if [ -n "$pid" ]; then kill $pid 2>/dev/null; wait $pid 2>/dev/null || true; fi; rm -rf "$secret" "$store" web.kio; exit $status' EXIT
"$KIO" check app.kio >/dev/null || { echo "app.kio does not check"; "$KIO" check app.kio; exit 1; }
token=t0k3n-$$
printf '%s\n' "$token" >"$secret/token"
out=$("$KIO" run set_token.kio --dir secret="$secret" --kv auth="$store/auth.kv" 2>&1)
case "$out" in *'token set'*) ;; *) echo "FAIL set_token: $out"; exit 1 ;; esac
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
"$KIO" run app.kio --kv auth="$store/auth.kv" --kv counts=:memory: --listen 127.0.0.1:$port >/dev/null 2>&1 &
pid=$!
for i in $(seq 50); do
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 1)" 2>/dev/null && break
    sleep 0.3
done
python3 client.py "$port" "$token"
status=0
