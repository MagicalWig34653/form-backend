# Eigenes Folgepaket P6-S: Skript-Sandbox

Stand: 26.10.2026. SPDX-License-Identifier: AGPL-3.0-only.
Status: **Anforderungsliste / VORGESCHLAGEN**, keine implementierte Sandbox und
keine Auswahl von Sprache, Runtime, Betriebssystem oder Isolationstechnik.
ADR 0003 Nr. 5 bestätigt Skriptknoten, Ressourcenlimits und ein eigenes
Sandbox-Paket mit unabhängigem Review. Engine ohne Skripte zuerst.

## Paketgrenze und Vertrag

Ziel: untrusted Skripte für einen exakt versionierten Ablauf ausführen können,
ohne Backendprozess, fremde Mandanten, Schlüssel oder externe Ziele freizugeben.
Dateibesitz wird für das Folgepaket separat vergeben; dieser Auftrag reserviert
keine Implementierungsdateien. Abhängigkeiten: abgestimmte Flowverträge,
Sicherheitsprofile, Rechte, Effektledger und reproduzierbare synthetische Umgebung.
Keine Ausführung hochgeladener Skripte im API-/Workerprozess als Zwischenlösung.

Eingang: fixiertes `script-artifact`, fixiertes Sandboxprofil, Durchlauf-/Knoten-/
Besuchs-ID, Fence, validierte Eingabe, genehmigter Klartextbedarf, effektive
Restbudgets und explizite Capabilityliste. Ausgang: validierte Ausgabe oder
strukturierter Fehlercode, Ressourcenverbrauch, ausschließlich maskierter Trace.
Die genaue IPC-Hülle ist **VORGESCHLAGEN** und im Folgepaket als eigenes
Draft-2020-12-Schema samt Gegenbeispielen abzustimmen. Keine beliebigen Objekte,
Funktionsreferenzen oder Hosthandles serialisieren.

## Erforderliche Sicherheitsanforderungen

1. **Isolation:** eigene kurzlebige Isolationsinstanz pro Ausführung/Mandant;
   kein direkter Interpreter im Backend. Prozess-/OS-Grenze oder gleichwertig
   nachzuweisende Isolation; Sprachsandbox allein genügt nicht als Nachweis.
   Nichtprivilegierter Benutzer, minimale Systemfähigkeiten, kein Hostsocket,
   keine Docker-/Cloud-Metadaten-/DB-Verbindung, keine Backendumgebung.
2. **Unveränderliche Artefakte:** Sprache, Runtime, Profil und Quellartefakt
   versionieren und mit Hash fixieren. Keine Paketinstallation, dynamischen
   Imports, Netzabhängigkeiten oder Ausführung von Werkzeugen zur Laufzeit.
   Artefakte bei Import, Veröffentlichung und Ausführung verifizieren.
3. **Ressourcen:** harte Grenzen für CPU/aktive Zeit, absolute Frist, Speicher,
   Prozesse/Threads, Datei-/Socketdeskriptoren, Ein-/Ausgabe, Trace und temporäre
   Dateien. Niedrigstes Restbudget gilt. Endlosschleife, Rekursion und Ausgabe-
   flut müssen zuverlässig abgebrochen werden. Kein Timeout nur auf kooperative
   Skriptrückgabe stützen. Abbruch beendet auch Kindprozesse und räumt Ressourcen.
4. **Dateisystem:** kein Hostdateisystem, kein Zugriff auf Secrets oder andere
   Aufträge. Falls nötig begrenztes flüchtiges Arbeitsverzeichnis, nach Ende
   vollständig verwerfen. Keine Klartexte in Swap, Core-Dumps, Diagnoselogs,
   dauerhaften Volumes oder erhaltenen Prozess-Snapshots.
5. **Netzwerk:** standardmäßig vollständig gesperrt, auch DNS/Loopback/IPv6/
   Metadatenendpunkte. Benötigte Außenwirkungen ausschließlich über einen
   autorisierenden Broker mit Zielalias, SSRF-Schutz und Effektledger.
   Keine direkten SMTP-/HTTP-/S3-/SFTP-Aufrufe aus Skripten.
