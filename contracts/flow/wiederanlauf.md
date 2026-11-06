# Menschlicher Wiederanlauf und unveränderter Resend

Stand 27.10.2026. SPDX-License-Identifier: AGPL-3.0-only.

**BESCHLOSSEN ADR 0004 H07/H09:** nach Warten oder Crash nur bewusste menschliche
Freigabe; Klartext und Entschlüsselungsschlüssel nie dauerhaft auf dem Server.
Timerablauf, Modulreaktivierung, Leaseablauf oder positiver Freigabestatus allein
starten keinen Worker erneut. `flow.execute` für bewussten Laufstart,
`flow.approve` für fachliche Freigabe, `flow.resume` für Fortsetzung; jeweils
aktuelle Einzel-/Gruppenrechte im Kunden-/Formularscope. Approval ersetzt nicht
Resume; ein Mensch kann beides in derselben ausdrücklich bestätigten Aktion
auslösen, wenn beide Rechte vorliegen. Keine Token-/Dienstfreigabe.

## Übergänge und Freigabeverbrauch (VORGESCHLAGEN)

`waiting` mit timer/approval/module-pause bleibt bis erfülltem Gate UND
menschlichem Resume gesperrt. Verwaistes running nach Crash wird
`waiting-manual` mit `suspension.kind=crash-recovery`; unbekannte externe
Wirkung bleibt `uncertain`, niemals blind noch einmal senden.
`waiting-manual` erlaubt außerdem manual-resend. Bestehende Zustands-/SQL-
Abbildung in `../data/abbildung.md` gilt mit diesen zusätzlichen Gates.

`POST /runs/{runId}/resume` bindet menschliche DB-Sitzung, CSRF, frische
Authentifizierung, erwartete Revision, Checkpointdigest und konkrete Aktion
an eine einmalige Freigabe. Rechte, Release/Modus, Deadline, Budget, Gate und
Effektzustand unter Sperre nochmals prüfen. `workflow_resumptions` speichert
nur diesen Beleg und den Verbrauch, keine Schlüssel/Klartexte. Freigabe wird
atomar mit Lease/Revision verbraucht; Worker läuft unmittelbar mit flüchtigem
Kontext. Stirbt er davor/danach, neue Freigabe nötig; keine persistierte
Queue mit Klartext oder entschlüsselbaren serverseitigen Datenschlüsseln.
Token/Service darf Zustand/Termine beobachten, aber keine Wiederaufnahme auslösen.
Fristen und Bestätigungsdialogdetails **OFFEN/VORGESCHLAGEN** wie Authvertrag.

Benötigte Checkpoint-/Originalobjekte werden vom berechtigten Browser lokal
entsperrt. Vorschlag: objektspezifische CEKs ausschließlich über TLS in
`originalProof` übertragen; Server lädt selbst das autorisierte unveränderliche
:2-Objekt, prüft ID/Revision/Paketdigest und öffnet dessen Nutzchiffrat mit CEK,
IV, AAD und Tag aus dem gespeicherten Paket. Kein Paket/IV/Tag vom Client als
Original verwenden. Kundenschlüssel, Kontoschlüssel und Passphrase bleiben lokal.
Vollständige Objektliste serverseitig aus Checkpoint/Versandmanifest bestimmen;
fehlende, zusätzliche oder fremde Objekte ablehnen. CEKs/Klartext nie in
Idempotenzdigest, Logs, Traces, Crashdumps, Swap oder Antwortcache übernehmen.
Flüchtige Verarbeitung einschließlich Speicherhygiene benötigt Implementierungsabnahme.

## Originalbindung und Bearbeiten (VORGESCHLAGENER Nachweis)

Resend bindet Originaleinsendung, Release, Modus, Versandumfang, ursprüngliche
Empfänger/Vorlagen und stabile Effekt-/Zustellidentitäten. `sourceHash` allein
ist kein Nachweis. `originalProof` benennt exakt gespeicherte Daten-, Anhang-,
Metadaten- und Mailobjekte mit Revision, Digest und CEK. Nach erfolgreicher
AEAD-Öffnung verwendet der Server ausschließlich diese Originalbytes;
zusätzlich mitgelieferte `fields`/`attachment` werden vollständig verglichen
und bei jeder Abweichung abgelehnt. Legacy-Repräsentation (`content_encoding`)
bytegenau beachten; kein Neu-Rendern aus aktuellen Vorlagen oder neuen Empfängern.
Existiert kein unveränderliches vollständiges Versandmanifest, bleibt Resend
für diesen Datensatz **OFFEN/gesperrt**, bis der Originalbezug belegt ist.
Manifestdigest, Quelle, Modus, Effektslot und Zielbindung im Aktionsledger
festhalten; Schlüssel-/Klartextwerte aus dem Requestdigest ausschließen und
stattdessen geprüfte Objektrevisionen und Manifestdigest binden.

Geänderte Felder, Anhänge, Empfänger oder Vorlagen sind **separater Neuversand**:
neue Einsendungs-/Lauf-/Effektidentitäten, neuer Idempotenzbereichseintrag,
Herkunftsverweis auf Original; volle neue Ingestvalidierung/Autorisierung und
menschliche Bestätigung. Kein `edit`-Flag im Resend, keine Änderung des Originals.
Detail-DTO für Bearbeiten bleibt **OFFEN**; kein allgemeiner Resend als Umgehung.

