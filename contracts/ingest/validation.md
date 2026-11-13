# Prüfstand P2-1

26.10.2026. Nur statische Vertragsprüfung; keine Produktionsreife.

- OpenAPI-YAML mit lokal vorhandenem PyYAML eingelesen.
- Alle 415 lokalen `$ref`-Verwendungen auf vorhandene Ziele geprüft.
- Neun Operationen (fünf Hauptrouten, vier Skriptaliase), eindeutige operationId.
- Komponentenschemas mit `jsonschema.Draft202012Validator.check_schema` geprüft.
- Fünf synthetische JSON-Antworten gegen ihre zugehörigen Schemas validiert.
- SHA256 des synthetischen Kanonisierungsbeispiels mit Python nachgerechnet;
  kein PHP-/Swift-Gegenbeweis und keine echte Signaturprüfung.
- Abschließende statische Prüfung nach Ergänzung des Legacycodes 501 und der
  unbekannten Key-Zusatzfelder durchgeführt.

Kein vollständiger OpenAPI-Metavalidator installiert (`openapi_spec_validator`
fehlt). Kein Build/Testbefehl im Gerüst. Keine Dienste, keine Altcodeausführung,
keine Laufzeit-/Krypto-/Race-/Proxy-/Uploadtests. Beispiele mit Platzhaltern
sind bewusst nicht sendefertig. Integrationstests/Review und offene Beschlüsse
siehe README. Alle geschriebenen Dateien liegen unter `contracts/ingest/`.
