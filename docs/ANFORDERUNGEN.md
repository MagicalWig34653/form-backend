# Anforderungen und Bestandsschutz

## Bestätigte Zielsetzung

Grundsätzlicher Neubau mit deutlich modularerer Struktur und langfristiger Erweiterbarkeit. Alle vorhandenen fachlichen Funktionen sollen erhalten bleiben. Backend in Swift, Oberfläche als PWA mit Svelte und shadcn. MariaDB bleibt. Backendinstanzen sollen möglichst zustandslos und für mehrere Docker-Swarm-Replikas geeignet sein.

Formulare auf Kundenseiten werden im Backend konfigurierbar: Felder hinzufügen, sperren, unsichtbar schalten und weitere Regeln festlegen. Kunden nutzen überwiegend Vanilla HTML/PHP/JS/CSS. Eine vollständige freie Seitengestaltung ist nicht als zwingende Anforderung bestätigt; strukturelle und gestalterische Anpassung bleiben Ziel des Formularmodells.

Formulare und Abläufe sollen ähnlich n8n zusammengeklickt werden können. Modulare Abläufe werden Formularen zugeordnet, importiert und exportiert. KI soll über MCP beim Erstellen und beim Nachbauen/Importieren vorhandener PHP-Skripte helfen können.

Bestehende und neue Schnittstellen werden getrennte, einzeln aktivierbare Module. Bestehende Kundenanbindungen bleiben kompatibel. Es muss weiterhin ein PHP-SDK geben, auch für Kunden ohne Docker. Ein zusätzlicher Docker-Client ist möglich.

Neue Formulare werden über einen Guide in der PWA eingerichtet, so weit wie möglich automatisiert. Schlüsselaustausch und Verwaltung werden im WebUI vereinfacht.

## Domains und Darstellung

Eigene Kundendomains und Subdomains lassen sich anbinden. Beispiel: Der Kunde setzt einen A-Eintrag auf die Server; im Backend wird dem Hostnamen ein Formular und eine Ansicht zugeordnet. Reverse Proxy, Zertifikate und deren Betrieb sind ausdrücklich außerhalb des Projektauftrags.

Formulare können vom Backend ausgeliefert werden. Die Variante mit Ausführung/Integration auf der Kundenseite bleibt Bestandteil. Formular und Ansicht sollen als getrennte Konzepte modelliert werden (Architekturvorschlag zur Umsetzung der Zuordnung).

## Daten, Sicherheit, Debug und Statistik

Verschlüsselung soll erhalten oder verbessert werden. Wie, wann und bis wohin verschlüsselt wird, wird pro Formular entschieden. Keine pauschale Ende-zu-Ende-Pflicht: Das Backend darf für den initialen Mailversand Klartext erhalten. Übertragung wahlweise nur über HTTPS oder zusätzlich symmetrisch verschlüsselt. Anforderungen an Profile, Speicherung und spätere Entschlüsselung müssen getrennt definiert werden.

Standardmäßig liegen alle hochgeladenen Formulardaten einschließlich Anhängen in MariaDB. Optional S3 oder SFTP anbinden. Timetrack dient als Orientierung, ist aber kein Nachweis einer dort vorhandenen SFTP-Implementierung.

Debugmodus: Auf eine Anfrage warten und anschließend den genauen Ablauf sowie Datenfluss mit den Änderungen je Schritt zeigen. Bestehende Statistiken erhalten und ausbauen.

Vollständige Datenmigration vom alten in das neue Backend ermöglichen.

## Funktionsinventar zur verbindlichen Überprüfung

Diese Liste ist aus Dokumentation und ausgewählten Quelltexten abgeleitet. In der Bestandsaufnahme vollständig gegen aktuelle Routen, Tests und Schema inklusive Migrationen abgleichen.

