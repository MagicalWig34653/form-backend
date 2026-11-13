#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SFTP client against a real OpenSSH server (atmoz/sftp in Docker on 127.0.0.1): host key pinning, auth, file operations and the SDK installer.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
NAME=p7u-sftp; PORT=${SFTP_PORT:-33422}; PW=$(openssl rand -hex 12)
cleanup() { "$DOCKER" rm -fv "$NAME" >/dev/null 2>&1; echo "cleanup: container $NAME removed"; }
trap cleanup EXIT
"$DOCKER" rm -fv "$NAME" >/dev/null 2>&1
"$DOCKER" run -d --name "$NAME" -p "127.0.0.1:$PORT:22" "${SFTP_IMAGE:-atmoz/sftp}" "sftpuser:$PW:::upload" >/dev/null || { echo "ENV: container"; exit 2; }
for _ in $(seq 40); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 1; done
sleep 2
FP=$("$DOCKER" exec "$NAME" ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}')
SFTP_TEST_PORT=$PORT SFTP_TEST_USER=sftpuser SFTP_TEST_PASSWORD=$PW SFTP_TEST_BASE=/upload SFTP_TEST_FINGERPRINT=$FP \
  swift test --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --filter SFTPClientTests 2>&1 | grep -E "error|passed|failed|Executed|skipped|LAP" | tail -12
exit ${PIPESTATUS[0]}
