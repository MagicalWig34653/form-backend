<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

namespace FormBackend;

use FormBackend\Exception\ConfigurationException;

/**
 * What `POST /tenants/{t}/forms/{f}/sdk-credentials` returns, validated. The signing seed is a secret: keep the JSON file
 * outside the web root, readable only by the PHP user. `__debugInfo` and `jsonSerialize` never expose it.
 */
final class Credentials implements \JsonSerializable
{
    private function __construct(
        public readonly string $formId,
        private readonly string $signingSeed,
        public readonly string $signingPublicKey,
        public readonly array $endpoints = [],
    ) {
    }

    /** @param array<string,mixed> $data decoded credentials JSON */
    public static function fromArray(array $data): self
    {
        $formId = $data['formId'] ?? null;
        if (!is_string($formId) || preg_match('/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/', $formId) !== 1) {
            throw new ConfigurationException('formId must be a lowercase UUID');
        }
        $seed = self::b64url($data['signingSeed'] ?? null, 32, 'signingSeed');
        $pub = self::b64url($data['signingPublicKey'] ?? null, 32, 'signingPublicKey');
        // The pair must belong together: a mismatch means a truncated/mixed-up credentials file and every request would be refused.
        $derived = sodium_crypto_sign_publickey(sodium_crypto_sign_seed_keypair($seed));
        if (!hash_equals($derived, $pub)) {
            throw new ConfigurationException('signingSeed does not match signingPublicKey');
        }
        $endpoints = $data['endpoints'] ?? [];
        if (array_key_exists('endpoints', $data) || array_key_exists('endpointSignature', $data)) {
            if (!is_array($endpoints) || !array_is_list($endpoints) || count($endpoints) < 1 || count($endpoints) > 10
                || count(array_unique($endpoints, SORT_REGULAR)) !== count($endpoints)) {
                throw new ConfigurationException('endpoints must be a unique ordered list of 1-10 URLs');
            }
            foreach ($endpoints as $endpoint) { Client::validateEndpoint($endpoint); }
            $signature = self::b64url($data['endpointSignature'] ?? null, 64, 'endpointSignature');
            $text = "KUBUS-SDK-CONFIG-V1\n" . $formId . "\n" . implode("\n", $endpoints);
            if (!sodium_crypto_sign_verify_detached($signature, $text, $pub)) {
                throw new ConfigurationException('invalid signed endpoint configuration');
            }
        }
        return new self($formId, $seed, $pub, $endpoints);
    }

    /** Reads the JSON file written from the admin API response. Refuses group/world-readable files (they hold a secret). */
    public static function fromFile(string $path, bool $checkPermissions = true): self
    {
        clearstatcache(true, $path);   // the permission check must see the CURRENT mode (PHP caches stat results per process)
        if (!is_file($path) || !is_readable($path)) {
            throw new ConfigurationException('credentials file is not readable');
        }
        if ($checkPermissions && DIRECTORY_SEPARATOR === '/' && ((fileperms($path) ?: 0) & 0o077) !== 0) {
            throw new ConfigurationException('credentials file must not be accessible by group or others (chmod 600)');
        }
        $raw = file_get_contents($path);
        try {
            $data = json_decode((string)$raw, true, 8, JSON_THROW_ON_ERROR);
        } catch (\JsonException) {
            throw new ConfigurationException('credentials file is not valid JSON');
        }
        if (!is_array($data)) {
            throw new ConfigurationException('credentials file is not a JSON object');
        }
        return self::fromArray($data);
    }

    /** Detached Ed25519 signature over `$message`. */
    public function sign(string $message): string
    {
        return sodium_crypto_sign_detached($message, sodium_crypto_sign_secretkey(sodium_crypto_sign_seed_keypair($this->signingSeed)));
    }

    private static function b64url(mixed $v, int $bytes, string $name): string
    {
        if (!is_string($v) || preg_match('/\A[A-Za-z0-9_-]+\z/', $v) !== 1) {
            throw new ConfigurationException("$name must be base64url without padding");
        }
        $raw = base64_decode(strtr($v, '-_', '+/') . str_repeat('=', (4 - strlen($v) % 4) % 4), true);
        if ($raw === false || strlen($raw) !== $bytes) {
            throw new ConfigurationException("$name must be $bytes bytes");
        }
        return $raw;
    }

    /** @return array<string,string> */
    public function __debugInfo(): array
    {
        return ['formId' => $this->formId, 'signingSeed' => '***', 'signingPublicKey' => $this->signingPublicKey === '' ? '' : '(set)'];
    }

    /** @return array<string,string> */
    public function jsonSerialize(): array
    {
        return ['formId' => $this->formId, 'signingSeed' => '***'];
    }
}
