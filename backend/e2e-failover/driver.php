<?php
// SPDX-License-Identifier: AGPL-3.0-only
// One SDK submission for backend/e2e-failover.sh. Prints a single TSV line:
//   outcome<TAB>elapsed_ms<TAB>submission_id<TAB>marker(0|1)
// Usage: php driver.php CREDENTIALS SESSION_DIR SESSION_ID TTL LIST_MODE KEY ENDPOINT1 [ENDPOINT2]
// LIST_MODE: signed (list signed locally with the issued seed) | unsigned | tampered (valid signature over another list)
declare(strict_types=1);
foreach (['Exception/FormBackendException', 'Exception/ConfigurationException', 'Exception/InvalidInputException', 'Exception/RejectedException', 'Exception/TransportException', 'Credentials', 'Transport', 'CurlTransport', 'Submission', 'Canonical', 'Client'] as $f) {
    require __DIR__ . '/../../sdk/php/src/' . $f . '.php';
}
use FormBackend\Client;
use FormBackend\Credentials;

[, $credFile, $dir, $sid, $ttl, $mode, $key] = $argv;
$endpoints = array_slice($argv, 7);
$data = json_decode((string)file_get_contents($credFile), true);
unset($data['endpoints'], $data['endpointSignature']);
$sign = static function (array $list) use ($data): string {
    $seed = base64_decode(strtr($data['signingSeed'], '-_', '+/') . '=');
    $sk = sodium_crypto_sign_secretkey(sodium_crypto_sign_seed_keypair($seed));
    $sig = sodium_crypto_sign_detached("KUBUS-SDK-CONFIG-V1\n" . $data['formId'] . "\n" . implode("\n", $list), $sk);
    return rtrim(strtr(base64_encode($sig), '+/', '-_'), '=');
};
$data['endpoints'] = $endpoints;
if ($mode === 'signed') { $data['endpointSignature'] = $sign($endpoints); }
if ($mode === 'tampered') { $data['endpointSignature'] = $sign(array_reverse($endpoints)); }

session_save_path($dir);
session_id($sid);
session_start();
$t = hrtime(true);
$outcome = 'ok'; $id = '';
try {
    $creds = Credentials::fromArray($data);
    $client = new Client(null, $creds, connectTimeout: 3.0, totalBudget: 10.0, failoverTtl: (int)$ttl);
    $id = $client->submit(['email' => 'failover@example.org', 'vorname' => 'Failover'], $key)->id;
} catch (Throwable $e) {
    $outcome = (new ReflectionClass($e))->getShortName();
}
$bucket = $_SESSION['kubus_form_failover'] ?? [];
printf("%s\t%.0f\t%s\t%d\n", $outcome, (hrtime(true) - $t) / 1e6, $id === '' ? '-' : $id,count($bucket) > 0 ? 1 : 0);
session_write_close();
