# ADR 0034: Serverseitige Feldvalidierung und Transportfelder im Eingang

Status: angenommen (Parität FA-024, Muss)

## Entscheidung
- Nach Signaturprüfung, Idempotenz und Missbrauchsschutz validiert der Eingang die Felder gegen die veröffentlichte Formularversion der aufgelösten Release (`SubmissionValidation`): Pflichtfelder (nicht bei `hidden`), Art (date, number, boolean; E-Mail-Syntax bleibt bei der Mail-Schicht), `minLength/maxLength` (Alias `minLaenge/maxLaenge`), `pattern` (Alias `muster`, vollständiger Treffer), `enum` (Aliase `options`, `erlaubt`), `minimum/maximum`, feste Werte (`fixedValue`), unbekannte Felder bei `unknownFields: reject`. Dateifelder: nur Pflichtprüfung.
- Fehler: `422 submission_invalid` mit **Feldnamen, nie Werten**. Formulare ohne Feldschema bleiben akzeptiert; Felder mit Präfix `_` (z. B. `_statistics`) gelten als Transport und werden nicht geprüft.
- Transportfelder (`csrf_token`, `cf-turnstile-response`, `g-recaptcha-response`, `h-captcha-response`; identisch zu den reservierten Namen in `DocumentValidator`) werden vor dem Verschlüsseln entfernt und gelangen weder in Speicher noch Mail, Webhook oder Flow.

## Signatur
Signatur und Idempotenz-Digest bleiben auf den Originalbytes. Die PWA prüft beim Entschlüsseln keine Signatur über den Klartext (geprüft in `pwa/src/lib`), das gesicherte Paket enthält daher die bereinigte kanonische JSON-Fassung. Wird später eine Klartextsignatur im Browser geprüft, muss sie über die bereinigten Bytes oder das gespeicherte Originalhash-Feld erfolgen.

## Folgen
Regeln im `validation`-Objekt sind eine pragmatische Teilmenge von JSON-Schema; neue Regeln brauchen einen Test in `SubmissionValidationTests`.

## Offen
`unknownFields: discard` verwirft unbekannte Felder vor dem Verschlüsseln (`discardUnknown`).
