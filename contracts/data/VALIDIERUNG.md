# Prüfstand technische P2-Korrekturen

27.10.2026. SPDX-License-Identifier: AGPL-3.0-only.
Im gemeinsamen Checkout ausgeführt, keine Installation, keine Migration.
Beide Prozess-Exitcodes: **0**. Nachfolgend jeweils vollständige unveränderte
Standardausgabe, keine Standardfehlerausgabe.

`python3 contracts/flow/validate.py`

```text
12 Draft-2020-12-Schemas gültig; alle lokalen $ref aufgelöst.
21 Beispiele gültig; Referenz-/Hash-/Graph-/Zeitprüfungen erfolgreich.
46 Negativfälle wie erwartet abgelehnt. Keine Engine-/DB-/Sandbox-Integration geprüft.
```

`python3 contracts/auth/validate.py`

```text
OK: YAML ohne doppelte Schlüssel; 66 Operationen, 1132 Referenzvorkommen, 11 lokale Dokumente.
OK: Komponenten-Metaschemata, Rechte-/Scope-/Pfad-/CSRF-/Sitzungsdeklarationen; 37 gezielte Payloadfälle.
Grenze: kein vollständiger OpenAPI-Spezifikationsvalidator; keine Autorisierungs-, DB-, HTTP-, OAuth- oder WebAuthn-Laufzeittests.
```

Die Validatoren wurden um technische Regressionsfälle ergänzt: Ressourcen-ID-
und SQL-/Checkpointzuordnung, Generation aus Form entfernt, reservierter
Technikfeldname, ungerade Hexlänge, ASCII-Groß-/Kleinschreibung bei Secretfeldern,
Paketexportformat und Holdliste. Die Liste ist keine Laufzeitabnahme.
Kein SQL ausgeführt; MariaDB-FKs/CHECKs/Fluent, atomare Mehrreplikatransaktionen,
TOTP-/Challenge-/Publikationsrennen, externe TTL-Löschung, Kryptografie und
CEK-/Hold-Kreuztests bleiben ungeprüft. Kein Commit oder Deployment.

## Vertragsrunde 2 — ADR 0004 (27.10.2026)

Aktueller Prüfstand; ersetzt die Zahlen des vorigen Abschnitts. Beide Befehle
im Projektwurzelverzeichnis ausgeführt; keine Installation, kein Netzwerk.
Die Werkzeugausgabe enthält keinen Fehlertext.

`python3 contracts/flow/validate.py` — Exitcode **0**

```text
12 Draft-2020-12-Schemas gültig; alle lokalen $ref aufgelöst.
21 Beispiele gültig; Referenz-/Hash-/Graph-/Zeitprüfungen erfolgreich.
51 Negativfälle wie erwartet abgelehnt. Keine Engine-/DB-/Sandbox-Integration geprüft.
```

`python3 contracts/auth/validate.py` — Exitcode **0**

```text
OK: YAML ohne doppelte Schlüssel; 76 Operationen, 1863 Referenzvorkommen, 12 lokale Dokumente.
OK: Komponenten-Metaschemata, Rechte-/Scope-/Pfad-/CSRF-/Sitzungsdeklarationen; 66 gezielte Payloadfälle.
Grenze: kein vollständiger OpenAPI-Spezifikationsvalidator; keine Autorisierungs-, DB-, HTTP-, OAuth- oder WebAuthn-Laufzeittests.
```

Zusätzlicher einmaliger statischer DDL-Abgleich — Exitcode **0**:

```text
OK: statischer DDL-Abgleich: 66 Tabellen mit Besitzer, 102 FK-Ziele/Spalten vorhanden; 28 Rechte identisch zur OpenAPI.
Grenze: keine SQL-Ausführung; Index-/FK-Typ-/CHECK-Kompatibilität und Transaktionen nicht geprüft.
```

Auth prüft jetzt auch Ingest-YAML (doppelte Schlüssel, Komponenten-Metaschemata,
alle statischen Referenzen), Transporthüllenformen/Pflichtsignaturdeklaration,
418/424-Deklaration, Einzel-/Gruppenrechte einschließlich unbekannter Rechte,
Scopeformen, Originalnachweis-/Resume-DTOs und DDL-Katalog-/Legacyfristabgleich.
Flow prüft zusätzlich das gesperrte sym-v2-Profil, die verpflichtende menschliche
Fortsetzungsdeklaration, unbekannte Flowrechte und synthetischen Crashzustand.
Der Crashzustand ist zusätzlich zum unveränderten Manifest mit 21 Beispielen
im Prüfer erzeugt; die 51 beziehen sich ausschließlich auf Negativfälle.

Keine Autorisierungs-, DB-, Kryptografie-, Docker-, HTTP-, Replay-/Refresh-,
Mehrreplika-, Crash-/Swap-/Speicherhygiene- oder Migrationsintegration ausgeführt.
Insbesondere CEK-Originalbeweis/AEAD, Transportbytes, Gruppenwiderruf zwischen
Replikas, Headeradapter und Credentialkontinuität benötigen echte Folgeabnahme.
Kein vollständiger OpenAPI-Spezifikationsvalidator und keine Produktionsfreigabe.

Abschlussprüfung nach Ergänzung aller fünf HANDOFF-Änderungslisten: beide
Validatoren erneut mit genau den obigen Ausgaben und jeweils Exitcode 0.
Zusätzliche Dateiverweisprüfung, Exitcode 0:

```text
OK: 92 lokale Markdown-Dateiverweise vorhanden.
```


## Vertragsrunde 3 (28.10.2026)

Aufruf mit dem venv-Python (jsonschema, pyyaml). Exakte Ausgaben:

```text
$ python contracts/flow/validate.py
12 Draft-2020-12-Schemas gültig; alle lokalen $ref aufgelöst.
21 Beispiele gültig; Referenz-/Hash-/Graph-/Zeitprüfungen erfolgreich.
53 Negativfälle wie erwartet abgelehnt. Keine Engine-/DB-/Sandbox-Integration geprüft.
Exitcode: 0

$ python contracts/auth/validate.py
OK: YAML ohne doppelte Schlüssel; 83 Operationen, 1988 Referenzvorkommen, 12 lokale Dokumente.
OK: Komponenten-Metaschemata, Rechte-/Scope-/Pfad-/CSRF-/Sitzungsdeklarationen; 93 gezielte Payloadfälle.
Grenze: kein vollständiger OpenAPI-Spezifikationsvalidator; keine Autorisierungs-, DB-, HTTP-, OAuth- oder WebAuthn-Laufzeittests.
Exitcode: 0
```

Zusätzlich geprüft: resend-manifest.schema.json (Metaschema, Beispiel gültig, 5 Negativfälle), legacy-validation.schema.json mit Fixtures (Struktur; 14 Fälle gegen eine Python-Referenz der deterministischen Teilmenge, 3 Fälle php-reference-required). Nicht ausgeführt: SQL/MariaDB, PHP, Krypto, HTTP, Mehrreplika, Sandbox.
