<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

namespace FormBackend;

use FormBackend\Exception\InvalidInputException;

/**
 * Turns the caller's fields into the request body and the canonical JSON that is signed. The canonical form is computed from
 * what PHP's own `parse_str` makes of the exact body that is sent, so the signature covers what the receiving side parses
 * (contracts/crypto/signatur.md: sorted keys, JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE, `{"fields":…,"files":[]}`).
 */
final class Canonical
{
    public const MAX_VARIABLES = 1000;   // PHP max_input_vars; the server refuses more
    public const MAX_DEPTH = 64;

    /**
     * @param array<string|int,mixed> $fields name => string|int|nested array of the same
     * @return array{body:string, canonical:string}
     */
    public static function build(array $fields, int $maxBodyBytes = 4_194_304): array
    {
        $count = 0;
        self::validate($fields, 0, $count, true);
        $body = http_build_query($fields, '', '&', PHP_QUERY_RFC3986);
        if (strlen($body) > $maxBodyBytes) {
            throw new InvalidInputException('submission is larger than the configured limit');
        }
        parse_str($body, $parsed);
        return ['body' => $body, 'canonical' => self::canonical($parsed)];
    }

    public const MAX_FILES = 5;
    public const MAX_FILE_BYTES = 19_999_999;
    private const TYPES = ['pdf' => 'application/pdf', 'png' => 'image/png', 'jpg' => 'image/jpeg', 'jpeg' => 'image/jpeg', 'heic' => 'image/heic', 'heif' => 'image/heif'];

    /**
     * Multipart variant. `$files` maps a field name to a path, or to a list of paths (sent as `name[]`), or to
     * `['name' => ..., 'content' => ...]` entries. Only pdf/png/jpg/jpeg/heic/heif below 20,000,000 bytes; the server checks the real content.
     *
     * @param array<string|int,mixed> $fields
     * @param array<string,mixed> $files
     * @return array{body:string, canonical:string, boundary:string}
     */
    public static function buildMultipart(array $fields, array $files, int $maxBodyBytes = 33_000_000): array
    {
        $count = 0;
        self::validate($fields, 0, $count, true);
        $flat = [];   // [wireName, filename, type, content]
        $meta = [];
        foreach ($files as $field => $spec) {
            $field = (string)$field;
            if ($field === '' || preg_match('/\A[A-Za-z0-9_-]{1,100}\z/', $field) !== 1) {
                throw new InvalidInputException('file field names may contain only letters, digits, "_" and "-"');
            }
            $list = is_array($spec) && array_is_list($spec) && !(isset($spec['name']) || isset($spec['content']));
            $items = $list ? $spec : [$spec];
            if ($list && $items === []) {
                continue;
            }
            $metas = [];
            foreach ($items as $item) {
                [$name, $content] = self::readFile($item);
                $type = self::TYPES[strtolower(pathinfo($name, PATHINFO_EXTENSION))] ?? null;
                if ($type === null) {
                    throw new InvalidInputException('unsupported file type (allowed: pdf, png, jpg, jpeg, heic, heif)');
                }
                $flat[] = [$field . ($list ? '[]' : ''), $name, $type, $content];
                $metas[] = ['name' => $name, 'type' => $type, 'error' => 0, 'size' => strlen($content), 'sha256' => hash('sha256', $content)];
            }
            $meta[$field] = $list ? $metas : $metas[0];
        }
        if (count($flat) > self::MAX_FILES) {
            throw new InvalidInputException('too many files');
        }
        $boundary = 'fb' . bin2hex(random_bytes(16));
        $body = '';
        $textPairs = [];
        foreach (explode('&', http_build_query($fields, '', '&', PHP_QUERY_RFC3986)) as $pair) {
            if ($pair !== '') {
                $textPairs[] = $pair;
            }
        }
        foreach ($textPairs as $pair) {
            $p = strpos($pair, '=');
            $body .= "--$boundary\r\nContent-Disposition: form-data; name=\"" . self::quote(rawurldecode(substr($pair, 0, $p === false ? null : $p))) . "\"\r\n\r\n"
                . rawurldecode($p === false ? '' : substr($pair, $p + 1)) . "\r\n";
        }
        foreach ($flat as [$wire, $name, $type, $content]) {
            $body .= "--$boundary\r\nContent-Disposition: form-data; name=\"" . self::quote($wire) . '"; filename="' . self::quote($name) . "\"\r\nContent-Type: $type\r\n\r\n" . $content . "\r\n";
        }
        $body .= "--$boundary--\r\n";
        if (strlen($body) > $maxBodyBytes) {
            throw new InvalidInputException('submission is larger than the configured limit');
        }
        parse_str(http_build_query($fields, '', '&', PHP_QUERY_RFC3986), $parsed);
        return ['body' => $body, 'canonical' => self::canonical($parsed, $meta), 'boundary' => $boundary];
    }