Vor erneutem Effekt `uncertain` manuell anhand sicherem Transportbeleg klären;
bereits bestätigte Effekte nicht zurücksetzen. Mail-Cron bleibt reine Übersicht.
Abnahme: Timer/Crash ohne Mensch blockiert; Widerruf zwischen Freigabe/Commit,
falscher CEK/Tag, vertauschtes Original/Anhang, zusätzliche/geänderte Felder,
fehlendes Versandmanifest, veraltete Revision, doppelter Freigabeverbrauch,
Antwortverlust und unklare SMTP-Annahme. Statische Schemas prüfen diese
Laufzeitgarantien nicht; Implementierungs-/Kryptoreview ist noch erforderlich.

## Vertragsrunde 3 — R02: Abrufpfad Browser → Resume → Worker (VORGESCHLAGEN)

Stand 28.10.2026. Ziel: Der berechtigte Browser kann den Freigabenachweis mit den
spezifizierten DTOs vollständig vorbereiten, ohne breitere Downloadrechte oder
serverseitige Entschlüsselung.

**Ablauf (alle Aufrufe menschliche Sitzung, no-store, jeweils neu autorisiert):**

1. `GET /runs/{runId}/resume-context` (`flow.resume`) → `ResumeContext`: Laufrevision,
   `checkpointHash`, Checkpointobjekt, `manifestObjectId` und die serverseitig
   aus Checkpoint und Manifest bestimmte **vollständige** `requiredObjects`-Menge
   mit aktueller Revision, Paketdigest, Nutzchiffratdigest, Generation und
   `access` (`allowed|denied`). `blocked` nennt Gründe (`manifest-missing`,
   `object-denied`, `object-missing`, `gate-open`); nicht leer = Resume wird
   abgelehnt. Kein Objekt wird verschwiegen.
2. `GET /runs/{runId}/checkpoint/ciphertext` (`flow.resume`): ausschließlich das
   Checkpointobjekt. Daraus folgt kein Inhaltsrecht.
3. `GET …/forms/{formId}/entries/{entryId}/objects` (`content.read`) und
   `GET …/forms/{formId}/objects/{objectId}/ciphertext` (`content.read` UND
   `content.decrypt`) für Daten-, Anhang-, Mail- und Manifestobjekte der
   Originaleinsendung. Rollen- und Besitzkette (Kunde, Formular, Einsendung,
   Lauf) werden serverseitig geprüft; URL-IDs sind keine Berechtigung.
4. Browser entsperrt lokal (Passphrase/Kontoschlüssel verlassen ihn nie), öffnet
   die Objekte, bildet `originalProof.objects[]` (objectId, expectedRevision,
   expectedSha256 = Paketdigest aus Schritt 1/3, cek) und sendet
   `POST /runs/{runId}/resume` (`expectedRevision`, `checkpointHash`, Nachweis).
5. Server: Rechte/Scope/Revision unter Sperre; Menge der Nachweisobjekte muss
   exakt `requiredObjects` entsprechen (fehlend/zusätzlich/fremd = 409); je Objekt
   aktuelle Revision und Paketdigest gleich; AEAD-Öffnung mit CEK; `payloadSha256`
   gegen die Zeile und das Manifest (`../data/objektinventar.md`, R07); Gate und
   Effektzustand prüfen; Freigabe verbrauchen; Worker läuft mit flüchtigem Kontext.
   Hat der Aufrufer `content.decrypt` für ein benötigtes Inhaltsobjekt nicht,
   steht es als `denied` im Kontext und der Lauf bleibt `waiting-manual` (klar
   definierter blockierter Schritt, keine Teilfortsetzung).

**Rechte-Unterscheidung.** Checkpoint = `flow.resume`; Inhalt (Daten/Anhänge/Mail/
Manifest) = zusätzlich `content.read` + `content.decrypt` + K; Genehmigung
= `flow.approve`. Keine Rolle ersetzt ein Einzelrecht.

**Neuer Lauf aus gespeicherter Einsendung (`POST /runs`).** `FlowExecuteInput`
kennt optional `originalProof`. Braucht das Release Klartext der gespeicherten
Einsendung (aus dem Releasemanifest abgeleitet), muss der Nachweis mitkommen;
sonst 409 `plaintext-proof-required` ohne Lauf und ohne Idempotenzverbrauch,
der Mensch wiederholt mit Nachweis (gleiche Objektprüfung wie oben, Menge aus dem
Manifest der Einsendung). Braucht das Release keinen Klartext, entfällt der
Nachweis. Der Nachweis ist wie bei Resume nicht Teil des Idempotenzdigests.

**Speicherhygiene (Implementierungsauflage, unverändert):** Bodylogs, Traces,
Crashdumps, Swap und Antwortcaches dürfen CEKs nicht enthalten; `writeOnly` allein
ist kein Beweis. Abnahme: synthetischer Gesamtpfad Browser → Resume → Worker mit
Prüfung auf Logs/Cache, ungültiger/abweichender Menge, veralteter Revision,
`denied`-Objekt, Widerruf zwischen Kontext und Resume, Rotation vor Resume.
Nicht ausgeführt.
