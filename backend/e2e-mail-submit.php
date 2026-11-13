<?php
// SPDX-License-Identifier: AGPL-3.0-only
// One signed submission through the PHP SDK for backend/e2e-mail-standard.sh (synthetic marker values).
// Usage: php e2e-mail-submit.php CREDENTIALS URL MARKER KEY   -> prints the submission id
declare(strict_types=1);
foreach (['Exception/FormBackendException', 'Exception/ConfigurationException', 'Exception/InvalidInputException', 'Exception/RejectedException', 'Exception/TransportException', 'Credentials', 'Transport', 'CurlTransport', 'Submission', 'Canonical', 'Client'] as $f) {
    require __DIR__ . '/../sdk/php/src/' . $f . '.php';
}
use FormBackend\Client;
use FormBackend\Credentials;

[, $cred, $url, $marker, $key] = $argv;
$client = new Client($url, Credentials::fromFile($cred), totalTimeoutMs: 15000, maxAttempts: 3);
echo $client->submit(['vorname' => "Vorname-$marker", 'email' => 'erika@example.org', 'anliegen' => "Anliegen-$marker"], $key)->id, "\n";
