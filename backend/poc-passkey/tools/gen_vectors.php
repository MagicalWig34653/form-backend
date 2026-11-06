<?php
// SPDX-License-Identifier: AGPL-3.0-only
// Generates SYNTHETIC WebAuthn assertion vectors (fresh throwaway keys, no real credentials).
// The stored public key PEM is produced by the legacy library (lbuchs/webauthn 2.2.0,
// read-only require) exactly as the legacy registration stores it. The legacy library's
// processGet() plus the legacy exact-origin check and counter rule act as parity oracle.
// Usage: php gen_vectors.php <legacy providers/webauthn dir> <output.json>
declare(strict_types=1);

[$self, $libDir, $out] = $argv + [null, null, null];
if (!$libDir || !$out) { fwrite(STDERR, "usage: gen_vectors.php <lib dir> <out.json>\n"); exit(2); }
$out = (str_starts_with($out, '/') ? $out : getcwd() . '/' . $out);
chdir($libDir);
require_once $libDir . '/WebAuthn.php';
use lbuchs\WebAuthn\WebAuthn;
use lbuchs\WebAuthn\WebAuthnException;
use lbuchs\WebAuthn\Attestation\AuthenticatorData;

const RP_ID = 'admin.example.test';
const ORIGIN = 'https://admin.example.test';
const USER_HANDLE = '11111111-2222-4333-8444-555555555555'; // legacy: UTF-8 bytes of the user UUID text

function b64u(string $b): string { return rtrim(strtr(base64_encode($b), '+/', '-_'), '='); }

// ---- minimal CBOR encoder (uint, negint, bytes, map) ----
function cUint(int $major, int $n): string {
    if ($n < 24) return chr(($major << 5) | $n);
    if ($n < 256) return chr(($major << 5) | 24) . chr($n);
    if ($n < 65536) return chr(($major << 5) | 25) . pack('n', $n);
    return chr(($major << 5) | 26) . pack('N', $n);
}
function cInt(int $v): string { return $v >= 0 ? cUint(0, $v) : cUint(1, -1 - $v); }
function cBytes(string $b): string { return cUint(2, strlen($b)) . $b; }
function cMap(array $pairs): string { // list of [encodedKey, encodedValue]
    $s = cUint(5, count($pairs));
    foreach ($pairs as [$k, $v]) $s .= $k . $v;
    return $s;
}

// ---- key creation (fresh, throwaway) ----
function pemFromCose(string $cose): string {
    $rp = hash('sha256', RP_ID, true);
    $credId = 'tmp';
    $ad = $rp . chr(0x45) . pack('N', 0) . str_repeat("\0", 16) . pack('n', strlen($credId)) . $credId . $cose;
    return (new AuthenticatorData($ad))->getPublicKeyPem();
}

$keys = [];
// ES256
$ec = openssl_pkey_new(['curve_name' => 'prime256v1', 'private_key_type' => OPENSSL_KEYTYPE_EC]);
$d = openssl_pkey_get_details($ec)['ec'];
$keys['es256'] = ['priv' => $ec, 'alg' => -7, 'pem' => pemFromCose(cMap([
    [cInt(1), cInt(2)], [cInt(3), cInt(-7)], [cInt(-1), cInt(1)],
    [cInt(-2), cBytes(str_pad($d['x'], 32, "\0", STR_PAD_LEFT))], [cInt(-3), cBytes(str_pad($d['y'], 32, "\0", STR_PAD_LEFT))]]))];
$ec2 = openssl_pkey_new(['curve_name' => 'prime256v1', 'private_key_type' => OPENSSL_KEYTYPE_EC]);
$d2 = openssl_pkey_get_details($ec2)['ec'];
$keys['es256_other'] = ['priv' => $ec2, 'alg' => -7, 'pem' => pemFromCose(cMap([
    [cInt(1), cInt(2)], [cInt(3), cInt(-7)], [cInt(-1), cInt(1)],
    [cInt(-2), cBytes(str_pad($d2['x'], 32, "\0", STR_PAD_LEFT))], [cInt(-3), cBytes(str_pad($d2['y'], 32, "\0", STR_PAD_LEFT))]]))];
// RS256
$rsa = openssl_pkey_new(['private_key_type' => OPENSSL_KEYTYPE_RSA, 'private_key_bits' => 2048]);
$r = openssl_pkey_get_details($rsa)['rsa'];
$keys['rs256'] = ['priv' => $rsa, 'alg' => -257, 'pem' => pemFromCose(cMap([
    [cInt(1), cInt(3)], [cInt(3), cInt(-257)], [cInt(-1), cBytes($r['n'])], [cInt(-2), cBytes($r['e'])]]))];
