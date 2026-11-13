# ADR 0043: Einmal-Snapshot mit Schreibpause-Prüfung im Code, kein Delta

13.11.2026. Status: umgesetzt (Agent), Nutzerentscheidung „B: Einmal-Snapshot, Quiesce-Prüfung im Code, kein Delta“.
Todolino 48E3D133-1121-4076-9002-587DEAC15B58. SPDX-License-Identifier: AGPL-3.0-only.
Ersetzt den Abschnitt „Delta und Idempotenz“ von ADR 0033 (Delta-Aktion) und den Abschnitt „Additive Snapshot-Deltas“ von ADR 0014.

## Kontext

Das Delta (ADR 0033) legte nur neue Quell-IDs an. Im Altsystem gelöschte oder geänderte Datensätze erschienen
danach als veralteter Stand im Ziel (Änderungen waren Konflikte, Löschungen nur eine mengenbasierte Warnung). Eine
Umschaltung mit „finalem Delta“ konnte so ein Ziel mit Daten hinterlassen, die im Altsystem nicht mehr existieren.

## Entscheidung

1. **Ein Snapshot je Quelle.** Die Aktion `delta` entfällt (404 wie jede unbekannte Aktion). Ein echter Lauf,
   dessen Namespace schon einen `migration_runs`-Eintrag mit **anderem** `dump_sha256` hat, bricht vor dem
   Schreiben mit `snapshot_changed` ab. Wiederholung und Wiederaufnahme mit gleichem Snapshot-Hash bleiben möglich
   (Ledger-Prüfung unverändert). Ein späterer Nachimport geht nur über die Wiederherstellung des Ziels aus der
   Sicherung und einen einmaligen neuen Import.
2. **Quellen-Fingerabdruck.** `LegacyImporter.sourceFingerprint()`: SHA-256 über `Tabelle:CHECKSUM TABLE:COUNT(*)`
   aller Basistabellen der Quell-DB (`information_schema.tables`, sortiert), gelesen außerhalb des
   Konsistenz-Snapshots in einer frischen Lesung. Es genügt `SELECT` (Lese-Konto der Quelle, E2E belegt). Ausgabe nur
   als Hash, nie mit Werten.
   - Der Prüflauf speichert ihn im Bericht (`sourceFingerprint`, Job: `report_json`).
   - Der echte Lauf bekommt den erwarteten Wert (`expectedSourceFingerprint`) und rechnet vor dem ersten
     Schreiben neu. Abweichung: Abbruch ohne Schreiben mit `source_changed`.
   - Nach dem letzten Objekt (vor Abschluss des Laufs) rechnet er erneut, nach dem Ende der Snapshot-Transaktion.
     Weicht der Wert vom Startwert ab: `source_not_quiesced`, Lauf und Job `failed`.
   - Job-Weg: Der Fortschrittsstand (`report_json`) behält den Fingerabdruck des Prüflaufs, damit auch eine
     Wiederaufnahme nach Pause oder Neustart gegen den Prüflauf prüft.
3. **Job-Aktion `rehearse`** („Prüflauf wiederholen“): erlaubt bei `state='review' AND dry_run=1` oder bei `state='failed'` mit
   `error_code='source_changed'`. Gleicher Plan und Snapshot-Hash, wieder als Prüflauf in der Warteschlange;
   Probe/Test werden zurückgesetzt. `import` verlangt den gespeicherten `sourceFingerprint` des Prüflaufs; fehlt er
   (Job vor dieser Änderung): 409 `source_fingerprint_missing`, Prüflauf wiederholen. Die 409-Antworten der Jobaktionen tragen
   einen stabilen Code und einen deutschen Text (`MigrationActionRefused`).
   `resume` ist bei `failed` mit `source_changed`, `source_not_quiesced` oder `snapshot_changed` gesperrt
   (409 `resume_not_possible`); die Oberfläche zeigt dort kein „Fortsetzen“ (Review-Fund, 13.11.2026).
4. **CLI** (`migrate-legacy`): Der Prüflauf gibt `source-fingerprint: <hex>` aus. Der echte Lauf akzeptiert
   `--expect-source-fingerprint <hex>` (dann gilt 2b) und prüft ohne die Option immer Start gegen Ende (2c).

## Fehlercodes

| Code | Bedeutung | Maßnahme |
|---|---|---|
| `snapshot_changed` | Namespace hat schon einen Import mit anderem Snapshot | Ziel aus der Sicherung wiederherstellen, einmalig neu importieren |
| `source_changed` | Altdaten seit dem Prüflauf verändert; nichts geschrieben | Altsystem in Schreibpause, „Prüflauf wiederholen“ |
| `source_not_quiesced` | Altsystem während des Imports beschrieben; Lauf `failed` | Ziel aus der Sicherung wiederherstellen, Schreibpause, neu importieren |

## Grenzen

- Der Fingerabdruck erkennt Änderungen nur zwischen den Messpunkten (Prüflauf, Start, Ende). Ein Schreibvorgang,
  der nach dem Ende der Messung und vor der Umschaltung erfolgt, wird nicht erkannt: Die Schreibpause gilt bis zur
  Umschaltung, die Umschaltung selbst bleibt außerhalb der Oberfläche.
- `CHECKSUM TABLE` liest jede Tabelle vollständig (Dauer ähnlich einem Prüflauf-Zählen, ein Lauf mehr beim Start, einer beim Ende).
- Nach `source_not_quiesced` bleiben die bis dahin je Objekt committeten Zielobjekte bestehen; der Weg zurück ist die Sicherung des Ziels.
- Alte Jobs im Zustand `review` ohne Fingerabdruck können nicht importieren, bis der Prüflauf wiederholt wurde.
