#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Linux test run: MariaDB container + swift container on a private Docker network (no published ports), all tests incl. DB ones.
# Used by CI and runnable locally (Docker Desktop: native arch). Random password per run, never printed.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
SWIFT_IMAGE=${SWIFT_IMAGE:-swift:6.4-noble}; DB_IMAGE=${MARIADB_IMAGE:-mariadb:lts}
NET=formbackend-ci-$$; DB=formbackend-ci-db-$$; MP=formbackend-ci-mail-$$; MP_IMAGE=${MAILPIT_IMAGE:-axllent/mailpit:latest}; PW=$(openssl rand -hex 16)
cleanup() { "$DOCKER" rm -f "$DB" "$MP" >/dev/null 2>&1; "$DOCKER" network rm "$NET" >/dev/null 2>&1; echo "cleanup done"; }
trap cleanup EXIT
"$DOCKER" network create "$NET" >/dev/null || exit 2
"$DOCKER" run -d --name "$DB" --network "$NET" --tmpfs /var/lib/mysql -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=p4atest "$DB_IMAGE" >/dev/null || exit 2
"$DOCKER" run -d --name "$MP" --network "$NET" -v "$PWD/backend/Tests/TestSupport/Fixtures:/certs:ro" -e MP_SMTP_TLS_CERT=/certs/test-cert.pem -e MP_SMTP_TLS_KEY=/certs/test-key.pem -e MP_SMTP_AUTH_ACCEPT_ANY=1 "$MP_IMAGE" >/dev/null || echo "note: mailpit not started, the SMTP interop tests will be skipped"
up=0
for _ in $(seq 90); do
  if "$DOCKER" exec -e MYSQL_PWD="$PW" "$DB" mariadb -uroot -e 'select 1' p4atest >/dev/null 2>&1 && sleep 2 \
     && "$DOCKER" exec -e MYSQL_PWD="$PW" "$DB" mariadb -uroot -e 'select 1' p4atest >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ $up = 1 ] || { echo "ENV: database did not become ready"; exit 2; }
"$DOCKER" run --rm --network "$NET" -e P4A_MAILPIT_HOST="$MP" -e P4A_MAILPIT_SMTP_PORT=1025 -e P4A_MAILPIT_API_PORT=8025 -e P4A_DB_HOST="$DB" -e P4A_DB_PORT=3306 -e P4A_DB_PASSWORD="$PW" \
  -v "$PWD:/src" -w /src/backend ${LINUX_SCRATCH:+-v "$LINUX_SCRATCH:/tmp/lin-build"} "$SWIFT_IMAGE" \
  bash -c '(apt-get update -qq && apt-get install -y -qq php-cli php-curl php-mbstring >/dev/null 2>&1) || echo "note: php not installed, PHP SDK end-to-end test will be skipped"; timeout 2700 stdbuf -oL -eL swift test --scratch-path /tmp/lin-build "$@"; rc=$?; [ $rc = 124 ] && echo "HANG: swift test exceeded 2700 s; last started test is the one without a result above"; exit $rc' -- "$@"
