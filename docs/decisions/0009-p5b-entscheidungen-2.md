# ADR 0009: P5-B2 Entscheidungen (31.10.2026)

Nutzerentscheidungen zu `docs/handoffs/P5-B-vertrag-offen.md`:

- **F2** Neues Formular: Das Backend erzeugt beim Anlegen selbst einen Standard-Entwurf (eine Standardansicht, leerer Ablauf `entry`→`end`, Speicherung in der Datenbank). Veröffentlichung mit menschlicher Bestätigung, danach ist das Formular aktiv. Heutiger Nutzerablauf bleibt: Formular anlegen, SDK und Formular-UUID kopieren, öffentliche IP des Webservers eintragen (Domain/Access-Bindung, `domain.manage`); neu ist nur der Bestätigungsschritt.
- **F3** Der Flow-Vertrag wird um `security.specialCategories` (Pflicht-Boolean) ergänzt; bis dahin synthetischer Platzhalter `false` mit Vermerk "kein Produktionsrelease". `max_upload_bytes` vs. `storage.maxSubmissionBytes`: Semantik im Vertrag klären.
- **F8** Die erste erfolgreiche Veröffentlichung (`publishRelease`) setzt `forms.active=1` in derselben Transaktion; die Folge wird in der Bestätigung angezeigt.
- **G1** `getForm` liefert eine eigene Projektion (id, name, active, currentReleaseId, Revision); der Vertrag wird angepasst (bisher `Reference` mit vorläufiger Bedeutung).
- **F4** Argon2id jetzt (umgesetzt, siehe `docs/handoffs/P5-B1.md`).
- **Remote/CI** Privates GitHub-Repo `MagicalWig34653/form-backend`; GitHub Actions für Tests und Docker-Images (linux/amd64 + linux/arm64).
- Aufbewahrung abgelaufener Sitzungen/Challenges: 7 Tage bestätigt.
