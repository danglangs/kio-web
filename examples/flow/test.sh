#!/bin/sh
# flow F1.1: POST /events end to end: signatures, 202 after commit, replays, bad bodies, and that
# a restart keeps the rows. Signs with sign.py (Python hmac). Then F1.2: the worker against dest.py
# (dedup by Idempotency-Key): retries with backoff, a SIGKILL between POST and done, two workers.
# KIO=path/to/kio.
set -e
status=1
KIO=${KIO:-kio}
cd "$(dirname "$0")"
store=$(mktemp -d)
pid=
dest=
trap 'for p in $pid $dest; do kill $p 2>/dev/null; wait $p 2>/dev/null || true; done; rm -rf "$store"; exit $status' EXIT
export FLOW_KEY=flow_test_$$_0123456789abcdef
key=$FLOW_KEY
"$KIO" check app.kio --grants app.grants >/dev/null || { "$KIO" check app.kio --grants app.grants; exit 1; }
FLOW_KEY=$key "$KIO" test app.kio --grants test.grants >/dev/null || { "$KIO" test app.kio --grants test.grants; exit 1; }
"$KIO" check worker.kio --grants worker.grants >/dev/null || { "$KIO" check worker.kio --grants worker.grants; exit 1; }
FLOW_KEY=$key "$KIO" test worker.kio --grants test.grants >/dev/null || { FLOW_KEY=$key "$KIO" test worker.kio --grants test.grants; exit 1; }
grep -v -e '^--db ' -e '^--listen ' app.grants >"$store/run.grants"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
base=http://127.0.0.1:$port
start() {
    "$KIO" run app.kio --grants "$store/run.grants" --db db="$store/flow.db" \
        --listen 127.0.0.1:$port >/dev/null 2>>"$store/stderr" &
    pid=$!
    for i in $(seq 50); do
        # the first POST also creates the table; 401 shows the server is up
        [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST $base/events)" = 401 ] && return
        sleep 0.3
    done
    echo "server did not start"; exit 1
}
stop() { kill $pid; wait $pid 2>/dev/null || true; pid=; }
rows() { python3 db.py "$store/flow.db" "SELECT id,state,attempts FROM jobs ORDER BY rowid"; }
count() { rows | wc -l | tr -d ' '; }
n=0
# check BODY EXPECTED-STATUS EXPECTED-BODY-SUBSTRING [SIGNATURE-HEADER-VALUE | -]: POST /events,
# signed over BODY unless a fifth argument is given ("-" sends no header).
check() {
    if [ $# -lt 4 ]; then set -- "$1" "$2" "$3" "$(python3 sign.py "$key" "$1")"; fi
    if [ "$4" = - ]; then
        out=$(curl -s -w ' %{http_code}' -X POST -d "$1" $base/events)
    else
        out=$(curl -s -w ' %{http_code}' -X POST -d "$1" -H "X-Signature: $4" $base/events)
    fi
    case "$out" in
    *"$3"*" $2") ;;
    *) echo "FAIL POST $1 [$4]: want $2 containing $3, got $out"; exit 1 ;;
    esac
    n=$((n + 1))
}
want_rows() { [ "$(rows)" = "$1" ] || { echo "FAIL rows: want '$1', got '$(rows)'"; exit 1; }; n=$((n + 1)); }

start
e1='{"id":"e1","kind":"order.paid","n":1}'
check "$e1" 202 '{"accepted":true}'
want_rows 'e1|pending|0'
# The row is durable when the 202 arrives: read it with another process, immediately.
e2='{"id":"e2"}'
check "$e2" 202 accepted
want_rows 'e1|pending|0
e2|pending|0'
# Replays: 200, nothing changes, even with another body.
check "$e1" 200 '{"duplicate":true}'
check '{"id":"e1","kind":"other"}' 200 duplicate
[ "$(python3 db.py "$store/flow.db" "SELECT body FROM jobs WHERE id='e1'")" = "$e1" ] || { echo "FAIL first body replaced"; exit 1; }
[ "$(count)" = 2 ] || { echo "FAIL replays added rows"; exit 1; }
# Bad signatures: 401, never stored (even for a new id).
e3='{"id":"e3"}'
good=$(python3 sign.py "$key" "$e3")
check "$e3" 401 'bad signature' "$(python3 sign.py wrong-key "$e3")"
check "$e3" 401 'bad signature' "$(python3 sign.py "$key" "$e3 ")"
check "$e3" 401 'bad signature' "${good}00"
check "$e3" 401 'bad signature' "${good%??}"
check "$e3" 401 'bad signature' "zz${good#??}"
check "$e3" 401 'bad signature' "sha256=$good"
check "$e3" 401 'missing X-Signature' -
check "" 401 'missing X-Signature' -
# A forged signature on malformed JSON is still 401: the body is not read before it is verified.
check '{"id":' 401 'bad signature' "$(python3 sign.py wrong-key '{"id":')"
want_rows 'e1|pending|0
e2|pending|0'
# Signed but not an event: 400, not stored.
check '{"id":' 400 'at byte'
check 'nope' 400 error
check '[1]' 400 'field \"id\"'
check '{"id":5}' 400 'field \"id\"'
check '{"kind":"x"}' 400 'field \"id\"'
check '' 400 error
# Signed bytes that are not UTF-8: 400, not a failed run.
printf '{"id":"\377"}' >"$store/bad.bin"
out=$(curl -s -w ' %{http_code}' -X POST --data-binary @"$store/bad.bin" -H "X-Signature: $(python3 sign.py "$key" @"$store/bad.bin")" $base/events)
case "$out" in *"not UTF-8"*" 400") n=$((n + 1)) ;; *) echo "FAIL non-UTF-8 body: $out"; exit 1 ;; esac
# Other routes and methods.
[ "$(curl -s -o /dev/null -w '%{http_code}' $base/events)" = 404 ] || { echo "FAIL GET /events"; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST $base/nope)" = 404 ] || { echo "FAIL POST /nope"; exit 1; }
want_rows 'e1|pending|0
e2|pending|0'
# Rows survive a restart, and the replay is still a replay.
stop
start
check "$e1" 200 duplicate
check '{"id":"e4"}' 202 accepted
want_rows 'e1|pending|0
e2|pending|0
e4|pending|0'
echo "ok: $n checks"

