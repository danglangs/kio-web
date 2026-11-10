#!/usr/bin/env python3
"""A small JSON server for tests/http_test.kio: `http_server.py PORT`."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, status, body, ctype="application/json"):
        data = body.encode()
        self.send_response(status)
        if data:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/json":
            self.reply(200, '{"ok":true}')
        elif self.path == "/text":
            self.reply(200, "not json", "text/plain")
        else:
            self.reply(404, '{"error":"no such thing"}')

    def echo(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
        body = json.loads(raw) if raw else None
        self.reply(200, json.dumps({
            "method": self.command,
            "path": self.path,
            "content_type": self.headers.get("Content-Type"),
            "body": body,
        }))

    do_POST = echo
    do_PUT = echo

    def do_DELETE(self):
        self.reply(204, "")

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