    /** @return array{0:string,1:string} */
    private static function readFile(mixed $item): array
    {
        if (is_string($item)) {
            if (!is_file($item) || !is_readable($item)) {
                throw new InvalidInputException('file not readable');
            }
            if (filesize($item) > self::MAX_FILE_BYTES) {
                throw new InvalidInputException('file is too large');
            }
            $content = file_get_contents($item);
            return [basename($item), $content === false ? '' : $content];
        }
        if (is_array($item) && is_string($item['name'] ?? null) && is_string($item['content'] ?? null)) {
            if (strlen($item['content']) > self::MAX_FILE_BYTES) {
                throw new InvalidInputException('file is too large');
            }
            return [basename($item['name']), $item['content']];
        }
        throw new InvalidInputException('a file must be a path or [name, content]');
    }

    private static function quote(string $s): string
    {
        if (preg_match('/[\x00-\x1F\x7F]/', $s) === 1 || !mb_check_encoding($s, 'UTF-8')) {
            throw new InvalidInputException('names must be valid UTF-8 without control characters');
        }
        return str_replace(['\\', '"'], ['\\\\', '\\"'], $s);
    }

    /**
     * @param array<mixed> $parsed
     * @param array<string,mixed> $files field => file metadata or list of metadata
     */
    public static function canonical(array $parsed, array $files = []): string
    {
        if ($files !== []) {
            ksort($files, SORT_STRING);
        }
        try {
            return json_encode(['fields' => self::sorted($parsed), 'files' => $files], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        } catch (\JsonException) {
            throw new InvalidInputException('fields cannot be encoded (invalid UTF-8?)');
        }
    }

    private static function sorted(mixed $v): mixed
    {
        if (!is_array($v)) {
            return $v;
        }
        if (!array_is_list($v)) {
            ksort($v, SORT_STRING);
        }
        return array_map(self::sorted(...), $v);
    }

    /** @param array<string|int,mixed> $a */
    private static function validate(array $a, int $depth, int &$count, bool $top): void
    {
        if ($depth >= self::MAX_DEPTH) {
            throw new InvalidInputException('fields are nested too deeply');
        }
        foreach ($a as $key => $value) {
            $name = (string)$key;
            if ($name === '' || str_contains($name, "\0") || !mb_check_encoding($name, 'UTF-8')) {
                throw new InvalidInputException('field names must be non-empty UTF-8 without NUL');
            }
            // PHP rewrites "." and " " in top-level names and treats brackets as nesting: such names would not arrive as written.
            if ($top && preg_match('/[.\s\[\]]/', $name) === 1) {
                throw new InvalidInputException('top-level field names must not contain ".", whitespace or brackets');
            }
            if (!$top && str_contains($name, ']')) {
                throw new InvalidInputException('nested field names must not contain "]"');
            }
            if (is_array($value)) {
                self::validate($value, $depth + 1, $count, false);
                continue;
            }
            if (!is_string($value) && !is_int($value)) {
                throw new InvalidInputException('field values must be strings or integers (convert booleans, floats and null explicitly)');
            }
            if (is_string($value) && !mb_check_encoding($value, 'UTF-8')) {
                throw new InvalidInputException('field values must be valid UTF-8');
            }
            if (++$count > self::MAX_VARIABLES) {
                throw new InvalidInputException('too many fields');
            }
        }
    }
}
