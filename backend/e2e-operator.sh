#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Operator path end to end with the PUBLISHED image (no local build): what an operator does after the documentation
# (README, docs/BETRIEB.md, docs/UMSTIEG-CHECKLISTE.md, deploy/compose/*), from an EMPTY instance through the Umstieg into production use.
#   IMAGE=<ref|digest>  default ghcr.io/magicalwig34653/form-backend:latest (pulled, pinned to its digest)
#   DUMP=synthetic|real synthetic: repository dump (legacy-real.sql + legacy-synthetic.sql, old keys known) -> full chain;
#                       real: REAL_DUMP=<file> (never in the repo, never printed) -> source check, mapping, dry run, import, report, counts
#   RUNS=n              n runs, each from an empty instance; log per run in $HOME/.cache/operator-runs/<ts>/run-N.log (step, duration, result)
#   OLD_IMAGE=<ref>     optional: the instance is first installed with OLD_IMAGE and updated to IMAGE after the import (image update step)
#   CLONES=n            optional: doubles the synthetic submissions n times (large source)
# Instance like the compose operation: deploy/compose/compose.yaml (entrypoint wrapper, uid 10001, file secrets, 512 MB limit) with a per-run
# override (labels, trust bundle), external MariaDB WITH TLS (FORM_DB_TLS=verify), TLS reverse proxy (nginx) for the admin origin (https) and
# the public listener, NO FORM_ALLOW_INSECURE_DEV. The legacy source is its own MariaDB with TLS from a throw-away CA; the CA reaches the app
# as part of its system trust bundle (mounted), the way docs/UMSTIEG-CHECKLISTE.md No. 6 requires. Mailpit offers STARTTLS with a
# self-signed certificate (per-connection option, ADR 0044).
# Exit 0 all runs green, 1 a run failed, 2 environment problem.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
ROOT=$PWD
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
IMAGE=${IMAGE:-ghcr.io/magicalwig34653/form-backend:latest}; DUMP=${DUMP:-synthetic}; RUNS=${RUNS:-1}
MARIA=${MARIADB_IMAGE:-mariadb:lts}; MAILPIT=${MAILPIT_IMAGE:-axllent/mailpit:latest}; NGINX=${NGINX_IMAGE:-nginx:alpine}

# ---------------------------------------------------------------- driver: n runs, one log each
if [ "${1:-}" != --one ]; then
  case $DUMP in synthetic) ;; real) [ -r "${REAL_DUMP:-}" ] || { echo "ENV: DUMP=real needs REAL_DUMP=<file>"; exit 2; } ;; *) echo "ENV: DUMP=synthetic|real"; exit 2 ;; esac
  "$DOCKER" info >/dev/null 2>&1 || { echo "ENV: docker daemon not reachable"; exit 2; }
  OUT=${OPERATOR_OUT:-$HOME/.cache/operator-runs/$(date +%Y%m%d-%H%M%S)}; mkdir -p "$OUT"
  for img in "$IMAGE" ${OLD_IMAGE:+"$OLD_IMAGE"}; do
    # PULL=0 only for developing the harness against a locally built image; the acceptance runs always pull
    if [ "${PULL:-1}" = 1 ]; then "$DOCKER" pull -q "$img" >/dev/null || { echo "ENV: pull $img"; exit 2; }; fi
  done
  green=0; rc=0
  for n in $(seq "$RUNS"); do
    t0=$(date +%s)
    bash "$0" --one "$n" > "$OUT/run-$n.log" 2>&1; r=$?
    d=$(( $(date +%s) - t0 ))
    if [ "$r" = 0 ]; then green=$((green + 1)); echo "run $n: ok (${d} s, streak $green)"; else green=0; rc=1; echo "run $n: FAIL rc=$r (${d} s), log $OUT/run-$n.log"; grep -E '^STEP .* (FAIL|ENV)' "$OUT/run-$n.log" | head -3; fi
  done
  echo "log dir: $OUT; green streak at the end: $green of $RUNS"
  exit $rc
fi

