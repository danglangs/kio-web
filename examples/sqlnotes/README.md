# sqlnotes

The [notes](../notes) API over one granted `Db` (SQLite) instead of a `Dir` or `Kv`, in kio-web. Same routes, same responses.

```
cp ../../web.kio ../../api.kio .
kio run app.kio --db notes=:memory: --listen 127.0.0.1:8080
```

`:memory:` is lost on exit; `--db notes=path/to/notes.db` keeps notes across runs (a SQLite file in WAL mode). Under `--listen` one connection is shared by all requests, one statement at a time.

```
$ kio check app.kio | grep -v ': none'
main, handle, create, show, list, replace, delete : notes exec query
```

The app can run statements on that database. It cannot attach another file, change the connection's settings, load an extension or touch anything else; the host refuses those statements as `Denied`.

Storage: one table, `notes (id INTEGER PRIMARY KEY, title, body)`, created with `IF NOT EXISTS` at the start of each request (a fresh sandbox per request has no memory of the last). Values reach SQL only as `?` parameters, so a title of `"; DROP TABLE notes; --` is stored as text. POST, PUT and DELETE use `RETURNING`, so one statement both changes a row and says whether it existed; racing POSTs get distinct ids from SQLite. GET /notes pages with `LIMIT ? OFFSET ?`.

`./test.sh` serves the app on a free port over a database file, exercises every route with curl, checks that 8 concurrent POSTs get distinct ids, then restarts the server and checks the notes survived.
