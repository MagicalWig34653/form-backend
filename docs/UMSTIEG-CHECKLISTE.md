# Umstieg: Betriebsablauf-Checkliste (Altsystem nach form-backend)

Stand 11.11.2026. Grundlage: Generalprobe gegen das echte Altschema (`docs/handoffs/Import-Generalprobe.md`), ADR 0014, 0038, 0040. Der Import ist offline: Er liest einen eingefrorenen Stand der Alt-Datenbank und schreibt nur ins neue System. Das Altsystem wird nie verändert. Alle Zielobjekte sind nach dem Import inaktiv (Formulare `active=0`, Verbindungen `enabled=0`, Kunden `disabled`).

## 1. Voraussetzungen (vor dem ersten Lauf)

1. Neues System läuft, Setup abgeschlossen, Konto mit Recht `migration.run` (Systemrecht) und frischer Anmeldung (Passkey-Bestätigung auf der Seite).
2. Einstellung `migration.enabled = true` (Einstellungen, keine ENV).
3. **`migration.allowedNets`** (ENV `FORM_MIGRATION_ALLOWED_NETS` oder Einstellung): das Netz der Alt-Datenbank als CIDR, z. B. `10.45.0.0/24`. Standard ist leer und sperrt jede Quelle. Meldung bei Fehler: „Quelladresse nicht freigegeben oder nicht auflösbar“ (bewusst eine Meldung für beide Fälle). In Container-Netzen liegt die Datenbank oft in `10.0.0.0/8`, `172.16.0.0/12` oder `192.168.0.0/16`.
4. **Alt-Datenbank**: eingefrorener Stand (Dump in ein eigenes Schema restaurieren oder Replikat anhalten), kein laufender Schreibverkehr. Die Quelle liegt auf einem anderen Host oder in einem anderen Schema als das Ziel (der Importer verweigert identische Ziele).
5. **SQL-Rechte der Quelle**: eigener Benutzer nur mit `GRANT SELECT` (optional `SHOW VIEW`) auf das Quellschema, keine Rollen, kein `WITH GRANT OPTION`, keine globalen Rechte. Beispiel: `CREATE USER 'umstieg'@'<Netz>' IDENTIFIED BY '<Passwort>'; GRANT SELECT ON altschema.* TO 'umstieg'@'<Netz>';` Mehr Rechte weist die Quellprüfung ab („mehr als Leserechte“).
6. **TLS**: Die Quelle muss TLS anbieten (Modus „verify“). Bietet sie keines an, bricht die Prüfung ab, bevor Zugangsdaten gesendet werden. Nur für Wegwerf- und Loopback-Quellen gibt es „disable“, und nur wenn `FORM_ALLOW_INSECURE_DEV=1` gesetzt ist (wird protokolliert).
7. **`max_allowed_packet`**: Die Importer-Statements bleiben je Zelle unter 2 MB (Teilstücke zu 1 MB). Der Alt-Server muss selbst Zeilen bis zur größten Zeile liefern können (Altsystem erlaubt Uploads bis 20 MB, `max_allowed_packet` ≥ 32 MB laut Altdokumentation).
8. Die Zielformulare dürfen nicht aktiv sein und keinen Release haben (sonst „invalid_plan“). Frisches Ziel oder nur Formulare, die der Import selbst angelegt hat.
9. Altschlüssel: Der private Datenschlüssel (X25519, Base64url) und, falls vorhanden, der Recovery-Code liegen bereit. Sie werden **nicht** in den Import eingegeben, sondern nach dem Import im Browser übernommen (Konto, Sicherheit, Erweitert, „Altschlüssel aus dem Umstieg übernehmen“, ADR 0037/0038).

## 2. Reihenfolge