// EdDSA
$kp = sodium_crypto_sign_keypair();
$sk = sodium_crypto_sign_secretkey($kp);
$pk = sodium_crypto_sign_publickey($kp);
$keys['eddsa'] = ['sodium_sk' => $sk, 'alg' => -8, 'pem' => pemFromCose(cMap([
    [cInt(1), cInt(1)], [cInt(3), cInt(-8)], [cInt(-1), cInt(6)], [cInt(-2), cBytes($pk)]]))];

function sign(array $key, string $data): string {
    if (isset($key['sodium_sk'])) return sodium_crypto_sign_detached($data, $key['sodium_sk']);
    openssl_sign($data, $sig, $key['priv'], OPENSSL_ALGO_SHA256);
    return $sig;
}

function makeAuthData(int $flags, int $counter, ?string $rpId = null, string $extra = ''): string {
    return hash('sha256', $rpId ?? RP_ID, true) . chr($flags) . pack('N', $counter) . $extra;
}

function legacyOracle(string $pem, string $cdj, string $ad, string $sig, string $challengeRaw, int $stored): array {
    // Legacy path: exact origin check first, then lbuchs processGet(UV=true, UP=true, prev=null), then own counter rule.
    $c = json_decode($cdj, true);
    $originOk = is_array($c) && isset($c['origin']) && is_string($c['origin'])
        && strtolower(rtrim($c['origin'], '/')) === strtolower(rtrim(ORIGIN, '/'));
    if (!$originOk) return ['result' => 'reject', 'stage' => 'origin'];
    try {
        $wa = new WebAuthn('kubusFormulare', RP_ID, ['none', 'packed', 'fido-u2f', 'apple'], true);
        $wa->processGet($cdj, $ad, $sig, $pem, $challengeRaw, null, true, true);
    } catch (WebAuthnException $e) {
        return ['result' => 'reject', 'stage' => 'library', 'message' => $e->getMessage()];
    } catch (\Throwable $e) {
        return ['result' => 'reject', 'stage' => 'library-throwable', 'message' => get_class($e)];
    }
    if (strlen($ad) < 37) return ['result' => 'reject', 'stage' => 'counter-parse'];
    $new = unpack('N', substr($ad, 33, 4))[1];
    $plaus = ($stored === 0 && $new === 0) || $new > $stored;
    return $plaus ? ['result' => 'ok'] : ['result' => 'reject', 'stage' => 'counter'];
}

$vectors = [];
function vec(string $name, string $keyName, array $o): void {
    global $vectors, $keys;
    $key = $keys[$o['signWith'] ?? $keyName];
    $challenge = $o['challenge'] ?? random_bytes(32);
    $cdChallenge = $o['clientChallenge'] ?? $challenge;
    $cdj = $o['cdj'] ?? json_encode([
        'type' => $o['type'] ?? 'webauthn.get',
        'challenge' => b64u($cdChallenge),
        'origin' => $o['origin'] ?? ORIGIN,
        'crossOrigin' => false,
    ], JSON_UNESCAPED_SLASHES);
    $ad = $o['ad'] ?? makeAuthData($o['flags'] ?? 0x05, $o['counter'] ?? 0, $o['rpId'] ?? null, $o['extra'] ?? '');
    $sig = sign($key, $ad . hash('sha256', $cdj, true));
    if (!empty($o['flipSig'])) { $sig[strlen($sig) - 1] = chr(ord($sig[strlen($sig) - 1]) ^ 1); }
    $stored = $o['stored'] ?? 0;
    $keyName2 = $keyName; // stored public key
    $legacy = legacyOracle($keys[$keyName2]['pem'], $cdj, $ad, $sig, $challenge, $stored);
    $GLOBALS['vectors'][] = [
        'name' => $name,
        'key' => $keyName2,
        'storedSignCount' => $stored,
        'challenge' => b64u($challenge),
        'clientDataJSON' => b64u($cdj),
        'authenticatorData' => b64u($ad),
        'signature' => b64u($sig),
        'userHandle' => b64u($o['userHandle'] ?? USER_HANDLE),
        'expect' => $o['expect'],
        'legacy' => ($o['legacyOverride'] ?? $legacy),
        'note' => $o['note'] ?? null,
    ];
}

// flags: UP=0x01 UV=0x04 BE=0x08 BS=0x10 AT=0x40 ED=0x80
foreach (['es256', 'rs256', 'eddsa'] as $k) {
    vec("{$k}_ok_counter_0_0", $k, ['expect' => 'ok', 'flags' => 0x05, 'counter' => 0, 'stored' => 0]);
    vec("{$k}_ok_counter_increase", $k, ['expect' => 'ok', 'flags' => 0x05, 'counter' => 6, 'stored' => 5]);
    vec("{$k}_bad_signature", $k, ['expect' => 'signatureInvalid', 'flipSig' => true]);
}
vec('es256_ok_synced_backup_flags', 'es256', ['expect' => 'ok', 'flags' => 0x1D, 'counter' => 0, 'stored' => 0, 'note' => 'UP|UV|BE|BS, Apple/iCloud style 0/0']);
// extension data present (ED flag, CBOR map {"hmac-secret": true} as trailing bytes)
vec('es256_ok_extension_data', 'es256', ['expect' => 'ok', 'flags' => 0x85, 'counter' => 1, 'stored' => 0,
    'extra' => cMap([[cUint(3, 11) . 'hmac-secret', chr(0xF5)]])]);
