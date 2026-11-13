# Agent-Einstieg

## Auftrag und maßgebliche Quellen

Claude Code koordiniert die Entwicklung. Agents mit Sonnet und Haiku werden entsprechend Schwierigkeit und Risiko eingesetzt. Codex wird für geeignete Implementierungs-, Analyse- und Reviewaufgaben eingebunden. Keine feste Quote und keine Pflicht, triviale Aufgaben zu parallelisieren.

Vor der Arbeit `docs/STATUS.md`, `docs/ARBEITSPLAN.md` und `docs/ENTWICKLUNG.md` lesen; anschließend nur aufgabenrelevante Anforderungen, Verträge und Entscheidungen. Das Repository ist das Projektgedächtnis; frühere Chats und persönliche Agent-Memory sind keine Voraussetzung.

Bestätigte Nutzeranforderungen haben Vorrang vor Entwurfsvorschlägen. Neue Architekturentscheidungen mit Begründung unter `docs/decisions/` dokumentieren. Offene Fragen nicht als Beschlüsse implementieren.

## Arbeitsweise

- Arbeit nur innerhalb eines klar abgegrenzten Pakets mit Ziel, Dateibesitz, Vertrag, Abnahme und Testumfang.
- Pro Datei ein schreibender Agent. Gemeinsame Verträge und Migrationen zuerst koordinieren.
- Kleine Aufgaben lokal erledigen; parallele Agents nur für unabhängig bearbeitbare Aufgaben.
- Sonnet: komplexe Fachlogik, Architektur, Integration und anspruchsvolle Reviews.
- Haiku: klar begrenzte Routinearbeit mit festem Vertrag und unmittelbar prüfbarem Ergebnis.
- Codex: abgeschlossene Implementierungspakete, Fehlersuche, Migration und unabhängige technische Reviews, sofern verfügbar.
- Keine rekursive Delegation ohne Koordinationsauftrag. Keine vollständigen Chatverläufe an jeden Agent verteilen.
- Kontext, Ergebnisse und Logs knapp und gezielt weitergeben; Fakten mit Dateipfaden belegen.
- Autorisierung und Fachlogik für REST, MCP und UI gemeinsam halten.
- Keine echten Kundendaten, Secrets, Schlüssel oder Klartext-Debugmitschnitte ins Repository.
- Keine Änderungen im alten Backend oder in Referenzprojekten ohne ausdrücklichen Auftrag.
- Tests passend zum Risiko; bei Verschlüsselung, Rechten, Migration und Wiederholungen echte Verhaltens-/Integrationsprüfungen.
- Fertigmeldungen enthalten Ergebnis, Dateien, ausgeführte Prüfungen, offene Grenzen und nächsten Schritt.

Dokumentation und Nutzerkommunikation deutsch. Vorschlag für Codekonventionen: technische Bezeichner und Codekommentare englisch, Nutzertexte deutsch und lokalisierbar; vor Implementierung als Projektentscheidung bestätigen.

## Image-Nachweis

Änderungen, die ins Image eingehen, gelten erst nach `scripts/docker-build.sh` (Build plus Smoke-Test gegen echte MariaDB) als fertig; `IMAGE_TAG=form-backend:<hash>` und das Ergebnis gehören in `post_progress`. Kein Push, kein Deploy. Details: `docs/ENTWICKLUNG.md`, Abschnitt „Lokales Image“.

## Grenzen des jetzigen Gerüsts

Es existiert noch kein Build oder Testbefehl. Keine erfolgreiche Prüfung oder Produktionsreife behaupten. Nicht eigenständig veröffentlichen, deployen oder produktive Migrationen ausführen.

## Wegwerfbare Sessions — verbindlich

Das Repository ist die alleinige Source of Truth. Sessions müssen wegwerfbar sein. Alles zur Fortsetzung nötige Wissen wird im selben Arbeitsschritt im Repository festgehalten: Anforderungen/Entscheidungen, Verträge, Arbeitsstand, Prüfungen, offene Fehler und nächste Schritte. Vor Übergabe, Unterbrechung, Sessionende oder Kontextwechsel STATUS/ARBEITSPLAN und bei Bedarf ADRs/handoffs aktualisieren; auch Dateibesitz, Branch/Worktree und laufende Jobs dokumentieren. Eine neue Session muss ohne alte Chats oder persönliches Agent-Memory fortsetzen können. Keine Secrets oder Kundendaten dokumentieren. Verbindliche vollständige Anforderung: docs/ANFORDERUNGEN.md, Abschnitt „Wegwerfbare Sessions“.

## Lizenz

GNU AGPLv3, SPDX: AGPL-3.0-only. LICENSE ist maßgeblich. Lizenzhinweise übernommener Komponenten erhalten.
