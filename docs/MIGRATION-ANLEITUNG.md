# So migrierst du vom Altsystem

Kurzanleitung für den Umstieg vom alten PHP-Formularbackend auf form-backend, Schritt für Schritt. Sie folgt genau dem Weg, den der
Betreiber-Echtlauf `backend/e2e-operator.sh` mit dem veröffentlichten Image prüft (Protokoll: `docs/handoffs/Betreiberweg-Protokoll.md`).
Details und alle Fehlermeldungen: `docs/UMSTIEG-CHECKLISTE.md`, Betrieb: `docs/BETRIEB.md`.

Geprüftes Image: siehe `docs/handoffs/Betreiberweg-Protokoll.md` (Abschnitt „Endlauf“, Digest). Verwende genau dieses Image oder ein neueres.

## Was du vorher wissen musst

- Das Altsystem wird **nicht verändert**. Der Import liest nur. Bis zur Umschaltung läuft das Altsystem weiter.
- Ab dem Prüflauf bis zur Umschaltung darf das Altsystem **keine neuen Einsendungen** annehmen (Schreibpause). Sonst bricht der Import
  mit „Die Altdaten wurden seit dem Prüflauf verändert“ ab. Plane ein ruhiges Zeitfenster (der Import deiner Daten dauert Sekunden bis Minuten).
- Deine alten Einsendungen sind im Altformat `:1` (CBC) verschlüsselt. Sie werden **nicht** lesbar übernommen (Entscheidung ADR 0001). Sie
  bleiben im Neusystem als „Prüfung“ stehen und im Altsystem bzw. im Dump erhalten. Lesbar übernommen werden nur `:2`-Einsendungen; davon hat
  dein Altbestand keine.
- Den alten privaten Datenschlüssel brauchst du deshalb für den Umstieg nicht.

## 1. Neues System installieren (einmalig)

```bash
git clone --branch deploy --single-branch https://github.com/magicalwig34653/form-backend.git
cd form-backend
sudo deploy/compose/setup.sh --dry-run
sudo deploy/compose/setup.sh --db-password-file /geschuetzt/db_password
```

Das Setup fragt Adresse (HTTPS), Passkey-Domain, Datenbank (Host, Benutzer, TLS) und Image ab, legt den Server-Schlüssel an, führt
`migrate` aus und startet den Dienst. **Sichere sofort** `deploy/compose/secrets/server_key` an einem zweiten Ort. Ohne ihn sind
gespeicherte Zugangsdaten (z. B. SMTP-Passwörter) nach einer Wiederherstellung nicht lesbar.

Zwei Netze musst du freigeben (`sudo deploy/compose/settings.sh --set KEY=WERT`, danach `sudo deploy/compose/update.sh`):

```bash
sudo deploy/compose/settings.sh --set FORM_MIGRATION_ALLOWED_NETS=10.45.0.0/24   # Netz der Alt-Datenbank
sudo deploy/compose/settings.sh --set FORM_MAIL_ALLOWED_NETS=10.45.0.0/24        # nur nötig, wenn dein SMTP-Server im privaten Netz liegt
sudo deploy/compose/update.sh
```

Ersten Administrator anlegen und Passkey einrichten:

```bash
sudo deploy/compose/admin.sh bootstrap-admin admin
```

Den ausgegebenen Link im Browser öffnen, Passkey erstellen, anmelden, den **Wiederherstellungscode** sichern (er wird nur einmal gezeigt).

**Du siehst:** die Seite „Einrichtung“ mit den Schritten.

## 2. Alt-Datenbank bereitstellen

Lege einen eigenen Lesebenutzer an (nur `SELECT`), zum Beispiel auf der Alt-Datenbank:

```sql
CREATE USER 'umstieg'@'10.45.0.%' IDENTIFIED BY '<starkes Passwort>';
GRANT SELECT ON altschema.* TO 'umstieg'@'10.45.0.%';
```

Die Verbindung zur Quelle ist immer TLS-geprüft. **Bietet deine Alt-Datenbank kein TLS an** (Meldung „Die Quelle bietet kein TLS an“), nimm
den einfachsten Weg: Spiele den Dump in ein **eigenes Schema auf der Datenbank des neuen Systems** ein. Diese spricht schon TLS mit einem
Zertifikat, dem das neue System vertraut.

