# P2-5: Identität, Rechte und Verwaltungszugänge

Stand: 26.10.2026. SPDX-License-Identifier: AGPL-3.0-only.
Status: **Vertragsentwurf, keine Implementierung**. Beschlossen sind ausschließlich
die ausdrücklich referenzierten Nutzerentscheidungen. Sämtliche neuen technischen
Bezeichner, Pfade, Rollenfeinheiten, Protokolldetails und Zahlen dieses Pakets sind
**VORGESCHLAGEN**, auch wenn eine einzelne Tabellenzelle das Wort nicht wiederholt.
Eine Spezifikation ist hier keine Freigabe zur Implementierung offener Entscheidungen.

## Paketvertrag

Ziel: gemeinsame Autorisierung und überprüfbare Schnittstellen für PWA, REST und
MCP im Mandantenmodell Kunde > Formulare. Dateibesitz: ausschließlich
`contracts/auth/`, ein schreibender Agent. Keine Anwendung, Migration oder Änderung
des Altprojekts. Abnahme: Matrix für alle drei Rollen; Anmeldung mit DB-Sitzungen;
REST-Ressourcen mit Endpunktrechten und Altzuordnung; MCP einschließlich Tokens,
OAuth und menschlicher Veröffentlichung; Domain-/Proxyvertrag; offene Details und
noch ausstehende Integrationsprüfungen nachvollziehbar dokumentiert.

| Datei | Vertrag |
| --- | --- |
| [rechte.md](rechte.md) | Einzelrechte/Rechtegruppen, Vorlagen, Mandantengrenzen, Schlüsselzugang und gemeinsamer Prüfpfad |
| [anmeldung.md](anmeldung.md) | Passwort, TOTP, WebAuthn, DB-Sitzung, CSRF und vorgeschlagene Schwellen |
| [admin-api.openapi.yaml](admin-api.openapi.yaml) | OpenAPI-3.1-Entwurf; `x-permissions` als Konjunktion und `x-legacy-routes` pro Operation |
| [p5b-ergaenzung.md](p5b-ergaenzung.md) | P5-B-Ergänzung E1–E8 (Entwurfsspeicher, Passkey, Login-Abschluss, Fehlerhülle, Hash, Rechte, Release-Umfang, Zeitkanäle) |
| [mcp.md](mcp.md) | Werkzeuge, Eingaben/Ausgaben, Token-, Scope-, OAuth- und Veröffentlichungssperren |
| [domains-proxy.md](domains-proxy.md) | Manuelle Domainzuordnung, feste Admin-Origin/RP-ID, Headervertrauen |
| [validate.py](validate.py) | Statische Offline-Prüfung; Aufruf `python3 contracts/auth/validate.py` |
| [HANDOFF.md](HANDOFF.md) | Tatsächlicher Arbeitsstand, Prüfungen, Grenzen und nächste Schritte |

## Maßgebliche Quellen und Widersprüche

- `../../docs/decisions/0001-grundentscheidungen-p1.md`: Kunde als Mandant,
  Rollen Admin/Betreuer/Kunde, englische technische Namen/deutsche Nutzertexte.
- `../../docs/decisions/0002-sicherheit-und-cutover.md`, Nr. 16/19:
  Login-Lockout/Backoff je Konto und IP, alle Admin-Routen begrenzen;
  Mail-Cron meldet, manueller Resend mit Passphrase, kein Klartext für Auto-Retry.
- `../../docs/decisions/0003-produkt-und-betrieb.md`, Nr. 4/8/9/12/13:
  Kundenschlüssel mit Generationen/Recovery; manuelle Domains ohne DNS-Nachweis;
  Debug maskiert, TTL 15 Minuten, Klartext mit Recht und Schlüssel, Export maskiert;
  Admin-Domain/RP-ID erhalten; Veröffentlichung nur durch bestätigende Menschen.
- `../../docs/ANFORDERUNGEN.md`, `../../docs/SICHERHEIT-UND-DATEN.md` und
  `../../docs/PARITAET.md`, ergänzt durch `../../docs/paritaet/A-routen-handler.md`,
  `review-A.md` und `B-funktionen-felder.md`. Reviews korrigieren die Berichte;
  ADRs ersetzen ältere Aussagen „offen“ zu bereits entschiedenen Punkten.
- `../flow/release.schema.json` verlangt `publication.actorKind = human` und
  `confirmationAuditId`. Diese Felder sind Ergebnisse der serverseitigen
  Bestätigung, keine vom Agenten einreichbaren Autorisierungsnachweise.
- `../ingest/ingest.openapi.yaml` bleibt eigener Eingangskontrakt. Identität von
  Admins und Herkunftsautorisierung einer Einsendung sind unterschiedliche Dinge.

Altprojekt ausschließlich gezielt und statisch gelesen: `providers/FormAccess.php`
und `providers/Passkey.php` (relative Pfade unter `form-backend_bvk`). Keine
Konfigurationswerte oder Secrets erhoben. Der konkrete bestehende Domain-/RP-Wert
bleibt daher **OFFEN**, seine unveränderte Übernahme ist **BESCHLOSSEN**.

## Parität und bewusste Entwurfsänderungen

Die OpenAPI ist ein neuer Verwaltungsvertrag, kein Versprechen identischer
HTML-Antworten alter Seiten. `x-legacy-routes` bezeichnet fachliche Herkunft,
keine automatische Weiterleitung oder Abschaltung. Direkte `/index.php`-Adressen,
PWA-Assets und nginx-Fallback-Unterschiede aus review-A M01–M03 sind im
Kompatibilitätsmodul zu entscheiden. Keine mutierenden GETs im neuen Entwurf;
Abmeldung wird POST+CSRF. REST meldet 401/403/404 statt Meta-Refresh mit HTTP 200.
Diese Änderungen sind **VORGESCHLAGEN** und benötigen Koordinationsabnahme.

Neue Entwurfs-/Testrechte für Betreuer sind eine **VORGESCHLAGENE** Erweiterung
gegenüber Admin-only `/forms/`. Webhookkonfiguration bleibt formularbezogen, wird
aber als produktionswirksame Änderung einer menschlichen Veröffentlichung
unterworfen. Alte Zuordnungen dürfen nicht still zu Zugriff auf alle Formulare
eines neuen Mandanten erweitert werden. Hold/Nachschutz, Schlüsselrotation,
Betroffenenrechte, Mail-/Proxyprofile, Vertrauensnetze, Audit und Benachrichtigungen
bleiben Paritätsanforderungen; nicht im minimalen OpenAPI ausgearbeitete Aktionen
sind in HANDOFF ausdrücklich aufgeführt und gelten nicht als gestrichen.


## Aktueller Stand ADR 0004

[rechte.md](rechte.md) und OpenAPI ersetzen die feste Rollenmatrix durch
konfigurierbare Einzelrechte/Gruppen mit Scope, Revision und Widerruf.
Admin/Betreuer/Kunde sind Vorlagen. Flowrechte und menschliche Fortsetzung sind
in [wiederanlauf.md](../flow/wiederanlauf.md), Hosttrennung in
[domains-proxy.md](domains-proxy.md), OAuth-/MCP-Neuanmeldung statt Credentialübernahme (ADR 0005 D4) in [mcp.md](mcp.md)
und [Migrationsmapping](../data/migration-mapping.md) angeschlossen.
Neue Detail-DTOs bleiben VORGESCHLAGEN; Zahlenwerte sind nicht bestätigt.
