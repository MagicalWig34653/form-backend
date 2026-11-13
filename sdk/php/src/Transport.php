<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

namespace FormBackend;

/** Sends one POST. Implementations must throw `TransportException` for anything that is not an HTTP response. */
interface Transport
{
    /**
     * Implementations must enforce timeoutMs as an upper bound for the complete attempt.
     * @param array<string,string> $headers
     * @return array{status:int, headers:array<string,string>, body:string} header names lower-cased
     */
    public function post(string $url, string $body, array $headers, int $timeoutMs): array;
}
