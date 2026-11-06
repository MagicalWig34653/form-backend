#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Statelessness check for Swarm/Kubernetes: two real App instances share one MariaDB.
# Checks: /ready is false before `migrate` and true after; a session created on replica A is valid on replica B
# (and CSRF verifies there); logout on B revokes it on A; DB password via FORM_DB_PASSWORD_FILE works.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
NAME=p4a-mariadb; PORT=${P3B_PORT:-33417}; A=${SMOKE_PORT_A:-38511}; B=${SMOKE_PORT_B:-38512}
PW=$(openssl rand -hex 16); TMP=$(mktemp -d); PIDS=""
umask 077; openssl rand -hex 32 > "$TMP/server.key"; printf '%s\n' "$PW" > "$TMP/dbpw"
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; "$DOCKER" rm -f "$NAME" >/dev/null 2>&1; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
"$DOCKER" run -d --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=rep "${MARIADB_IMAGE:-mariadb:lts}" >/dev/null || { echo "ENV: container"; exit 2; }
for _ in $(seq 90); do
  "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' rep >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' rep >/dev/null 2>&1 && up=1 && break; sleep 1
done
[ "${up:-0}" = 1 ] || { echo "ENV: db not ready"; exit 2; }
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >/dev/null 2>&1 || { sleep 2; swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >/dev/null 2>&1; } || { echo "ENV: build"; exit 2; }  # retry: the Swift frontend crashes sporadically
BIN=backend/.build/debug/App
unset FORM_DB_PASSWORD
export FORM_DB_PASSWORD_FILE="$TMP/dbpw" FORM_DB_PORT=$PORT FORM_DB_USER=root FORM_DB_NAME=rep FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1
export FORM_SCHEMA_FILE=backend/db/schema-p3.sql FORM_SERVER_KEY_FILE="$TMP/server.key" FORM_ADMIN_ORIGIN=http://localhost:$A FORM_RP_ID=localhost
fail=0; check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# Admin config requires the catalog check, which needs the schema: start only the plain service before migrating.
( unset FORM_SERVER_KEY_FILE FORM_ADMIN_ORIGIN FORM_RP_ID; FORM_HTTP_PORT=$A FORM_PUBLIC_PORT=$((A+100)) "$BIN" serve >"$TMP/pre.log" 2>&1 & echo $! > "$TMP/pre.pid" )
for _ in $(seq 30); do curl -fs "http://127.0.0.1:$A/health" >/dev/null 2>&1 && break; sleep 1; done
check "health ok but NOT ready before migrate (no traffic to unmigrated replicas)" "$(code http://127.0.0.1:$A/health)/$(code http://127.0.0.1:$A/ready)" "200/503"
kill "$(cat "$TMP/pre.pid")" 2>/dev/null; sleep 1
"$BIN" migrate >/dev/null 2>&1; check "migrate" "$?" "0"
FORM_HTTP_PORT=$A FORM_PUBLIC_PORT=$((A+100)) "$BIN" serve >"$TMP/a.log" 2>&1 & PIDS="$PIDS $!"
FORM_HTTP_PORT=$B FORM_PUBLIC_PORT=$((B+100)) "$BIN" serve >"$TMP/b.log" 2>&1 & PIDS="$PIDS $!"
for _ in $(seq 40); do curl -fs "http://127.0.0.1:$A/health" >/dev/null 2>&1 && curl -fs "http://127.0.0.1:$B/health" >/dev/null 2>&1 && break; sleep 1; done
check "ready A after migrate" "$(code http://127.0.0.1:$A/ready)" "200"
check "ready B after migrate" "$(code http://127.0.0.1:$B/ready)" "200"
# session on A, used on B
curl -s -D "$TMP/h" -o "$TMP/body" "http://127.0.0.1:$A/admin/api/v1/auth/session"
COOKIE=$(grep -i '^set-cookie:' "$TMP/h" | sed 's/^[^:]*: *//; s/;.*//' | tr -d '\r')
CSRF=$(python3 -c 'import json;print(json.load(open("'"$TMP"'/body"))["csrfToken"])')
check "session on B has same CSRF token" "$(curl -s -H "Cookie: $COOKIE" "http://127.0.0.1:$B/admin/api/v1/auth/session" | python3 -c 'import sys,json;print(json.load(sys.stdin)["csrfToken"])')" "$CSRF"
check "B has no new cookie" "$(curl -s -D - -o /dev/null -H "Cookie: $COOKIE" "http://127.0.0.1:$B/admin/api/v1/auth/session" | grep -ci '^set-cookie')" "0"
check "logout on B" "$(code -X POST -H "Cookie: $COOKIE" -H "X-CSRF-Token: $CSRF" -H "Origin: http://localhost:$A" "http://127.0.0.1:$B/admin/api/v1/auth/logout")" "204"
check "revoked session is rejected on A" "$(code -X POST -H "Cookie: $COOKIE" -H "X-CSRF-Token: $CSRF" -H "Origin: http://localhost:$A" "http://127.0.0.1:$A/admin/api/v1/auth/logout")" "401"
# the rate limit counter is shared: hammer A, then B sees the same budget (login budget is 10/min per IP)
for _ in $(seq 12); do curl -s -o /dev/null -H "Cookie: $COOKIE" -X POST "http://127.0.0.1:$A/admin/api/v1/auth/passkey/options"; done
check "login budget shared across replicas" "$(code -X POST "http://127.0.0.1:$B/admin/api/v1/auth/passkey/options")" "429"
exit $fail
