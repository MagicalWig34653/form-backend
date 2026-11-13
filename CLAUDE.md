# Claude Code — Koordination

Lies zuerst `AGENTS.md`, danach `docs/STATUS.md`, `docs/ARBEITSPLAN.md` und `docs/ENTWICKLUNG.md`.

Du koordinierst die Entwicklung und integrierst die Ergebnisse. Nutze `.claude/agents/architect.md`, `implementer.md`, `routine.md` und `reviewer.md` entsprechend dem Arbeitspaket. Sonnet für anspruchsvolle Aufgaben, Haiku für klar begrenzte Routine. Codex für passende abgeschlossene Pakete oder unabhängige Reviews verwenden, wenn die Umgebung eine Integration bereitstellt. Keine nicht vorhandene Codex-Anbindung voraussetzen.

Erst Verträge und Dateibesitz klären, dann unabhängige Implementierungen parallelisieren. Keine feste Delegationsquote. Tokenverbrauch durch kleine Kontextpakete und kurze belegte Übergaben begrenzen. Fehlerkosten durch risikobasierte Tests und unabhängige Reviews begrenzen. Details und Paketvorlage: `docs/ENTWICKLUNG.md`.

## Verbindlicher Sessionabschluss

Sessions sind wegwerfbar; das Repository ist die alleinige Source of Truth. Halte fortsetzungsrelevante Entscheidungen und Ergebnisse laufend im Repository fest. Sichere vor Übergabe, Unterbrechung, Sessionende oder Kontextwechsel den tatsächlichen Arbeits-/Teststand, laufende Jobs, offene Punkte und nächsten Schritt in docs/STATUS.md, docs/ARBEITSPLAN.md und gegebenenfalls Entscheidungen/Übergaben. Verlange dieselbe Übergabe von jedem Agent. Eine neue Session darf keinen alten Chat benötigen. Secrets und Kundendaten bleiben ausgeschlossen.

Projektlizenz: AGPL-3.0-only, siehe LICENSE.

<!-- todolino:begin -->
## Todolino

Dieses Projekt wird in Todolino geplant (Projekt-ID in `.todolino.json`). Das Board laufend nutzen, nicht nur einmal am Ende:
- Start: `session_start` (Skill `todolino`) oder `get_sync_status`, `get_command_center`, `list_open_questions`, `list_pending_reviews`; ist das Board veraltet, zuerst `sync_project`.
- Vor der Arbeit: passende Aufgabe suchen oder mit `create_task` anlegen (keine Duplikate), dann `claim_task`.
- Nach jedem abgeschlossenen Teilschritt und jedem Commit: `post_progress`.
- Entscheidungen des Nutzers als `ask_question` an der Aufgabe stellen statt nur im Chat zu fragen.
- Fertig: `request_review` NUR wenn der Nutzer etwas ansehen oder entscheiden muss (sichtbares Ergebnis, Risiko, Rollout). Reine Update-Infos (Commit, Tests grün, interne Änderung) gehören in `post_progress`, nicht in ein Review. Eigene Arbeit nie selbst auf erledigt setzen. Ende: `record_sync`.
- Texte am Board kurz und in Stichpunkten: Überschrift = Aufgabentitel; Review: ein Satz Ergebnis + höchstens 4 Stichpunkte (neu, geprüft, ansehen, offen); Frage: 1 bis 2 Zeilen + 2 bis 4 Optionen, Empfehlung zuerst; Fortschritt: 1 bis 2 Sätze.
- Gestartete Agenten bekommen die Aufgaben-ID im Prompt und melden `post_progress` selbst; die Hauptsession stellt das Review.
<!-- todolino:end -->
