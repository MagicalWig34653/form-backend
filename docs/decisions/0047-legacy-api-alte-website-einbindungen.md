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

## Nachtrag 14.11.2026: Client-Adresse alter Einbindungen (Karte 4D037986)

- Das Alt-SDK sendet nie die signierte Besucher-IP (ADR 0048); `CLIENTIP-ENCRYPT`/`CLIENTUA-ENCRYPT` bleiben opak und ändern keine Identität. Auf den Legacy-Pfaden zählen Budget (`ingest.requestsPerMinute`) und Missbrauchssperre (`abuse.threshold`) deshalb die Adresse, die `proxiedClientIP` liefert: Peer, oder bei vertrauenswürdigem Peer (`FORM_PUBLIC_TRUSTED_PROXIES`) der erste nicht vertraute Eintrag von rechts in `X-Forwarded-For` (`X-Real-IP` wird nicht gelesen). `ingest.peerRequestsPerMinute` gilt nur für Anfragen mit Besucheranspruch und trifft Legacy-Anfragen nie.
- Belegt (`IngestDBTests`, drei neue Tests; Mutationsprobe: Header ignorieren + Peer-Deckel auf unsignierte Anfragen = 6 Fehlschläge): hinter vertrautem nginx werden Besucher getrennt gezählt (A erschöpft = 429, B läuft weiter, beide Legacy-Pfade teilen den Eimer je Besucher), 200/412 für normales Verhalten, Bann trifft nur den auffälligen Besucher, von unvertrautem Peer gesendete Header wirken nicht. E2E `backend/e2e-legacy.sh` Teil 3 mit echtem Alt-SDK.
- Ohne vertrauten Proxy teilen alle Besucher einer Website EIN Budget und EINE Sperre (Peer). Entschärfung: `ingest.requestsPerMinute` erhöhen (0 = aus), `abuse.threshold` hoch lassen. Das ist hier ohnehin der Normalfall: Der Alt-Webserver ruft das Backend selbst auf, nginx sieht dessen Adresse als `$remote_addr`; die Besucher unterscheidet nur das neue SDK (ADR 0048).

## Nachtrag 14.11.2026 (2): Server-zu-Server-Budget statt Peer-Bann, X-Real-IP (Karte 4D037986)

Entscheidung (Linie: alte Einbindungen laufen ohne Änderung der Website, nie ganze Websites sperren). Sie ersetzt die Aussage des vorigen Nachtrags, alle Besucher einer Website teilten EIN Besucherbudget und EINE Sperre:

- Legacy-Anfrage ohne benannten Besucher (kein verifizierter Anspruch, kein vertrauter Proxy mit nicht vertrauter Besucher-IP): Budget je (Formular, Peer) `ingest.legacyPeerRequestsPerMinute` (Standard 600, 0 = aus) anstelle von `ingest.requestsPerMinute` (60). Keine Sperre allein auf Peer-Identität: weder `abuse.threshold`-Bann noch `abuse.blockedNets`; Fehlversuche (Turnstile, Malware-Treffer) werden beantwortet, aber nicht gezählt. Die Fehlerantworten selbst (412/406/451) bleiben.
- Ist der Besucher vertraut aufgelöst, bleibt es bei Besucherbudget und -bann. Die Pfade `/api/v2/submit/` ändern sich nicht.
- Reihenfolge der Client-IP hinter vertrautem Proxy (`ClientIPResolver`, alle Aufrufer): `X-Forwarded-For` von rechts, sonst `X-Real-IP` (ein gültiger Wert), sonst Peer. Unvertraute Peers: Header wirkungslos. Eine Kette, die nur aus vertrauten Hops besteht, gilt nicht als Besucher.
- Umsetzung: `IngestConfig.clientIPResolved`/`useTrustedProxies`, `SubmitHandler.enforceBudget` und `AbuseProtection.check` unterscheiden `LegacyIngestBackend.isLegacy` und `visitorKnown`.
- Offen: `CLIENTIP-ENCRYPT` wird erst nach Import der Alt-Schlüssel ausgewertet (Folgekarte).

