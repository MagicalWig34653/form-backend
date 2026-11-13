#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Real run against the memory limit (fb-sec findings 1 and 2, S2-02): 16 PARALLEL 30 MiB bodies WITHOUT login against the public listener
# (FORM_PUBLIC_DASHBOARD=1) must not kill the container. App container with mem limit 512m and 1 CPU like deploy/swarm/stack.yaml,
# Linux binary of this checkout (release, static stdlib), own MariaDB, own network, unique names and ports (backend/e2e-common.sh).
# Phases (each: 16 x 30 MiB, then `OOMKilled` + liveness are checked; a killed container is restarted so every phase is judged):
#   ingest-unknown-form  POST /api/v2/submit/?f=<unknown>      ingest-existing-form  POST ...?f=<active form>, well-formed signature headers
#   admin-rotation       PUT .../key-rotation/objects/{id}     admin-hold            PUT .../entries/{id}/hold   (no cookie, dashboard host)
# Afterwards: both listeners answer, the ingest and the admin routes answer small requests with their normal status, RestartCount unchanged.
#   BB_BIN=<path>   use this prebuilt Linux App binary instead of building (e.g. the one of an older commit: proves the failure)
#   BB_SRC=<dir>    source tree to build (default: this checkout); BB_SCRATCH=<dir> build cache (default $HOME/.cache/fb-bb-build)
#   BB_N / BB_MB    parallel bodies (16) / size in MiB (30);  FORM_BODY_BUDGET_MB is passed through to the app
# Exit 0 = container survived every phase, 1 = OOMKilled or a check failed, 2 = environment problem.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
ROOT=$PWD
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
. backend/e2e-common.sh
DBIMG=${MARIADB_IMAGE:-mariadb:lts}; SWIFT_BUILD=${SWIFT_IMAGE:-swift:6.4-noble}; SWIFT_RUN=${SWIFT_RUN_IMAGE:-swift:6.4-noble-slim}
NET=$(e2e_name bb-net); DB=$(e2e_name bb-db); APP=$(e2e_name bb-app)
BASE=$(e2e_pick_port) || exit 2; PUB=${BB_PUBLIC_PORT:-$BASE}; INT=${BB_INTERNAL_PORT:-$((BASE + 1))}
N=${BB_N:-16}; MB=${BB_MB:-30}; SIZE=$((MB * 1024 * 1024)); HOST=dash.localhost
PW=$(openssl rand -hex 16); TMP=$(mktemp -d "${E2E_TMP_BASE:-$HOME/.cache}/bb.XXXXXX"); chmod 755 "$TMP"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
cleanup() { "$DOCKER" logs --tail 30 "$APP" >"$TMP/app-tail.log" 2>&1; [ -n "${E2E_LOG_DIR:-}" ] && { mkdir -p "$E2E_LOG_DIR"; cp "$TMP/app-tail.log" "$E2E_LOG_DIR/e2e-body-budget-app.log" 2>/dev/null; }; e2e_cleanup; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
e2e_reap_stale
"$DOCKER" info >/dev/null 2>&1 || { echo "ENV: docker daemon not reachable"; exit 2; }

# --- binary ---
if [ -n "${BB_BIN:-}" ]; then BIN=$BB_BIN; else
  SRC=${BB_SRC:-$ROOT}; SCRATCH=${BB_SCRATCH:-$HOME/.cache/fb-bb-build}; mkdir -p "$SCRATCH"
  echo "build: release binary of $SRC (cached in $SCRATCH)"
  "$DOCKER" run --rm "${E2E_LABEL_ARGS[@]}" -v "$SRC:/src" -v "$SCRATCH:/tmp/bb" -w /src/backend "$SWIFT_BUILD" \
    swift build -c release --product App --static-swift-stdlib --scratch-path /tmp/bb -Xswiftc -gnone >"$TMP/build.log" 2>&1 || { tail -20 "$TMP/build.log"; echo "ENV: build failed"; exit 2; }
  BIN=$SCRATCH/release/App
fi
[ -x "$BIN" ] || { echo "ENV: no binary at $BIN"; exit 2; }

# --- instance ---
umask 077; openssl rand -hex 32 > "$TMP/server.key"; chmod 400 "$TMP/server.key"
"$DOCKER" network create "${E2E_LABEL_ARGS[@]}" "$NET" >/dev/null || exit 2
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --network "$NET" --tmpfs /var/lib/mysql --name "$DB" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "$DBIMG" >/dev/null || { echo "ENV: db start failed"; exit 2; }
for _ in $(seq 90); do
  "$DOCKER" exec -e MYSQL_PWD="$PW" "$DB" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$PW" "$DB" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && break
  sleep 1
done
app_env=(-e FORM_HTTP_HOST=0.0.0.0 -e FORM_PUBLIC_PORT=8080 -e FORM_INTERNAL_PORT=8081 -e FORM_INTERNAL_SECOND_FACTOR=1 -e FORM_PUBLIC_DASHBOARD=1
  -e FORM_PUBLIC_DASHBOARD_HOSTS=$HOST -e FORM_DB_HOST="$DB" -e FORM_DB_PORT=3306 -e FORM_DB_USER=root -e FORM_DB_PASSWORD="$PW" -e FORM_DB_NAME=e2e
  -e FORM_DB_TLS=disable -e FORM_ALLOW_INSECURE_DEV=1 -e FORM_SCHEMA_FILE=/app/db/schema-p3.sql -e FORM_SERVER_KEY_FILE=/run/server.key
  -e FORM_ADMIN_ORIGIN=http://localhost:$INT -e FORM_RP_ID=localhost ${FORM_BODY_BUDGET_MB:+-e FORM_BODY_BUDGET_MB=$FORM_BODY_BUDGET_MB})
app_mounts=(-v "$BIN:/app/App:ro" -v "$ROOT/backend/db:/app/db:ro" -v "$TMP/server.key:/run/server.key:ro")
"$DOCKER" run --rm "${E2E_LABEL_ARGS[@]}" --network "$NET" "${app_env[@]}" "${app_mounts[@]}" --entrypoint /app/App "$SWIFT_RUN" migrate >"$TMP/migrate.log" 2>&1 || { tail -5 "$TMP/migrate.log"; echo "ENV: migrate failed"; exit 2; }
# memory limit and CPU like deploy/swarm/stack.yaml (APP_MEMORY 512M, APP_CPUS 1.0); swap = limit so that the limit is real
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --network "$NET" --name "$APP" --memory 512m --memory-swap 512m --cpus 1.0 \
  -p "127.0.0.1:$PUB:8080" -p "127.0.0.1:$INT:8081" "${app_env[@]}" "${app_mounts[@]}" --entrypoint /app/App "$SWIFT_RUN" serve >/dev/null || { echo "ENV: app start failed"; exit 2; }
wait_up() { for _ in $(seq 60); do curl -fs -o /dev/null "http://127.0.0.1:$PUB/healthz" && curl -fs -o /dev/null "http://127.0.0.1:$INT/healthz" && return 0; sleep 1; done; return 1; }
wait_up || { "$DOCKER" logs --tail 20 "$APP"; echo "ENV: app not healthy"; exit 2; }
FORM=$(python3 -c 'import uuid;print(uuid.uuid4().hex)'); CUST=$(python3 -c 'import uuid;print(uuid.uuid4().hex)')
FORMID=$(python3 -c "import uuid;print(uuid.UUID('$FORM'))")
"$DOCKER" exec -i -e MYSQL_PWD="$PW" "$DB" mariadb -uroot e2e <<SQL || { echo "ENV: seed failed"; exit 2; }
INSERT INTO customers (id,name,state,created_at) VALUES (UNHEX('$CUST'),'Synthetik Flut','active',UTC_TIMESTAMP(6));
INSERT INTO forms (id,customer_id,name,active,created_at) VALUES (UNHEX('$FORM'),UNHEX('$CUST'),'Flutformular',1,UTC_TIMESTAMP(6));
SQL
LIMIT=$("$DOCKER" inspect -f '{{.HostConfig.Memory}}' "$APP"); echo "instance: memory limit $LIMIT bytes, public :$PUB (dashboard $HOST), internal :$INT"
state() { "$DOCKER" inspect -f 'oom={{.State.OOMKilled}} running={{.State.Running}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' "$APP"; }
peak() { "$DOCKER" exec "$APP" cat /sys/fs/cgroup/memory.peak 2>/dev/null || "$DOCKER" exec "$APP" cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes 2>/dev/null || echo unknown; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@"; }

phase() { # name mode form
  local name=$1 mode=$2 form=${3:-} out st
  echo "--- phase $name: $N x $MB MiB, no login"
  out=$(python3 backend/e2e-body-budget-flood.py "$mode" "$PUB" "$HOST" "$N" "$SIZE" $form 2>&1); echo "responses: $out"
  sleep 2
  st=$(state); echo "state: $st; cgroup memory peak so far: $(peak) bytes"
  case $st in
    *oom=true*) bad "phase $name: container OOMKilled=true"; "$DOCKER" start "$APP" >/dev/null 2>&1; wait_up || { echo "ENV: restart failed"; exit 1; } ;;
    *running=true*) ok "phase $name: OOMKilled=false, still running" ;;
    *) bad "phase $name: container not running ($st)"; "$DOCKER" start "$APP" >/dev/null 2>&1; wait_up || exit 1 ;;
  esac
  wait_up && ok "phase $name: both listeners answer /healthz" || bad "phase $name: /healthz unreachable"
}
phase ingest-unknown-form ingest ""
phase ingest-existing-form ingest "$FORMID"
phase admin-rotation admin-rotation ""
phase admin-hold admin-hold ""

