#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Umstieg source check over REAL TLS, in the browser (real binary + real target MariaDB + real legacy MariaDB WITH TLS from a throw-away CA +
# Chromium with a CDP virtual authenticator, NO mocks). Scenarios (spec pwa/e2e-real/real-migration-tls.spec.ts): tls=verify with a trusted
# certificate, wrong host name, unknown CA, expired certificate, source without TLS (aborted before credentials), tls=disable, then an import.
# How the product trusts a CA: tls=verify uses the SYSTEM trust store only (mysql-nio default client configuration; no CA field in the UI/API).
# swift-nio-ssl trusts on Linux only the fixed bundle /etc/ssl/certs/ca-certificates.crt (+ directory /etc/ssl/certs, no SSL_CERT_FILE) and on macOS the
# Keychain. So the throw-away CA reaches the app as an operator would do it: macOS/local default APP_MODE=docker runs the local image
# (IMAGE=form-backend:latest, scripts/docker-build.sh) with the CA mounted as its system bundle; Linux CI (APP_MODE=host, native debug binary) installs
# the CA into the runner's system store (E2E_INSTALL_CA=1 required, uses sudo, removed again on exit). Exit 0 ok, 1 failed, 2 environment.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$HERE" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
FIX=backend/Tests/FormMigrationTests/Fixtures
TNAME=$(e2e_name p4t-target); SNAME=$(e2e_name p4t-src-tls); PNAME=$(e2e_name p4t-src-plain); ANAME=$(e2e_name p4t-app); NET=$(e2e_name p4t-net)
TPORT=${P3B_PORT:-$(e2e_pick_port)}; SPORT=${TLS_SRC_PORT:-$(e2e_pick_port)}; PPORT=${PLAIN_SRC_PORT:-$(e2e_pick_port)}; WPORT=${E2E_PORT:-$(e2e_pick_port)}
APP_MODE=${APP_MODE:-$([ "$(uname)" = Darwin ] && echo docker || echo host)}; IMAGE=${IMAGE:-form-backend:latest}
MARIA=${MARIADB_IMAGE:-mariadb:lts}
PW=$(openssl rand -hex 16); LPW=$(openssl rand -hex 16); SKEY=$(openssl rand -hex 32); PASSWORD=$(openssl rand -hex 12)
# Docker must see the dir (macOS Docker shares $HOME, not always /tmp); see scripts/test-backup-crypto.sh.
mkdir -p "${E2E_TMP_BASE:=$HOME/.cache}"; TMP=$(mktemp -d "$E2E_TMP_BASE/fbtls.XXXXXX"); APP_PID=""
savelogs() { [ -n "${E2E_LOG_DIR:-}" ] || return 0; mkdir -p "$E2E_LOG_DIR"; for l in "$TMP"/*.log; do [ -f "$l" ] && cp "$l" "$E2E_LOG_DIR/$(basename "$0" .sh)-$(basename "$l")"; done; return 0; }
cleanup() { [ -f /usr/local/share/ca-certificates/p4t-e2e-ca.crt ] && { sudo rm -f /usr/local/share/ca-certificates/p4t-e2e-ca.crt; sudo update-ca-certificates --fresh >/dev/null 2>&1; }; savelogs; [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; e2e_cleanup; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
e2e_reap_stale
[ "$APP_MODE" = host ] && [ "$(uname)" = Darwin ] && { echo "ENV: APP_MODE=host on macOS cannot trust a private CA (Keychain); use APP_MODE=docker"; exit 2; }
[ "$APP_MODE" = host ] && [ "${E2E_INSTALL_CA:-0}" != 1 ] && { echo "ENV: APP_MODE=host installs a throw-away CA into the system trust store (sudo); set E2E_INSTALL_CA=1 on a disposable runner"; exit 2; }
if [ "$APP_MODE" = docker ]; then "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 || { echo "ENV: image $IMAGE missing (scripts/docker-build.sh)"; exit 2; }; fi

"$DOCKER" network create "${E2E_LABEL_ARGS[@]}" "$NET" >/dev/null || { echo "ENV: network"; exit 2; }
SUBNET=$("$DOCKER" network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$NET")
IFS=. read -r n1 n2 n3 n4 <<<"${SUBNET%/*}"; SRC_IP=$n1.$n2.$n3.$((n4+50))  # fixed address of the TLS source: the certificate carries it as an IP SAN
# --- throw-away CAs and server certificates (the server key never leaves $TMP and is never printed) ---
umask 077; mkdir -p "$TMP/ssl" "$TMP/ca"; chmod 755 "$TMP" "$TMP/ssl"
cd "$TMP/ca" || exit 1
for ca in good other; do
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$ca.key" -out "$ca.pem" -subj "/CN=E2E Test CA $ca" -days 2 -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1 || { echo "ENV: openssl ca"; exit 2; }
  : > "$ca.idx"; echo 1000 > "$ca.srl"
  printf '[ca]\ndefault_ca=c\n[c]\ndatabase=%s.idx\nserial=%s.srl\nnew_certs_dir=.\ndefault_md=sha256\npolicy=p\nunique_subject=no\n[p]\ncommonName=supplied\n' "$ca" "$ca" > "$ca.cnf"
done
openssl req -newkey rsa:2048 -nodes -keyout "$TMP/ssl/server.key" -out server.csr -subj "/CN=$SNAME" >/dev/null 2>&1 || { echo "ENV: openssl key"; exit 2; }
printf 'subjectAltName=DNS:localhost,DNS:%s,IP:127.0.0.1,IP:%s\n' "$SNAME" "$SRC_IP" > ext.ok; printf 'subjectAltName=DNS:other.invalid\n' > ext.wrong
sign() { # name ca ext start end
  openssl ca -batch -config "$2.cnf" -cert "$2.pem" -keyfile "$2.key" -in server.csr -out "$TMP/ssl/$1.pem" -extfile "$3" -startdate "$4" -enddate "$5" -notext >/dev/null 2>&1 || { echo "ENV: sign $1"; exit 2; }
}
now=$(date -u -d '1 hour ago' +%Y%m%d%H%M%SZ 2>/dev/null || date -u -v-1H +%Y%m%d%H%M%SZ); later=$(date -u -d '1 day' +%Y%m%d%H%M%SZ 2>/dev/null || date -u -v+1d +%Y%m%d%H%M%SZ)
sign good good ext.ok "$now" "$later"; sign wronghost good ext.wrong "$now" "$later"; sign unknownca other ext.ok "$now" "$later"
sign expired good ext.ok 20240101000000Z 20240102000000Z
cp "$TMP/ssl/good.pem" "$TMP/ssl/server.pem"; cp good.pem "$TMP/ssl/ca.pem"; chmod 644 "$TMP/ssl"/*.pem "$TMP/ssl/server.key"
cd "$HERE" || exit 1
echo "ok   throw-away CA and certificates (good, wrong host name, unknown CA, expired)"

# --- containers ---
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --network "$NET" --name "$TNAME" -p "127.0.0.1:$TPORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "$MARIA" >/dev/null || { echo "ENV: target container"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --network "$NET" --ip "$SRC_IP" --name "$SNAME" -p "127.0.0.1:$SPORT:3306" -v "$TMP/ssl:/ssl:ro" -e MARIADB_ROOT_PASSWORD="$LPW" -e MARIADB_DATABASE=legacy \
  "$MARIA" --ssl-ca=/ssl/ca.pem --ssl-cert=/ssl/server.pem --ssl-key=/ssl/server.key >/dev/null || { echo "ENV: TLS source container"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --network "$NET" --name "$PNAME" -p "127.0.0.1:$PPORT:3306" -e MARIADB_ROOT_PASSWORD="$LPW" -e MARIADB_DATABASE=legacy \
  "$MARIA" --ssl=0 --general-log=1 --log-output=TABLE >/dev/null || { echo "ENV: plain source container"; exit 2; }
waitdb() { for _ in $(seq 90); do "$DOCKER" exec -e MYSQL_PWD="$2" "$1" mariadb --skip-ssl -uroot -e 'select 1' "$3" >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$2" "$1" mariadb --skip-ssl -uroot -e 'select 1' "$3" >/dev/null 2>&1 && return 0; sleep 1; done; echo "ENV: $1 not ready"; exit 2; }
waitdb "$TNAME" "$PW" e2e; waitdb "$SNAME" "$LPW" legacy; waitdb "$PNAME" "$LPW" legacy
for c in "$SNAME" "$PNAME"; do
  { echo "SET FOREIGN_KEY_CHECKS=0;"; cat "$FIX/legacy-real.sql" "$FIX/legacy-synthetic.sql"; } | "$DOCKER" exec -i -e MYSQL_PWD="$LPW" "$c" mariadb --skip-ssl -uroot legacy >"$TMP/legacy-load-$c.log" 2>&1 || { tail -3 "$TMP/legacy-load-$c.log"; echo "ENV: synthetic dump import failed"; exit 2; }
  "$DOCKER" exec -e MYSQL_PWD="$LPW" "$c" mariadb --skip-ssl -uroot -e "CREATE USER 'migro'@'%' IDENTIFIED BY '$LPW'; GRANT SELECT ON legacy.* TO 'migro'@'%'; FLUSH PRIVILEGES" || { echo "ENV: legacy user"; exit 2; }
done
[ "$("$DOCKER" exec -e MYSQL_PWD="$LPW" "$SNAME" mariadb --skip-ssl -uroot -N -e "SHOW VARIABLES LIKE 'have_ssl'" | cut -f2)" = YES ] || { echo "ENV: TLS source has no TLS"; exit 2; }
[ "$("$DOCKER" exec -e MYSQL_PWD="$LPW" "$PNAME" mariadb --skip-ssl -uroot -N -e "SHOW VARIABLES LIKE 'have_ssl'" | cut -f2)" = YES ] && { echo "ENV: plain source offers TLS"; exit 2; }
echo "ok   sources up: one with TLS (throw-away CA), one without TLS (general log in a table); read-only user"

# --- app ---
export E2E_LEGACY_USER=migro E2E_LEGACY_PASSWORD=$LPW E2E_LEGACY_DB=legacy E2E_CERT_DIR="$TMP/ssl"
export E2E_DB_CONTAINER="$TNAME" E2E_DB_PASSWORD="$PW" E2E_LEGACY_CONTAINER="$SNAME" E2E_LEGACY_ROOT_PASSWORD="$LPW" E2E_PLAIN_CONTAINER="$PNAME" E2E_PLAIN_ROOT_PASSWORD="$LPW"
{ printf 'FORM_DB_PASSWORD=%s\nFORM_SERVER_KEY=%s\nFORM_DB_USER=root\nFORM_DB_NAME=e2e\nFORM_DB_TLS=disable\nFORM_ALLOW_INSECURE_DEV=1\n' "$PW" "$SKEY"
  printf 'FORM_ADMIN_ORIGIN=http://localhost:%s\nFORM_RP_ID=localhost\n' "$WPORT"; } > "$TMP/app.env"
if [ "$APP_MODE" = docker ]; then
  export E2E_SRC_HOST=$SNAME E2E_SRC_PORT=3306 E2E_PLAIN_HOST=$PNAME E2E_PLAIN_PORT=3306
  # TLS_SRC_BY_IP=1: the IP SAN of the certificate is checked instead of the DNS name
  [ "${TLS_SRC_BY_IP:-0}" = 1 ] && export E2E_SRC_HOST=$SRC_IP
  printf 'FORM_DB_HOST=%s\nFORM_PUBLIC_PORT=8080\nFORM_INTERNAL_PORT=8081\nFORM_MIGRATION_ALLOWED_NETS=%s\n' "$TNAME" "$SUBNET" >> "$TMP/app.env"
  "$DOCKER" run --rm "${E2E_LABEL_ARGS[@]}" --network "$NET" --env-file "$TMP/app.env" "$IMAGE" migrate >"$TMP/migrate.log" 2>&1 || { echo "FAIL migrate"; tail -3 "$TMP/migrate.log"; exit 1; }
  OUT=$("$DOCKER" run --rm "${E2E_LABEL_ARGS[@]}" --network "$NET" --env-file "$TMP/app.env" -e FORM_BOOTSTRAP_PASSWORD="$PASSWORD" "$IMAGE" bootstrap-admin admin 2>&1) || { echo "FAIL bootstrap-admin"; echo "$OUT" | head -3; exit 1; }
else
  export E2E_SRC_HOST=127.0.0.1 E2E_SRC_PORT=$SPORT E2E_PLAIN_HOST=127.0.0.1 E2E_PLAIN_PORT=$PPORT
  export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
  swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >/dev/null 2>&1 || { sleep 2; swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App >/dev/null 2>&1; } || { echo "ENV: build"; exit 2; }
  e2e_pwa_build "$TMP/dist" || { echo "ENV: pwa build"; exit 2; }
  BIN=backend/.build/debug/App
  set -a; . "$TMP/app.env"; set +a
  export FORM_DB_HOST=127.0.0.1 FORM_DB_PORT=$TPORT FORM_INTERNAL_PORT=$WPORT FORM_PUBLIC_PORT=$((WPORT+100)) FORM_SCHEMA_FILE=backend/db/schema-p3.sql FORM_PUBLIC_DIR="$TMP/dist"
  export FORM_MIGRATION_ALLOWED_NETS=127.0.0.0/8
  sudo cp "$TMP/ssl/ca.pem" /usr/local/share/ca-certificates/p4t-e2e-ca.crt && sudo update-ca-certificates >/dev/null 2>&1 || { echo "ENV: could not install the CA"; exit 2; }
  printf '%s' "$SKEY" > "$TMP/server.key"; unset FORM_SERVER_KEY; export FORM_SERVER_KEY_FILE="$TMP/server.key"
  printf '%s' "$PASSWORD" > "$TMP/bootpw"
  "$BIN" migrate >/dev/null 2>&1 || { echo "FAIL migrate"; exit 1; }
  OUT=$(FORM_BOOTSTRAP_PASSWORD_FILE="$TMP/bootpw" "$BIN" bootstrap-admin admin 2>&1) || { echo "FAIL bootstrap-admin"; echo "$OUT" | head -3; exit 1; }
fi
LINK=$(printf '%s\n' "$OUT" | sed -n 's/.*): \(http[^ ]*\)$/\1/p' | head -1)
[ -n "$LINK" ] || { echo "FAIL no link in output"; exit 1; }
echo "ok   bootstrap-admin printed an enrollment link (not shown); app mode: $APP_MODE"
if [ "$APP_MODE" = docker ]; then
  "$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --name "$ANAME" --network "$NET" --env-file "$TMP/app.env" -v "$TMP/ssl/ca.pem:/etc/ssl/certs/ca-certificates.crt:ro" -p "127.0.0.1:$WPORT:8081" "$IMAGE" serve >/dev/null || { echo "ENV: app container"; exit 2; }
else
  "$BIN" serve >"$TMP/app.log" 2>&1 & APP_PID=$!
fi
for _ in $(seq 40); do curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 || { echo "FAIL app not healthy"; [ "$APP_MODE" = docker ] && "$DOCKER" logs "$ANAME" 2>&1 | tail -5 | cut -c1-200; exit 1; }
export E2E_SETUP_LINK="$LINK" E2E_PASSWORD="$PASSWORD" E2E_PORT=$WPORT E2E_SPEC=real-migration-tls.spec.ts
(cd pwa && npx playwright test -c e2e-real/playwright.config.ts) >"$TMP/playwright.log" 2>&1; rc=$?  # own status: a pipe into tail would hide a failed run
tail -60 "$TMP/playwright.log"
[ "$APP_MODE" = docker ] && "$DOCKER" logs "$ANAME" >"$TMP/app.log" 2>&1
TOKEN=${LINK##*#}
for secret in "$TOKEN" "$PASSWORD" "$LPW" "$PW" "$SKEY"; do grep -q "$secret" "$TMP/app.log" && { echo "FAIL a secret was found in the app log"; rc=1; }; done
[ "$rc" = 0 ] && echo "ok   enrollment token, bootstrap password, source/target passwords and server key not in app log"
grep -h "migration source" "$TMP/app.log" | cut -c1-200 | sort | uniq -c | head -5
N=$("$DOCKER" exec -e MYSQL_PWD="$PW" "$TNAME" mariadb --skip-ssl -uroot -N e2e -e 'SELECT COUNT(*) FROM passkeys' 2>/dev/null)
[ "$N" = 1 ] && echo "ok   exactly one passkey stored" || { echo "FAIL passkeys=$N"; rc=1; }
exit $rc
