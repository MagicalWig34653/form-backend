# ADR 0041: Inhalt der Mail an das Team: Standard „mit allen Angaben“, Benachrichtigung nur als Wahl

Status: Entscheidung geändert durch Nutzer am 13.11.2026 (Review `request_changes` zu Karte 4287D708). Ursprünglich (12.11.2026) war die Benachrichtigung der Standard; das ist aufgehoben. Ergänzt ADR 0010.

## Anlass

ADR 0010 erlaubt Mails mit Inhalt (Nutzerentscheidung 31.10.2026: „können“). Der erste Entwurf dieses ADR machte aus Datensparsamkeit (Art. 9 DSGVO) die reine Benachrichtigung mit Link zum Standard. Der Nutzer hat das am 13.11.2026 verworfen:

> „Das Praxisteam hat keinen Zugriff zum Backend. Es MUSS alles in der Mail stehen. Außerdem ist das eine Veränderung im Vergleich zu dem alten PHP Backend.“

## Entscheidung

- `form.mail.organisation.content`: `full` (Standard) oder `notification`. Fehlt das Feld, gilt `full`; das gilt auch für bereits veröffentlichte Releases (der Server wertet beim Versand aus, nicht beim Veröffentlichen) und für importierte Formulare (`LegacyFormConverter` übernimmt `mailBody` mit Platzhaltern ohne `content`).
- `full`: Die Mail an das Team enthält alle Angaben der Einsendung.
  - Mit Vorlage (Betreff, Text oder HTML-Builder aus ADR 0039): die Vorlage wird mit Platzhaltern gerendert, wie im Altbackend (`providers/formulare/generisch.php`, `mailBody`).
  - Ohne Vorlage (neues Formular, Import ohne Text) scheitert nichts: ein leerer oder fehlender Betreff wird zu „Neue Einsendung: <Formularname>“, ein leerer oder fehlender Text zu einer Standard-Feldliste (reiner Text): Formular, Zeitpunkt (Europe/Berlin, Eingang der Einsendung), Kennung, dann je Feld eine Zeile `Beschriftung: Wert` in der Reihenfolge der Feld-IDs (numerisch sortiert). Fehlende Werte erscheinen als leere Zeile, Zeilenumbrüche in Werten bleiben erhalten. Betreff und Text fallen einzeln zurück. Das Altbackend kannte keine Standardvorlage (der Text kam stets aus der Formularkonfiguration); die Liste ist die kleinste Lösung, die „alle Felder“ garantiert.
  - `Reply-To` aus `replyToField` wie bisher; ein `replyToField` auf ein gelöschtes Feld ist in `full` ein Fehler beim Speichern (unverändert).
- `notification`: nur durch ausdrückliche Wahl je Formular. Die Mail enthält Formularname, Zeitpunkt, Kennung und einen Link `<FORM_ADMIN_ORIGIN>/t/<kunde>/f/<formular>/entries`, keine Feldwerte, keinen Vorlagentext, kein `Reply-To`. Eine ausgeblendete Vorlage bleibt gespeichert und darf unvollständig sein.
- Keine zusätzliche Warnung und kein zusätzlicher Audit-Eintrag: der Audit-Eintrag `release.mail-fulltext` und der Warnhinweis im Mail-Reiter (Art. 9) entfallen; auch die bewusste Wahl von `notification` erzeugt keinen Hinweis oder Eintrag, nur die Wahl selbst im Mail-Reiter.
- Die Vorlage der Organisationsmail ist in beiden Modi optional (Typ, Größe und Steuerzeichen im Betreff werden weiter geprüft). Die Bestätigungsmail an die einsendende Person bleibt unverändert (Vorlage Pflicht).
- PWA (Mail-Reiter): Auswahl „Inhalt der Mail an das Team“ mit „Mit allen Angaben“ (Standard) und „Nur Benachrichtigung mit Link“. Betreff, Format, Inhalt/Builder und „Antwort an“ nur bei „Mit allen Angaben“; leerer Betreff/Text ist gültig (Standard-Feldliste). Mail-Builder (ADR 0039) und Vorschau unverändert.
- Manueller Wiederversand (`prepareResend`) und verzögerte Flow-Mails rendern denselben Modus neu.

## Folge für Altbestand und Import

Keine Änderung zum Altbackend: bereits konfigurierte, veröffentlichte und importierte Formulare senden weiter Mails mit allen Angaben. Die schon gesendeten Mails sind nicht betroffen (die Benachrichtigung war nur im ungemergten Branch). Wer für ein Formular die Benachrichtigung will, wählt sie im Mail-Reiter und veröffentlicht neu.

## Nicht Teil

- Feldauswahl je Mailvorlage; Anhänge (existieren in Mails noch nicht); Einzeleintrags-Deep-Link in der PWA.
- Reihenfolge der Standard-Feldliste nach Ansichts-Layout (die Liste folgt den Feld-IDs, nicht der Ansicht).
