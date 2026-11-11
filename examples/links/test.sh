#!/bin/sh
# Store a token, serve the links app on a free port and exercise every route with curl, then
# restart it on the same store and check that links and counts remain; a local receiver collects
# the webhook events, each authorized by a header the host adds (the app never holds the key).
# KIO=path/to/kio.
set -e
status=1
KIO=${KIO:-kio}
cd "$(dirname "$0")"
cp ../../web.kio ../../api.kio ../../http.kio .
secret=$(mktemp -d)  # the token file; the stores must be outside any granted Dir
store=$(mktemp -d)
pid=
hook=
trap 'for p in $pid $hook; do kill $p 2>/dev/null; wait $p 2>/dev/null || true; done; rm -rf "$secret" "$store" web.kio api.kio http.kio; exit $status' EXIT
"$KIO" check app.kio --grants app.grants >/dev/null || { echo "app.kio does not check with app.grants"; "$KIO" check app.kio --grants app.grants; exit 1; }
# app.grants less the lines the test replaces (stores, the seeded slugs, the fixed clock, the log,
# the receiver, the port): the assets and the webhook's grants come from app.grants as in production.
grep -v -e '^--kv ' -e '^--rng ' -e '^--clock ' -e '^--log ' -e '^--http ' -e '^--listen ' app.grants >"$store/test.grants"
token=links-token-$$-0123456789
printf 'short\n' >"$secret/token"
out=$("$KIO" run set_token.kio --dir secret="$secret" --kv auth="$store/auth.kv" 2>&1)
case "$out" in *'at least 16'*) ;; *) echo "FAIL set_token short: $out"; exit 1 ;; esac
printf '%s\n' "$token" >"$secret/token"
out=$("$KIO" run set_token.kio --dir secret="$secret" --kv auth="$store/auth.kv" 2>&1)
case "$out" in *'token set'*) ;; *) echo "FAIL set_token: $out"; exit 1 ;; esac
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
port=$(free_port)
base=http://127.0.0.1:$port
# The webhook receiver: each POST body with the right Authorization becomes a line of $events.
hook_port=$(free_port)
events=$store/events
: >"$events"
hook_key=hook-key-$$-5e1d9a07c3b2
printf 'Bearer %s\n' "$hook_key" >"$store/hook_auth"
export HOOK_AUTH="Bearer $hook_key"
python3 hook.py "$hook_port" "$events" "$store/hook_auth" &
hook=$!
# The clock is fixed and the slugs seeded, so a run is reproducible; the restart below moves the
# clock past a link's ttl.
clock=1794225600000  # 2026-11-09T12:00:00Z
log=$store/links.log

start() {
    "$KIO" run app.kio --grants "$store/test.grants" --kv links="$store/links.kv" --kv auth="$store/auth.kv" \
        --rng links_rng=seed:1 --clock now=fixed:$clock --log log="$log" --http hook=http://127.0.0.1:$hook_port \
        --audit "$store/audit.log" --listen 127.0.0.1:$port >/dev/null 2>>"$store/stderr" &
    pid=$!
    for i in $(seq 50); do
        curl -s -o /dev/null $base/ && return
        sleep 0.3
    done
    echo "server did not start"; exit 1
}
stop() { kill $pid; wait $pid 2>/dev/null || true; pid=; }

n=0
# check METHOD PATH BODY EXPECTED-STATUS EXPECTED-BODY-SUBSTRING [AUTH-HEADER]
check() {
    out=$(curl -s -w ' %{http_code}' -X "$1" ${3:+-d "$3"} ${6:+-H "$6"} $base$2)
    case "$out" in
    *"$5"*" $4") ;;
    *) echo "FAIL $1 $2 $3: want $4 containing $5, got $out"; exit 1 ;;
    esac
    n=$((n + 1))
}
auth="Authorization: Bearer $token"
# redirect PATH EXPECTED-LOCATION: a 302 with that location header.
redirect() {
    got=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' $base$1)
    [ "$got" = "302 $2" ] || { echo "FAIL GET $1: want 302 $2, got $got"; exit 1; }
    n=$((n + 1))
}
# settled PATH EXPECTED-BODY-SUBSTRING: a GET answers 200 containing it within 5 s. A hit is
# counted after its redirect is sent, so the count can land just after the client has the 302.
settled() {
    for i in $(seq 50); do
        out=$(curl -s -w ' %{http_code}' $base$1)
        case "$out" in *"$2"*" 200") n=$((n + 1)); return ;; esac
        sleep 0.1
    done
    echo "FAIL GET $1: want 200 containing $2, got $out"; exit 1
}

