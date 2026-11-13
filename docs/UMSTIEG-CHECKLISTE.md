# Umstieg: Betriebsablauf-Checkliste (Altsystem nach form-backend)

Stand 13.11.2026 (Einmal-Snapshot, ADR 0043). Grundlage: Generalprobe gegen das echte Altschema (`docs/handoffs/Import-Generalprobe.md`), ADR 0014, 0038, 0040. Der Import ist offline: Er liest einen eingefrorenen Stand der Alt-Datenbank und schreibt nur ins neue System. Das Altsystem wird nie verändert. Es muss aber zwischen Prüflauf und Ende des Imports ruhen (Schreibpause): Der Code prüft das mit einem Quellen-Fingerabdruck (ADR 0043). Alle Zielobjekte sind nach dem Import inaktiv (Formulare `active=0`, Verbindungen `enabled=0`, Kunden `disabled`).

## 1. Voraussetzungen (vor dem ersten Lauf)

1. Neues System läuft, Setup abgeschlossen, Konto mit Recht `migration.run` (Systemrecht) und frischer Anmeldung (Passkey-Bestätigung auf der Seite).
2. Einstellung `migration.enabled = true` (Einstellungen, keine ENV).
3. **`migration.allowedNets`** (ENV `FORM_MIGRATION_ALLOWED_NETS` oder Einstellung): das Netz der Alt-Datenbank als CIDR, z. B. `10.45.0.0/24`. Standard ist leer und sperrt jede Quelle. Meldung bei Fehler: „Quelladresse nicht freigegeben oder nicht auflösbar“ (bewusst eine Meldung für beide Fälle). In Container-Netzen liegt die Datenbank oft in `10.0.0.0/8`, `172.16.0.0/12` oder `192.168.0.0/16`.
4. **Alt-Datenbank**: eingefrorener Stand (Dump in ein eigenes Schema restaurieren oder Replikat anhalten), kein laufender Schreibverkehr. Die Schreibpause beginnt vor dem Prüflauf und gilt bis zur Umschaltung; der Import bricht ab, wenn die Altdaten zwischen Prüflauf und Import (`source_changed`) oder während des Imports (`source_not_quiesced`) verändert wurden. Die Quelle liegt auf einem anderen Host oder in einem anderen Schema als das Ziel (der Importer verweigert identische Ziele).
5. **SQL-Rechte der Quelle**: eigener Benutzer nur mit `GRANT SELECT` (optional `SHOW VIEW`) auf das Quellschema, keine Rollen, kein `WITH GRANT OPTION`, keine globalen Rechte. Beispiel: `CREATE USER 'umstieg'@'<Netz>' IDENTIFIED BY '<Passwort>'; GRANT SELECT ON altschema.* TO 'umstieg'@'<Netz>';` Mehr Rechte weist die Quellprüfung ab („mehr als Leserechte“).
6. **TLS**: Die Quelle muss TLS anbieten (Modus „verify“). Bietet sie keines an, bricht die Prüfung ab, bevor Zugangsdaten gesendet werden. Nur für Wegwerf- und Loopback-Quellen gibt es „disable“, und nur wenn `FORM_ALLOW_INSECURE_DEV=1` gesetzt ist (wird protokolliert). „verify“ vertraut ausschließlich dem Zertifikatsspeicher des Betriebssystems, in dem der Dienst läuft (Linux: `/etc/ssl/certs/ca-certificates.crt`; es gibt kein Feld für eine eigene CA und `SSL_CERT_FILE` wirkt nicht). Stellt die Quelle ein Zertifikat einer privaten CA aus, muss diese CA im Image bzw. Host eingetragen sein. Zertifikatsfehler nennen ihre Ursache: „passt nicht zum Hostnamen“ (die eingetragene Adresse muss dem Namen oder der IP im Zertifikat entsprechen), „von einer unbekannten Stelle“ (private Quell-CA: in den Vertrauensspeicher des Images bzw. Hosts eintragen, z. B. `update-ca-certificates`; es gibt weder ein CA-Feld noch Pinning) und „abgelaufen“. Zur Unterscheidung von unbekannter CA und abgelaufen öffnet der Dienst eine zweite Verbindung, die nur die Fähigkeiten (SSLRequest) und nie Benutzername oder Passwort sendet. Bei Zweifeln zusätzlich `openssl s_client -connect <Host>:<Port> -starttls mysql -verify_hostname <Host>` von der Dienst-Umgebung aus. Echtlauf: `backend/e2e-migration-tls.sh`.
7. **`max_allowed_packet`**: Die Importer-Statements bleiben je Zelle unter 2 MB (Teilstücke zu 1 MB). Der Alt-Server muss selbst Zeilen bis zur größten Zeile liefern können (Altsystem erlaubt Uploads bis 20 MB, `max_allowed_packet` ≥ 32 MB laut Altdokumentation).
8. Die Zielformulare dürfen nicht aktiv sein und keinen Release haben (sonst `target_forms_live`, schon im Prüflauf, es wird nichts geschrieben). Frisches Ziel oder nur Formulare, die der Import selbst angelegt hat: **Import vor dem Live-Gang**. Ein Depublizieren gibt es im Produkt nicht (Pausieren setzt nur `active=0`, der Release bleibt und blockiert weiter); ist ein Formular schon veröffentlicht, hilft nur ein frisches Ziel oder die Wiederherstellung aus der Sicherung vor der Veröffentlichung. Die Formular-IDs stehen im Server-Log („migration job failed“, `targetFormsLive`), nie im Jobcode.
   Ein vorhandener Zielkunde muss denselben Namen tragen wie in der Zuordnung, sonst `customer_name_mismatch` (ebenfalls schon im Prüflauf, vor dem ersten Schreiben).
   Schlüsselübernahme (ADR 0037/0038): Gibt es im Ziel schon einen **aktiven** Schlüssel desselben Kunden, bricht der Lauf mit `key_conflict_active` ab. Der Altschlüssel kommt nur dazu, wenn der eigene Schlüssel des Zielkunden nicht aktiv ist (z. B. eigener Schlüssel erst nach dem Import anlegen oder vorher zurückbauen); die Rotation im Ziel danach ist Sache des Kunden.
