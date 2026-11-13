#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SDK failover against the real binary (ADR 0023): throwaway MariaDB, form provisioned through the real UI, then two
# instances on the same DB act as primary and backup domain ("endpoints" differ by public port). A PHP file session
# carries the failover marker across separate PHP processes. Exit 0 ok, 1 failed, 2 environment.
# Covered: primary served; primary refused -> backup within budget + marker; follow-up within TTL goes straight to the
# backup (silent primary: ~3 s once, then fast); after TTL the primary is tried again; unsigned/tampered list refused.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
NAME=$(e2e_name p7f-failover-mariadb); PORT=${P3B_PORT:-$(e2e_pick_port)}; WPORT=${E2E_PORT:-$(e2e_pick_port)}; PA=$((WPORT+100)); PB=$((WPORT+101)); WB=$((WPORT+1)); PS=$((WPORT+102))
PW=$(openssl rand -hex 16); TMP=$(mktemp -d); A_PID=""; B_PID=""; S_PID=""
cleanup() { for p in "$A_PID" "$B_PID" "$S_PID"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; e2e_cleanup; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
e2e_reap_stale
umask 077; openssl rand -hex 32 > "$TMP/server.key"; mkdir "$TMP/sess"
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "${MARIADB_IMAGE:-mariadb:lts}" >/dev/null || { echo "ENV: container"; exit 2; }
for _ in $(seq 90); do
  "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && up=1 && break; sleep 1
done
[ "${up:-0}" = 1 ] || { echo "ENV: db not ready"; exit 2; }
SB="swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App"
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
$SB >/dev/null 2>&1 || { sleep 2; $SB >/dev/null 2>&1; } || { echo "ENV: build"; exit 2; }  # retry: the Swift frontend crashes sporadically
e2e_pwa_build "$TMP/dist" || { echo "ENV: pwa build"; exit 2; }
BIN=backend/.build/debug/App
export FORM_DB_PORT=$PORT FORM_DB_USER=root FORM_DB_PASSWORD=$PW FORM_DB_NAME=e2e FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1
export FORM_SCHEMA_FILE=backend/db/schema-p3.sql FORM_PUBLIC_DIR="$TMP/dist"
export FORM_SERVER_KEY_FILE="$TMP/server.key" FORM_RP_ID=localhost
export FORM_INTERNAL_PORT=$WPORT FORM_PUBLIC_PORT=$PA FORM_ADMIN_ORIGIN=http://localhost:$WPORT E2E_PUBLIC_URL=http://127.0.0.1:$PA
"$BIN" migrate >/dev/null 2>&1 || { echo "FAIL migrate"; exit 1; }
PASSWORD=$(openssl rand -hex 12); printf '%s' "$PASSWORD" > "$TMP/bootpw"
OUT=$(FORM_BOOTSTRAP_PASSWORD_FILE="$TMP/bootpw" "$BIN" bootstrap-admin admin 2>&1) || { echo "FAIL bootstrap-admin"; exit 1; }
LINK=$(printf '%s\n' "$OUT" | sed -n 's/.*): \(http[^ ]*\)$/\1/p' | head -1)
[ -n "$LINK" ] || { echo "FAIL no link"; exit 1; }
start_a() { FORM_INTERNAL_PORT=$WPORT FORM_PUBLIC_PORT=$PA "$BIN" serve >>"$TMP/a.log" 2>&1 & A_PID=$!; for _ in $(seq 30); do curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
start_b() { FORM_INTERNAL_PORT=$WB FORM_PUBLIC_PORT=$PB FORM_ADMIN_ORIGIN=http://localhost:$WB "$BIN" serve >>"$TMP/b.log" 2>&1 & B_PID=$!; for _ in $(seq 30); do curl -fs "http://localhost:$WB/health" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
stop() { eval "p=\$$1_PID"; [ -n "$p" ] && kill "$p" 2>/dev/null && wait "$p" 2>/dev/null; eval "$1_PID=''"; }
start_a || { echo "ENV: instance A not ready"; tail -5 "$TMP/a.log"; exit 2; }
CRED="$TMP/credentials.json"
export E2E_SETUP_LINK="$LINK" E2E_PASSWORD="$PASSWORD" E2E_PORT=$WPORT E2E_SPEC=real-load-setup.spec.ts E2E_CREDENTIALS_OUT="$CRED"
(cd pwa && npx playwright test -c e2e-real/playwright.config.ts) >"$TMP/playwright.log" 2>&1; prc=$?  # own status, not hidden behind tail
tail -4 "$TMP/playwright.log"
[ "$prc" = 0 ] && [ -s "$CRED" ] || { echo "FAIL provisioning (playwright rc=$prc, credentials missing or empty)"; exit 1; }
echo "ok   form provisioned, credentials issued (not shown)"

rc=0
A=http://127.0.0.1:$PA; B=http://127.0.0.1:$PB; S=http://127.0.0.1:$PS
# run SESSION TTL MODE KEY EP... -> sets OUTC ELAPSED SID MARK
run() { local s=$1 ttl=$2 mode=$3 key=$4; shift 4
  local line; line=$(php backend/e2e-failover/driver.php "$CRED" "$TMP/sess" "$s" "$ttl" "$mode" "$key" "$@" 2>"$TMP/php.err")
  IFS=$'\t' read -r OUTC ELAPSED SUBID MARK <<<"$line"; echo "     [$mode $key] -> $OUTC ${ELAPSED}ms id=${SUBID:-none} marker=$MARK"; }
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; rc=1; fi; }
stored() { "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -N e2e -e 'SELECT COUNT(*) FROM submissions' 2>/dev/null; }

echo "-- (1) primary reachable (backup instance not running: success proves the primary served)"
run sess1 60 signed k1 "$A" "$B"
check "primary served, no marker" '[ "$OUTC" = ok ] && [ "$MARK" = 0 ] && [ -n "$SUBID" ]'
check "one stored submission" '[ "$(stored)" = 1 ]'

echo "-- (2) primary port closed -> backup (instance B up, A stopped)"
start_b || { echo "ENV: instance B not ready"; exit 2; }
stop A
run sess2 60 signed k2 "$A" "$B"
check "backup received the submission, within budget, marker set" '[ "$OUTC" = ok ] && [ "$MARK" = 1 ] && [ "$ELAPSED" -lt 10000 ]'
check "two stored submissions (same DB)" '[ "$(stored)" = 2 ]'

echo "-- (2b/3) primary connected but silent: first call pays the 3 s connect/total limit once, the next goes straight to the backup"
python3 backend/e2e-failover/silent.py "$PS" & S_PID=$!; sleep 1
run sess3 60 signed k3 "$S" "$B"
check "silent primary: backup used after ~3 s (2.5-6 s), marker set" '[ "$OUTC" = ok ] && [ "$MARK" = 1 ] && [ "$ELAPSED" -ge 2500 ] && [ "$ELAPSED" -lt 6000 ]'
run sess3 60 signed k4 "$S" "$B"
check "follow-up within TTL: direct to backup in < 1 s, marker kept" '[ "$OUTC" = ok ] && [ "$MARK" = 1 ] && [ "$ELAPSED" -lt 1000 ]'
run sess3b 60 signed k5 "$S" "$B"
check "a different session has no marker and pays the delay again (state is per session)" '[ "$OUTC" = ok ] && [ "$ELAPSED" -ge 2500 ]'

echo "-- (4) TTL expiry: with TTL=4 the primary is tried again (silent primary again costs ~3 s)"
run sess4 4 signed k6 "$S" "$B"; first=$ELAPSED
run sess4 4 signed k7 "$S" "$B"; second=$ELAPSED
check "within TTL fast ($second ms)" '[ "$second" -lt 1000 ] && [ "$first" -ge 2500 ]'
sleep 5
run sess4 4 signed k8 "$S" "$B"
check "after TTL the primary is tried first again (~3 s)" '[ "$OUTC" = ok ] && [ "$ELAPSED" -ge 2500 ] && [ "$ELAPSED" -lt 6000 ]'
echo "     primary recovery: A restarted, B stopped; marker from an earlier failure must not block the primary"
stop B; start_a || { echo "ENV: A restart"; exit 2; }
run sess2 60 signed k9 "$A" "$B"
check "primary answers again after restart (backup is down, so success proves the primary; marker removed)" '[ "$OUTC" = ok ] && [ "$MARK" = 0 ]'
id9=$SUBID; run sess2 60 signed k9 "$A" "$B"
check "replay with the same key returns the same id (no duplicate)" '[ "$SUBID" = "$id9" ] && [ -n "$id9" ]'

echo "-- (5) signed endpoint list"
run sess5 60 unsigned k10 "$A" "$B"
check "multi-endpoint list without signature is refused (ConfigurationException)" '[ "$OUTC" = ConfigurationException ] && [ "$SUBID" = - ]'
run sess5 60 tampered k11 "$A" "$B"
check "list with a signature for a different list is refused" '[ "$OUTC" = ConfigurationException ] && [ "$SUBID" = - ]'

kill -0 "$A_PID" 2>/dev/null && echo "ok   instance A still running" || { echo "FAIL instance A died"; rc=1; }
exit $rc
