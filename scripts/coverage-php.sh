#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# PHP SDK line coverage with pcov. The SDK tests are plain PHP scripts (no PHPUnit), so each script runs in its own
# process with scripts/coverage-php-prepend.php, the per-process results are merged into one JSON file.
#
#   scripts/coverage-php.sh [output.json]      (default: coverage/php/coverage.json; needs the pcov extension)
#
# Only the self-contained tests run (no Swift output needed). form_crypto.php and alt_sdk_vectors.php need
# backend/.build/swift-output.json / fixtures from the Swift run and are therefore not part of this measurement.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
out=${1:-$root/coverage/php/coverage.json}
php -r 'exit(extension_loaded("pcov") ? 0 : 1);' || php -d extension=pcov -r 'exit(extension_loaded("pcov") ? 0 : 1);' \
  || { echo "pcov extension not available (pecl install pcov, or shivammathur/setup-php with coverage: pcov)" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$(dirname "$out")"
for t in sdk_test.php curl_transport_test.php session_failover_test.php; do
  echo "== $t"
  COVERAGE_PHP_DIR=$tmp php -d pcov.enabled=1 -d pcov.directory="$root/sdk/php/src" -d auto_prepend_file="$root/scripts/coverage-php-prepend.php" "$root/sdk/php/tests/$t"
done
python3 - "$tmp" "$out" <<'PY'
import glob, json, sys
merged = {}
for f in glob.glob(sys.argv[1] + '/*.json'):
    for path, lines in json.load(open(f)).items():
        m = merged.setdefault(path, {})
        for ln, hit in lines.items():
            m[ln] = max(m.get(ln, 0), hit)
json.dump(merged, open(sys.argv[2], 'w'))
print(f'merged {len(merged)} files into {sys.argv[2]}')
PY
