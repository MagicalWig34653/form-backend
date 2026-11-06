<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

namespace FormBackend;

use FormBackend\Exception\ConfigurationException;
use FormBackend\Exception\RejectedException;
use FormBackend\Exception\TransportException;

/**
 * Submits form data to the Formular-Backend ingest (`POST /api/v2/submit/?f=<formId>`).
 *
 * The SDK signs the request (Ed25519, timestamped); the SERVER seals the data with the customer's public key on receipt and
 * stores only ciphertext. Transport must therefore be HTTPS (plain HTTP is accepted for loopback hosts only).
 *
 * Retrying is safe: every submission carries an idempotency key; a retry after a lost answer returns the same submission id.
 */
final class Client
{
    public const SUBMIT_PATH = '/api/v2/submit';

    private readonly array $endpoints;
    private readonly int $budgetMs;
    private readonly string $failoverKey;
    private const SESSION_KEY = 'kubus_form_failover';

    /** $sleep is retained for source compatibility; failover sends immediately without backoff. */
    public function __construct(
        string|array|null $baseUrl,
        private readonly Credentials $credentials,
        private readonly Transport $transport = new CurlTransport(),
        private readonly int $maxBodyBytes = 4_194_304,
        private readonly ?\Closure $sleep = null,
        private readonly ?\Closure $clock = null,
        private readonly int $totalTimeoutMs = 10_000,
        private readonly int $maxAttempts = 3,
        private readonly ?\Closure $monotonicClock = null,
        private readonly float $connectTimeout = 3.0,
        ?float $totalBudget = null,
        private readonly int $failoverTtl = 60,
        private readonly bool $sessionStart = false,
    ) {
        if ($totalTimeoutMs < 1 || $maxAttempts < 1 || $maxAttempts > 100) {
            throw new ConfigurationException('positive time budget and 1-100 attempts required');
        }
        if (!is_finite($connectTimeout) || $connectTimeout < 0.001 || $connectTimeout > PHP_INT_MAX / 1000
            || ($totalBudget !== null && (!is_finite($totalBudget) || $totalBudget < 0.001 || $totalBudget > PHP_INT_MAX / 1000))
            || $failoverTtl < 1) {
            throw new ConfigurationException('positive finite timeouts and positive failover TTL required');
        }
        $this->budgetMs = $totalBudget === null ? $totalTimeoutMs : (int)floor($totalBudget * 1000);
        $signed = $credentials->endpoints;
        $endpoints = $baseUrl === null ? $signed : (is_array($baseUrl) ? $baseUrl : [$baseUrl]);
        if ($endpoints === [] || !array_is_list($endpoints)) {
            throw new ConfigurationException('a non-empty ordered endpoint list is required');
        }
        if (($signed !== [] && $endpoints !== $signed) || (count($endpoints) > 1 && $signed === [])) {
            throw new ConfigurationException('endpoint list must match the signed SDK configuration');
        }
        foreach ($endpoints as $url) {
            self::validateEndpoint($url);
        }
        $this->endpoints = array_map(static fn(string $url): string => rtrim($url, '/'), $endpoints);
        $this->failoverKey = hash('sha256', $credentials->formId . "\n" . implode("\n", $this->endpoints));
    }

    /**
     * @param array<string|int,mixed> $fields name => string|int|nested array
     * @param string|null $idempotencyKey reuse the same key when YOU retry a failed call; default: a fresh random key per call
     * @throws Exception\InvalidInputException  nothing was sent
     * @throws RejectedException                the server refused (see ->status, ->errorCode)
     * @throws TransportException               no answer after retries; the submission may have arrived (retry with the same key)
     */
    public function submit(array $fields, ?string $idempotencyKey = null, array $files = []): Submission
    {
        $built = $files === [] ? Canonical::build($fields, $this->maxBodyBytes) : Canonical::buildMultipart($fields, $files);
        $contentType = $files === [] ? 'application/x-www-form-urlencoded' : 'multipart/form-data; boundary=' . $built['boundary'];
        $key = $idempotencyKey ?? bin2hex(random_bytes(16));
        if (strlen($key) < 1 || strlen($key) > 190 || preg_match('/\A[\x21-\x7E]+\z/', $key) !== 1) {
            throw new ConfigurationException('idempotency key must be 1-190 printable ASCII characters without spaces');
        }
        $deadline = $this->monotonicMs() + $this->budgetMs;
        // Build once: boundary, body, timestamp, signature and key survive a lost response unchanged.
        $ts = (string)($this->clock ? ($this->clock)() : time());
        $headers = [
            'Content-Type' => $contentType, 'Accept' => 'application/json',
            'X-Kubus-Timestamp' => $ts,
            'X-Kubus-Signature' => base64_encode($this->credentials->sign($this->signingText($ts, $built['canonical']))),
            'Idempotency-Key' => $key, 'User-Agent' => 'form-backend-php-sdk/0.3',
        ];
        $order = $this->endpointOrder();
        $last = null;
        for ($attempt = 1; $attempt <= $this->maxAttempts; $attempt++) {
            $remaining = (int)floor($deadline - $this->monotonicMs());
            if ($remaining < 1) { break; }
            $endpoint = $order[min($attempt - 1, count($order) - 1)];
            $url = $this->endpoints[$endpoint]
                . self::SUBMIT_PATH . '/?f=' . rawurlencode($this->credentials->formId);
            try {
                // Reserve time for subsequent endpoints even if the primary stalls for its whole timeout.
                $slice = max(1, intdiv($remaining, $this->maxAttempts - $attempt + 1));
                if ($endpoint === 0 && count($this->endpoints) > 1) {
                    // Bound the complete primary attempt as well as cURL's connect phase.
                    $slice = min($slice, (int)floor($this->connectTimeout * 1000));
                }
                $res = $this->transport->post($url, $built['body'], $headers, $slice);
            } catch (TransportException $e) {
                if (!$e->retryable) { throw $e; }
                $this->rememberPrimaryFailure($endpoint);
                $last = $e;
                continue;
            }
            if ($res['status'] === 200) {
                $submission = Submission::fromResponse($res['body']);
                if ($endpoint === 0) { $this->clearPrimaryFailure(); }
                return $submission;
            }
            $last = $this->rejection($res);
            if (!$last->isRetryable() || $last->status === 429) { throw $last; }
            $this->rememberPrimaryFailure($endpoint);
        }
        throw $last ?? new TransportException('request time budget exhausted');
    }

