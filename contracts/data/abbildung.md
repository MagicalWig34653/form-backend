# Gemeinsame technische Abbildung (H01, H03, H06, M01, M03)

Stand 27.10.2026. SPDX-License-Identifier: AGPL-3.0-only.
Status: **VORGESCHLAGEN**, technische Vertragskorrektur; keine neue Produktentscheidung,
keine ausgeführte Migration. Dieser Nachtrag ersetzt widersprechende ältere
technische Beschreibungen in den fünf Vertragspaketen. Nicht freigegebene
Produktsemantik bleibt OFFEN.

## Identitäten und Import

`../flow/common.schema.json` definiert `uuid`, `kid`, portable `id`, `reference`
und `resourceReference`. Kunde (`tenantId` = SQL `customer_id`), Formular,
Ansicht, Workflow, Release, Lauf, Einsendung, Objekt, Sitzung und Generation
verwenden Ressourcen-UUIDs. Portable Modul-/Baustein-/Skript-/Template-/Paket-
und Knotenkennungen bleiben lesbare `id`; sie sind keine Admin-URL-IDs.
UUID-Darstellung: lowercase mit Bindestrichen; SQL BINARY(16) entsteht durch
Entfernen der Bindestriche und Hexdekodierung in Textreihenfolge, ohne Byte-Swap.
Rückweg: dieselben 16 Bytes als lowercase UUID. Keine Umwandlung durch Hashen
oder stilles Neunummerieren einer bereits referenzierten Identität.

`resource_versions` bildet `(Kunde, Ressourcenart, UUID, Semver)` bijektiv auf
`version_no` der jeweiligen SQL-Ressource und denselben Inhaltsdigest ab.
`contract_version` ist die Schemaversion, nicht die Inhaltsversion. Semver wird
nicht arithmetisch in BIGINT gepackt. Abweichender Digest bei belegter Version
ist Konflikt. Dienst schreibt Mapping und Versionszeile atomar und prüft den
jeweiligen Ressourcen-FK; die polymorphe Mappingtabelle ersetzt keinen FK.
Release-ID bezeichnet genau einen unveränderlichen Release; dessen Semver und
`release_version_no` dürfen danach nicht anderweitig belegt werden.

Import verwendet `migration_objects`: Quellnamespace+Tabelle+Schlüssel+Zielslot
bindet dauerhaft die Ziel-UUID/Versionszuordnung. Vorhandene gültige eindeutige
UUIDs erhalten; fehlende oder kollidierende Quell-IDs vor Hashbildung explizit
zuordnen und bei Wiederholung wiederverwenden. Kunden-/globaler Schlüsselschnitt
bleibt OFFEN; keine willkürliche Kundenzuweisung. Portable Paketreferenzen werden
vollständig aufgelöst, umgeschriebene Definitionen erhalten neue Hashes und sind
nur Entwürfe. Historische Hashes/Signaturen/Releasebelege bleiben als Herkunft
unverändert, niemals als Beleg für umgeschriebene Definitionen verwenden.

`customer_key_generations.generation_id` ist die globale UUID für Auth-DTOs.
Sie bildet eindeutig auf `(customer_id,kid,generation_no)` ab; die letzten
beiden Paare sind je Kunde ebenfalls eindeutig. `protectedRef.keyGeneration`
ist `generation_no` im expliziten Kundenkontext. `debug.keyIds` enthält `kid`.
Keine direkte UUID→kid-Konvertierung. Alle Angaben gegen denselben DB-Satz und
gegen `kid = SHA256(pk_D_raw)[0:8]` als Hex prüfen; Kollision mit abweichendem
Public Key ablehnen. Globale Altgenerationen bleiben bis Kundenentscheidung
OFFEN. `identity-example.json` verbindet Admin-URL, Flowbeispiele und SQL-Bytes;
die dortige Generation ist nur eine Zuordnungsfixture, kein Kryptovektor.

## Generation am Objekt

Neue Annahme sperrt die Kundengenerationszeile gemeinsam mit Rotation, löst
die aktive Generation serverseitig auf und bindet jedes neue Objekt an deren
`kid`. Falls vor Persistenz ein anderer Writer gewonnen hat, Transaktion neu
prüfen; keine neue Annahme unter auslaufender Generation. Release und gehashte
Formulardefinition bleiben unverändert. Historische Objekte behalten ihre
jeweilige Generation bis zum geprüften Umhängen. Mehrere Objekte einer
Einsendung können danach verschiedene Generationen haben. `security` enthält
keine konkrete `customerKeyGeneration` mehr. ADR 0004 H05: neue Speicherung hpke-v2; Transport separat in ../crypto/transport.md, sym-v2-Speicherprofil gesperrt.

## Totale DTO↔SQL-Abbildung

| Flowzustand (mit Diskriminator) | SQL workflow_runs.state |
| --- | --- |
| queued | ready |
| running | running |
| waiting + timer oder approval | waiting |
| waiting + module-pause | paused |
| waiting-manual + manual-resend oder crash-recovery | waiting-manual |
| succeeded | complete |
| failed | failed |
| uncertain | uncertain |
| cancelled | cancelled |

