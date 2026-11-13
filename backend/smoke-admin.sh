#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Smoke test of the real App binary with the admin API configured: migrate, start, GET /admin/api/v1/auth/session.
# Throw-away Docker MariaDB on 127.0.0.1:${P3B_PORT:-33417} (tmpfs), random password and server key per run (memory/tmp only,
# key file mode 0600 removed afterwards). Exit 0 = ok, 1 = check failed, 2 = environment problem.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
IMAGE=${MARIADB_IMAGE:-mariadb:lts}; NAME=$(e2e_name p4a-mariadb); PORT=${P3B_PORT:-$(e2e_pick_port)}; HPORT=${SMOKE_HTTP_PORT:-$(e2e_pick_port)}; PPORT=${SMOKE_PUBLIC_PORT:-$(e2e_pick_port)}
PW=$(openssl rand -hex 16); TMP=$(mktemp -d); KEYFILE="$TMP/server.key"; APP_PID=""
umask 077; openssl rand -hex 32 > "$KEYFILE"; chmod 600 "$KEYFILE"
savelogs() { [ -n "${E2E_LOG_DIR:-}" ] || return 0; mkdir -p "$E2E_LOG_DIR"; for l in "$TMP"/*.log; do [ -f "$l" ] && cp "$l" "$E2E_LOG_DIR/$(basename "$0" .sh)-$(basename "$l")"; done; return 0; }  # CI: keep logs as artifact
cleanup() { savelogs; [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; e2e_cleanup; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
e2e_reap_stale
"$DOCKER" info >/dev/null 2>&1 || { echo "ENV: docker daemon not reachable"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=smoke "$IMAGE" >/dev/null || { echo "ENV: container start failed"; exit 2; }
up=0
for _ in $(seq 90); do
  if "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' smoke >/dev/null 2>&1 && sleep 2 \
     && "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' smoke >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ $up = 1 ] || { echo "ENV: server did not become ready"; exit 2; }
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >>"$TMP/build.log" 2>&1 || { sleep 2; swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >>"$TMP/build.log" 2>&1; } || { echo "ENV: build failed"; exit 2; }  # retry: the Swift frontend crashes sporadically
BIN=backend/.build/debug/App
export FORM_DB_PORT=$PORT FORM_DB_USER=root FORM_DB_PASSWORD=$PW FORM_DB_NAME=smoke FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1
export FORM_INTERNAL_PORT=$HPORT FORM_PUBLIC_PORT=$PPORT FORM_SCHEMA_FILE=backend/db/schema-p3.sql
export FORM_SERVER_KEY_FILE="$KEYFILE" FORM_ADMIN_ORIGIN=http://localhost:$HPORT FORM_RP_ID=localhost
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
"$BIN" migrate >/dev/null 2>&1; check "migrate exit" "$?" "0"
"$BIN" serve >"$TMP/app.log" 2>&1 & APP_PID=$!
for _ in $(seq 30); do curl -fs "http://127.0.0.1:$HPORT/health" >/dev/null 2>&1 && break; sleep 1; done
check "health" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HPORT/health")" "200"
out=$(curl -s -D "$TMP/h.txt" "http://127.0.0.1:$HPORT/admin/api/v1/auth/session")
check "session status" "$(head -1 "$TMP/h.txt" | tr -d '\r' | awk '{print $2}')" "200"
check "session state" "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')" "anonymous"
grep -qi '^set-cookie: __Host-admin_session=.*Secure.*HttpOnly.*SameSite=Lax' "$TMP/h.txt"; check "cookie attributes" "$?" "0"
check "forms without session" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HPORT/admin/api/v1/tenants/00000000-0000-4000-8000-000000000001/forms")" "401"
grep -q "$(cat "$KEYFILE")" "$TMP/app.log" && { echo "FAIL key found in log"; fail=1; } || echo "ok   key not in log"
# the ingest route is live in the real server (it refuses an unsigned request with 403 and an unknown form with 404)
check "ingest: unsigned request is refused" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data 'a=1' "http://127.0.0.1:$PPORT/api/v2/submit/?f=00000000-0000-4000-8000-000000000001")" "404"
check "ingest: GET is not allowed" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PPORT/api/v2/submit/?f=00000000-0000-4000-8000-000000000001")" "405"
# fail closed: wrong key file permissions must stop the server
chmod 644 "$KEYFILE"; "$BIN" serve >"$TMP/app2.log" 2>&1 & P2=$!; sleep 4
if kill -0 $P2 2>/dev/null; then echo "FAIL server started with a world-readable key file"; kill $P2; fail=1; else wait $P2; check "loose key file exit code" "$?" "78"; fi
chmod 600 "$KEYFILE"
exit $fail
