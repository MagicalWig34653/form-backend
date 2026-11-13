# Sicherheitsrichtlinie

## Sicherheitslücken melden

Bitte melde Sicherheitslücken **nicht** als öffentliches Issue. Nutze stattdessen die private Meldung über GitHub:
**Security → „Report a vulnerability“** in diesem Repository (GitHub Private Vulnerability Reporting).

Hilfreich sind: betroffene Version/Commit, Schritte zum Nachstellen (nur mit synthetischen Daten), erwartetes und beobachtetes Verhalten, mögliche Auswirkung. Schicke keine echten Kundendaten, Schlüssel oder Zugangsdaten.

Wir bestätigen den Eingang in der Regel innerhalb von 7 Tagen und melden uns mit einer Einschätzung. Eine koordinierte Veröffentlichung nach Behebung ist willkommen; Reporter werden auf Wunsch genannt.

## Unterstützte Versionen

Das Projekt befindet sich in früher Entwicklung (siehe [Stand & Roadmap](https://magicalwig34653.github.io/form-backend/status.html)). Sicherheitskorrekturen gibt es für den Stand auf `main` und das jeweils neueste Image `ghcr.io/magicalwig34653/form-backend`.

## Was bewusst so gebaut ist

- Zero-Knowledge für Einsendungen: Der Server speichert nur Chiffrat (HPKE X25519 / AES-256-GCM); private Schlüssel liegen im Browser des Kunden. Entwürfe: [ADR 0016/0024](docs/decisions/).
- Zwei getrennte Listener (öffentlich: SDK, Statistik-Ereignisse, MCP/OAuth; intern: Oberfläche und Verwaltung), Passkey-Anmeldung, Rechte je Anfrage live aus der Datenbank.
- Es gab **noch kein unabhängiges externes Audit.** Interne Sicherheitsreviews sind unter `docs/paritaet/review-*.md` und in den ADRs dokumentiert.

## Nicht im Geltungsbereich

Fehlkonfiguration des Betreibers (z. B. öffentlicher Zugriff auf den internen Port, fehlende TLS-Terminierung am Reverse Proxy), Angriffe, die privilegierten Zugriff auf die Datenbank oder den Server-Schlüssel voraussetzen, und DoS durch reine Volumenlast.
