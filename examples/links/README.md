# links

A link shortener for a small team, in kio-web: a JSON API behind a bearer token, redirects that count hits, and an HTML page of the top links. Links and counts live in a `Kv` file, so they survive restarts.

```
cp ../../web.kio ../../api.kio .
echo a-long-random-team-token > secret/token
kio run set_token.kio --dir secret=./secret --kv auth=auth.kv
kio run app.kio --kv links=links.kv --kv auth=auth.kv --dir assets=./static --listen 127.0.0.1:8080
```

| Route | Does |
|---|---|
| `GET /` | HTML page: the top 20 links by hits |
| `GET /static/<file>` | a file from `assets` |
| `GET /<slug>` | 302 to the link's URL; counts the hit (`swap`, retried, so concurrent hits are all counted) |
| `GET /api/links` | links by hits, most first; `?offset=`, `?limit=` (default 50, at most 100); 400 on a bad value |
| `POST /api/links` | `{"url": .., "slug": optional}`: 201, 400 (bad JSON, URL or slug), 409 (slug taken); token needed |
| `DELETE /api/links/<slug>` | 204 or 404; token needed |

A URL must be `http://` or `https://` with a host, at most 2048 bytes, with no spaces or control characters. A slug is 1 to 64 of `A-Z a-z 0-9 _ -`, not `api` or `static`; without one, the next value of a counter in base62 names the link. The token is the key `token` in `auth`, compared against `Authorization: Bearer <token>`; a missing or wrong one is a 401.

```
$ curl -H "Authorization: Bearer $TOKEN" -d '{"url":"https://example.com/docs","slug":"docs"}' localhost:8080/api/links
{"hits":0,"short":"/docs","slug":"docs","url":"https://example.com/docs"}
$ curl -sI localhost:8080/docs | grep location
location: https://example.com/docs
$ curl 'localhost:8080/api/links?limit=1'
{"items":[{"hits":1,"short":"/docs","slug":"docs","url":"https://example.com/docs"}],"limit":1,"offset":0,"total":1}
```

The token is set by a separate program, so the server can only read it:

```
$ kio check set_token.kio
main : secret read, auth set
$ kio check app.kio | grep -v ': none' | grep -v '^web::\|^api::'
all_links        : links get keys
authorized       : auth get
claim            : links swap
create           : links get swap
delete           : links get swap
follow           : links get swap
generated        : links get swap
handle           : links get keys swap, auth get, assets read
home             : links get keys
list             : links get keys
load             : links get
main             : req body header_names header_values method target, res send, links get keys swap, auth get, assets read
take_id          : links get swap
```

The server reads and swaps links, reads the token and reads files under `static/`. It cannot write the token, write files, or make requests.

`./test.sh` sets a token, serves the app on a free port and checks every route with curl: auth failures, bad JSON and URLs, taken and reserved slugs, redirects and hit counts, 20 concurrent hits counted exactly, paging and sort order, HTML escaping, static files, delete, and a restart on the same store with links and counts intact.
