#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Real end-to-end retention period (ADR 0012 no. 2, package EEDF6CCE): empty database -> `bootstrap-admin` -> Chromium (CDP virtual
# authenticator) -> customer + new form: the Aufbewahrung panel shows 3 days (72 h default) and no "off" option; change to 5, reload shows 5;
# a real SDK submission gets retention_due_at; a form whose setting was removed by SQL cannot be published (409 reason shown in the browser).
# Real binary, real MariaDB (Docker), no mocks. E2E_RETENTION_WRONG=1 expects a wrong value (proof that a failing check ends with rc!=0).
# Exit 0 ok, 1 failed, 2 environment.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
NAME=$(e2e_name p4a-retention-mariadb); PORT=${P3B_PORT:-$(e2e_pick_port)}; WPORT=${E2E_PORT:-$(e2e_pick_port)}
PW=$(openssl rand -hex 16); TMP=$(mktemp -d); APP_PID=""
savelogs() { [ -n "${E2E_LOG_DIR:-}" ] || return 0; mkdir -p "$E2E_LOG_DIR"; for l in "$TMP"/*.log; do [ -f "$l" ] && cp "$l" "$E2E_LOG_DIR/$(basename "$0" .sh)-$(basename "$l")"; done; return 0; }  # CI: keep logs as artifact
cleanup() { savelogs; [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; e2e_cleanup; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
e2e_reap_stale
umask 077; openssl rand -hex 32 > "$TMP/server.key"
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "${MARIADB_IMAGE:-mariadb:lts}" >/dev/null || { echo "ENV: container"; exit 2; }
for _ in $(seq 90); do
  "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && up=1 && break; sleep 1
done
[ "${up:-0}" = 1 ] || { echo "ENV: db not ready"; exit 2; }
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >>"$TMP/build.log" 2>&1 || { sleep 2; swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >>"$TMP/build.log" 2>&1; } || { echo "ENV: build"; exit 2; }  # retry: the Swift frontend crashes sporadically
e2e_pwa_build "$TMP/dist" || { echo "ENV: pwa build"; exit 2; }
BIN=backend/.build/debug/App
export FORM_DB_PORT=$PORT FORM_DB_USER=root FORM_DB_PASSWORD=$PW FORM_DB_NAME=e2e FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1
export FORM_INTERNAL_PORT=$WPORT FORM_PUBLIC_PORT=$((WPORT+100)) E2E_PUBLIC_URL=http://127.0.0.1:$((WPORT+100)) FORM_SCHEMA_FILE=backend/db/schema-p3.sql FORM_PUBLIC_DIR="$TMP/dist"
export FORM_SERVER_KEY_FILE="$TMP/server.key" FORM_ADMIN_ORIGIN=http://localhost:$WPORT FORM_RP_ID=localhost
"$BIN" migrate >/dev/null 2>&1 || { echo "FAIL migrate"; exit 1; }
PASSWORD=$(openssl rand -hex 12); printf '%s' "$PASSWORD" > "$TMP/bootpw"
OUT=$(FORM_BOOTSTRAP_PASSWORD_FILE="$TMP/bootpw" "$BIN" bootstrap-admin admin 2>&1) || { echo "FAIL bootstrap-admin"; echo "$OUT" | head -3; exit 1; }
LINK=$(printf '%s\n' "$OUT" | sed -n 's/.*): \(http[^ ]*\)$/\1/p' | head -1)
[ -n "$LINK" ] || { echo "FAIL no link in output"; exit 1; }
echo "ok   bootstrap-admin printed an enrollment link (not shown)"
"$BIN" serve >"$TMP/app.log" 2>&1 & APP_PID=$!
for _ in $(seq 30); do curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 && break; sleep 1; done
export E2E_SETUP_LINK="$LINK" E2E_PASSWORD="$PASSWORD" E2E_PORT=$WPORT E2E_SPEC=real-retention.spec.ts
export E2E_DOCKER="$DOCKER" E2E_DB_CONTAINER="$NAME" E2E_DB_PASSWORD="$PW"
(cd pwa && npx playwright test -c e2e-real/playwright.config.ts) >"$TMP/playwright.log" 2>&1; rc=$?  # own status: a pipe into tail would hide a failed run (PIPESTATUS after a subshell is the status of tail)
tail -25 "$TMP/playwright.log"
q() { "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -N e2e -e "$1" 2>/dev/null; }
# database side: the stored period of the form that was changed, and every real submission carries a due date
PERIOD=$(q "SELECT GROUP_CONCAT(CAST(safe_value_json AS CHAR) ORDER BY safe_value_json) FROM settings WHERE setting_key='retention.days'")
echo "info retention.days values: ${PERIOD:-none}"
case "$PERIOD" in *5*) echo "ok   changed period (5) stored in the database" ;; *) echo "FAIL stored periods: ${PERIOD:-none} (expected a 5)"; rc=1 ;; esac
TOTAL=$(q "SELECT COUNT(*) FROM submissions"); NODUE=$(q "SELECT COUNT(*) FROM submissions WHERE retention_due_at IS NULL")
[ "${TOTAL:-0}" -ge 1 ] && [ "${NODUE:-1}" = 0 ] && echo "ok   $TOTAL real submission(s), all with retention_due_at" || { echo "FAIL submissions=$TOTAL without due date=$NODUE"; rc=1; }
TOKEN=${LINK##*#}
grep -q "$TOKEN" "$TMP/app.log" && { echo "FAIL enrollment token found in app log"; rc=1; } || echo "ok   token not in app log"
grep -q "$PASSWORD" "$TMP/app.log" && { echo "FAIL password found in app log"; rc=1; } || echo "ok   password not in app log"
exit $rc
