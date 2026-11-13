#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Self-test of scripts/docker-build.sh without building the real image:
#   1. prune_old_images keeps :latest and the newest 3 hash tags of a dummy repo (form-backend-selftest), removes the rest.
#   2. A failing smoke test exits non-zero and leaves no container or network behind.
# Dummy images are label-only layers on top of an already present image (no pull of new layers, a few kB each).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
BASE_IMAGE=${SELFTEST_BASE_IMAGE:-mariadb:lts}
REPO=form-backend-selftest
# shellcheck source=scripts/docker-build.sh
source "$HERE/docker-build.sh"
docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || docker pull -q "$BASE_IMAGE" >/dev/null

fail=0
expect() { if [[ "$2" == "$3" ]]; then log "ok   $1"; else log "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
cleanup() { docker image ls "$REPO" --format '{{.Repository}}:{{.Tag}}' | xargs -r docker rmi -f >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

# 1. image retention: 6 hash tags built one after the other (distinct creation times) plus :latest
for n in 1 2 3 4 5 6; do
  printf 'FROM %s\nLABEL selftest=%s\n' "$BASE_IMAGE" "$n" | docker build -q -t "$REPO:h$n" - >/dev/null
  sleep 1
done
docker tag "$REPO:h6" "$REPO:latest"
prune_old_images "$REPO" 3 >/dev/null
expect "retention: kept tags" "$(docker image ls "$REPO" --format '{{.Tag}}' | sort | tr '\n' ' ')" "h4 h5 h6 latest "
expect "retention: older tags removed" "$(docker image ls "$REPO" --format '{{.Tag}}' | grep -cE '^h[123]$' || true)" 0
prune_old_images "$REPO" 3 >/dev/null
expect "retention: idempotent" "$(docker image ls "$REPO" --format '{{.Tag}}' | wc -l | tr -d ' ')" 4
prune_old_images "$REPO" 0 >/dev/null
expect "retention: keep 0 still keeps :latest" "$(docker image ls "$REPO" --format '{{.Tag}}' | tr -d '\n')" latest

# 2. failing smoke test: the image cannot serve the app (its entrypoint rejects `migrate`) -> exit != 0, nothing left over
before=$(docker ps -a --format '{{.Names}}' | grep -c "^$SMOKE_PREFIX-" || true)
set +e
"$HERE/docker-build.sh" --smoke-image "$REPO:latest" >/dev/null 2>&1
rc=$?
set -e
expect "failing smoke: exit code is not 0" "$([[ $rc -ne 0 ]] && echo nonzero || echo "$rc")" nonzero
expect "failing smoke: no smoke container left" "$(docker ps -a --format '{{.Names}}' | grep -c "^$SMOKE_PREFIX-" || true)" "$before"
expect "failing smoke: no smoke network left" "$(docker network ls --format '{{.Name}}' | grep -c "^$SMOKE_PREFIX-" || true)" 0

if (( fail )); then log "SELFTEST FEHLGESCHLAGEN"; exit 1; fi
log "SELFTEST ok"
