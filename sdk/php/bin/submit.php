#!/usr/bin/env php
<?php
// SPDX-License-Identifier: AGPL-3.0-only
// Command line submitter for tests and scripts:
//   php bin/submit.php --credentials creds.json --url https://admin.example.org [--key IDEMPOTENCY_KEY] name=value [name2=value2 ...]
// Prints the submission id on success. Exit codes: 0 ok, 1 rejected by the server, 2 transport error, 64 usage/configuration.
declare(strict_types=1);

// Diagnostics belong on stderr: stdout carries only the submission id.
ini_set('display_errors', 'stderr');

spl_autoload_register(static function (string $class): void {
    if (str_starts_with($class, 'FormBackend\\')) {
        $file = __DIR__ . '/../src/' . str_replace('\\', '/', substr($class, 12)) . '.php';
        if (is_file($file)) {
            require $file;
        }
    }
});

use FormBackend\Client;
use FormBackend\Credentials;
use FormBackend\Exception\ConfigurationException;
use FormBackend\Exception\FormBackendException;
use FormBackend\Exception\InvalidInputException;
use FormBackend\Exception\RejectedException;
use FormBackend\Exception\TransportException;

$opts = getopt('', ['credentials:', 'url:', 'key:', 'file:', 'budget-ms:', 'attempts:'], $rest);
$files = [];
foreach ((array)($opts['file'] ?? []) as $spec) {   // --file field=path (repeat the same field for a list)
    $q = strpos((string)$spec, '=');
    if ($q === false || $q === 0) {
        fwrite(STDERR, "usage: --file field=path\n");
        exit(64);
    }
    $f = substr((string)$spec, 0, $q);
    $files[$f][] = substr((string)$spec, $q + 1);
}
foreach ($files as $f => $paths) {
    if (count($paths) === 1) {
        $files[$f] = $paths[0];
    }
}
$query = [];
foreach (array_slice($argv, $rest) as $pair) {
    $p = strpos($pair, '=');
    if ($p === false || $p === 0) {
        fwrite(STDERR, "usage: name=value expected, got an argument without '='\n");
        exit(64);
    }
    $name = substr($pair, 0, $p);
    // PHP would silently rename "a.b" / "a b" while parsing; refuse instead (nested names like list[] and map[k] are fine).
    if (preg_match('/[.\s]/', explode('[', $name, 2)[0]) === 1) {
        fwrite(STDERR, "top-level field names must not contain '.' or whitespace\n");
        exit(64);
    }
    $query[] = $name . '=' . rawurlencode(substr($pair, $p + 1));
}
parse_str(implode('&', $query), $fields);
if (!isset($opts['credentials']) || !is_string($opts['credentials']) || (isset($opts['url']) && !is_string($opts['url']))) {
    fwrite(STDERR, "usage: submit.php --credentials FILE [--url BASE_URL] [--budget-ms 10000] [--attempts 3] [--key KEY] name=value ...\n");
    exit(64);
}
try {
    foreach (['budget-ms', 'attempts'] as $option) {
        if (isset($opts[$option]) && (!is_string($opts[$option]) || !ctype_digit($opts[$option]) || strlen($opts[$option]) > 8)) {
            throw new ConfigurationException('invalid numeric option: ' . $option);
        }
    }
    $client = new Client($opts['url'] ?? null, Credentials::fromFile($opts['credentials']),
        totalTimeoutMs: (int)($opts['budget-ms'] ?? 10000), maxAttempts: (int)($opts['attempts'] ?? 3));
    echo $client->submit($fields, isset($opts['key']) && is_string($opts['key']) ? $opts['key'] : null, $files)->id, "\n";
} catch (ConfigurationException | InvalidInputException $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(64);
} catch (RejectedException $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
} catch (TransportException $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(2);
} catch (FormBackendException $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
}