6. **Capabilities:** pro Aufruf minimale, mandanten-/formular-/releasegebundene
   Fähigkeiten. Hostoperationen erlaubnislistenbasiert. Keine universellen Tokens,
   privaten Schlüssel, Passphrasen oder Credentials an das Skript geben.
   Widerruf und Modulabschaltung auch bei bereits wartenden Läufen beachten.
7. **Klartext:** nur explizit erlaubte Eingabefelder, Ort und Zweck. Daten im
   Speicher nur für den Aufruf, keine Persistenz für automatische Retries.
   Fehlender Schlüsselzugang führt zum sichtbaren Warten/Fehler, nie zu einem
   unsicheren Ersatzpfad. Sensitive Ausgaben bleiben sensitiv und verschlüsselt.
8. **IPC und Validierung:** keine Deserialisierung ausführbarer Objekte;
   begrenztes JSON-/Binärprotokoll, Tiefe/Größe vor Allokation beschränken.
   Ein-/Ausgabe gegen fixierte Schemas prüfen; externe `$ref`-Auflösung sperren.
   Hostseitige Rechteprüfung unabhängig von Skriptbehauptungen durchführen.
9. **Wiederanlauf:** Skript darf vor Commit erneut laufen; reine Verarbeitung
   bevorzugen. Uhr/Zufall/Iteration/Versionen als explizite Eingaben binden,
   soweit Reproduzierbarkeit verlangt wird. Außenwirkungen nur im Broker
   reservieren, Fence/Idempotenz erhalten. Unklare Effekte nicht blind wiederholen.
10. **Debug:** stdout/stderr gelten als untrusted und potenziell sensibel;
    nicht ungeprüft übernehmen. Maskierung vor Persistenz, TTL 900 Sekunden,
    keine Secrets in Fehlertext/Stacktrace/Dateipfaden. Klartextanzeige nur über
    einen separat berechtigten und schlüsselgebundenen Datenzugriff.
11. **Mehrmandantenbetrieb:** kein gemeinsam veränderbarer Speicher, kein
    Pool-Reuse ohne nachgewiesene vollständige Bereinigung. Ressourcenquoten
    auch über parallele Aufrufe und Replikas; Missbrauch darf andere Mandanten
    nicht dauerhaft blockieren. API bleibt bei Sandboxausfall funktionsfähig.
12. **Lieferkette/Betrieb:** Runtime minimal, gepinnte Abhängigkeiten,
    Lizenzhinweise, reproduzierbarer Build, Update-/Sperrverfahren für unsichere
    Versionen, Health/Readiness und maskierte Betriebsmesswerte. Ein abgeschaltetes
    Profil verhindert neue Ausführung und verliert laufende Jobs nicht still.

## Abnahme und unabhängiger Review

Verbindliche Testfälle des Folgepakets, hier **nicht ausgeführt**:

- CPU-Endlosschleife, Rekursion, Speicherbombe, Prozess-/Ausgabeflut und IPC-
  Übergröße werden innerhalb der Grenzen beendet; Backend bleibt erreichbar.
- Hostdateien, Environment, Netzwerk/DNS/Metadaten und andere Mandantendaten sind
  unzugänglich. Pfad-/Symlink-/Protokollumgehungen und manipulierte Hostantworten
  werden als negative Fälle geprüft; keine echten Secrets als Testmaterial.
- Crash vor/nach Brokerannahme, Fencewechsel, verlorene Lease und doppelter
  Aufruf erzeugen keine unkontrollierte Außenwirkung; unklarer Zustand bleibt
  sichtbar. SMTP wird nicht als garantiert genau einmal behandelt.
- Skript-/Profilhashmanipulation, veraltete Runtime, fehlendes Modul, widerrufene
  Fähigkeit und inkompatible Schemas verhindern Ausführung vor Außenwirkung.
- Klartext hinterlässt nach Erfolg, Fehler, Timeout und Prozessabbruch keine
  persistierten Reste; Debugexport ist maskiert und nach 15 Minuten unzugänglich.
- Gleichzeitige synthetische Mandanten überschreiten weder Quoten noch Grenzen;
  Wiederanlauf nach Sandbox-/Workerneustart respektiert Rootbudget/Versionen.

