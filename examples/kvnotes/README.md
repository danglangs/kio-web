# kvnotes

The [notes](../notes) API over one granted `Kv` instead of a `Dir`, in kio-web. Same routes, same responses.

```
cp ../../web.kio ../../json.kio ../../api.kio .
kio run app.kio --kv notes=:memory: --listen 127.0.0.1:8080
```

`:memory:` is lost on exit; `--kv notes=path/to/file` keeps notes across runs. Under `--listen` one store is shared by all requests.

```
$ kio check app.kio | grep -v ': none'
main, handle : notes get keys set swap
create : notes get set swap
take_id : notes get swap
replace, delete : notes get swap
list : notes get keys
show, load : notes get
```

The app can read and write keys in the store. It cannot make requests or touch anything else.

Storage: note `n` is the key `note/n` holding its JSON; the counter is the key `next`. POST claims an id with `swap("next", old, Some(old + 1))` and reads again when it returns `false`, so racing POSTs get distinct ids. GET /notes is `keys("note/")`. PUT and DELETE `swap` against the value they just read, so a concurrent change makes them retry instead of overwriting it. Ids are never reused.

`./test.sh` serves the app on a free port, exercises every route with curl, and checks that 8 concurrent POSTs get distinct ids.
