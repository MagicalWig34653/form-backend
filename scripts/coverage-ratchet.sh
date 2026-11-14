#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Coverage ratchet: fails when a measured value drops below the committed baseline (scripts/coverage-baseline.json,
# minus the per-metric tolerance for run-to-run noise). The baseline only ever moves up (--update never lowers a value).
#
#   scripts/coverage-ratchet.sh <swift|pwa|php> <coverage-input> [--update] [--diff-base <git-ref>]
#
# Inputs: swift = SwiftPM codecov JSON, pwa = pwa/coverage/lcov.info, php = merged JSON from scripts/coverage-php.sh.
# --diff-base additionally requires >= 90 % coverage of changed executable lines (only for pwa and php; Swift's
# line mapping from llvm-cov segments is approximate, so it is reported but does not fail the run).
# A baseline value of null means "not measured yet": the value is reported, nothing is enforced.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
kind=${1:?kind (swift|pwa|php)}; input=${2:?coverage input file}; shift 2
update=0; base=""
while [ $# -gt 0 ]; do
  case $1 in
    --update) update=1 ;;
    --diff-base) base=${2:?ref}; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
baseline="$here/coverage-baseline.json"
[ -f "$input" ] || { echo "coverage input missing: $input" >&2; exit 2; }
python3 "$here/coverage-tool.py" exclusions-check >/dev/null || { python3 "$here/coverage-tool.py" exclusions-check; exit 1; }

measured=$(python3 "$here/coverage-tool.py" metrics "$kind" "$input")
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; return 0; }

rc=0
table=$(python3 - "$kind" "$baseline" "$measured" "$update" <<'PY'
import json, sys
kind, path, measured, update = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4] == '1'
doc = json.load(open(path))
entry = doc[kind]
tol = doc.get('tolerance', 0.2)
fail = False
rows = []
for metric in [k for k in entry if k in measured]:
    cur, base = measured[metric], entry[metric]
    if base is None:
        rows.append((metric, cur, None, 'not enforced (no baseline yet)'))
        continue
    ok = cur >= base - tol
    rows.append((metric, cur, base, 'ok' if ok else 'BELOW BASELINE'))
    fail |= not ok
    if update and cur > base:
        entry[metric] = cur
if update:
    for metric in entry:
        if entry[metric] is None and metric in measured:
            entry[metric] = measured[metric]
    json.dump(doc, open(path, 'w'), indent=2)
    open(path, 'a').write('\n')
out = [f'### Coverage ratchet: {kind}', '', '| metric | measured % | baseline % | result |', '|---|---|---|---|']
out += [f'| {m} | {c} | {"-" if b is None else b} | {r} |' for m, c, b, r in rows]
print('\n'.join(out))
sys.exit(1 if fail else 0)
PY
) || rc=$?
echo "$table"; summary "$table"
text=$(python3 - "$kind" "$baseline" "$measured" <<'PY'
import json, sys
kind, path, measured = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
print(f"{kind}: {measured['lines_covered']}/{measured['lines_total']} lines in {measured['files']} files")
PY
)
echo "$text"
summary "$text"

if [ -n "$base" ]; then
  dmin=$(python3 -c "import json;print(json.load(open('$baseline')).get('diff_min',90))")
  drc=0
  python3 "$here/coverage-tool.py" diff "$kind" "$input" "$base" --min "$dmin" || drc=$?
  if [ "$drc" != 0 ]; then
    if [ "$kind" = swift ]; then echo "note: Swift diff coverage is advisory (approximate line mapping)"; else rc=1; fi
  fi
fi
if [ "$rc" != 0 ]; then echo "coverage ratchet FAILED for $kind" >&2; fi
exit "$rc"
