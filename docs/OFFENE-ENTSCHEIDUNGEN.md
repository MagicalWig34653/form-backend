# Offene Entscheidungen

Vor abhängiger Umsetzung klären; keine erneute Abfrage bereits bestätigter Grundwünsche.

1. Produktname und spätere Remote-Entscheidung. Lizenz ist verbindlich AGPLv3 (AGPL-3.0-only), siehe LICENSE.
2. Swift-Framework, konkrete Targetstruktur und minimale Laufzeitversionen; Vapor/Fluent sind Vorschläge.
3. Kunden-/Mandantenmodell, Rollen und Berechtigungen für Konfiguration, Veröffentlichung, Inhalte und Debug.
4. Genaue Verschlüsselungsprofile, Schlüsselgranularität, erlaubte Klartextpersistenz für Retry, Entschlüsselung/Resend und Recovery.
5. Umfang des ersten Ablaufeditors: azyklische Graphen, Teilabläufe, Warte-/Freigabeschritte, Schleifen und Skriptknoten.
6. Ausführungsorte und minimale Fähigkeiten von PHP-SDK und optionalem Docker-Agenten; unterstützte PHP-Versionen.
7. Designfreiheit und Feldzuordnung auf Bestandsseiten; genaue Semantik gesperrter/verborgener Felder.
8. Domainbesitzprüfung und Vertrag mit vorhandenem Reverse Proxy (Host-/Forwarded-Header), ohne Proxy/TLS zu implementieren.
9. Debugaufzeichnung: Profilgrenzen, Maskierung, Klartextzugang, TTL, Export und Testzielverwaltung.
10. Statistik: Ereignisdefinitionen, Besuch/Beginn/Abbruch-Instrumentierung, Datenschutz-/Retentionregeln und Conversion-Semantik.
11. Speicherregeln: pro Kunde/Formular, Größenlimits, externer Ausfall und spätere Verlagerung vorhandener Daten.
12. Migrationsquelle/-stand, zulässige Unterbrechung, Admin-RP-ID/Passkeys, Altchiffrate und offene Zustellungen.
13. REST-/MCP-Rechte für Entwürfe, Tests und Veröffentlichung; KI-Konvertierung von PHP und mögliche Übergangsadapter.
14. Code-/Kommentarsprache, Repo-/Branchkonventionen und verfügbarer Codex-Zugang.

15. (aus P0) Ed25519-Signatur v2: Pflicht für jedes Formular oder Übergang ohne Public Key wie im Altbestand?
16. (aus P0) Passwort-Login: eigener Fehlversuchs-Lockout (Altbestand hat keinen) und Rate-Limit für Admin-Oberflächen.
17. (aus P0) Altkompatibilität: müssen `:1`/CBC-Chiffrate und v1-Header-Schlüssel dauerhaft lesbar bleiben, oder vorher Umstieg auf `:2`?
18. (aus P0) Migration offener Zustellungen (`mailZustellung`, `webhookOutbox`): Quiesce vor Cutover oder Übernahme laufender Wiederholungen?
19. (aus P0) Mail-Cron: bleibt „melden statt senden“ mit manuellem Resend (Passphrase), oder automatischer Wiederholversand?

Beschlossen am 26.10.2026 (ADR 0001): Nr. 2 Vapor+Fluent, Nr. 3 Grundmodell Kunde>Formulare mit Rollen Admin/Betreuer/Kunde, Nr. 17 Altformate nur im Migrationswerkzeug, Nr. 14 Code englisch/Nutzertexte deutsch (Teilaspekte jeweils offen).

Beschlossen am 26.10.2026 (ADR 0002): Nr. 15 Ed25519-Pflicht mit befristeter Ausnahme, Nr. 16 Lockout+Backoff und Admin-Rate-Limit, Nr. 18 Quiesce vor Cutover, Nr. 19 Mail-Cron melden/manueller Resend.

