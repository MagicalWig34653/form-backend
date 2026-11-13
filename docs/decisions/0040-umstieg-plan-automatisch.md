# ADR 0040: Umstiegsplan automatisch aus der Quellprüfung

11.11.2026. Status: umgesetzt (Agent), Nutzerprüfung mit echter Quelle offen.
Todolino 1EA2CCBB-22BB-4E35-9956-69F083B72F9B. SPDX-License-Identifier: AGPL-3.0-only.

## Kontext

Beim echten Umstieg brach der Prüflauf in Phase `anfragen` mit `unknownKeyGeneration@kid` ab. Die
Ursache: Die PWA schickte `keyCustomers` und `keyGenerationNumbers` immer leer. Der Importer
(`FormMigration/Transform.swift`, Fall `datenschluessel`) legt eine Generation aber nur an, wenn
die kid genau einem Plan-Kunden und einer Nummer > 0 zugeordnet ist. Dazu kamen weitere Pflichtangaben,
die der Nutzer von Hand eintragen musste: Formular-UUIDs, Kunden-UUID, Namespace und Verbindungen
(als JSON). Nutzerwunsch: Alles, was sich aus den Quelldaten belegen lässt, soll automatisch gehen.

## Entscheidung

**Quellprüfung (POST /migration/test) additiv erweitert.** Bestehende Felder bleiben unverändert.
Neu sind diese reinen Metadaten (Vertrag in `contracts/auth/p5-implementiert.openapi.yaml`):

- `keys`: je `datenschluessel`-Zeile die kid, der Status (`aktiv`/`auslaufend`, sonst `andere`), `erstelltAm`
  (Unix-Sekunden) und `publicKeyValid` (32 Byte und keyID == kid, wie im Importer). Die Antwort enthält
  keine Public-Key-Bytes, keine Hüllen und keine Recovery-Daten.
- `keyUsage`: aus den ersten 30 Byte der Spalten `data`, `file1Enc`, `mailBody` und `mailBodyFiller`
  (Kopf `KUBUS-AEAD:2|kid|`) ermittelt. Je kid gibt es die Zahl der Einsendungen, `inKeyStore` (binärer
  Vergleich gegen `datenschluessel`) und die Formular-UUIDs. Gelesen wird per Keyset auf `ID`, mit
  harten Grenzen: 200 Schlüssel, 200000 Zeilen, 200 kids, 100 Formulare je kid und 20 s. Wird eine
  Grenze überschritten, steht `complete=false`, und die Zähler sind Mindestwerte. Es wird nichts
  hochgerechnet. Code: `FormMigration/KeyInventory.swift`.
- `forms` (Name aus `formulare.name`; Verbindungs-UUIDs aus `outgoingProductionServer`/`outgoingTestingServer`,
  nur wenn sie zu einer gelisteten Verbindung gehören) und `connections` (Art und Name). Zugangsdaten,
  Host und Proxy-URL bleiben in der Quelle. Namen werden getrimmt, ohne Steuerzeichen übernommen und
  auf 200 Zeichen begrenzt.

**PWA (Schritt „Zuordnung“) leitet den Plan ab** (`lib/admin/migrationFlow.ts`: `assignForms`,
`assignConnections`, `assignKeys`, `generationNumbers`, `buildPlan`, `mappingIssues`, `keyWarnings`):

- Formulare stammen bei jeder Prüfung aus der Quelle und erscheinen mit ihrem Namen. Gibt es nur einen
  Kunden, gehören ihm alle; bei mehreren Kunden gibt es je Formular eine Auswahl, vorbelegt mit dem
  ersten Kunden. Eine UUID-Eingabe ist nicht mehr nötig.
- Kunden-UUIDs werden neu erzeugt oder von einem gewählten vorhandenen Kunden übernommen. Den
  Kundennamen muss der Nutzer eintragen, weil das Altsystem keine Kunden führt (Altschema
  `db/schema.sql` und die Migrationen sind geprüft). Es wird kein Name vorgeschlagen.
- Der Namespace wird als `legacy-<Datenbankname>` vorgeschlagen (Host als Ersatz), mit den Zeichen
  `[A-Za-z0-9._-]` und höchstens 64 Zeichen. Er ist je Quelle stabil und bleibt änderbar. Bei
  Wiederholung muss er gleich bleiben (Delta gibt es nicht mehr, ADR 0043); danach steht er im gespeicherten Plan des Laufs.
