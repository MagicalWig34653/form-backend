#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Real end-to-end Betrieb (ops) view: Chromium (CDP virtual authenticator) -> App binary (serves the PWA) -> Docker MariaDB.
# Seeds account, passkey and password like e2e-login.sh, plus a customer, a form, an audit.read grant and two real mail deliveries
# whose inserts fire the ops triggers: one accepted, then one failed (an open alarm). The failed one is stamped ahead of the
# app clock (database clock drift).
# E2E_OPS_WRONG=1 expects a wrong count (proof that a failing check ends with rc!=0).
# Exit 0 = ok, 1 = check failed, 2 = environment problem.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
IMAGE=${MARIADB_IMAGE:-mariadb:lts}; NAME=$(e2e_name p4a-ops-mariadb); PORT=${P3B_PORT:-$(e2e_pick_port)}; WPORT=${E2E_PORT:-$(e2e_pick_port)}; BPORT=$WPORT
PW=$(openssl rand -hex 16); TMP=$(mktemp -d); APP_PID=""
savelogs() { [ -n "${E2E_LOG_DIR:-}" ] || return 0; mkdir -p "$E2E_LOG_DIR"; for l in "$TMP"/*.log; do [ -f "$l" ] && cp "$l" "$E2E_LOG_DIR/$(basename "$0" .sh)-$(basename "$l")"; done; return 0; }  # CI: keep logs as artifact
cleanup() { savelogs; [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; e2e_cleanup; rm -rf "$TMP"; echo "cleanup done"; }
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
swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >>"$TMP/build.log" 2>&1 || { sleep 2; swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >>"$TMP/build.log" 2>&1; } || { echo "ENV: build failed"; exit 2; }  # retry: the Swift frontend crashes sporadically
e2e_pwa_build "$TMP/dist" || { echo "ENV: pwa build failed"; exit 2; }
BIN=backend/.build/debug/App
export FORM_DB_PORT=$PORT FORM_DB_USER=root FORM_DB_PASSWORD=$PW FORM_DB_NAME=e2e FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1
export FORM_INTERNAL_PORT=$BPORT FORM_INTERNAL_SECOND_FACTOR=1 FORM_SCHEMA_FILE=backend/db/schema-p3.sql FORM_PUBLIC_DIR="$TMP/dist"
export FORM_SERVER_KEY_FILE="$TMP/server.key" FORM_ADMIN_ORIGIN=http://localhost:$WPORT FORM_RP_ID=localhost
"$BIN" migrate >/dev/null 2>&1 || { echo "FAIL migrate"; exit 1; }

# --- synthetic credential material (never leaves $TMP / the environment) ---
ACCOUNT=$(python3 -c 'import uuid;print(uuid.uuid4())')
PASSWORD=$(openssl rand -hex 12)
# Argon2id (contract target) from PHP; set E2E_HASH_ALGO=bcrypt to exercise the legacy path instead.
if [ "${E2E_HASH_ALGO:-argon2id}" = bcrypt ]; then
  HASH=$(PASSWORD="$PASSWORD" php -r 'echo password_hash(getenv("PASSWORD"), PASSWORD_BCRYPT, ["cost"=>10]);')
else
  HASH=$(PASSWORD="$PASSWORD" php -r 'echo password_hash(getenv("PASSWORD"), PASSWORD_ARGON2ID, ["memory_cost"=>19456,"time_cost"=>2,"threads"=>1]);')
fi
openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkcs8 -topk8 -nocrypt -outform DER -out "$TMP/priv.der" 2>/dev/null
openssl pkey -inform DER -in "$TMP/priv.der" -pubout -out "$TMP/pub.pem" 2>/dev/null
CRED_ID_HEX=$(openssl rand -hex 32)
export E2E_PRIVATE_KEY_B64=$(base64 < "$TMP/priv.der" | tr -d '\n')
export E2E_CREDENTIAL_ID_B64=$(printf '%s' "$CRED_ID_HEX" | xxd -r -p | base64 | tr -d '\n')
export E2E_USER_HANDLE_B64=$(printf '%s' "$ACCOUNT" | base64 | tr -d '\n')
export E2E_RP_ID=localhost E2E_PASSWORD=$PASSWORD E2E_PORT=$WPORT
PUBPEM=$(cat "$TMP/pub.pem")
"$DOCKER" exec -i -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot e2e <<SQL || { echo "FAIL seed"; exit 1; }
INSERT INTO accounts (id, username, password_hash, active, mcp_allowed, rights_version, created_at)
VALUES (UNHEX(REPLACE('$ACCOUNT','-','')), 'e2e-user', '$HASH', 1, 0, 1, '2026-10-31 00:00:00.000000');
INSERT INTO passkeys (credential_id, account_id, user_handle, public_key_bytes, public_key_encoding, cose_algorithm, sign_count, label, rp_id, created_at)
VALUES (UNHEX('$CRED_ID_HEX'), UNHEX(REPLACE('$ACCOUNT','-','')), '$ACCOUNT', '$PUBPEM', 'pem-spki', -7, 0, 'e2e', 'localhost', '2026-10-31 00:00:00.000000');
SQL

CUSTOMER=$(python3 -c 'import uuid;print(uuid.uuid4().hex)'); FORM=$(python3 -c 'import uuid;print(uuid.uuid4().hex)')
SUB=$(python3 -c 'import uuid;print(uuid.uuid4().hex)'); DELIVERY=$(python3 -c 'import uuid;print(uuid.uuid4().hex)'); DELIVERY2=$(python3 -c 'import uuid;print(uuid.uuid4().hex)')
"$DOCKER" exec -i -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot e2e <<SQL || { echo "FAIL seed ops"; exit 1; }
INSERT INTO customers (id,name,state,created_at) VALUES (UNHEX('$CUSTOMER'),'Synthetik Betrieb','active',UTC_TIMESTAMP(6));
INSERT INTO forms (id,customer_id,name,active,created_at) VALUES (UNHEX('$FORM'),UNHEX('$CUSTOMER'),'Betriebsformular',0,UTC_TIMESTAMP(6));
INSERT INTO permission_assignments (id,account_id,permission,scope_kind,customer_id,form_id,revision,granted_by,granted_at)
VALUES (UNHEX(REPLACE(UUID(),'-','')),UNHEX(REPLACE('$ACCOUNT','-','')),'audit.read','customer',UNHEX('$CUSTOMER'),UNHEX('$FORM'),1,UNHEX(REPLACE('$ACCOUNT','-','')),UTC_TIMESTAMP(6));
INSERT INTO submissions (id,customer_id,form_id,release_evidence,environment,state,removable,malware_scan_status)
VALUES (UNHEX('$SUB'),UNHEX('$CUSTOMER'),UNHEX('$FORM'),'legacy-unknown','production','accepted',1,'none');
INSERT INTO mail_deliveries (id,customer_id,form_id,submission_id,environment,mail_kind,identity_scope,transport_kind,state,attempts,created_at,updated_at)
VALUES (UNHEX('$DELIVERY'),UNHEX('$CUSTOMER'),UNHEX('$FORM'),UNHEX('$SUB'),'production','organisation','form-mail','smtp','smtp-accepted',1,UTC_TIMESTAMP(6),UTC_TIMESTAMP(6));
INSERT INTO mail_deliveries (id,customer_id,form_id,submission_id,environment,mail_kind,identity_scope,transport_kind,state,attempts,created_at,updated_at)
VALUES (UNHEX('$DELIVERY2'),UNHEX('$CUSTOMER'),UNHEX('$FORM'),UNHEX('$SUB'),'production','confirmation','form-mail','smtp','waiting-manual',3,UTC_TIMESTAMP(6),UTC_TIMESTAMP(6));
SQL
N=$("$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -N e2e -e "SELECT COUNT(*) FROM ops_events WHERE form_id=UNHEX('$FORM')" 2>/dev/null)
[ "$N" = 2 ] && echo "ok   triggers wrote 2 ops events" || { echo "FAIL ops events=$N (expected 2 from the triggers)"; exit 1; }
"$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot e2e -e "UPDATE ops_events SET occurred_at=UTC_TIMESTAMP(6) + INTERVAL 10 MINUTE WHERE form_id=UNHEX('$FORM') AND event='failed'" || { echo "FAIL drift"; exit 1; }
echo "ok   newest event stamped 10 minutes ahead of the app clock (database clock drift)"
export E2E_SPEC=real-ops.spec.ts E2E_OPS_FORM_NAME=Betriebsformular
"$BIN" serve >"$TMP/app.log" 2>&1 & APP_PID=$!
for _ in $(seq 30); do curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 && break; sleep 1; done
(cd pwa && npx playwright test -c e2e-real/playwright.config.ts) >"$TMP/playwright.log" 2>&1; rc=$?  # own status: a pipe into tail would hide a failed run
tail -25 "$TMP/playwright.log"
grep -q "$PASSWORD" "$TMP/app.log" && { echo "FAIL password found in app log"; rc=1; } || echo "ok   password not in app log"
grep -q "$(cat "$TMP/server.key")" "$TMP/app.log" && { echo "FAIL key found in app log"; rc=1; }
exit $rc
