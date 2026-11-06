<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

namespace FormBackend;

// Simulate the host's session and headers without cookies, locks or filesystem writes.
function session_status(): int { return $GLOBALS['sessionStatus']; }
function headers_sent(): bool { return $GLOBALS['headersSent']; }
function session_start(): bool {
    $GLOBALS['sessionStarts']++;
    if ($GLOBALS['startSucceeds']) { $GLOBALS['sessionStatus'] = PHP_SESSION_ACTIVE; }
    return $GLOBALS['startSucceeds'];
}
function session_write_close(): bool { throw new \RuntimeException('SDK must not close the host session'); }
function session_commit(): bool { throw new \RuntimeException('SDK must not commit the host session'); }
function session_regenerate_id(): bool { throw new \RuntimeException('SDK must not change the host session'); }

spl_autoload_register(static function (string $c): void {
    if (str_starts_with($c, 'FormBackend\\')) {
        require __DIR__ . '/../src/' . str_replace('\\', '/', substr($c, 12)) . '.php';
    }
});
$failures = 0; $passed = 0;
function ok(bool $condition, string $label): void {
    global $failures, $passed;
    if ($condition) { $passed++; } else { $failures++; fwrite(STDERR, "FAIL $label\n"); }
}
function throws(string $class, callable $fn, string $label): void {
    try { $fn(); } catch (\Throwable $e) { ok($e instanceof $class, $label); return; }
    ok(false, $label);
}
function b64u(string $value): string { return rtrim(strtr(base64_encode($value), '+/', '-_'), '='); }
$seed = str_repeat("\x42", 32);
$pub = sodium_crypto_sign_publickey(sodium_crypto_sign_seed_keypair($seed));
$formId = '0000000a-0000-4000-8000-0000000000fb';
$data = ['formId' => $formId, 'signingSeed' => b64u($seed), 'signingPublicKey' => b64u($pub),
    'endpoints' => ['https://primary.example', 'https://backup.example']];
$creds = Credentials::fromArray(array_diff_key($data, ['endpoints' => true]));
$data['endpointSignature'] = b64u($creds->sign("KUBUS-SDK-CONFIG-V1\n$formId\n" . implode("\n", $data['endpoints'])));
$multi = Credentials::fromArray($data);
$accepted = ['status' => 200, 'headers' => [], 'body' => '{"submission":{"id":"11111111-2222-4333-8444-555555555555"}}'];

final class TimedFake implements Transport {
    public array $requests = [];
    public function __construct(public array $answers) {}
    public function post(string $url, string $body, array $headers, int $timeoutMs): array {
        $this->requests[] = compact('url', 'body', 'headers', 'timeoutMs');
        $answer = array_shift($this->answers);
        if ($answer instanceof \Throwable) {
            $GLOBALS['elapsedMs'] += $timeoutMs;
            throw $answer;
        }
        return $answer;
    }
}
function resetHost(int $status = PHP_SESSION_ACTIVE, bool $headers = false): void {
    $GLOBALS['sessionStatus'] = $status;
    $GLOBALS['headersSent'] = $headers;
    $GLOBALS['sessionStarts'] = 0;
    $GLOBALS['startSucceeds'] = true;
    $GLOBALS['elapsedMs'] = 0;
    $GLOBALS['wallTime'] = 1000;
    $_SESSION = ['host_data' => ['unchanged' => true]];
}
function sessionClient(Transport $transport, array $options = []): Client {
    global $multi;
    return new Client(null, $multi, $transport, ...(['clock' => fn() => $GLOBALS['wallTime'],
        'monotonicClock' => fn() => $GLOBALS['elapsedMs']] + $options));
}
function isPrimary(array $request): bool { return str_starts_with($request['url'], 'https://primary.example/'); }
function marker(): array { return array_values($_SESSION['kubus_form_failover'] ?? [])[0] ?? []; }

resetHost();
$t = new TimedFake([new Exception\TransportException('timeout'), $accepted, $accepted, $accepted]);
sessionClient($t)->submit(['a' => 'same'], 'same');
ok($GLOBALS['elapsedMs'] === 3000 && $t->requests[0]['timeoutMs'] === 3000, 'first primary timeout bounded at 3 seconds');
ok(isPrimary($t->requests[0]) && !isPrimary($t->requests[1]), 'first request falls back');
ok($t->requests[0]['body'] === $t->requests[1]['body'] && $t->requests[0]['headers'] === $t->requests[1]['headers'], 'session failover preserves signed bytes');
ok(marker() === ['timestamp' => 1000, 'endpoint' => 0], 'marker contains timestamp and index only');
$originalMarker = $_SESSION['kubus_form_failover'];
sessionClient($t)->submit([]); // A new SDK instance, same host session.
ok(count($t->requests) === 3 && !isPrimary($t->requests[2]) && $GLOBALS['elapsedMs'] === 3000, 'second request directly uses backup without timeout across clients');
ok($_SESSION['kubus_form_failover'] === $originalMarker, 'backup success does not extend TTL');
$GLOBALS['wallTime'] = 1060;
sessionClient($t)->submit([]);
ok(isPrimary($t->requests[3]) && marker() === [], 'at TTL primary returns and success clears marker');
ok($_SESSION['host_data'] === ['unchanged' => true] && $GLOBALS['sessionStarts'] === 0 && session_status() === PHP_SESSION_ACTIVE, 'host session unchanged and left active');

// A successful primary reached after a failed backup also removes a still-valid marker.
resetHost();
$t = new TimedFake([new Exception\TransportException('timeout'), $accepted,
    new Exception\TransportException('backup timeout'), $accepted]);
