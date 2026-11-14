<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

namespace FormBackend;

/**
 * Determines the address of the website VISITOR for the backend's abuse protection (ADR 0047).
 *
 * Default: `REMOTE_ADDR` (the TCP peer of this web server). A forwarding header is read ONLY when `REMOTE_ADDR` lies inside
 * `$trustedProxies` (your own reverse proxy/CDN ranges); `X-Forwarded-For` is evaluated from the right and the first hop that is
 * not a trusted proxy wins (the left part is controlled by the visitor and ignored), any other header (e.g. `CF-Connecting-IP`)
 * is taken as a single address. Anything malformed yields the peer address: never a spoofable value.
 */
final class VisitorIp
{
    /** @param list<string> $trustedProxies CIDR ranges or single addresses of YOUR proxies; empty = never believe a header */
    public static function fromServer(array $server, array $trustedProxies = [], string $header = 'X-Forwarded-For'): ?string
    {
        $peer = self::normalize($server['REMOTE_ADDR'] ?? null);
        if ($peer === null) { return null; }
        if ($trustedProxies === [] || !self::inAny($peer, $trustedProxies)) { return $peer; }
        $key = 'HTTP_' . strtoupper(str_replace('-', '_', $header));
        $raw = $server[$key] ?? null;
        if (!is_string($raw) || $raw === '') { return $peer; }
        if (strcasecmp($header, 'X-Forwarded-For') !== 0) { return self::normalize(trim($raw)) ?? $peer; }
        $hops = array_map('trim', explode(',', $raw));
        if (count($hops) > 20) { return $peer; }
        foreach (array_reverse($hops) as $hop) {
            $ip = self::normalize($hop);
            if ($ip === null) { return $peer; }          // never fall through to a spoofable value
            if (!self::inAny($ip, $trustedProxies)) { return $ip; }
        }
        return $peer;
    }

    /** Canonical text: dotted quad for IPv4 (incl. IPv4-mapped IPv6), compressed form for IPv6; null if not an address. */
    public static function normalize(mixed $ip): ?string
    {
        // Strict character set first: libc parsers differ on zone ids (%eth0), whitespace and similar extras.
        if (!is_string($ip) || strlen($ip) > 45 || preg_match('/\A[0-9A-Fa-f:.]+\z/', $ip) !== 1) { return null; }
        $bin = @inet_pton($ip);
        if ($bin === false) { return null; }
        if (strlen($bin) === 16 && str_starts_with($bin, str_repeat("\0", 10) . "\xff\xff")) { $bin = substr($bin, 12); }
        $text = inet_ntop($bin);
        return $text === false ? null : $text;
    }

    /** @param list<string> $ranges */
    private static function inAny(string $ip, array $ranges): bool
    {
        foreach ($ranges as $range) {
            if (self::inRange($ip, (string)$range)) { return true; }
        }
        return false;
    }

    private static function inRange(string $ip, string $range): bool
    {
        $parts = explode('/', $range, 2);
        $net = self::normalize($parts[0]);
        if ($net === null) { return false; }
        $a = inet_pton($ip); $b = inet_pton($net);
        if ($a === false || $b === false || strlen($a) !== strlen($b)) { return false; }
        $bits = isset($parts[1]) ? (ctype_digit($parts[1]) ? (int)$parts[1] : -1) : strlen($a) * 8;
        if ($bits < 0 || $bits > strlen($a) * 8) { return false; }
        $full = intdiv($bits, 8); $rest = $bits % 8;
        if ($full > 0 && substr($a, 0, $full) !== substr($b, 0, $full)) { return false; }
        if ($rest === 0) { return true; }
        $mask = (0xFF << (8 - $rest)) & 0xFF;
        return (ord($a[$full]) & $mask) === (ord($b[$full]) & $mask);
    }
}
