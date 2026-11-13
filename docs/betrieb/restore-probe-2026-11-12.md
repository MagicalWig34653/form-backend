# Restore-Probe 12.11.2026 (verschlüsselte Backups)

Synthetische Daten, Wegwerf-MariaDB `mariadb:12.3` (Container `form-backup-probe-db`, Port 23399, tmpfs, danach entfernt). Keine echten Daten, kein Produktionsserver.

## Befehl

```bash
scripts/test-backup-crypto.sh
```

Ablauf: Quell-DB `probe_src` (Tabelle `entries` mit 3 Zeilen inkl. Umlaut und NULL, Tabelle `leer`) -> `backup-db.sh` (gpg bzw. age, Pipe, kein Klartext auf Platte) -> `backup-offsite.sh` (rsync auf lokalen Pfad, Stub für rclone) -> `restore-db.sh` in `restore_*` -> Zeilenzahlvergleich (`counts.tsv`). Negativfälle: kein Empfänger, falscher Schlüssel, manipuliertes Chiffrat, Klartext-Backup, Prune.

## Ausgabe (wörtlich)

```
OK    Backup ohne Empfaenger bricht ab
OK    kein Klartext-Dump ohne Empfaenger
OK    laute Klartext-Warnung
OK    Restore verweigert Klartext ohne ALLOW_PLAINTEXT
OK    gpg: Backup
OK    gpg: nur Chiffrat im Verzeichnis
OK    gpg: kein Klartext im Chiffrat
OK    gpg: SHA256SUMS deckt Chiffrat
OK    gpg: Chiffrat 0600
OK    gpg: Restore
OK    gpg: Zeilenzahlen gleich (3)
OK    Server-Key-Stellvertreter: Chiffrat nach Restore mit demselben Key lesbar
OK    anderer Key kann Chiffrat nicht lesen
OK    gpg: falscher Schluessel schlaegt fehl
OK    gpg: falscher Schluessel legt keine DB an
OK    gpg: manipuliertes Chiffrat scheitert
OK    gpg: Abbruch an der Pruefsumme
OK    Offsite: rsync-Upload mit Verifikation
OK    Offsite: Chiffrat am Ziel
OK    Offsite: Trockenlauf
OK    Offsite: Klartext-Backup wird nicht uebertragen
OK    Offsite: ohne Ziel Abbruch
OK    Offsite: rclone copy + check (Stub)
OK    age: Backup
OK    age: nur Chiffrat
OK    age: Restore
OK    age: Zeilenzahlen gleich
OK    age: falscher Schluessel
OK    age: manipuliertes Chiffrat
OK    Prune: Trockenlauf
OK    Prune: Trockenlauf loescht nichts
OK    Prune: Lauf
OK    Prune: nur Altes mit Muster geloescht
OK    Prune: juengstes Backup bleibt immer
OK    Prune: Frist 0 abgelehnt
OK    Prune: ungueltige Frist abgelehnt

36 bestanden, 0 fehlgeschlagen
```

## Ergebnis

36 bestanden, 0 fehlgeschlagen; gpg 2.5.24 und age 1.3.2 vollständig lokal geprüft (Backup, Restore, Zeilenzahlen, falscher Schlüssel, manipuliertes Chiffrat). Ein falscher Schlüssel legt keine Datenbank an (Entschlüsselung wird vor `CREATE DATABASE` an den ersten Bytes geprobt). Vor der Implementierung schlug der Test rot fehl.

## Server-Key

Nachweis nur als Stellvertreter: Eine Spalte `secret_blob` enthält ein mit einer synthetischen Schlüsseldatei (openssl AES-256-CBC) erzeugtes Chiffrat. Nach dem Restore ist es mit derselben Schlüsseldatei lesbar, mit einem neu erzeugten Schlüssel nicht. Das belegt das Prinzip „denselben Key zur DB wiederherstellen“, **nicht** das echte Serverformat. Offen: Wiederherstellungsprobe mit der echten App, echtem Server-Key-Secret und echten Chiffraten (isolierte Umgebung, siehe BETRIEB.md).

## Nicht geprüft

rclone gegen ein echtes Ziel (nur Stub der Kommandozeilen), rsync über echtes ssh (lokaler Pfad geprüft), Offsite-Prune per rclone, TLS-DB, Restore auf separatem Server, passphrase-geschützte gpg-Schlüssel.
