#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Local regression check (not in CI, ~2 min): the release IMAGE under --memory 512m takes 12 submissions with a 19,5 MB PDF one after
# another without OOM and with bounded RSS. Throwaway MariaDB + app container, form provisioned through the real UI (Playwright).
# Cause it guards: glibc heap fragmentation (without MALLOC_MMAP_THRESHOLD_ in the image RSS grows per large upload -> OOMKilled).
# Usage: backend/ingest-memory-check.sh IMAGE [COUNT=12] [MEM=512m] [RSS_LIMIT_MB=150]   (extra -e flags: DOCKER_EXTRA="-e MALLOC_MMAP_THRESHOLD_=-1")
# Needs: docker, php, pwa/node_modules with Playwright Chromium; WORKDIR must be inside a directory the Docker VM can mount (home).
# Exit 0 ok, 1 failed, 2 environment.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
IMG=${1:?image}; CNT=${2:-12}; MEM=${3:-512m}; LIM=${4:-150}
S=$(openssl rand -hex 3); N=fbmemchk-$S; PI=$((29000 + 0x$S % 900 * 2)); PP=$((PI + 1)); W=$(mktemp -d "$HOME/.fbmemchk.XXXXXX"); chmod 755 "$W"
cleanup() { docker rm -f "$N-app" "$N-db" >/dev/null 2>&1; docker network rm "$N" >/dev/null 2>&1; rm -rf "$W"; echo "cleanup done"; }
trap cleanup EXIT
PW=$(openssl rand -hex 16); KEY=$(openssl rand -hex 32); printf '%s' "$PW" > "$W/dbpw"
docker network create "$N" >/dev/null || { echo "ENV: network"; exit 2; }
docker run -d --network "$N" --name "$N-db" --tmpfs /var/lib/mysql -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=form "${MARIADB_IMAGE:-mariadb:lts}" --max-allowed-packet=67108864 >/dev/null || { echo "ENV: db"; exit 2; }
for _ in $(seq 60); do docker exec -e MYSQL_PWD="$PW" "$N-db" mariadb -uroot -e 'select 1' form >/dev/null 2>&1 && sleep 2 && break; sleep 1; done
cat > "$W/env.list" <<EOL
FORM_HTTP_HOST=0.0.0.0
FORM_PUBLIC_PORT=8080
FORM_INTERNAL_PORT=8081
FORM_DB_HOST=$N-db
FORM_DB_PORT=3306
FORM_DB_USER=root
FORM_DB_NAME=form
FORM_DB_TLS=disable
FORM_ALLOW_INSECURE_DEV=1
FORM_DB_PASSWORD_FILE=/s/dbpw
FORM_SERVER_KEY=$KEY
FORM_ADMIN_ORIGIN=http://localhost:$PI
FORM_RP_ID=localhost
EOL
chmod 644 "$W/dbpw" "$W/env.list"; printf '%s' "$(openssl rand -hex 12)" > "$W/bootpw"; chmod 644 "$W/bootpw"
D="docker run --rm --network $N --env-file $W/env.list -v $W:/s:ro"
$D "$IMG" migrate >/dev/null 2>&1 || { echo "FAIL migrate"; exit 1; }
LINK=$($D -e FORM_BOOTSTRAP_PASSWORD_FILE=/s/bootpw "$IMG" bootstrap-admin admin 2>&1 | sed -n 's/.*): \(http[^ ]*\)$/\1/p' | head -1)
[ -n "$LINK" ] || { echo "FAIL no enrollment link"; exit 1; }
# shellcheck disable=SC2086
docker run -d --network "$N" --name "$N-app" --env-file "$W/env.list" -v "$W:/s:ro" --memory "$MEM" --memory-swap "$MEM" ${DOCKER_EXTRA:-} -p "127.0.0.1:$PI:8081" -p "127.0.0.1:$PP:8080" "$IMG" serve >/dev/null || { echo "ENV: app"; exit 2; }
for _ in $(seq 30); do curl -fs "http://localhost:$PI/health" >/dev/null 2>&1 && break; sleep 1; done
(cd "${PWA_DIR:-pwa}" && E2E_SETUP_LINK="$LINK" E2E_PASSWORD=x E2E_PORT=$PI E2E_SPEC=real-load-setup.spec.ts E2E_CREDENTIALS_OUT="$W/cred.json" npx playwright test -c e2e-real/playwright.config.ts >"$W/pw.log" 2>&1)
[ -s "$W/cred.json" ] || { echo "ENV: provisioning failed"; tail -5 "$W/pw.log"; exit 2; }
{ printf '%%PDF-1.4\n'; head -c 19500000 /dev/urandom; } > "$W/big.pdf"
cat > "$W/drv.php" <<'PHP'
<?php
foreach (['Exception/FormBackendException', 'Exception/ConfigurationException', 'Exception/InvalidInputException', 'Exception/RejectedException', 'Exception/TransportException', 'Credentials', 'Transport', 'CurlTransport', 'VisitorIp', 'Submission', 'Canonical', 'Client'] as $f) require $argv[5] . '/sdk/php/src/' . $f . '.php';
$c = new FormBackend\Client($argv[2], FormBackend\Credentials::fromFile($argv[1]), totalTimeoutMs: 120000, maxAttempts: 1);
try { $c->submit(['email' => 'a@example.org', 'vorname' => 'X'], $argv[3], ['upload' => $argv[4]]); echo '200'; } catch (Throwable $e) { echo get_class($e) . ': ' . substr($e->getMessage(), 0, 120); }
PHP
rc=0; ok=0; PEAK=0
for i in $(seq "$CNT"); do
  r=$(php "$W/drv.php" "$W/cred.json" "http://127.0.0.1:$PP" "m-$S-$i" "$W/big.pdf" "$PWD" 2>&1 | tail -1)
  rss=$(docker exec "$N-app" sh -c "grep VmRSS /proc/1/status" 2>/dev/null | tr -dc '0-9'); rss=$(( ${rss:-0} / 1024 ))
  [ "$rss" -gt "$PEAK" ] && PEAK=$rss
  [ "$r" = 200 ] && ok=$((ok + 1))
  echo "#$i result=$r rss=${rss}MB oom=$(docker inspect -f '{{.State.OOMKilled}}' "$N-app")"
done
[ "$ok" = "$CNT" ] && echo "ok   $ok/$CNT submissions accepted at --memory $MEM" || { echo "FAIL only $ok/$CNT accepted"; rc=1; }
[ "$PEAK" -le "$LIM" ] && echo "ok   RSS peak ${PEAK}MB <= ${LIM}MB" || { echo "FAIL RSS peak ${PEAK}MB > ${LIM}MB"; rc=1; }
[ "$(docker inspect -f '{{.State.OOMKilled}}' "$N-app")" = false ] && echo "ok   no OOM kill" || { echo "FAIL OOM kill"; rc=1; }
exit $rc
