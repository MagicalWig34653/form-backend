# Gesamtinventar verschlüsselter Gegenstände und Hold

Stand 27.10.2026. SPDX-License-Identifier: AGPL-3.0-only.
**VORGESCHLAGEN**, technische Ergänzung H08/H10; keine Krypto-/DB-Laufzeitabnahme.

## Inventar und Lebenszyklus

Alle kundenbezogenen :2-Nutzpakete liegen im gemeinsamen `stored_objects`-
Inventar: Objekt-UUID, Kunde, Formular, optionale Einsendung, Rolle, Revision,
Paketdigest, `kid` (FK zur Kundengeneration), Wrap, DB-/S3-/SFTP-Referenz,
Zustand und ggf. Ablauf. Freie Chiffratspalten außerhalb dieses Inventars sind
für diese Rollen unzulässig. Selbst vorbereitete, fehlgeschlagene und extern
noch nicht gelöschte Pakete zählen als Generationsreferenz.

| Rolle / Referenz | Zugriff | Rotation und Löschung |
| --- | --- | --- |
| data, attachment, mail-organisation, mail-filler, mail-manifest, legacy-errors / submission_id | aktueller Formular-/Inhaltsbereich, für Klartext zusätzlich Schlüsselzugang | CEK umhängen, Anfragefristen/Hold; genaue Anfragefrist OFFEN |
| checkpoint / workflow_runs.checkpoint_object_id | gleicher Kunde/Formular/Lauf, aktuelles Fortsetzungsrecht; kein automatischer Klartextzugang | CEK umhängen; mindestens bis Abschluss/zulässiger Laufbereinigung; Frist OFFEN |
| debug / debug_objects | aktueller Debugbereich, Klartext nur mit Berechtigung und lokalem Schlüssel | CEK umhängen oder löschen; exakt Grenze recording_started_at+900s, auch Metadaten/Kopien |
| object-metadata / stored_objects.metadata_object_id | höchstens Zugriff auf das Elternobjekt | eigene Generation und Hülle, gemeinsam mit Elternobjekt löschen bzw. frühere TTL; keine offenen Dateinamen |
| statistics-metadata / legacy_statistics.metadata_object_id | aktueller Statistikbereich, Schlüsselzugang für Klartext | eigene Generation/Hülle, Herkunft legacy: vollständiger Erhalt ohne 13-Monatsfrist; IP-Bezug vor Import ausschließen, unklarer IP-Bezug OFFEN M04 |

Für mehrere Objekte derselben Rolle wird ordinal_no je Einsendung/Rolle
unter derselben Sperre eindeutig vergeben; insbesondere Checkpoints mehrerer
Läufe und Metadaten verwenden nicht alle den Default 0. Die Objekt-UUID
bleibt bei Revisionen stabil.

Dienste prüfen Rollen, Kunde/Formular, Elternreferenz, Zyklenfreiheit der
Metadaten und Fristen atomar. Ein Metadatenobjekt wird nicht zwischen Eltern
mit unterschiedlichen Fristen geteilt. `submission_id` muss für alle
anfragebezogenen Rollen einschließlich Checkpoint gesetzt sein. Debug ohne
Einsendung und geschützte Altstatistik bleiben trotzdem im selben Inventar.
Debugobjekte und rekursive Metadaten müssen spätestens bei der gemeinsamen
900-s-Grenze unzugänglich sein; Löschjobs entfernen auch externe Kopien und
Referenzen. TTL-Durchsetzung und externe Löschbestätigung sind P3-Abnahme,
keine hier nachgewiesene Garantie. Ein Hold verlängert keine Debug-/Neustatistik-TTL. Legacybestand und zugehörige
Metadaten unterliegen gemäß ADR 0004 keiner neuen 13-Monatsfrist.

Andere kryptografische Gegenstände sind getrennt inventarisiert:
`data_key_access` und `data_key_recovery` referenzieren direkt Kunde+kid und
werden erst nach null Nutzpaketreferenzen entfernt. `account_keys`,
Passkey-/Passphrase-Kontowraps gehören zum Kontoschlüssel, nicht zur
Kundengeneration. Protokollschlüssel, Sitzungs-CSRF-Verschlüsselung,
Enrollment-/MFA-/Integrationssecrets gehören zu separaten Schutzschlüsseln;
Provider, Zielformat und deren Rotation bleiben OFFEN M05/K11. Maskierte
Debug-/Audit-/Statistikprojektionen sind keine zusätzliche Schlüsselhülle.

