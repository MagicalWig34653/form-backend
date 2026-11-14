#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Real UI end-to-end of the retention panel with IMPORTED submissions (QA D945BDCD, card C174F624): real binary, real target + legacy MariaDB,
# `App migrate-legacy`, `App serve` with a 2 s retention job, Chromium with a virtual WebAuthn authenticator. Form > Datenschutz > Aufbewahrung:
#   dry run text, save WITHOUT the checkbox (one PUT, no applyToImported, imported rows keep NULL), Cancel in the dialog (no PUT),
#   checkbox + confirm (exactly one PUT with applyToImported=true, due dates written, the job deletes exactly the due ones).
# E2E_RETENTION_UI_WRONG=1 flips one expectation (red proof, exit 1). Exit 0 ok, 1 failed, 2 environment.
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
WPORT=$FORM_INTERNAL_PORT
e2e_pwa_build "$TMP/dist" || { echo "ENV: pwa build"; exit 2; }
export FORM_PUBLIC_DIR="$TMP/dist" FORM_SERVER_KEY_FILE="$TMP/server.key" FORM_ADMIN_ORIGIN=http://localhost:$WPORT FORM_RP_ID=localhost FORM_DB_NAME=e2e
PASSWORD=$(openssl rand -hex 12); printf '%s' "$PASSWORD" > "$TMP/bootpw"
OUT=$(FORM_BOOTSTRAP_PASSWORD_FILE="$TMP/bootpw" "$BIN" bootstrap-admin admin 2>&1) || { echo "FAIL bootstrap-admin"; echo "$OUT" | head -3; exit 1; }
LINK=$(printf '%s\n' "$OUT" | sed -n 's/.*): \(http[^ ]*\)$/\1/p' | head -1)
[ -n "$LINK" ] || { echo "FAIL no link in output"; exit 1; }
cli e2e "$TMP/import.log" --plan "$TMP/plan.json"; r=$?
{ [ "$r" = 0 ] || [ "$r" = 3 ]; } && ok "import finished (exit $r)" || { bad "import exit $r"; tail -5 "$TMP/import.log"; exit 1; }
N=$(tc e2e 'SELECT COUNT(*) FROM submissions'); ok "$N imported submissions"
check "imported submissions have no due date" 0 "$(tc e2e 'SELECT COUNT(*) FROM submissions WHERE retention_due_at IS NOT NULL')"
# short retention job pass (2 s) for the whole run; imported rows carry no due date, so nothing may disappear before the decision
FORM_RETENTION_INTERVAL_SECONDS=2 "$BIN" serve >"$TMP/app.log" 2>&1 & APP_PID=$!
trap 'kill $APP_PID 2>/dev/null; cleanup' EXIT
for _ in $(seq 30); do curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 && break; sleep 1; done
export E2E_SETUP_LINK="$LINK" E2E_PASSWORD="$PASSWORD" E2E_PORT=$WPORT E2E_SPEC=real-retention-ui.spec.ts
export E2E_DOCKER="$DOCKER" E2E_DB_CONTAINER="$NAME" E2E_DB_PASSWORD="$PW"
(cd pwa && npx playwright test -c e2e-real/playwright.config.ts) >"$TMP/playwright.log" 2>&1; prc=$?
tail -40 "$TMP/playwright.log"
[ "$prc" = 0 ] && ok "browser steps" || bad "browser steps (exit $prc)"
TOKEN=${LINK##*#}
grep -q "$TOKEN" "$TMP/app.log" && bad "enrollment token in app log"
grep -q "$PASSWORD" "$TMP/app.log" && bad "password in app log"
echo "elapsed $(( $(date +%s) - start )) s"
exit $rc
