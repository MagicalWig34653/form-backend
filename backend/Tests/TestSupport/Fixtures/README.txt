SYNTHETIC TEST CERTIFICATE AND KEY ONLY - generated for unit tests, never use elsewhere. Regenerate: openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout test-key.pem -out test-cert.pem -days 36500 -subj /CN=smtp.test.invalid -addext subjectAltName=DNS:smtp.test.invalid,IP:127.0.0.1

Variants for IP-literal host verification (same key as test-key.pem; same openssl command with other -out/-subj/-addext):
- test-cert-otherip.pem: SAN DNS:smtp.test.invalid, IP:192.0.2.1 (does not cover 127.0.0.1)
- test-cert-noip.pem: CN=127.0.0.1 but SAN only DNS:smtp.test.invalid (no IP SAN; the CN must not be accepted for IPs)

- test-cert-expired.pem: same key and names as test-cert.pem, valid only 2024-01-01 .. 2024-01-02 (always expired, self-signed). openssl req -x509 -key test-key.pem ... -not_before 20240101000000Z -not_after 20240102000000Z