Aus P2 (26.10.2026, Verträge unter `contracts/`, Details in deren HANDOFF-Dateien):
20. Alt-SDK-Header-Schlüssel (v1): ADR 0001 erlaubt ihr Lesen nur im Migrationswerkzeug, Alt-SDKs im Feld senden sie aber weiter. Vorschlag: separater Docker-Kompatibilitätsadapter, der v1 entgegennimmt und auf den neuen Vertrag übersetzt (`contracts/ingest/README.md`, K12). Bestätigen oder Alternative wählen.
21. Alle als VORGESCHLAGEN markierten Werte bestätigen: Lockout/Backoff/Rate-Limits, Sitzungs- und Tokenlaufzeiten (`contracts/auth/HANDOFF.md`), Befristung der Signaturausnahme (K14), Moduldeaktivierung/Effekttransaktionen im Ablaufmodell (`contracts/flow/HANDOFF.md`).
22. Bedeutung der „zusätzlichen symmetrischen Nutzlasthülle“ (ADR 0003 Nr. 4): `sym` im Paket oder eigener Transportvertrag (K04).
23. Offene Krypto-Prüfaufträge: AES-Schlüsselkürzung der Header-Schlüssel, RSA-OAEP-Hash, PEM-Format (Prüfung gegen Altcode, keine Nutzerentscheidung).

Beschlossen am 26.10.2026 (ADR 0003): Nr. 1, 4 (Rest), 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 (Rest). Damit sind alle Grundentscheidungen P1 gefallen; verbleibend sind Detailwerte (Lockout-/Rate-Limit-Schwellen, Rollenrechte im Einzelnen, Targetstruktur, Mindestversionen), die in P2 festgelegt werden.

Bereits entschieden: Swift, Svelte/shadcn, MariaDB, modulares System, PHP-SDK, DB als Standardspeicher, optional S3/SFTP, formularbezogene Verschlüsselung, HTTPS oder zusätzliche symmetrische Nutzlastverschlüsselung, Debug-Warten auf Anfrage, Statistikerhalt/-ausbau, vorhandener externer Reverse Proxy, Claude-Koordination mit Sonnet/Haiku und sinnvoller Codex-Nutzung.

Aus dem Vertragsreview P2 (27.10.2026, `docs/paritaet/review-P2-vertraege.md`):
24. Feine Rollen-/Aktionsrechte (H02): Betreuerveröffentlichung, Kundenrechte, Entschlüsselung/Export/Löschung/Debug, Workflowfreigabe/-fortsetzung.
25. Bedienung nach Warten/Crash und Resend (H07/H09): bewusste erneute Klartext-/Schlüsselfreigabe; unveränderter Resend vs. bearbeiteter Neuversand.
26. Gemeinsame Alt-Hosts (H04): zentrale Ingesthosts getrennt von eindeutigen Ansichtsdomains.
27. Statistik/Ads und Altbestand > 13 Monate (M04).
28. Kunden-/Schlüsselschnitt globaler Altgenerationen, nicht migrierbare Zeilen (H08/M05).
29. Bewusste Legacyverschärfungen (M02): Scannerfehler 503, typisierte Validierung, unbekannte Felder, Statuscodes 418/424.
30. OAuth-/Token-/Sitzungsübergang: Übernahme oder Neufreigabe (M05). Nr. 21 umfasst weiterhin die Sicherheits-/Betriebswerte.

Beschlossen am 27.10.2026 (ADR 0004 `decisions/0004-vertragsreview-entscheidungen.md`): Nr. 20 (befristeter Adapter), 22 (eigener Transportvertrag), 24 (frei konfigurierbare Rechte/Gruppen), 25, 26, 27 (Altbestand komplett), 29 Teil (typisierte Validierung), 30 (Tokens übernehmen). Offen: Nr. 21 (Zahlenwerte), Rest von 29 (Scannerausfall, 418/424), 28.

Beschlossen am 29.10.2026 (ADR 0005 `decisions/0005-vertragsrunde-3-entscheidungen.md`): D1 (Domain folgt Release nicht automatisch, auch an Zugriffsadressen koppelbar), D2 (eigene Adapter-Identität), D3 (Transporthülle pro Formular), D4 (Neuanmeldung statt Token-Übernahme, ersetzt ADR 0004 Nr. 8), D6 (Altverhalten), D7 (Altstatistik komplett). Offen: D5 (Erklärung nachgefragt), D8–D11.

Beschlossen am 30.10.2026 (ADR 0006): A2 (Adapter nicht aktivieren, SDK-Umstellung vor Cutover; ersetzt faktisch Nr. 20), T3 (nur Anfragen geschützt), D4-Rückfrage (auch mcp_tokens neu), D5 (409). Offen: D8–D11, Nr. 21, Nr. 28.

Beschlossen am 30.10.2026 (ADR 0006 Nachträge): D8, D9, D10 (JavaScript in Isolation), D11 (Vorschlagswerte), Nr. 28 (Zuordnung per Formular, Rewrap). Damit sind alle Grundentscheidungen gefallen; verbleibend sind technische Details und Reviews.
