<?php
// SPDX-License-Identifier: AGPL-3.0-only
// Load worker for backend/loadtest.sh. Uses the PHP SDK client; prints one TSV line per request:
//   phase<TAB>key<TAB>outcome<TAB>latency_ms<TAB>submission_id
// Usage: php driver.php CREDENTIALS URL PHASE KEY_PREFIX FROM TO
// Requests use keys KEY_PREFIX-FROM .. KEY_PREFIX-(TO-1). A KEY_PREFIX ending in "=" is one fixed key (race phase).
declare(strict_types=1);
foreach (['Exception/FormBackendException', 'Exception/ConfigurationException', 'Exception/InvalidInputException', 'Exception/RejectedException', 'Exception/TransportException', 'Credentials', 'Transport', 'CurlTransport', 'Submission', 'Canonical', 'Client'] as $f) {
    require __DIR__ . '/../../sdk/php/src/' . $f . '.php';
}
use FormBackend\Client;
use FormBackend\Credentials;
use FormBackend\Exception\RejectedException;
use FormBackend\Exception\TransportException;

[, $cred, $url, $phase, $prefix, $from, $to] = $argv;
$client = new Client($url, Credentials::fromFile($cred), totalTimeoutMs: 15000, maxAttempts: 3);
for ($i = (int)$from; $i < (int)$to; $i++) {
    $key = str_ends_with($prefix, '=') ? substr($prefix, 0, -1) : "$prefix-$i";
    $t = hrtime(true);
    $id = '';
    try {
        $id = $client->submit(['nachricht' => "synthetic load message $key", 'email' => 'load@example.org', 'vorname' => 'Last'], $key)->id;
        $outcome = '200';
    } catch (RejectedException $e) {
        $outcome = (string)$e->status;
    } catch (TransportException $e) {
        $outcome = 'transport';
    } catch (Throwable $e) {
        $outcome = 'error';
    }
    printf("%s\t%s\t%s\t%.1f\t%s\n", $phase, $key, $outcome, (hrtime(true) - $t) / 1e6, $id);
}
