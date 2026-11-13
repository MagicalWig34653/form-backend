<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

namespace FormBackend\Exception;

/** The server answered with an error status. `status` and the machine `errorCode` (if any) are safe to log. */
final class RejectedException extends FormBackendException
{
    public function __construct(
        string $message,
        public readonly int $status,
        public readonly ?string $errorCode = null,
        public readonly ?int $retryAfter = null,
    ) {
        parent::__construct($message, $status);
    }

    /**
     * True when repeating the same request (same idempotency key) can succeed later. The per-client ingest budget
     * (429 ingest_rate_limited) is retryable by the caller after `retryAfter` seconds; the client itself does not retry it
     * immediately, because that would hit the same budget again.
     */
    public function isRetryable(): bool
    {
        return in_array($this->status, [502, 503, 504], true) || ($this->status === 429 && $this->errorCode === 'ingest_rate_limited');
    }
}
