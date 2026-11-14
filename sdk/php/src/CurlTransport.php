<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

namespace FormBackend;

use FormBackend\Exception\TransportException;

/** cURL with certificate and host verification, no redirects, only http/https, bounded time and response size. */
final class CurlTransport implements Transport
{
    // Stable libcurl error codes not exposed as constants by all PHP builds.
    private const HTTP2_ERROR = 16;
    private const HTTP2_STREAM_ERROR = 92;

    public function __construct(private readonly int $connectTimeout = 5, /** Hard ceiling per request in seconds; null = only the $timeoutMs the Client passes (it bounds large uploads by SERVER_WAIT_MS + upload time + budget). */
        private readonly ?int $timeout = null, private readonly int $maxResponseBytes = 65_536)
    {
    }

    public function post(string $url, string $body, array $headers, int $timeoutMs): array
    {
        $h = curl_init($url);
        if ($h === false) {
            throw new TransportException('could not initialise the HTTP client');
        }
        $lines = [];
        foreach ($headers as $k => $v) {
            $lines[] = $k . ': ' . $v;
        }
        $received = '';
        $respHeaders = [];
        curl_setopt_array($h, [
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $body,
            CURLOPT_HTTPHEADER => $lines,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_PROTOCOLS => CURLPROTO_HTTP | CURLPROTO_HTTPS,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_CONNECTTIMEOUT_MS => min($this->connectTimeout * 1000, $timeoutMs),
            CURLOPT_TIMEOUT_MS => $this->timeout === null ? $timeoutMs : min($this->timeout * 1000, $timeoutMs),
            CURLOPT_NOSIGNAL => true,
            CURLOPT_HEADERFUNCTION => static function ($c, string $line) use (&$respHeaders): int {
                $parts = explode(':', $line, 2);
                if (count($parts) === 2) {
                    $respHeaders[strtolower(trim($parts[0]))] = trim($parts[1]);
                }
                return strlen($line);
            },
            CURLOPT_WRITEFUNCTION => function ($c, string $chunk) use (&$received): int {
                $received .= $chunk;
                return strlen($received) > $this->maxResponseBytes ? 0 : strlen($chunk);   // 0 aborts: oversized answers are an error
            },
        ]);
        $ok = curl_exec($h);
        $status = (int)curl_getinfo($h, CURLINFO_RESPONSE_CODE);
        $errno = curl_errno($h);
        // The handle is freed when it goes out of scope (curl_close() has had no effect since PHP 8.0 and is deprecated in 8.5).
        unset($h);
        if ($ok === false || $errno !== 0 || $status === 0) {
            // curl_error() may echo the URL; only the numeric code is reported.
            // Never reinterpret a backend refusal with a truncated response as a failover signal.
            $retryable = !($status >= 400 && $status < 500) && $status !== 500
                && in_array($errno, [CURLE_COULDNT_RESOLVE_PROXY, CURLE_COULDNT_RESOLVE_HOST, CURLE_COULDNT_CONNECT, CURLE_OPERATION_TIMEDOUT,
                    CURLE_SEND_ERROR, CURLE_RECV_ERROR, CURLE_GOT_NOTHING, CURLE_PARTIAL_FILE, self::HTTP2_ERROR, self::HTTP2_STREAM_ERROR], true);
            throw new TransportException('request failed (curl error ' . $errno . ')', $retryable);
        }
        return ['status' => $status, 'headers' => $respHeaders, 'body' => $received];
    }
}
