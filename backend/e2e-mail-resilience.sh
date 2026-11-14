#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Real end-to-end of the failure paths of the mail chain (PHP SDK -> real binary -> real SMTP server Mailpit), see pwa/e2e-real/real-mail-resilience.spec.ts:
# (1) 16 stalled uploads take all ingest slots: 3 parallel SDK submissions get 503 ingest_busy + Retry-After, the SDK waits (pauses are counted) and every submission arrives as exactly one
# mail with its file byte for byte; (2) a field value of 11 MiB: shortened mail ("gekürzt"), complete stored submission, one mail; (3) Mailpit stopped: delivery waits
# (waiting-manual), Mailpit restarted, "Erneut senden" in the PWA -> exactly one mail, files byte for byte. Synthetic data only.
# Containers/ports unique per run (backend/e2e-common.sh). Exit 0 ok, 1 failed, 2 environment problem.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
NAME=$(e2e_name p4a-mailres-mariadb); MP=$(e2e_name p4a-mailres-mailpit)
PORT=${P3B_PORT:-$(e2e_pick_port)}; WPORT=${E2E_PORT:-$(e2e_pick_port)}; PPORT=$((WPORT+100)); MPSMTP=$((PORT+1)); MPAPI=$((PORT+2))
PW=$(openssl rand -hex 16); TMP=$(mktemp -d); APP_PID=""
cleanup() { [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; e2e_cleanup; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
e2e_reap_stale
umask 077; openssl rand -hex 32 > "$TMP/server.key"
"$DOCKER" info >/dev/null 2>&1 || { echo "ENV: docker daemon not reachable"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "${MARIADB_IMAGE:-mariadb:lts}" --max-allowed-packet=67108864 >/dev/null || { echo "ENV: container"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --name "$MP" -p "127.0.0.1:$MPSMTP:1025" -p "127.0.0.1:$MPAPI:8025" "${MAILPIT_IMAGE:-axllent/mailpit:latest}" >/dev/null || { echo "ENV: mailpit container"; exit 2; }
for _ in $(seq 90); do
  "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && up=1 && break; sleep 1
done
[ "${up:-0}" = 1 ] || { echo "ENV: db not ready"; exit 2; }
mp=0; for _ in $(seq 60); do curl -fs "http://127.0.0.1:$MPAPI/api/v1/info" >/dev/null 2>&1 && { mp=1; break; }; sleep 1; done
[ $mp = 1 ] || { echo "ENV: mailpit not ready"; exit 2; }
SB="swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App"
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
$SB >/dev/null 2>&1 || { sleep 2; $SB >/dev/null 2>&1; } || { echo "ENV: build"; exit 2; }  # retry: the Swift frontend crashes sporadically
e2e_pwa_build "$TMP/dist" || { echo "ENV: pwa build"; exit 2; }
BIN=backend/.build/debug/App
export FORM_DB_PORT=$PORT FORM_DB_USER=root FORM_DB_PASSWORD=$PW FORM_DB_NAME=e2e FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1
export FORM_INTERNAL_PORT=$WPORT FORM_PUBLIC_PORT=$PPORT FORM_SCHEMA_FILE=backend/db/schema-p3.sql FORM_PUBLIC_DIR="$TMP/dist"
export FORM_SERVER_KEY_FILE="$TMP/server.key" FORM_ADMIN_ORIGIN=http://localhost:$WPORT FORM_RP_ID=localhost
[ -n "${MR_BODY_BUDGET_MB:-}" ] && export FORM_BODY_BUDGET_MB=$MR_BODY_BUDGET_MB
export FORM_MAIL_MAX_MB=30 FORM_MAIL_ALLOWED_NETS=127.0.0.0/8   # Mailpit listens on loopback; private targets are blocked by default
"$BIN" migrate >/dev/null 2>&1 || { echo "FAIL migrate"; exit 1; }
PASSWORD=$(openssl rand -hex 12); printf '%s' "$PASSWORD" > "$TMP/bootpw"
OUT=$(FORM_BOOTSTRAP_PASSWORD_FILE="$TMP/bootpw" "$BIN" bootstrap-admin admin 2>&1) || { echo "FAIL bootstrap-admin"; exit 1; }
LINK=$(printf '%s\n' "$OUT" | sed -n 's/.*): \(http[^ ]*\)$/\1/p' | head -1)
[ -n "$LINK" ] || { echo "FAIL no link"; exit 1; }
"$BIN" serve >"$TMP/app.log" 2>&1 & APP_PID=$!
for _ in $(seq 30); do curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 && break; sleep 1; done
export E2E_SETUP_LINK="$LINK" E2E_PASSWORD="$PASSWORD" E2E_PORT=$WPORT E2E_SPEC=${MR_SPEC:-real-mail-resilience.spec.ts} E2E_TMP="$TMP" E2E_PUBLIC_URL=http://127.0.0.1:$PPORT
export E2E_DB_CONTAINER="$NAME" E2E_DB_PASSWORD="$PW" E2E_MAILPIT_CONTAINER="$MP" E2E_HOLD_SCRIPT="$PWD/backend/e2e-hold-ingest-slots.py" E2E_RAW_ABORT_SCRIPT="$PWD/backend/e2e-raw-abort.py"
export E2E_MAILPIT_SMTP=$MPSMTP E2E_MAILPIT_API=$MPAPI E2E_SUBMIT_DRIVER="$PWD/backend/e2e-mail-resilience-submit.php"
(cd pwa && npx playwright test -c e2e-real/playwright.config.ts) >"$TMP/playwright.log" 2>&1; prc=$?
tail -25 "$TMP/playwright.log"
if [ "$prc" = 0 ]; then echo "ok   ${MR_OK_MSG:-busy server (503 + Retry-After), oversized field and mail outage each end in exactly one correct mail (Mailpit)}"; exit 0; fi
echo "FAIL (playwright rc=$prc)"
"$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot e2e -e 'SELECT mail_kind, state, attempts, last_error_code, transport_kind FROM mail_deliveries' 2>&1 | head -10
tail -5 "$TMP/app.log"
[ -n "${E2E_LOG_DIR:-}" ] && { mkdir -p "$E2E_LOG_DIR"; cp "$TMP"/*.log "$E2E_LOG_DIR/" 2>/dev/null; }
exit 1
