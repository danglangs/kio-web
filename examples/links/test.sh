#!/bin/sh
# Store a token, serve the links app on a free port and exercise every route with curl, then
# restart it on the same store and check that links and counts remain. KIO=path/to/kio.
set -e
status=1
KIO=${KIO:-kio}
cd "$(dirname "$0")"
cp ../../web.kio ../../api.kio .
secret=$(mktemp -d)  # the token file; the stores must be outside any granted Dir
store=$(mktemp -d)
pid=
trap 'if [ -n "$pid" ]; then kill $pid 2>/dev/null; wait $pid 2>/dev/null || true; fi; rm -rf "$secret" "$store" web.kio api.kio; exit $status' EXIT
"$KIO" check app.kio >/dev/null || { echo "app.kio does not check"; "$KIO" check app.kio; exit 1; }
token=links-token-$$-0123456789
printf 'short\n' >"$secret/token"
out=$("$KIO" run set_token.kio --dir secret="$secret" --kv auth="$store/auth.kv" 2>&1)
case "$out" in *'at least 16'*) ;; *) echo "FAIL set_token short: $out"; exit 1 ;; esac
printf '%s\n' "$token" >"$secret/token"
out=$("$KIO" run set_token.kio --dir secret="$secret" --kv auth="$store/auth.kv" 2>&1)
case "$out" in *'token set'*) ;; *) echo "FAIL set_token: $out"; exit 1 ;; esac
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
base=http://127.0.0.1:$port

start() {
    "$KIO" run app.kio --kv links="$store/links.kv" --kv auth="$store/auth.kv" --dir assets=./static \
        --listen 127.0.0.1:$port >/dev/null 2>&1 &
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
# Create: generated and chosen slugs; a taken slug.
check POST /api/links '{"url":"https://a.example/one"}' 201 '"short":"/' "$auth"
check POST /api/links '{"url":"https://b.example/?q=1&r=2","slug":"docs"}' 201 '"slug":"docs"' "$auth"
check POST /api/links '{"url":"https://c.example/","slug":"docs"}' 409 'is taken' "$auth"
check POST /api/links '{"url":"http://d.example/","slug":null}' 201 '"hits":0' "$auth"
# Redirects count hits.
redirect /docs 'https://b.example/?q=1&r=2'
redirect /docs 'https://b.example/?q=1&r=2'
check GET /nope "" 404 'not found'
check GET /a.b "" 404 'not found'
check GET /api/links "" 200 '"hits":2,"short":"/docs"'
# Concurrent hits: 20 at once give exactly 20 more.
pids=
for i in $(seq 20); do
    curl -s -o /dev/null $base/docs &
    pids="$pids $!"
done
wait $pids
check GET /api/links "" 200 '"hits":22,"short":"/docs"'
# Sorting and paging.
redirect /2 'http://d.example/'
check GET '/api/links?limit=1' "" 200 '{"items":[{"hits":22,"short":"/docs"'
check GET '/api/links?offset=1&limit=1' "" 200 '{"items":[{"hits":1,"short":"/2"'
check GET '/api/links?offset=1&limit=1' "" 200 '"total":3'
check GET '/api/links?offset=9' "" 200 '"items":[]'
check GET '/api/links?limit=x' "" 400 'limit must be an integer'
check GET '/api/links?limit=501' "" 400 'limit must be 0 to 500'
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
# Restart on the same store: links and counts remain, and new slugs do not reuse old ones.
stop
start
check GET /api/links "" 200 '"hits":22,"short":"/docs"'
check GET /api/links "" 200 '"total":3'
redirect /docs 'https://b.example/?q=1&r=2'
check GET /api/links "" 200 '"hits":23,"short":"/docs"'
check POST /api/links '{"url":"https://f.example/"}' 201 '"short":"/3"' "$auth"
echo "links ok ($n checks)"
status=0
