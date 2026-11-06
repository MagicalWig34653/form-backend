#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SMTP/MIME interop against a real mail server with an independent parser (Mailpit, STARTTLS with the synthetic test certificate).
# Exit: swift test's code; 2 = environment problem. Never run two docker-based scripts at once (shared container names/ports).
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
NAME=p4a-mailpit; SMTP=${MAILPIT_SMTP_PORT:-31025}; API=${MAILPIT_API_PORT:-38025}; IMAGE=${MAILPIT_IMAGE:-axllent/mailpit:latest}
FIX="$PWD/backend/Tests/TestSupport/Fixtures"
cleanup() { "$DOCKER" rm -f "$NAME" >/dev/null 2>&1; echo "cleanup: container $NAME removed"; }
trap cleanup EXIT
"$DOCKER" info >/dev/null 2>&1 || { echo "ENV: docker daemon not reachable"; exit 2; }
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
"$DOCKER" run -d --name "$NAME" -p "127.0.0.1:$SMTP:1025" -p "127.0.0.1:$API:8025" -v "$FIX:/certs:ro" \
  -e MP_SMTP_TLS_CERT=/certs/test-cert.pem -e MP_SMTP_TLS_KEY=/certs/test-key.pem -e MP_SMTP_AUTH_ACCEPT_ANY=1 "$IMAGE" >/dev/null || { echo "ENV: container start failed"; exit 2; }
up=0; for _ in $(seq 60); do curl -fs "http://127.0.0.1:$API/api/v1/info" >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
[ $up = 1 ] || { echo "ENV: mailpit did not become ready"; "$DOCKER" logs "$NAME" 2>&1 | tail -5; exit 2; }
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
P4A_MAILPIT_SMTP_PORT=$SMTP P4A_MAILPIT_API_PORT=$API \
  swift test --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --filter MailpitInteropTests "$@"
