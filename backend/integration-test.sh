#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# P4-A: swift test (native build system, see run-tests.sh) incl. DB integration test against a
# throw-away Docker MariaDB on 127.0.0.1:${P3B_PORT:-33417}. Random root password per run, kept in
# memory only (never written to disk or printed). Container is removed afterwards.
# P3B_DB_ARGS adds server options (e.g. --max-allowed-packet=4194304 for the packet-limit tests).
# Exit: swift test's exit code; 2 = environment problem.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
IMAGE=${MARIADB_IMAGE:-mariadb:lts}; NAME=${P3B_NAME:-p4a-mariadb}; PORT=${P3B_PORT:-33417}
PW=$(openssl rand -hex 16)
cleanup() {
  rc=$?
  if [ "$rc" != 0 ]; then
    # A server that died or restarted mid-run looks like an abruptly closed connection in the tests: say so.
    echo "diag: container state: $("$DOCKER" inspect -f 'status={{.State.Status}} oomKilled={{.State.OOMKilled}} exit={{.State.ExitCode}} restarts={{.RestartCount}} started={{.State.StartedAt}}' "$NAME" 2>&1)"
    echo "diag: server log tail:"; "$DOCKER" logs --tail 15 "$NAME" 2>&1 | sed 's/^/diag:   /'
  fi
  "$DOCKER" rm -f "$NAME" >/dev/null 2>&1; echo "cleanup: container $NAME removed"
}
trap cleanup EXIT
"$DOCKER" info >/dev/null 2>&1 || { echo "ENV: docker daemon not reachable"; exit 2; }
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
"$DOCKER" run -d --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=p4atest "$IMAGE" ${P3B_DB_ARGS:-} >/dev/null \
  || { echo "ENV: container start failed"; exit 2; }
up=0
for _ in $(seq 90); do
  if "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' p4atest >/dev/null 2>&1 && sleep 2 \
     && "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' p4atest >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ $up = 1 ] || { echo "ENV: server did not become ready"; exit 2; }
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
P4A_DB_PORT=$PORT P4A_DB_PASSWORD=$PW \
  python3 backend/run-with-timeout.py swift test --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native "$@"
