#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Flood helper of backend/e2e-body-budget.sh: N parallel UNAUTHENTICATED large bodies against a LOCAL instance, prints a Counter of the
first response line per connection (local test instances only).
Usage: e2e-body-budget-flood.py MODE PORT HOST N SIZE [FORM]
  MODE ingest | admin-rotation | admin-hold   (ingest: POST /api/v2/submit/?f=FORM; admin-*: PUT without cookie)"""
import socket, sys, threading, time, uuid
from collections import Counter

mode, port, host, n, size = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
form = sys.argv[6] if len(sys.argv) > 6 else str(uuid.uuid4())
results = []

def request_head() -> bytes:
    if mode == "ingest":
        return (f"POST /api/v2/submit/?f={form} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/x-www-form-urlencoded\r\n"
                f"X-Kubus-Timestamp: {int(time.time())}\r\nX-Kubus-Signature: {'A' * 86}==\r\nContent-Length: {size}\r\n\r\n").encode()
    path = (f"/admin/api/v1/tenants/{uuid.uuid4()}/key-rotation/objects/{uuid.uuid4()}" if mode == "admin-rotation"
            else f"/admin/api/v1/tenants/{uuid.uuid4()}/forms/{uuid.uuid4()}/entries/{uuid.uuid4()}/hold")
    return (f"PUT {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: {size}\r\n\r\n").encode()

def one() -> None:
    s = None
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=120)
        s.sendall(request_head())
        chunk = b"a=" + b"b" * ((1 << 20) - 2)
        sent = 0
        try:
            while sent < size:
                k = min(len(chunk), size - sent)
                s.sendall(chunk[:k]); sent += k
        except OSError:
            pass   # the server answered and closed early: read the answer below
        line = s.recv(200).split(b"\r\n")[0].decode(errors="replace")
        results.append(line or "EMPTY")
    except Exception as e:
        results.append("ERR " + type(e).__name__)
    finally:
        if s is not None:
            s.close()

threads = [threading.Thread(target=one) for _ in range(n)]
[t.start() for t in threads]
[t.join() for t in threads]
print(dict(Counter(results)))
