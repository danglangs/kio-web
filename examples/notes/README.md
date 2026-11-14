# notes

A JSON notes API over one granted `Dir`, in kio-web. [../kvnotes](../kvnotes) is the same API over `Kv`.

```
kio run app.kio --dir notes=./data --listen 127.0.0.1:8080
```

```
$ kio check app.kio | grep -v ': none'
main   : req body header_names header_values method target, res send, notes create exists list read remove write
handle : notes create exists list read remove write
create, store : notes create list
replace : notes exists write
delete : notes remove
list : notes list read
show, load : notes read
ids, next_id : notes list
```

The app can list, read, create, replace and remove files in `data/`. It cannot make requests or touch anything else.

```
$ curl -d '{"title":"milk","body":"2 litres"}' localhost:8080/notes
{"body":"2 litres","id":1,"title":"milk"}
$ curl localhost:8080/notes/1
$ curl localhost:8080/notes
[{"body":"2 litres","id":1,"title":"milk"}]
$ curl -X PUT -d '{"title":"milk","body":"3 litres"}' localhost:8080/notes/1   # 200; 404 if no such note
$ curl -X DELETE localhost:8080/notes/1                                          # 204; 404 if no such note
$ curl -d '{"title":' localhost:8080/notes
{"error":"..."}                                   # 400,'s message
```

Ids: note `n` is the file `n.json`. POST takes the largest listed id plus one and uses `create`, which refuses to overwrite and answers `IoErr::Exists` when a racing POST took the id; the loser lists again and retries. Any other error is a 500. PUT is `exists` then `write` (atomic replace); DELETE is `remove`. Each POST and GET /notes lists the directory once.

`./test.sh` serves the app on a free port, exercises every route with curl, and checks that 8 concurrent POSTs get distinct ids.
