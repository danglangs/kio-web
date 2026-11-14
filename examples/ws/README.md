# ws

A WebSocket app in kio-web, routed by the upgrade request's path and open only to clients holding a token.

```
echo my-token > secret/token
kio run set_token.kio --dir secret=./secret --kv auth=auth.kv
kio run app.kio --kv auth=auth.kv --kv counts=:memory: --listen 127.0.0.1:8080
websocat -H 'Authorization: Bearer my-token' ws://127.0.0.1:8080/count
```

| Path | Does |
|---|---|
| `/echo` | echoes each text and binary message |
| `/count` | answers each text message with how many this connection has sent (`counts`, key `count/<conn>`, dropped on close) |
| other | closes with 4404 |

A connection whose upgrade lacks `authorization: Bearer <token>` matching the key `token` in `auth` is closed with 4401; with no token stored, every connection is. Each event sees the same upgrade request, so the check runs on every event.

The token is set by a separate program, so the server never holds write access to it:

```
$ kio check set_token.kio
main : secret read, auth set
$ kio check app.kio | grep '^main'
main             : msg conn data header kind target, conn binary close text, auth get, counts delete get set
```

`./test.sh` stores a token, serves the app on a free port and runs [client.py](client.py), a standard-library WebSocket client: echo, counts per connection, the query ignored, the header name in any case, and 4401/4404 refusals.
