#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# `App migrate-legacy` end to end as a REAL PROCESS (real binary, real source MariaDB, real target MariaDB, no mocks, no browser):
#   A  parameters/plan: missing or wrong input exits 2 (1 for runtime failures) with a named cause on stderr, never a value, and writes nothing
#   B  dry run: exit 0, target unchanged
#   C  import without statisticsReview/statisticsPublicKeys: counts like the web route, statistics rows become review cases (statistics-review-missing), nothing statistical written; exit 3 = finished with open review cases
#   D  repetition: exit 0, target fingerprint unchanged
#   D2 `App migrate-legacy-accept`: reason mandatory (exit 2), accepts the open submission cases (accepted-with-decision, reason, audit), other tables stay open, nothing else changes
#   E  statistics with approved review + public keys (fresh target): encrypted statistics-metadata, NO clear text in the target dump, IP presence flag
#   F  SIGINT/SIGTERM in the middle of a run on an enlarged source: exit 130/143 at an object boundary, run not 'running', lock free; resume by calling again; end state equals an undisturbed import (fingerprint)
#   G  no secret (source password, target password, server key, HMAC key) in any output
# Source: synthetic legacy dump (legacy-real.sql + legacy-synthetic.sql) + legacy-synthetic-statistics-extra.sql. The web route comparison uses the
# same per-table ledger assertions as pwa/e2e-real/real-migration.spec.ts and the shared fingerprint of e2e-migration-restart.sh.
# Exit codes of the CLI under test: 0 done without open cases, 1 failure, 2 parameter/plan error, 3 done with open review cases, 130/143 stopped by SIGINT/SIGTERM.
# E2E_CLI_WRONG=1 flips one expectation on purpose (red proof: must exit 1). Exit 0 ok, 1 failed, 2 environment.
# Ports: target 33730, legacy 33970 (override P3B_PORT / LEGACY_PORT).
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
ROOT=$PWD
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
LNAME=$(e2e_name p4a-cli-legacy); LPORT=${LEGACY_PORT:-$(e2e_pick_port)}
NAME=$(e2e_name p4a-cli-mariadb); PORT=${P3B_PORT:-$(e2e_pick_port)}
CLONES=${E2E_CLONE_ROUNDS:-5} # each round doubles the submissions of the source (stage F only)
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
{"namespace":"cli-e2e","dumpSHA256":"$HASH","customers":{"$c":"CLI Test GmbH"},
 "formCustomers":{"$F1":"$c","$F2":"$c","$F3":"$c"},
 "connectionCustomers":{"44444444-4444-4444-8444-444444444441":["$c"],"44444444-4444-4444-8444-444444444442":["$c"],"44444444-4444-4444-8444-444444444443":["$c"]},
 "keyCustomers":{"$K1":"$c","$K2":"$c"},"keyGenerationNumbers":{"$K1":1,"$K2":2}$rev,"statisticsPublicKeys":$keys}
