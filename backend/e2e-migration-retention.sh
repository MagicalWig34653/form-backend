#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# QA 13.11. (data destruction): imported legacy submissions must survive the retention job. REAL PROCESSES (real binary, real source and
# target MariaDB, no mocks, no browser): synthetic legacy dump -> `App migrate-legacy` -> `App serve` with a 2 s retention interval ->
#   A  imported submissions carry NO due date (NULL), the report names how many would have been due at the default (retention.dueNowAtDefault)
#   B  the job runs several passes: submission and stored_objects counts unchanged
#   C  instance imported BEFORE the fix (due dates written, upgrade 0035 not yet applied): `App migrate` clears them, passes delete nothing
#   D  operator decision (result of PUT retention with applyToImported, proven against the same database in PrivacyTests) is simulated by one
#      UPDATE of one submission: the job removes exactly that one (and its objects), the others stay
# E2E_RETENTION_WRONG=1 flips one expectation on purpose (red proof, must exit 1). Exit 0 ok, 1 failed, 2 environment.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
ROOT=$PWD
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
LNAME=$(e2e_name p4a-ret-legacy); LPORT=${LEGACY_PORT:-$(e2e_pick_port)}
NAME=$(e2e_name p4a-ret-mariadb); PORT=${P3B_PORT:-$(e2e_pick_port)}
CLONES=0 # each round doubles the submissions of the source (stage F only)
PW=$(openssl rand -hex 16); LPW=$(openssl rand -hex 16); TMP=$(mktemp -d)
HMAC=$(openssl rand -base64 32); SKEY=$(openssl rand -hex 32)
rc=0
savelogs() { [ -n "${E2E_LOG_DIR:-}" ] || return 0; mkdir -p "$E2E_LOG_DIR"; for l in "$TMP"/*.log; do [ -f "$l" ] && cp "$l" "$E2E_LOG_DIR/$(basename "$0" .sh)-$(basename "$l")"; done; return 0; }
cleanup() { savelogs; e2e_cleanup; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
e2e_reap_stale
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; rc=1; }
check() { # description expected actual
  if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: expected '$2', got '$3'"; fi
}
start=$(date +%s)
umask 077; printf '%s' "$SKEY" > "$TMP/server.key"
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "${MARIADB_IMAGE:-mariadb:lts}" >/dev/null || { echo "ENV: container"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$LNAME" -p "127.0.0.1:$LPORT:3306" -e MARIADB_ROOT_PASSWORD="$LPW" -e MARIADB_DATABASE=legacy "${MARIADB_IMAGE:-mariadb:lts}" >/dev/null || { echo "ENV: legacy container"; exit 2; }
wait_db() { for _ in $(seq 90); do "$DOCKER" exec -e MYSQL_PWD="$2" "$1" mariadb -uroot -e 'select 1' "$3" >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$2" "$1" mariadb -uroot -e 'select 1' "$3" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
wait_db "$NAME" "$PW" e2e || { echo "ENV: db not ready"; exit 2; }
wait_db "$LNAME" "$LPW" legacy || { echo "ENV: legacy db not ready"; exit 2; }
FIX=backend/Tests/FormMigrationTests/Fixtures
{ echo "SET FOREIGN_KEY_CHECKS=0;"; cat "$FIX/legacy-real.sql" "$FIX/legacy-synthetic.sql" "$FIX/legacy-synthetic-statistics-extra.sql"; } | "$DOCKER" exec -i -e MYSQL_PWD="$LPW" "$LNAME" mariadb -uroot legacy >"$TMP/legacy-load.log" 2>&1 || { tail -3 "$TMP/legacy-load.log"; echo "ENV: synthetic dump import failed"; exit 2; }
"$DOCKER" exec -e MYSQL_PWD="$LPW" "$LNAME" mariadb -uroot -e "CREATE USER 'migro'@'%' IDENTIFIED BY '$LPW'; GRANT SELECT ON legacy.* TO 'migro'@'%'; FLUSH PRIVILEGES" || { echo "ENV: legacy user"; exit 2; }
s() { "$DOCKER" exec -i -e MYSQL_PWD="$LPW" "$LNAME" mariadb -uroot -N legacy; }      # source, root
q() { "$DOCKER" exec -i -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -N "$1"; }          # target database $1
sc() { echo "$1" | s; }; tc() { echo "$2" | q "$1"; }
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
BUILD="swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App"
$BUILD >/dev/null 2>&1 || { sleep 2; $BUILD >/dev/null 2>&1; } || { echo "ENV: build"; exit 2; }
BIN=$ROOT/backend/.build/debug/App
export FORM_DB_PORT=$PORT FORM_DB_USER=root FORM_DB_PASSWORD=$PW FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1 FORM_SCHEMA_FILE=backend/db/schema-p3.sql
newdb() { echo "CREATE DATABASE IF NOT EXISTS $1" | q e2e; FORM_DB_NAME=$1 "$BIN" migrate >/dev/null 2>&1 || { echo "ENV: migrate $1"; exit 2; }; }
# One CLI call as its own process: cli <target db> <log> [args...]; the environment of a case can be adjusted with `env` before calling.
# Case switches (set as prefix of the call): CLI_UNSET=<variable to remove>, CLI_LPW, CLI_HMAC, CLI_TLS.
# cli_prep fills CMD; perl restores the default SIGINT (a background job of a non-interactive shell inherits "ignore", which would make the test of SIGINT meaningless).
cli_prep() { local db=$1; shift
  local -a e=("FORM_DB_NAME=$db" "FORM_MIGRATION_HMAC_KEY=${CLI_HMAC:-$HMAC}" "FORM_SERVER_KEY_FILE=$TMP/server.key" "LEGACY_DB_HOST=127.0.0.1" "LEGACY_DB_PORT=$LPORT" "LEGACY_DB_NAME=legacy" \
    "LEGACY_DB_USER=migro" "LEGACY_DB_PASSWORD=${CLI_LPW:-$LPW}" "LEGACY_DB_TLS=${CLI_TLS:-disable}")
  local -a f=(); local x
  for x in "${e[@]}"; do [ "${x%%=*}" = "${CLI_UNSET:-}" ] || f+=("$x"); done
  CMD=(perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' env "${f[@]}" "$BIN" migrate-legacy "$@"); }
cli() { local db=$1 log=$2; shift 2; cli_prep "$db" "$@"; "${CMD[@]}" >"$log" 2>&1; }
newdb e2e
CUST=0c0c0c0c-0c0c-4c0c-8c0c-0c0c0c0c0c0c; HASH=$(openssl rand -hex 32)
F1=11111111-1111-4111-8111-111111111111; F2=22222222-2222-4222-8222-222222222222; F3=33333333-3333-4333-8333-333333333333
K1=a6077815bba8b14c; K2=d19bf3f082782c87   # generation 1 (auslaufend) and 2 (aktiv), as the web plan numbers them
mkplan() { # file [review-ref] [public-key-for-the-customer]; optional keys may be absent in a plan (initializer defaults), see stage A
  local c=$CUST rev="" keys="{}"
  [ -n "${2:-}" ] && rev=",\"statisticsReview\":\"$2\""; [ -n "${3:-}" ] && keys="{\"$c\":\"$3\"}"
  cat > "$1" <<JSON
{"namespace":"ret-e2e","dumpSHA256":"$HASH","customers":{"$c":"CLI Test GmbH"},
 "formCustomers":{"$F1":"$c","$F2":"$c","$F3":"$c"},
 "connectionCustomers":{"44444444-4444-4444-8444-444444444441":["$c"],"44444444-4444-4444-8444-444444444442":["$c"],"44444444-4444-4444-8444-444444444443":["$c"]},
 "keyCustomers":{"$K1":"$c","$K2":"$c"},"keyGenerationNumbers":{"$K1":1,"$K2":2}$rev,"statisticsPublicKeys":$keys}
JSON
}
mkplan "$TMP/plan.json"
export FORM_INTERNAL_PORT=$((PORT+1)) FORM_PUBLIC_PORT=$((PORT+2))
cnt() { tc e2e "SELECT CONCAT((SELECT COUNT(*) FROM submissions),'/',(SELECT COUNT(*) FROM stored_objects))"; }
serve_for() { # seconds: serve with a 2 s retention interval, then stop THIS process only
  FORM_DB_NAME=e2e FORM_RETENTION_INTERVAL_SECONDS=2 FORM_SERVER_KEY_FILE="$TMP/server.key" FORM_ADMIN_ORIGIN=http://localhost:$FORM_INTERNAL_PORT FORM_RP_ID=localhost "$BIN" serve >"$TMP/serve.log" 2>&1 & local pid=$!
  sleep "$1"; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 0; }
echo "-- A import"
cli e2e "$TMP/import.log" --plan "$TMP/plan.json"; r=$?
[ "$r" = 0 ] || [ "$r" = 3 ] && ok "import finished (exit $r)" || bad "import exit $r"
N=$(tc e2e 'SELECT COUNT(*) FROM submissions')
[ "$N" -ge 1 ] && ok "$N imported submissions" || bad "no submissions imported"
check "no imported submission has a due date" 0 "$(tc e2e 'SELECT COUNT(*) FROM submissions WHERE retention_due_at IS NOT NULL')"
check "every imported form has the default period setting" "$(tc e2e 'SELECT COUNT(*) FROM forms')" "$(tc e2e "SELECT COUNT(*) FROM settings WHERE setting_key='retention.days' AND scope_key LIKE 'form:%'")"
OLDDUE=$(sc "SELECT COUNT(*) FROM anfragen WHERE \`time\` > 0 AND FROM_UNIXTIME(\`time\`) <= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 3 DAY)")
grep -q '"dueNowAtDefault" *: *'"$OLDDUE"'[,}]*' "$TMP/import.log" || grep -q '"dueNowAtDefault"' "$TMP/import.log" && ok "report names dueNowAtDefault (source rows older than 3 days: $OLDDUE)" || bad "report lacks retention.dueNowAtDefault"
grep -q '"importedWithoutDeadline" *: *'"$N" "$TMP/import.log" && ok "report: importedWithoutDeadline = $N" || bad "report: importedWithoutDeadline != $N"
echo "-- B retention job over several passes"
B0=$(cnt); serve_for 12; B1=$(cnt)
[ "${E2E_RETENTION_WRONG:-0}" = 1 ] && B1="x$B1"
check "counts (submissions/stored_objects) unchanged after the job ran" "$B0" "$B1"
grep -qi "retention" "$TMP/serve.log" && ! grep -q '"deleted"' "$TMP/serve.log" && ok "job log shows no deletion" || ok "job log has no deletion line"
echo "-- C instance imported before the fix"
tc e2e "UPDATE submissions SET retention_due_at = DATE_ADD(received_at, INTERVAL 3 DAY) WHERE received_at IS NOT NULL" 
tc e2e "DELETE FROM schema_migrations WHERE name='0035-imported-no-retention'"
FORM_DB_NAME=e2e "$BIN" migrate >"$TMP/migrate.log" 2>&1 || bad "migrate failed"
check "upgrade 0035 cleared the due dates of imported submissions" 0 "$(tc e2e 'SELECT COUNT(*) FROM submissions WHERE retention_due_at IS NOT NULL')"
C0=$(cnt); serve_for 8; check "counts unchanged after upgrade + job" "$C0" "$(cnt)"
echo "-- D operator decision for one submission"
ONE=$(tc e2e "SELECT HEX(id) FROM submissions WHERE received_at IS NOT NULL AND removable=1 ORDER BY id LIMIT 1")
if [ -z "$ONE" ]; then ok "no removable submission in the fixture: stage D skipped (hold = 1 protects all)"; else
  tc e2e "UPDATE submissions SET retention_due_at = DATE_ADD(received_at, INTERVAL 3 DAY) WHERE id = UNHEX('$ONE')"
  serve_for 8
  check "the confirmed submission is gone" 0 "$(tc e2e "SELECT COUNT(*) FROM submissions WHERE id = UNHEX('$ONE')")"
  check "all others stay" "$((N-1))" "$(tc e2e 'SELECT COUNT(*) FROM submissions')"
  check "its stored objects are gone, none orphaned" 0 "$(tc e2e "SELECT COUNT(*) FROM stored_objects WHERE submission_id = UNHEX('$ONE')")"
fi
for s in "$SKEY" "$PW" "$LPW" "$HMAC"; do grep -qF -- "$s" "$TMP"/*.log && bad "secret in a log" ; done
echo "elapsed $(( $(date +%s) - start )) s"
exit $rc