# ---- F1.2: the worker. The server stays up and takes new events; the worker shares its database.
grep -v -e '^--db ' -e '^--http ' worker.grants >"$store/worker.grants"
dest_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
dest_url=http://127.0.0.1:$dest_port
dlog=$store/dest.log
: >"$dlog"
export DEST_AUTH="Bearer dest-key-$$-7c1e"
printf '%s\n' "$DEST_AUTH" >"$store/dest_auth"
python3 dest.py "$dest_port" "$dlog" "$store/dest_auth" &
dest=$!
mode() { curl -s -o /dev/null -X POST -d "$1" $dest_url/_mode; }
for i in $(seq 50); do mode ok && break; sleep 0.1; done
w=0
# worker: one pass; prints how many jobs it attempted.
worker() {
    "$KIO" run worker.kio --grants "$store/worker.grants" --db db="$store/flow.db" \
        --http dest=$dest_url 2>>"$store/stderr" | tail -1
}
want() { [ "$2" = "$3" ] || { echo "FAIL $1: want '$3', got '$2'"; exit 1; }; w=$((w + 1)); }
state() { python3 db.py "$store/flow.db" "SELECT state,attempts FROM jobs WHERE id='$1'"; }
recv() { grep -c "^RECV $1 " "$dlog" || true; }
apply() { grep -c "^APPLY $1\$" "$dlog" || true; }
ingest() { check "{\"id\":\"$1\"}" 202 accepted; }

# Delivery: the three stored jobs go out once each, with the grant's key and the stored body.
want "first pass" "$(worker)" "Ok(3)"
want "states" "$(python3 db.py "$store/flow.db" "SELECT id,state,attempts FROM jobs ORDER BY rowid")" 'e1|done|1
e2|done|1
e4|done|1'
want "e1 body" "$(grep '^RECV e1 ' "$dlog")" "RECV e1 $e1"
want "e1 sent once" "$(recv e1)" 1
want "nothing unauthorized" "$(grep -c UNAUTH "$dlog" || true)" 0
want "idle pass" "$(worker)" "Ok(0)"

# Failure: 500 means retry after a backoff (1 s, then 2 s); a retry that succeeds is done.
ingest e5
mode 500
want "fail 1" "$(worker)" "Ok(1)"
want "e5 retry" "$(state e5)" "retry|1"
want "not due yet" "$(worker)" "Ok(0)"
sleep 1.2
want "fail 2" "$(worker)" "Ok(1)"
want "e5 retry 2" "$(state e5)" "retry|2"
mode ok
sleep 1
want "backoff doubled" "$(worker)" "Ok(0)"
sleep 1.2
want "retry succeeds" "$(worker)" "Ok(1)"
want "e5 done" "$(state e5)" "done|3"
want "e5 posted 3 times, applied once" "$(recv e5) $(apply e5)" "3 1"

# Crash between the POST and `done`: SIGKILL the worker while the destination holds the reply.
ingest e6
mode stall
"$KIO" run worker.kio --grants "$store/worker.grants" --db db="$store/flow.db" --http dest=$dest_url >/dev/null 2>&1 &
wpid=$!
for i in $(seq 50); do [ "$(recv e6)" = 1 ] && break; sleep 0.1; done
kill -9 $wpid; wait $wpid 2>/dev/null || true
mode ok
want "e6 claimed, worker gone" "$(state e6)" "claimed|1"
want "lease still held" "$(worker)" "Ok(0)"
sleep 3.2
want "lease expired, retried" "$(worker)" "Ok(1)"
want "e6 done on attempt 2" "$(state e6)" "done|2"
want "e6 seen twice, applied once" "$(recv e6) $(apply e6)" "2 1"
want "same key both times" "$(grep -c '^RECV e6 ' "$dlog")" 2

# Two workers on one database: each job is POSTed once (the POST takes 0.3 s, far inside a lease).
for i in 0 1 2 3 4 5 6 7 8 9; do ingest j$i; done
mode slow
( worker >"$store/w1" ) &
p1=$!
( worker >"$store/w2" ) &
p2=$!
wait $p1 $p2
want "all attempted once between them" "$(( $(sed 's/Ok(\(.*\))/\1/' "$store/w1") + $(sed 's/Ok(\(.*\))/\1/' "$store/w2") ))" 10
want "both workers took part" "$(cat "$store/w1" "$store/w2" | grep -c 'Ok(0)' || true)" 0
for i in 0 1 2 3 4 5 6 7 8 9; do
    want "j$i posted once" "$(recv j$i)" 1
done
want "all done" "$(python3 db.py "$store/flow.db" "SELECT count(*) FROM jobs WHERE state='done' AND attempts=1 AND id LIKE 'j%'")" 10
echo "ok: $w worker checks"
status=0
