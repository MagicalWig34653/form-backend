<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

namespace FormBackend;

use FormBackend\Exception\FormBackendException;

/** The accepted submission. `id` is stable across retries with the same idempotency key. */
final class Submission
{
    private function __construct(public readonly string $id)
    {
    }

    public static function fromResponse(string $body): self
    {
        $d = json_decode($body, true, 8);
        $id = is_array($d) ? ($d['submission']['id'] ?? null) : null;
        if (!is_string($id) || preg_match('/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/', $id) !== 1) {
            throw new FormBackendException('unexpected answer from the server');
        }
        return new self($id);
    }
}
