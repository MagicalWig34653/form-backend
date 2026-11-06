<?php
// SPDX-License-Identifier: AGPL-3.0-only
// Unit tests of the PHP SDK with a fake transport (no network). Run: php sdk/php/tests/sdk_test.php
declare(strict_types=1);

spl_autoload_register(static function (string $c): void {
    if (str_starts_with($c, 'FormBackend\\')) { $f = __DIR__ . '/../src/' . str_replace('\\', '/', substr($c, 12)) . '.php'; if (is_file($f)) require $f; }
});

use FormBackend\{Canonical, Client, Credentials, Submission, Transport};
use FormBackend\Exception\{ConfigurationException, InvalidInputException, RejectedException, TransportException};

$failures = 0; $passed = 0;
function ok(bool $cond, string $label): void { global $failures, $passed; if ($cond) { $passed++; return; } $failures++; fwrite(STDERR, "FAIL $label\n"); }
function throws(string $class, callable $fn, string $label): ?Throwable { try { $fn(); } catch (Throwable $e) { ok($e instanceof $class, "$label (got " . $e::class . ')'); return $e; } ok(false, "$label (no exception)"); return null; }
function b64u(string $s): string { return rtrim(strtr(base64_encode($s), '+/', '-_'), '='); }

$seed = str_repeat("\x42", 32);
$pub = sodium_crypto_sign_publickey(sodium_crypto_sign_seed_keypair($seed));
$formId = '0000000a-0000-4000-8000-0000000000fb';
$creds = Credentials::fromArray(['formId' => $formId, 'signingSeed' => b64u($seed), 'signingPublicKey' => b64u($pub)]);
$UUID = '/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/';

/** Records every request; answers from a queue (arrays are responses, Throwables are thrown). */
final class Fake implements Transport {
    /** @var list<array{url:string,body:string,headers:array<string,string>}> */ public array $requests = [];
    /** @param list<array|Throwable> $answers */ public function __construct(public array $answers) {}
    public function post(string $url, string $body, array $headers, int $timeoutMs): array {
        $this->requests[] = ['url' => $url, 'body' => $body, 'headers' => $headers, 'timeoutMs' => $timeoutMs];
        $a = array_shift($this->answers) ?? ['status' => 500, 'headers' => [], 'body' => ''];
        if ($a instanceof Throwable) throw $a;
        return $a;
    }
}
$accepted = ['status' => 200, 'headers' => [], 'body' => '{"submission":{"id":"11111111-2222-4333-8444-555555555555"}}'];
$noSleep = static function (int $us): void {};

// --- canonical form: byte-identical to the contract's examples (also checked against the Swift server in the live test)
$c = Canonical::build(['b' => '2', 'a' => '1']);
ok($c['canonical'] === '{"fields":{"a":"1","b":"2"},"files":[]}', 'canonical sorted keys');
ok($c['body'] === 'b=2&a=1', 'body keeps caller order');
ok(Canonical::build([])['canonical'] === '{"fields":[],"files":[]}', 'empty fields are a JSON list like PHP');
$n = Canonical::build(['z' => 'Grüße / 🌍', 'list' => ['b', 'a'], 'map' => ['y' => '1', 'x' => '2'], 'n' => 7]);
ok($n['canonical'] === '{"fields":{"list":["b","a"],"map":{"x":"2","y":"1"},"n":"7","z":"Grüße / 🌍"},"files":[]}', 'canonical nested, unicode and slashes unescaped');
ok(Canonical::build(['k' => [2 => 'two', 0 => 'zero']])['canonical'] === '{"fields":{"k":{"0":"zero","2":"two"}},"files":[]}', 'sparse integer keys sort as strings');
ok(Canonical::build(['t' => "a\0b\n"])['canonical'] === '{"fields":{"t":"a\u0000b\n"},"files":[]}', 'control characters are escaped');

// --- input refusals: nothing may be silently altered
foreach ([['a.b' => '1'], ['a b' => '1'], ['a[b]' => '1'], ['' => '1'], ['ok' => null], ['ok' => true], ['ok' => 1.5], ['ok' => "\xff"], ["na\xffme" => '1'], ['ok' => new stdClass()], ["n\0" => '1']] as $i => $bad) {
    throws(InvalidInputException::class, fn() => Canonical::build($bad), "refused input #$i");
}
throws(InvalidInputException::class, fn() => Canonical::build(array_fill(0, 1001, 'x')), 'more than 1000 variables');
throws(InvalidInputException::class, fn() => Canonical::build(['a' => str_repeat('x', 100)], 50), 'body limit');
$deep = 'x'; for ($i = 0; $i < 70; $i++) $deep = [$deep];
throws(InvalidInputException::class, fn() => Canonical::build(['d' => $deep]), 'nesting depth');