Rotationsabschluss sperrt Kunde/Generation sowie konkurrierende Writer,
Holds, Objektlöschungen und Umhängevorgänge. Er prüft null alte `kid` in
**allen** stored_objects-Rollen/Backendzuständen einschließlich geschützter
Metadaten und externer Orphans. Erst bestätigte Löschung entfernt eine
Inventarzeile. Danach Zugänge/Recovery/Generation atomar entfernen. Unbekannte
Rolle, unaufgelöste Altchiffrate, fehlende Inventarreferenz oder unbestätigte
externe Löschung sperren Abschluss. Kunden-/Altschlüsselschnitt bleibt OFFEN.

## Hold-Objektliste

Auth `HoldInput.objects` enthält die vollständige aktuelle Menge aller
verbleibenden anfragebezogenen Pakete einschließlich Anhänge, Mailrollen,
Checkpoints und rekursiver Metadaten. Debug/Statistik folgen ihren eigenen
TTL-Regeln. Jede Objekt-ID genau einmal; keine fremden Kunden/Formulare oder
Einsendungen. Liste mit `expectedRevision`, `expectedSha256` und
`sourceGenerationId` vollständig unter Sperre mit Inventar vergleichen.
Fehlende, zusätzliche, doppelte oder inzwischen geänderte Objekte ergeben 409.
Gleichzeitige Objekterzeugung muss dieselbe Einsendungssperre verwenden.

Bei `held=true`: jedes HPKE-Paket benötigt ein sym-Ersatzpaket mit demselben
kid; vorhandenes sym bleibt ohne Ersatz unverändert oder darf sym→sym gewickelt
werden. Bei `held=false`: keine Ersatzpakete zulassen, nur Flag ändern; sym→hpke
bleibt verboten. Fälle ohne HPKE-Nachschutz benötigen trotzdem die vollständige
Prüfliste. Jedes Ersatzpaket strikt gemäß `../crypto/paket-v2.md` parsen;
Kunde/Generation, bytegleiche Nutzdaten-IV/ct/tag und erlaubten Wrap prüfen.
Vergleich betrifft Nutzbytes, der Paketdigest ändert sich beim Umhängen.
Alle Pakete, Revisionen/Digests und `removable` gemeinsam committen. Externe
Pakete zunächst revisionsgetrennt vorbereiten, dann Referenzen atomar schalten;
fehlgeschlagener Nachschutz ändert weder Flag noch sichtbare Referenzen.

Erzeugung eines sym-Ersatzes braucht lokal entsperrten Datenschlüssel; ein
Serverzugangseintrag beweist dies nicht. Aktuelle Inhalts-/Holdrechte immer
prüfen. Die Zuordnung zusätzlicher Aktionsrechte für diesen Fall bleibt
nach ADR 0004 individuell konfigurierbar, siehe ../auth/rechte.md. Die bereits dokumentierte
Grenze bleibt: Ohne Schlüssel kann der Server gleichen CEK im Ersatzwrap nicht
beweisen. Kein Hash wird als Ersatz für diesen Beweis ausgegeben.


ADR 0004 H09: `submissions.mail_manifest_object_id` referenziert ein unveränderliches
`stored_objects`-Objekt Rolle mail-manifest mit Original-Release/Modus,
Effektslot/Versandumfang, Empfängern/Vorlagen und vollständigen Objektbezügen.
Der Inhalt bleibt verschlüsselt; Originalbezug/AEAD-Prüfung gemäß
../flow/wiederanlauf.md. Manifest und referenzierte Objekte müssen gemeinsam
verfügbar sein; Rewrap ändert nur Hülle/Revision, niemals Nutzbytes. Fehlt das
historische Manifest, keine aktuelle Konfiguration als Original ausgeben.

## Vertragsrunde 3 — R07: Manifest, Objektidentität und Referenzpflege (VORGESCHLAGEN)

Stand 28.10.2026. Technische Festlegung ohne neue Produktentscheidung;
Schema: [resend-manifest.schema.json](resend-manifest.schema.json), synthetisches
Beispiel [resend-manifest.example.json](resend-manifest.example.json) (gegen das
Schema geprüft, siehe VALIDIERUNG.md). Kryptoreview der Digestdefinition fehlt.

**Drei getrennte Werte pro Objekt:**

| Wert | Bedeutung | Ändert sich bei Rewrap/Hold/Rotation? |
| --- | --- | --- |
| `objectId` | stabile Objektidentität | nein |
| `payloadSha256` = SHA-256(iv‖ct‖tag), rohe Nutzchiffratbytes aus `paket-v2.md` | unveränderliche Nutzdatenidentität; Spalte `stored_objects.payload_sha256` | nein (Nutzbytes bleiben nach Vertrag gleich) |
| `ciphertext_sha256` / `revision` / `kid` / Wrap-Segmente | aktuelle Hülle | ja |

