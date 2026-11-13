#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
# Native avoids a file-provider FinderInfo/codesign failure in this workspace.
# It is deprecated in Swift 6.4; revisit when integrating the production build.
export FORM_SWIFT_EXPORT="$PWD/backend/.build/swift-output.json"
rm -f "$FORM_SWIFT_EXPORT"
python3 backend/run-with-timeout.py swift test --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native > backend/swift-test.log 2>&1
swift_result=$?
cat backend/swift-test.log
php sdk/php/tests/form_crypto.php > sdk/php/tests/php-test.log 2>&1
php_result=$?
cat sdk/php/tests/php-test.log
printf 'swift test exit code: %s\nPHP exit code: %s\n' "$swift_result" "$php_result" > backend/test-exit-codes.txt
cat backend/test-exit-codes.txt
[ "$swift_result" -eq 0 ] && [ "$php_result" -eq 0 ]