// --- request shape and signature (verified with libsodium against the PUBLIC key only)
$t = new Fake([$accepted]);
$client = new Client('https://admin.example.org/', $creds, $t, sleep: $noSleep, clock: fn() => 1793012400);
$s = $client->submit(['nachricht' => 'Grüße / Test', 'name' => 'Beispiel'], 'key-1');
ok($s->id === '11111111-2222-4333-8444-555555555555', 'submission id');
$r = $t->requests[0];
ok($r['url'] === "https://admin.example.org/api/v2/submit/?f=$formId", 'url');
ok($r['headers']['Idempotency-Key'] === 'key-1' && $r['headers']['Content-Type'] === 'application/x-www-form-urlencoded', 'headers');
$canon = Canonical::build(['nachricht' => 'Grüße / Test', 'name' => 'Beispiel'])['canonical'];
$text = "KUBUS-V2\nPOST\n/api/v2/submit/?f=$formId\n1793012400\n" . hash('sha256', $canon);
$sig = base64_decode($r['headers']['X-Kubus-Signature'], true);
ok($sig !== false && strlen($sig) === 64 && sodium_crypto_sign_verify_detached($sig, $text, $pub), 'signature verifies over the contract signing text');
ok(!sodium_crypto_sign_verify_detached($sig, $text . 'x', $pub), 'signature does not verify for other text');
ok($r['headers']['X-Kubus-Timestamp'] === '1793012400', 'timestamp header');
parse_str($r['body'], $got);
ok($got === ['nachricht' => 'Grüße / Test', 'name' => 'Beispiel'], 'body round-trips through parse_str');
ok(!str_contains(json_encode($r['headers']), $seed) && !str_contains($r['body'], b64u($seed)), 'seed never leaves');

// --- generated idempotency keys are unique and well formed
$t2 = new Fake([$accepted, $accepted]);
$c2 = new Client('https://h.example', $creds, $t2, sleep: $noSleep);
$c2->submit(['a' => '1']); $c2->submit(['a' => '1']);
$k1 = $t2->requests[0]['headers']['Idempotency-Key']; $k2 = $t2->requests[1]['headers']['Idempotency-Key'];
ok($k1 !== $k2 && preg_match('/\A[0-9a-f]{32}\z/', $k1) === 1, 'fresh random idempotency key per call');
foreach (['', str_repeat('k', 191), "a b", "k\n"] as $badKey) throws(ConfigurationException::class, fn() => $c2->submit(['a' => '1'], $badKey), 'bad idempotency key');

// --- retries: identical request, only for transport errors / 502-504
$tick = 1793012400;
$t3 = new Fake([new TransportException('x'), ['status' => 503, 'headers' => ['retry-after' => '1'], 'body' => ''], $accepted]);
$sleeps = [];
$c3 = new Client('https://h.example', $creds, $t3, sleep: function (int $us) use (&$sleeps) { $sleeps[] = $us; }, clock: function () use (&$tick) { return $tick++; });
$res = $c3->submit(['a' => '1']);
ok($res->id !== '' && count($t3->requests) === 3, 'succeeds on the third attempt');
ok(count(array_unique(array_column(array_column($t3->requests, 'headers'), 'Idempotency-Key'))) === 1, 'same idempotency key on every attempt');
ok(count(array_unique(array_column(array_column($t3->requests, 'headers'), 'X-Kubus-Signature'))) === 1, 'identical timestamp and signature per attempt');
ok(count($sleeps) === 0, 'immediate failover without budget-consuming sleep');
$t4 = new Fake([new TransportException('a'), new TransportException('b'), new TransportException('c')]);
throws(TransportException::class, fn() => (new Client('https://h.example', $creds, $t4, sleep: $noSleep))->submit(['a' => '1']), 'transport error after all attempts');
ok(count($t4->requests) === 3, 'three attempts');