start
check GET / "" 200 'No links yet.'
check GET /api/links "" 200 '"items":[]'
# Auth failures.
check POST /api/links '{"url":"https://a.example/"}' 401 'bearer token'
check POST /api/links '{"url":"https://a.example/"}' 401 'bearer token' "Authorization: Bearer wrong"
check POST /api/links '{"url":"https://a.example/"}' 401 'bearer token' "Authorization: Basic $token"
check POST /api/links '{"url":"https://a.example/"}' 401 'bearer token' "Authorization: Bearer ${token}x"
check DELETE /api/links/x "" 401 'bearer token'
hdr=$(curl -s -D - -o /dev/null -X POST $base/api/links | tr -d '\r' | grep -i '^www-authenticate:' || true)
[ "$hdr" = "www-authenticate: Bearer" ] || { echo "FAIL www-authenticate: got $hdr"; exit 1; }
n=$((n + 1))
# Bad JSON and bad fields.
check POST /api/links '{"url":' 400 'at byte' "$auth"
check POST /api/links '[1]' 400 'field \"url' "$auth"
check POST /api/links '{"url":5}' 400 'field \"url' "$auth"
check POST /api/links '{"url":"HTTPS://Upper.example/Path","slug":"upper"}' 201 '"url":"HTTPS://Upper.example/Path"' "$auth"
check DELETE /api/links/upper "" 204 '' "$auth"
check POST /api/links '{"url":"ftp://a.example/"}' 400 'http:// or https://' "$auth"
check POST /api/links '{"url":"javascript:alert(1)"}' 400 'http:// or https://' "$auth"
check POST /api/links '{"url":"https:///path"}' 400 'no host' "$auth"
check POST /api/links '{"url":"https://a.example/a b"}' 400 'space or control' "$auth"
check POST /api/links '{"url":"https://a.example/\r\nset-cookie: x"}' 400 'space or control' "$auth"
long=$(python3 -c 'print("https://a.example/" + "a" * 2040)')
check POST /api/links "{\"url\":\"$long\"}" 400 'longer than 2048' "$auth"
check POST /api/links '{"url":"https://a.example/","slug":"a/b"}' 400 'only A-Z' "$auth"
check POST /api/links '{"url":"https://a.example/","slug":""}' 400 '1 to 64' "$auth"
check POST /api/links '{"url":"https://a.example/","slug":"api"}' 400 'reserved' "$auth"
check POST /api/links '{"url":"https://a.example/","slug":7}' 400 'must be a string' "$auth"
# created BODY: a 201 whose generated slug is 7 base62 characters; leaves it in $slug.
b62='[0-9A-Za-z]'
created() {
    out=$(curl -s -w ' %{http_code}' -X POST -d "$1" -H "$auth" $base/api/links)
    case "$out" in *' 201') ;; *) echo "FAIL POST $1: want 201, got $out"; exit 1 ;; esac
    slug=$(printf '%s' "${out% 201}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["slug"])')
    case "$slug" in $b62$b62$b62$b62$b62$b62$b62) ;; *) echo "FAIL generated slug: $slug"; exit 1 ;; esac
    n=$((n + 1))
}
# Create: generated and chosen slugs; a taken slug; the fixed clock as created_ms; a ttl.
created '{"url":"https://a.example/one"}'
first=$slug
check GET /api/links "" 200 "\"created_ms\":$clock,\"hits\":0,\"short\":\"/$first\""
check POST /api/links '{"url":"https://b.example/?q=1&r=2","slug":"docs"}' 201 '"slug":"docs"' "$auth"
check POST /api/links '{"url":"https://c.example/","slug":"docs"}' 409 'is taken' "$auth"
created '{"url":"http://d.example/","slug":null}'
second=$slug
[ "$first" != "$second" ] || { echo "FAIL two generated slugs are the same: $first"; exit 1; }
n=$((n + 1))
check POST /api/links '{"url":"https://t.example/","slug":"temp","ttl_s":60}' 201 '"ttl_s":60' "$auth"
check POST /api/links '{"url":"https://t.example/","slug":"bad","ttl_s":"x"}' 400 'must be an integer' "$auth"
check POST /api/links '{"url":"https://t.example/","slug":"bad","ttl_s":0}' 400 'ttl_s must be 1 to' "$auth"
# Redirects count hits.
redirect /docs 'https://b.example/?q=1&r=2'
redirect /docs 'https://b.example/?q=1&r=2'
check GET /nope "" 404 'not found'
check GET /a.b "" 404 'not found'
settled /api/links '"hits":2,"short":"/docs"'
# Concurrent hits: 20 at once give exactly 20 more.
pids=
for i in $(seq 20); do
    curl -s -o /dev/null $base/docs &
    pids="$pids $!"