vec('es256_wrong_key', 'es256', ['expect' => 'signatureInvalid', 'signWith' => 'es256_other']);
vec('es256_wrong_type_create', 'es256', ['expect' => 'wrongType', 'type' => 'webauthn.create']);
vec('es256_wrong_challenge', 'es256', ['expect' => 'challengeMismatch', 'clientChallenge' => random_bytes(32)]);
vec('es256_origin_subdomain_attack', 'es256', ['expect' => 'originMismatch', 'origin' => 'https://evil.admin.example.test']);
vec('es256_origin_suffix_attack', 'es256', ['expect' => 'originMismatch', 'origin' => 'https://eviladmin.example.test']);
vec('es256_origin_other_port', 'es256', ['expect' => 'originMismatch', 'origin' => 'https://admin.example.test:8443']);
vec('es256_origin_http', 'es256', ['expect' => 'originMismatch', 'origin' => 'http://admin.example.test']);
vec('es256_origin_trailing_slash', 'es256', ['expect' => 'originMismatch', 'origin' => 'https://admin.example.test/',
    'note' => 'DEVIATION: legacy tolerates trailing slash and case; browsers never send it; PoC is exact']);
vec('es256_origin_uppercase', 'es256', ['expect' => 'originMismatch', 'origin' => 'HTTPS://ADMIN.EXAMPLE.TEST',
    'note' => 'legacy rejects too (library scheme check is case-sensitive)']);
vec('es256_wrong_rpid_hash', 'es256', ['expect' => 'rpIdHashMismatch', 'rpId' => 'example.test']);
vec('es256_up_missing', 'es256', ['expect' => 'userNotPresent', 'flags' => 0x04]);
vec('es256_uv_missing', 'es256', ['expect' => 'userNotVerified', 'flags' => 0x01]);
vec('es256_counter_equal_nonzero', 'es256', ['expect' => 'counterRegression', 'counter' => 10, 'stored' => 10]);
vec('es256_counter_backwards', 'es256', ['expect' => 'counterRegression', 'counter' => 3, 'stored' => 10]);
vec('es256_counter_reset_to_zero', 'es256', ['expect' => 'counterRegression', 'counter' => 0, 'stored' => 5]);
vec('es256_counter_max_uint32', 'es256', ['expect' => 'ok', 'counter' => 4294967295, 'stored' => 4294967294]);
vec('es256_counter_exhausted', 'es256', ['expect' => 'counterRegression', 'counter' => 4294967295, 'stored' => 4294967295]);
vec('es256_authdata_truncated', 'es256', ['expect' => 'authenticatorDataInvalid', 'ad' => substr(makeAuthData(0x05, 1), 0, 36)]);
vec('es256_user_handle_mismatch', 'es256', ['expect' => 'userHandleMismatch', 'userHandle' => '99999999-2222-4333-8444-555555555555', 'legacyOverride' => ['result' => 'n/a', 'note' => 'checked in Passkey.php, not in library: reject']]);
vec('es256_malformed_clientdata', 'es256', ['expect' => 'clientDataInvalid', 'cdj' => '{not json']);
// RS256 signature presented against an EC key: must fail
$vectors[] = array_merge($vectors[array_search('rs256_ok_counter_0_0', array_column($vectors, 'name'))], [
    'name' => 'rs256_signature_against_ec_key', 'key' => 'es256', 'expect' => 'signatureInvalid',
    'legacy' => ['result' => 'n/a']]);

$keyOut = [];
foreach ($keys as $n => $k) {
    $keyOut[$n] = ['alg' => $k['alg'], 'publicKeyPem' => $k['pem'], 'credentialId' => b64u(hash('sha256', $n, true))];
}
file_put_contents($out, json_encode([
    'synthetic' => true,
    'generator' => 'tools/gen_vectors.php; PEM via lbuchs/webauthn 2.2.0 getPublicKeyPem()',
    'rpId' => RP_ID, 'origin' => ORIGIN, 'userHandleText' => USER_HANDLE,
    'keys' => $keyOut, 'vectors' => $vectors,
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
$bad = 0;
foreach ($vectors as $v) {
    $l = $v['legacy']['result'] ?? 'n/a';
    $e = $v['expect'] === 'ok' ? 'ok' : 'reject';
    $flag = ($l === 'n/a' || $l === $e) ? '' : '   <-- legacy differs from expectation';
    if ($flag) $bad++;
    printf("%-40s expect=%-26s legacy=%s%s\n", $v['name'], $v['expect'], $l, $flag);
}
echo count($vectors), " vectors, $bad legacy differences\n";
