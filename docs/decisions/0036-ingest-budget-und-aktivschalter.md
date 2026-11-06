# ADR 0036: Ingest-Budget je Client und Aktivschalter

Status: angenommen (Parität FA-015, FA-021; Werte sind Vorschläge und per Setting änderbar)

## Entscheidung
- Ingest-Rate-Limit: Fensterbudget (feste 60 s) je Formular und Client-IP. Zähler liegt in `auth_throttles` (Scope `admin-route`, Subjekt nur als HMAC unter dem Serverschlüssel; keine Klartext-IP). Setting `ingest.requestsPerMinute` (Standard 60, 0 = aus, ENV `FORM_INGEST_REQUESTS_PER_MINUTE`, ohne Neustart wirksam). Die Client-IP kommt aus der Trusted-Proxy-Logik des öffentlichen Listeners (`IngestConfig.clientIP`).
- Zeitpunkt: nach Formularauflösung (unbekannte/inaktive Formulare liefern weiter 404 ohne Zählung), vor Body-Parsing, Signaturprüfung, Hashing und Sealing. Idempotente Wiederholungen zählen mit. Überschreitung: 429 mit `Retry-After`, Code `ingest_rate_limited`.
- SDK: `RejectedException::isRetryable()` ist für 429 `ingest_rate_limited` wahr; der Client wiederholt nicht sofort (gleiches Budget), sondern wirft, damit der Aufrufer nach `retryAfter` (max. 60 s) mit demselben Idempotency-Key erneut sendet.
- Aktivschalter: `PUT /admin/api/v1/tenants/{t}/forms/{f}/active` mit `{"active":bool}`, Antwort 204. Recht `release.publish` (kein neues Recht, da der Katalog kompiliert und gegen die DB geprüft wird), keine frische Anmeldung, Audit `form.activate`/`form.deactivate`. PWA: Schalter im Überblick, nur mit `release.publish` und veröffentlichtem Formular, Bestätigung beim Pausieren.

## Grenzen
- Ein NAT-Client teilt sich das Budget; Standard 60/min ist bewusst großzügig. Keine Gesamtbegrenzung je Formular.
- Zähler fallen über die bestehende Throttle-Bereinigung (`expires_at`) weg.
