#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# The mail chain PHP SDK -> backend -> Mailpit ONCE against the built/published Docker IMAGE (not the binary), so image, entrypoint wrapper,
# the image ENV (MALLOC_*), the compose resource limit (APP_MEMORY) and FORM_MAIL_MAX_MB/FORM_BODY_BUDGET_MB defaults are tested together.
#   IMAGE=<ref|digest>  default ghcr.io/magicalwig34653/form-backend:latest
#   PULL=1              pull IMAGE first (default 1; PULL=0 for a locally built image such as form-local:probe)
#   APP_MEMORY=<limit>  optional, default from deploy/compose/compose.yaml (1024M)
# Instance like the compose operation: deploy/compose/compose.yaml (entrypoint wrapper, uid via APP_UID, file secrets, memory limit) with a
# per-run override (labels, host ports on loopback), external MariaDB (max_allowed_packet 256M) and Mailpit in the run network.
# The browser part is the EXISTING spec pwa/e2e-real/real-mail-attachment.spec.ts (setup link, passkey, form, mail connection, SDK submissions:
# 2 small files with umlaut names, 3 MB, 19,9 MB, over the mail limit, manual resend; each exactly one mail, SHA-256 per attachment).
# Afterwards: container still running, RestartCount 0, OOMKilled false, memory limit applied, MALLOC_* in the container environment.
# NOT covered here (see e2e-operator.sh): DB TLS and the HTTPS reverse proxy; this run uses FORM_DB_TLS=disable + FORM_ALLOW_INSECURE_DEV=1 (http://localhost).
# Containers/networks/ports unique per run (backend/e2e-common.sh, removed by label only). Exit 0 ok, 1 failed, 2 environment problem.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
ROOT=$PWD
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
IMAGE=${IMAGE:-ghcr.io/magicalwig34653/form-backend:latest}
. backend/e2e-common.sh
STACK=mim$(printf '%s' "$E2E_RUN_ID" | tr -cd 'a-z0-9' | cut -c1-12)
NET=$(e2e_name mim-net); DBN=$(e2e_name mim-db); MP=$(e2e_name mim-mailpit)
BASE=$(e2e_pick_port) || exit 2; WPORT=${E2E_PORT:-$BASE}; PPORT=$((WPORT + 1)); MPAPI=$((WPORT + 2))
mkdir -p "${E2E_TMP_BASE:=$HOME/.cache}"; TMP=$(mktemp -d "$E2E_TMP_BASE/mim.XXXXXX"); chmod 755 "$TMP"
T0=$(date +%s)
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
compose() { "$DOCKER" compose --project-directory "$ROOT/deploy/compose" --project-name "$STACK" --env-file "$TMP/compose.env" -f "$ROOT/deploy/compose/compose.yaml" -f "$TMP/override.yaml" "$@"; }
cleanup() {
  compose logs --no-color app > "$TMP/app.log" 2>&1
  [ -n "${E2E_LOG_DIR:-}" ] && { mkdir -p "$E2E_LOG_DIR"; cp "$TMP"/*.log "$E2E_LOG_DIR/" 2>/dev/null; }
  compose down -v --remove-orphans >/dev/null 2>&1; e2e_cleanup; rm -rf "$TMP"; log "cleanup done (runtime $(( $(date +%s) - T0 )) s)"
}
trap cleanup EXIT
"$DOCKER" info >/dev/null 2>&1 || { echo "ENV: docker daemon not reachable"; exit 2; }
e2e_reap_stale
if [ "${PULL:-1}" = 1 ]; then "$DOCKER" pull -q "$IMAGE" >/dev/null || { echo "ENV: pull $IMAGE"; exit 2; }; fi
PINNED=$("$DOCKER" image inspect "$IMAGE" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}') || { echo "ENV: image $IMAGE not available"; exit 2; }
[ -n "$PINNED" ] || PINNED=$IMAGE
log "image $PINNED ($("$DOCKER" image inspect "$PINNED" --format '{{.Id}} {{.Architecture}} created {{.Created}}'))"

umask 077
mkdir -p "$TMP/secrets"; chmod 755 "$TMP/secrets"
DBPW=$(openssl rand -hex 16); ROOTPW=$(openssl rand -hex 16); PASSWORD=$(openssl rand -hex 12)
printf '%s' "$DBPW" > "$TMP/secrets/db_password"; openssl rand -hex 32 | tr -d '\n' > "$TMP/secrets/server_key"; printf '%s' "$PASSWORD" > "$TMP/secrets/bootstrap_password"
chmod 400 "$TMP/secrets"/*   # owned by APP_UID = the current user, like the compose setup after its chown

# network (own subnet; FORM_MAIL_ALLOWED_NETS permits it, private SMTP targets are blocked by default)
for _ in 1 2 3 4 5 6; do
  "$DOCKER" network create "${E2E_LABEL_ARGS[@]}" --subnet "10.$((100 + RANDOM % 120)).$((RANDOM % 256)).0/24" "$NET" >/dev/null 2>&1 && break
done
SUBNET=$("$DOCKER" network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$NET" 2>/dev/null)
[ -n "$SUBNET" ] || { echo "ENV: network"; exit 2; }

# MariaDB: max_allowed_packet 256M (BETRIEB.md: at least the largest attachment cell), own DB and user like an operator
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --tmpfs /var/lib/mysql --network "$NET" --name "$DBN" -e MARIADB_ROOT_PASSWORD="$ROOTPW" \
  -e MARIADB_DATABASE=e2e -e MARIADB_USER=form -e MARIADB_PASSWORD="$DBPW" "${MARIADB_IMAGE:-mariadb:lts}" --max-allowed-packet=268435456 >/dev/null || { echo "ENV: db container"; exit 2; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --network "$NET" --name "$MP" -p "127.0.0.1:$MPAPI:8025" "${MAILPIT_IMAGE:-axllent/mailpit:latest}" >/dev/null || { echo "ENV: mailpit container"; exit 2; }
for _ in $(seq 120); do
  "$DOCKER" exec -e MYSQL_PWD="$ROOTPW" "$DBN" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$ROOTPW" "$DBN" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && up=1 && break; sleep 1
done
[ "${up:-0}" = 1 ] || { echo "ENV: db not ready"; exit 2; }
PKT=$("$DOCKER" exec -e MYSQL_PWD="$ROOTPW" "$DBN" mariadb -uroot -N -e 'select @@max_allowed_packet' 2>/dev/null)
[ "${PKT:-0}" -ge 268435456 ] || { echo "ENV: max_allowed_packet is $PKT"; exit 2; }
for _ in $(seq 60); do curl -fs "http://127.0.0.1:$MPAPI/api/v1/info" >/dev/null 2>&1 && mp=1 && break; sleep 1; done
[ "${mp:-0}" = 1 ] || { echo "ENV: mailpit not ready"; exit 2; }

cat > "$TMP/compose.env" <<EOF
STACK=$STACK
NETWORK_NAME=$NET
FORM_IMAGE=$PINNED
FORM_DB_HOST=$DBN
FORM_DB_PORT=3306
FORM_DB_USER=form
FORM_DB_NAME=e2e
FORM_DB_TLS=disable
FORM_ALLOW_INSECURE_DEV=1
FORM_ADMIN_ORIGIN=http://localhost:$WPORT
FORM_RP_ID=localhost
FORM_MAIL_ALLOWED_NETS=$SUBNET
DB_PASSWORD_SOURCE_FILE=$TMP/secrets/db_password
SERVER_KEY_SOURCE_FILE=$TMP/secrets/server_key
BOOTSTRAP_PASSWORD_SOURCE_FILE=$TMP/secrets/bootstrap_password
APP_UID=$(id -u)
APP_GID=$(id -g)
${APP_MEMORY:+APP_MEMORY=$APP_MEMORY}
EOF
# Labels only (cleanup), host ports on loopback for the browser and the SDK. FORM_MAIL_MAX_MB / FORM_BODY_BUDGET_MB are NOT set: the image defaults count
# (the compose app service does not even pass them through, see the handoff).
cat > "$TMP/override.yaml" <<EOF
services:
  migrate:
    labels: { e2e.run: "$E2E_RUN_ID", e2e.started: "$E2E_STARTED" }
  app:
    labels: { e2e.run: "$E2E_RUN_ID", e2e.started: "$E2E_STARTED" }
    ports: ["127.0.0.1:$WPORT:8081", "127.0.0.1:$PPORT:8080"]
EOF
compose config -q >"$TMP/config.log" 2>&1 || { echo "ENV: compose config"; tail -5 "$TMP/config.log"; exit 2; }

step() { local n=$1 t; shift; t=$(date +%s); if "$@"; then echo "STEP $n ok $(( $(date +%s) - t ))s"; else echo "STEP $n FAIL $(( $(date +%s) - t ))s"; exit 1; fi; }
migrate_once() { compose run --rm --no-deps -T migrate > "$TMP/migrate.log" 2>&1 || { tail -5 "$TMP/migrate.log"; return 1; }; }
bootstrap() {
  compose run --rm --no-deps -T app bootstrap-admin admin > "$TMP/bootstrap.out" 2>&1 || { sed -n 1,3p "$TMP/bootstrap.out" | cut -c1-120; return 1; }
  LINK=$(sed -n 's/.*): \(http[^ ]*\)$/\1/p' "$TMP/bootstrap.out" | head -1); [ -n "$LINK" ]
}
app_up() { compose up -d --wait --wait-timeout 180 app > "$TMP/up.log" 2>&1 || { tail -5 "$TMP/up.log"; compose logs --no-color --tail 20 app; return 1; }; }
step migrate migrate_once
step bootstrap-admin bootstrap
step app-up app_up
CID=$(compose ps -q app)

browser() {
  export E2E_SETUP_LINK="$LINK" E2E_PASSWORD="$PASSWORD" E2E_PORT=$WPORT E2E_SPEC=real-mail-attachment.spec.ts E2E_TMP="$TMP" E2E_PUBLIC_URL=http://127.0.0.1:$PPORT
  export E2E_DB_CONTAINER="$DBN" E2E_DB_PASSWORD="$ROOTPW" E2E_MAILPIT_SMTP=1025 E2E_MAILPIT_SMTP_HOST="$MP" E2E_MAILPIT_API=$MPAPI
  export E2E_SUBMIT_DRIVER="$ROOT/backend/e2e-mail-attach-submit.php"
  (cd pwa && npx playwright test -c e2e-real/playwright.config.ts --reporter=line) > "$TMP/playwright.log" 2>&1; local r=$?
  tail -25 "$TMP/playwright.log"
  [ "$r" = 0 ] || "$DOCKER" exec -e MYSQL_PWD="$ROOTPW" "$DBN" mariadb -uroot e2e -e 'SELECT mail_kind, state, attempts, last_error_code, transport_kind FROM mail_deliveries' 2>&1 | head -10
  return $r
}
step browser browser

# the container itself: no restart, no OOM, limit applied, image ENV present, peak memory
container_checks() {
  local r=0 st rc oom mem env
  st=$("$DOCKER" inspect -f '{{.State.Status}}' "$CID"); rc=$("$DOCKER" inspect -f '{{.RestartCount}}' "$CID")
  oom=$("$DOCKER" inspect -f '{{.State.OOMKilled}}' "$CID"); mem=$("$DOCKER" inspect -f '{{.HostConfig.Memory}}' "$CID")
  echo "state=$st restarts=$rc oomkilled=$oom memory-limit=$mem exit-code=$("$DOCKER" inspect -f '{{.State.ExitCode}}' "$CID")"
  [ "$st" = running ] && [ "$rc" = 0 ] && [ "$oom" = false ] || { echo "FAIL container not stable"; r=1; }
  [ "$mem" -gt 0 ] || { echo "FAIL no memory limit applied (APP_MEMORY)"; r=1; }
  env=$("$DOCKER" exec "$CID" env | grep -E '^MALLOC_' | sort); echo "$env"
  for v in MALLOC_MMAP_THRESHOLD_=131072 MALLOC_TRIM_THRESHOLD_=131072 MALLOC_ARENA_MAX=2; do
    printf '%s\n' "$env" | grep -qx "$v" || { echo "FAIL $v missing in the container"; r=1; }
  done
  "$DOCKER" stats --no-stream --format 'memory now: {{.MemUsage}}' "$CID" 2>/dev/null
  compose ps -q app | grep -qx "$CID" || { echo "FAIL container was replaced"; r=1; }
  compose logs --no-color app > "$TMP/app.log" 2>&1
  for s in "$DBPW" "$ROOTPW" "$PASSWORD" "$(cat "$TMP/secrets/server_key")" "${LINK##*#}"; do grep -qF -- "$s" "$TMP/app.log" && { echo "FAIL a secret is in the app log"; r=1; }; done
  echo "app log: $(grep -cE '\[ (ERROR|CRITICAL) \]|level=error|"level":"error"' "$TMP/app.log") error lines"
  return $r
}
step container container_checks
log "green (image $PINNED)"
exit 0
