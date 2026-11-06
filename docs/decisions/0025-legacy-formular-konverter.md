# ADR 0025: Legacy-Formulare als prüfbare Entwurfsvorschläge

Stand: 03.11.2026. P11-F Teil 1, Nutzerauftrag; keine Umstiegs-/Produktionsfreigabe.
SPDX-License-Identifier: AGPL-3.0-only.

## Vertrag und Begründung

Quelle ist ausschließlich `form_versions` Version 1 mit `contract_version=migration-review`
und `legacy_adapter_ref=inactive:migration-review` aus P9/ADR 0014. Keine Verbindung zur
Alt-DB, kein echter Dump, keine privaten Schlüssel. Die URL-ID ist die erhaltene
Formular-UUID; Kunde und Formular werden aus der Ziel-DB abgeleitet.

Die reine Abbildung in `FormMigration/LegacyFormConverter.swift` erhält die P9-Projektion
und das Standarddokument aus `FormAdmin/DraftStore.swift`. Dadurch bleiben Standardablauf,
Versionen und Dokumentvertrag gemeinsam mit der bestehenden Entwurfsverwaltung.
`FormAdmin` verwendet `FormMigration`, nicht umgekehrt. Quellen für das Zielformat:
`FieldsTab.svelte`, `lib/draft/doc.ts`, `DraftRoutes`, `DocumentValidator`, `MailPlan`,
`MailTemplate` und der Bausteinkatalog `FlowDefinition.builtinBlocks`.

- Feldtypen text/email/datum/zahl/bool/auswahl werden in die sechs Editorarten übersetzt.
  Auswahl benötigt Textoptionen (`regel.optionen`). Pflicht-/Leerwert-/Datums-/Zahlsemantik
  weicht ab und wird ausdrücklich als angepasst gemeldet. Sonstige PHP-Regeln werden
  nicht ausgeführt oder als gleichwertig behauptet. Dateifelder benötigen Anhangprüfung
  und sind im aktuellen Editor nicht abbildbar. Reihenfolge bleibt erhalten, IDs sind
  wertfreie Ordinale; Namen müssen zum aktuellen Editor passen, keine stillen Umbenennungen.
- Ohne Altschema dient die JSON-Pflichtliste als Vorschlag sensibler Textfelder. Ohne
  abbildbare Felder bleibt das optionale Standardfeld als gemeldeter Platzhalter.
- `besondereKategorien` wird übernommen; fehlend/ungültig konservativ true mit Prüfhinweis.
- Ein neuer Entwurf wird mit `base_release_id=NULL`, Revision 1 und kanonischem Dokumenthash
  angelegt und durch denselben `DocumentValidator` wie normale Entwürfe geprüft.
- Das Dokument erlaubt **keine Domains**. Deshalb liegen normalisierte Hostvorschläge
  separat in `migration_form_drafts.proposals_json`; keine Domainbindung, DNS-Prüfung
  oder Freigabe. Wildcards/URLs/Ports werden als nicht abbildbar gemeldet.
- Das gültige `form.mail` benötigt eine Absenderadresse, die P9s Formularprojektion nicht
  enthält. Daher enthält der ausführbare Entwurf kein `form.mail`. Separate unvollständige
  Vorschläge verwenden die neuen Schlüssel from/organisation/confirmation und enthalten
  Absendername, Produktions-/Testempfänger getrennt sowie Mailvorlagen (HTML als zu prüfender
  Vorschlag). `#=[Name]=#` bleibt erhalten wie in `MailTemplate`; geändertes Escaping und
  abgeleitete Handlerwerte erfordern Prüfung. Das Bestätigungsempfängerfeld wird nicht
  geraten. Kein Ersatzabsender, keine Probeversendung. `connectionCustomers` bleibt im Plan.
- `modes` und `active` werden nie aktiviert. Spezialhandler können aus dieser Projektion
  nicht sicher rekonstruiert werden; Bericht verlangt Prüfung statt fingierter core.mail-
  oder anderer Knoten. Der Standardablauf bleibt erhalten.

## API, Wiederholung und Datenschutz

`POST /admin/api/v1/migration/legacy-forms/:legacyFormId/draft` ohne Requestbody erzeugt
den Vorschlag; `GET` auf demselben Pfad liefert ausschließlich Bericht und technische IDs.
Beide verlangen eine Cookie-Sitzung, frische Anmeldung und **system.manage auf Systemscope**.
POST verlangt zusätzlich CSRF/Origin. Keine Bearer-/MCP-Freigabe. Fehlende Rechte/Ressourcen
folgen dem vorhandenen 404/403-Vertrag; aktive/freigegebene Formulare ergeben bei POST 409.
Erfolg 200, `Cache-Control: no-store`; POST liefert zusätzlich `document` und `proposals`.

Der Formularlock serialisiert parallele Aufrufe. Einziges Artefakt je Formular:
`migration_form_drafts` mit Entwurfsreferenz, Bericht, Vorschlägen und Zeit. Wiederholung
liefert denselben Entwurf samt aktuellen menschlichen Änderungen; kein Überschreiben.
Bericht und Zusatzvorschläge bleiben der ursprüngliche Konvertierungsstand. GET vor
Konvertierung ist 404. Keine erneute Konvertierung derselben ID in diesem Paket.
Entwurf, Bericht und Erfolgs-Audit werden gemeinsam committet oder zurückgerollt. GET
schreibt ebenfalls ein Audit. Auditcodes `migration.draft.create` / `migration.draft.report`,
Details `{}`; Bericht nur feste Gründe, bekannte Spaltennamen und Feldpositionen, keine
Namen/Empfänger/Regel-/Vorlagen-/Personenwerte und keine untrusted Schlüssel. Inhaltsvorschläge
liegen ausschließlich im berechtigten POST-Ergebnis und der DB, niemals im Bericht/Audit.

## Schema und Abnahme

DDL in beiden Schemaabbildern identisch ergänzt. Bestandsupgrade als **ungeprüfter Kandidat**
`backend/db/upgrades/0025-legacy-form-drafts.sql`; keine produktive Ausführung, keine
Änderung aufgezeichneter Baseline-Prüfsummen. DB-Tests geschrieben und kompiliert, auf
Nutzeranweisung nicht ausgeführt. Unit-Tests der reinen Abbildung ausführen; tatsächlichen
Prüfstand und nächste Befehle im [Handoff](../handoffs/P11-F-Konverter.md) fortschreiben.