9. Altschlüssel: Der private Datenschlüssel (X25519, Base64url) und, falls vorhanden, der Recovery-Code liegen bereit. Sie werden **nicht** in den Import eingegeben, sondern nach dem Import im Browser übernommen (Konto, Sicherheit, Erweitert, „Altschlüssel aus dem Umstieg übernehmen“, ADR 0037/0038).

## 2. Reihenfolge

1. **Quelle prüfen** (Umstieg, Schritt 1). Prüfbericht lesen: Formulare, Mailverbindungen, Schlüssel mit Einsendungszahlen, Statistikzeilen.
2. **Zuordnung** (Schritt 2): nur den Kundennamen eintragen (oder vorhandenen Kunden wählen). Warnungen vor dem Start abarbeiten: Schlüssel, die Einsendungen verwenden, aber nicht im Altbestand stehen, brechen den Lauf ab. Statistikzeilen werden ohne öffentliche Statistik-Schlüssel nicht übernommen, sondern als Prüffälle gemeldet (Erweitert: `statisticsReview`, `statisticsPublicKeys`).
3. **Prüflauf** starten (Altsystem schon in Schreibpause). Er speichert den Quellen-Fingerabdruck (nur ein Hash) im Bericht. Er läuft vollständig in einer zurückgerollten Transaktion; nichts bleibt im Ziel. Phasen: Quelle, Schlüssel, Verbindungen, Formulare, Felder, Anfragen, Idempotenz, Webhooks, Statistik. Bei Fehler zeigt die Seite die Ursache (Tabelle der Meldungen siehe unten); nach Behebung „Fortsetzen“ im selben Lauf. „Prüflauf wiederholen“ nimmt einen neuen Fingerabdruck desselben Plans.
4. **Import starten** (nach dem Prüfbericht; Altsystem weiter in Schreibpause). Der Import vergleicht den Fingerabdruck der Quelle mit dem des Prüflaufs, bevor er schreibt, und noch einmal nach dem letzten Objekt. Pausieren ist an Objektgrenzen möglich; Abbruch, Neustart des Dienstes und Wiederholung setzen am Ledger fort und erzeugen keine Duplikate. Nach einem Neustart steht der Lauf auf „pausiert“ und wird nur mit „Fortsetzen“ weitergeführt.
5. **Prüfung** (Schritt 4): Bericht ansehen (offene Prüffälle: `unsupported-content` = Paket nicht übernehmbar, Dateiname/Fehlertext/Klartextanhang nur in der Quelle; `unmapped-table` = Tabellen ohne Abbildung wie Benutzer und Konfiguration; `migration-review` = einzelne nicht übernommene Zeilen), Entschlüsselungsprobe mit dem Altschlüssel lokal im Browser, Testnachricht, Entwürfe der Formulare erzeugen.
6. **Altschlüssel übernehmen** (Konto, siehe Voraussetzung 9). Erst danach sind importierte Einsendungen im normalen Betrieb lesbar.
7. **Kein Delta.** Wurde das Altsystem nach dem Prüflauf beschrieben, steht der Lauf auf `source_changed` (nichts geschrieben): Schreibpause herstellen, „Prüflauf wiederholen“, Import. Ein zweiter Import mit anderem Snapshot-Hash auf demselben Namespace ist nicht vorgesehen (`snapshot_changed`); dann Ziel aus der Sicherung wiederherstellen und einmalig neu importieren.
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
| Das Zertifikat der Quelle passt nicht zum Hostnamen | Adresse nicht im Zertifikat (SAN), Audit `source_cert_hostname` | Adresse wie im Zertifikat eintragen |
| Das Zertifikat der Quelle stammt von einer unbekannten Stelle | CA nicht im Vertrauensspeicher des Dienstes, Audit `source_cert_untrusted` | Quell-CA in Image/Host eintragen (kein CA-Feld) |
| Das Zertifikat der Quelle ist abgelaufen | Gültigkeit überschritten, Audit `source_cert_expired` | Zertifikat an der Quelle erneuern |
| Quelle konnte nicht sicher geprüft werden | sonstiger, nicht zuordenbarer Fehler (Audit `source_failed`) | Verbindung mit `openssl s_client` prüfen |
| Es läuft bereits eine Quellprüfung (429) | höchstens eine Prüfung je Konto, zwei insgesamt | kurz warten |
| `unknownKeyGeneration@kid` | Einsendung verwendet einen Schlüssel, der nicht im Plan/Altbestand steht | Warnung in der Zuordnung beachten; fehlenden Schlüssel in der Quelle ergänzen oder die Zeile klären, Prüflauf wiederholen |
| `conflict` | Ziel enthält abweichende Daten zu dieser Quelle (z. B. geänderter Plan nach Teilimport, im Ziel veränderte importierte Zeilen) | Plan nicht ändern; sonst Ziel aus der Sicherung wiederherstellen |
| `source_changed` | Die Altdaten wurden seit dem Prüflauf verändert; nichts geschrieben | Altsystem in Schreibpause versetzen, „Prüflauf wiederholen“ (CLI: Prüflauf wiederholen, neuen Fingerabdruck übergeben) |
| `source_not_quiesced` | Das Altsystem wurde während des Imports beschrieben; Lauf und Job `failed` | Ziel aus der Sicherung wiederherstellen, Schreibpause herstellen, neu importieren |
| `snapshot_changed` | Für diesen Namespace gibt es schon einen Import mit anderem Snapshot (kein Delta) | Ziel aus der Sicherung wiederherstellen und einmalig neu importieren |
| `source_fingerprint_missing` (409 beim Import) | Job aus der Zeit vor dem Fingerabdruck | „Prüflauf wiederholen“ |
| `target_forms_live` | Im Ziel gibt es aktive/veröffentlichte Formulare (ADR 0014) | Import vor dem Live-Gang; frisches Ziel oder Wiederherstellung (kein Depublizieren im Produkt); IDs im Server-Log |
| `customer_name_mismatch` | Zielkunde heißt anders als im Plan | Namen in der Zuordnung an das Ziel anpassen |
| `invalid_plan` | Plan passt nicht (Kunde/Formular fehlt, widersprüchliche Zuordnung) | Zuordnung prüfen |
| `database` | Zielseite: Datenbankfehler | Server-Log (nur Fehlertyp, keine Werte) |
| Prüffall `statistics-review-missing` | Statistikzeilen im Altbestand, der Plan enthält keine Statistik-Freigabe (`statisticsReview`) | Die Zeilen werden nicht geschrieben (Altbestand bleibt); Freigabe im Plan setzen und neu aufrufen, oder Fall bewusst annehmen |
| Prüffall `statistics-key-unknown` | Der öffentliche Statistikschlüssel im Plan fehlt oder ist keine Schlüsselgeneration des Kunden | Die Zeilen werden nicht geschrieben, der übrige Import läuft weiter; Schlüssel der aktiven Altgeneration des Kunden eintragen und neu aufrufen |

