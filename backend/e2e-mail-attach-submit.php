<?php
// SPDX-License-Identifier: AGPL-3.0-only
// One signed multipart submission with synthetic files through the PHP SDK for backend/e2e-mail-attachment.sh.
// Usage: php e2e-mail-attach-submit.php CREDENTIALS URL MARKER KEY MODE   -> prints the submission id, then one "sha256 name" line per file
// MODE mid: one file of 3,000,000 bytes; multi: two small files (umlaut and special characters in the names); big: one file of 19,900,000 bytes; over: 19,900,000 + 6,000,000 bytes.
declare(strict_types=1);
foreach (['Exception/FormBackendException', 'Exception/ConfigurationException', 'Exception/InvalidInputException', 'Exception/RejectedException', 'Exception/TransportException', 'Credentials', 'Transport', 'CurlTransport', 'VisitorIp', 'Submission', 'Canonical', 'Client'] as $f) {
    require __DIR__ . '/../sdk/php/src/' . $f . '.php';
}
use FormBackend\Client;
use FormBackend\Credentials;

[, $cred, $url, $marker, $key, $mode] = $argv;
function pdf(int $n, int $seed): string
{
    $d = "%PDF-1.4\nsynthetic $seed\n";
    while (strlen($d) < $n) {
        $d .= random_bytes(min(65536, $n - strlen($d)));
    }
    return $d;
}
$files = match ($mode) {
    'multi' => [['Überweisung Ärzte-äöüß.pdf', pdf(41_000, 1)], ['Befund; Nr 2 (final).pdf', pdf(70_001, 2)]],
    'mid' => [['mittel.pdf', pdf(3_000_000, 6)]],
    'big' => [['antrag.pdf', pdf(19_900_000, 3)]],
    'over' => [['gross.pdf', pdf(19_900_000, 4)], ['zweite-Datei.pdf', pdf(6_000_000, 5)]],
    default => throw new RuntimeException('mode'),
};
$spec = [];
foreach ($files as $i => [$name, $content]) {
    $spec["f$i"] = ['name' => $name, 'content' => $content];
}
$client = new Client($url, Credentials::fromFile($cred), totalTimeoutMs: 120000, maxAttempts: 1);
echo $client->submit(['vorname' => "Vorname-$marker", 'email' => 'erika@example.org', 'anliegen' => "Anliegen-$marker"], $key, $spec)->id, "\n";
foreach ($files as [$name, $content]) {
    echo hash('sha256', $content), ' ', $name, "\n";
}
