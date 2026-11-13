#!/usr/bin/env python3
"""Stand-in destination for the worker: `dest.py PORT LOG KEYFILE`.
POST /events needs the Authorization in KEYFILE (else 401, line UNAUTH). Each request appends
`RECV <Idempotency-Key> <body>` to LOG; the first one for a key also appends `APPLY <key>` (a
repeat is deduplicated: nothing applied twice) and is answered by the current mode: ok, 500, slow
(0.3 s), stall (30 s, for killing the worker mid-request). `POST /_mode` with that word sets it."""
import socketserver
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, log, keyfile = sys.argv[1:4]
with open(keyfile) as f:
    expected = f.read().rstrip("\n")
mode = "ok"
applied = set()


def record(line):
    with open(log, "a") as f:
        f.write(line + "\n")


class Server(ThreadingHTTPServer):
    def server_bind(self):  # no reverse DNS lookup of 127.0.0.1
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        global mode
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
        if self.path == "/_mode":
            mode = raw
            return self.reply(200)
        if self.path != "/events" or self.headers.get_all("Authorization") != [expected]:
            record("UNAUTH" if self.path == "/events" else "BADPATH")
            return self.reply(401)
        key = self.headers.get("Idempotency-Key", "")
        record("RECV %s %s" % (key, raw))
        if key not in applied:
            applied.add(key)
            record("APPLY " + key)
        if mode == "500":
            return self.reply(500)
        if mode in ("slow", "stall"):
            time.sleep(0.3 if mode == "slow" else 30)
        try:
            self.reply(200)
        except OSError:
            pass

    def log_message(self, *args):
        pass


Server(("127.0.0.1", int(port)), Handler).serve_forever()