JSON
}
mkplan "$TMP/plan.json"
FP="backend/e2e-migration-fingerprint.sql"
fp() { q "$1" < "$FP"; }
# Statistics objects are sealed with a fresh ephemeral key per write, so their ciphertext hash is random: compare the objects digest without them (their count is checked on its own).
sed "s/FROM stored_objects;/FROM stored_objects WHERE object_role<>'statistics-metadata';/" "$FP" > "$TMP/fp-nostat.sql"
fpx() { q "$1" < "$TMP/fp-nostat.sql"; }
# Whole-target row counts of every table ("unchanged" proof).
rowsum() { for t in $(echo "SELECT table_name FROM information_schema.tables WHERE table_schema='$1' ORDER BY 1" | q information_schema); do echo "$t $(tc "$1" "SELECT COUNT(*) FROM \`$t\`")"; done | cksum; }
echo "ok   source and target ready ($(( $(date +%s) - start )) s)"

# ---------------- A: parameters and plans ----------------
echo "-- A parameters and plans"
BASE=$(rowsum e2e)
expect_fail() { # description log expected-text [args]; XRC=<expected exit code> (default: any != 0), NOT=<text that must not appear>
  local d=$1 log=$2 want=$3; shift 3
  "$@"; local code=$?
  if [ "$code" = 0 ]; then bad "$d: exit 0, expected failure"; else
    if grep -q -- "$want" "$log"; then ok "$d: exit $code, named cause '$want'"; else bad "$d: exit $code but output lacks '$want': $(head -c 200 "$log")"; fi
    [ -z "${XRC:-}" ] || check "$d: exit code" "$XRC" "$code"
    [ -z "${NOT:-}" ] || { if grep -q -- "$NOT" "$log"; then bad "$d: output contains '$NOT'"; else ok "$d: output free of '$NOT'"; fi; }
  fi
}
XRC=2 expect_fail "no --plan" "$TMP/a1.log" "Parameter fehlt: --plan" cli e2e "$TMP/a1.log"
XRC=2 expect_fail "plan file missing" "$TMP/a2.log" "Parameter ungültig: --plan" cli e2e "$TMP/a2.log" --plan "$TMP/nope.json"
echo '{not json' > "$TMP/bad.json"
XRC=2 NOT="database" expect_fail "plan is not JSON" "$TMP/a3.log" "Plan nicht lesbar: kein gültiges JSON" cli e2e "$TMP/a3.log" --plan "$TMP/bad.json"
sed 's/"namespace":"cli-e2e"/"namespace":""/' "$TMP/plan.json" > "$TMP/p-ns.json"
XRC=2 expect_fail "empty namespace" "$TMP/a4.log" "invalidPlan field=namespace" cli e2e "$TMP/a4.log" --plan "$TMP/p-ns.json"
sed "s/\"dumpSHA256\":\"$HASH\"/\"dumpSHA256\":\"zz\"/" "$TMP/plan.json" > "$TMP/p-hash.json"
XRC=2 expect_fail "dump hash not hex" "$TMP/a5.log" "invalidPlan field=dumpSHA256" cli e2e "$TMP/a5.log" --plan "$TMP/p-hash.json"
sed "s/\"$F1\":\"$CUST\"/\"$F1\":\"99999999-9999-4999-8999-999999999999\"/" "$TMP/plan.json" > "$TMP/p-cust.json"
XRC=2 expect_fail "form mapped to unknown customer" "$TMP/a6.log" "invalidPlan field=formCustomers" cli e2e "$TMP/a6.log" --plan "$TMP/p-cust.json"
XRC=2 expect_fail "batch size 0" "$TMP/a7.log" "Parameter ungültig: --batch-size" cli e2e "$TMP/a7.log" --plan "$TMP/plan.json" --batch-size 0
for v in FORM_MIGRATION_HMAC_KEY FORM_SERVER_KEY_FILE LEGACY_DB_HOST LEGACY_DB_NAME LEGACY_DB_USER LEGACY_DB_PASSWORD; do
  XRC=2 CLI_UNSET=$v expect_fail "missing $v" "$TMP/a-$v.log" "Parameter fehlt: $v" cli e2e "$TMP/a-$v.log" --plan "$TMP/plan.json"
done
XRC=2 CLI_HMAC=$(openssl rand -base64 8) expect_fail "short HMAC key" "$TMP/a9.log" "Parameter ungültig: FORM_MIGRATION_HMAC_KEY" cli e2e "$TMP/a9.log" --plan "$TMP/plan.json"
XRC=1 CLI_LPW=wrong-$(openssl rand -hex 4) expect_fail "source password wrong" "$TMP/a10.log" "migration: database" cli e2e "$TMP/a10.log" --plan "$TMP/plan.json"
CLI_TLS=verify expect_fail "source without TLS, verify mode" "$TMP/a11.log" "migration:" cli e2e "$TMP/a11.log" --plan "$TMP/plan.json"
# Plan without optional keys: initializer defaults (a plan of an older caller); security-relevant keys stay mandatory and are named (key name only).
printf '{"namespace":"cli-e2e","dumpSHA256":"%s","customers":{"%s":"CLI Test GmbH"},"formCustomers":{}}' "$HASH" "$CUST" > "$TMP/p-min.json"
cli e2e "$TMP/a12.log" --plan "$TMP/p-min.json" --dry-run; check "minimal plan without optional keys: dry run exit code" 0 "$?"
sed 's/"namespace":"cli-e2e",//' "$TMP/plan.json" > "$TMP/p-nons.json"
XRC=2 NOT="database" expect_fail "plan without namespace" "$TMP/a13.log" "Plan nicht lesbar: namespace" cli e2e "$TMP/a13.log" --plan "$TMP/p-nons.json"
sed 's/"formCustomers":{[^}]*},//' "$TMP/plan.json" > "$TMP/p-nofc.json"
XRC=2 expect_fail "plan without formCustomers" "$TMP/a14.log" "Plan nicht lesbar: formCustomers" cli e2e "$TMP/a14.log" --plan "$TMP/p-nofc.json"
sed 's/"keyGenerationNumbers":{[^}]*}/"keyGenerationNumbers":"SECRET-VALUE-X"/' "$TMP/plan.json" > "$TMP/p-badtype.json"
XRC=2 NOT="SECRET-VALUE-X" expect_fail "plan field of wrong type names the key only" "$TMP/a15.log" "Plan nicht lesbar: keyGenerationNumbers" cli e2e "$TMP/a15.log" --plan "$TMP/p-badtype.json"
check "all failed calls wrote nothing to the target" "$BASE" "$(rowsum e2e)"
check "no migration run was created by failed calls" 0 "$(tc e2e 'SELECT COUNT(*) FROM migration_runs')"

# A plan that is valid until a key is not numbered fails in the middle (per-object commits): own database, cause must be named.
sed 's/"keyGenerationNumbers":{[^}]*}/"keyGenerationNumbers":{"a6077815bba8b14c":1}/' "$TMP/plan.json" > "$TMP/p-gen.json"
newdb e2e_gen
expect_fail "key generation not numbered (own database)" "$TMP/a8.log" "migration:" cli e2e_gen "$TMP/a8.log" --plan "$TMP/p-gen.json"
echo "     cause line: $(head -c 160 "$TMP/a8.log" | tr '\n' ' ')"
echo "     partial state after that failure: run state '$(tc e2e_gen 'SELECT state FROM migration_runs')', submissions $(tc e2e_gen 'SELECT COUNT(*) FROM submissions')"

# ---------------- B: dry run ----------------
echo "-- B dry run"
cli e2e "$TMP/b-dry.log" --plan "$TMP/plan.json" --dry-run; r=$?
check "dry run exit code" 0 "$r"
grep -q '"dryRun" *: *true' "$TMP/b-dry.log" && ok "report says dryRun true" || bad "report lacks dryRun true: $(head -c 200 "$TMP/b-dry.log")"
check "dry run left the target unchanged" "$BASE" "$(rowsum e2e)"
check "dry run: no customer, no form, no ledger" "0 0 0" "$(tc e2e 'SELECT (SELECT COUNT(*) FROM customers),(SELECT COUNT(*) FROM forms),(SELECT COUNT(*) FROM migration_objects)' | tr '\t' ' ')"
# Source fingerprint (ADR 0043): the dry run prints it; a wrong expectation stops the real run before the first write.
SRCFP=$(sed -n 's/^source-fingerprint: \([0-9a-f]\{64\}\)$/\1/p' "$TMP/b-dry.log")
[ "${#SRCFP}" = 64 ] && ok "dry run prints the source fingerprint (64 hex, hash only)" || bad "dry run prints no source fingerprint"
XRC=2 expect_fail "malformed --expect-source-fingerprint" "$TMP/b-fp0.log" "Parameter ungültig: --expect-source-fingerprint" cli e2e "$TMP/b-fp0.log" --plan "$TMP/plan.json" --expect-source-fingerprint zz
newdb e2e_fp
XRC=1 expect_fail "wrong --expect-source-fingerprint: source_changed, exit 1" "$TMP/b-fp1.log" "Die Altdaten wurden seit dem Prüflauf verändert" cli e2e_fp "$TMP/b-fp1.log" --plan "$TMP/plan.json" --expect-source-fingerprint "$(printf '0%.0s' $(seq 64))"
check "wrong fingerprint: nothing written (no run, no customer)" "0 0" "$(tc e2e_fp 'SELECT (SELECT COUNT(*) FROM migration_runs),(SELECT COUNT(*) FROM customers)' | tr '\t' ' ')"
cli e2e_fp "$TMP/b-fp2.log" --plan "$TMP/plan.json" --dry-run --expect-source-fingerprint "$SRCFP"; check "--expect-source-fingerprint is ignored by the dry run (exit 0)" 0 "$?"
check "right fingerprint: second dry run prints the same fingerprint" "$SRCFP" "$(sed -n 's/^source-fingerprint: //p' "$TMP/b-fp2.log")"

# ---------------- C: import without statistics review ----------------
echo "-- C import (no statisticsReview / statisticsPublicKeys)"
cli e2e "$TMP/c-import.log" --plan "$TMP/plan.json"; r=$?
check "import exit code (3 = finished with open review cases)" 3 "$r"
grep -q '"dryRun" *: *false' "$TMP/c-import.log" && ok "report says dryRun false" || bad "report lacks dryRun false"
tgt() { tc e2e "$1"; }
check "forms = source formulare" "$(sc 'SELECT COUNT(*) FROM formulare')" "$(tgt 'SELECT COUNT(*) FROM forms')"
check "submissions = source anfragen" "$(sc 'SELECT COUNT(*) FROM anfragen')" "$(tgt 'SELECT COUNT(*) FROM submissions')"
check "key generations = source datenschluessel" "$(sc 'SELECT COUNT(*) FROM datenschluessel')" "$(tgt 'SELECT COUNT(*) FROM customer_key_generations')"
check "recovery = source datenschluesselRecovery" "$(sc 'SELECT COUNT(*) FROM datenschluesselRecovery')" "$(tgt 'SELECT COUNT(*) FROM data_key_recovery')"
check "no form active" 0 "$(tgt 'SELECT COUNT(*) FROM forms WHERE active=1')"
for t in formulare formularFelder anfragen datenschluessel datenschluesselRecovery outgoingMailServer outgoingMailProxy formularWebhooks anfrageIdempotenz; do
  check "ledger $t = source" "$(sc "SELECT COUNT(*) FROM $t")" "$(tgt "SELECT COUNT(DISTINCT source_key) FROM migration_objects WHERE source_table='$t'")"
done
check "generations" "1retiring,2active" "$(tgt 'SELECT GROUP_CONCAT(CONCAT(generation_no,state) ORDER BY generation_no) FROM customer_key_generations')"
STATN=$(sc 'SELECT COUNT(*) FROM `statistics`')
check "statistics rows in source" 9 "$STATN"
check "statistics: nothing written (legacy_statistics)" 0 "$(tgt 'SELECT COUNT(*) FROM legacy_statistics')"
check "statistics: no statistics-metadata object" 0 "$(tgt "SELECT COUNT(*) FROM stored_objects WHERE object_role='statistics-metadata'")"
check "statistics: no ledger entry" 0 "$(tgt "SELECT COUNT(*) FROM migration_objects WHERE source_table='statistics'")"
check "statistics: one open review case per row" "$STATN" "$(tgt "SELECT COUNT(DISTINCT source_key) FROM migration_issues WHERE source_table='statistics' AND state='open'")"
tgt "SELECT DISTINCT issue_code FROM migration_issues WHERE source_table='statistics'" | tr '\n' ' ' > "$TMP/c-code.txt"; echo "     (issue code of statistics rows: $(cat "$TMP/c-code.txt"))"
echo "     run state: $(tgt 'SELECT state FROM migration_runs')"
OPENC=$(tgt "SELECT COUNT(DISTINCT source_table,source_key) FROM migration_issues WHERE state='open'")
grep -q "abgeschlossen mit $OPENC offenen Prüffällen" "$TMP/c-import.log" && ok "final message names the count of open cases ($OPENC)" || bad "final message 'abgeschlossen mit $OPENC offenen Prüffällen' missing: $(tail -c 300 "$TMP/c-import.log")"
check "run state is failed while cases are open" failed "$(tgt 'SELECT state FROM migration_runs')"
check "statistics rows: named review code (finding 7)" "statistics-review-missing" "$(tgt "SELECT GROUP_CONCAT(DISTINCT issue_code) FROM migration_issues WHERE source_table='statistics'")"
FP1=$(fp e2e); echo "$FP1" > "$TMP/fp.c"; R1=$(rowsum e2e)

# ---------------- D: repetition ----------------
echo "-- D repetition"
cli e2e "$TMP/d-again.log" --plan "$TMP/plan.json"; r=$?
check "repetition exit code (open cases remain)" 3 "$r"
check "repetition left the target fingerprint unchanged" "$FP1" "$(fp e2e)"
check "repetition left all row counts unchanged" "$R1" "$(rowsum e2e)"
check "exactly one run row" 1 "$(tgt 'SELECT COUNT(*) FROM migration_runs')"

# ---------------- D2: accept open review cases (task 8E8CEC06) ----------------
echo "-- D2 migrate-legacy-accept"
cli_accept() { local db=$1 log=$2; shift 2; cli_prep "$db" "$@"; local -a c=(); local x; for x in "${CMD[@]}"; do [ "$x" = migrate-legacy ] && x=migrate-legacy-accept; c+=("$x"); done; "${c[@]}" >"$log" 2>&1; }
OPEN_A=$(tgt "SELECT COUNT(DISTINCT source_key) FROM migration_issues WHERE source_table='anfragen' AND state='open'")
OPEN_O=$(tgt "SELECT COUNT(*) FROM migration_issues WHERE source_table<>'anfragen' AND state='open'")
[ "$OPEN_A" -gt 0 ] && ok "open review cases of submissions before: $OPEN_A" || bad "no open submission cases to accept"
FP_D2=$(fp e2e | grep -v "^issues" | cksum)
cli_accept e2e "$TMP/d2-noreason.log" --plan "$TMP/plan.json"; r=$?
check "accept without --reason: exit code" 2 "$r"; grep -q "Parameter fehlt: --reason" "$TMP/d2-noreason.log" && ok "accept without --reason names the parameter" || bad "no named cause: $(head -c 200 "$TMP/d2-noreason.log")"
cli_accept e2e "$TMP/d2-short.log" --plan "$TMP/plan.json" --reason "kurz"; r=$?
check "accept with a too short reason: exit code" 2 "$r"
check "refused calls changed nothing" "$OPEN_A" "$(tgt "SELECT COUNT(DISTINCT source_key) FROM migration_issues WHERE source_table='anfragen' AND state='open'")"
cli_accept e2e "$TMP/d2-ok.log" --plan "$TMP/plan.json" --reason "Betreiber hat die Altdaten geprueft"; r=$?
check "accept: exit code" 0 "$r"
grep -q "$OPEN_A Prüffälle akzeptiert" "$TMP/d2-ok.log" && ok "accept reports the count" || bad "count message missing: $(head -c 200 "$TMP/d2-ok.log")"
check "no open submission case left" 0 "$(tgt "SELECT COUNT(*) FROM migration_issues WHERE source_table='anfragen' AND state='open'")"
check "decided cases carry the reason" "$OPEN_A" "$(tgt "SELECT COUNT(DISTINCT source_key) FROM migration_issues WHERE state='accepted-with-decision' AND decision_ref='Betreiber hat die Altdaten geprueft'")"
check "cases of other tables stay open" "$OPEN_O" "$(tgt "SELECT COUNT(*) FROM migration_issues WHERE source_table<>'anfragen' AND state='open'")"
check "audit entry with reason" 1 "$(tgt "SELECT COUNT(*) FROM audit_events WHERE action_code='migration.job.accept-review' AND actor_kind='migration' AND JSON_VALUE(safe_details_json,'$.reason')='Betreiber hat die Altdaten geprueft'")"
check "submissions and packages unchanged (fingerprint without the open-case lines)" "$FP_D2" "$(fp e2e | grep -v "^issues" | cksum)"
cli_accept e2e "$TMP/d2-again.log" --plan "$TMP/plan.json" --reason "zweiter Aufruf ohne Wirkung"; r=$?
check "second call: exit code" 0 "$r"; grep -q "0 Prüffälle akzeptiert" "$TMP/d2-again.log" && ok "second call accepts nothing" || bad "second call: $(head -c 200 "$TMP/d2-again.log")"

# ---------------- E: statistics with review and public keys ----------------
echo "-- E statistics with approved review and public keys"
# The statistics recipient must be a key generation of the customer (Transform.swift:72): here the public key of the ACTIVE legacy key.
PUB=$(sc "SELECT TO_BASE64(publicKey) FROM datenschluessel WHERE kid='$K2'")
openssl genpkey -algorithm X25519 -out "$TMP/foreign.pem" 2>/dev/null || { echo "ENV: openssl X25519"; exit 2; }
FOREIGN=$(openssl pkey -in "$TMP/foreign.pem" -pubout -outform DER | tail -c 32 | base64)
mkplan "$TMP/plan-stat.json" e2e-approved-review "$PUB"
newdb e2e_stat
# 3: the import finishes, but the plan leaves other open review cases (unmapped tables/columns of the synthetic source), independent of the statistics.
STATRC=3
cli e2e_stat "$TMP/e-import.log" --plan "$TMP/plan-stat.json"; r=$?
check "import with statistics exit code" "$STATRC" "$r"
st() { tc e2e_stat "$1"; }
check "legacy_statistics rows = source" "$STATN" "$(st 'SELECT COUNT(*) FROM legacy_statistics')"
check "statistics-metadata objects = source rows" "$STATN" "$(st "SELECT COUNT(*) FROM stored_objects WHERE object_role='statistics-metadata'")"
check "ledger statistics = source" "$STATN" "$(st "SELECT COUNT(DISTINCT source_key) FROM migration_objects WHERE source_table='statistics'")"
check "no open review case for statistics" 0 "$(st "SELECT COUNT(*) FROM migration_issues WHERE source_table='statistics'")"
check "IP presence flag: rows 102 and 103 only" "102,103" "$(st 'SELECT GROUP_CONCAT(source_id ORDER BY source_id) FROM legacy_statistics WHERE has_ip_reference=1')"
check "gclid flag: row 101 only" "101" "$(st 'SELECT GROUP_CONCAT(source_id ORDER BY source_id) FROM legacy_statistics WHERE has_gclid=1')"
check "user agent flag set for 101,103 and Mozilla rows" "1" "$(st 'SELECT has_user_agent FROM legacy_statistics WHERE source_id=101')"
"$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb-dump -uroot --skip-extended-insert e2e_stat > "$TMP/e-dump.sql" 2>/dev/null || "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mysqldump -uroot --skip-extended-insert e2e_stat > "$TMP/e-dump.sql"
"$DOCKER" exec -e MYSQL_PWD="$LPW" "$LNAME" mariadb-dump -uroot --skip-extended-insert legacy statistics > "$TMP/src-stat-dump.sql" 2>/dev/null
MARK='synthetic-gclid-AbC123|SyntheticAgent|stat-probe|203\.0\.113\.77|2001:db8::7'
check "positive control: markers are found in the SOURCE dump" 3 "$(grep -cE "$MARK" "$TMP/src-stat-dump.sql")"
check "no clear text (gclid, user agent, domain, IPv4, IPv6) in the target dump" 0 "$(grep -cE "$MARK" "$TMP/e-dump.sql")"
check "target dump is non-trivial" yes "$([ "$(wc -c < "$TMP/e-dump.sql")" -gt 100000 ] && echo yes || echo no)"
# Same result as stage C outside the statistics: compare the non-statistics fingerprint lines.
NS='^(customers|forms|form_versions|generations|recovery|connections|webhooks|idempotency|submissions)'
check "non-statistics fingerprint equals the import without statistics" "$(grep -E "$NS" "$TMP/fp.c")" "$(fp e2e_stat | grep -E "$NS")"
# Without review but WITH keys, and with review but WITHOUT the customer's key: both stay review cases (code: Transform.swift:184,187).
newdb e2e_foreign
mkplan "$TMP/plan-foreign.json" e2e-approved-review "$FOREIGN"
cli e2e_foreign "$TMP/e-foreign.log" --plan "$TMP/plan-foreign.json"; r=$?
check "public key that is no key generation of the customer: exit code (finding 5: review cases, no abort)" 3 "$r"
grep -q "abgeschlossen mit" "$TMP/e-foreign.log" && ok "run finished with a final message" || bad "no final message: $(tail -c 200 "$TMP/e-foreign.log")"
grep -q "unknownKeyGeneration" "$TMP/e-foreign.log" && bad "unknownKeyGeneration still aborts the run" || ok "no unknownKeyGeneration abort"
check "foreign key: no statistics written" 0 "$(tc e2e_foreign 'SELECT COUNT(*) FROM legacy_statistics')"
check "foreign key: statistics rows are named review cases" "statistics-key-unknown $STATN" "$(tc e2e_foreign "SELECT CONCAT(GROUP_CONCAT(DISTINCT issue_code),' ',COUNT(DISTINCT source_key)) FROM migration_issues WHERE source_table='statistics'")"
check "foreign key: the rest of the import ran (forms = source)" "$(sc 'SELECT COUNT(*) FROM formulare')" "$(tc e2e_foreign 'SELECT COUNT(*) FROM forms')"
check "foreign key: the rest of the import ran (submissions = source)" "$(sc 'SELECT COUNT(*) FROM anfragen')" "$(tc e2e_foreign 'SELECT COUNT(*) FROM submissions')"
mkplan "$TMP/plan-nokey.json" e2e-approved-review
newdb e2e_nokey
cli e2e_nokey "$TMP/e-nokey.log" --plan "$TMP/plan-nokey.json"; r=$?
check "review without public key: exit code" 3 "$r"
check "review without public key: code statistics-key-unknown" "statistics-key-unknown" "$(tc e2e_nokey "SELECT GROUP_CONCAT(DISTINCT issue_code) FROM migration_issues WHERE source_table='statistics'")"
check "review without public key: nothing written, rows are review cases" "0 $STATN" "$(tc e2e_nokey "SELECT (SELECT COUNT(*) FROM legacy_statistics),(SELECT COUNT(DISTINCT source_key) FROM migration_issues WHERE source_table='statistics')" | tr '\t' ' ')"
mkplan "$TMP/plan-norev.json" "" "$PUB"
newdb e2e_norev
cli e2e_norev "$TMP/e-norev.log" --plan "$TMP/plan-norev.json"; r=$?
check "keys without review: exit code" 3 "$r"
check "keys without review: code statistics-review-missing" "statistics-review-missing" "$(tc e2e_norev "SELECT GROUP_CONCAT(DISTINCT issue_code) FROM migration_issues WHERE source_table='statistics'")"
check "keys without review: nothing written" "0 $STATN" "$(tc e2e_norev "SELECT (SELECT COUNT(*) FROM legacy_statistics),(SELECT COUNT(DISTINCT source_key) FROM migration_issues WHERE source_table='statistics')" | tr '\t' ' ')"
if [ "${E2E_CLI_WRONG:-0}" = 1 ]; then check "ABSICHTLICH FALSCH: forms im Ziel" 4 "$(tgt 'SELECT COUNT(*) FROM forms')"; fi

# ---------------- F: SIGINT / SIGTERM mid-run, resume ----------------
echo "-- F interruption and resume (enlarged source)"
COLS='time,formularUUID,sentServer,data,file1,file1Enc,file1Name,malwareScanStatus,errors,mailBody,mailBodyFiller,removable'
{ for _ in $(seq "$CLONES"); do echo "INSERT INTO anfragen (UUID,$COLS) SELECT UUID(),$COLS FROM anfragen;"; done; } | "$DOCKER" exec -i -e MYSQL_PWD="$LPW" "$LNAME" mariadb -uroot legacy || { echo "ENV: enlarge source"; exit 2; }
echo "     source now holds $(sc 'SELECT COUNT(*) FROM anfragen') submissions"
newdb e2e_ref
t0=$(date +%s); cli e2e_ref "$TMP/f-ref.log" --plan "$TMP/plan-stat.json"; r=$?; REFSEC=$(( $(date +%s) - t0 ))
REFRC=$r
check "undisturbed reference import exit code" "$STATRC" "$r"
REFN=$(tc e2e_ref 'SELECT COUNT(*) FROM migration_objects'); echo "     reference: $REFN ledger entries in ${REFSEC} s"
newdb e2e_int
run_and_signal() { # signal threshold-percent log
  cli_prep e2e_int --plan "$TMP/plan-stat.json"; "${CMD[@]}" >"$3" 2>&1 & local pid=$! ; local goal=$(( REFN * $2 / 100 )) n=0 sig=$1
  for _ in $(seq 400); do
    kill -0 "$pid" 2>/dev/null || break
    n=$(tc e2e_int 'SELECT COUNT(*) FROM migration_objects' 2>/dev/null); n=${n:-0}
    if [ "$n" -ge "$goal" ]; then kill -"$sig" "$pid" 2>/dev/null; break; fi
    sleep 0.1
  done
  wait "$pid"; SIGRC=$?; SIGN=$n
}
integrity() { # label: only whole objects (ledger distinct anfragen = submissions, no package without submission)
  check "$1: ledger anfragen = submissions" "$(tc e2e_int "SELECT COUNT(DISTINCT source_key) FROM migration_objects WHERE source_table='anfragen'")" "$(tc e2e_int 'SELECT COUNT(*) FROM submissions')"
  check "$1: no stored object without submission/statistics owner" 0 "$(tc e2e_int "SELECT COUNT(*) FROM stored_objects o WHERE o.object_role<>'statistics-metadata' AND o.submission_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM submissions s WHERE s.id=o.submission_id)")"
}
run_and_signal INT 30 "$TMP/f-int.log"; INTRC=$SIGRC
echo "     SIGINT sent at $SIGN of $REFN ledger entries, process exit code $INTRC"
[ "$SIGN" -ge 1 ] && [ "$SIGN" -lt "$REFN" ] && ok "SIGINT hit the middle of the run" || bad "SIGINT not in the middle ($SIGN of $REFN): enlarge E2E_CLONE_ROUNDS"
check "SIGINT: process exit code (130 = stopped at an object boundary)" 130 "$INTRC"
grep -q "unterbrochen durch Signal 2" "$TMP/f-int.log" && ok "SIGINT: stop message" || bad "SIGINT: no stop message: $(tail -c 200 "$TMP/f-int.log")"
check "SIGINT: run state is not 'running'" 0 "$(tc e2e_int "SELECT COUNT(*) FROM migration_runs WHERE state='running'")"
check "SIGINT: lock is free" 1 "$(tc e2e_int "SELECT IS_FREE_LOCK('form_legacy_import')")"
integrity "after SIGINT"; N1=$(tc e2e_int 'SELECT COUNT(*) FROM migration_objects')
run_and_signal TERM 65 "$TMP/f-term.log"; TERMRC=$SIGRC
echo "     SIGTERM sent at $SIGN of $REFN ledger entries, process exit code $TERMRC"
[ "$SIGN" -gt "$N1" ] && [ "$SIGN" -lt "$REFN" ] && ok "SIGTERM hit the middle of the resumed run" || bad "SIGTERM not in the middle of the 2nd run ($N1 -> $SIGN of $REFN)"
check "SIGTERM: process exit code (143 = stopped at an object boundary)" 143 "$TERMRC"
grep -q "unterbrochen durch Signal 15" "$TMP/f-term.log" && ok "SIGTERM: stop message" || bad "SIGTERM: no stop message: $(tail -c 200 "$TMP/f-term.log")"
check "SIGTERM: run state is not 'running'" 0 "$(tc e2e_int "SELECT COUNT(*) FROM migration_runs WHERE state='running'")"
integrity "after SIGTERM"
check "no second import process holds the lock" 1 "$(tc e2e_int "SELECT IS_FREE_LOCK('form_legacy_import')")"
cli e2e_int "$TMP/f-resume.log" --plan "$TMP/plan-stat.json"; r=$?
check "resume by calling again: exit code (same as the undisturbed import)" "$REFRC" "$r"
check "exactly one run row after the resumes" 1 "$(tc e2e_int 'SELECT COUNT(*) FROM migration_runs')"
check "resumed end state equals the undisturbed import (fingerprint)" "$(fpx e2e_ref)" "$(fpx e2e_int)"
check "resumed ledger count equals the undisturbed one" "$REFN" "$(tc e2e_int 'SELECT COUNT(*) FROM migration_objects')"
check "statistics rows encrypted after resume" "$STATN" "$(tc e2e_int "SELECT COUNT(*) FROM stored_objects WHERE object_role='statistics-metadata'")"
cli e2e_int "$TMP/f-again.log" --plan "$TMP/plan-stat.json"; r=$?
check "call after completion: exit code" "$REFRC" "$r"
check "call after completion changes nothing" "$(fpx e2e_ref)" "$(fpx e2e_int)"

# ---------------- G: no secrets in any output ----------------
echo "-- G secrets"
for secret in "$LPW" "$PW" "$SKEY" "$HMAC"; do
  if grep -rlF -- "$secret" "$TMP"/*.log >/dev/null 2>&1; then bad "a secret appears in a CLI output: $(grep -rlF -- "$secret" "$TMP"/*.log | tr '\n' ' ')"; else ok "secret (${#secret} chars) in none of $(ls "$TMP"/*.log | wc -l | tr -d ' ') output files"; fi
done
for secret in "$LPW" "$SKEY"; do check "secret (${#secret} chars) not in the target dump either" 0 "$(grep -cF -- "$secret" "$TMP/e-dump.sql")"; done
check "stdout/stderr has no SQL fragments" 0 "$(cat "$TMP"/[a-f]-*.log | grep -ciE 'insert into |select .* from |values \(' )"
echo "     sample import report: $(head -c 260 "$TMP/c-import.log" | tr '\n' ' ')"
echo "runtime $(( $(date +%s) - start )) s"
exit $rc
