# notes

A JSON notes API over one granted `Dir`, in kio-web.

```
cp ../../web.kio ../../json.kio ../../api.kio .
kio run app.kio --dir notes=./data --listen 127.0.0.1:8080
```

```
$ kio check app.kio | grep -v ': none'
main : req body header_names header_values method target, res send, notes create read
handle : notes create read
create : notes create read
store  : notes create read
list, load, show, next_id, exists : notes read
```

The app can read and create files in `data/`. It cannot list, overwrite or delete them, make requests, or touch anything else.

```
$ curl -d '{"title":"milk","body":"2 litres"}' localhost:8080/notes
{"body":"2 litres","id":1,"title":"milk"}
$ curl localhost:8080/notes/1
$ curl localhost:8080/notes
[{"body":"2 litres","id":1,"title":"milk"}]
$ curl -d '{"title":' localhost:8080/notes
{"error":"..."}                                   # 400, json.kio's message
$ curl -X PUT localhost:8080/notes/1              # 501: Dir has no `overwrite` method
$ curl -X DELETE localhost:8080/notes/1           # 501: Dir has no `delete` method
```

Ids: note `n` is the file `n.json`. `Dir` cannot list, so POST and GET /notes probe `read` for 1, 2, 3.. until the first gap. `create` refuses to overwrite, so two racing POSTs cannot take one id; the loser probes on. Cost is linear in the number of notes per request.

`./test.sh` serves the app on a free port and exercises every route with curl.