- Schema-HMAC und Snapshot-Kennung werden bei jeder Prüfung neu gesetzt. Ändert der Nutzer danach die
  Verbindungsangaben, sperrt das den Start („erneute Quellprüfung“). Lehnt der Server mit 422 ab
  (Schema- oder Formularmenge geändert), nennt die Oberfläche diese wahrscheinliche Ursache.
- Mailverbindungen: Bei einem Kunden gehören sie diesem. Bei mehreren Kunden werden sie den Kunden
  zugeordnet, deren Formulare die Verbindung verwenden, sonst bleibt die Auswahl offen.
- Schlüssel: Übernehmbar sind nur Schlüssel mit Status aktiv oder auslaufend und gültigem Public Key.
  Bei einem Kunden werden sie diesem zugeordnet. Bei mehreren Kunden werden sie vorbelegt, wenn alle
  Formulare, deren Einsendungen die kid verwenden, demselben Kunden gehören und die Liste vollständig
  ist; sonst bleibt die Wahl offen mit Hinweis. Die Nummern sind je Kunde lückenlos: erst die
  auslaufenden, dann die aktive Generation, innerhalb der Gruppe nach `erstelltAm`, bei Gleichstand nach
  kid. Begründung: Die aktive Generation trägt die höchste Nummer, denn eine Rotation (`RotationRoutes`)
  vergibt `old.generation_no + 1`. Außerdem ist je Kunde höchstens eine aktive Generation erlaubt
  (`uq_customer_active_key`), was als Prüfpunkt `activeKeys` geprüft wird. Andere Status werden nicht
  zugeordnet und sind gekennzeichnet.
- Das JSON-Expertenfeld unter „Erweitert“ bleibt. Es wird je Eintrag über den automatischen Plan gelegt,
  und die Nutzerwerte gewinnen. Die Nummern folgen der zusammengeführten Kundenzuordnung.
- Am Ende des Schritts steht eine Zusammenfassung (Kunden, Formulare mit Namen, zugeordnete Verbindungen
  und Schlüssel, Namespace) mit der Liste offener Punkte. „Prüflauf starten“ wird erst aktiv, wenn
  nichts mehr fehlt.

## Importer bewusst unverändert

`store()` wirft `invalidSourceAt(stored_objects, kid, unknownKeyGeneration)`. `object()` gibt diesen
Fehler weiter, statt ihn als Prüffall zu fassen, und der ganze Lauf endet mit `failed`. Ein Umbau zu
„Einsendung bleibt `migration-review`, Lauf läuft weiter“ wurde erwogen und verworfen:

- ADR 0014 verlangt: „Zugeordnete öffentliche Schlüsselgeneration muss existieren“. Ein Planfehler (kid
  nicht zugeordnet) wäre sonst von einem Quelldefekt nicht mehr zu unterscheiden.
- Im Prüflauf zählt jede `anfragen`-Zeile ohnehin als Review. Fehlende Generationen würden den
  Trockenlauf deshalb unauffällig grün aussehen lassen.

Deshalb warnt die Oberfläche vor dem Start deutlich und mit Zählern. Sie nennt, wie viele Einsendungen
eine kid ohne Altbestand, eine nicht übernehmbare kid oder die kid eines fremden Kunden verwenden, und
dass der Lauf an der ersten solchen Einsendung abbricht. Gelöst werden müssen solche Fälle im Altsystem
oder über eine eigene Vertragsentscheidung, etwa zur Archivierung nicht lesbarer Pakete.

## Restrisiken und Grenzen

- `keyUsage` erkennt nur den Paketkopf. Ein Paket mit gültigem Kopf, aber defektem Rumpf bricht nicht
  ab (der Importer macht es zum Review), wird hier aber mitgezählt. Die Warnung ist dann zu streng,
  nie zu mild.
- Ist ein vorhandener Zielkunde gewählt, der schon Generationen hat, können die Nummern 1..n mit
  bestehenden kollidieren (`uq_customer_generation`). Der Assistent kennt die Zielnummern nicht; die
  Korrektur geht über das JSON-Feld.
- Die Snapshot-Kennung ist eine Ableitung aus Schema-HMAC, Bestand und Formularen, kein Dump-Hash. Das
  war schon vorher so; für einen echten Dump-SHA256 bleibt das Feld unter „Erweitert“.
- Alle Tests laufen mit synthetischen Daten; eine echte Quelle ist nicht geprüft.
