# 0001 Grundentscheidungen P1 (Teil 1)

Datum: 26.10.2026. Status: **beschlossen durch den Nutzer** (Auswahl der jeweils empfohlenen Option in der Session vom 26.10.2026).

## Entscheidungen

| Nr. in OFFENE-ENTSCHEIDUNGEN | Entscheidung                                                                                                                                                                                                                                                          | Alternative (verworfen)                   |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| 2                            | Backend-Framework: Vapor mit Fluent. Targetstruktur und Mindestversionen noch offen.                                                                                                                                                                                  | Hummingbird                               |
| 3                            | Mandantenmodell: Kunde als Mandant, Formulare gehören einem Kunden; Rollen Admin, Betreuer, Kunde (Kunde mit eigener Sicht). Feine Berechtigungen (Konfiguration, Veröffentlichung, Inhalte, Debug) noch offen.                                                       | Altbestand Benutzer↔Formular ohne Mandant |
| 4 (Teil), 17                 | Altchiffrate (`KUBUS-AEAD:1`, CBC) und v1-Header-Schlüssel werden nur im Migrationswerkzeug gelesen und auf `:2` umgestellt; die Laufzeit schreibt und liest nur `:2`. Verschlüsselungsprofile, Schlüsselgranularität, Klartext für Retry und Recovery bleiben offen. | Dauerhaft alle Formate lesen              |
| 14 (Teil)                    | Code und Codekommentare englisch, Nutzertexte deutsch und lokalisierbar, Dokumentation deutsch. Repo-/Branchkonventionen offen.                                                                                                                                       | Alles deutsch                             |

## Folgen

- Das Migrationswerkzeug (P9) muss alle Altformate aus `docs/paritaet/D-krypto-protokolle.md` und `review-D.md` byte-genau lesen; Fixtures aus Altcode erzeugen, ohne echte Schlüssel.
- Voraussetzung: Altdaten müssen vor oder bei Cutover vollständig umstellbar sein; Ausnahmen (`datenschluesselUmstiegAusnahme`) brauchen eine Regel.
- Vapor/Fluent: Versionen und Sicherheitsvoraussetzungen vor Implementierung gegen die aktuelle Dokumentation prüfen (siehe REFERENZEN.md).

## Offen

Nr. 5–13, 15, 16, 18, 19 sowie die oben genannten Teilaspekte.