Unabhängiges Sicherheitsreview und dokumentierter Nachweis der Isolation sind
Voraussetzung für Skriptfreigabe. Bis dahin verweigert die Veröffentlichung
Graphen mit Skriptknoten; der Editor darf sie ausschließlich als Entwurf speichern.
Offen zur Entscheidung: konkrete Runtime/Sprache, Sandboxprofilformat, Quoten,
Broker-API, deterministische Fähigkeiten, OS-Isolation und Reviewverfahren.

## Vertragsrunde 3 — M07: Schema-, Regex-, Capability- und Profilrahmen (VORGESCHLAGEN)

Stand 28.10.2026. Zahlenwerte sind **Vorschläge ohne Nutzerbestätigung** (Nr. 21);
**Runtime, Sprache und Isolationstechnik bleiben ungewählt** und die bestehende
Veröffentlichungssperre für Skriptknoten bleibt bis zum unabhängigen
Isolationsnachweis unverändert.

**Schemaprofil `sandbox-schema-v1`** für Ein-/Ausgabeschemas von Skriptartefakten
und für Host/IPC-Validierung: JSON-Schema Draft 2020-12 nur mit `type`, `properties`,
`required`, `items`, `enum`, `const`, `minimum/maximum`, `minLength/maxLength`,
`minItems/maxItems`, `additionalProperties:false`, `pattern` (siehe Regex).
Verboten: externe `$ref`, `$dynamicRef`, `$anchor`-übergreifende Referenzen,
`patternProperties`, `unevaluated*`, `if/then/else` mit Muster, Formatassertions.
Quoten: Schemagröße ≤ 64 KiB, Tiefe ≤ 8, ≤ 256 Eigenschaften je Objekt,
`maxLength` ≤ 65 536, `maxItems` ≤ 1 024, Instanzgröße je IPC-Nachricht ≤ 1 MiB,
Instanztiefe ≤ 16. Prüfung beginnt vor Allokation (Längenpräfix) und bricht beim ersten
Überschreiten ab.

**Regex:** nur eine linear laufende Teilmenge (RE2-/Rust-`regex`-Klasse: keine
Rückreferenzen, kein Lookaround, keine rückverfolgenden Konstrukte), Musterlänge ≤ 256
Byte, ≤ 16 Wiederholungsoperatoren, Eingabelänge durch `maxLength` begrenzt, harte
Wanduhrgrenze je Prüfung. Die in `common.schema.json` verwendete
explizite ASCII-Klasse für Geheimfeldnamen liegt in dieser Teilmenge. Muster
außerhalb der Teilmenge werden beim Import/Veröffentlichen abgelehnt, nicht
übersetzt. (Das trennt sich bewusst vom PCRE-Dialekt der Altformulare; für
Altmuster siehe `../ingest/legacy-validation-v1.md`.)

**Capability-/Broker-Vertrag (Entwurf):** IPC-Nachrichten `{v:1, kind:"call"|"result"|
"error"|"cancel", callId, capability, args}` mit begrenztem JSON (keine Funktionen/
Handles). Capabilityliste je Aufruf: `log.emit` (maskiert, Größenlimit), `time.now`
(als gebundene Eingabe bevorzugt), `random.bytes` (gebunden), `field.read`
(nur explizit erlaubte Eingabefelder), `effect.request` (Broker reserviert Effekt mit
Zielalias; nie direkter Netzwerkzugriff). Jede Capability trägt Kunde, Formular,
Release, Lauf, Besuch, Fence, Restbudget und Ablauf; der Host prüft Zugehörigkeit und
Rechte unabhängig vom Skript. Unbekannte Capability = Abbruch.

**Runtimeprofil (Felder, kein Wert gewählt):** `profileId`, `profileVersion`,
`artifactSha256`, `runtimeSha256`, `limits{cpuMs, wallMs, memoryBytes, processes,
descriptors, outputBytes, traceBytes}`, `capabilities[]`, `network:"none"`,
`filesystem:"ephemeral"|"none"`. Profil und Artefakt sind veröffentlichungs- und
ausführungszeitlich per Hash fixiert.

**Offen für P6-S (Entscheidungen/Nachweise):** konkrete Runtime/Sprache, OS-
Isolation, endgültige Zahlenwerte, Brokerprotokollbestätigung und das unabhängige
Review. Hier keine Prüfung ausgeführt.