### Kommandozeile `App migrate-legacy`: Exit-Codes und Meldungen

Meldungen stehen auf stderr (der Bericht als JSON auf stdout), nennen nur Parameter- und Feldnamen, nie Werte oder Geheimnisse.

| Exit | Bedeutung | Maßnahme |
|---|---|---|
| 0 | Abgeschlossen ohne offene Prüffälle (auch Prüflauf `--dry-run`) | keine |
| 1 | Fehler beim Import (z. B. `conflict`, `database`, `keyConflict`, `invalidSource`) | Meldung auswerten; erneuter Aufruf setzt fort |
| 2 | Parameter- oder Planfehler: `Parameter fehlt: <Name>`, `Parameter ungültig: <Name> (...)`, `Plan nicht lesbar: <Feldname>`, `migration: invalidPlan field=<Feld>` | Eingabe korrigieren; es wurde nichts geschrieben |
| 3 | Abgeschlossen mit N offenen Prüffällen („abgeschlossen mit N offenen Prüffällen“); der Lauf steht auf `failed`, die Daten sind übernommen, die Fälle bleiben im Altbestand | Prüffälle ansehen (Umstieg-Ansicht, Tabelle `migration_issues`), entscheiden, bei Bedarf Plan anpassen und erneut aufrufen. Skripte dürfen 3 nicht als Fehler des Prozesses werten, aber auch nicht als „fertig“ |
| 130 / 143 | SIGINT / SIGTERM: Stopp an der nächsten Objektgrenze, Sperre frei, kein Lauf bleibt auf `running` | Erneut aufrufen: setzt fort. Das Schema kennt keinen eigenen Zustand „pausiert“; ein gestoppter Lauf steht wie ein pausierter Web-Lauf auf `failed` |
| 137 (SIGKILL) o. Ä. | Prozess hart beendet (nicht abfangbar) | Lauf bleibt auf `running`, Sperre fällt mit der Verbindung weg; erneuter Aufruf setzt fort |

