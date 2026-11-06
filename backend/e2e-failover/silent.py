# SPDX-License-Identifier: AGPL-3.0-only
# Accepts TCP connections and never answers (a primary that is connected but mute). Usage: silent.py PORT
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(16)
keep = []
while True:
    c, _ = s.accept()
    keep.append(c)
