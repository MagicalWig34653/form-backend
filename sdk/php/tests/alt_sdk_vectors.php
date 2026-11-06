<?php
// SPDX-License-Identifier: AGPL-3.0-only
// Differential vectors from the LEGACY code (read-only): providers/Clients/BackendV2.php (SDK signer) and
// providers/AnfrageSignatur.php (backend verifier). Their class bodies are evaluated unmodified except for
// the stripped `require_once`/`declare` lines (no bootstrap, no config, no secrets, no database is loaded).
// Inputs are synthetic; the throw-away signing key is derived from a fixed public test seed.
//
//   php alt_sdk_vectors.php [path-to-legacy-project]    (default: ../form-backend_bvk next to this repo)
//
// Writes backend/Tests/FormCryptoTests/Fixtures/alt-sdk.json. Swift (AltSDKVectorTests) must reproduce
// every canonical/body hash/signature text byte for byte.
declare(strict_types=1);
function check(bool $ok, string $label): void { if (!$ok) throw new RuntimeException($label); }

$legacy = $argv[1] ?? dirname(__DIR__, 4) . '/form-backend_bvk';
$load = function (string $file, string $class) use ($legacy): void {
    $path = $legacy . '/providers/' . $file;
    check(is_file($path) && !str_contains($path, 'secrets'), 'legacy file missing');
    $src = (string)file_get_contents($path);
    $src = preg_replace('/^<\?php\s*/', '', $src, 1);
    $src = preg_replace('/^declare\(strict_types=1\);\s*/m', '', $src, 1);
    $src = preg_replace('/^require_once .*$/m', '', $src);
    if (!class_exists($class, false)) eval($src);
    check(class_exists($class, false), 'class not loaded: ' . $class);
};
$load('Clients/BackendV2.php', 'BackendV2');
$load('AnfrageSignatur.php', 'AnfrageSignatur');
$sdkText = new ReflectionMethod('BackendV2', 'signaturtext');
$sdkBody = new ReflectionMethod('BackendV2', 'bodyHash');

