#!/usr/bin/env python3
"""Sign like a flow sender: `sign.py KEY BODY` (or `KEY @FILE`) prints the hex HMAC-SHA256 of the body."""
import hashlib
import hmac
import sys

key, body = sys.argv[1:3]
data = open(body[1:], "rb").read() if body.startswith("@") else body.encode()
print(hmac.new(key.encode(), data, hashlib.sha256).hexdigest())
