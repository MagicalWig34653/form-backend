#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Raw-socket client for backend/e2e-body-budget-wait.sh (card 01480C4B, local test instances only).
Replays a request captured by `e2e-mail-resilience-submit.php capture` over ONE TCP connection with a huge send buffer, so the WHOLE request is
accepted by the kernel at once (it does not matter that the server does not read while the request waits in the body-budget queue), waits
ABORT_SECONDS and then closes the connection: a client that uploaded everything and gave up. The unsent rest stays in the kernel and reaches the
server after the close, followed by the FIN. Nothing is read from the server (a real giving-up client does not read either).
Prints "sent <bytes> sndbuf=<effective>" and "closed". Usage: e2e-raw-abort.py HOST PORT REQUEST_FILE ABORT_SECONDS"""
import socket, sys, time

host, port, path, abort_after = sys.argv[1], int(sys.argv[2]), sys.argv[3], float(sys.argv[4])
data = open(path, "rb").read()
s = socket.create_connection((host, port), timeout=60)
for size in (16 << 20, 8 << 20, 4 << 20):
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, size)
        break
    except OSError:
        continue
t = time.time()
sent = 0
s.settimeout(abort_after)
try:
    sent = s.send(memoryview(data)[:0])
    while sent < len(data):
        sent += s.send(memoryview(data)[sent:sent + (1 << 20)])
except socket.timeout:
    pass   # more than the buffers hold: the client gives up in the middle of the upload (reported)
print(f"sent {sent} of {len(data)} bytes in {time.time() - t:.2f}s sndbuf={s.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)}", flush=True)
time.sleep(max(0.0, abort_after - (time.time() - t)))
s.close()
print("closed", flush=True)