```bash
mariadb --ssl --ssl-verify-server-cert -h <db-host> -u root -p -e 'CREATE DATABASE `kubus_alt` CHARACTER SET utf8mb4'
mariadb --ssl --ssl-verify-server-cert -h <db-host> -u root -p kubus_alt < legacy-dump.sql
mariadb --ssl --ssl-verify-server-cert -h <db-host> -u root -p -e "CREATE USER 'umstieg'@'%' IDENTIFIED BY '<Passwort>' REQUIRE SSL; GRANT SELECT ON \`kubus_alt\`.* TO 'umstieg'@'%'"
```

Dann ist die Quelle derselbe Host wie `FORM_DB_HOST`, und `FORM_MIGRATION_ALLOWED_NETS` muss dessen Netz enthalten. Ein Dump ist von selbst
in Schreibpause (er ändert sich nicht).

## 3. Umstieg im Browser

Menü **Umstieg**:

1. **Quelle prüfen:** Host, Port, Datenbank, Benutzer, Passwort, TLS-Modus `verify` lassen. „Verbindung prüfen“.
   **Du siehst:** „Nur lesender Zugang geprüft“ und den Prüfbericht (bei dir: 3 Formulare, 4 Mailverbindungen, 0 Schlüssel, 794 Statistikzeilen).
2. **Zuordnung:** nur den Kundennamen eintragen. **Du siehst:** „Der Plan ist vollständig.“ Der Hinweis zu den Statistikzeilen ist normal:
   ohne Statistikschlüssel werden sie nicht übernommen (Prüffall), der Rest läuft.
3. **Prüflauf starten.** **Du siehst:** „Der Prüflauf ist abgeschlossen.“ Ab jetzt keine Änderungen mehr am Altsystem.
4. **Import starten.** **Du siehst:** den Schritt „Prüfung“ mit dem Prüfbericht.
5. **Prüfung:** Bei deinen Daten steht dort „Keine :2-Einsendungen importiert: Die Entschlüsselungsprobe entfällt“ und „10 Einsendungen im
   Altformat (:1/CBC) sind nicht übernehmbar und bleiben in der Prüfung“. Das ist erwartet. Die Entwürfe der Formulare sind schon erzeugt.

**Kontrolle (optional, auf der Ziel-Datenbank):** gleiche Anzahl Formulare (3) und Einsendungen (10) wie im Altsystem.

## 4. Kunde, Schlüssel, Mailverbindungen, Formulare

1. **Datenschlüssel anlegen:** Seite neu laden, entsperre mit dem Passkey, **Konto → Erweitert → „Datenschlüssel im Browser erzeugen“** beim importierten Kunden
   (ohne Altschlüssel entsteht der Schlüssel nicht von selbst). **Du siehst:** „Datenschlüssel erzeugt (Kennung …)“. Danach **Kunden** öffnen: der Kunde steht in der Liste.
2. **Verbindungen:** Deine alten SMTP-Server sind übernommen, aber **deaktiviert**. Je Verbindung „Testen“, dann im Menü der Zeile
   „Verbindung aktivieren“. **Du siehst:** „Die Verbindung ist aktiv …“. Server, bei denen im Altsystem „Eigene Zertifikate erlauben“ an war,
   tragen „Zertifikat wird nicht geprüft“.
3. **Formular** öffnen (Kunde → Formular):
   - Reiter **Mail:** Versandverbindung wählen, „Versandweg zuweisen“, Absender und Empfänger eintragen, „Speichern“. Die Empfänger kommen
     nicht automatisch aus dem Altsystem; trage sie ein, wie sie dort standen.
   - Reiter **Felder:** prüfen (die alten Feldnamen sind übernommen).
   - **Veröffentlichen:** „Ich habe die Änderungen geprüft.“ → „Jetzt veröffentlichen“.
   - **Einbindung:** „Zugangsdatei ausstellen“ und die Datei für das PHP-SDK auf der Website ablegen.

Eigene Feldmuster aus dem Altsystem werden nicht übernommen (Prüfbericht „nicht abbildbar“); im Editor neu gesetzte Muster müssen zum einfachen Regex-Dialekt passen (kein Lookaround, keine Rückreferenz, kein `(?i)`); `App migrate` meldet Abweichungen vor dem Umschalten.

## 5. Umschalten

1. Website auf das neue PHP-SDK umstellen (Zugangsdatei aus 4.3), Testeinsendung schicken.
   **Du siehst:** die Mail beim Team mit allen Angaben und die Einsendung unter Formular → „Einsendungen“.
