#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Regenerates legacy-synthetic.sql (DATA ONLY; the structure is legacy-real.sql) from the synthetic rehearsal source of FormAdminTests
# (RehearsalSource.swift) in a throw-away MariaDB container. Synthetic data only; secrets: see RehearsalSource (recoveryCode, key seeds 0x10/0x11).
# Every run draws new random package bytes; commit the result only when the content must change. Exit 0 ok, 2 environment.
set -u
cd "$(cd "$(dirname "$0")/../../../.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
NAME=${P3B_NAME:-p4a-synth-mariadb}; PORT=${P3B_PORT:-33951}
PW=$(openssl rand -hex 16); TMP=$(mktemp -d)
cleanup() { "$DOCKER" rm -f "$NAME" >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT
OUT=backend/Tests/FormMigrationTests/Fixtures/legacy-synthetic.sql
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
"$DOCKER" run -d --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=p4atest "${MARIADB_IMAGE:-mariadb:lts}" >/dev/null || { echo "ENV: container"; exit 2; }
for _ in $(seq 90); do
  "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' p4atest >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' p4atest >/dev/null 2>&1 && up=1 && break; sleep 1
done
[ "${up:-0}" = 1 ] || { echo "ENV: db not ready"; exit 2; }
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
FORM_SYNTH_NAME_FILE="$TMP/name" P4A_DB_PORT=$PORT P4A_DB_PASSWORD=$PW swift test --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --filter SyntheticLegacyDumpTests >"$TMP/test.log" 2>&1 || { tail -20 "$TMP/test.log"; echo "ENV: generator test"; exit 2; }
SCHEMA=$(cat "$TMP/name")
{
  echo "-- SPDX-License-Identifier: AGPL-3.0-only"
  echo "-- Synthetische Altdaten (erfunden) zur Struktur legacy-real.sql. Erzeugt mit regen-legacy-synthetic.sh aus RehearsalSource.swift."
  echo "-- Schluessel: Seeds 0x10 (auslaufend) und 0x11 (aktiv); Recovery-Code der aktiven Generation: siehe RehearsalSource.recoveryCode."
  echo "SET FOREIGN_KEY_CHECKS=0;"
  "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb-dump -uroot --no-create-info --skip-triggers --skip-comments --skip-add-locks --skip-disable-keys \
    --hex-blob --complete-insert --net-buffer-length=65536 --skip-tz-utc "$SCHEMA" | grep -v '^/\*M!999999'
  echo "SET FOREIGN_KEY_CHECKS=1;"
} > "$OUT"
ls -l "$OUT"