`payloadSha256` ist ein Digest über Chiffrat, nicht über Klartext; er verrät dem
Server nichts Neues und beweist keinen CEK (siehe Sicherheitsgrenze Ersatzwrap).
Der Server prüft ihn beim Rewrap: Ersatzpaket muss dieselben iv/ct/tag tragen
(bereits Regel oben) und bekommt dieselbe `payload_sha256`.

**Regel für eingebettete Referenzen** (Manifest, Checkpoint, `protectedRef` in
`../flow/common.schema.json`): Eine eingebettete Referenz identifiziert ein Objekt
ausschließlich durch `objectId` und ggf. `payloadSha256`. Die in `protectedRef`
vorhandenen Felder `keyGeneration` und `sha256` sind **Schnappschusswerte zum
Erzeugungszeitpunkt** und dürfen nach Rewrap/Rotation nicht als Gleichheitsbedingung
gegen die aktuelle Hülle geprüft werden. Aktuelle Revision, Paketdigest, `kid`
und Generation werden zur Prüfzeit ausschließlich aus `stored_objects` gelesen
und im `originalProof` (`expectedRevision`, `expectedSha256`) vom Aufrufer
bestätigt. Es gibt keinen Pfad, der eingebettete Referenzen automatisch
nachschreibt; Rewrap ändert nur Zeilen in `stored_objects` (Hülle, Revision,
Digest, kid) atomar mit den übrigen Objekten der Hold-/Rotationsliste.
Checkpoints und Manifeste sind unveränderlich; ein Fortschritt erzeugt einen
neuen Checkpoint (neue Objekt-ID, neuer Lauf-Revisionsstand).

**Manifestinhalt:** Original-Release, Modus, Effektslot, je Zustellung die stabile
`deliveryId`, Kanal, Verbindungsalias, Vorlagenverweis (Id+Version, nur
Nachweis), gerenderter Betreff, Empfänger, `bodyObjectId` (bereits gerendertes
Original `mail-organisation`/`mail-filler`), `attachmentObjectIds`, sowie für jedes
Objekt `payloadSha256`, Rolle, Ordinal, Länge und `contentEncoding`. Die
**Originalversandbytes sind die referenzierten Mailobjekte**, nicht eine spätere
Neurenderung. Vorlagenverweise werden nie zum Neurendern benutzt. Das Manifest
wird bei Annahme einmal im selben Commit wie die Zustellidentitäten erzeugt und
als `mail-manifest`-Objekt (:2) gespeichert; `submissions.mail_manifest_object_id`
zeigt darauf. Kein Manifest-Update: Neuversand mit Änderung = neue Einsendung.

**Prüfung bei Resend/Resume (Reihenfolge):** (1) Rechte/Scope/H/K; (2) Manifest-
und Referenzobjekte aus `stored_objects` laden (Manifestobjekt nur über den Pin
`submissions.mail_manifest_object_id` + `mail_manifest_payload_sha256`, Runde 4 M1); Besitzkette und Vollständigkeit
gegen Manifest (`objects` = Menge der gelieferten `originalProof.objects`);
(2a, Runde 4 M1) Manifest an die Einsendung binden: `manifest.submissionId` ==
Einsendungs-ID, `sourceReleaseId`, `sourceMode`, `effectSlot` gleich den Werten der
Einsendung bzw. des Effektledgers, `stored_objects.submission_id` == Einsendungs-ID,
Rolle `mail-manifest`, `payload_sha256` der Zeile == `submissions.mail_manifest_payload_sha256`
(sonst Ablehnung ohne Versand); (3) je Objekt `expectedRevision`/`expectedSha256` gegen aktuelle Zeile; (4) AEAD-
Öffnung mit CEK; (5) Vergleich `payloadSha256` aus Zeile gegen Manifest;
(6) Manifest-Deliveries gegen Effektledger. Erster Positivfall der Abnahme:
unveränderter Resend und Resume vor und nach vollständiger Rotation und nach Hold,
ohne neue Empfänger und ohne Neurendern. Negativfälle: vertauschtes Objekt mit
anderer `payloadSha256`, fehlendes oder zusätzliches Objekt, veraltete Revision,
Manifestobjekt gelöscht. Historische Einsendungen ohne Manifest (Altbestand,
`release_evidence='legacy-unknown'`) bleiben für Resend **sichtbar gesperrt**;
kein Rekonstruieren aus aktueller Konfiguration.
Migration: `payload_sha256` wird aus den importierten Chiffratbytes berechnet;
nichtparsbare Altpakete sind Importblocker, kein Auffüllen mit Nullwerten.


