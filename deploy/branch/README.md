# form-backend: Deploy-Branch

Betriebsdateien für **Docker Swarm oder Docker Compose**. Das fertige Image
`ghcr.io/magicalwig34653/form-backend` enthält Backend und PWA. MariaDB und TLS-Reverse-Proxy
werden **extern** bereitgestellt. Dieses Repository startet weder DB noch Proxy und baut
keine Images. Lizenz: [AGPL-3.0-only](LICENSE).

```bash
git clone --depth 1 --branch deploy https://github.com/MagicalWig34653/form-backend.git
cd form-backend
# Compose (ein Server):
sudo deploy/compose/setup.sh
sudo deploy/compose/admin.sh bootstrap-admin admin    # gibt den einmaligen Passkey-Einrichtungslink aus
# oder Swarm (Manager, vorher einmalig docker swarm init):
deploy/swarm/setup.sh
deploy/swarm/admin.sh bootstrap-admin admin
```

Mit `--dry-run` zeigt Setup vorab, was passieren würde. Schritt-für-Schritt-Anleitung:
<https://magicalwig34653.github.io/form-backend/einrichtung.html>

Setup fragt Origin, Passkey-RP-ID und die vorhandene DB-Verbindung ab. Das DB-Passwort kommt
aus verdeckter Eingabe oder `--db-password-file /geschuetzt/db_password`; Setup prüft mit
einem einmaligen MariaDB-Client `SELECT 1` in der gewählten Datenbank. Datenbank und Benutzer
müssen bereits existieren. TLS zur DB ist standardmäßig `verify`.

Alle App-Variablen, Infrastrukturparameter und Defaults stehen kommentiert in
`deploy/swarm/stack.env.example` bzw. `deploy/compose/.env.example`. Die echte Env-Datei
hat Modus 0600 und bleibt außerhalb von Git. Prozess-ENV überschreibt gespeicherte Werte.
Secret-Werte werden nicht darin gespeichert. **Server-Key separat verschlüsselt sichern.**
Einen bestehenden Key mit `--server-key-file DATEI` übernehmen.

Einstellungen ändern ohne die Datei von Hand zu bearbeiten: `deploy/swarm/settings.sh` bzw.
`deploy/compose/settings.sh` öffnet ein Menü (whiptail, Bash 4.4+) oder arbeitet per CLI:
`--list`, `--get KEY`, `--set KEY=VALUE`, `--unset KEY`, `--check`, `--env PFAD`. Werte werden
geprüft (Typ, Grenzen, Konflikte), atomar mit Modus 0600 gespeichert und vorher als
`<Datei>.bak.JJJJMMTT-HHMMSS` gesichert. Geheimnisse zeigt und schreibt das Skript nie. Ausgerollt
wird nichts, außer im Menü „Jetzt anwenden“ wird bestätigt (ruft `update.sh`).

Der externe Reverse Proxy terminiert TLS und leitet HTTP an Port **8080** weiter.
Compose bindet standardmäßig an `127.0.0.1`; Swarm kann Published Ports nicht an einzelne
Host-IP-Adressen binden und benötigt eine Firewall mit Zugriff ausschließlich vom Proxy.
`FORM_TRUSTED_PROXIES` auf die tatsächlichen Proxy-CIDRs begrenzen.

Vor Updates DB und Schlüssel sichern, Schema-Kompatibilität prüfen:

```bash
git pull --ff-only
deploy/swarm/update.sh --tag GEWUENSCHTE_COMMIT_SHA --dry-run
deploy/swarm/update.sh --tag GEWUENSCHTE_COMMIT_SHA
# Compose entsprechend:
sudo deploy/compose/update.sh --tag GEWUENSCHTE_COMMIT_SHA
```

Der Tag wird zu einem Digest aufgelöst: zuerst einmalige Migration, dann App-Rollout,
anschließend `/ready`. Compose ersetzt die einzelne App und hat eine kurze Unterbrechung.
Ein Image-Rollback setzt kein DB-Schema zurück. Optionen: `setup.sh --help`, `update.sh --help`.

Details zu externer DB, Proxy-Headern, ENV, Entrypoint-Integration auf `main`,
Backup/Restore und Fehlerbehandlung: [docs/BETRIEB.md](docs/BETRIEB.md).

Der Export-Workflow `.github/workflows/deploy-branch.yml` muss auf `main` übernommen werden.
Er erzeugt bei geänderten Betriebsdateien einen Commit auf `deploy`, ohne Force-Push.
README und Gitignore kommen aus `deploy/branch/`. Künftige Änderungen auf `main` pflegen.
