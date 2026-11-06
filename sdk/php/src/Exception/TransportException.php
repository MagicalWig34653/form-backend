<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

namespace FormBackend\Exception;

/** The request could not be completed (DNS, TLS, timeout, connection). The submission may or may not have arrived; retry with the SAME idempotency key. */
final class TransportException extends FormBackendException
{
    public function __construct(string $message, public readonly bool $retryable = true)
    {
        parent::__construct($message);
    }
}