    public static function validateEndpoint(mixed $url): void
    {
        if (!is_string($url) || preg_match('/[\x00-\x20\x7f\\\\]/', $url)) {
            throw new ConfigurationException('invalid endpoint URL');
        }
        $parts = parse_url($url);
        $scheme = strtolower((string)($parts['scheme'] ?? ''));
        $host = strtolower((string)($parts['host'] ?? ''));
        if ($host === '' || !in_array($scheme, ['https', 'http'], true) || isset($parts['query']) || isset($parts['fragment']) || isset($parts['user'])) {
            throw new ConfigurationException('endpoint must be https://host[:port][/prefix] without credentials, query or fragment');
        }
        if ($scheme === 'http' && !in_array($host, ['localhost', '127.0.0.1', '[::1]'], true)) {
            throw new ConfigurationException('plain HTTP is only allowed for localhost; use HTTPS');
        }
    }

    /** Only reorder verified endpoints; session contents can never supply a URL. */
    private function endpointOrder(): array
    {
        $order = array_keys($this->endpoints);
        if (count($order) < 2) { return $order; }
        if ($this->sessionStart && session_status() === PHP_SESSION_NONE && !headers_sent()) {
            // Failure (e.g. unavailable host session storage) falls back to stateless operation.
            @session_start();
        }
        if (session_status() !== PHP_SESSION_ACTIVE) { return $order; }
        $bucket = $_SESSION[self::SESSION_KEY] ?? null;
        $marker = is_array($bucket) ? ($bucket[$this->failoverKey] ?? null) : null;
        $now = $this->now();
        if (is_array($marker) && ($marker['endpoint'] ?? null) === 0
            && is_int($marker['timestamp'] ?? null) && $marker['timestamp'] <= $now
            && $now - $marker['timestamp'] < $this->failoverTtl) {
            return [...array_slice($order, 1), 0];
        }
        $this->clearPrimaryFailure();
        return $order;
    }

    private function rememberPrimaryFailure(int $endpoint): void
    {
        if ($endpoint !== 0 || count($this->endpoints) < 2 || session_status() !== PHP_SESSION_ACTIVE) { return; }
        // Do not overwrite an unexpected value belonging to the host application.
        if (isset($_SESSION[self::SESSION_KEY]) && !is_array($_SESSION[self::SESSION_KEY])) { return; }
        $_SESSION[self::SESSION_KEY][$this->failoverKey] = ['timestamp' => $this->now(), 'endpoint' => 0];
    }

    private function clearPrimaryFailure(): void
    {
        if (session_status() === PHP_SESSION_ACTIVE && is_array($_SESSION[self::SESSION_KEY] ?? null)) {
            unset($_SESSION[self::SESSION_KEY][$this->failoverKey]);
        }
    }

    private function now(): int
    {
        return $this->clock ? (int)($this->clock)() : time();
    }

    private function monotonicMs(): float
    {
        return $this->monotonicClock ? (float)($this->monotonicClock)() : hrtime(true) / 1_000_000;
    }

    /** `KUBUS-V2\nPOST\n/api/v2/submit/?f=<uuid>\n<ts>\n<sha256 hex of the canonical JSON>` (signatur.md). */
    private function signingText(string $ts, string $canonical): string
    {
        return "KUBUS-V2\nPOST\n" . self::SUBMIT_PATH . '/?f=' . rawurlencode($this->credentials->formId) . "\n" . $ts . "\n" . hash('sha256', $canonical);
    }

    /** @param array{status:int, headers:array<string,string>, body:string} $res */
    private function rejection(array $res): RejectedException
    {
        $code = null;
        $decoded = json_decode($res['body'], true, 8);
        if (is_array($decoded)) {
            $c = $decoded['code'] ?? ($decoded['error']['code'] ?? null);
            $code = is_string($c) && preg_match('/\A[a-z0-9_.-]{1,64}\z/i', $c) === 1 ? $c : null;
        }
        $ra = isset($res['headers']['retry-after']) && ctype_digit($res['headers']['retry-after']) ? min(60, (int)$res['headers']['retry-after']) : null;
        $hint = match ($res['status']) {
            403 => 'signature rejected: check the signing key, the form id and that the server clock and this clock agree within 5 minutes',
            404 => 'unknown or inactive form',
            409 => 'idempotency key already used with different content',
            413 => 'submission too large',
            415 => 'unsupported content type',
            422 => 'submission refused',
            429 => 'too many requests',
            default => 'server error',
        };
        return new RejectedException(sprintf('submission rejected (HTTP %d): %s', $res['status'], $hint), $res['status'], $code, $ra);
    }

}
