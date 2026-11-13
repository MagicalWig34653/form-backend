#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Guards backend/e2e-*.sh against reporting success after a failed Playwright run.
# 1) Proves the broken pattern: PIPESTATUS after a subshell is the status of `tail`, so a failing run reads as 0.
# 2) Proves the repaired pattern (own status, no pipe) reports the failure.
# 3) Fails if any backend/e2e-*.sh still uses `| tail ...); rc=${PIPESTATUS[0]}`.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
( (false | tail -1); rc=${PIPESTATUS[0]}; [ "$rc" = 0 ] ) && ok "altes Muster liefert 0 trotz Fehler (Beleg des Fehlers)" || bad "altes Muster verhält sich anders als angenommen"
tmp=$(mktemp); ( (false) >"$tmp" 2>&1; rc=$?; [ "$rc" != 0 ] ) && ok "neues Muster meldet den Fehler" || bad "neues Muster meldet Fehler nicht"; rm -f "$tmp"
if grep -nE '\| *tail[^)]*\); *rc=\$\{PIPESTATUS' backend/e2e-*.sh; then bad "altes PIPESTATUS-Muster in backend/e2e-*.sh"; else ok "kein altes PIPESTATUS-Muster in backend/e2e-*.sh"; fi
# 3b) No Playwright run piped into anything (tail/grep): the pipe's status is that of the last command, a failure is hidden.
if grep -nE 'playwright test[^|]*[|][^|]' backend/e2e-*.sh backend/smoke-admin.sh backend/loadtest.sh backend/proxy-probe.sh; then bad "playwright run piped (status hidden) in backend scripts"; else ok "no piped playwright run in backend scripts"; fi
# 4) Unique names: no fixed container/network name in docker run/network/rm, no pre-clean by name, labels set, cleanup by label.
if grep -nE '(--name|network create|network rm|rm -f) +"?(p4a|p4t|p7f|formprobe)-[a-z]' backend/e2e-*.sh backend/smoke-admin.sh backend/loadtest.sh backend/proxy-probe.sh; then bad "fixed container/network name in a script"; else ok "no fixed container/network names"; fi
if grep -nE '^(NAME|LNAME|TNAME|SNAME|PNAME|ANAME|NET|DB|APP|PX)=(\$\{P3B_NAME:-)?(p4a|p4t|p7f|formprobe)-' backend/e2e-*.sh backend/smoke-admin.sh backend/loadtest.sh backend/proxy-probe.sh; then bad "name variable without e2e_name"; else ok "all names built with e2e_name"; fi
for f in backend/e2e-*.sh backend/smoke-admin.sh backend/loadtest.sh backend/proxy-probe.sh; do
  [ "$f" = backend/e2e-common.sh ] && continue
  grep -q 'e2e-common.sh' "$f" || { bad "$f does not source backend/e2e-common.sh"; continue; }
  if grep -E '"\$DOCKER" (run -d|run --rm|network create)' "$f" | grep -qv 'E2E_LABEL_ARGS'; then bad "$f: docker run / network create without E2E_LABEL_ARGS"; fi
  grep -q 'e2e_cleanup' "$f" || bad "$f: cleanup does not use e2e_cleanup"
  grep -qE 'rm -f +"\$(NAME|LNAME|TNAME|SNAME|PNAME|ANAME|DB|APP|PX)"' "$f" && bad "$f: removes containers by name"
done
exit $fail
