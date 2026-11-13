#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Finding 15C5D5E9: a legacy attachment of ~20 MB (about 27 MB as a package cell) against the target's max_allowed_packet, as a REAL PROCESS
# (real binary `App migrate-legacy`, real legacy MariaDB with the cell, two real target MariaDB servers, no mocks, no browser, SYNTHETIC bytes only):
#   A  target at the 16 MiB default: the dry run AND the real run stop BEFORE the first write with the named cause (targetPacketTooSmall,
#      exit 1), the target stays unchanged. Without the check this ended after many rows with database error 1301 (CONCAT result > limit).
#   B  target at the recommended 64 MiB: dry run exit 0 (target unchanged), real import finishes (exit 0 or 3 = open review cases of the
#      synthetic dump), the 27 MB cell is in the target byte for byte (length and SHA-256 equal to the source).
# E2E_BIN=<path> uses another binary without building (red proof with the build before the fix). E2E_PACKET_WRONG=1 flips one expectation
# on purpose (must exit 1). Exit 0 ok, 1 failed, 2 environment.
# Ports: from e2e-common.sh (override P3B_PORT target 16 MiB, P3B_PORT2 target 64 MiB, LEGACY_PORT).
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
ROOT=$PWD
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
LNAME=$(e2e_name p4a-pk-legacy); LPORT=${LEGACY_PORT:-$(e2e_pick_port)}
NAMEA=$(e2e_name p4a-pk-small); PORTA=${P3B_PORT:-$(e2e_pick_port)}
NAMEB=$(e2e_name p4a-pk-big); PORTB=${P3B_PORT2:-$(e2e_pick_port)}
PW=$(openssl rand -hex 16); LPW=$(openssl rand -hex 16); TMP=$(mktemp -d)
HMAC=$(openssl rand -base64 32); SKEY=$(openssl rand -hex 32)
rc=0
savelogs() { [ -n "${E2E_LOG_DIR:-}" ] || return 0; mkdir -p "$E2E_LOG_DIR"; for l in "$TMP"/*.log; do [ -f "$l" ] && cp "$l" "$E2E_LOG_DIR/$(basename "$0" .sh)-$(basename "$l")"; done; return 0; }
cleanup() { savelogs; e2e_cleanup; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
e2e_reap_stale
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; rc=1; }
check() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: expected '$2', got '$3'"; fi; }
start=$(date +%s)
umask 077; printf '%s' "$SKEY" > "$TMP/server.key"
IMG=${MARIADB_IMAGE:-mariadb:lts}
# The legacy server runs with a large limit (the old documentation asks for >= 32 MB); the targets differ ONLY in max_allowed_packet.
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$LNAME" -p "127.0.0.1:$LPORT:3306" -e MARIADB_ROOT_PASSWORD="$LPW" -e MARIADB_DATABASE=legacy "$IMG" --max-allowed-packet=134217728 >/dev/null || { echo "ENV: legacy container"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$NAMEA" -p "127.0.0.1:$PORTA:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "$IMG" --max-allowed-packet=16777216 >/dev/null || { echo "ENV: container A"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --name "$NAMEB" -p "127.0.0.1:$PORTB:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "$IMG" --max-allowed-packet=67108864 >/dev/null || { echo "ENV: container B"; exit 2; }
wait_db() { for _ in $(seq 90); do "$DOCKER" exec -e MYSQL_PWD="$2" "$1" mariadb -uroot -e 'select 1' "$3" >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$2" "$1" mariadb -uroot -e 'select 1' "$3" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
wait_db "$LNAME" "$LPW" legacy || { echo "ENV: legacy db not ready"; exit 2; }
wait_db "$NAMEA" "$PW" e2e || { echo "ENV: db A not ready"; exit 2; }
wait_db "$NAMEB" "$PW" e2e || { echo "ENV: db B not ready"; exit 2; }
FIX=backend/Tests/FormMigrationTests/Fixtures
{ echo "SET FOREIGN_KEY_CHECKS=0;"; cat "$FIX/legacy-real.sql" "$FIX/legacy-synthetic.sql"; } | "$DOCKER" exec -i -e MYSQL_PWD="$LPW" "$LNAME" mariadb -uroot legacy >"$TMP/legacy-load.log" 2>&1 || { tail -3 "$TMP/legacy-load.log"; echo "ENV: synthetic dump import failed"; exit 2; }
"$DOCKER" exec -e MYSQL_PWD="$LPW" "$LNAME" mariadb -uroot -e "CREATE USER 'migro'@'%' IDENTIFIED BY '$LPW'; GRANT SELECT ON legacy.* TO 'migro'@'%'; FLUSH PRIVILEGES" || { echo "ENV: legacy user"; exit 2; }
s() { "$DOCKER" exec -i -e MYSQL_PWD="$LPW" "$LNAME" mariadb -uroot -N legacy; }
qa() { "$DOCKER" exec -i -e MYSQL_PWD="$PW" "$NAMEA" mariadb -uroot -N "$1"; }
qb() { "$DOCKER" exec -i -e MYSQL_PWD="$PW" "$NAMEB" mariadb -uroot -N "$1"; }
# The attachment of a legacy upload of 20 MB: 6.75 million repetitions of 'QUJD' = 27 MB of base64 ciphertext inside a valid package frame.
CELL=ffffffff-0000-4000-8000-0000000000aa
echo "INSERT INTO anfragen (UUID,time,formularUUID,sentServer,data,file1Name,malwareScanStatus,removable,file1Enc) SELECT '$CELL',time,formularUUID,sentServer,data,'gross.bin','sauber',1,CONCAT(SUBSTRING_INDEX(data,'|',5),'|',REPEAT('QUJD',6750000),'|',SUBSTRING_INDEX(data,'|',-1)) FROM anfragen WHERE ID=1" | s || { echo "ENV: large cell"; exit 2; }
SRCLEN=$(echo "SELECT OCTET_LENGTH(file1Enc) FROM anfragen WHERE UUID='$CELL'" | s); SRCSHA=$(echo "SELECT SHA2(file1Enc,256) FROM anfragen WHERE UUID='$CELL'" | s)
echo "ok   source ready: attachment cell $SRCLEN bytes (~$(( SRCLEN / 1048576 )) MiB); target A max_allowed_packet $(echo 'SELECT @@global.max_allowed_packet' | qa e2e), target B $(echo 'SELECT @@global.max_allowed_packet' | qb e2e)"
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
if [ -z "${E2E_BIN:-}" ]; then
  BUILD="swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App"
  $BUILD >/dev/null 2>&1 || { sleep 2; $BUILD >/dev/null 2>&1; } || { echo "ENV: build"; exit 2; }
fi
BIN=${E2E_BIN:-$ROOT/backend/.build/debug/App}
export FORM_DB_USER=root FORM_DB_PASSWORD=$PW FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1 FORM_SCHEMA_FILE=backend/db/schema-p3.sql
newdb() { echo "CREATE DATABASE IF NOT EXISTS $2" | "$1" e2e; FORM_DB_PORT=$([ "$1" = qa ] && echo "$PORTA" || echo "$PORTB") FORM_DB_NAME=$2 "$BIN" migrate >/dev/null 2>&1 || { echo "ENV: migrate $2"; exit 2; }; }
cli() { # port db log args...
  local port=$1 db=$2 log=$3; shift 3
  perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' env "FORM_DB_PORT=$port" "FORM_DB_NAME=$db" "FORM_MIGRATION_HMAC_KEY=$HMAC" "FORM_SERVER_KEY_FILE=$TMP/server.key" "LEGACY_DB_HOST=127.0.0.1" "LEGACY_DB_PORT=$LPORT" "LEGACY_DB_NAME=legacy" \
    "LEGACY_DB_USER=migro" "LEGACY_DB_PASSWORD=$LPW" "LEGACY_DB_TLS=disable" "$BIN" migrate-legacy "$@" >"$log" 2>&1
}
CUST=0c0c0c0c-0c0c-4c0c-8c0c-0c0c0c0c0c0c; HASH=$(openssl rand -hex 32)
F1=11111111-1111-4111-8111-111111111111; F2=22222222-2222-4222-8222-222222222222; F3=33333333-3333-4333-8333-333333333333
K1=a6077815bba8b14c; K2=d19bf3f082782c87
cat > "$TMP/plan.json" <<JSON
{"namespace":"packet-e2e","dumpSHA256":"$HASH","customers":{"$CUST":"Packet Test GmbH"},
 "formCustomers":{"$F1":"$CUST","$F2":"$CUST","$F3":"$CUST"},
 "connectionCustomers":{"44444444-4444-4444-8444-444444444441":["$CUST"],"44444444-4444-4444-8444-444444444442":["$CUST"],"44444444-4444-4444-8444-444444444443":["$CUST"]},
 "keyCustomers":{"$K1":"$CUST","$K2":"$CUST"},"keyGenerationNumbers":{"$K1":1,"$K2":2},"statisticsPublicKeys":{}}
JSON
newdb qa e2e; newdb qb e2e
rowsum() { local q=$1; for t in $(echo "SELECT table_name FROM information_schema.tables WHERE table_schema='e2e' ORDER BY 1" | $q information_schema); do echo "$t $(echo "SELECT COUNT(*) FROM \`$t\`" | $q e2e)"; done | cksum; }
BASEA=$(rowsum qa); BASEB=$(rowsum qb)
echo "ok   targets ready ($(( $(date +%s) - start )) s)"

echo "-- A target at the 16 MiB default"
cli "$PORTA" e2e "$TMP/a-dry.log" --plan "$TMP/plan.json" --dry-run; r=$?
check "dry run exit code (1 = refused)" 1 "$r"
grep -q "targetPacketTooSmall" "$TMP/a-dry.log" && ok "dry run names the cause (targetPacketTooSmall)" || bad "dry run does not name targetPacketTooSmall: $(head -c 300 "$TMP/a-dry.log")"
grep -q "1301" "$TMP/a-dry.log" && bad "dry run still ends with database error 1301: $(head -c 300 "$TMP/a-dry.log")" || ok "no database error 1301"
echo "     message: $(head -c 240 "$TMP/a-dry.log" | tr '\n' ' ')"
check "dry run wrote nothing" "$BASEA" "$(rowsum qa)"
cli "$PORTA" e2e "$TMP/a-real.log" --plan "$TMP/plan.json"; r=$?
check "real run exit code (1 = refused)" 1 "$r"
grep -q "targetPacketTooSmall" "$TMP/a-real.log" && ok "real run names the cause" || bad "real run does not name targetPacketTooSmall: $(head -c 300 "$TMP/a-real.log")"
check "real run wrote nothing before the first write (no customer, no run, no object)" "0 0 0" "$(echo 'SELECT (SELECT COUNT(*) FROM customers),(SELECT COUNT(*) FROM migration_runs),(SELECT COUNT(*) FROM stored_objects)' | qa e2e | tr '\t' ' ')"
check "target unchanged after both runs" "$BASEA" "$(rowsum qa)"

echo "-- B target at the recommended 64 MiB"
cli "$PORTB" e2e "$TMP/b-dry.log" --plan "$TMP/plan.json" --dry-run; r=$?
check "dry run exit code" 0 "$r"
check "dry run left the target unchanged" "$BASEB" "$(rowsum qb)"
t0=$(date +%s); cli "$PORTB" e2e "$TMP/b-import.log" --plan "$TMP/plan.json"; r=$?
if [ "$r" = 0 ] || [ "$r" = 3 ]; then ok "import finished (exit $r; 3 = open review cases of the synthetic dump), $(( $(date +%s) - t0 )) s"; else bad "import exit code $r: $(head -c 300 "$TMP/b-import.log")"; fi
check "submissions = source anfragen" "$(echo 'SELECT COUNT(*) FROM anfragen' | s)" "$(echo 'SELECT COUNT(*) FROM submissions' | qb e2e)"
check "the large cell: target ciphertext length = source" "$SRCLEN" "$(echo "SELECT OCTET_LENGTH(ciphertext) FROM stored_objects WHERE object_role='attachment' ORDER BY byte_count DESC LIMIT 1" | qb e2e)"
check "the large cell: byte_count = source" "$SRCLEN" "$(echo "SELECT MAX(byte_count) FROM stored_objects WHERE object_role='attachment'" | qb e2e)"
check "the large cell: SHA-256 of the target bytes = source" "$SRCSHA" "$(echo "SELECT LOWER(SHA2(ciphertext,256)) FROM stored_objects WHERE object_role='attachment' ORDER BY byte_count DESC LIMIT 1" | qb e2e)"
check "the large cell: stored hash column = source" "$SRCSHA" "$(echo "SELECT LOWER(HEX(ciphertext_sha256)) FROM stored_objects WHERE object_role='attachment' ORDER BY byte_count DESC LIMIT 1" | qb e2e)"
if [ "${E2E_PACKET_WRONG:-0}" = 1 ]; then check "ABSICHTLICH FALSCH: byte_count" 1 "$(echo "SELECT MAX(byte_count) FROM stored_objects WHERE object_role='attachment'" | qb e2e)"; fi
for secret in "$LPW" "$PW" "$SKEY" "$HMAC"; do
  if grep -rlF -- "$secret" "$TMP"/*.log >/dev/null 2>&1; then bad "a secret appears in a CLI output"; fi
done
echo "runtime $(( $(date +%s) - start )) s"
exit $rc
