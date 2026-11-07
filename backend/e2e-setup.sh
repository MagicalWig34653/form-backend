#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# First-run end to end: empty database -> `bootstrap-admin` (real binary) -> enrollment link in Chromium with a CDP virtual
# authenticator registers a passkey -> passkey login + password. No seeded credentials. Exit 0 ok, 1 failed, 2 environment.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
NAME=p4a-mariadb; PORT=${P3B_PORT:-33417}; WPORT=${E2E_PORT:-4180}
PW=$(openssl rand -hex 16); TMP=$(mktemp -d); APP_PID=""
savelogs() { [ -n "${E2E_LOG_DIR:-}" ] || return 0; mkdir -p "$E2E_LOG_DIR"; for l in "$TMP"/*.log; do [ -f "$l" ] && cp "$l" "$E2E_LOG_DIR/$(basename "$0" .sh)-$(basename "$l")"; done; return 0; }  # CI: keep logs as artifact
cleanup() { savelogs; [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; "$DOCKER" rm -f "$NAME" >/dev/null 2>&1; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
umask 077; openssl rand -hex 32 > "$TMP/server.key"
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
"$DOCKER" run -d --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "${MARIADB_IMAGE:-mariadb:lts}" >/dev/null || { echo "ENV: container"; exit 2; }
for _ in $(seq 90); do
  "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && up=1 && break; sleep 1
done
[ "${up:-0}" = 1 ] || { echo "ENV: db not ready"; exit 2; }
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >>"$TMP/build.log" 2>&1 || { sleep 2; swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >>"$TMP/build.log" 2>&1; } || { echo "ENV: build"; exit 2; }  # retry: the Swift frontend crashes sporadically
(cd pwa && npm run build >/dev/null 2>&1) || { echo "ENV: pwa build"; exit 2; }
BIN=backend/.build/debug/App
export FORM_DB_PORT=$PORT FORM_DB_USER=root FORM_DB_PASSWORD=$PW FORM_DB_NAME=e2e FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1
export FORM_INTERNAL_PORT=$WPORT FORM_PUBLIC_PORT=$((WPORT+100)) E2E_PUBLIC_URL=http://127.0.0.1:$((WPORT+100)) FORM_SCHEMA_FILE=backend/db/schema-p3.sql FORM_PUBLIC_DIR="$PWD/pwa/dist"
export FORM_SERVER_KEY_FILE="$TMP/server.key" FORM_ADMIN_ORIGIN=http://localhost:$WPORT FORM_RP_ID=localhost
"$BIN" migrate >/dev/null 2>&1 || { echo "FAIL migrate"; exit 1; }
PASSWORD=$(openssl rand -hex 12); printf '%s' "$PASSWORD" > "$TMP/bootpw"
OUT=$(FORM_BOOTSTRAP_PASSWORD_FILE="$TMP/bootpw" "$BIN" bootstrap-admin admin 2>&1) || { echo "FAIL bootstrap-admin"; echo "$OUT" | head -3; exit 1; }
LINK=$(printf '%s\n' "$OUT" | sed -n 's/.*): \(http[^ ]*\)$/\1/p' | head -1)
[ -n "$LINK" ] || { echo "FAIL no link in output"; exit 1; }
echo "ok   bootstrap-admin printed an enrollment link (not shown)"
printf '%s\n' "$OUT" | grep -q "$PASSWORD" && { echo "FAIL given password echoed"; exit 1; } || echo "ok   given password not echoed"
second=$("$BIN" bootstrap-admin second 2>&1); echo "$second" | grep -qi "accounts already exist" && echo "ok   second bootstrap refused" || { echo "FAIL second bootstrap not refused"; exit 1; }
"$BIN" serve >"$TMP/app.log" 2>&1 & APP_PID=$!
for _ in $(seq 30); do curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 && break; sleep 1; done
export E2E_SETUP_LINK="$LINK" E2E_PASSWORD="$PASSWORD" E2E_PORT=$WPORT E2E_SPEC=real-setup.spec.ts
(cd pwa && npx playwright test -c e2e-real/playwright.config.ts 2>&1 | tail -15); rc=${PIPESTATUS[0]}
TOKEN=${LINK##*#}
grep -q "$TOKEN" "$TMP/app.log" && { echo "FAIL enrollment token found in app log"; rc=1; } || echo "ok   token not in app log"
grep -q "$PASSWORD" "$TMP/app.log" && { echo "FAIL password found in app log"; rc=1; } || echo "ok   password not in app log"
N=$("$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -N e2e -e 'SELECT COUNT(*) FROM passkeys' 2>/dev/null)
[ "$N" = 1 ] && echo "ok   exactly one passkey stored" || { echo "FAIL passkeys=$N"; rc=1; }
exit $rc
