#!/usr/bin/env python3
"""Sign like Stripe: `sign.py KEY TS BODY` prints `t=TS,v1=<hex hmac-sha256 of "TS.BODY">`."""
import hashlib
import hmac
import sys

key, ts, body = sys.argv[1:4]
mac = hmac.new(key.encode(), (ts + "." + body).encode(), hashlib.sha256).hexdigest()
print("t=%s,v1=%s" % (ts, mac))
