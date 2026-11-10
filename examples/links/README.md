# links

A link shortener for a small team, in kio-web: a JSON API behind a bearer token, redirects that count hits, links that can expire, and an HTML page of the top links. Links and counts live in a `Kv` file, so they survive restarts; random slugs come from an `Rng`, timestamps from a `Clock`, and creates and deletes go to a `Log`.

```
cp ../../web.kio ../../api.kio .
echo a-long-random-team-token > secret/token
kio run set_token.kio --dir secret=./secret --kv auth=auth.kv
kio run app.kio --kv links=links.kv --kv auth=auth.kv --dir assets=./static --rng links_rng --clock now --log log=links.log --listen 127.0.0.1:8080
```

For a reproducible run (tests, a replay) fix the two sources (never in production: a seed makes every slug predictable): `--rng links_rng=seed:1 --clock now=fixed:2026-11-09T12:00:00Z`; `--log log=-` writes the log to stderr.

| Route | Does |
|---|---|
| `GET /` | HTML page: the top 20 links by hits |
| `GET /static/<file>` | a file from `assets` |
| `GET /<slug>` | 302 to the link's URL, then counts the hit after the redirect is sent (`add` on `hits/<slug>`, atomic, so concurrent hits are all counted; the client does not wait for it); 410 once a link's `ttl_s` has passed |
| `GET /api/links` | links by hits, most first; `?offset=`, `?limit=` (default 50, at most 500); 400 on a bad value |
| `POST /api/links` | `{"url": .., "slug": optional, "ttl_s": optional}`: 201, 400 (bad JSON, URL, slug or ttl), 409 (slug taken); token needed |
| `DELETE /api/links/<slug>` | 204 or 404; token needed |

A URL must be `http://` or `https://` with a host, at most 2048 bytes, with no spaces or control characters. A slug is 1 to 64 of `A-Z a-z 0-9 _ -`, not `api` or `static`; without one, 7 random base62 characters from `links_rng` name the link (one `int` in `0..62^7`; a taken name is drawn again, up to 5 times). Every link records `created_ms` from `now`; with `ttl_s` (1 second to 10 years) it answers 410 once `created_ms + ttl_s` has passed, and stays listed until deleted. A re-created slug starts at 0 hits: `claim` resets `hits/<slug>`, which a `follow` racing an earlier `delete` could have left behind. The key `token` in `auth` holds the SHA-256 hex of the token, never the token itself; the app hashes the presented `Authorization: Bearer <token>` and compares with `ct_eq` (constant time). A missing or wrong one is a 401. The URL scheme is matched case-insensitively (`HTTPS://x` is accepted and stored as given).

```
$ curl -H "Authorization: Bearer $TOKEN" -d '{"url":"https://example.com/docs","slug":"docs"}' localhost:8080/api/links
{"created_ms":1794225600000,"hits":0,"short":"/docs","slug":"docs","url":"https://example.com/docs"}
$ curl -H "Authorization: Bearer $TOKEN" -d '{"url":"https://example.com/today","ttl_s":86400}' localhost:8080/api/links
{"created_ms":1794225600000,"hits":0,"short":"/k3Zq0Tb","slug":"k3Zq0Tb","ttl_s":86400,"url":"https://example.com/today"}
$ curl -sI localhost:8080/docs | grep location
location: https://example.com/docs
$ curl 'localhost:8080/api/links?limit=1'
{"items":[{"created_ms":1794225600000,"hits":1,"short":"/docs","slug":"docs","url":"https://example.com/docs"}],"limit":1,"offset":0,"total":2}
$ cat links.log
req 3: create docs https://example.com/docs
req 4: create k3Zq0Tb https://example.com/today
```

The token is set by a separate program, so the server can only read it:

```
$ kio check set_token.kio
main : secret read, auth set
$ kio check app.kio | grep -v ': none' | grep -v '^web::\|^api::'
all_links         : links scan
authorized        : auth get
claim             : links delete swap
create            : links delete swap, rng int, clock now_ms, log write
delete            : links delete get, log write
follow            : links get, clock now_ms
generated         : links delete swap, rng int, log write
handle            : links delete get scan swap, auth get, assets read, rng int, clock now_ms, log write
home              : links scan
list              : links scan
main              : req body header_names header_values method target, res send, links add delete get scan swap, auth get, assets read, links_rng int, now now_ms, log write
note              : log write
record_of         : links get
scan_all          : links scan
slug7             : rng int
```

The server reads, scans, swaps, counts and deletes links, reads the token hash, reads files under `static/`, draws integers, reads the clock and writes log lines. It cannot write the token hash, write files, or make requests; `follow` is the only route that asks the clock, and only for a link with a ttl.

Listing is two `scan`s (the `link/` records and the `hits/` counts, 1,000 a page) however many links there are, and a hit is one `get` plus one `add`: with 301 links, `GET /api/links` went from 271 to 13,200 requests/s and redirects from 5,660 to 15,500 (`ab -c 20`, Apple silicon) when `scan` and `add` replaced `keys` plus a `get` per link and a `swap` loop.

`./test.sh` sets a token, serves the app on a free port with `--rng links_rng=seed:1 --clock now=fixed:...` (so the run is reproducible) and checks every route with curl: auth failures, bad JSON, URLs and ttls, taken and reserved slugs, generated slugs of 7 base62 characters, `created_ms` from the fixed clock, redirects and hit counts, 20 concurrent hits counted exactly, paging and sort order, HTML escaping, static files, HEAD, delete, a re-created slug starting at 0 hits, then a restart on the same store 61 s later: links and counts intact, the 60 s link answering 410, and the log holding one `req N: create|delete <slug> <url>` line per create and delete.
