# ADR 0026 — Lokale Suche, Auskunft und Klartextexport

Stand: 03.11.2026. Bestätigter Nutzerauftrag FA-061/068/073–075.

## Entscheidung

Die Formularansicht bietet eine eigene lokale Such-/Auskunftssektion im neuen
PWA-Stil. Der Browser liest Metadatenseiten und die vorhandene Chiffratroute,
öffnet mit dem automatisch entsperrten Keyring (ADR 0024) und durchsucht rekursiv
Feldnamen/-werte, Unicode-normalisiert und ohne Beachtung der Großschreibung.
Zeiträume beziehen sich einschließlich beider Tagesgrenzen auf UTC. Die Suche
umfasst ein Formular, alle Seiten, ohne Klartextanfrage oder Browserpersistenz.
Personenbezug wird nicht serverseitig indexiert.

Nicht entschlüsselbare Kandidaten bleiben ausdrücklich ungeklärte Ergebnisse.
Sie lassen sich als Marker exportieren, jedoch nicht über die Personentreffer-
Löschaktion entfernen. Transport-/Rechtefehler brechen den gesamten Suchlauf ab;
sie sind keine Entschlüsselungsmarker. Ausgewählte sichtbare Ergebnisse werden
als JSON (strukturierte Felder) oder CSV (Metadaten plus Feldspalten, verschachtelte
Werte als JSON) heruntergeladen. Alle CSV-Zellen sind RFC-4180-quotiert; gefährliche
Formelanfänge einschließlich vorangestellter Leer-/Steuerzeichen erhalten ein
Apostroph. CSV beginnt mit UTF-8-BOM und verwendet CRLF. Anhänge sind nicht Teil
dieses Datenexports. Kein Kopieren des Alt-UI oder seiner Implementierung.

`GET .../entries/local-access` verlangt frische menschliche Sitzung,
`content.read` und `content.decrypt` und liefert Live-Hinweise für Export/Löschen.
Jeder Chiffratabruf prüft dieselben Rechte. Vor Download verlangt die PWA
`POST .../export/audit` mit leerem JSON-Objekt, Cookie/CSRF/Origin, frischer Sitzung
und erneuter Live-Prüfung aller drei Rechte read/decrypt/export in der Audit-
Transaktion. Erst nach Erfolg wird die Datei erzeugt. Auditaktion
`content.export.local`, Subjekt Formular, keine Suchbegriffe, Zeitfilter,
Treffer-IDs oder Personen-/Feldwerte. Das Ereignis belegt die Downloadfreigabe,
nicht den Empfang einer Datei durch den Nutzer. Der bestehende Chiffratexport
und dessen Audit bleiben serverseitig erhalten (ADR 0012).

Gezielte Löschung verwendet den bestehenden Stapelvertrag (höchstens 100 je
Request), frischen Login, Live-Recht `content.delete`, Grund `request`, Hold-
Schutz und wertfreien Nachweis. Keine neue Löschgrund-Freitextspeicherung.
Gemischte/pending Ergebnisse bleiben sichtbar; kein automatischer Retry.
Sperren/Logout/Ansichtsende entwerten laufende Arbeit, entfernen lokale Treffer
und verhindern verspäteten Download. Rohpuffer werden nach Verwendung gelöscht;
JavaScript-Strings können nur dereferenziert, nicht garantiert überschrieben werden.

## Folgen und Grenzen

Kein neues Schema und keine neue Einstellung: deshalb keine Upgrade-Datei,
Splitter-Zähleränderung oder alternative Registry neben ADR 0021. Laufzeit und
Speicher skalieren mit den im Zeitraum lesbaren Einsendungen. Der seitenweise
Leselauf ist kein DB-Snapshot; parallele Eingänge/Änderungen erfordern erneute
Suche. Bei veränderter Zeitspanne erneut suchen. Ein gelöschter Cursor oder ein
Rechteverlust bricht ab. Schon lokal freigegebener Klartext ist nach Rechteentzug
nicht rückrufbar. Formularübergreifende Sammelsuche und Anhangexport sind keine
Bestandteile dieses Pakets. Browser-/DB-Abnahme und unabhängiges Review bleiben
separat nachzuweisen; Prüfstand im Handoff.

## Erstquellen (nur lesend geprüft)

- `docs/paritaet/featureliste-alt.md`: FA-061/068/073/074/075.
- Altbestand `providers/AnfrageVerlauf.php:241`,
  `providers/DataSubjectRights.php:120`, `www/src/krypto/export.js:123,198,316`.
- ADR 0012, 0021, 0024 und `docs/ux/konzept.md` (Einsendungen/Export,
  Datenzugang, Sie-Ansprache, Barrierefreiheit, keine Klartextpersistenz).