echo "--- after the floods: normal requests"
# the ingest still judges a normal small request normally (well-formed headers, no signature key: 403) and unknown forms 404
sig=$(printf 'A%.0s' $(seq 86))==
c=$(code -X POST -H 'Content-Type: application/x-www-form-urlencoded' -H "X-Kubus-Timestamp: $(date +%s)" -H "X-Kubus-Signature: $sig" --data 'a=b' "http://127.0.0.1:$PUB/api/v2/submit/?f=$FORMID")
[ "$c" = 403 ] && ok "small ingest request -> $c (handled by the signature check)" || bad "small ingest request -> $c (expected 403)"
c=$(code -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data 'a=b' "http://127.0.0.1:$PUB/api/v2/submit/?f=$(python3 -c 'import uuid;print(uuid.uuid4())')")
[ "$c" = 404 ] && ok "small ingest request, unknown form -> $c" || bad "small ingest request, unknown form -> $c (expected 404)"
c=$(code -X PUT -H "Host: $HOST" -H 'Content-Type: application/json' --data '{}' "http://127.0.0.1:$PUB/admin/api/v1/tenants/$(python3 -c 'import uuid;print(uuid.uuid4())')/key-rotation/objects/$(python3 -c 'import uuid;print(uuid.uuid4())')")
[ "$c" = 401 ] && ok "small anonymous admin PUT -> $c" || bad "small anonymous admin PUT -> $c (expected 401)"
st=$(state); echo "final state: $st"
case $st in *oom=false*restarts=0*) ok "no OOM kill and no restart during the whole run" ;; *) bad "container was killed or restarted during the run ($st)" ;; esac
echo "cgroup memory peak of the whole run: $(peak) bytes (limit $LIMIT)"
[ $fail = 0 ] && echo "RESULT: ok" || echo "RESULT: FAIL"
exit $fail