2. Altsystem abschalten oder Formular dort deaktivieren.
3. **Umstieg → Umschaltung:** Häkchen „Ich habe verstanden: Ohne Probe wird der Altzugriff entfernt …“ setzen, „Altzugriff entfernen“.
   **Du siehst:** „Umstieg abgeschlossen“. Die Zugangsdaten zur Alt-Datenbank sind gelöscht.
4. Danach in den Einstellungen „Umstieg aktiv“ ausschalten.

## 6. Danach im Betrieb

- Nach dem Neuladen der Seite ist der Schlüssel gesperrt: Konto → „Erweitert“ → „Mit Passkey entsperren“. Geht der Passkey nicht, öffnet der
  **Wiederherstellungscode** (Konto → „Wiederherstellungscode“ → „Datenzugang öffnen“) denselben Zugang, auch zu importierten Einsendungen.
- Aufbewahrung: Einsendungen werden nach der am Formular eingestellten Frist automatisch gelöscht (stündlicher Lauf); die Frist steht unter Formular → Aufbewahrung.
- Wiederherstellen (Probe oder Ernstfall): `scripts/restore-db.sh <Backup> restore_<name>` legt eine NEUE Datenbank an. Der Restore-Benutzer braucht nur Rechte auf `restore_%`; Trigger-DEFINER werden dabei entfernt.
- Sicherung: `scripts/backup-db.sh` mit `FORM_BACKUP_AGE_RECIPIENTS_FILE` (verschlüsselt), siehe `docs/BETRIEB.md`. Den Server-Schlüssel
  getrennt sichern.
- Update: `sudo deploy/compose/update.sh` (führt `migrate` aus und startet neu; Daten bleiben).

## Wenn etwas schiefgeht

| Was du siehst | Was du tust |
|---|---|
| „Quelladresse nicht freigegeben oder nicht auflösbar“ | `FORM_MIGRATION_ALLOWED_NETS` um das Netz der Quelle ergänzen, `update.sh` |
| „Die Quelle bietet kein TLS an“ | Dump auf die Datenbank des neuen Systems einspielen (Abschnitt 2) |
| „Das Zertifikat der Quelle stammt von einer unbekannten Stelle“ | Quell-CA in den Vertrauensspeicher des Containers aufnehmen oder Abschnitt 2 |
| „Die Altdaten wurden seit dem Prüflauf verändert“ | Altsystem anhalten, „Prüflauf wiederholen“, dann Import |
| Dienst startet nicht, Log „admin API configuration failed: LoadError“ | Server-Schlüsseldatei fehlt, hat falsche Rechte (muss 0400/0600 sein und dem App-Benutzer gehören) oder ist kein 64-stelliger Hexwert |
| „Übernommene Verbindung nicht verwendbar (…)“ beim Aktivieren | Verbindung neu anlegen (z. B. Altserver ohne Verschlüsselung) |
| Import bricht ab oder der Dienst wurde mitten im Import neu gestartet | Lauf steht auf „pausiert“: „Fortsetzen“. Es entstehen keine Doppelten |

## Zurück (Rollback)

Grundsatz: Das Altsystem und sein Dump werden vom Import **nie verändert**. Du kannst jederzeit zurück.

- **Vor „Altzugriff entfernen“:** Nichts tun. Website zeigt weiter auf das Altsystem. Das Neusystem kann verworfen oder der Import wiederholt werden.
- **Neusystem auf den Stand vor dem Import zurücksetzen:** `scripts/restore-db.sh <Backup-Verzeichnis> restore_vorher` (Backup vorher mit `scripts/backup-db.sh`
  gemacht, am besten direkt vor dem Import), dann `FORM_DB_NAME=restore_vorher` setzen und `update.sh`. Der Server-Schlüssel muss derselbe sein.
- **Nach der Umschaltung:** DNS bzw. Website-Einbindung wieder auf das Altsystem (altes PHP-Skript) zurückstellen und das SDK entfernen. Einsendungen, die in der
  Zwischenzeit im Neusystem eingegangen sind, bleiben dort (Formular → Einsendungen oder Export) und müssen von Hand nachgezogen werden.
- Importierte Altdaten bleiben im Neusystem als „Prüfung“ stehen; ein Löschen ist nur über die Aufbewahrung oder den Kunden möglich.
