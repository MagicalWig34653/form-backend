# ADR 0022: Listenerabhängiger Zweitfaktor (P11-G)

Datum: 03.11.2026. Status: beschlossen durch ausdrückliche Nutzerentscheidung.
Todolino: P11-G. Ergänzt ADR 0008/0009 und ADR 0020 sowie den Anmeldevertrag.

## Entscheidung

Intern genügt standardmäßig ein Passkey mit zwingender User Verification (UV,
Geräte-PIN/Biometrie). `FORM_INTERNAL_SECOND_FACTOR=1` erzwingt auch intern
Passkey plus Passwort; Default `0`, andere Werte sind Konfigurationsfehler.
Diese Sicherheits-/Listenerkonfiguration ist ENV-only und braucht einen Neustart.
Öffentlich gemountetes Dashboard (`FORM_PUBLIC_DASHBOARD=1`) verlangt immer
Passkey plus Passwort, unabhängig vom internen Schalter.

Die feste AuthConfig der registrierten Listener entscheidet serverseitig. Weder
Host, Origin, Forwarded-Header noch Client-IP schalten die Faktorpflicht um.
Der öffentliche AuthConfig-Modus kann den Zweitfaktor nicht abschalten. Die
Origin-/Host-/Trusted-Proxy-Prüfungen aus ADR 0020 bleiben zusätzlich bestehen.

## Sitzungen und frische Anmeldung

SessionService speichert SHA-256 über `form-session-v2|<listener>|` plus zufälliges
256-Bit-Token. Beide Listener verwenden feste getrennte Domänen (`internal`,
`public`). Das gilt für anonyme, faktorbegrenzte und authentifizierte Sitzungen;
auch kopierte Cookies und Challenge-Anfragen funktionieren nicht über Kreuz.
Das Cookie bleibt Secure/HttpOnly/SameSite=Lax mit __Host-Präfix. Bei derselben
Cookie-Authority überschreiben die Listener einander das Cookie; Neuanmeldung
ist dann erforderlich. Keine Schemaänderung; alte Sitzungshashes werden nicht
mehr erkannt, alle Nutzer müssen sich nach dem Upgrade neu anmelden.

Passkey allein erzeugt `auth_method=passkey`, keine vorgetäuschte zweite
Faktorzeit. Öffentlich wird erst nach Passwortprüfung authentifiziert. Beim
Sitzungszugriff wird zusätzlich geprüft, ob die aktuelle Policy den gespeicherten
Anmeldemodus erlaubt; Einschalten des internen Schalters sperrt bestehende
Passkey-only-Sitzungen. Rotation, atomarer Zählervergleich, Challenge-Verbrauch,
Lockout, Rate-Limits, CSRF, Rechteprüfungen und Ablaufzeiten bleiben erhalten.

Sensible Aktionen verlangen weiterhin eine höchstens fünf Minuten alte Anmeldung.
Die PWA beendet bei erforderlicher Wiederbestätigung die alte Sitzung und führt
den Login erneut aus: intern standardmäßig UV-Passkey, bei aktivem Zweitfaktor
Passkey plus Passwort. Enrollment/Ersatz-Link erzeugen weiterhin keine Anmeldung;
Einmalverbrauch, Befristung und Schutz des letzten Passkeys bleiben erhalten.

## Konten und Betrieb

Intern ohne Zweitfaktor ist das Passwort bei Kontoanlage optional; leerer Hash
bedeutet „kein Passwort“, nicht ein gültiges leeres Passwort. Auf einem Zugang mit
Zweitfaktor muss die Kontoanlage ein Passwort (12–256 Zeichen) angeben.
`bootstrap-admin` erzeugt nur bei öffentlichem Dashboard oder internem Zweitfaktor
ein Startpasswort, falls keine Passwortdatei angegeben ist. Ein explizites Passwort
kann auch intern gesetzt werden. Passkey-Registrierung bleibt der Einstieg.

Nach interner Anmeldung kann jedes Konto unter Konto sein Passwort setzen
(`PUT /me/password`, Session/CSRF/Origin/frische Anmeldung). Passwortänderung,
Widerruf anderer Sitzungen und Audit werden gemeinsam transaktional gespeichert.
Ein Konto ohne Passwort kann sich öffentlich nicht vollständig anmelden; vor
Aktivierung des öffentlichen Wegs muss intern oder beim Bootstrap eines gesetzt
werden. Das Setup zeigt dort den Hinweis auf das zusätzlich benötigte Passwort.
Die PWA leitet den Passwortschritt ausschließlich aus dem Serverzustand ab.

## Ausdrückliche Abschwächung und Gegenmaßnahmen

Der unabhängige Passwortschutz entfällt standardmäßig intern. Ein gestohlener
Passkey einschließlich nutzbarer UV (z. B. kompromittiertes/entsperrtes Gerät)
reicht dann zur Anmeldung. Ein kompromittiertes internes Netz bzw. ein falsch
öffentlich weitergeleiteter interner Port erhöht die Angriffsfläche; „intern“ ist
keine Garantie für vertrauenswürdige Nutzer oder Geräte. Die Nutzerentscheidung
akzeptiert dieses zusätzliche Risiko bewusst.

Gegenmaßnahmen: UV wird kryptografisch serverseitig geprüft, nicht bloß im Browser
angefordert; separate Listener und Sitzungsdomänen verhindern den Wechsel zur
öffentlichen Verwaltung; öffentlicher Zweitfaktor bleibt zwingend. Betreiber müssen
den internen Port mit Firewall/Netz-/Proxykonfiguration begrenzen und TLS verwenden.
Der interne Schalter erlaubt den stärkeren Schutz. Frische Anmeldung, Throttles,
Challenge-Replayschutz, CSRF und minimale Rechte begrenzen weitere Angriffe.
Sie ersetzen den entfallenen unabhängigen Faktor nicht.

## Abnahme

Tests und tatsächliche Prüfergebnisse samt verbleibender DB-/Browser-/Reviewabnahme
stehen in `docs/handoffs/P11-G.md`. Keine produktive Migration oder Veröffentlichung.