SQL `suspension_json` bewahrt alle Suspensionfelder; Checkpoint/Budget bleiben
verlustfrei. `waiting` ohne timer/approval und `paused` ohne module-pause sind
ungültig; keine Ersatzzuordnung. Reverse-Mapping nutzt denselben Diskriminator.
`uncertain` ist ein dauerhafter unklarer Laufzustand ohne automatische Freigabe;
die menschliche Klärung/Freigabe erfolgt nach ../flow/wiederanlauf.md. Lease nur bei running.

Technischer Übergangsvorschlag: ready→running; running→waiting/paused/
waiting-manual/complete/failed/uncertain; waiting/paused→ready nur nach erfülltem Gate UND bewusster menschlicher Freigabe; waiting-manual/uncertain→ready nur nach gesonderter autorisierter Klärung;
nichtterminale Zustände→cancelled; complete/failed/cancelled terminal. Jeder
Übergang per Revision/Fence und atomarem Checkpoint. Diese Tabelle erteilt keine Flowrechte; aktuelle Rechte und Menschfreigabe
nach ADR 0004/../flow/wiederanlauf.md sind zusätzlich erforderlich.

Auth/Ingest `production`↔SQL/Flow `production`, `testing`↔`test`.
SQL `legacy-unknown` besitzt keine ausführbare Flowentsprechung: nur explizite
Importprojektion, kein Default auf production/test. Mail-Altmodus bleibt als
Originalbytes erhalten, unbekannte Altwerte werden nicht umgedeutet.
Crypto `aktiv`↔SQL `active`, `auslaufend`↔`retiring`.
Effektstatus prepared/in-flight/confirmed/uncertain/failed wird jeweils identisch
abgebildet. Effektidentität: `(run_id,nodeId,visit,effectSlot)` entsprechend
SQL UNIQUE; Laufidentität: `(Kunde,Einsendung,Release,runSlot)`.
Bewusst neuer Lauf erhält neuen runSlot und neue Lauf-UUID; Wiederholung behält
beides. Effektslot steht explizit im DTO, SQL effect_slot entspricht ihm.
Externe Idempotenzschlüssel werden aus dieser Identität stabil abgeleitet bzw.
einmal vergeben und gespeichert; sie sind kein Nachweis externer Deduplizierung.

## Drei Idempotenzbereiche

1. Ingest: `(Kunde,Formular,SHA256(getrimmte Headerkeybytes))`. Release/Modus
   und geprüfter Requestdigest sind gebundene Werte, keine Scopeerweiterung.
   Derselbe Key darf beim Release-/Moduswechsel keinen zweiten Eingang erzeugen.
   Vor erster Außenwirkung Reservierung samt stabiler submission_id, Release,
   Modus, Digest, Lease/Fence persistieren. Replay prüft erneut Signatur und
   Rechte/Herkunft, benutzt die ursprüngliche Bindung und das gespeicherte
   Ergebnis; geänderter Digest ergibt 409. Bei offener Reservierung bleiben
   ursprünglicher Modus/Release maßgeblich, unzulässige Fortsetzung ergibt
   Konflikt. Legacytreffer ohne Hash werden als legacy-missing/review behandelt;
   ob alte 200-Antworten beibehalten werden, bleibt OFFEN, keine Außenwirkung.
2. Ausführung: `(Kunde,Formular,Einsendung,Release,runSlot)`. Interne
   `idempotency.key` ist eine gesonderte generierte portable Laufkennung und
   niemals der bis 190 Byte lange freie Ingestheader. SQL UNIQUE löst auf run_id
   auf, ursprünglicher Digest/Checkpoint bleiben gebunden.
3. Verwaltung: `admin_action_idempotency` bindet Akteurart+ID, Kunde, konkrete
   Aktion, Ziel-ID und Keydigest an Requestdigest sowie stabile Ergebnis-ID.
   Hash gehört nicht in den Scope: geänderter Inhalt ist 409. Vor Außenwirkung
   reservieren, aktuelle Rechte bei jedem Aufruf prüfen. Veröffentlichung
   reserviert Release-ID und verbraucht Bestätigung samt Release/Ledgerabschluss
   in einer Transaktion. Antwortverlust liefert bei gleichem Key denselben
   Release ohne erneuten Bestätigungsverbrauch. Andere Keys dürfen eine schon
   verbrauchte Bestätigung nicht erneut verwenden. Unklare externe Effekte
   bleiben uncertain und werden nicht blind wiederholt.

Löschen setzt einen inhaltsfreien Tombstone (`result_state=deleted` bzw.
Aktionsstate deleted); ein Replay erzeugt innerhalb der Bindungsfrist keinen
Ersatz. Konkrete Fristen und öffentliche Antwort auf gelöschte Ergebnisse sind
**OFFEN**. Bis Abnahme keine automatische Ledger-/Tombstonelöschung; dies ist
eine Implementierungssperre, keine beschlossene unbegrenzte Retention.
Beispielzeiten (z.B. sieben Tage) sind nur VORGESCHLAGEN. Keine gespeicherten
Klartextantworten oder ungebundenen Keys als Retryhilfe. Idempotenz ersetzt
weder die fehlende Signaturbindung des Headers noch Empfängerdeduplizierung.

