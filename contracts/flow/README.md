# P2-4: Formular-, Ablauf- und Ereignisverträge

Stand: 26.10.2026. SPDX-License-Identifier: AGPL-3.0-only.

**Vertragsentwurf 0.1.0 — VORGESCHLAGEN.** Dieses Paket konkretisiert bestätigte
Anforderungen für die Abstimmung in P2. Es enthält keine Engine, Sandbox oder
Veröffentlichungsfunktion. Alle neuen Eigenschaftsnamen, Enums, Versionsregeln,
Algorithmen und Beispielgrenzen sind VORGESCHLAGEN; sie werden durch gültige
Beispiele nicht zu Nutzerentscheidungen. In den Instanzen ist dieser Status durch
`proposalStatus: VORGESCHLAGEN` sichtbar. Es gibt keine stillen Standardwerte für
Laufzeitgrenzen. Die `.invalid`-Schema-IDs sind stabile Entwurfskennungen ohne
Netzwerkdienst; lokale Auflösung erfolgt über `$id` und ein Schema-Register.

## Maßgebliche Quellen und abgegrenztes Paket

Gelesen: [AGENTS.md](../../AGENTS.md), [STATUS](../../docs/STATUS.md),
[ARBEITSPLAN](../../docs/ARBEITSPLAN.md), [ENTWICKLUNG](../../docs/ENTWICKLUNG.md),
[ADR 0001](../../docs/decisions/0001-grundentscheidungen-p1.md),
[ADR 0002](../../docs/decisions/0002-sicherheit-und-cutover.md),
[ADR 0003](../../docs/decisions/0003-produkt-und-betrieb.md),
[Formulare/Abläufe](../../docs/FORMULARE-UND-ABLAEUFE.md),
[Architektur](../../docs/ARCHITEKTUR.md),
[Sicherheit/Daten](../../docs/SICHERHEIT-UND-DATEN.md),
[Parität](../../docs/PARITAET.md),
[Funktionen/Felder](../../docs/paritaet/B-funktionen-felder.md) und
[Anforderungen: wegwerfbare Sessions](../../docs/ANFORDERUNGEN.md#wegwerfbare-sessions--verbindliche-anforderung).
Bei Widersprüchen gelten die bestätigten ADRs vor älteren Entwürfen.

Ziel und Dateibesitz: ausschließlich `contracts/flow/**`, ein schreibender Agent.
Abnahme: Draft-2020-12-Schemas, synthetische Beispiele, wiederholbare lokale
Prüfung, begründete Semantik und separat umrissene Sandbox-Anforderungen.
Keine Änderungen außerhalb dieses Verzeichnisses, keine Zugriffe auf das
Altprojekt nötig; dessen Fakten werden aus P0-B übernommen. Keine Migration,
Installation, Veröffentlichung oder Produktimplementierung.
Der paketbezogene [Fortsetzungsstand](HANDOFF.md) bleibt wegen der ausdrücklich
beschränkten Schreibfreigabe hier; STATUS/ARBEITSPLAN/ADRs werden von der
Koordination nach Review aktualisiert. Hier werden keine neuen ADRs beschlossen.

## Bestätigt und vorgeschlagen

| Quelle | Bestätigte Vorgabe | Konkretisierung dieses Entwurfs |
| --- | --- | --- |
| ADR 0001/0003 | Kunde als Mandant; englischer Code, deutsche Nutzertexte | stabile Feld-IDs, getrennte HTML-Namen, Lokalisierungsobjekte |
| ADR 0003 Nr. 5 | voller Editor: Graphen, Schleifen, Warten, Freigabe, Skripte; Grenzen und Wiederanlauf | explizite Kontrollknoten, serielle Token-Semantik, Budgets, Checkpoints und Fencing |
| ADR 0003 Nr. 7 | Zuordnung per Name; gesperrt serverseitig fixiert; verborgen nicht gerendert, aber validiert | `locked`, `fixedValue`, `hidden`, getrennt von UI-Attributen |
| ADR 0002 Nr. 19 | Mail-Cron meldet; Resend nur durch berechtigten Benutzer mit Passphrase | `waiting-manual`, stabile Effekt-ID; kein automatischer Klartext-Retry |
| ADR 0003 Nr. 4/11 | HPKE `:2` bzw. `sym`; Kundenschlüsselgeneration; DB/S3/SFTP, Annahmefehler bei Speicherausfall | Profilkennungen und Speicherreferenzen; keine neuen Kryptoparameter |
| ADR 0003 Nr. 9 | sensible Werte maskieren, TTL 15 Minuten, Klartext nur mit Recht und Schlüssel, Export maskiert | maskierter Ereignisvertrag; TTL ab Aufzeichnungsbeginn ohne Verlängerung |
| ADR 0003 Nr. 10 | pseudonym, keine IP, 13 Monate, vier Ereignisse, Absenden/Besuch, Löschprotokoll bleibt | Ereignis-IDs, Annahmeereignis vom Ingest, nach Umgebung getrennte Aggregation |
| ADR 0003 Nr. 13 | REST/MCP: Entwürfe/Tests; Veröffentlichung nur Mensch mit Bestätigung | Import nur als Entwurf; Veröffentlichungsbezug mit Auditverweis |

## Dateien und Begründung

| Datei | Zweck |
| --- | --- |
| `common.schema.json` | gemeinsame Typen, feste Referenzen, Laufzeitlimits, Retry und Klartextbedarf |
| `form.schema.json` | mandantenbezogene Felder, Validierung, Sperren, Profil und Speicher |
| `view.schema.json` | versionierte Ansicht mit Schritten, Abschnitten, Theme und Feldplatzierung |
| `graph.schema.json` | alle Editor-Knoten, gerichtete Kanten, explizite Schleifen und Grenzen |
| `release.schema.json` | unveränderliche Bindung an exakte Formular-/Ansicht-/Ablauf-/Modulversionen |
| `execution.schema.json` | dauerhafter Zustand, Budget, Wiederanlauf, Lease, Idempotenz und Effekte |
| `block.schema.json` | Ein-/Ausgabe-/Konfigurationsschema, Orte, Rechte, Retry, Klartext und Maskierung |
| `module.schema.json` | Modulbesitz, Abhängigkeiten, Bausteine, Aktivierung und Gesundheitszustand |
| `script-artifact.schema.json` | inertes, versioniertes Quellartefakt mit Hash; kein Ausführungsrecht |
| `debug-event.schema.json` | ausschließlich maskierte Traceereignisse mit 900 Sekunden TTL |
| `statistics-event.schema.json` | Besuch, Beginn, Absenden und Abbruch ohne Inhalte/IP |
| `package.schema.json` | portable Definitionen, Vorlagen und Verbindungsaliase; keine Credentials |
| `SANDBOX-ANFORDERUNGEN.md` | eigener Folgeauftrag mit Sicherheits- und Abnahmeanforderungen |
| `examples/manifest.json` | vollständige Zuordnung der 21 synthetischen Beispiele zu ihren Schemas |
| `validate.py` | Offline-Prüfung einschließlich ausgewählter semantischer Gegenbeispiele |

Objektverträge sind geschlossen (`additionalProperties: false`). Felder und
Graphknoten sind nach stabilen IDs indiziert; so gibt es innerhalb eines Objekts
keine doppelten ID-Einträge. Parser müssen doppelte JSON-Schlüssel vor der
Schemaauswertung ablehnen. HTML-Feldnamen müssen zusätzlich eindeutig sein.
Definitionen tragen eine eigene Version, die Vertragsversion steht separat.
Breaking Changes brauchen eine neue Vertragsversion und explizite Migration.
Unbekannte Versionen ablehnen. Die URI-Version bedeutet keine Produktionsfreigabe.

Referenzen mit `sha256` fixieren Inhalt und Version. Die Beispiele verwenden dafür
UTF-8 und `json.dumps(..., ensure_ascii=False, sort_keys=True, separators=(',', ':'))`.
Das ist **nur eine VORGESCHLAGENE Fixture-Konvention**, kein produktiver
Signatur-/Kanonisierungsvertrag und kein Ersatz für die Legacy-Signaturregeln.
Modulzugehörigkeit referenziert Bausteine nur mit ID/Version, während Bausteine
auf das Modul mit Hash zeigen. Das vermeidet zyklische Hashabhängigkeiten;
der Veröffentlichungsbezug fixiert die verwendeten Bausteine separat mit Hash.

## Feld- und Ansichtssemantik — VORGESCHLAGEN

1. Name auf stabile Feld-ID abbilden; Mehrfachwerte/Dateien gemäß Feldtyp
   normalisieren. Unbekannte Eingaben je Formular ablehnen oder verwerfen,
   niemals ungeprüft persistieren. Keine implizite Typumwandlung in der Engine.
2. Bei `locked: true` den Clientwert unabhängig von dessen Inhalt durch
   `fixedValue` ersetzen, auch wenn die Eingabe fehlt. Der feste Wert gehört zur
   serverseitigen Definition, niemals zu einer frei wählbaren Browserkonfiguration.
3. Für jedes Feld Anwesenheit gemäß `required` prüfen; vorhandene Werte gegen
   `validation` prüfen, ausdrücklich auch verborgene und fixierte Werte.
   Ein Leerstring ist vorhanden; Nichtleerheit verlangt etwa `minLength: 1`.
   `null` ist nur bei explizit passendem Schema zulässig.
4. `hidden: true` darf in keiner Ansicht gerendert werden, auch nicht als
   HTML-hidden-input. `showWhen` steuert nur die Darstellung sichtbarer Felder;
   es hebt serverseitige Pflicht/Validierung nicht auf. `readOnly` und `disabled`
   sind UI-Verhalten, keine Autorisierung oder Fixierung. Optional fehlende
   verborgene Felder werden nicht erfunden; Pflichtfelder brauchen eine Quelle.
5. `validation` ist ein Draft-2020-12-Schema für den normalisierten Einzelwert.
   `kind` legt Grundtyp und Adapter fest: Text/E-Mail/Datum/Auswahl als String,
   Zahl als JSON-Zahl, Bool als JSON-Boolean, Datei als geprüfte Uploadreferenz.
   Auswahlregeln verwenden `enum`, Zustimmung `const`, Längen `minLength`/
   `maxLength`, Grenzen `minimum`/`maximum`. Grundtyp und Validierung müssen
   vereinbar sein. Uploadpräsenz, MIME/Größe/Scan und Artefaktzugriff werden am
   tatsächlichen Upload geprüft, nicht an einem frei behaupteten Dateinamen.

`typed-v1`, Unbekanntfeldverhalten, Regexdialekt und Dateimetadaten sind Vorschläge.
P0-B beschreibt sieben Bestandsarten (`text/email/datum/zahl/bool/auswahl/datei`).
Dort akzeptierte Leerstrings, PHP-Datumswerte und Booleanstrings sowie die erste
Datei/erste E-Mail dürfen nicht still als identisches neues Verhalten gelten.
Legacy-Adapter müssen Bestandsfälle gesondert prüfen; dieses Paket beschließt
keine Inkompatibilität. Ein generiertes Einsendungs-/Uploadsicherheitsschema und
Adaptervergleich sind Folgearbeit. Das Formularschema prüft Definitionen,
nicht eingehende Formularwerte oder deren serverseitige Verarbeitung.

## Graph, Bausteine und Veröffentlichung — VORGESCHLAGEN

Ein Durchlauf führt einen aktiven Kontrollpfad seriell aus; Bedingungen wählen
genau einen Port. Fork/Join ist keine zusätzliche beschlossene Fähigkeit.
`entry` erzeugt den normalisierten Kontext. Ein Baustein liest explizite
`inputBindings` (Quellknoten, JSON-Pointer), verarbeitet nur validierte Eingaben
und liefert schema-validierte Ausgaben. Nicht verfügbare Quellwerte sind ein
sichtbarer Fehler; keine versteckte Vorwärtsreferenz oder ungeprüfte Interpolation.
`condition`/`loop` werten ihr Prädikatschema gegen den aktuellen Kontext aus.

Ein Schleifenknoten wählt `body` bei erfülltem Prädikat, sonst `done`. Vor jeder
Body-Ausführung wird der dauerhafte Iterationszähler erhöht. Bei weiter wahrem
Prädikat und erreichtem `maxIterations` schlägt der Durchlauf mit `step-limit`
fehl, statt unbemerkt erfolgreich zu enden. Jeder Zyklus muss einen kontrollierten
Schleifenknoten enthalten. Eintritt in jeden Knoten und jeder Retry verbrauchen
einen Schritt; eine suspendierte Wartezeit verbraucht keine Workerzeit.
Wiederanlauf, Schleifen und Teilabläufe dürfen die Budgets nicht zurücksetzen.

`wait` speichert einen fälligen Zeitpunkt und gibt die Lease frei. Ein Scheduler
markiert nur die Fälligkeit; die Fortsetzung geschieht ausschließlich durch die
menschliche Freigabe nach [wiederanlauf.md](wiederanlauf.md) (`resume`), niemals
durch den Timer allein (ADR 0004). `approval` speichert eine Freigabeanforderung;
Antworten sind an Mandant, Durchlauf, Knotenbesuch, gültige Berechtigung und
ablauffähigen Zustand gebunden und werden atomar einmalig konsumiert. Ablehnung
oder Ablauf nehmen den konfigurierten Pfad; Zeitüberschreitungen sind kein Erfolg.
Widerrufene Rechte werden bei Antwort erneut geprüft. Teilabläufe sind exakt
versioniert, teilen Root-Budgets und dürfen keine unkontrollierte Rekursion erzeugen.

`next`, `true/false`, `body/done`, `resume`, `approved/rejected` sind die regulären
Ports; pro Port höchstens eine Kante. Optional `error`, sonst `stop-and-record`.
Endknoten haben keine Ausgänge. Ein `error`-Pfad darf harte Ressourcenlimits nicht
umgehen. Schema prüft Knotenformen; vor Veröffentlichung zusätzlich Graphverweise,
Erreichbarkeit, Ports, Zyklen, Typfluss, Teilablaufrekursion und Abhängigkeitsabschluss
prüfen. `validate.py` prüft davon ausgewählte statische Fixture-Eigenschaften.

Der engste Wert aus Serverrichtlinie, Formularablauf, Baustein, Skript und verbleibendem
Root-Budget gilt: `maxSteps`, `activeTimeoutMs`, `maxElapsedMs`, `memoryBytes`,
`nodeTimeoutMs`, `maxStateBytes`. `maxElapsedMs` umfasst Warten/Freigabe;
`activeTimeoutMs` umfasst Verarbeitung über alle Wiederanläufe. Speicherlimits
brauchen Prozess-/Sandbox-Durchsetzung und begrenztes Streaming. Beispielwerte
(1.000 Schritte, 30 s aktive Zeit, 24 h Gesamtdauer, 64 MiB Speicher, 5 s pro Knoten,
1 MiB Zustand) sind **VORGESCHLAGEN**, keine Betriebsdefaults.

Ein Modul ist nur bei allen vier Stufen effektiv aktiv: installiert, serverweit
verfügbar, für Kunde freigegeben, für Formular aktiv. Manifestwerte sind keine
vertrauenswürdigen Rechtebelege; Import verwirft Aktivierungs-/Healthbehauptungen
und ermittelt sie serverseitig. `onDisable` muss wartende Durchläufe auslaufen
lassen, sichtbar pausieren oder abbrechen; niemals still verlieren. Rechte und
Ausführungsort werden bei jedem Übergang erneut geprüft. Rechtekennungen,
Deaktivierungsdetails und Healthcodes bleiben VORGESCHLAGEN.

Eine Veröffentlichung verlangt verfügbare Module/Bausteine/Orte, passenden
Klartextbedarf und vorhandene Verbindungszuordnungen. Der menschlich bestätigte
Veröffentlichungsbezug ist unveränderlich, bestehende Durchläufe bleiben daran
gebunden. Ein JSON-Feld `actorKind: human` beweist keine Autorisierung: Derselbe
Anwendungsdienst muss REST, MCP und UI prüfen und die Bestätigung auditieren.
Das Skriptbeispiel bleibt wegen der nicht implementierten Sandbox unveröffentlichbar.

## Ausführung, Lease und Außenwirkungen — VORGESCHLAGEN

Zustände: `queued → running → succeeded|failed`; `running → waiting → queued`,
`running → waiting-manual → queued`; Abbruch aus nichtterminalen Zuständen.
Pausierung bei Modulabschaltung hält einen Lauf in `waiting` mit
`module-pause`, exaktem Modulbezug und Wiederaufnahmerecht. Nach erneuter
Aktivierung setzt nur ein autorisierter atomarer Übergang fort. Die Rootdeadline
läuft weiter; Ablauf beendet auch einen pausierten Lauf sichtbar. Terminale Läufe
sind unveränderlich. Ein bewusster erneuter Lauf ist eine neue Aktion mit
Herkunftsverweis, nicht die Rücksetzung eines abgeschlossenen Zustands.

- Atomare Übernahme nur mit passender `revision`, ohne gültige fremde Lease;
  `ownerId`, steigender `fence` und `expiresAt` schützen jeden Commit. Heartbeats
  verlängern nur die eigene noch gültige Lease. Der Worker darf nach Leaseverlust
  nicht committen oder neue Effekte beginnen. Beispiel-Lease 30 s: VORGESCHLAGEN.
- Zustand, Budget, Checkpoint, Effektreservierung und Outbox/Freigabe müssen an der
  definierten Transaktionsgrenze zusammenpassen. Nach Ablauf ist eine bewusste menschliche Freigabe nach wiederanlauf.md
  erforderlich; dann wird vom letzten bestätigten Checkpoint fortgesetzt. Version/Deadline/Zähler bleiben erhalten.
  Checkpoints enthalten nur verschlüsselte Objektreferenzen, keinen Klartext.
- Die Idempotenzidentität gilt innerhalb Mandant + Formular + Einsendung + Release + runSlot; siehe ../data/abbildung.md.
  Atomare Reservierung bindet Schlüssel an den serverseitig bestimmten
  `requestDigest`. Gleicher Inhalt liefert vorhandenen Lauf/Ergebnis, anderer
  Inhalt einen Konflikt; aktive Reservierung startet keinen zweiten Lauf.
  Payloadnormalisierung, Hashkanonisierung, Schlüssellänge und Retention sind
  abzustimmen. Beispiel-Retention sieben Tage ist VORGESCHLAGEN.
- Effekte haben eine stabile Identität aus Lauf-UUID, Knoten, Besuch und
  Effektslot. Die konkrete Schlüsselableitung bleibt abzustimmen. Ein Retry behält die Identität; ein neuer Schleifenbesuch bekommt
  eine neue. `prepared → in-flight → confirmed|uncertain|failed` trennt lokalen
  Zustand und externe Annahme. Versuchszähler und Fehlversuche bleiben dauerhaft
  erhalten (`checkpoint.nodeAttempts`, `effects[].attempt`) und zählen gegen
  Retry-/Rootlimits. Der jeweilige Besuch bleibt über `nodeVisits` identifizierbar;
  eine Wiederaufnahme erhöht den Versuch, ohne den Besuch oder Effektschlüssel
  neu anzulegen. Ein neuer Schleifenbesuch beginnt einen eigenen Versuchszähler.
- Absturz nach externer Annahme vor Commit ergibt `uncertain`. Receiver-Idempotenz
  oder verlässliche Abfrage kann klären; ohne diese Fähigkeiten manuelle Klärung.
  Lease/Fencing verhindern nicht rückwirkend einen schon gestarteten Netzaufruf.
  Keine Genau-einmal-Garantie für SMTP; SMTP-Annahme ist kein Zustell-/Lesebeleg.
- Automatische Retries nur für geeignete Effekte ohne erneut benötigten Klartext,
  mit expliziter Idempotenzstrategie und begrenztem Backoff/Jitter. Der Entwurf
  verbietet automatische Retries für Klartextbausteine vorsorglich insgesamt;
  die genauere Unterscheidung noch verfügbarer flüchtiger Daten ist offen.
  Mail-Retry ist ausschließlich `never` oder `manual-authorized`.
  Resend braucht aktive Berechtigung und bewussten Schlüssel-/Passphrasezugang;
  kein Server-Cron entschlüsselt oder hält Klartext dafür vor.

Vor Engineimplementierung sind echte DB-/Mehrworker-/Crashprüfungen erforderlich:
konkurrierender Claim, Leaseverlust während I/O, alter Fence, Checkpoint-Crash,
Timeout über Warten, verbrauchtes Schleifenbudget, gleiche/abweichende Idempotenz,
unklare SMTP-Annahme und manuelles Resend ohne Doppelversand. Diese Prüfungen
werden hier weder implementiert noch als erfolgreich behauptet.

## Debug und Statistik

Der Debugvertrag ist zugleich die sichere Exportprojektion: Eingabe/Ausgabe
bestehen aus maskierten Feldpfaden; Änderungen, Validierungscodes, Empfängeraliase,
Knotendauer, Pfad und Verschlüsselungszustand bleiben sichtbar. Alle Werte werden
in diesem Entwurf maskiert (VORGESCHLAGENE konservative Projektion). Keine Header,
URLs mit Parametern, Stacktraces, freien Fehlermeldungen oder Schlüsselwerte.
Auch IDs/Codes dürfen keine Inhalte oder personenbezogenen Freitexte transportieren.

`ttlSeconds: 900` ist bestätigt. VORGESCHLAGENER TTL-Anker ist der Beginn der
Aufzeichnung: `expiresAt = recordingStartedAt + 900 s`, Folgeereignisse verlängern
nicht. Der Server setzt diese Zeiten, sperrt Lesen/Schreiben ab Ablauf und löscht
Aufzeichnung, Indizes und Cachekopien innerhalb der TTL. JSON Schema kann
Zeitdifferenzen nicht ausdrücken; der Prüfer kontrolliert die Beispieldaten.
Zugriff und Export auditieren. Klartextanzeige ist ein separater, noch zu
spezifizierender berechtigter und schlüsselgebundener Zugriff auf verschlüsselte
Originale, keine Eigenschaft dieses maskierten Ereignisses. Backend-Debug kann
fehlenden Schlüsselzugang nicht umgehen. Debugaufträge brauchen atomare Zuordnung
über Replikas. `test` simuliert oder nutzt verwaltete Testziele; `observe` verändert
den realen Lauf nicht. Eine Wiederholung mit Außenwirkung ist eine neue Aktion.

Statistikereignisse sind `visit` (Formular tatsächlich angezeigt, kein Konfigabruf),
`begin` (erste Interaktion), `submit` (serverseitig angenommene Einsendung,
nicht SMTP-Erfolg), `abandon` (explizites Clientsignal oder getrennt markierte
Inaktivitätsableitung). Diese Auslösedefinitionen und Abbruchschwellen sind
VORGESCHLAGEN. Blocker/fehlende Instrumentierung können Ereignisse fehlen lassen.
Pseudonyme dürfen nicht aus IP, E-Mail oder Formularwerten abgeleitet werden.
Clientsignale sind unvertrauenswürdig und brauchen Plausibilitäts-/Missbrauchsprüfung.
Keine IP, User-Agent, GCLID, freien URLs oder Feldwerte im neuen Ereignisvertrag.

Collector dedupliziert nach Ereignis-ID, `submit` zusätzlich nach Einsendung;
Retries und Resend erzeugen keine weitere Einsendung/Conversion. Pro Besuch
höchstens ein `visit`/`begin` und eine terminale Zuordnung für die Conversion,
späte Annahme löst einen vorher inferierten Abbruch auf. `Absenden / Besuch`
nach gleichem Formular/Ansicht/Version/Domain und Zeitraum aggregieren; bei null
Besuchen keine definierte Quote. Testereignisse standardmäßig ausschließen.
13 Kalendermonate Aufbewahrung sind bestätigt; Monatsende-/Zeitzonendetails und
Pseudonymrotation bleiben VORGESCHLAGEN. Löschprotokoll separat ohne Inhalte
behalten; auch Pseudonyme und Rohereignisse löschen, keine Rekonstruktion aus
Aggregaten. Bestehende Statistik/Ads/GCLID werden nicht verworfen: Migration und
abgetrennter Legacy-/Conversion-Vertrag sind noch zu koordinieren.

## Import/Export

Pakete enthalten ausschließlich Definitionen, inerte Skripte, Vorlagen,
Modulanforderungen und Verbindungsaliase. Keine Einsendungen, Durchläufe,
Debug-/Statistikdaten, Credentials, privaten Schlüssel oder Schlüsselhüllen.
`portableValue` sperrt häufige Credential-Eigenschaftsnamen rekursiv. Dies ist
kein Inhaltsnachweis: Ein Secret kann in jedem String, Schema-`default`, einer
Vorlage oder im Skript stehen. Export muss deshalb erlaubte Konfigurationen aus
ihren Schemas projizieren und sämtliche Artefakte auf eingebettete Credentials
prüfen; bei Unklarheit Export verweigern. Der Vertrag allein kann diese Garantie
nicht leisten. Aliase sind opake Kennungen, keine URLs/Zugangsdaten.

Import prüft Vertragsversion, Inhaltshash, Größen-/Tiefenlimits, erlaubte lokale
Schema-Referenzen, Abhängigkeiten und Mandantenzuordnung, zeigt Konflikte/Vorschau
und verlangt explizite Verbindungszuordnung. Keine `$ref`-Netzwerkabrufe, kein
Code-/HTML-Ausführen bei Vorschau. Wiederholung mit Paket-ID/Revision/Inhaltshash
liefert dasselbe Importergebnis; gleicher Schlüssel mit anderem Inhalt ist Konflikt.
ID-Kollisionen werden explizit zugeordnet oder umbenannt und alle Referenzen
konsistent neu gebunden. Hashneuberechnung durch Mapping erzeugt neue Entwürfe.
Import aktiviert nichts, testet keine echten Ziele und veröffentlicht nie.
Ein Test/Publish ist jeweils ein separat autorisierter Anwendungsdienst.

## Beispiele und lokale Prüfung

```sh
python3 contracts/flow/validate.py
```

Benötigt lokal `jsonschema` und `referencing`; keine Projekt-Buildabhängigkeit
installiert. Ausgeführt mit `jsonschema 4.26.0`: **12 Schemas gültig, 21 Beispiele
gültig, 41 Negativfälle abgelehnt**. Alle statischen lokalen `$ref` wurden aufgelöst,
auch in von Beispielen nicht benutzten Schemaästen. Keine Netzwerkabrufe.
Das optionale RFC3339-Extra fehlt lokal; das Skript ergänzt explizit Syntax- und
Kalenderprüfung für `date-time` (keine historische Schaltsekundentabelle).

Beispiele: `graph.json` enthält Verzweigung, Schleife, Skript, Timer, Teilablauf
und Freigabe; `execution*.json` zeigt Lease, Timer und unklaren Mailversand mit
manuellem Wiederanlauf; `execution-paused.json` zeigt die Modulpausierung. `mail-graph.json` und `mail-release.json` binden diesen
Mailfall separat. `statistics-*.json` illustriert alle vier Ereignisse.
`package.json` bündelt die Definitionen; die Sandbox bleibt eine ausdrücklich
unaufgelöste Anforderung. `release.json` ist ein synthetisches Strukturbeispiel,
keine tatsächlich veröffentlichte Konfiguration.

Die ergänzenden Fixture-Prüfungen decken Hashbindung, ausgewählte Graphinvarianten,
versteckte Ansichts-Felder, feste Feldwerte, Checkpointreferenzen und Zeitgrenzen
ab. Negativfälle prüfen unter anderem Klartext im Checkpoint, falsche Leases,
fehlende Sandbox, automatische Mail-Retries, unmaskierte Debugwerte, IP-Felder
und Credential-Eigenschaften. Keine vollständige Importvalidierung, kein
Sicherheitsaudit, keine laufende Engine, keine DB-/Sandbox-/Mehrreplikaprüfung.
Nächster Schritt: Koordinationsreview der VORGESCHLAGENEN Details, danach
Abstimmung von Ledgertransaktionen/Retrydetails und P6-Aufteilung.


## Technische Vertragskorrekturen 27.10.2026 — VORGESCHLAGEN

Gemeinsame UUID-/Artefakt-/Versions- und Generationszuordnung, totale
Zustands-/Modusabbildung und getrennte Idempotenzbereiche:
`../data/abbildung.md`. Neue Annahmen lösen die aktive Kundengeneration atomar
auf; historische Generation steht am Objekt, nicht in der gehashten Definition.
Alle verschlüsselten Zwischen-/Debug-/Metadatenobjekte einschließlich externer
Kopien folgen `../data/objektinventar.md`. Rechte und Klartextfortsetzung bleiben
durch ADR 0004 entschieden; technische Ausgestaltung siehe wiederanlauf.md. Paketexport verwendet unverändert `package.schema.json` mit
allen transitiven erlaubten Abhängigkeiten; Import bleibt Entwurf ohne Effekte.

`visitPseudonym` enthält 16–32 Hexbytepaare; SQL erhält exakt die dekodierten
16–32 Bytes ohne Padding oder Kürzung. Rückweg lowercase Hex. Ungerade Länge
wird abgelehnt. Das Geheimfeldnamenmuster in `portableValue` verwendet explizite
ASCII-Groß-/Kleinbuchstabenklassen statt sprachabhängigem Inlineflag. Das ist
keine Sandboxfreigabe: Schema-/Regexquoten, IPC-/Capabilityvertrag und unabhängige
P6-S-Abnahme bleiben OFFEN; bestehende Ausführungssperre bleibt bestehen.


## ADR 0004 — aktueller gemeinsamer Vertrag

[wiederanlauf.md](wiederanlauf.md) konkretisiert H07/H09 verbindlich hinsichtlich
Menschfreigabe nach Warten/Crash und unverändertem originalgebundenem Resend;
der technische CEK-Nachweis bleibt VORGESCHLAGEN. `continuationPolicy` im
Laufschema erzwingt die Deklaration, keine Laufzeitautorisierung.
`flow.execute/approve/resume` sind im gemeinsamen Rechtekatalog konfigurierbar.
Neue Formulare bleiben typed-v1; Altformulare werden separat per
`form_versions.validation_profile=legacy-v1` und festem Adapterverweis betrieben,
nicht als bereits typisierte portable Formschema-Instanz ausgegeben.
Siehe [Legacyadapter](../ingest/legacy-adapter.md). `sym-v2` ist als
Speicherprofil im Formschema gesperrt; zusätzliche Transporthülle siehe
[transport.md](../crypto/transport.md).
Altstatistik vollständig mit Herkunft legacy erhalten, unabhängig von der
13-Monatsfrist für neue Daten; mögliche IP-Bezüge nach ADR 0005 D7 geschützt übernehmen (Bestandsprüfung am Dump vorab, nur Herkunft legacy).
