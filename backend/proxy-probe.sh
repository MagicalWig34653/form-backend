#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Real deployment probe: the release image + MariaDB + nginx (two server blocks, public and internal host) on a private Docker
# network. Checks the listener separation through a real reverse proxy (deploy/proxy/nginx.conf.example, HTTP variant without TLS).
# Usage: IMAGE=form-local:probe bash backend/proxy-probe.sh      Exit 0 = ok, 1 = check failed, 2 = environment problem.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; IMAGE=${IMAGE:-form-local:probe}
. "$(dirname "$0")/e2e-common.sh"
NET=$(e2e_name formprobe-net); DB=$(e2e_name formprobe-db); APP=$(e2e_name formprobe-app); PX=$(e2e_name formprobe-px); PW=$(openssl rand -hex 16)
WORK=$(mktemp -d "${PROBE_TMP:-$HOME}/formprobe.XXXXXX"); PXPORT=${PROBE_PORT:-$(e2e_pick_port)}
cleanup() { e2e_cleanup; rm -rf "$WORK"; echo "cleanup done"; }
trap cleanup EXIT
e2e_reap_stale
"$DOCKER" info >/dev/null 2>&1 || { echo "ENV: docker daemon not reachable"; exit 2; }
"$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 || { echo "ENV: image $IMAGE missing"; exit 2; }
umask 077
openssl rand -hex 32 > "$WORK/server.key"; printf '%s' "$PW" > "$WORK/db.pw"; chmod 600 "$WORK/server.key" "$WORK/db.pw"
cat > "$WORK/nginx.conf" <<'NGINX'
events {}
http {
  server {
    listen 80; server_name forms.probe;
    location / { proxy_pass http://APP:8080; proxy_set_header Host $host; proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-For $remote_addr; proxy_set_header Forwarded ""; }
  }
  server {
    listen 80; server_name admin.probe;
    location / { proxy_pass http://APP:8081; proxy_set_header Host $host; proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-For $remote_addr; proxy_set_header Forwarded ""; }
  }
}
NGINX
sed -i.bak "s/APP:/$APP:/g" "$WORK/nginx.conf" && rm -f "$WORK/nginx.conf.bak"
"$DOCKER" network create "${E2E_LABEL_ARGS[@]}" "$NET" >/dev/null || exit 2
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --name "$DB" --network "$NET" --tmpfs /var/lib/mysql -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=form "${MARIADB_IMAGE:-mariadb:lts}" >/dev/null || exit 2
up=0
for _ in $(seq 90); do
  "$DOCKER" exec -e MYSQL_PWD="$PW" "$DB" mariadb -uroot -e 'select 1' form >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$PW" "$DB" mariadb -uroot -e 'select 1' form >/dev/null 2>&1 && { up=1; break; }
  sleep 1
done
[ $up = 1 ] || { echo "ENV: db not ready"; exit 2; }
ENVS=(-e FORM_DB_HOST="$DB" -e FORM_DB_USER=root -e FORM_DB_NAME=form -e FORM_DB_TLS=disable -e FORM_ALLOW_INSECURE_DEV=1
  -e FORM_DB_PASSWORD_FILE=/run/secrets/db.pw -e FORM_SERVER_KEY_FILE=/run/secrets/server.key
  -e FORM_ADMIN_ORIGIN=http://admin.probe -e FORM_RP_ID=admin.probe -e FORM_PUBLIC_PORT=8080 -e FORM_INTERNAL_PORT=8081
  -e FORM_PUBLIC_TRUSTED_PROXIES=0.0.0.0/0 -e FORM_INTERNAL_TRUSTED_PROXIES=0.0.0.0/0)
MOUNTS=(-v "$WORK/server.key:/run/secrets/server.key:ro" -v "$WORK/db.pw:/run/secrets/db.pw:ro")
"$DOCKER" run --rm "${E2E_LABEL_ARGS[@]}" --user 0:0 --network "$NET" "${ENVS[@]}" "${MOUNTS[@]}" "$IMAGE" migrate >"$WORK/migrate.log" 2>&1 || { echo "FAIL migrate"; tail -5 "$WORK/migrate.log"; exit 1; }
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --user 0:0 --name "$APP" --network "$NET" "${ENVS[@]}" "${MOUNTS[@]}" "$IMAGE" serve >/dev/null || exit 2
"$DOCKER" run -d "${E2E_LABEL_ARGS[@]}" --name "$PX" --network "$NET" -p "127.0.0.1:$PXPORT:80" -v "$WORK/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:alpine >/dev/null || exit 2
fail=0; check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
for _ in $(seq 40); do [ "$(code -H 'Host: admin.probe' "http://127.0.0.1:$PXPORT/health")" = 200 ] && break; sleep 1; done
P="http://127.0.0.1:$PXPORT"
check "internal host: health" "$(code -H 'Host: admin.probe' $P/health)" 200
check "internal host: ready" "$(code -H 'Host: admin.probe' $P/ready)" 200
check "internal host: admin API without session" "$(code -H 'Host: admin.probe' $P/admin/api/v1/me)" 401
check "internal host: PWA index" "$(code -H 'Host: admin.probe' $P/)" 200
check "internal host: setup-state needs a session" "$(code -H 'Host: admin.probe' $P/admin/api/v1/setup-state)" 401
check "internal host: submit endpoint absent" "$(code -X POST -H 'Host: admin.probe' $P/api/v2/submit/)" 404
check "public host: admin API absent" "$(code -H 'Host: forms.probe' $P/admin/api/v1/me)" 404
check "public host: setup-state absent" "$(code -H 'Host: forms.probe' $P/admin/api/v1/setup-state)" 404
check "public host: PWA absent (dashboard off)" "$(code -H 'Host: forms.probe' $P/)" 404
check "public host: submit unsigned" "$(code -X POST -H 'Host: forms.probe' -H 'Content-Type: application/x-www-form-urlencoded' --data a=1 "$P/api/v2/submit/?f=00000000-0000-4000-8000-000000000001")" 404
check "public host: submit GET not allowed" "$(code -H 'Host: forms.probe' "$P/api/v2/submit/?f=00000000-0000-4000-8000-000000000001")" 405
check "public host: MCP needs a token" "$(code -X POST -H 'Host: forms.probe' -H 'Content-Type: application/json' --data '{}' $P/mcp/)" 401
check "public host: OAuth discovery" "$(code -H 'Host: forms.probe' $P/.well-known/oauth-authorization-server)" 200
check "public host: oauth consent absent" "$(code -H 'Host: forms.probe' $P/admin/api/v1/account/oauth)" 404
out=$("$DOCKER" logs "$APP" 2>&1 | grep -ciE "password|secret|FORM_SERVER_KEY" || true)
check "no secret words in app log" "$out" 0
[ $fail = 0 ] || { echo "--- app log"; "$DOCKER" logs "$APP" 2>&1 | tail -15 | cut -c1-200; echo "--- proxy log"; "$DOCKER" logs "$PX" 2>&1 | tail -8 | cut -c1-200; }
echo "exit=$fail"; exit $fail