Schreibpause (ADR 0043): `--dry-run` gibt zusätzlich `source-fingerprint: <64 Hex>` aus (nur ein Hash). Der echte Lauf akzeptiert `--expect-source-fingerprint <hex>`: weicht die Quelle ab, Exit 1 mit `migration: sourceChanged` und dem Text „Die Altdaten wurden seit dem Prüflauf verändert …“, vor dem ersten Schreiben. Ohne die Option vergleicht der Lauf Start und Ende; Abweichung: Exit 1, `migration: sourceNotQuiesced`, Lauf `failed`. Ein anderer Dump-Hash auf bestehendem Namespace: Exit 1, `migration: snapshotChanged`.

Plan-Felder: Namespace, Dump-Hash, Kunden- und Formularzuordnung sind Pflicht. Fehlen `connectionCustomers`, `keyCustomers`, `keyGenerationNumbers`, `statisticsReview` oder `statisticsPublicKeys`, gelten die leeren Standardwerte (der kanonische Plan-JSON und damit die Lauf-Identität ändern sich dadurch nicht).

## 4. Rollback

- **Prüflauf**: nichts zu tun, alles zurückgerollt.
- **Vor der Umschaltung** (Import abgeschlossen, nichts aktiv): Das Altsystem läuft unverändert weiter. Das neue System bleibt inaktiv. Eine Wiederholung mit gleichem Snapshot genügt; ein Löschen von Zielobjekten ist nicht vorgesehen. Soll der Import ganz verworfen werden, die Ziel-Datenbank aus der Sicherung vor dem Import wiederherstellen.
- **Sicherung**: Vor dem echten Import Datenbank des Ziels sichern (inkl. Geheimnistabellen und dem dauerhaften Importschlüssel `settings._migration.hmac`; ohne ihn lassen sich Ledger-Nachweise nicht prüfen).
- **Nach der Umschaltung**: DNS/SDK zurück auf das Altsystem; neue Einsendungen im neuen System bleiben dort und müssen bei Bedarf manuell nachgezogen werden.

## 5. Zeit und Ressourcen

Messwerte der Generalprobe stehen in `docs/handoffs/Import-Generalprobe.md`. Faustregel aus der Messung: Prüflauf und Import dauern je etwa gleich lang; der Job hält höchstens 2 Verbindungen des Ziel-Pools.
