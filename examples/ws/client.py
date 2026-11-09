"""Exercise the ws app on 127.0.0.1:PORT with token TOKEN: python3 client.py PORT TOKEN

A minimal RFC 6455 client over the standard library (handshake, masked frames), so the test
needs nothing installed.
"""
import base64
import hashlib
import os
import socket
import struct
import sys

PORT, TOKEN = int(sys.argv[1]), sys.argv[2]
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Ws:
    def __init__(self, path, headers=()):
        self.s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
        key = base64.b64encode(os.urandom(16))
        lines = [
            f"GET {path} HTTP/1.1",
            f"Host: 127.0.0.1:{PORT}",
            "Connection: Upgrade",
            "Upgrade: websocket",
            "Sec-WebSocket-Version: 13",
            f"Sec-WebSocket-Key: {key.decode()}",
            *headers,
        ]
        self.s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        head = b""
        while not head.endswith(b"\r\n\r\n"):
            b = self.s.recv(1)
            if not b:
                raise RuntimeError(f"connection closed during the handshake: {head!r}")
            head += b
        want = base64.b64encode(hashlib.sha1(key + GUID).digest())
        if not head.startswith(b"HTTP/1.1 101") or want not in head:
            raise RuntimeError(f"upgrade refused: {head!r}")

    def send(self, opcode, payload):
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            head = struct.pack("!BB", 0x80 | opcode, 0x80 | n)
        elif n < 65536:
            head = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, n)
        else:
            head = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, n)
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.s.sendall(head + mask + body)

    def exact(self, n):
        out = b""
        while len(out) < n:
            b = self.s.recv(n - len(out))
            if not b:
                raise RuntimeError("connection closed")
            out += b
        return out

    def recv(self):
        """The next frame other than a ping or pong: (opcode, payload)."""
        while True:
            b0, b1 = self.exact(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self.exact(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self.exact(8))[0]
            op, payload = b0 & 0x0F, self.exact(n)
            if op not in (9, 10):
                return op, payload

    def text(self, s):
        self.send(1, s.encode())
        op, p = self.recv()
        if op != 1:
            raise RuntimeError(f"want a text frame, got opcode {op} {p!r}")
        return p.decode()

    def closed_with(self):
        """The code of the server's close frame, answered."""
        op, p = self.recv()
        if op != 8:
            raise RuntimeError(f"want a close frame, got opcode {op} {p!r}")
        self.send(8, p[:2])
        self.s.close()
        return struct.unpack("!H", p[:2])[0]

    def hang_up(self):
        self.send(8, struct.pack("!H", 1000))
        self.closed_with()


checks = 0


def check(name, got, want):
    global checks
    if got != want:
        sys.exit(f"FAIL {name}: want {want!r}, got {got!r}")
    checks += 1


auth = f"Authorization: Bearer {TOKEN}"

ws = Ws("/echo", [auth])
check("echo text", ws.text("hi ü"), "hi ü")
ws.send(2, b"\x00\x01\xff")
check("echo binary", ws.recv(), (2, b"\x00\x01\xff"))
ws.hang_up()

ws = Ws("/count", [auth])
check("count 1", ws.text("a"), "1")
check("count 2", ws.text("b"), "2")
check("count 3", ws.text("c"), "3")
ws.hang_up()
# Counts are per connection; the query is not part of the path; the header name is in any case.
ws = Ws("/count?from=test", [f"AUTHORIZATION: Bearer {TOKEN}"])
check("count on a new connection", ws.text("a"), "1")
ws.hang_up()

check("no token", Ws("/echo").closed_with(), 4401)
check("wrong token", Ws("/echo", ["Authorization: Bearer nope"]).closed_with(), 4401)
check("not bearer", Ws("/echo", [f"Authorization: {TOKEN}"]).closed_with(), 4401)
check("unknown path", Ws("/nope", [auth]).closed_with(), 4404)

print(f"ws ok ({checks} checks)")
