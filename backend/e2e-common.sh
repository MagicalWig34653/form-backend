#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Shared helpers for backend/e2e-*.sh, smoke-admin.sh, loadtest.sh, proxy-probe.sh (source it from the repo root: `. backend/e2e-common.sh`).
# Rule: every Docker container/network of a run carries the labels e2e.run=<RUN_ID> and e2e.started=<epoch>, has a name ending in -<RUN_ID>,
# and is removed ONLY via that label. Two runs (same or different scripts, any number of sessions) never touch each other.
#   e2e_name BASE            -> BASE-<RUN_ID> (unique container/network name)
#   E2E_LABEL_ARGS           -> array: --label e2e.run=.. --label e2e.started=.. (pass to `docker run` / `docker network create`)
#   e2e_cleanup              -> removes the containers/networks of THIS run (label) and releases its port blocks
#   e2e_reap_stale [HOURS]   -> removes labelled containers/networks of dead runs older than HOURS (default E2E_STALE_HOURS or 6)
#   e2e_pick_port            -> prints a free port block base (block = base..base+127), reserved until e2e_cleanup (ports stay overridable by the callers)
#   e2e_pwa_build DIR        -> builds the PWA into DIR (per run, never the shared pwa/dist)
# RUN_ID: E2E_RUN_ID if preset (self test), otherwise <pid>-<random>.

E2E_RUN_ID=${E2E_RUN_ID:-$$-$(openssl rand -hex 3)}
E2E_STARTED=$(date +%s)
E2E_LABEL_ARGS=(--label "e2e.run=$E2E_RUN_ID" --label "e2e.started=$E2E_STARTED")
E2E_PORT_LOCKS=${E2E_PORT_LOCKS:-${TMPDIR:-/tmp}/e2e-port-locks}
E2E_OUTPUT_DIR=${E2E_OUTPUT_DIR:-${TMPDIR:-/tmp}/e2e-pw-$E2E_RUN_ID}  # Playwright output dir per run (default test-results is shared)
export E2E_RUN_ID E2E_OUTPUT_DIR

e2e_name() { printf '%s-%s' "$1" "$E2E_RUN_ID"; }

e2e_cleanup() {
  local d=${DOCKER:-docker} ids p
  ids=$("$d" ps -aq --filter "label=e2e.run=$E2E_RUN_ID" 2>/dev/null)
  [ -n "$ids" ] && "$d" rm -f $ids >/dev/null 2>&1
  ids=$("$d" network ls -q --filter "label=e2e.run=$E2E_RUN_ID" 2>/dev/null)
  [ -n "$ids" ] && "$d" network rm $ids >/dev/null 2>&1
  rm -rf "$E2E_OUTPUT_DIR"
  for p in "$E2E_PORT_LOCKS"/*/; do
    [ -f "${p}owner" ] && [ "$(cat "${p}owner" 2>/dev/null)" = "$E2E_RUN_ID" ] && rm -rf "$p"
  done
  return 0
}

# Only labelled objects, only when started more than HOURS ago AND the owning run is not ours; never name patterns, never unlabelled objects.
e2e_reap_stale() {
  local d=${DOCKER:-docker} hours=${1:-${E2E_STALE_HOURS:-6}} now line id run started
  now=$(date +%s)
  while IFS='|' read -r id run started; do
    [ -n "$id" ] && [ "$run" != "$E2E_RUN_ID" ] || continue
    case $started in ''|*[!0-9]*) continue ;; esac
    [ $((now - started)) -gt $((hours * 3600)) ] && "$d" rm -f "$id" >/dev/null 2>&1
  done < <("$d" ps -a --filter label=e2e.run --format '{{.ID}}|{{.Label "e2e.run"}}|{{.Label "e2e.started"}}' 2>/dev/null)
  while IFS='|' read -r id run started; do
    [ -n "$id" ] && [ "$run" != "$E2E_RUN_ID" ] || continue
    case $started in ''|*[!0-9]*) continue ;; esac
    [ $((now - started)) -gt $((hours * 3600)) ] && "$d" network rm "$id" >/dev/null 2>&1
  done < <("$d" network ls --filter label=e2e.run --format '{{.ID}}|{{.Label "e2e.run"}}|{{.Label "e2e.started"}}' 2>/dev/null)
  return 0
}

# Blocks of 128 ports in 20480..32639 (below the Linux ephemeral range). Reserved by an atomic mkdir; a lock whose owner process is dead is taken over.
e2e_port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
e2e_pick_port() {
  local try idx base off busy lock pid
  mkdir -p "$E2E_PORT_LOCKS" 2>/dev/null
  for try in $(seq 60); do
    idx=$((160 + RANDOM % 95)); base=$((idx * 128)); lock=$E2E_PORT_LOCKS/$idx
    if [ -d "$lock" ]; then
      pid=$(cat "$lock/pid" 2>/dev/null)
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi
      rm -rf "$lock"
    fi
    busy=0; for off in $(seq 0 127); do e2e_port_busy $((base + off)) && { busy=1; break; }; done
    [ $busy = 0 ] || continue
    mkdir "$lock" 2>/dev/null || continue
    echo $$ > "$lock/pid"; echo "$E2E_RUN_ID" > "$lock/owner"
    printf '%s' "$base"; return 0
  done
  echo "ENV: no free port block" >&2; return 1
}

e2e_pwa_build() { (cd pwa && npm run build -- --outDir "$1" --emptyOutDir >/dev/null 2>&1); }
