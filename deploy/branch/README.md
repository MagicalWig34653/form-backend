# form-backend: Deploy-Branch

Betriebsdateien für **Docker Swarm oder Docker Compose**. Das fertige Image
`ghcr.io/magicalwig34653/form-backend` enthält Backend und PWA. MariaDB und TLS-Reverse-Proxy
werden **extern** bereitgestellt. Dieses Repository startet weder DB noch Proxy und baut
keine Images. Lizenz: [AGPL-3.0-only](LICENSE).

```bash
git clone --branch deploy --single-branch https://github.com/magicalwig34653/form-backend.git
cd form-backend
# Eine Variante wählen; Swarm vorher auf dem Manager initialisieren:
deploy/swarm/setup.sh --dry-run
deploy/swarm/setup.sh
# Oder Einzelserver (rootful Linux-Docker, Compose v2):
sudo deploy/compose/setup.sh --dry-run
sudo deploy/compose/setup.sh
```

Setup fragt Origin, Passkey-RP-ID und die vorhandene DB-Verbindung ab. Das DB-Passwort kommt
aus verdeckter Eingabe oder `--db-password-file /geschuetzt/db_password`; Setup prüft mit
einem einmaligen MariaDB-Client `SELECT 1` in der gewählten Datenbank. Datenbank und Benutzer
müssen bereits existieren. TLS zur DB ist standardmäßig `verify`.

Alle App-Variablen, Infrastrukturparameter und Defaults stehen kommentiert in
`deploy/swarm/stack.env.example` bzw. `deploy/compose/.env.example`. Die echte Env-Datei
hat Modus 0600 und bleibt außerhalb von Git. Prozess-ENV überschreibt gespeicherte Werte.
Secret-Werte werden nicht darin gespeichert. **Server-Key separat verschlüsselt sichern.**
Einen bestehenden Key mit `--server-key-file DATEI` übernehmen.

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
