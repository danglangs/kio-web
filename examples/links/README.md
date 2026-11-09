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
| `GET /<slug>` | 302 to the link's URL; counts the hit (`add` on `hits/<slug>`, atomic, so concurrent hits are all counted) |
| `GET /api/links` | links by hits, most first; `?offset=`, `?limit=` (default 50, at most 500); 400 on a bad value |
| `POST /api/links` | `{"url": .., "slug": optional}`: 201, 400 (bad JSON, URL or slug), 409 (slug taken); token needed |
| `DELETE /api/links/<slug>` | 204 or 404; token needed |

A URL must be `http://` or `https://` with a host, at most 2048 bytes, with no spaces or control characters. A slug is 1 to 64 of `A-Z a-z 0-9 _ -`, not `api` or `static`; without one, the next value of a counter in base62 names the link. The key `token` in `auth` holds the SHA-256 hex of the token, never the token itself; the app hashes the presented `Authorization: Bearer <token>` and compares with `ct_eq` (constant time). A missing or wrong one is a 401. The URL scheme is matched case-insensitively (`HTTPS://x` is accepted and stored as given).

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
all_links         : links scan
authorized        : auth get
claim             : links swap
create            : links get swap
delete            : links delete get
follow            : links add get
generated         : links get swap
handle            : links add delete get scan swap, auth get, assets read
home              : links scan
list              : links scan
main              : req body header_names header_values method target, res send, links add delete get scan swap, auth get, assets read
scan_all          : links scan
take_id           : links get swap
url_of            : links get
```

The server reads, scans, swaps, counts and deletes links, reads the token hash and reads files under `static/`. It cannot write the token hash, write files, or make requests.

Listing is two `scan`s (the `link/` records and the `hits/` counts, 1,000 a page) however many links there are, and a hit is one `get` plus one `add`: with 301 links, `GET /api/links` went from 271 to 13,200 requests/s and redirects from 5,660 to 15,500 (`ab -c 20`, Apple silicon) when `scan` and `add` replaced `keys` plus a `get` per link and a `swap` loop.

`./test.sh` sets a token, serves the app on a free port and checks every route with curl: auth failures, bad JSON and URLs, taken and reserved slugs, redirects and hit counts, 20 concurrent hits counted exactly, paging and sort order, HTML escaping, static files, HEAD, delete, and a restart on the same store with links and counts intact.
