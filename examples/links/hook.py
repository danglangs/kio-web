#!/usr/bin/env python3
"""The webhook receiver for test.sh: `hook.py PORT EVENTS KEYFILE`. A POST whose Authorization is the
line in KEYFILE (`Bearer ...`) is a 200 and its body a line of EVENTS; any other is a 401 and an
`unauthorized` line."""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, events, keyfile = sys.argv[1:4]
with open(keyfile) as f:
    expected = f.read().rstrip("\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
        ok = self.headers.get_all("Authorization") == [expected]
        with open(events, "a") as f:
            f.write((raw if ok else "unauthorized") + "\n")
        self.send_response(200 if ok else 401)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(port)), Handler).serve_forever()