function nest(int $n, mixed $leaf): mixed { $v = $leaf; for ($i = 0; $i < $n; $i++) $v = [$v]; return $v; }
function inputs(): array {
    return [
        'empty' => [[], []],
        'mixed' => [['z' => 'Grüße / 🌍', 'a' => ['x' => true, 'n' => null, 'i' => -42], 'line' => "\0\n\t\u{2028}\u{2029}"], upload()],
        'unordered-list' => [[2 => 'two', 0 => 'zero'], []],
        'list-order' => [[1 => 'one', 0 => 'zero'], []],
        'string-keys' => [['10' => 'ten', '2' => 'two', '01' => 'leading'], []],
        'nested-list' => [['list' => ['b', 'a'], 'empty' => []], []],
        'numeric-edge-keys' => [['-0' => 'a', '1.5' => 'b', '9223372036854775807' => 'c', '9223372036854775808' => 'd', '' => 'empty'], []],
        'scalars' => [['max' => PHP_INT_MAX, 'min' => PHP_INT_MIN, 'zero' => 0, 'f' => false, 't' => true, 'n' => null], []],
        'controls-and-specials' => [['k' => "\x01\x1f\x7f\x08\x0c\r", 'html' => "<a href='x'>&\"</a> / \\", 'astral' => "\u{10FFFF}\u{FFFF}", 'bom' => "\u{FEFF}a"], []],
        'bom-key' => [["\u{FEFF}k" => 'v', 'ü' => 1, 'z' => 2, 'Z' => 3, 'é' => 4], []],
        'depth-511' => [['d' => nest(510, 'x')], []],
        'depth-512' => [['d' => nest(511, 'x')], []],
        'files-only' => [[], ['f' => ['name' => 'a', 'type' => 't', 'error' => 0, 'size' => 1, 'content' => 'x'], 'g' => ['name' => '', 'type' => '', 'error' => 4, 'size' => 0, 'content' => null]]],
        'files-empty-multi' => [[], ['m' => ['name' => ['a', 'b'], 'type' => ['', ''], 'error' => [4, 4], 'size' => [0, 0], 'content' => [null, null]]]],
        'files-list-keys' => [[], ['1' => ['name' => 'a', 'type' => '', 'error' => 0, 'size' => 0, 'content' => ''], '0' => ['name' => 'b', 'type' => '', 'error' => 0, 'size' => 0, 'content' => 'y']]],
    ];
}
function upload(): array {
    return ['upload' => ['name' => ['b.bin', 'skip', 'missing'], 'type' => ['application/octet-stream', '', ''], 'error' => [0, 4, 0], 'size' => [3, 0, 0], 'content' => ["\0\xff\x01", null, null]]];
}
/** Convert the harness file shape to a $_FILES shape with real temporary files. */
function toFiles(array $files, array &$tmp): array {
    $out = [];
    foreach ($files as $key => $f) {
        $mk = function (mixed $content) use (&$tmp): string {
            if ($content === null) return '';
            $p = tempnam(sys_get_temp_dir(), 'altvec'); file_put_contents($p, $content); $tmp[] = $p; return $p;
        };
        if (is_array($f['name'])) {
            $e = ['name' => $f['name'], 'type' => $f['type'], 'error' => $f['error'], 'size' => $f['size'], 'tmp_name' => []];
            foreach ($f['content'] as $i => $c) $e['tmp_name'][$i] = $mk($c);
        } else {
            $e = ['name' => $f['name'], 'type' => $f['type'], 'error' => $f['error'], 'size' => $f['size'], 'tmp_name' => $mk($f['content'])];
        }
        $out[$key] = $e;
    }
    return $out;
}
function legacyCanonicalJson(array $post, array $files): string {
    // The legacy code only exposes the hash; reproduce its JSON (same flags) for the byte comparison.
    $sort = new ReflectionMethod('AnfrageSignatur', 'sortiereRekursiv');
    $dat = new ReflectionMethod('AnfrageSignatur', 'dateien');
    return json_encode(['fields' => $sort->invoke(null, $post), 'files' => $dat->invoke(null, $files)],
        JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
}

$tmp = [];
$cases = [];
foreach (inputs() as $id => [$post, $files]) {
    $f = toFiles($files, $tmp);
    $entry = ['id' => $id];
    try {
        $hashSdk = $sdkBody->invoke(null, $post, $f);
        $hashBackend = AnfrageSignatur::bodyHash($post, $f);
        check($hashSdk === $hashBackend, "legacy SDK and backend disagree: $id");
        $entry['canonical'] = bin2hex(legacyCanonicalJson($post, $f));
        check(hash('sha256', hex2bin($entry['canonical'])) === $hashSdk, "hash/json mismatch: $id");
        $entry['bodyHash'] = $hashSdk;
    } catch (JsonException $e) {
        $entry['error'] = 'json';
    }
    $cases[] = $entry;
}

$emptyCanonical = (string)hex2bin($cases[0]['canonical']);
$pathCases = [
    ['post', 'https://example.invalid/api/v2/submit///?ignored=yes', 'a b/ü', '1793145600'],
    ['POST', '/api/v2/form', 'plain-uuid', '0'],
    ['post', '0', 'x', '1'], ['Post', '//host/api/v2/submit', 'x', '1'], ['POST', 'host:80/x', 'x', '1'],
    ['POST', '', 'x', '1'], ['POST', '?f=1', 'x', '1'], ['POST', '/', 'x', '1'], ['POST', '/a?b#c', 'x', '1'],
    ['POST', 'http://h', 'x', '1'], ['POST', '/api/v2/submit/#frag', 'x', '1'], ['POST', '///', 'x', '1'],
    ['POST', 'a:b', 'x', '1'], ['POST', 'api/v2/submit/', 'x', '1'], ['POST', '/api//v2/submit//', 'x', '1'],
    ['POST', '/p', "a+b%~._-*()'!\u{FEFF}\u{10FFFF}", '1'], ['get', '/api/v2/form/', '', '99'],
    ['POST', '//', 'x', '1'], ['POST', '/a:80', 'x', '1'], ['POST', '/a:b', 'x', '1'], ['POST', 'a b:80/x', 'x', '1'], ['POST', 'host:99999/x', 'x', '1'], ['POST', 'host:80', 'x', '1'], ['POST', '1a:80/x', 'x', '1'], ['POST', 'a:80?x', 'x', '1'], ['POST', 'host:0080/x/y/', 'x', '1'], ['POST', 'mailto:me/x', 'x', '1'], ['POST', 'a:/b', 'x', '1'], ['POST', 'a://h:80/p', 'x', '1'], ['POST', '//h:80', 'x', '1'], ['POST', '//h:80/p?q', 'x', '1'], ['POST', '/0', 'x', '1'], ['POST', 'x:', 'x', '1'], ['POST', '/api/v2/submit', 'x', '00'],
];
$texts = [];
foreach ($pathCases as $i => [$method, $path, $uuid, $ts]) {
    $a = $sdkText->invoke(null, $method, $path, $uuid, $ts, [], []);
    $b = AnfrageSignatur::signaturtext($method, $path, $uuid, $ts, [], []);
    check($a === $b, "legacy SDK/backend text disagree: path case $i");
    $texts[] = ['id' => "path-$i", 'method' => $method, 'path' => $path, 'formID' => $uuid, 'timestamp' => $ts, 'text' => bin2hex($a)];
}

// Signatures from the legacy signer path: sodium_crypto_sign_detached over the SDK-built text (BackendV2::sende()).
$pair = sodium_crypto_sign_seed_keypair(str_repeat("\x77", 32));
$sk = sodium_crypto_sign_secretkey($pair); $pk = sodium_crypto_sign_publickey($pair);
$signed = [];
foreach ($texts as $t) {
    $sig = sodium_crypto_sign_detached((string)hex2bin($t['text']), $sk);
    check(sodium_crypto_sign_verify_detached($sig, (string)hex2bin($t['text']), $pk), 'self verify');
    $signed[] = $t + ['signature' => bin2hex($sig)];
}
foreach ($tmp as $p) @unlink($p);

$out = [
    'notice' => 'PUBLIC SYNTHETIC TEST DATA ONLY - NEVER USE IN PRODUCTION',
    'source' => 'legacy providers/Clients/BackendV2.php (signaturtext/bodyHash via reflection) and providers/AnfrageSignatur.php, evaluated read-only',
    'php' => PHP_VERSION,
    'seed' => bin2hex(str_repeat("\x77", 32)), 'publicKey' => bin2hex($pk),
    'bodies' => $cases, 'emptyBodyCanonical' => bin2hex($emptyCanonical), 'paths' => $signed,
];
$target = dirname(__DIR__, 3) . '/backend/Tests/FormCryptoTests/Fixtures/alt-sdk.json';
file_put_contents($target, json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR) . "\n");
echo 'GENERATED ' . count($cases) . ' body cases and ' . count($signed) . " path cases from legacy code\n";
