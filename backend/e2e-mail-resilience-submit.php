<?php
// SPDX-License-Identifier: AGPL-3.0-only
// One signed submission through the PHP SDK for backend/e2e-mail-resilience.sh (synthetic data only).
// Usage: php -d memory_limit=1G e2e-mail-resilience-submit.php CREDENTIALS URL MARKER KEY MODE [BYTES]
// Prints: line 1 the submission id, line 2 "pauses N" (how often the SDK waited for a Retry-After of a busy 503), line 3 "http <status>@<seconds>,..." (every HTTP answer the SDK saw), then "sha256 name" per file.
// MODE busy:  one file of BYTES bytes, up to 12 attempts within 5 minutes (waits for ingest_busy / body_budget_exhausted).
//      field: the field "anliegen" carries a value of 11 MiB (more than the 10 MiB mail limit), no file.
//      abort: like busy (deterministic file of BYTES bytes, same key and bytes as "retry") but ONE attempt with a client timeout of TIMEOUT_MS (argv 7): emulates an old SDK
//             that gives up while its request waits in the server's body-budget queue. Prints "aborted" (line 1) and the HTTP log (line 2), or the id lines when the server answered in time.
//      retry: the same submission (same key, same bytes) with a generous budget; the result must be the one and only submission.
//      files: two files (umlaut name, 41,000 and 3,000,001 bytes), the normal retry budget.
declare(strict_types=1);
foreach (['Exception/FormBackendException', 'Exception/ConfigurationException', 'Exception/InvalidInputException', 'Exception/RejectedException', 'Exception/TransportException', 'Credentials', 'Transport', 'CurlTransport', 'VisitorIp', 'Submission', 'Canonical', 'Client'] as $f) {
    require __DIR__ . '/../sdk/php/src/' . $f . '.php';
}
use FormBackend\Client;
use FormBackend\Credentials;
use FormBackend\CurlTransport;
use FormBackend\Transport;

/** Records every HTTP exchange of the SDK (status and duration) so the E2E can prove which answers the SDK really saw. */
final class RecordingTransport implements Transport
{
    /** @var list<string> */
    public array $log = [];
    private CurlTransport $inner;
    public function __construct()
    {
        $this->inner = new CurlTransport();
    }
    public function post(string $url, string $body, array $headers, int $timeoutMs): array
    {
        $t = microtime(true);
        try {
            $res = $this->inner->post($url, $body, $headers, $timeoutMs);
            $this->log[] = $res['status'] . '@' . round(microtime(true) - $t, 1) . 's';
            return $res;
        } catch (\Throwable $e) {
            $this->log[] = 'ERR@' . round(microtime(true) - $t, 1) . 's';
            throw $e;
        }
    }
}

[, $cred, $url, $marker, $key, $mode] = $argv;
$bytes = (int)($argv[6] ?? 0);
function pdf(int $n, int $seed): string
{
    $d = "%PDF-1.4\nsynthetic $seed\n";
    while (strlen($d) < $n) {
        $d .= random_bytes(min(65536, $n - strlen($d)));
    }
    return $d;
}
function detPdf(int $n, string $seed): string
{
    $d = "%PDF-1.4\nsynthetic $seed\n";
    $block = hash('sha256', $seed, true);
    while (strlen($d) < $n) {
        $block = hash('sha512', $block, true);
        $d .= substr($block, 0, min(64, $n - strlen($d)));
    }
    return $d;
}
$fields = ['vorname' => "Vorname-$marker", 'email' => 'erika@example.org', 'anliegen' => "Anliegen-$marker"];
$files = [];
$pauses = 0;
$transport = new RecordingTransport();
$count = function (int $microseconds) use (&$pauses): void {
    $pauses++;
    usleep($microseconds);
};
switch ($mode) {
    case 'busy':
        $files = [["busy-$marker.pdf", pdf($bytes, crc32($marker))]];
        $client = new Client($url, Credentials::fromFile($cred), $transport, sleep: $count, totalTimeoutMs: 300000, maxAttempts: 12);
        break;
    case 'abort':
    case 'retry':
        $files = [["budget-$marker.pdf", detPdf($bytes, $marker)]];
        $abort = $mode === 'abort';
        $client = new Client($url, Credentials::fromFile($cred), $transport, sleep: $count, totalTimeoutMs: $abort ? (int)$argv[7] : 120000, maxAttempts: $abort ? 1 : 5);
        break;
    case 'field':
        $fields['anliegen'] = "Anliegen-$marker-" . str_repeat('x', 11 * 1024 * 1024);
        $client = new Client($url, Credentials::fromFile($cred), $transport, sleep: $count, maxBodyBytes: 32 * 1024 * 1024, totalTimeoutMs: 120000, maxAttempts: 3);
        break;
    case 'files':
        $files = [['Überweisung Ärzte-äöüß.pdf', pdf(41_000, 11)], ['Befund-groß.pdf', pdf(3_000_001, 12)]];
        $client = new Client($url, Credentials::fromFile($cred), $transport, sleep: $count, totalTimeoutMs: 120000, maxAttempts: 3);
        break;
    default:
        throw new RuntimeException('mode');
}
$spec = [];
foreach ($files as $i => [$name, $content]) {
    $spec["f$i"] = ['name' => $name, 'content' => $content];
}
try {
    $id = $client->submit($fields, $key, $spec)->id;
} catch (\FormBackend\Exception\TransportException | \FormBackend\Exception\RejectedException $e) {   // timeout, or (bodies < 4 MiB, no wait window) an immediate 503
    if ($mode !== 'abort') { throw $e; }
    echo "aborted\n", "http ", implode(',', $transport->log), "\n";
    exit(0);
}
echo $id, "\n", "pauses $pauses", "\n", "http ", implode(',', $transport->log), "\n";
foreach ($files as [$name, $content]) {
    echo hash('sha256', $content), ' ', $name, "\n";
}
