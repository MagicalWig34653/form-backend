# ADR 0026: Konten, öffentlicher TOTP-Zugang und Secret-Rotation

03.11.2026. Status: Umsetzung gemäß Nutzerauftrag Paket Konten; DB-/Browserabnahme und unabhängiger Sicherheitsreview offen. Ergänzt ADR 0022 (Listener) und ADR 0021 (Registry).

## Entscheidung und Begründung

Intern bleibt UV-Passkey allein beziehungsweise die bestehende interne Passwortpflicht bestehen. Nur der fest konfigurierte öffentliche Listener erlaubt alternativ Passwort + TOTP oder nach Passkey TOTP statt Passwort. Clientheader schalten diesen Weg nicht frei. Die PWA zeigt ihn ausschließlich nach `totpAllowed` aus der Sitzungsauskunft. TOTP ersetzt keine Browser-PRF-Entsperrung; die bestehende Daten-Recovery bleibt erforderlich, wenn kein PRF vorliegt.

TOTP gemäß [RFC 6238](https://www.rfc-editor.org/rfc/rfc6238.html): SHA-1-HMAC, 6 Ziffern, 30 Sekunden, benachbarte Schritte ±1. Ein konsumierter oder älterer Schritt wird nie nochmals angenommen, auch nicht parallel oder nach Sitzungswechsel. Einrichtungsbestätigung konsumiert ihren Schritt ebenfalls. Öffentliche Anmeldung direkt danach benötigt den nächsten Code. Die Einrichtung erzeugt serverseitig 20 Zufallsbytes und gibt den Base32-Schlüssel einmalig im Response aus; nach 600 Sekunden verfällt der noch unbestätigte Vorschlag. Ohne gültige Codebestätigung entsteht kein aktiver Faktor. Entfernen verlangt frische Anmeldung und das tatsächliche Kontopasswort. Konten ohne Passwort setzen dieses vorher über die vorhandene frische Passkey-Anmeldung.

`account_totp` hält ausschließlich SecretStore-Referenzen und Sperr-/Replayzustand. Kontenzeile und TOTP-Zeile werden transaktional gesperrt. Fünf Fehlversuche ergeben kontoweit 900 Sekunden Sperre; Sitzungs-/IP-Wechsel setzt nichts zurück. Fehlerantwort erst nach Commit des Zählers; Sperrantwort verlängert die Sperre nicht. Nach Ablauf beginnt der Zähler neu. Login-/Passwort-/Entfernungsversuche haben zusätzlich die vorhandenen persistenten Throttles. Sicherheitswerte sind feste Vertragswerte, keine neuen konfigurierbaren Einstellungen und keine neue ENV. Künftige Konfiguration muss die Registry aus ADR 0021 nutzen.

SecretStore verschlüsselt unverändert AES-256-GCM mit Referenz-AAD und separater HKDF-Domäne. `reencrypt(from:)` verschlüsselt alle verwalteten Secrets atomar unter dem neuen Provider, behält Referenzen bei und erhöht `key_version`. Nicht lesbare oder manipulierte Einträge brechen die gesamte Transaktion ab. Diese Wartungsfunktion ist bewusst keine HTTP-Schlüsselausgabe: beide Provider bleiben ausschließlich im Betriebsspeicher. Alle Instanzen vor Rotation anhalten; alte Schlüsselquelle bis erfolgreicher Prüfung behalten, neue anschließend gemeinsam aktivieren. CSRF/Sitzungen und Throttle-HMACs nutzen ebenfalls den Serverkey: Sitzungen nach Wechsel erneuern; Throttleüberführung separat planen. Kein automatischer Schlüsselwechsel, keine produktive Migration und kein Altchiffratimport in diesem Paket.

Kontostatus und MCP-Freigabe verlangen live `identity.manage` auf Systemscope, Cookie/Origin/CSRF und frische Anmeldung. Eine Transaktion sperrt alle Kontenzeilen in ID-Reihenfolge, prüft effektive Systemadministratorrechte einschließlich Gruppen und schützt den letzten aktiven Systemadministrator (ein Ersatz muss Systemverwaltung, Kontenverwaltung und einen hinterlegten Passkey besitzen) sowie die letzte handlungsfähige Schlüsselidentität je Kunde. Sperren widerruft sämtliche Sitzungen, MCP-Tokens und OAuth-Grants. Entsperren reaktiviert keine widerrufenen Zugänge. MCP-Sperren widerruft Tokens/Grants dauerhaft, normale Sitzungen bleiben nutzbar. Passwortwechsel entzieht zusätzlich zu anderen Sitzungen auch MCP-Tokens und OAuth-Grants. Bestehende Token-/OAuth-Auflösung prüft Aktivität und MCP-Erlaubnis weiter live.

Audit enthält ausschließlich IDs und feste Aktionscodes, keine Namen, Passwörter, Codes, Secrets oder Eingabewerte. Neue Loginmethoden erhalten echte zweite Faktorzeiten; der Sessionguard lässt sie nur öffentlich zu. Sitzungsrotation prüft Kontoaktivität unter Zeilensperre erneut, damit eine konkurrierende Kontosperre keine neue Sitzung hinterlassen kann.

## Migration und Abnahme

Baseline `backend/db/schema-p3.sql` und separat `backend/db/upgrades/0026-account-totp.sql`; keine Änderung bestehender Baselineprüfsummen. Bestehende ungenutzte `accounts.mfa_secret_ref` wird nicht als aktiviertes TOTP interpretiert. Alt-TOTP erfordert eine getrennte geprüfte Importentscheidung; neue Einrichtung ist vollständig unterstützt. Testumfang und tatsächliche Ergebnisse: `docs/handoffs/Konten.md`.

## Audit-Nachtrag 03.11.2026: laufende Anmeldung beim Passwortwechsel

Todolino-Task: `8B72B9D6-1FAE-4B18-AA1D-0876B1EE7D5D`.
Offener Befund `needs_validation` (behoben 04.11.2026: Hash und Aktivstatus werden nach der TOTP-Prüfung erneut gelesen, bei Änderung keine Sitzung):
`FormAuth/AuthRoutes.swift` liest und prüft beim öffentlichen Passwort+TOTP-Login
den Passwort-Hash vor `SessionService.rotate`. `FormAdmin/AccountRoutes.swift`
ändert das Passwort und widerruft zugeordnete Sitzungen in einer Transaktion.
Die anonyme Vorgängersitzung eines laufenden Passwort+TOTP-Logins hat jedoch noch
keine Kontozuordnung. Erfolgt der Passwortwechsel nach dem Lesen des alten Hashes
und vor der Rotation, kann die Anmeldung nach dem Wechsel mit dem bereits
geprüften alten Passwort abgeschlossen werden. `rotate` sperrt die Kontenzeile
und prüft Aktivität und TOTP-Einrichtung, aber weder Passwortstand noch eine
Authentifizierungsgeneration. Der Vorgänger-CAS schützt diese anonyme Sitzung
nicht vor einem kontobezogenen Widerruf.

Gemäß Auftrag hier nur dokumentiert: Eine belastbare Korrektur betrifft den
Vertrag zwischen Passwortprüfung, zweitem Faktor und Rotation (z. B. erwartete
Passwort-/Authentifizierungsgeneration unter derselben Kontosperre prüfen).
Nicht bloß eine erneute Prüfung außerhalb der Transaktion ergänzen. Vor Schließung
mit deterministisch angehaltenem Passwortverifier beide Reihenfolgen gegen
MariaDB testen: Wechsel gewinnt → alte Anmeldung verworfen; Anmeldung gewinnt →
Wechsel widerruft die entstandene Sitzung. Internen Passwort-Zweitfaktor und
Passkey+TOTP ebenfalls auf Widerrufsverhalten prüfen. Keine Schemaänderung oder
Änderung dieses Nebenläufigkeitsverhaltens im Auditfix.

TOTP-Benutzername wird im Auditfix vor Datenbankabfrage und Sperrschlüsselbildung
mit `whitespacesAndNewlines` getrimmt; keine zusätzliche Kleinschreibung eingeführt.