## Vertragsrunde 3 — Anschlussbefunde (VORGESCHLAGEN, 28.10.2026)

**R01 Auslieferungsstand.** `domain_bindings` trägt `release_id`, `view_id`
(zusammengesetzter FK auf `release_views`: derselbe Kunde/Formular/Release),
`revision` und `confirmation_audit_id`. Ein Ansichtshost liefert exakt die
gebundene `(release_id, view_id)`; `forms.current_release_id` ist für die
Hostauslieferung nie Quelle. Aktivierung (`enabled=1`) erfordert Release und
Ansicht; produktive Aktivierung zusätzlich Audit-Beleg der menschlichen
Bestätigung dieser `revision`. Änderung (Host, Release, Ansicht, enabled) =
eine Transaktion: `SELECT … FOR UPDATE` auf die Zeile, `If-Match`/`revision`
prüfen, Release in `releases` und `release_views` gegen Kunde/Formular prüfen,
Bestätigung an `(domainId, expectedRevision, hostname, releaseId, viewId)`
binden und verbrauchen, `revision+1`, Audit. Konkurrierende Änderung → 412/409,
die ausstehende Bestätigung ist durch die Revision automatisch ungültig.
Inaktive Bindung (`enabled=0`) liefert 421 und behält Release/Ansicht als Beleg.
**BESCHLOSSEN ADR 0005 D1:** Eine Domain folgt einem neuen Release nicht
automatisch (explizit bestätigte Domainänderung, optional im selben
Bestätigungsdialog wie die Veröffentlichung). Dieselbe Bindung ist auch für
API-/Ingest-Hosts koppelbar: VORGESCHLAGEN `api_host_forms.release_id` (NULL =
ungebunden) mit `binding_revision`, `changed_by/changed_at`,
`confirmation_audit_id` und FK `(customer_id,form_id,release_id)` auf `releases`.
Gebundene Hosts liefern nie aus `forms.current_release_id`; Auflösung weiter über
das signierte Formular (ADR 0004 Nr. 5). Details: `../auth/domains-proxy.md`.

**R03 Signierer.** Einsendungen halten den akzeptierten Signierer
(`signer_kind`: `native`, `legacy-adapter`, `exception`; Generation; ggf.
`adapter_binding_id`). `native` löst gegen `form_protocol_keys(purpose='ed25519')`,
`legacy-adapter` ausschließlich gegen `adapter_signers` der durch das mTLS-
Zertifikat bestimmten `legacy_adapter_bindings`-Zeile. Kein Pfad probiert den
jeweils anderen Satz. Details: `../crypto/signatur.md`, `../ingest/legacy-adapter.md`.

**R05 Transportpolitik.** `form_versions.transport_policy` ist Teil der
versionierten Formulardefinition (`security.transport` in `form.schema.json`),
wird also nur über Release/Bestätigung wirksam. Verhalten: `../crypto/transport.md`.

**R06 Digest.** Transport und reguläre Routen bilden denselben `request_digest`
(siehe `../ingest/README.md`, Abschnitt R06); `ingest_idempotency` benötigt keine
Spalte für den Hüllenhash.

**Runde 4 D1/M1 (VORGESCHLAGEN).** `ingest_idempotency.request_digest` und
`workflow_runs.request_digest` enthalten den HMAC-SHA256 des Fachdigests mit einem
Formularschlüssel (`form_protocol_keys purpose='digest-hmac'`, Generation in
`digest_key_generation`), nie den rohen Digest (`../ingest/README.md`, Runde 4 D1).
`submissions.mail_manifest_payload_sha256` pinnt das Manifestobjekt (Prüfschritt 2a in
`objektinventar.md`); `adapter_replays` hält das Replayregister des Adapterpfads;
`adapter_signers.public_key` ist global eindeutig.

**M03 Antwort auf gelöschte Ergebnisse und Legacytreffer (technischer Rahmen).**
Nach Löschung bleibt der Tombstone `result_state=deleted` mit Kunde, Formular,
Keydigest, Release/Modus, Zeit, ohne Inhalt. Replay mit gleichem Key und
gleichem verifizierten Digest antwortet ohne Nebenwirkung mit
`409 idempotency-result-deleted` (DTO `{ "code": "idempotency-result-deleted",
"submissionState": "deleted" }`, keine Ids, kein Inhalt, `Cache-Control: no-store`);
abweichender Digest bleibt `409 idempotency-conflict`. Legacytreffer ohne Digest
(`digest_evidence='legacy-missing'`): Replay erzeugt keine zweite Einsendung und
keine Außenwirkung, Antwort `409 idempotency-legacy-unverifiable`. Weder 200-
Nachbildung noch Neuannahme ohne Nutzerentscheidung. **OFFEN (Nutzer):**
öffentliche Antwort (409 versus 200/410), Dauer der Bindungsfrist und Verhalten
nach Tombstone-Ablauf. Bis dahin Tombstones nicht automatisch löschen
(bestehende Implementierungssperre).