sessionClient($t)->submit([]);
sessionClient($t)->submit([]);
ok(!isPrimary($t->requests[2]) && isPrimary($t->requests[3]) && marker() === [], 'primary recovery clears valid marker');

foreach ([PHP_SESSION_NONE, PHP_SESSION_DISABLED] as $status) {
    resetHost($status);
    $t = new TimedFake([new Exception\TransportException('timeout'), $accepted, new Exception\TransportException('timeout'), $accepted]);
    $c = sessionClient($t);
    $c->submit([]); $c->submit([]);
    ok(isPrimary($t->requests[0]) && isPrimary($t->requests[2]) && marker() === [] && $GLOBALS['sessionStarts'] === 0, 'inactive session stays stateless status ' . $status);
}
resetHost(PHP_SESSION_NONE, true);
sessionClient(new TimedFake([$accepted]), ['sessionStart' => true])->submit([]);
ok($GLOBALS['sessionStarts'] === 0 && session_status() === PHP_SESSION_NONE, 'headers sent prevents opt-in session start');
resetHost(PHP_SESSION_NONE);
sessionClient(new TimedFake([new Exception\TransportException('timeout'), $accepted]), ['sessionStart' => true])->submit([]);
ok($GLOBALS['sessionStarts'] === 1 && session_status() === PHP_SESSION_ACTIVE && marker() !== [], 'opt-in session start before headers supports marker');
resetHost(PHP_SESSION_NONE);
$GLOBALS['startSucceeds'] = false;
sessionClient(new TimedFake([$accepted]), ['sessionStart' => true])->submit([]);
ok($GLOBALS['sessionStarts'] === 1 && marker() === [], 'failed session start falls back to stateless');
resetHost(PHP_SESSION_DISABLED);
sessionClient(new TimedFake([$accepted]), ['sessionStart' => true])->submit([]);
ok($GLOBALS['sessionStarts'] === 0, 'disabled sessions never started');
resetHost(PHP_SESSION_ACTIVE, true);
sessionClient(new TimedFake([new Exception\TransportException('timeout'), $accepted]), ['sessionStart' => true])->submit([]);
ok($GLOBALS['sessionStarts'] === 0 && marker() !== [], 'active session usable after headers without restart');

resetHost();
$t = new TimedFake([new Exception\TransportException('timeout'), $accepted, $accepted]);
$c = sessionClient($t, ['connectTimeout' => 0.25, 'totalBudget' => 2.0, 'failoverTtl' => 5]);
$c->submit([]);
ok($GLOBALS['elapsedMs'] === 250 && $t->requests[1]['timeoutMs'] <= 1750, 'custom timeout and total budget enforced');
$GLOBALS['wallTime'] += 5; $c->submit([]);
ok(isPrimary($t->requests[2]), 'custom TTL expires');

// Untrusted marker contents can affect ordering only, never the verified endpoint list.
foreach ([['timestamp' => 1000, 'endpoint' => 'https://evil.example'], ['timestamp' => '1000', 'endpoint' => 0],
    ['timestamp' => 1001, 'endpoint' => 0], ['timestamp' => 900, 'endpoint' => 0]] as $badMarker) {
    resetHost();
    sessionClient(new TimedFake([new Exception\TransportException('timeout'), $accepted]))->submit([]);
    $key = array_key_first($_SESSION['kubus_form_failover']);
    $_SESSION['kubus_form_failover'][$key] = $badMarker;
    $t = new TimedFake([$accepted]); sessionClient($t)->submit([]);
    ok(isPrimary($t->requests[0]), 'invalid/future/expired marker ignored');
}
resetHost();
sessionClient(new TimedFake([new Exception\TransportException('timeout'), $accepted]))->submit([]);
$data2 = $data; $data2['endpoints'] = ['https://other.example', 'https://backup.example'];
$data2['endpointSignature'] = b64u($creds->sign("KUBUS-SDK-CONFIG-V1\n$formId\n" . implode("\n", $data2['endpoints'])));
$t = new TimedFake([$accepted]);
(new Client(null, Credentials::fromArray($data2), $t))->submit([]);
ok(str_starts_with($t->requests[0]['url'], 'https://other.example/'), 'marker scoped to configuration');

foreach ([400, 429, 500] as $status) {
    resetHost();
    $t = new TimedFake([['status' => $status, 'headers' => [], 'body' => '']]);
    throws(Exception\RejectedException::class, fn() => sessionClient($t)->submit([]), 'terminal response with active session');
    ok(marker() === [] && count($t->requests) === 1, 'terminal response creates no marker');
}
resetHost();
$t = new TimedFake([new Exception\TransportException('certificate', false)]);
throws(Exception\TransportException::class, fn() => sessionClient($t)->submit([]), 'terminal transport failure');
ok(marker() === [], 'terminal transport failure creates no marker');
foreach ([502, 503, 504] as $status) {
    resetHost();
    sessionClient(new TimedFake([['status' => $status, 'headers' => [], 'body' => ''], $accepted]))->submit([]);
    ok(marker() !== [], 'gateway failure creates marker ' . $status);
}
foreach ([['connectTimeout' => 0], ['connectTimeout' => INF], ['totalBudget' => NAN], ['totalBudget' => 0], ['failoverTtl' => 0]] as $badOptions) {
    throws(Exception\ConfigurationException::class, fn() => sessionClient(new TimedFake([]), $badOptions), 'invalid timing configuration');
}
resetHost();
$_SESSION['kubus_form_failover'] = 'host-owned';
sessionClient(new TimedFake([new Exception\TransportException('timeout'), $accepted]))->submit([]);
ok($_SESSION['kubus_form_failover'] === 'host-owned', 'unexpected namespace value preserved');
echo "Session failover: $passed passed, $failures failed\n";
exit($failures ? 1 : 0);
