#!/usr/bin/env python3
"""Stand-in for the chat webhook: `hook.py PORT EVENTS KEYFILE`.
POST /hook with the Authorization header in KEYFILE: answers by the current mode and appends
`<RESULT>\t<body>` to EVENTS (OK, FAIL500, HANG); a wrong or missing Authorization is a 401 and an
`UNAUTH` line; any other path a 404 and `BADPATH`. `POST /_mode` with body ok, 500 or hang sets the mode
(hang sleeps 4 s, longer than the app's 2 s timeout, then answers 200)."""
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, events, keyfile = sys.argv[1:4]
with open(keyfile) as f:
    expected = f.read().rstrip("\n")
mode = "ok"


def record(line):
    with open(events, "a") as f:
        f.write(line + "\n")


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
        if self.path != "/hook":
            record("BADPATH\t" + self.path)
            return self.reply(404)
        if self.headers.get_all("Authorization") != [expected]:
            record("UNAUTH")
            return self.reply(401)
        if mode == "500":
            record("FAIL500\t" + raw)
            return self.reply(500)
        if mode == "hang":
            record("HANG\t" + raw)
            time.sleep(4)
            try:
                return self.reply(200)
            except OSError:
                return
        record("OK\t" + raw)
        self.reply(200)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", int(port)), Handler).serve_forever()
