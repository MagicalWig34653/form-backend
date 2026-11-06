# Vollständige Migration und Kompatibilität

## Ziel und Inventar

Vollständige, überprüfbare Übernahme aller relevanten Bestandsdaten und Funktionen. Der Baseline-Dump allein genügt nicht; sämtliche SQL-Migrationen und der tatsächliche Quell-/Zielschemastand sind zu berücksichtigen. Produktionsdaten wurden in dieser Planung nicht gelesen.

Inventarisieren: Formulare/UUIDs, Feldschemata, individuelle Handlerlogik, Domains/Betriebsarten, Empfänger/Vorlagen/Transportkonfiguration, Anfragen, Anhänge/Mailpakete, Retention/Löschschutz, Statistiken, Fehler/Audits, Benutzer/Rollen/Zuständigkeiten, Einstellungen, Schlüsselgenerationen/-hüllen/-zugänge/Recovery, offene Zustellungen/Webhooks und MCP/OAuth-Konfiguration.

## Vorgehen — Vorschlag

1. Funktionsmatrix Alt → neuer Dienst/Adapter → Migrationsregel → Abnahmetest erstellen.
2. Quellversion und angewandte Migrationen prüfen; nur ausdrücklich freigegebene Quelle lesen.
3. Wiederholbaren Import mit Quellkennungen, Prüflauf, Fortschritt und Fehlerbericht bauen.
4. Zuerst Definitionen/Konten/Zugänge, dann referenzierte Inhalte und Historie übernehmen; Abhängigkeiten dokumentieren.
5. Verschlüsselte Pakete und Schlüsselhüllen möglichst bytegleich übertragen. Entschlüsselbarkeit in einer berechtigten Testumgebung nachweisen. Keine private Passphrase in CLI-Argumenten, Logs oder Agentkontext.
6. Synthetische Referenzfälle und anonymisierte Strukturfixtures für Parität prüfen: Statuscodes, Signaturen, Canonicalisierung, Pflichtfelder, Anhänge, Mailausgaben und Idempotenz.
7. Probelauf mit Mengen-, Referenz-, Hash-/Stichproben- und Statistikvergleich; Abweichungen erklären.
8. Umschaltung bevorzugt mit kurzer Schreibpause, finalem Delta und eindeutigem Übergangspunkt; Parallelbetrieb/Dual Write nur bei begründetem Bedarf.
9. Rückfallfenster und Verhalten neuer Daten nach Umschaltung definieren. Ein simples Zurückschalten stellt neue Daten im Altsystem nicht her.

## Besondere Grenzen

v1/v2 bleiben als Adapter zum gemeinsamen Kern möglich; konkrete URL-/Header-/Fehlervertragsparität prüfen. Neue API als eigenes Modul. UUIDs oder belastbare Zuordnung erhalten, damit Kundenseiten nicht alle gleichzeitig geändert werden müssen.

Passkeys hängen an RP-ID/Origin. Bei geändertem Adminhost kann Neuregistrierung nötig sein. Übernahme bestehender Credentials und PRF-Schlüsselhüllen separat erproben. Passworthashverfahren, MFA-Geheimnisverschlüsselung und Tokenformate auf Swift-Kompatibilität prüfen. Sitzungen und kurzlebige OAuth-Codes dürfen bei geplantem Cutover bewusst ungültig werden, aber nicht still als vollständig migriert gelten.

Aktuelle Browseransichten unterstützen nicht automatisch alle alten CBC/:1-Pakete. Altformatlesbarkeit oder vorgelagerter Bestandsumstieg muss ausdrücklich entschieden werden. Bestandsmigration und neue Verschlüsselungsprofile nicht unbeabsichtigt vermischen.

Produktive Migration, Schlüsselrotation, Löschung und Cutover sind nicht durch das Anlegen dieses Gerüsts beauftragt.
