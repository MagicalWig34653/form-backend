# Legacy-Validierung `legacy-validation-v1` (M02)

Stand 28.10.2026. SPDX-License-Identifier: AGPL-3.0-only. **VORGESCHLAGEN**
(Vertragsrunde 3); Belegquelle nur gelesen: `providers/FeldSchema.php:63–260`
im Altprojekt. Keine Altcodeausführung, keine PHP-Referenzläufe in dieser Runde.

## Zweck und Abgrenzung

`form_versions.legacy_adapter_ref` verweist auf ein unveränderliches Dokument
dieses Formats (Schema [legacy-validation.schema.json](legacy-validation.schema.json)).
Es ist **Daten, kein ausführbarer PHP-Import**. Die Auswahl (`validation_profile`) ist
durch ADR 0004 Nr. 7 entschieden; hier ist die fachliche Semantik definiert.
Reihenfolge der Technikfelder und Signatur: `README.md` (Nachtrag M02/M03/H01).

## Definitionsdokument

`adapterVersion="legacy-validation-v1"`, `fields[]` mit `name`, `type`
(`text|datei|email|datum|zahl|bool|auswahl`), `required`, `rule` (Objekt mit
den Alt-Schlüsseln `minLaenge`, `maxLaenge`, `muster`, `mussSein`, `optionen`),
optional `specialHandler` (Bezeichner, siehe unten) und `configurationErrors`
(Namen von Feldern, deren Regel-JSON im Altbestand unlesbar war; Altverhalten:
Regel leer, Feld wird weiter geprüft). Das Dokument wird beim Import aus den
Altzeilen erzeugt; `rule` bleibt der verbatim decodierte Altwert (keine
Typkorrektur, kein Hinzufügen).

## Semantik pro Feld (aus dem Altcode, verbindlich für den Adapter)

Eingabe ist die PHP-geparste POST-Struktur (Werte sind Strings oder verschachtelte
Arrays, nie null/int).

1. Feld **fehlt** (`!isset`): bei `required` → fehlend, sonst weiter ohne Prüfung.
   Ein Wert, der als leerer String vorhanden ist, zählt als **vorhanden**
   (Pflicht erfüllt), wird aber von allen weiteren Prüfungen übersprungen.
2. Typ prüft (nur wenn Wert ≠ `""`): `text`, `datei` → immer gültig;
   `email` → String und `filter_var(FILTER_VALIDATE_EMAIL)`; `datum` → String und
   `new DateTimeImmutable($wert)` wirft nicht; `zahl` → `is_numeric` (auch auf
   Arrays: false); `bool` → Wert strikt in `["true","false","1","0","on","off",""]`;
   `auswahl` → ohne `optionen` jeder Wert, sonst strikt (`in_array` strict) in
   `optionen`, wobei ein Array-Wert nie gültig ist.
3. Regeln (nur wenn Typ gültig): `minLaenge`/`maxLaenge` (nur wenn int) zählen
   `mb_strlen` in Zeichen und sind für Nicht-Strings ungültig; `muster` (nur wenn
   String) per `preg_match(...)===1`, Nicht-String ungültig; `mussSein` strikt
   `===` mit dem JSON-Wert der Regel.
4. Ergebnis `fehlend[]`, `ungueltig[]`, gültig nur wenn beide leer. Fehlerbild
   und Statuscodes bleiben die des Altvertrags (`README.md`).
5. `muster`, das beim Import nicht kompilierbar war, wird entfernt und das Feld in
   `configurationErrors` geführt (Altverhalten).
6. Es gibt **keine Ablehnung unbekannter Felder** und keine Mehrdateiannahme; eine
   Datei (erstes `datei`-Feld) wie bisher. Eine Typkonvertierung findet nicht
   statt; Normalisierung von Bool für Folgeschritte ist Sache des Flows, nicht
   dieses Adapters.

**Regex-Dialekt (OFFEN, Importblocker):** `muster` ist ein PCRE-Ausdruck mit
Begrenzern und Flags des Altbestands. Der Zielstack muss entweder PCRE-kompatibel
sein oder jedes Altmuster gegen einen Korpus synthetisch gleichwertig prüfen; ein
nicht abbildbares Muster blockiert den Import dieses Formulars, es wird nicht
still entfernt oder umgeschrieben.

## Spezialhandler

`specialHandler` ist ein fester, im Code registrierter Bezeichner (kein Skript):
`bewerbung-v1` (Bewerbungshandler): Zustimmung ungleich String `true` → 418;
Proxyzweigfehler → 424. **BESCHLOSSEN ADR 0005 D6:** Das Altverhalten gilt
verbindlich weiter; die Statuscodes 418 und 424 bleiben, ein Ersatz ist nicht
beschlossen (siehe `legacy-adapter.md`). Weitere Handler müssen vor Import einzeln mit Belegstelle und
Fixture ergänzt werden; ein nicht bekannter Handler blockiert den Import.
**Scannerfehler (BESCHLOSSEN ADR 0005 D6):** Nur ein Treffer führt zu 451; ein
Scannerfehler/-ausfall lässt die Annahme durch (Status `nicht_geprueft`) und führt
**nie** zu 503. Eine Verschärfung ist unbeschlossen und nicht Teil dieses Vertrags.
Die Datei darf bei Scannerfehler nicht als geprüft markiert werden; der Scanstatus
muss im Betrieb sichtbar sein. Prüfkriterium: Fixture je Handler und Fehlerpriorität
(Zustimmung 418 vor Proxyzweig 424; Scannerfehler beeinflusst keinen der Codes).

## Synthetische Paritätsfixtures

[legacy-validation-fixtures.json](legacy-validation-fixtures.json). Fälle mit
`expected` ableitbar aus der Beschreibung oben sind verbindlich; Fälle mit
`"expected": "php-reference-required"` brauchen vor Freigabe einen Lauf gegen eine
PHP-Referenz (is_numeric, FILTER_VALIDATE_EMAIL, DateTimeImmutable, PCRE). Keine
Fixture enthält echte Daten.
