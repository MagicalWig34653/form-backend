#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Swift coverage in the Linux CI job: runs backend/ci-linux.sh with code coverage on (scratch dir on the host so the
# SwiftPM codecov JSON, written by `swift test --enable-code-coverage`, survives the container) and copies the JSON
# to coverage/swift/codecov.json. Tests failing still produces the report; the test exit code is passed on.
#
#   scripts/coverage-swift.sh [scratch-dir]
set -u
root=$(cd "$(dirname "$0")/.." && pwd -P)
scratch=${1:-${RUNNER_TEMP:-/tmp}/lin-build}
mkdir -p "$scratch" "$root/coverage/swift"
LINUX_SCRATCH=$scratch bash "$root/backend/ci-linux.sh" --enable-code-coverage
rc=$?
json=$(find "$scratch" -path '*/codecov/*.json' -not -name 'default*' 2>/dev/null | head -n 1)
if [ -n "$json" ]; then
  cp "$json" "$root/coverage/swift/codecov.json"
  echo "coverage JSON: $json"
else
  echo "no codecov JSON found under $scratch" >&2
  [ "$rc" = 0 ] && rc=3
fi
exit "$rc"