1. **Quelle prüfen** (Umstieg, Schritt 1). Prüfbericht lesen: Formulare, Mailverbindungen, Schlüssel mit Einsendungszahlen, Statistikzeilen.
2. **Zuordnung** (Schritt 2): nur den Kundennamen eintragen (oder vorhandenen Kunden wählen). Warnungen vor dem Start abarbeiten: Schlüssel, die Einsendungen verwenden, aber nicht im Altbestand stehen, brechen den Lauf ab. Statistikzeilen werden ohne öffentliche Statistik-Schlüssel nicht übernommen, sondern als Prüffälle gemeldet (Erweitert: `statisticsReview`, `statisticsPublicKeys`).
3. **Prüflauf** starten. Er läuft vollständig in einer zurückgerollten Transaktion; nichts bleibt im Ziel. Phasen: Quelle, Schlüssel, Verbindungen, Formulare, Felder, Anfragen, Idempotenz, Webhooks, Statistik. Bei Fehler zeigt die Seite die Ursache (Tabelle der Meldungen siehe unten); nach Behebung „Fortsetzen“ im selben Lauf.
4. **Import starten** (nach dem Prüfbericht). Pausieren ist an Objektgrenzen möglich; Abbruch, Neustart des Dienstes und Wiederholung setzen am Ledger fort und erzeugen keine Duplikate. Nach einem Neustart steht der Lauf auf „pausiert“ und wird nur mit „Fortsetzen“ weitergeführt.
5. **Prüfung** (Schritt 4): Bericht ansehen (offene Prüffälle: `unsupported-content` = Paket nicht übernehmbar, Dateiname/Fehlertext/Klartextanhang nur in der Quelle; `unmapped-table` = Tabellen ohne Abbildung wie Benutzer und Konfiguration; `migration-review` = einzelne nicht übernommene Zeilen), Entschlüsselungsprobe mit dem Altschlüssel lokal im Browser, Testnachricht, Entwürfe der Formulare erzeugen.
6. **Altschlüssel übernehmen** (Konto, siehe Voraussetzung 9). Erst danach sind importierte Einsendungen im normalen Betrieb lesbar.
7. **Delta** bei Bedarf: neuer eingefrorener Stand gleicher Struktur, neuer Snapshot-Hash. Bestehende Objekte werden gegen das Ledger geprüft, nur Neues wird angelegt.
8. **Umschalten** außerhalb der Oberfläche (SDK, DNS), danach Quelle entfernen („Quelle entfernen“ löscht die abgelegten Zugangsdaten; nach einem echten Import nur mit bestätigter Probe und Testnachricht).

## 3. Meldungen und Ursachen

| Meldung / Code | Ursache | Maßnahme |
|---|---|---|
| Quelladresse nicht freigegeben oder nicht auflösbar | `migration.allowedNets` leer oder Netz fehlt; oder Hostname unbekannt | Netz eintragen, IP statt Name testen |
| Die Quelle ist nicht erreichbar | Adresse/Port falsch, Firewall | Netz/Port prüfen |
| Anmeldung an der Quelle abgelehnt | Benutzer/Passwort/Host-Muster des Benutzers | `'user'@'<Netz>'` prüfen |
| Die Quelldatenbank existiert nicht … | Schemaname falsch oder kein Recht | Name/Rechte prüfen |
| mehr als Leserechte | Benutzer hat INSERT/UPDATE/… | Rechte auf SELECT beschränken |
| Die Quelle bietet kein TLS an | Quellserver ohne TLS | TLS aktivieren |
| Es läuft bereits eine Quellprüfung (429) | höchstens eine Prüfung je Konto, zwei insgesamt | kurz warten |
| `unknownKeyGeneration@kid` | Einsendung verwendet einen Schlüssel, der nicht im Plan/Altbestand steht | Warnung in der Zuordnung beachten; fehlenden Schlüssel in der Quelle ergänzen oder die Zeile klären, Prüflauf wiederholen |
| `conflict` | Ziel enthält abweichende Daten zu dieser Quelle (z. B. geänderter Plan nach Teilimport) | Plan nicht ändern; Delta nur mit neuem Snapshot-Hash |
| `invalid_plan` | Plan passt nicht (Kunde/Formular fehlt, aktive Formulare im Ziel) | Zuordnung prüfen |
| `database` | Zielseite: Datenbankfehler | Server-Log (nur Fehlertyp, keine Werte) |

## 4. Rollback

- **Prüflauf**: nichts zu tun, alles zurückgerollt.
- **Vor der Umschaltung** (Import abgeschlossen, nichts aktiv): Das Altsystem läuft unverändert weiter. Das neue System bleibt inaktiv. Wiederholen oder Delta genügen; ein Löschen von Zielobjekten ist nicht vorgesehen. Soll der Import ganz verworfen werden, die Ziel-Datenbank aus der Sicherung vor dem Import wiederherstellen.
- **Sicherung**: Vor dem echten Import Datenbank des Ziels sichern (inkl. Geheimnistabellen und dem dauerhaften Importschlüssel `settings._migration.hmac`; ohne ihn lassen sich Ledger-Nachweise nicht prüfen).
- **Nach der Umschaltung**: DNS/SDK zurück auf das Altsystem; neue Einsendungen im neuen System bleiben dort und müssen bei Bedarf manuell nachgezogen werden.

## 5. Zeit und Ressourcen

Messwerte der Generalprobe stehen in `docs/handoffs/Import-Generalprobe.md`. Faustregel aus der Messung: Prüflauf und Import dauern je etwa gleich lang; der Job hält höchstens 2 Verbindungen des Ziel-Pools.
