# ADR 0047: Legacy-API für alte Website-Einbindungen

Status: angenommen (Todolino 4D037986; Befund Feature-Matrix 14.11.2026, §1). Schalter standardmäßig AN.

## Problem

Alte Websites binden das alte Backend (form-backend_bvk) über das PHP-Client-SDK ein (`providers/Clients/Backend.php` = v1, `BackendV2.php` = v2). Gegen das neue Backend ergab das 404 beim Konfigurationsabruf, 403 beim Absenden, 422 statt 412 bei Feldfehlern und `problem+json` statt der alten Fehlerformate. Ein reiner DNS-Umzug hätte jede Website gebrochen.

## Entscheidung

Eigenes SwiftPM-Target `FormLegacyAPI` (nur Übersetzung, keine zweite Validierungs-/Speicherlogik). Es spricht ausschließlich über die schmale Fassade `LegacyIngestBackend` (FormIngest) mit der neuen Einsende-Pipeline. Registriert wird es nur am öffentlichen Listener (`main.swift`, direkt nach `IngestSetup.register`).

Alt-Verhalten (aus dem alten Repo, `www/api/*`, `providers/Response.php`, `FormularKonfiguration.php`, `AnfrageIngest.php`):

| Pfad (alle `POST`) | Alt-Antwort | Neu |
|---|---|---|
| `/endpoint/?f=` (+ `index.php`) v1-Einsendung | Erfolg `200 - OK` (Text), Fehler `<code> - <Statustext>` (Text) | gleiche Pipeline wie `/api/v2/submit/` |
| `/api/getFormData.php?z=` v1-Konfig | `{"cf-sitekey":…|null,"mode":"production"|"testing"}` | aus veröffentlichter Release-Policy |
| `/api/v2/form/?f=` v2-Konfig | `{"configuration":{"cfSitekey","mode","signaturschluesselHinterlegt"},"fields":[{name,type,required,rule}]}` | aus veröffentlichter Formulardefinition |
| `/api/v2/submit/?f=` (Pfad existiert schon) | Erfolg `{"submission":{"id"}}`, Fehler `{"error":{"code","status"}}` | Fehlerformat alt, wenn der Aufrufer die Alt-SDK-Köpfe `CLIENTUA-ENCRYPT`/`CLIENTIP-ENCRYPT` sendet (das neue SDK sendet sie nie) |
| `/api/v2/key/` Schlüsselanmeldung | – | konstant 403 (die alten symmetrischen Client-Schlüssel werden nicht importiert, eine Anmeldung ist nicht prüfbar) |

Statusabbildung neu → alt nur in der Legacy-Antwort: Feldfehler 422 → 412; fehlendes Turnstile-Token 412, fehlgeschlagene Prüfung 406; Malware 415 → 451; 429 mit `Retry-After`; sonst unverändert. Interne Fehler: 500, nur Fehlertyp im Log. Die Einwilligung 418 entfällt (kein Alt-Äquivalent im neuen Modell).

## Sicherheit

- Gleich wie neu (selber Code): Formularauflösung (unbekannt/inaktiv/gesperrter Kunde = 404, kein Orakel), Ingest-Budget je (Formular, Client-IP), Body-Limit, Parser, Origin-/Host-Regeln, Abuse-Policy, Feldvalidierung, Versiegelung, Idempotenz. Fehlertexte enthalten nie Werte oder Feldnamen. Keine Klartext-IPs.
- Konfigabruf zählt in einem eigenen Eimer `ingestcfg` (gleiches Limit), damit Seitenaufrufe das Absende-Budget nicht verbrauchen.
- Konfigabruf verrät nur, was das Alt-Backend verriet (Sitekey, Modus, Feldnamen/-typen/Pflicht/Muster) und nur zum bekannten aktiven Formular.
- **Bewusste Abweichung (Risiko):** Auf den Legacy-Pfaden nimmt ein Formular OHNE hinterlegten Signaturschlüssel unsignierte Anfragen an (alt: Signatur nur bei hinterlegtem Schlüssel; v1 hatte nie eine). Die alten Schlüssel werden nicht importiert, ohne diese Regel wäre jede alte Einbindung 403. Mit hinterlegtem Schlüssel gilt unverändert die Signaturpflicht (v2-Konfig: Signatur über `/api/v2/form`). Wer die UUID kennt, kann also senden, solange kein Schlüssel hinterlegt ist; Schutz bleibt Budget, Abuse-Policy, Origin/Host-Regeln und Validierung. Gegenmaßnahme: nach dem Umbau der Websites Schalter AUS stellen oder Formularschlüssel ausstellen.

## Schalter

Setting `compat.legacy` (ENV `FORM_COMPAT_LEGACY`, Gruppe „Umstieg“, Standard `true`, ohne Neustart wirksam). AUS = alle Legacy-Pfade antworten 404 wie unbekannte Routen und der Alt-Erkennungszweig am Submit-Pfad ist inaktiv. Eingetragen in SettingsRegistry, `config-registry.tsv`, `config-help.tsv`, `stack.yaml`, `compose.yaml`, beide Env-Vorlagen und `docker-entrypoint.sh`.

## Grenzen

- Echte Alt-Signaturen können nicht geprüft werden, solange die Schlüssel fehlen (Importer: andere Karte). Ein importierter Schlüssel aktiviert die Signaturpflicht automatisch auch auf den Legacy-Pfaden.
- Das Alt-SDK v1 hat die Backend-URL hart im Code (`alt-backend.example.invalid`): DNS/Proxy muss den Namen auf das neue Backend lenken.
- Besucher-IP: Alt-Köpfe `CLIENTIP-ENCRYPT` bleiben ignoriert (siehe Client-IP-Karte); die Sperre zählt die aufgelöste Peer-IP.
- Alt-Statistik, Mail-Proxy-424, Idempotenz-Konflikt-Code des Alt-Systems nicht nachgebildet; Idempotenz-Konflikt bleibt 409.