// --- server refusals: mapped, never retried when permanent
foreach ([403 => 'signature', 404 => 'unknown or inactive form', 409 => 'idempotency', 413 => 'too large', 415 => 'content type', 422 => 'refused'] as $status => $needle) {
    $tt = new Fake([['status' => $status, 'headers' => [], 'body' => '{"code":"some_code","message":"secret detail"}']]);
    $e = throws(RejectedException::class, fn() => (new Client('https://h.example', $creds, $tt, sleep: $noSleep))->submit(['a' => '1']), "HTTP $status");
    ok($e instanceof RejectedException && $e->status === $status && $e->errorCode === 'some_code' && !$e->isRetryable() && count($tt->requests) === 1 && str_contains($e->getMessage(), $needle), "HTTP $status mapping");
    ok($e !== null && !str_contains($e->getMessage(), 'secret detail'), "HTTP $status message does not echo server text");
}
$t5 = new Fake([['status' => 429, 'headers' => ['retry-after' => '99999'], 'body' => ''], ['status' => 429, 'headers' => [], 'body' => ''], ['status' => 429, 'headers' => [], 'body' => '']]);
$e = throws(RejectedException::class, fn() => (new Client('https://h.example', $creds, $t5, sleep: $noSleep))->submit(['a' => '1']), '429 stops immediately');
ok($e instanceof RejectedException && !$e->isRetryable() && count($t5->requests) === 1, '429 never retried');
$t6 = new Fake([['status' => 429, 'headers' => ['retry-after' => '7'], 'body' => '{"code":"ingest_rate_limited"}'], $accepted]);
$e = throws(RejectedException::class, fn() => (new Client('https://h.example', $creds, $t6, sleep: $noSleep))->submit(['a' => '1']), 'ingest budget 429 surfaces');
ok($e instanceof RejectedException && $e->isRetryable() && $e->retryAfter === 7 && $e->errorCode === 'ingest_rate_limited' && count($t6->requests) === 1, 'ingest_rate_limited is retryable by the caller after Retry-After, not immediately');
foreach (['', 'not json', '{"submission":{"id":"x"}}', '{"submission":{}}', '[]'] as $badBody) {
    throws(\FormBackend\Exception\FormBackendException::class, fn() => Submission::fromResponse($badBody), 'unexpected 200 body');
}

// --- base URL rules
foreach (['http://admin.example.org', 'ftp://x', 'https://', 'https://u:p@h.example', 'https://h.example?x=1', 'https://h.example#f', 'h.example', ''] as $u) {
    throws(ConfigurationException::class, fn() => new Client($u, $creds, new Fake([])), "base URL refused: $u");
}
foreach (['http://localhost:8080', 'http://127.0.0.1:1', 'https://h.example/prefix/'] as $u) { new Client($u, $creds, new Fake([])); ok(true, "base URL accepted: $u"); }
$tp = new Fake([$accepted]); (new Client('https://h.example/prefix', $creds, $tp))->submit(['a' => '1']);
ok($tp->requests[0]['url'] === "https://h.example/prefix/api/v2/submit/?f=$formId", 'prefix is kept, signing path stays /api/v2/submit');

// --- credentials: validation and secrecy
foreach ([['formId' => 'X'], ['formId' => strtoupper($formId)], ['formId' => $formId, 'signingSeed' => 'AAAA', 'signingPublicKey' => b64u($pub)],
          ['formId' => $formId, 'signingSeed' => b64u($seed) . '=', 'signingPublicKey' => b64u($pub)],
          ['formId' => $formId, 'signingSeed' => b64u(str_repeat("\x43", 32)), 'signingPublicKey' => b64u($pub)]] as $i => $bad) {
    throws(ConfigurationException::class, fn() => Credentials::fromArray($bad), "bad credentials #$i");
}
ok(!str_contains(print_r($creds, true) . var_export($creds, true) . json_encode($creds), b64u($seed)), 'seed hidden from print_r/var_export/json');
ob_start(); var_dump($creds); $dump = ob_get_clean();
ok(!str_contains($dump, b64u($seed)), 'seed hidden from var_dump');
$dir = sys_get_temp_dir() . '/sdk-' . bin2hex(random_bytes(4)); mkdir($dir, 0700);
$file = $dir . '/c.json';
file_put_contents($file, json_encode(['formId' => $formId, 'signingSeed' => b64u($seed), 'signingPublicKey' => b64u($pub)]));
chmod($file, 0644);
throws(ConfigurationException::class, fn() => Credentials::fromFile($file), 'world-readable credentials file refused');
chmod($file, 0600);
ok(Credentials::fromFile($file)->formId === $formId, 'credentials file accepted with mode 600');
file_put_contents($file, '{broken'); chmod($file, 0600);
throws(ConfigurationException::class, fn() => Credentials::fromFile($file), 'invalid JSON refused');
throws(ConfigurationException::class, fn() => Credentials::fromFile($dir . '/missing.json'), 'missing file refused');
array_map('unlink', glob($dir . '/*')); rmdir($dir);

