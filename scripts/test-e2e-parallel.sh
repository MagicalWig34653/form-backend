#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Self test: two runs of the same e2e script at the same time (different ports) must both succeed and must not touch each other,
# and afterwards no container/network labelled with their run ids may remain.
#   scripts/test-e2e-parallel.sh                         # backend/e2e-setup.sh, explicit distinct ports
#   E2E_PARALLEL_AUTOPORT=1 scripts/test-e2e-parallel.sh # no ports given: the runs pick free ports themselves
#   E2E_PARALLEL_SCRIPT=backend/<old copy>.sh ...        # RED proof against an old script version (copy it into backend/ first)
# Exit 0 ok, 1 failed. Needs Docker, Swift, Node (like e2e-setup.sh); takes a few minutes.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
SCRIPT=${E2E_PARALLEL_SCRIPT:-backend/e2e-setup.sh}
BASE=$((33800 + RANDOM % 100)); WB=$((4500 + RANDOM % 100))
IDA=par-$$-a; IDB=par-$$-b; TMP=$(mktemp -d); fail=0; seen_both=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
cleanup() {
  for id in "$IDA" "$IDB"; do
    ids=$("$DOCKER" ps -aq --filter "label=e2e.run=$id" 2>/dev/null); [ -n "$ids" ] && "$DOCKER" rm -f $ids >/dev/null 2>&1
    ids=$("$DOCKER" network ls -q --filter "label=e2e.run=$id" 2>/dev/null); [ -n "$ids" ] && "$DOCKER" network rm $ids >/dev/null 2>&1
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
if [ -n "${E2E_PARALLEL_AUTOPORT:-}" ]; then
  E2E_RUN_ID=$IDA bash "$SCRIPT" >"$TMP/a.log" 2>&1 & PA=$!
  E2E_RUN_ID=$IDB bash "$SCRIPT" >"$TMP/b.log" 2>&1 & PB=$!
else
  E2E_RUN_ID=$IDA P3B_PORT=$BASE E2E_PORT=$WB bash "$SCRIPT" >"$TMP/a.log" 2>&1 & PA=$!
  E2E_RUN_ID=$IDB P3B_PORT=$((BASE + 1)) E2E_PORT=$((WB + 3)) bash "$SCRIPT" >"$TMP/b.log" 2>&1 & PB=$!
fi
while kill -0 "$PA" 2>/dev/null || kill -0 "$PB" 2>/dev/null; do
  na=$("$DOCKER" ps -q --filter "label=e2e.run=$IDA" 2>/dev/null | wc -l); nb=$("$DOCKER" ps -q --filter "label=e2e.run=$IDB" 2>/dev/null | wc -l)
  [ "$na" -gt 0 ] && [ "$nb" -gt 0 ] && seen_both=1
  sleep 2
done
wait "$PA"; ra=$?; wait "$PB"; rb=$?
echo "script=$SCRIPT rc_a=$ra rc_b=$rb"
[ "$ra" = 0 ] && ok "run A rc=0" || { bad "run A rc=$ra"; tail -8 "$TMP/a.log"; }
[ "$rb" = 0 ] && ok "run B rc=0" || { bad "run B rc=$rb"; tail -8 "$TMP/b.log"; }
[ "$seen_both" = 1 ] && ok "containers of both runs existed at the same time (labels $IDA / $IDB)" || bad "never saw containers of both runs at the same time"
for id in "$IDA" "$IDB"; do
  c=$("$DOCKER" ps -aq --filter "label=e2e.run=$id" 2>/dev/null | wc -l); n=$("$DOCKER" network ls -q --filter "label=e2e.run=$id" 2>/dev/null | wc -l)
  [ "$c" -eq 0 ] && [ "$n" -eq 0 ] && ok "nothing left for $id" || bad "left for $id: containers=$c networks=$n"
done
exit $fail
