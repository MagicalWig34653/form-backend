<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

// Exercise the actual CurlTransport policy without sockets, including failures after HTTP headers.
namespace FormBackend;
require __DIR__ . '/../src/Transport.php';
require __DIR__ . '/../src/Exception/FormBackendException.php';
require __DIR__ . '/../src/Exception/TransportException.php';
require __DIR__ . '/../src/CurlTransport.php';

function curl_init(string $url): object { return new \stdClass(); }
function curl_setopt_array(object $handle, array $options): bool { $GLOBALS['options'] = $options; return true; }
function curl_exec(object $handle): bool {
    $options = $GLOBALS['options'];
    $options[CURLOPT_HEADERFUNCTION]($handle, 'HTTP/1.1 ' . $GLOBALS['status'] . " Test\r\n");
    $written = $options[CURLOPT_WRITEFUNCTION]($handle, $GLOBALS['body']);
    return $GLOBALS['errno'] === 0 && $written !== 0;
}
function curl_getinfo(object $handle, int $option): int { return $GLOBALS['status']; }
function curl_errno(object $handle): int { return $GLOBALS['errno']; }

$checks = 0;
function check(bool $condition): void { global $checks; if (!$condition) { throw new \RuntimeException('curl policy check failed #' . ($checks + 1)); } $checks++; }
$transport = new CurlTransport();
foreach ([CURLE_COULDNT_RESOLVE_HOST, CURLE_COULDNT_CONNECT, CURLE_OPERATION_TIMEDOUT, CURLE_RECV_ERROR,
    CURLE_SEND_ERROR, CURLE_GOT_NOTHING, CURLE_PARTIAL_FILE, 92] as $networkError) {
    foreach ([0, 400, 403, 429, 500] as $httpStatus) {
        $GLOBALS['status'] = $httpStatus; $GLOBALS['errno'] = $networkError; $GLOBALS['body'] = 'partial';
        try { $transport->post('https://primary.example', 'body', ['Idempotency-Key' => 'same'], 123); check(false); }
        catch (Exception\TransportException $e) { check($e->retryable === ($httpStatus === 0)); }
    }
}
foreach ([60, CURLE_WRITE_ERROR, CURLE_URL_MALFORMAT] as $localError) {
    $GLOBALS['status'] = 0; $GLOBALS['errno'] = $localError;
    try { $transport->post('https://primary.example', 'body', [], 123); check(false); }
    catch (Exception\TransportException $e) { check(!$e->retryable); }
}
$GLOBALS['status'] = 503; $GLOBALS['errno'] = 0; $GLOBALS['body'] = 'gateway';
$response = $transport->post('https://primary.example', 'body', ['Idempotency-Key' => 'same'], 123);
check($response['status'] === 503 && $response['body'] === 'gateway');
$options = $GLOBALS['options'];
check($options[CURLOPT_TIMEOUT_MS] === 123 && $options[CURLOPT_CONNECTTIMEOUT_MS] === 123);
check($options[CURLOPT_FOLLOWLOCATION] === false && $options[CURLOPT_SSL_VERIFYPEER] === true && $options[CURLOPT_SSL_VERIFYHOST] === 2);
check($options[CURLOPT_POSTFIELDS] === 'body' && in_array('Idempotency-Key: same', $options[CURLOPT_HTTPHEADER], true));
echo "PASS curl transport: $checks checks\n";