| Bereich            | Zu erhaltendes Verhalten                                                                                                                   |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Eingang            | v1-/v2-Routen, Konfiguration/Feldschema, Antworten und Statuscodes, Signaturen, Idempotenz                                                 |
| Felder und Handler | Typen, Pflichtfelder, Regeln, generische und individuelle Kundenhandler                                                                    |
| Betriebsarten      | Test/Produktion, IP-/CIDR-/DNS-basierte Autorisierung, vertrauenswürdige Netze/Proxys                                                      |
| Missbrauchsschutz  | Rate-Limits, Sperren, Turnstile und vorhandene Bot-/Netzprüfungen                                                                          |
| Uploads            | Größen-/Typprüfung, Scanstatus und Schadsoftwareprüfung mit sichtbaren Fehlerzuständen                                                     |
| Speicherung        | verschlüsselte Felder, Anhänge und Mailinhalte; alle vorhandenen Paketgenerationen                                                         |
| Versand            | SMTP, separater Mail-Proxy, Empfängerbegrenzung, Organisations-/Bestätigungsmail, Vorlagen, Zustellstatus und Wiederholungen               |
| Verlauf            | Filter, Suche, Mailvorschau, Anhänge, Einzel-/Stapelaktionen, erneuter Versand und Versandumfang                                           |
| Datenschutz        | Aufbewahrung, Löschschutz, Auskunft/Löschung, Exporte und Protokollierung                                                                  |
| Konten             | Rollen/Zuständigkeiten, Verwaltung/Sperrung, Passwort, TOTP, Passkeys, Sitzungsrichtlinien und Anmeldeprotokoll                            |
| Schlüssel          | formularbezogene SDK-Schlüssel, Provisionierung/Rotation, Browserentschlüsselung, Datenzugänge, Recovery und Bestandsumstieg               |
| Betrieb            | Dashboard, Statistik inkl. Google Ads/GCLID, Fehler-/Auditprotokolle, Konfiguration, Benachrichtigungen/Pushover, Aufräumjobs, Healthcheck |
| MCP                | bestehende Statistikwerkzeuge, persönliche Tokens, OAuth, Freigaben und Zugriffsprotokolle                                                 |
| PWA/UI             | bestehende Einstellungen, Darstellungsoptionen und PWA-Funktionen                                                                          |

„Erhalten“ bedeutet fachliche Parität. Alte Sicherheitslücken oder technische Zufälligkeiten werden nicht ungeprüft zum neuen Vertrag. Jede bewusste Verhaltensänderung muss dokumentiert und mit ihrer Kompatibilitätsfolge entschieden werden.

## Entwicklungsorganisation — bestätigt

Claude Code führt die Entwicklung. Agents nutzen Sonnet oder Haiku nach Schwierigkeit. Codex wird eingesetzt, wo sinnvoll. Die Arbeitsstruktur soll Tokenverbrauch und Fehler reduzieren. Konkrete Rollen, Pakete und Integrationsregeln stehen in ENTWICKLUNG.md.

## Wegwerfbare Sessions — verbindliche Anforderung

Das Repository ist die alleinige Source of Truth und das dauerhafte Projektgedächtnis. Jede Claude-Code-, Sonnet-, Haiku- oder Codex-Session muss jederzeit durch eine neue Session ohne Kenntnis früherer Chats fortgesetzt werden können.

Alle zur Fortsetzung benötigten Anforderungen, Nutzerentscheidungen, Architekturbegründungen, Verträge, Arbeitsstände, Änderungen, Testergebnisse, offenen Fehler, Blockaden und nächsten Schritte müssen im Repository dokumentiert sein. Chatverläufe, Agent-Memory, lokale Notizen und Desktop-Kopien dürfen keine alleinigen Wissensquellen sein. Vollständige Chats müssen dafür nicht kopiert werden; maßgeblich sind knappe, sachliche und nachvollziehbare Ergebnisse.

Dokumentation wird im selben Arbeitsschritt wie die fachliche Änderung aktualisiert. Vor jeder Übergabe, Unterbrechung, Sessionbeendigung oder einem Kontextwechsel sind STATUS, ARBEITSPLAN und bei Bedarf Entscheidungen/Übergaben auf den tatsächlichen Stand zu bringen. Bei unerwartetem Abbruch muss sich der Stand aus kleinen nachvollziehbaren Änderungen und den zuletzt gesicherten Notizen rekonstruieren lassen.

Zu sichern sind insbesondere Paket/Dateizuständigkeiten, Branch/Worktree, laufende Jobs oder Prozesse samt Fortsetzungs-/Abbruchhinweisen, ausgeführte und fehlende Prüfungen, Migrationsfolgen und der nächste konkrete Schritt. Secrets, private Schlüssel, Zugangsdaten und echte Kundendaten werden dabei niemals ins Repository geschrieben; nur sichere Referenzen auf deren vorgesehene Ablage dokumentieren.

Abnahmekriterium: Eine neue Session kann anhand von AGENTS.md, STATUS, ARBEITSPLAN und den referenzierten Verträgen/Entscheidungen den nächsten Schritt bestimmen, ohne nach einem alten Chat fragen zu müssen.

## Lizenz — verbindlich

Das Projekt steht unter GNU Affero General Public License, Version 3 (AGPLv3). Für dieses Repository gilt der SPDX-Identifier `AGPL-3.0-only`; spätere Lizenzversionen sind nicht automatisch eingeschlossen. Der vollständige unveränderte Lizenztext liegt in LICENSE. Abhängigkeiten und übernommene Komponenten behalten ihre jeweiligen Lizenzen und erforderlichen Hinweise.
