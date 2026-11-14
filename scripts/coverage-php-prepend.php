<?php
// SPDX-License-Identifier: AGPL-3.0-only
// auto_prepend_file for PHP coverage runs (see scripts/coverage-php.sh): collects pcov data of the script under test and
// writes it to $COVERAGE_PHP_DIR/<pid>.json as {file: {line: hits}} when the process ends (also after exit()).
declare(strict_types=1);

if (!function_exists('pcov\\start') || !($dir = getenv('COVERAGE_PHP_DIR'))) {
    return;
}
\pcov\start();
register_shutdown_function(static function () use ($dir): void {
    \pcov\stop();
    $out = [];
    // \pcov\all is restricted to sdk/php/src by -d pcov.directory (coverage-php.sh); \pcov\inclusive would need a list of files, not a directory
    foreach (\pcov\collect(\pcov\all) as $file => $lines) {
        foreach ($lines as $line => $hit) {
            // pcov: 1 = executed, -1 = executable but not executed, 0 = dead code
            if ($hit !== 0) {
                $out[$file][$line] = $hit > 0 ? 1 : 0;
            }
        }
    }
    file_put_contents($dir . '/' . getmypid() . '.json', json_encode($out, JSON_FORCE_OBJECT));
});
