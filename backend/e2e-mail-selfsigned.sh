#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Real end-to-end for self-signed mail server certificates (ADR 0044): throwaway MariaDB + Mailpit with STARTTLS and the self-signed synthetic
# test certificate + real binary. Chromium (Playwright) creates SMTP connections in the admin UI: without the option the connection test fails
# with the named TLS error; with "Eigene/selbstsignierte Zertifikate erlauben" (warning + list marker) the test passes and a real signed SDK
# submission arrives in Mailpit; switching verification back on fails again. SMTP is STARTTLS in all steps (never plain).
# Containers/ports unique per run (backend/e2e-common.sh). Exit 0 ok, 1 failed, 2 environment problem.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
NAME=$(e2e_name p4a-mailss-mariadb); MP=$(e2e_name p4a-mailss-mailpit)
PORT=${P3B_PORT:-$(e2e_pick_port)}; WPORT=${E2E_PORT:-$(e2e_pick_port)}; PPORT=$((WPORT+100)); MPSMTP=$((PORT+1)); MPAPI=$((PORT+2))
PW=$(openssl rand -hex 16); TMP=$(mktemp -d); APP_PID=""
cleanup() { [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; e2e_cleanup; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
e2e_reap_stale
umask 077; openssl rand -hex 32 > "$TMP/server.key"
"$DOCKER" info >/dev/null 2>&1 || { echo "ENV: docker daemon not reachable"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "${MARIADB_IMAGE:-mariadb:lts}" >/dev/null || { echo "ENV: container"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --name "$MP" -p "127.0.0.1:$MPSMTP:1025" -p "127.0.0.1:$MPAPI:8025" -v "$PWD/backend/Tests/TestSupport/Fixtures:/certs:ro" -e MP_SMTP_TLS_CERT=/certs/test-cert.pem -e MP_SMTP_TLS_KEY=/certs/test-key.pem "${MAILPIT_IMAGE:-axllent/mailpit:latest}" >/dev/null || { echo "ENV: mailpit container"; exit 2; }
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
export FORM_MAIL_ALLOWED_NETS=127.0.0.0/8   # Mailpit listens on loopback; private targets are blocked by default
"$BIN" migrate >/dev/null 2>&1 || { echo "FAIL migrate"; exit 1; }
PASSWORD=$(openssl rand -hex 12); printf '%s' "$PASSWORD" > "$TMP/bootpw"
OUT=$(FORM_BOOTSTRAP_PASSWORD_FILE="$TMP/bootpw" "$BIN" bootstrap-admin admin 2>&1) || { echo "FAIL bootstrap-admin"; exit 1; }
LINK=$(printf '%s\n' "$OUT" | sed -n 's/.*): \(http[^ ]*\)$/\1/p' | head -1)
[ -n "$LINK" ] || { echo "FAIL no link"; exit 1; }
"$BIN" serve >"$TMP/app.log" 2>&1 & APP_PID=$!
for _ in $(seq 30); do curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 && break; sleep 1; done
export E2E_SETUP_LINK="$LINK" E2E_PASSWORD="$PASSWORD" E2E_PORT=$WPORT E2E_SPEC=real-mail-selfsigned.spec.ts E2E_TMP="$TMP" E2E_PUBLIC_URL=http://127.0.0.1:$PPORT
export E2E_MAILPIT_SMTP=$MPSMTP E2E_MAILPIT_API=$MPAPI E2E_SUBMIT_DRIVER="$PWD/backend/e2e-mail-submit.php"
(cd pwa && npx playwright test -c e2e-real/playwright.config.ts) >"$TMP/playwright.log" 2>&1; prc=$?
tail -25 "$TMP/playwright.log"
if [ "$prc" = 0 ]; then echo "ok   self-signed option per connection: fails when verifying, mail arrives with the option, switch back fails again (Mailpit)"; exit 0; fi
echo "FAIL (playwright rc=$prc)"
"$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot e2e -e 'SELECT mail_kind, state, attempts, last_error_code, transport_kind FROM mail_deliveries' 2>&1 | head -10
tail -5 "$TMP/app.log"
[ -n "${E2E_LOG_DIR:-}" ] && { mkdir -p "$E2E_LOG_DIR"; cp "$TMP"/*.log "$E2E_LOG_DIR/" 2>/dev/null; }
exit 1
