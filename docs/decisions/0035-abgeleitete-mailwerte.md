# ADR 0035: Abgeleitete Werte in Mailvorlagen

Status: angenommen (Parität FA-029 bis FA-031, ersetzt die drei Spezialhandler des Altsystems)

## Entscheidung

`form.mail.derived` definiert bis zu 20 benannte Werte, die beim Rendern aus den im Speicher gehaltenen Feldern berechnet werden und in Betreff, Text und HTML wie Felder (`#=[name]=#`) verfügbar sind. Keine Skriptsprache, nur feste Regeln:

| `op`            | Parameter                                     | Wirkung                                                  |
| --------------- | --------------------------------------------- | -------------------------------------------------------- |
| `join`          | `fields`, `separator` (Standard Leerzeichen)  | nicht leere Werte verbinden (z. B. Vorname + Nachname)   |
| `firstNonEmpty` | `fields`                                      | erster nicht leerer Wert (alternative Behandlungsfelder) |
| `date`          | `field`, `format`                             | `yyyy-MM-dd` nach `format` (z. B. `dd.MM.yyyy`)          |
| `now`           | `format`, `timeZone` (Standard Europe/Berlin) | Zeitpunkt der Mail (Eingang bzw. Wiederholung)           |

Namen dürfen kein Formularfeld überdecken, Felder müssen existieren, unbekannte Regeln und Zeitzonen sind ungültig (Veröffentlichung scheitert). Fehlende Eingaben ergeben einen leeren Text, nie einen Fehler.

## Abgrenzung

Pflicht-Einwilligung (z. B. `data_agreement`) wird über Pflichtfeld bzw. festen Wert (`fixedValue`) im Feldschema abgebildet (ADR 0034). Dateiempfang der Terminformulare läuft über die vorhandene Upload-Pipeline. Der Konverter (ADR 0025) erzeugt `derived` nicht automatisch; es wird in der Prüfung des Entwurfs ergänzt. Eine PWA-Oberfläche für `derived` fehlt noch (Dokument-/JSON-Ebene).
