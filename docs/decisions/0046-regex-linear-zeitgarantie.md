# ADR 0046: Feldmuster mit linearer Regex-Engine

14.11.2026. Status: umgesetzt (Agent), Review durch Lino steht aus. Todolino S2-03 (017C4F98). SPDX-License-Identifier: AGPL-3.0-only.

## Problem

Betreiber definieren pro Feld ein `pattern`/`muster`; öffentliche Einsendungen werden dagegen mit `NSRegularExpression` (ICU, Backtracking) geprüft. Ein Textfilter (`hasNestedQuantifier`) sollte gefährliche Muster abfangen, war aber umgehbar (`((a|aa))+`: die innere Klammer beendet das `[^)]*`). ICU bietet über Foundation kein Zeitlimit, ein Thread lässt sich nicht abbrechen; ein Zeitbudget wäre daher nur ein Wächter, der den blockierten Worker nicht frei bekommt.

## Entscheidung

- Eigene Engine `FormCore/LinearRegex.swift`: Parser für einen eingeschränkten Dialekt, Thompson-NFA, Simulation mit Zustandsmenge. Laufzeit O(Programmgröße x Eingabelänge), kein Backtracking, also kein ReDoS, unabhängig vom Muster.
- Dialekt: Literale, `.`, Klassen (`[a-z]`, `[^..]`, `\d \w \s` und Negationen), maskierte Satzzeichen, `\n \r \t`, Gruppen `( )`/`(?: )`, `|`, `* + ? {n} {n,} {n,m}` (max. 1000), `^`/`$`. Abgelehnt: Lookaround, Rückreferenzen, lazy/possessive/gestapelte Quantoren, Flags, `\b`, `\p{..}`, verschachtelte Klassen, Programm über 4000 Befehle, Klammertiefe über 20, Muster über 500 Byte. Eingabe über 2000 Byte passt nie.
- Zwei Stellen: (1) Speichern/Veröffentlichen (`DocumentValidator`): unzulässige Muster werden mit `/form/fields/<id>/validation/pattern` abgelehnt, damit der Betreiber es sofort sieht. (2) Auswertung (`SubmissionValidation`) nutzt dieselbe Engine; ein Muster außerhalb des Dialekts (Bestandsdaten) lehnt die Einsendung ab, statt zu rechnen (wie bisher bei unparsbaren Mustern).
- Verworfen: nur Zeitbudget (Thread nicht abbrechbar), Prozess-Isolation (Overhead), weiter Textfilter (nicht beweisbar).

## Grenzen

- Semantik weicht minimal von ICU ab: `\d`/`\w`/`\s` nach Unicode-Eigenschaften (nicht ICU-identisch an Randzeichen), `$` nur am echten Ende, keine Groß-/Kleinschreibungs-Flags. Bestehende Formulare mit Mustern außerhalb des Dialekts (z. B. `\p{L}`, `(?i)`) lehnen Einsendungen ab, bis das Muster angepasst ist; der Migrationskonverter erzeugt nur Zahlenmuster im Dialekt.
- Die Browser-Prüfung (HTML-`pattern`) ist unabhängig und nicht Sicherheitsgrenze.
