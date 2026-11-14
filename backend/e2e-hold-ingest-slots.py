#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Holder for backend/e2e-mail-resilience.sh: occupies all ingest slots of a LOCAL instance (IngestGate, 16 submissions in flight per replica).
It opens COUNT connections to the ingest endpoint of an existing form, each declares a body of SIZE bytes, sends only a few bytes and keeps the
connection open for HOLD seconds. The slots stay taken, so a further submission is refused at once with 503 ingest_busy + Retry-After: 1.
Prints "held" once all heads are sent and the server has not answered any of them, "released" at the end; exits 3 when the server answered early.
Local test instances only.
Usage: e2e-hold-ingest-slots.py PORT HOST FORM_ID COUNT SIZE HOLD_SECONDS"""
import socket, sys, time

port, host, form, count, size, hold = int(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), float(sys.argv[6])
socks = []
for _ in range(count):
    s = socket.create_connection(("127.0.0.1", port), timeout=30)
    head = (f"POST /api/v2/submit/?f={form} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/x-www-form-urlencoded\r\n"
            f"X-Kubus-Timestamp: {int(time.time())}\r\nX-Kubus-Signature: {'A' * 86}==\r\nContent-Length: {size}\r\n\r\n").encode()
    s.sendall(head + b"a=" + b"b" * 1022)
    socks.append(s)
time.sleep(1)
for s in socks:
    s.settimeout(0.5)
    try:
        answer = s.recv(200).split(b"\r\n")[0].decode(errors="replace")
        print(f"answered early (slot NOT held): {answer}", flush=True)
        sys.exit(3)
    except socket.timeout:
        pass   # still waiting for the body: the slot is held
print("held", flush=True)
time.sleep(hold)
for s in socks:
    s.close()
print("released", flush=True)
