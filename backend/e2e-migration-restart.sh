#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Migration end to end across process deaths: the REAL binary runs as a service, a synthetic legacy source (legacy-synthetic.sql, enlarged by
# copies of its submissions so that the import takes a few seconds) is imported through the browser UI, and the service is stopped in the
# middle of the import three times (kill -9, SIGTERM, pause button). After each stop the service is restarted (same database); the job must
# stand on "paused", is resumed with "Fortsetzen" and ends in review. Afterwards the end state is compared with an UNDISTURBED import of the
# same plan into a second target database (CLI migrate-legacy, same binary). Real MariaDB servers for source and target, no mocks.
# Exit 0 ok, 1 failed, 2 environment. Ports (CI): target 33717, legacy 33955, internal 4316 / public 4416.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
ROOT=$PWD
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
LNAME=$(e2e_name p4a-rs-legacy); LPORT=${LEGACY_PORT:-$(e2e_pick_port)}
NAME=$(e2e_name p4a-rs-mariadb); PORT=${P3B_PORT:-$(e2e_pick_port)}; WPORT=${E2E_PORT:-$(e2e_pick_port)}
CLONES=${E2E_CLONE_ROUNDS:-4} # each round doubles the 29 submissions of the dump: 4 rounds = 464 submissions
PW=$(openssl rand -hex 16); TMP=$(mktemp -d)
savelogs() { [ -n "${E2E_LOG_DIR:-}" ] || return 0; mkdir -p "$E2E_LOG_DIR"; for l in "$TMP"/*.log; do [ -f "$l" ] && cp "$l" "$E2E_LOG_DIR/$(basename "$0" .sh)-$(basename "$l")"; done; return 0; }  # CI: keep logs as artifact
cleanup() { savelogs; [ -f "$TMP/app.pid" ] && kill "$(cat "$TMP/app.pid")" 2>/dev/null; e2e_cleanup; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
e2e_reap_stale
start=$(date +%s)
umask 077; openssl rand -hex 32 > "$TMP/server.key"
LPW=$(openssl rand -hex 16)
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "${MARIADB_IMAGE:-mariadb:lts}" >/dev/null || { echo "ENV: container"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$LNAME" -p "127.0.0.1:$LPORT:3306" -e MARIADB_ROOT_PASSWORD="$LPW" -e MARIADB_DATABASE=legacy "${MARIADB_IMAGE:-mariadb:lts}" >/dev/null || { echo "ENV: legacy container"; exit 2; }
wait_db() { # container password database
  for _ in $(seq 90); do
    "$DOCKER" exec -e MYSQL_PWD="$2" "$1" mariadb -uroot -e 'select 1' "$3" >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$2" "$1" mariadb -uroot -e 'select 1' "$3" >/dev/null 2>&1 && return 0; sleep 1
  done; return 1
}
wait_db "$NAME" "$PW" e2e || { echo "ENV: db not ready"; exit 2; }
wait_db "$LNAME" "$LPW" legacy || { echo "ENV: legacy db not ready"; exit 2; }
DUMP=backend/Tests/FormMigrationTests/Fixtures
{ echo "SET FOREIGN_KEY_CHECKS=0;"; cat "$DUMP/legacy-real.sql" "$DUMP/legacy-synthetic.sql"; } | "$DOCKER" exec -i -e MYSQL_PWD="$LPW" "$LNAME" mariadb -uroot legacy >"$TMP/legacy-load.log" 2>&1 || { tail -3 "$TMP/legacy-load.log"; echo "ENV: synthetic dump import failed"; exit 2; }
# Enlarge the source with plain SQL copies of the existing submissions (new UUID, same sealed package): more rows, same format.
COLS='time,formularUUID,sentServer,data,file1,file1Enc,file1Name,malwareScanStatus,errors,mailBody,mailBodyFiller,removable'
{ for _ in $(seq "$CLONES"); do echo "INSERT INTO anfragen (UUID,$COLS) SELECT UUID(),$COLS FROM anfragen;"; done; } | "$DOCKER" exec -i -e MYSQL_PWD="$LPW" "$LNAME" mariadb -uroot legacy || { echo "ENV: enlarge source"; exit 2; }
"$DOCKER" exec -e MYSQL_PWD="$LPW" "$LNAME" mariadb -uroot -e "CREATE USER 'migro'@'%' IDENTIFIED BY '$LPW'; GRANT SELECT ON legacy.* TO 'migro'@'%'; FLUSH PRIVILEGES" || { echo "ENV: legacy user"; exit 2; }
TOTAL=$("$DOCKER" exec -e MYSQL_PWD="$LPW" "$LNAME" mariadb -uroot -N legacy -e 'SELECT COUNT(*) FROM anfragen')
echo "ok   legacy source loaded: $TOTAL submissions (read-only user)"
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
BUILD="swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App"
$BUILD >/dev/null 2>&1 || { sleep 2; $BUILD >/dev/null 2>&1; } || { echo "ENV: build"; exit 2; }  # retry: the Swift frontend crashes sporadically
e2e_pwa_build "$TMP/dist" || { echo "ENV: pwa build"; exit 2; }
BIN=$ROOT/backend/.build/debug/App
export FORM_DB_PORT=$PORT FORM_DB_USER=root FORM_DB_PASSWORD=$PW FORM_DB_NAME=e2e FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1
export FORM_INTERNAL_PORT=$WPORT FORM_PUBLIC_PORT=$((WPORT+100)) E2E_PUBLIC_URL=http://127.0.0.1:$((WPORT+100)) FORM_SCHEMA_FILE=backend/db/schema-p3.sql FORM_PUBLIC_DIR="$TMP/dist"
export FORM_MIGRATION_ALLOWED_NETS=127.0.0.0/8 E2E_LEGACY_PORT=$LPORT E2E_LEGACY_USER=migro E2E_LEGACY_PASSWORD=$LPW E2E_LEGACY_DB=legacy
export FORM_SERVER_KEY_FILE="$TMP/server.key" FORM_ADMIN_ORIGIN=http://localhost:$WPORT FORM_RP_ID=localhost
export E2E_DB_CONTAINER=$NAME E2E_DB_PASSWORD=$PW E2E_LEGACY_CONTAINER=$LNAME E2E_LEGACY_ROOT_PASSWORD=$LPW E2E_EXPECTED_TOTAL=$TOTAL
"$BIN" migrate >/dev/null 2>&1 || { echo "FAIL migrate"; exit 1; }
PASSWORD=$(openssl rand -hex 12); printf '%s' "$PASSWORD" > "$TMP/bootpw"
OUT=$(FORM_BOOTSTRAP_PASSWORD_FILE="$TMP/bootpw" "$BIN" bootstrap-admin admin 2>&1) || { echo "FAIL bootstrap-admin"; echo "$OUT" | head -3; exit 1; }
LINK=$(printf '%s\n' "$OUT" | sed -n 's/.*): \(http[^ ]*\)$/\1/p' | head -1)
[ -n "$LINK" ] || { echo "FAIL no link in output"; exit 1; }
# Service control for the spec: start / kill9 / term / wait-exit. The service is a detached background process; its pid is the only state.
cat > "$TMP/ctl.sh" <<CTL
#!/usr/bin/env bash
cd "$ROOT" || exit 1
PIDF="$TMP/app.pid"
alive() { [ -f "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
case "\$1" in
  start)
    alive && { echo "already running"; exit 1; }
    nohup "$BIN" serve >>"$TMP/app.log" 2>&1 </dev/null &
    echo \$! > "\$PIDF"
    for _ in \$(seq 60); do curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 && exit 0; sleep 0.5; done; echo "service did not become healthy"; exit 1;;
  kill9) alive || { echo "not running"; exit 1; }; kill -9 "\$(cat "\$PIDF")";;
  term) alive || { echo "not running"; exit 1; }; kill -TERM "\$(cat "\$PIDF")";;
  wait-exit) for _ in \$(seq 120); do alive || exit 0; sleep 0.25; done; echo "service still running"; exit 1;;
  *) exit 2;;
esac
CTL
chmod +x "$TMP/ctl.sh"
"$TMP/ctl.sh" start || { echo "FAIL service start"; exit 1; }
export E2E_APP_CTL="$TMP/ctl.sh" E2E_SETUP_LINK="$LINK" E2E_PASSWORD="$PASSWORD" E2E_PORT=$WPORT E2E_SPEC=real-migration-restart.spec.ts
(cd pwa && npx playwright test -c e2e-real/playwright.config.ts >"$TMP/pw.log" 2>&1); rc=$?
grep -E "^(T\+|KILL9|SIGTERM at|PAUSE|LEDGER)" "$TMP/pw.log"; tail -25 "$TMP/pw.log" | grep -vE "^(T\+|KILL9|SIGTERM at|PAUSE|LEDGER)"
[ "$rc" = 0 ] && echo "ok   playwright spec passed" || echo "FAIL playwright spec exit $rc"
grep -q "${LINK##*#}" "$TMP/app.log" && { echo "FAIL enrollment token found in app log"; rc=1; }
grep -q "$PASSWORD" "$TMP/app.log" && { echo "FAIL password found in app log"; rc=1; }
# Undisturbed reference: the same plan imported in one go by the CLI (same binary and importer) into an empty second target database.
q() { "$DOCKER" exec -i -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -N "$1"; }
if [ "$rc" = 0 ]; then
  echo 'CREATE DATABASE e2e_ref' | q e2e >/dev/null
  FORM_DB_NAME=e2e_ref "$BIN" migrate >/dev/null 2>&1 || { echo "FAIL reference migrate"; rc=1; }
  echo 'SELECT plan_json FROM migration_jobs' | q e2e > "$TMP/plan.json"
  FORM_DB_NAME=e2e_ref FORM_MIGRATION_HMAC_KEY=$(openssl rand -base64 32) LEGACY_DB_HOST=127.0.0.1 LEGACY_DB_PORT=$LPORT LEGACY_DB_NAME=legacy LEGACY_DB_USER=migro \
    LEGACY_DB_PASSWORD=$LPW LEGACY_DB_TLS=disable "$BIN" migrate-legacy --plan "$TMP/plan.json" >"$TMP/ref.log" 2>&1; refrc=$?
  # Exit 3 = finished with open review cases (the synthetic source leaves some): same end state as the web route. Anything else is a failure.
  { [ "$refrc" = 0 ] || [ "$refrc" = 3 ]; } || { echo "FAIL reference import (exit $refrc)"; tail -3 "$TMP/ref.log"; rc=1; }
fi
if [ "$rc" = 0 ]; then
  # Content fingerprint without random ids: row counts, ledger per source table, and digests over submissions and packages.
  cp backend/e2e-migration-fingerprint.sql "$TMP/fp.sql"  # shared with e2e-migration-cli.sh
  q e2e < "$TMP/fp.sql" > "$TMP/fp.disturbed"; q e2e_ref < "$TMP/fp.sql" > "$TMP/fp.reference"
  if [ -s "$TMP/fp.reference" ] && cmp -s "$TMP/fp.disturbed" "$TMP/fp.reference"; then echo "ok   end state equals the undisturbed import ($(wc -l < "$TMP/fp.reference" | tr -d ' ') fingerprint lines)"
  else echo "FAIL end state differs from the undisturbed import"; diff "$TMP/fp.disturbed" "$TMP/fp.reference" | head -20; rc=1; fi
  grep -E "^(submissions|forms|ledger.anfragen)" "$TMP/fp.reference" | cut -c1-90
fi
echo "runtime $(( $(date +%s) - start )) s"
exit $rc
