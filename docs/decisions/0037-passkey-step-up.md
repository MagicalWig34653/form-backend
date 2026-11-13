# ADR 0037: Passkey-Step-up auf der Seite statt Neuanmeldung

Status: angenommen (Nutzerwunsch 11.11.2026: „Ich möchte mich nicht immer erneut anmelden müssen! Es soll einfach auf der jeweiligen Seite eine Passkeyabfrage kommen!“). Ändert ADR 0022 (Satz „PWA beendet die Sitzung …“) und ADR 0030 (Frische für alle Migrationsoperationen bzw. das Lesen der Einstellungen).

## Entscheidung

- `POST /admin/api/v1/auth/reauth/options` und `POST /admin/api/v1/auth/reauth/verify` erneuern die frische Authentifizierung (`sessions.authenticated_at`) der aufrufenden Sitzung mit einem UV-Passkey desselben Kontos. Umsetzung der Entwurfsoperationen `reauthenticatePasskeyOptions`/`reauthenticate` aus `contracts/auth/admin-api.openapi.yaml` mit den Abweichungen unten.
- Voraussetzungen: Sitzung `authenticated` mit Konto, kein Bearer, exakte Origin und `X-CSRF-Token`, Budgets `budget(login: true)`.
- Challenge: `auth_challenges.purpose = 'fresh-auth'`, `account_id` = Sitzungskonto, nur SHA-256 gespeichert, 120 s, neue Optionen widerrufen ältere offene Step-up-Challenges der Sitzung. `allowCredentials` enthält nur die Credential-IDs des eigenen Kontos.
- Verify: Challenge wird zuerst in eigener Transaktion verbraucht (Sitzung + Zweck + Konto + ID), auch wenn die Prüfung danach scheitert. Der Passkey muss dem Sitzungskonto gehören; fremde/unbekannte Credentials laufen über denselben Dummy-Prüfpfad und erhalten dieselbe Antwort `401 authentication_failed` wie jeder andere Fehler. UV ist Pflicht (AssertionVerifier), Zählerregel atomar wie beim Login.
- Erfolg setzt NUR `authenticated_at` dieser einen Sitzung (bedingt auf lebende, authentifizierte Sitzung desselben Kontos), schreibt Audit `auth.reauth` (Kategorie `auth`, `actor_kind=human`, Subjekt Sitzungs-ID, Details nur `{"method":"passkey"}`) in derselben Transaktion und antwortet `{status:"fresh", authenticatedAt, freshUntil}`. Kein neuer Token, keine Rotation, kein neues CSRF-Geheimnis, keine Änderung von Zustand, Methode oder Rechteversion.
- Drosselung: IP-Fehlerzähler wie Login (`passwordPerIP`) und zusätzlich je Konto+IP 5 Fehler/15 min mit Backoff und 15 min Sperre (Zeile „Bestätigungsfehlversuche“ in `anmeldung.md`). Erfolg löscht nur den Konto+IP-Zähler.
- Listener-Policy: Verlangt der Listener Passwort/Zweitfaktor (öffentliches Dashboard immer, intern mit `FORM_INTERNAL_SECOND_FACTOR=1`), lehnen beide Endpunkte mit `409 second_factor_required` ab. Ein Passkey allein darf nicht erneuern, was mit Passkey + Passwort entstanden ist; die PWA fällt dann auf den vollständigen Login zurück.
- Lesen ohne Frische: `GET /migration/jobs` (feste Allowlist, keine Zugangsdaten/Plannamen/Quellschlüssel) und `GET /settings` (sensible Einträge maskiert, `value: null`). Alle verändernden Migrations- und Einstellungsoperationen sowie `GET /migration/jobs/:jobId/probe` (migriertes Chiffrat, auditiert) verlangen weiter frische Authentifizierung.
- PWA: zentraler Dialog „Bestätigung erforderlich“ auf der aktuellen Seite; nach Erfolg wird der abgelehnte Aufruf genau einmal wiederholt. Gleichzeitige Anfragen teilen einen Vorgang. Nach Abbruch öffnet sich der Dialog erst nach der nächsten Nutzeraktion erneut (kein Dialog-Spam durch Polling). Kein Passkey-Support im Browser oder `409`/`404` vom Server: Rückfall auf `/login?next=…&reauth=1`.

## Abweichungen vom Entwurf

- Pfade `auth/reauth/{options,verify}` wie die umgesetzten Paare `passkey/…`, `passkeys/…`, `enrollment/…`.
- Kein Recht `account.manage`: Jede authentifizierte Person muss sich selbst bestätigen können, sonst wären alle frischepflichtigen Aktionen für Konten ohne dieses Recht gesperrt. Rechte werden weiterhin bei der eigentlichen Aktion geprüft.
- Antwort ist kein `SessionState`, da sich Sitzung, Token und CSRF nicht ändern.

## Gründe und Grenzen

- Keine Rotation: Step-up ändert weder Identität noch Rechte; Rotation würde den CSRF-Token und die Schlüsselbindung der PWA (`keyring.bind`) ohne Sicherheitsgewinn invalidieren. Ein gestohlener Sitzungscookie bleibt Cookie-Diebstahl; der Step-up verlangt zusätzlich einen UV-Passkey desselben Kontos.
- Das Frischefenster ist einstellbar (`auth.freshLoginMinutes`, Standard 30, 1–120; `SessionService.freshWindow()`, Rückfall 300 s). Nur Veröffentlichungsbestätigungen nutzen 300 s (`ReleaseRoutes.swift`). (Korrigiert nach Sicherheitsreview B4.)
- Bekannte Grenze (Review B5): Der Step-up ist nicht an die auslösende Aktion gebunden; der Dialog nennt keine Aktion.
- Publikationsbestätigungen (`publication_confirmations.authenticated_at`) bleiben unverändert an den Zeitpunkt ihrer Erzeugung gebunden.