done
wait $pids
settled /api/links '"hits":22,"short":"/docs"'
# Sorting and paging.
redirect "/$second" 'http://d.example/'
check GET '/api/links?limit=1' "" 200 "{\"items\":[{\"created_ms\":$clock,\"hits\":22,\"short\":\"/docs\""
settled '/api/links?offset=1&limit=1' "{\"items\":[{\"created_ms\":$clock,\"hits\":1,\"short\":\"/$second\""
check GET '/api/links?offset=1&limit=1' "" 200 '"total":4'
check GET '/api/links?offset=9' "" 200 '"items":[]'
check GET '/api/links?limit=x' "" 400 'limit must be an integer'
check GET '/api/links?limit=501' "" 400 'limit must be 0 to 500'
# A link with a ttl redirects while the clock is before it.
redirect /temp 'https://t.example/'
settled /api/links '"hits":1,"short":"/temp"'
# HTML: escaped, top links in order, the stylesheet from the granted Dir.
check POST /api/links '{"url":"https://e.example/?a=<script>&b=\"x\"","slug":"xss"}' 201 '"slug":"xss"' "$auth"
check GET / "" 200 'https://e.example/?a=&lt;script&gt;&amp;b=&quot;x&quot;'
page=$(curl -s $base/)
case "$page" in *'<script>'*) echo "FAIL GET /: unescaped <script>"; exit 1 ;; esac
case "$page" in *'/docs</a></td><td>https://b.example/?q=1&amp;r=2</td><td class="hits">22<'*) ;; *) echo "FAIL GET /: $page"; exit 1 ;; esac
n=$((n + 2))
check GET /static/style.css "" 200 'border-collapse'
check GET /static/nope.css "" 404 'not found'
check GET /static/../app.kio "" 404 'not found'
check GET /static/ "" 404 'not found'
# HEAD: the GET headers (content-length of the body the handler built), no body.
head=$(curl -s -I $base/static/style.css | tr -d '\r')
len=$(curl -s $base/static/style.css | wc -c | tr -d ' ')
case "$head" in "HTTP/1.1 200"*) ;; *) echo "FAIL HEAD /static/style.css: $head"; exit 1 ;; esac
case "$head" in *"content-length: $len"*) ;; *) echo "FAIL HEAD content-length want $len: $head"; exit 1 ;; esac
case "$head" in *"content-type: text/css"*) ;; *) echo "FAIL HEAD content-type: $head"; exit 1 ;; esac
n=$((n + 3))
# HEAD on a short link redirects without counting a hit (link previews must not inflate counts).
head=$(curl -s -I $base/docs | tr -d '\r')
case "$head" in "HTTP/1.1 302"*) ;; *) echo "FAIL HEAD /docs: $head"; exit 1 ;; esac
n=$((n + 1))
check GET /api/links "" 200 '"hits":22,"short":"/docs"'
# Delete.
check DELETE /api/links/xss "" 204 '' "$auth"
check DELETE /api/links/xss "" 404 'no link xss' "$auth"
check GET /xss "" 404 'not found'
# A re-created slug starts at 0 hits (a follow racing a delete can leave a count behind).
check POST /api/links '{"url":"https://g.example/","slug":"again"}' 201 '"slug":"again"' "$auth"
redirect /again 'https://g.example/'
settled /api/links '"hits":1,"short":"/again"'
check DELETE /api/links/again "" 204 '' "$auth"
check POST /api/links '{"url":"https://g.example/","slug":"again"}' 201 '"hits":0' "$auth"
check GET /api/links "" 200 '"hits":0,"short":"/again"'
check DELETE /api/links/again "" 204 '' "$auth"
# Restart on the same store, 61 s later: links and counts remain, the link with a 60 s ttl is
# gone, and a new generated slug is neither of the earlier ones.
stop
clock=$((clock + 61000))
start
check GET /api/links "" 200 '"hits":22,"short":"/docs"'
check GET /api/links "" 200 '"total":4'
redirect /docs 'https://b.example/?q=1&r=2'
settled /api/links '"hits":23,"short":"/docs"'
check GET /temp "" 410 'has expired'
check GET /api/links "" 200 '"hits":1,"short":"/temp"'
created '{"url":"https://f.example/"}'
[ "$slug" != "$first" ] && [ "$slug" != "$second" ] || { echo "FAIL a generated slug came back: $slug"; exit 1; }
n=$((n + 1))
# The program's log: one `req N: ` line per create and delete, nothing else.
grep -qE '^req [0-9]+: create docs https://b\.example/\?q=1&r=2$' "$log" || { echo "FAIL log lacks the docs create"; cat "$log"; exit 1; }
grep -qE "^req [0-9]+: create $first https://a\.example/one$" "$log" || { echo "FAIL log lacks the first create"; cat "$log"; exit 1; }
grep -qE '^req [0-9]+: delete xss https://e\.example/\?a=<script>&b="x"$' "$log" || { echo "FAIL log lacks the xss delete"; cat "$log"; exit 1; }
[ "$(grep -c '^req [0-9]*: \(create\|delete\) ' "$log")" = "$(wc -l <"$log" | tr -d ' ')" ] || { echo "FAIL log has other lines"; cat "$log"; exit 1; }
n=$((n + 4))
# The webhook: one event per create, sent after the 201, so it may land just after.
for i in $(seq 50); do
    [ "$(wc -l <"$events" | tr -d ' ')" = 9 ] && break
    sleep 0.1
done
[ "$(wc -l <"$events" | tr -d ' ')" = 9 ] || { echo "FAIL want 9 webhook events"; cat "$events"; exit 1; }
! grep -q unauthorized "$events" || { echo "FAIL a webhook lacked the injected Authorization"; cat "$events"; exit 1; }
grep -q '"injected":\["authorization"\]' "$store/audit.log" || { echo "FAIL audit lacks injected"; exit 1; }
for f in "$store/audit.log" "$log" "$store/stderr"; do
    ! grep -q "$hook_key" "$f" || { echo "FAIL the hook key is in $f"; exit 1; }
done
grep -qxF '{"event":"created","slug":"docs","url":"https://b.example/?q=1&r=2"}' "$events" || { echo "FAIL no docs event"; cat "$events"; exit 1; }
grep -qxF "{\"event\":\"created\",\"slug\":\"$first\",\"url\":\"https://a.example/one\"}" "$events" || { echo "FAIL no first event"; cat "$events"; exit 1; }
n=$((n + 6))
echo "links ok ($n checks)"
status=0