# ---------------------------------------------------------------- one run from an empty instance
RUN_NO=${2:-1}
. backend/e2e-common.sh
STACK=opr$(printf '%s' "$E2E_RUN_ID" | tr -cd 'a-z0-9' | cut -c1-12)
NET=$(e2e_name opr-net); TNAME=$(e2e_name opr-db); SNAME=$(e2e_name opr-legacy); MP=$(e2e_name opr-mailpit); PX=$(e2e_name opr-proxy)
BASE=$(e2e_pick_port) || exit 2; WPORT=$BASE; PPORT=$((BASE + 1)); MPAPI=$((BASE + 2))
mkdir -p "${E2E_TMP_BASE:=$HOME/.cache}"; TMP=$(mktemp -d "$E2E_TMP_BASE/opr.XXXXXX"); chmod 755 "$TMP"
T_RUN=$(date +%s)
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
# step NAME cmd... : runs, prints "STEP name ok|FAIL <s>" (the per-run protocol); a failing step ends the run
step() {
  local name=$1 t r; shift; t=$(date +%s)
  "$@"; r=$?
  if [ "$r" = 0 ]; then echo "STEP $name ok $(( $(date +%s) - t ))s"; return 0; fi
  echo "STEP $name FAIL $(( $(date +%s) - t ))s (rc=$r)"; exit 1
}
compose() { "$DOCKER" compose --project-directory "$ROOT/deploy/compose" --project-name "$STACK" --env-file "$TMP/compose.env" -f "$ROOT/deploy/compose/compose.yaml" -f "$TMP/override.yaml" "$@"; }
savelogs() { compose logs --no-color app > "$TMP/app.log" 2>&1; "$DOCKER" logs "$PX" > "$TMP/proxy.log" 2>&1; return 0; }
cleanup() {
  savelogs
  [ -n "${KEEP_LOGS:-}" ] && { mkdir -p "$KEEP_LOGS"; cp "$TMP"/*.log "$KEEP_LOGS/" 2>/dev/null; }
  compose down -v --remove-orphans >/dev/null 2>&1; e2e_cleanup; rm -rf "$TMP"; log "cleanup done (runtime $(( $(date +%s) - T_RUN )) s)"
}
trap cleanup EXIT
e2e_reap_stale
log "run $RUN_NO: image $IMAGE, dump $DUMP, run id $E2E_RUN_ID"

# ---- secrets and identities (values never printed; the log check at the end greps for them)
umask 077
mkdir -p "$TMP/secrets" "$TMP/ca"; chmod 755 "$TMP/secrets"
DBPW=$(openssl rand -hex 16); ROOTPW=$(openssl rand -hex 16); LROOT=$(openssl rand -hex 16)
# Source account with characters that need escaping in URLs and shells (UMSTIEG-CHECKLISTE No. 5: own SELECT-only user)
LUSER='umstieg-alt'; LPW="Pw:$(openssl rand -hex 6)/@#%&ä'\"x"; LDB='kubus_alt-2026'
printf '%s' "$DBPW" > "$TMP/secrets/db_password"; openssl rand -hex 32 | tr -d '\n' > "$TMP/secrets/server_key"; printf 'FORM_OPTIONAL_UNSET' > "$TMP/secrets/bootstrap_password"
chmod 400 "$TMP/secrets"/*   # like the compose setup: 0400 and owned by APP_UID (setup chowns as root; here the files already belong to APP_UID=$(id -u))

# ---- network and throw-away CA
mk_net() {
  local _
  for _ in 1 2 3 4 5 6; do
    "$DOCKER" network create "${E2E_LABEL_ARGS[@]}" --subnet "10.$((100 + RANDOM % 120)).$((RANDOM % 256)).0/24" "$NET" >/dev/null 2>&1 && break
  done
  SUBNET=$("$DOCKER" network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$NET" 2>/dev/null) && [ -n "$SUBNET" ]
}
mk_certs() {
  ( cd "$TMP/ca" || exit 1
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -subj "/CN=Operator E2E CA" -days 3 \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1 || exit 1
    for host in "$TNAME" "$SNAME" localhost; do
      openssl req -newkey rsa:2048 -nodes -keyout "$host.key" -out "$host.csr" -subj "/CN=$host" >/dev/null 2>&1 || exit 1
      printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n' "$host" > "$host.ext"
      openssl x509 -req -in "$host.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -sha256 -extfile "$host.ext" -out "$host.pem" >/dev/null 2>&1 || exit 1
      mkdir -p "$host.d"; cp "$host.pem" "$host.d/server.pem"; cp "$host.key" "$host.d/server.key"; cp ca.pem "$host.d/ca.pem"; chmod 755 "$host.d"; chmod 644 "$host.d"/*
    done )
  # trust bundle of the app = the image's system bundle + the throw-away CA (an operator adds a private CA to the system store)
  "$DOCKER" run --rm "${E2E_LABEL_ARGS[@]}" --entrypoint cat "$APP_IMAGE" /etc/ssl/certs/ca-certificates.crt > "$TMP/trust.pem" && cat "$TMP/ca/ca.pem" >> "$TMP/trust.pem" && chmod 644 "$TMP/trust.pem"
  SPKI=$(openssl x509 -in "$TMP/ca/localhost.pem" -pubkey -noout | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary | base64)
}
APP_IMAGE=${OLD_IMAGE:-$IMAGE}
pin() { local d; d=$("$DOCKER" image inspect "$1" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}') || return 1; [ -n "$d" ] && echo "$d" || echo "$1"; }
APP_IMAGE=$(pin "$APP_IMAGE") || { echo "ENV: image $APP_IMAGE not pulled"; exit 2; }
NEW_IMAGE=$(pin "$IMAGE") || exit 2
log "image ids: $("$DOCKER" image inspect "$APP_IMAGE" --format '{{.Id}} created {{.Created}}')"
log "app image digest: $APP_IMAGE${OLD_IMAGE:+ (update target $NEW_IMAGE)}"
step network mk_net
step certificates mk_certs

# ---- external databases (target: TLS, own DB and user like an operator's MariaDB; source: TLS, frozen dump, read-only user)
wait_db() { local _; for _ in $(seq 120); do "$DOCKER" exec -e MYSQL_PWD="$2" "$1" mariadb --skip-ssl -uroot -e 'select 1' >/dev/null 2>&1 && sleep 2 && return 0; sleep 1; done; return 1; }
start_target() {
  "$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --network "$NET" --name "$TNAME" -v "$TMP/ca/$TNAME.d:/ssl:ro" \
    -e MARIADB_ROOT_PASSWORD="$ROOTPW" "$MARIA" --ssl-ca=/ssl/ca.pem --ssl-cert=/ssl/server.pem --ssl-key=/ssl/server.key --max-allowed-packet=64M >/dev/null || return 1
  wait_db "$TNAME" "$ROOTPW" || return 1
  printf "CREATE DATABASE form CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE USER 'form'@'%%' IDENTIFIED BY '%s' REQUIRE SSL; GRANT ALL PRIVILEGES ON form.* TO 'form'@'%%'; FLUSH PRIVILEGES;" "$DBPW" \
    | "$DOCKER" exec -i -e MYSQL_PWD="$ROOTPW" "$TNAME" mariadb --skip-ssl -uroot
}
sqlesc() { printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"; }
start_source() {
  if [ "${SOURCE_ON_TARGET:-0}" = 1 ]; then
    # Source without own TLS (docs/MIGRATION-ANLEITUNG.md): the dump goes into its own schema on the target MariaDB, which already
    # offers TLS with a certificate the app trusts (FORM_DB_TLS=verify); the source account only reads that schema.
    SNAME=$TNAME; LROOT=$ROOTPW
  else
    "$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --network "$NET" --name "$SNAME" -v "$TMP/ca/$SNAME.d:/ssl:ro" \
      -e MARIADB_ROOT_PASSWORD="$LROOT" "$MARIA" --ssl-ca=/ssl/ca.pem --ssl-cert=/ssl/server.pem --ssl-key=/ssl/server.key --max-allowed-packet=64M >/dev/null || return 1
    wait_db "$SNAME" "$LROOT" || return 1
  fi
  printf 'CREATE DATABASE `%s` CHARACTER SET utf8mb4;' "$LDB" | "$DOCKER" exec -i -e MYSQL_PWD="$LROOT" "$SNAME" mariadb --skip-ssl -uroot || return 1
  if [ "$DUMP" = real ]; then
    "$DOCKER" exec -i -e MYSQL_PWD="$LROOT" "$SNAME" mariadb --skip-ssl -uroot "$LDB" < "$REAL_DUMP" > "$TMP/legacy-load.log" 2>&1 || return 1
  else
    { echo "SET FOREIGN_KEY_CHECKS=0;"; cat backend/Tests/FormMigrationTests/Fixtures/legacy-real.sql backend/Tests/FormMigrationTests/Fixtures/legacy-synthetic.sql; } \
      | "$DOCKER" exec -i -e MYSQL_PWD="$LROOT" "$SNAME" mariadb --skip-ssl -uroot "$LDB" > "$TMP/legacy-load.log" 2>&1 || return 1
    if [ "${CLONES:-0}" -gt 0 ]; then
      local cols='time,formularUUID,sentServer,data,file1,file1Enc,file1Name,malwareScanStatus,errors,mailBody,mailBodyFiller,removable'
      for _ in $(seq "$CLONES"); do echo "INSERT INTO anfragen (UUID,$cols) SELECT UUID(),$cols FROM anfragen;"; done | "$DOCKER" exec -i -e MYSQL_PWD="$LROOT" "$SNAME" mariadb --skip-ssl -uroot "$LDB" || return 1
    fi
  fi
  # The first legacy SMTP server points at this run's Mailpit (STARTTLS, self-signed: SMTPallowSelfSigned=1), so the imported connection itself
  # is activated and used after the cutover (finding C). Only host/port/security/flag change; user and password stay as in the dump.
  printf "UPDATE outgoingMailServer SET SMTPHost='%s', SMTPPort='1025', SMTPSecurity='tls', SMTPallowSelfSigned=1 ORDER BY ID LIMIT 1;" "$MP" \
    | "$DOCKER" exec -i -e MYSQL_PWD="$LROOT" "$SNAME" mariadb --skip-ssl -uroot "$LDB" || return 1
  printf "CREATE USER '%s'@'%%' IDENTIFIED BY '%s'; GRANT SELECT ON \`%s\`.* TO '%s'@'%%'; FLUSH PRIVILEGES;" "$LUSER" "$(sqlesc "$LPW")" "$LDB" "$LUSER" \
    | "$DOCKER" exec -i -e MYSQL_PWD="$LROOT" "$SNAME" mariadb --skip-ssl -uroot
}
start_mailpit() {
  "$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --network "$NET" --name "$MP" -p "127.0.0.1:$MPAPI:8025" -v "$ROOT/backend/Tests/TestSupport/Fixtures:/certs:ro" \
    -e MP_SMTP_TLS_CERT=/certs/test-cert.pem -e MP_SMTP_TLS_KEY=/certs/test-key.pem -e MP_SMTP_REQUIRE_STARTTLS=true -e MP_SMTP_AUTH_ACCEPT_ANY=true "$MAILPIT" >/dev/null || return 1
  local _; for _ in $(seq 60); do curl -fs "http://127.0.0.1:$MPAPI/api/v1/info" >/dev/null 2>&1 && return 0; sleep 1; done; return 1
}
step target-db start_target
step legacy-source start_source
step mailpit start_mailpit

# ---- the instance: deploy/compose/compose.yaml as rendered by the setup (no host ports), plus this run's override
write_compose_env() {
  # Same keys the compose setup writes (deploy/compose/.env); FORM_IMAGE pinned to the digest like setup/update do.
  cat > "$TMP/compose.env" <<EOF
STACK=$STACK
NETWORK_NAME=$NET
FORM_IMAGE=$1
FORM_DB_HOST=$TNAME
FORM_DB_PORT=3306
FORM_DB_USER=form
FORM_DB_NAME=form
FORM_DB_TLS=verify
FORM_ALLOW_INSECURE_DEV=0
FORM_ADMIN_ORIGIN=https://localhost:$WPORT
FORM_RP_ID=localhost
FORM_TRUSTED_PROXIES=$SUBNET
DB_PASSWORD_SOURCE_FILE=$TMP/secrets/db_password
SERVER_KEY_SOURCE_FILE=$TMP/secrets/server_key
BOOTSTRAP_PASSWORD_SOURCE_FILE=$TMP/secrets/bootstrap_password
APP_UID=$(id -u)
APP_GID=$(id -g)
FORM_MIGRATION_ALLOWED_NETS=$SUBNET
FORM_MAIL_ALLOWED_NETS=$SUBNET
EOF
  # Labels make every container of the run removable by e2e_cleanup; the trust bundle carries the throw-away CA.
  cat > "$TMP/override.yaml" <<EOF
services:
  migrate:
    labels: { e2e.run: "$E2E_RUN_ID", e2e.started: "$E2E_STARTED" }
    volumes: ["$TMP/trust.pem:/etc/ssl/certs/ca-certificates.crt:ro"]
  app:
    labels: { e2e.run: "$E2E_RUN_ID", e2e.started: "$E2E_STARTED" }
    volumes: ["$TMP/trust.pem:/etc/ssl/certs/ca-certificates.crt:ro"]
EOF
}
# Keys without a value in compose.yaml (FORM_MIGRATION_ALLOWED_NETS, FORM_MAIL_ALLOWED_NETS) are resolved from the env file
# (deploy/compose/settings.sh --set writes them there), checked with `docker compose config`.
write_compose_env "$APP_IMAGE"
start_proxy() {
  cat > "$TMP/nginx.conf" <<EOF
server {
  listen 8443 ssl; server_name localhost;
  ssl_certificate /tls/server.pem; ssl_certificate_key /tls/server.key;
  client_max_body_size 30m;
  location / { proxy_pass http://$STACK-internal:8081; proxy_set_header Host \$host:$WPORT; proxy_set_header X-Forwarded-Host \$host:$WPORT;
    proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-For \$remote_addr; proxy_set_header Forwarded ""; proxy_read_timeout 300s; }
}
server {
  listen 9443 ssl; server_name localhost;
  ssl_certificate /tls/server.pem; ssl_certificate_key /tls/server.key;
  client_max_body_size 30m;
  location / { proxy_pass http://$STACK-public:8080; proxy_set_header Host \$host; proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-For \$remote_addr; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header Forwarded ""; }
}
EOF
  chmod 644 "$TMP/nginx.conf"
  "$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --network "$NET" --name "$PX" -p "127.0.0.1:$WPORT:8443" -p "127.0.0.1:$PPORT:9443" \
    -v "$TMP/nginx.conf:/etc/nginx/conf.d/default.conf:ro" -v "$TMP/ca/localhost.d:/tls:ro" "$NGINX" >/dev/null
}
app_up() { compose up -d --wait --wait-timeout 180 app > "$TMP/up.log" 2>&1 || { tail -5 "$TMP/up.log"; compose logs --no-color --tail 20 app; return 1; }; }
ready() { local _; for _ in $(seq 60); do curl -fs --cacert "$TMP/ca/ca.pem" "https://localhost:$WPORT/ready" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
migrate_once() { compose run --rm --no-deps -T migrate > "$TMP/migrate-$1.log" 2>&1 || { tail -5 "$TMP/migrate-$1.log"; return 1; }; }
bootstrap() {
  # deploy/compose/admin.sh bootstrap-admin admin == compose run --rm --no-deps -T app bootstrap-admin admin
  compose run --rm --no-deps -T app bootstrap-admin admin > "$TMP/bootstrap.out" 2>&1 || { sed -n 1,3p "$TMP/bootstrap.out" | cut -c1-120; return 1; }
  LINK=$(sed -n 's/.*): \(http[^ ]*\)$/\1/p' "$TMP/bootstrap.out" | head -1); [ -n "$LINK" ]
}
step migrate migrate_once first
step migrate-idempotent migrate_once second
step bootstrap-admin bootstrap
step app-up app_up
step proxy start_proxy
step ready ready

# ---- control script for the spec (restart, image update, backup/restore, log check); state stays in this run's tmp dir
cat > "$TMP/ctl.sh" <<CTL
#!/usr/bin/env bash
# called by the spec: ctl.sh <action>; prints what it did, exit 0 ok
set -u
cd "$ROOT" || exit 1
compose() { "$DOCKER" compose --project-directory "$ROOT/deploy/compose" --project-name "$STACK" --env-file "$TMP/compose.env" -f "$ROOT/deploy/compose/compose.yaml" -f "$TMP/override.yaml" "\$@"; }
ready() { for _ in \$(seq 90); do curl -fs --cacert "$TMP/ca/ca.pem" "https://localhost:$WPORT/ready" >/dev/null 2>&1 && return 0; sleep 1; done; echo "not ready"; return 1; }
case "\$1" in
  restart) compose restart app >/dev/null 2>&1 && ready ;;
  recreate) compose up -d --wait --wait-timeout 180 --force-recreate app >/dev/null 2>&1 && ready ;;
  kill) "$DOCKER" kill -s KILL "\$(compose ps -q app)" >/dev/null && sleep 1 && compose up -d --wait --wait-timeout 180 app >/dev/null 2>&1 && ready ;;
  update)
    sed -i.bak "s|^FORM_IMAGE=.*|FORM_IMAGE=$NEW_IMAGE|" "$TMP/compose.env" && rm -f "$TMP/compose.env.bak"
    compose run --rm --no-deps -T migrate >"$TMP/migrate-update.log" 2>&1 || { tail -3 "$TMP/migrate-update.log"; exit 1; }
    compose up -d --wait --wait-timeout 180 app >/dev/null 2>&1 && ready && echo "updated to $NEW_IMAGE" ;;
  image) compose ps --format '{{.Image}}' app ;;
  *) echo "unknown action"; exit 2 ;;
esac
CTL
chmod 700 "$TMP/ctl.sh"

# ---- the browser part (Playwright, CDP virtual authenticator, https through the proxy)
export E2E_SETUP_LINK="$LINK" E2E_PORT=$WPORT E2E_BASE_URL="https://localhost:$WPORT" E2E_PUBLIC_URL="https://localhost:$PPORT" E2E_SPKI="$SPKI"
export E2E_DB_CONTAINER=$TNAME E2E_DB_PASSWORD=$ROOTPW E2E_DB_NAME=form E2E_LEGACY_CONTAINER=$SNAME E2E_LEGACY_ROOT_PASSWORD=$LROOT
export E2E_SRC_HOST=$SNAME E2E_SRC_PORT=3306 E2E_LEGACY_DB=$LDB E2E_LEGACY_USER=$LUSER E2E_LEGACY_PASSWORD=$LPW E2E_DUMP=$DUMP
export E2E_MAILPIT_HOST=$MP E2E_MAILPIT_API=$MPAPI E2E_CA=$TMP/ca/ca.pem E2E_TMP=$TMP E2E_CTL=$TMP/ctl.sh E2E_SPEC=${E2E_SPEC:-real-operator.spec.ts}
browser() {
  (cd pwa && npx playwright test -c e2e-real/real-operator.config.ts --reporter=line) > "$TMP/playwright.log" 2>&1
  local r=$?
  grep -E '^(STEP|NOTE|FINDING)' "$TMP/playwright.log"
  [ "$r" = 0 ] || tail -60 "$TMP/playwright.log"
  return $r
}
step browser browser

# ---- backup (encrypted, docs/BETRIEB.md "Backup/Restore") during a maintenance pause, restore probe into a NEW database, and the
#      restored database served by the same image with the same server key (the key file is part of what the operator keeps)
backup_restore() {
  local bk="$TMP/backups/form-backup-$(date -u +%Y%m%dT%H%M%SZ)" rpw r
  mkdir -p "$TMP/backups"; chmod 700 "$TMP/backups"
  age-keygen -o "$TMP/backup.key" >/dev/null 2>&1 && age-keygen -y "$TMP/backup.key" > "$TMP/backup.pub" || return 1
  export FORM_DB_HOST=$TNAME FORM_DB_PORT=3306 FORM_DB_TLS=verify DB_TLS_CA_FILE=$TMP/ca/ca.pem NETWORK_NAME=$NET
  compose stop app >/dev/null 2>&1 || return 1
  FORM_DB_USER=form FORM_DB_NAME=form FORM_DB_PASSWORD_FILE=$TMP/secrets/db_password FORM_BACKUP_AGE_RECIPIENTS_FILE=$TMP/backup.pub \
    scripts/backup-db.sh "$bk" > "$TMP/backup.log" 2>&1; r=$?
  compose start app >/dev/null 2>&1; ready || { echo "app not ready after the backup pause"; return 1; }
  [ "$r" = 0 ] || { tail -5 "$TMP/backup.log"; return 1; }
  ls "$bk" | tr '\n' ' '; echo
  grep -qi "BETRIEB-1" "$bk/database.sql.age" && { echo "clear text in the encrypted backup"; return 1; }
  rpw=$(openssl rand -hex 16); printf '%s' "$rpw" > "$TMP/restore_password"; chmod 400 "$TMP/restore_password"
  printf "CREATE USER 'restore_operator'@'%%' IDENTIFIED BY '%s' REQUIRE SSL; GRANT ALL PRIVILEGES ON \`restore\\\\_%%\`.* TO 'restore_operator'@'%%';" "$rpw" \
    | "$DOCKER" exec -i -e MYSQL_PWD="$ROOTPW" "$TNAME" mariadb --skip-ssl -uroot || return 1
  FORM_DB_USER=restore_operator FORM_DB_NAME=form FORM_DB_PASSWORD_FILE=$TMP/restore_password FORM_BACKUP_AGE_IDENTITY_FILE=$TMP/backup.key \
    scripts/restore-db.sh "$bk" restore_probe > "$TMP/restore.log" 2>&1 || { tail -5 "$TMP/restore.log"; return 1; }
  tail -2 "$TMP/restore.log"
  local a b
  a=$(echo "SELECT COUNT(*) FROM submissions; SELECT COUNT(*) FROM stored_objects; SELECT COUNT(*) FROM managed_secrets;" | "$DOCKER" exec -i -e MYSQL_PWD="$ROOTPW" "$TNAME" mariadb --skip-ssl -uroot -N form | tr '\n' ' ')
  b=$(echo "SELECT COUNT(*) FROM submissions; SELECT COUNT(*) FROM stored_objects; SELECT COUNT(*) FROM managed_secrets;" | "$DOCKER" exec -i -e MYSQL_PWD="$ROOTPW" "$TNAME" mariadb --skip-ssl -uroot -N restore_probe | tr '\n' ' ')
  echo "counts live/restored: $a / $b"; [ "$a" = "$b" ] || return 1
  # the restored database with the same image and server key: migrate is a no-op, the app becomes ready
  printf "GRANT ALL PRIVILEGES ON restore_probe.* TO 'form'@'%%';" | "$DOCKER" exec -i -e MYSQL_PWD="$ROOTPW" "$TNAME" mariadb --skip-ssl -uroot || return 1
  cp "$TMP/compose.env" "$TMP/compose.env.live"
  sed -i.bak 's/^FORM_DB_NAME=.*/FORM_DB_NAME=restore_probe/' "$TMP/compose.env" && rm -f "$TMP/compose.env.bak"
  compose run --rm --no-deps -T migrate > "$TMP/migrate-restore.log" 2>&1; r=$?
  grep -q "applied" "$TMP/migrate-restore.log" && grep -v "already\|skipped\|Creat\|Container" "$TMP/migrate-restore.log" | head -3
  compose up -d --wait --wait-timeout 180 app >/dev/null 2>&1 && ready; local ok=$?
  compose logs --no-color app 2>&1 | grep -iE "configuration failed|LoadError|secret" | head -3
  cp "$TMP/compose.env.live" "$TMP/compose.env"; compose up -d --wait --wait-timeout 180 app >/dev/null 2>&1 && ready || return 1
  [ "$r" = 0 ] && [ "$ok" = 0 ]
}
step backup-restore backup_restore

# ---- logs: no secret, no unexplained error
check_logs() {
  savelogs; local r=0 s
  for s in "${LINK##*#}" "$DBPW" "$ROOTPW" "$LROOT" "$LPW" "$(cat "$TMP/secrets/server_key")"; do
    grep -qF -- "$s" "$TMP/app.log" "$TMP/proxy.log" && { echo "FAIL a secret is in the logs"; r=1; }
  done
  grep -E '\[ (ERROR|CRITICAL|WARNING) \]|level=(error|warning)|"level":"(error|warning)"' "$TMP/app.log" | sed -E 's/[0-9a-f]{8}-[0-9a-f-]{27}/<id>/g' | cut -c1-200 | sort | uniq -c | sort -rn | head -20
  return $r
}
step logs check_logs
log "run $RUN_NO green"
exit 0
