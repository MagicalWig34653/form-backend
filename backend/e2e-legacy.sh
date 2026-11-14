#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Legacy API end to end (ADR 0047) with the REAL old SDK: Chromium (CDP virtual authenticator) publishes a form with a required field in the
# new backend; then a tiny PHP "customer website" (php -S, backend/e2e-legacy/site/index.php) embeds the UNCHANGED old SDK of the previous
# backend (LEGACY_SDK_DIR, default ../form-backend_bvk: providers/Clients/BackendV2.php = v2, Backend.php = v1 with only its hard-coded host
# replaced) and talks to the PUBLIC listener: loadForm(), valid send() -> 200, invalid send() -> 412 with the old end-user text,
# nothing stored for the invalid one. Part 2 restarts the app with FORM_COMPAT_LEGACY=false: the same old SDK gets 404 (switch proof).
# E2E_LEGACY_MUTATION=1 expects the checks to FAIL (the script then exits 0 only if a check failed): used as mutation proof together with a
# deliberately broken build; not needed normally.
# Synthetic data only. Exit 0 ok, 1 failed, 2 environment (no docker, no old SDK checkout, no php with curl/sodium).
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
LEGACY_SDK_DIR=${LEGACY_SDK_DIR:-$HOME/Development/PhpstormProjects/form-backend_bvk}
[ -f "$LEGACY_SDK_DIR/providers/Clients/BackendV2.php" ] && [ -f "$LEGACY_SDK_DIR/providers/Clients/Backend.php" ] || { echo "ENV: old SDK not found in LEGACY_SDK_DIR=$LEGACY_SDK_DIR"; exit 2; }
php -r 'exit(extension_loaded("curl") && extension_loaded("sodium") && extension_loaded("openssl") ? 0 : 1);' || { echo "ENV: php with curl, sodium, openssl needed"; exit 2; }
IMAGE=${MARIADB_IMAGE:-mariadb:lts}; NAME=$(e2e_name p4a-legacy-mariadb); PORT=${P3B_PORT:-$(e2e_pick_port)}; WPORT=${E2E_PORT:-$(e2e_pick_port)}; SPORT=$((WPORT+50))
PW=$(openssl rand -hex 16); TMP=$(mktemp -d); APP_PID=""; SITE_PID=""; rc=0
savelogs() { [ -n "${E2E_LOG_DIR:-}" ] || return 0; mkdir -p "$E2E_LOG_DIR"; for l in "$TMP"/*.log; do [ -f "$l" ] && cp "$l" "$E2E_LOG_DIR/$(basename "$0" .sh)-$(basename "$l")"; done; return 0; }
cleanup() { savelogs; [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; [ -n "$SITE_PID" ] && kill "$SITE_PID" 2>/dev/null; e2e_cleanup; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
e2e_reap_stale
umask 077; openssl rand -hex 32 > "$TMP/server.key"
"$DOCKER" info >/dev/null 2>&1 || { echo "ENV: docker daemon not reachable"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "$IMAGE" >/dev/null || { echo "ENV: container start failed"; exit 2; }
up=0
for _ in $(seq 90); do
  if "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && sleep 2 \
     && "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ $up = 1 ] || { echo "ENV: server did not become ready"; exit 2; }
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >>"$TMP/build.log" 2>&1 || { sleep 2; swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >>"$TMP/build.log" 2>&1; } || { echo "ENV: build"; exit 2; }  # retry: the Swift frontend crashes sporadically
e2e_pwa_build "$TMP/dist" || { echo "ENV: pwa build failed"; exit 2; }
BIN=backend/.build/debug/App; PUBLIC=http://127.0.0.1:$((WPORT+100)); SITE=http://127.0.0.1:$SPORT
export FORM_DB_PORT=$PORT FORM_DB_USER=root FORM_DB_PASSWORD=$PW FORM_DB_NAME=e2e FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1
export FORM_INTERNAL_PORT=$WPORT FORM_PUBLIC_PORT=$((WPORT+100)) E2E_PUBLIC_URL=$PUBLIC FORM_SCHEMA_FILE=backend/db/schema-p3.sql FORM_PUBLIC_DIR="$TMP/dist"
export FORM_SERVER_KEY_FILE="$TMP/server.key" FORM_ADMIN_ORIGIN=http://localhost:$WPORT FORM_RP_ID=localhost
"$BIN" migrate >/dev/null 2>&1 || { echo "FAIL migrate"; exit 1; }
PASSWORD=$(openssl rand -hex 12); printf '%s' "$PASSWORD" > "$TMP/bootpw"
OUT=$(FORM_BOOTSTRAP_PASSWORD_FILE="$TMP/bootpw" "$BIN" bootstrap-admin admin 2>&1) || { echo "FAIL bootstrap-admin"; exit 1; }
LINK=$(printf '%s\n' "$OUT" | sed -n 's/.*): \(http[^ ]*\)$/\1/p' | head -1)
[ -n "$LINK" ] || { echo "FAIL no link in output"; exit 1; }
"$BIN" serve >"$TMP/app.log" 2>&1 & APP_PID=$!
for _ in $(seq 30); do curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 && break; sleep 1; done
export E2E_SETUP_LINK="$LINK" E2E_PASSWORD="$PASSWORD" E2E_PORT=$WPORT E2E_SPEC=real-legacy.spec.ts E2E_FORM_FILE="$TMP/form.txt"
(cd pwa && npx playwright test -c e2e-real/playwright.config.ts 2>&1 | tail -15); [ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL form preparation in the UI"; exit 1; }
FORM=$(cat "$TMP/form.txt" 2>/dev/null); [ -n "$FORM" ] || { echo "FAIL no form id"; exit 1; }
echo "ok   form published in the new backend"

# --- the "customer website" with the unchanged old SDK ---
# Der Alt-SDK v1 hat den Host hart im Code; er wird aus der Datei gelesen (kein Kundenname im Skript).
LEGACY_HOST_URL=$(grep -Eo "https://[A-Za-z0-9.-]+" "$LEGACY_SDK_DIR/providers/Clients/Backend.php" | head -1)
[ -n "$LEGACY_HOST_URL" ] || { echo "Alt-SDK-Host nicht gefunden" >&2; exit 2; }
sed "s#$LEGACY_HOST_URL#$PUBLIC#g" "$LEGACY_SDK_DIR/providers/Clients/Backend.php" > "$TMP/BackendV1Copy.php"
grep -q "$PUBLIC" "$TMP/BackendV1Copy.php" || { echo "ENV: host not found in old v1 SDK"; exit 2; }
cat > "$TMP/v2-config.php" <<PHP
<?php
return ['base_url' => '$PUBLIC', 'formular_uuid' => '$FORM', 'client_ua_key' => '$(openssl rand -base64 32)', 'client_ip_key' => '$(openssl rand -base64 32)'];
PHP
export LEGACY_SDK_DIR LEGACY_V1_COPY="$TMP/BackendV1Copy.php" LEGACY_V2_CONFIG="$TMP/v2-config.php" E2E_FORM_UUID=$FORM
php -d display_errors=0 -d error_reporting=0 -S "127.0.0.1:$SPORT" -t backend/e2e-legacy/site >"$TMP/site.log" 2>&1 & SITE_PID=$!
for _ in $(seq 20); do curl -fs "$SITE/?sdk=v2" -o /dev/null 2>&1 && break; sleep 0.5; done
fail() { echo "FAIL $1"; rc=1; }
ok() { echo "ok   $1"; }
json() { python3 -c 'import json,sys; d=json.load(sys.stdin); v=d; [v:=v[k] for k in sys.argv[1:]]; print(json.dumps(v) if not isinstance(v,str) else v)' "$@"; }
count() { "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -N e2e -e 'SELECT COUNT(*) FROM submissions' 2>/dev/null; }

run_sdk() {  # $1 = v1|v2
  local sdk=$1 jar="$TMP/jar-$1" page csrf before
  page=$(curl -s -c "$jar" -H 'X-Real-IP: 203.0.113.9' "$SITE/?sdk=$sdk")
  [ "$(printf '%s' "$page" | json status)" = 200 ] && ok "$sdk loadForm: config call answered 200 by the legacy path" || fail "$sdk loadForm status: $page"
  [ "$(printf '%s' "$page" | json mode)" = production ] && ok "$sdk mode production" || fail "$sdk mode: $page"
  csrf=$(printf '%s' "$page" | json csrf)
  if [ "$sdk" = v2 ]; then
    printf '%s' "$page" | json fields | grep -q '"name"' && printf '%s' "$page" | json fields | grep -q '"email"' && ok "v2 field list from the published form" || fail "v2 fields: $page"
  fi
  before=$(count)
  local valid; valid=$(curl -s -b "$jar" -H 'X-Real-IP: 203.0.113.9' --data-urlencode "csrf_token=$csrf" --data-urlencode "name=Max Beispiel" --data-urlencode "email=max@example.org" "$SITE/?sdk=$sdk")
  [ "$(printf '%s' "$valid" | json status)" = 200 ] && ok "$sdk valid submission -> 200" || fail "$sdk valid submission: $valid"
  [ "$(count)" = $((before + 1)) ] && ok "$sdk submission stored" || fail "$sdk submission not stored"
  local invalid; invalid=$(curl -s -b "$jar" -H 'X-Real-IP: 203.0.113.9' --data-urlencode "csrf_token=$csrf" --data-urlencode "name=" --data-urlencode "email=max@example.org" "$SITE/?sdk=$sdk")
  [ "$(printf '%s' "$invalid" | json status)" = 412 ] && ok "$sdk missing required field -> 412 (old status)" || fail "$sdk invalid submission: $invalid"
  printf '%s' "$invalid" | json message | grep -q '^412<br>Eine Voraussetzung' && ok "$sdk old end-user text for 412" || fail "$sdk end-user text: $invalid"
  [ "$(count)" = $((before + 1)) ] && ok "$sdk invalid submission not stored" || fail "$sdk invalid submission was stored"
}
run_sdk v2
run_sdk v1
grep -qE "max@example.org|Max Beispiel" "$TMP/app.log" && fail "submission data found in app log" || ok "no submission data in app log"

# --- part 2: switch off ---
kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
FORM_COMPAT_LEGACY=false "$BIN" serve >"$TMP/app2.log" 2>&1 & APP_PID=$!
for _ in $(seq 30); do curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 && break; sleep 1; done
off=$(curl -s -H 'X-Real-IP: 203.0.113.9' "$SITE/?sdk=v2")
[ "$(printf '%s' "$off" | json status)" = 404 ] && ok "switch off: old v2 config call -> 404" || fail "switch off v2: $off"
off1=$(curl -s -H 'X-Real-IP: 203.0.113.9' "$SITE/?sdk=v1")
[ "$(printf '%s' "$off1" | json status)" = 404 ] && ok "switch off: old v1 config call -> 404" || fail "switch off v1: $off1"
if [ "${E2E_LEGACY_MUTATION:-0}" = 1 ]; then [ $rc = 0 ] && { echo "MUTATION NOT DETECTED"; exit 1; } || { echo "mutation detected (checks failed as expected)"; exit 0; }; fi
exit $rc