// Signed failover configuration, including tamper rejection and replay identity.
$endpoints = ['https://primary.example', 'https://backup.example'];
$data = ['formId' => $formId, 'signingSeed' => b64u($seed), 'signingPublicKey' => b64u($pub), 'endpoints' => $endpoints];
$data['endpointSignature'] = b64u($creds->sign("KUBUS-SDK-CONFIG-V1\n$formId\n" . implode("\n", $endpoints)));
$multi = Credentials::fromArray($data);
$bad = $data; $bad['endpoints'][1] = 'https://evil.example';
throws(ConfigurationException::class, fn() => Credentials::fromArray($bad), 'modified endpoint refused');
$bad = $data; $bad['endpoints'] = array_reverse($endpoints);
throws(ConfigurationException::class, fn() => Credentials::fromArray($bad), 'modified order refused');
throws(ConfigurationException::class, fn() => new Client($endpoints, $creds), 'unsigned list refused');
throws(ConfigurationException::class, fn() => new Client('https://evil.example', $multi), 'signed configuration override refused');
$t = new Fake([new TransportException('down'), $accepted, $accepted]);
$c = new Client(null, $multi, $t);
$c->submit(['a' => '1'], 'stable'); $c->submit(['a' => '2']);
ok(str_starts_with($t->requests[1]['url'], $endpoints[1]), 'primary down uses backup');
ok(str_starts_with($t->requests[2]['url'], $endpoints[0]), 'next call starts at primary');
ok($t->requests[0]['body'] === $t->requests[1]['body'] && $t->requests[0]['headers'] === $t->requests[1]['headers'], 'identical bytes and headers on backup');
foreach ([400, 401, 403, 404, 409, 429, 500, 301] as $status) {
    $t = new Fake([['status' => $status, 'headers' => [], 'body' => '{"code":"backend_error"}'], $accepted]);
    throws(RejectedException::class, fn() => (new Client(null, $multi, $t))->submit([]), "no failover HTTP $status");
    ok(count($t->requests) === 1, "one attempt HTTP $status");
}
foreach ([502, 503, 504] as $status) {
    $t = new Fake([['status' => $status, 'headers' => [], 'body' => 'gateway'], $accepted]);
    (new Client(null, $multi, $t))->submit([]);
    ok(str_starts_with($t->requests[1]['url'], $endpoints[1]), "failover HTTP $status");
}
$t = new Fake([new TransportException('TLS or local error', false), $accepted]);
throws(TransportException::class, fn() => (new Client(null, $multi, $t))->submit([]), 'non-network transport error stops');
ok(count($t->requests) === 1, 'no switch on non-retryable transport error');
$mono = 0;
$t = new Fake([new TransportException('timeout'), $accepted]);
$c = new Client(null, $multi, $t, totalTimeoutMs: 10, monotonicClock: function () use (&$mono) { $now = $mono; $mono += 6; return $now; });
throws(TransportException::class, fn() => $c->submit([]), 'total budget exhausted');
ok(count($t->requests) === 1 && $t->requests[0]['timeoutMs'] <= 4, 'remaining budget passed to transport; no late attempt');
$t = new Fake([new TransportException('down'), $accepted]);
throws(TransportException::class, fn() => (new Client(null, $multi, $t, maxAttempts: 1))->submit([]), 'attempt limit');
ok(count($t->requests) === 1, 'attempt limit respected');
$file = sys_get_temp_dir() . '/multipart-' . bin2hex(random_bytes(6)) . '.pdf'; file_put_contents($file, '%PDF-1.4 test');
try {
    $t = new Fake([new TransportException('reset'), $accepted]);
    (new Client(null, $multi, $t))->submit(['a' => '1'], 'multipart', ['upload' => $file]);
    ok($t->requests[0]['body'] === $t->requests[1]['body'] && $t->requests[0]['headers'] === $t->requests[1]['headers'], 'multipart boundary and bytes stable');
} finally { unlink($file); }

echo $failures === 0 ? "PASS sdk: $passed checks\n" : "FAILED sdk: $failures of " . ($passed + $failures) . " checks\n";
exit($failures === 0 ? 0 : 1);