## Vertragsrunde 4 — Befunde M1–M4 (VORGESCHLAGEN)

Stand 30.10.2026, Bezug `docs/paritaet/review-krypto-adapter.md`. Nichts ausgeführt.

**M1 Manifest an Einsendung pinnen.** `submissions.mail_manifest_payload_sha256` (im
selben Commit wie `mail_manifest_object_id`, CHECK: beide NULL oder beide gesetzt) plus
zusammengesetzter FK auf `stored_objects(customer_id,form_id,id,payload_sha256)`
(`schema-entwurf.sql`). Prüfschritt (2a) siehe Reihenfolge oben. Prüffall:
Manifest einer anderen Einsendung eingehängt → Ablehnung ohne Versand; ebenso
Manifest mit richtigem Objekt, aber `submissionId`/Slot/Modus abweichend.

**M2 Grenze von `payloadSha256` (ausdrücklich).** `payloadSha256` ist ein
ungeschlüsselter SHA-256 über iv‖ct‖tag und **kein Authentizitätsanker**. Er erkennt
Beschädigung, Vertauschung und Rewrap-/Rotationsfehler gegenüber einem intakten Manifest.
Er schützt **nicht** gegen jemanden mit Datenbank-Schreibrecht: Wer `stored_objects`,
`submissions` und das Manifest schreiben kann, kann mit dem öffentlichen
Empfängerschlüssel neue Objekte samt passendem Manifest, Pin und Digest erzeugen. Auch
der Pin aus M1 und der FK ändern das nicht (beide Seiten liegen in derselben DB). Resend
darf deshalb nicht als Echtheitsnachweis gegenüber einem DB-Schreiber bezeichnet oder
beworben werden. Schutz dagegen ist Zugriffsbeschränkung auf die Datenbank (Mehrfach-
rollen, Audit) und, falls gewünscht, eine Änderung am Paketformat (Objekt-ID, Rolle,
Einsendungs-ID in der Nutz-AAD neuer `:2`-Pakete; `paket-v2.md` hat konstante AAD
`KUBUS-AEAD:2`). Das ist eine eigene Entscheidung und hier nicht getroffen.

**M3 Validierungsregeln (nicht per JSON-Schema erzwingbar, Pflichtprüfung vor
Annahme und Resend):** `objects[].objectId` eindeutig; `(role, ordinal)` eindeutig;
`deliveries[].deliveryId` eindeutig; jede `bodyObjectId` und jede
`attachmentObjectIds[]` kommt in `objects` vor (sonst entfällt für sie der
`payloadSha256`-Vergleich), `bodyObjectId` hat Rolle `mail-organisation`/`mail-filler`,
Anhänge Rolle `attachment`. Steuerzeichenverbot (Mail-Header-Injektion): `subject`,
`displayName` und `address` enthalten keine Zeichen U+0000–U+001F, U+007F, U+2028,
U+2029; `address` zusätzlich kein Leerzeichen; per Schema-Pattern und zusätzlich
beim Annehmen und beim Resend geprüft; bei Verstoß keine Versandvorbereitung.

**M4 Altimport: Hash über Chiffratbytes.** `payload_sha256` wird aus den **dekodierten
Bytes** iv‖ct‖tag berechnet, nicht aus dem Base64-String. Nicht streng
kanonisches Base64 in Altpaketen (`base64_decode(s,true)`-Semantik ohne
Rückkodierungsvergleich, `../crypto/migration.md`) darf deshalb nicht zu zwei Digests
für dasselbe Chiffrat führen; nach dem Import steht der Digest der Bytes fest und wird
beim Rewrap verglichen. Nichtparsbare Altpakete bleiben Importblocker.

## Implementierung externer Speicher (03.11.2026)

Betriebsrichtlinie, API, Chiffrat-Spool, Zustands-/Retryvertrag und verpflichtende zweiphasige Löschabsicht: [externe-speicher.md](externe-speicher.md), ADR 0019. Kein Wechsel des Speicherorts bestehender Objekte durch neue Richtlinien. Neue Tabelle `storage_uploads` enthält ausschließlich temporär dauerhaftes Chiffrat; Inventar bleibt autoritativ. Laufzeitabnahme der DB-/Transportfälle ist noch offen (siehe STATUS).
