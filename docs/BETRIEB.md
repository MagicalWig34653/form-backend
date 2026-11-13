# Betrieb von form-backend

## Aufbau und geprüfte Konfigurationsquelle

Stand P11-A, 03.11.2026: zwei HTTP-Listener im selben Prozess mit gemeinsamem DB-Pool
und gemeinsamen Diensten (ADR 0020). Externe MariaDB und TLS-Proxys bleiben Betreiberaufgabe.
Die aktuellen Sources und Deploy-Vorlagen sind maßgeblich. Keine automatische Migration beim
App-Start, kein Deployment durch dieses Paket. Lizenz: AGPL-3.0-only.

DB-Pool: je Event-Loop (= CPUs des Containers) `max(4, 32 / Loops)` Verbindungen, Wartezeit
auf eine freie Verbindung 10 s. Pro Replik werden höchstens 32 Verbindungen geöffnet, ab 8 CPUs 4 je CPU;
`max_connections` der MariaDB muss Repliken × diese Zahl plus Reserve erlauben. Meldet das Log
`Connection request timed out`, prüfen: `SHOW VARIABLES LIKE 'max_connections'`,
`SHOW STATUS LIKE 'Max_used_connections'`, `SHOW STATUS LIKE 'Aborted_connects'`, `SHOW PROCESSLIST`
(siehe `docs/handoffs/DB-Pool-Deadlock.md`).

## Listener und sichere Proxy-Zuordnung

| Listener   | ENV / Standard            | Registrierte Oberfläche                                                                                             |
| ---------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Öffentlich | `FORM_PUBLIC_PORT=8080`   | `/api/v2/submit` (inkl. index.php-Alias), `/api/v2/statistics/events`, `/mcp`, vorhandene MCP-Metadaten, `/healthz` |
| Intern     | `FORM_INTERNAL_PORT=8081` | PWA aus `FORM_PUBLIC_DIR`, `/admin/api`, `/health`, `/healthz`, `/ready`, weitere Verwaltungsrouten                 |

**Ingest ausschließlich öffentlich**: intern gibt es hierfür 404, ebenso für MCP und den
Statistik-Collector. Ohne `FORM_PUBLIC_DASHBOARD=1` sind PWA und sämtliche Admin-Routen öffentlich
nicht registriert (404), unabhängig von Host- oder Forwarded-Headern. `/.well-known`,
`/oauth/token` und `/oauth/register` sind öffentliche Erweiterungspunkte für P11-E; OAuth ist
noch nicht implementiert. Die bestehende Protected-Resource-Metadatenroute bleibt öffentlich.

`FORM_PUBLIC_DASHBOARD=1` registriert PWA und Admin-API zusätzlich öffentlich.
`FORM_PUBLIC_DASHBOARD_HOSTS` ist dann Pflicht: kommagetrennte exakte Kleinbuchstaben-Hosts,
ohne Schema, Port, Wildcards oder leere Einträge. Fehlende/ungültige Liste verhindert den Start.
Für Dashboard-Anfragen muss der Host auf dieser Liste stehen. Ein vorhandener Origin muss
`https://` plus derselben Authority (einschließlich Port) sein; Cookie-Mutationen benötigen
weiterhin den gültigen CSRF-Token. Hostübergreifende Origins, doppelte Header und unzulässige
Hosts werden abgewiesen. Intern bleibt der genaue `FORM_ADMIN_ORIGIN`-Abgleich bestehen.
WebAuthn verwendet weiterhin genau `FORM_ADMIN_ORIGIN`/`FORM_RP_ID`; die Hostliste erweitert
keine Passkey-Origin. Für Login die konfigurierte Admin-Origin auch öffentlich verwenden.

Beide Listener binden an `FORM_HTTP_HOST`. Container-Ports: `FORM_PUBLIC_PORT` (Standard 8080)
und `FORM_INTERNAL_PORT` (Standard 8081); gleiche Ports sind ungültig. Der frühere Name
`FORM_HTTP_PORT` wird nicht mehr gelesen. Nach außen veröffentlicht das Deployment standardmäßig
beide Listener (Host-Ports 8081 Dashboard, 8080 API/SDK; `PUBLISHED_PORT`/`FORM_PUBLISH_PORT`
und `FORM_PUBLIC_PUBLISH_PORT`).
CLI-Overrides `serve --port/--hostname/--bind/--socket` werden abgewiesen; Listener per ENV konfigurieren.

`FORM_PUBLIC_TRUSTED_PROXIES` und `FORM_INTERNAL_TRUSTED_PROXIES` gelten jeweils nur am
entsprechenden Listener (CIDRs). Fehlt eine Variable, gilt `FORM_TRUSTED_PROXIES` als gemeinsamer
Legacy-Fallback; explizit leer bedeutet keine vertrauenswürdigen Proxys. Die Deploy-Vorlagen
lassen beide standardmäßig weg und erhalten den Legacy-Fallback (auch dessen Datei-Override).
Bei älteren gespeicherten Env-Dateien explizit leere Listener-Listen entfernen, wenn der
Legacy-Fallback gewünscht ist. Ein bewusst gesetzter Leerwert bleibt eine Vertrauenssperre.
Nur bekannte Proxy-Peers dürfen Forwarded-Header liefern; am äußeren Proxy überschreiben.
Für das öffentliche Dashboard wird bei vertrauenswürdigem Peer genau ein `X-Forwarded-Host`
und `X-Forwarded-Proto: https` verlangt, sonst der originale `Host` ausgewertet. Für den
Statistik-/Ingest-Hostvertrag zusätzlich `X-Real-IP` aus dem verifizierten Client setzen.

Beide Proxy-Aliase zeigen auf dieselben Tasks, sind **keine Netzwerk-Isolation**:
`<stack>-public:8080` und `<stack>-internal:8081` (geänderte ENV-Ports entsprechend verwenden).
Öffentlichen Proxy ausschließlich zum öffentlichen Port verbinden; internen Proxy durch VPN,
privates Netz oder gleichwertigen Zugang schützen. Der Container-Healthcheck prüft intern
`/ready` inklusive DB-/Schemazustand; `/healthz` auf beiden Ports prüft nur Liveness.
`HEALTHCHECK_URL` für den abschließenden Skript-Check zeigt standardmäßig auf
`FORM_ADMIN_ORIGIN/ready`, also den **internen** Proxy. Der ausführende Rechner muss ihn erreichen.

Optionale Hostveröffentlichung (leer = keine, auch bei Compose):

| Variante         | Intern                     | Öffentlich                        |
| ---------------- | -------------------------- | --------------------------------- |
| Swarm app        | `FORM_PUBLISH_PORT`        | `FORM_PUBLIC_PUBLISH_PORT`        |
| Swarm app-pinned | `FORM_PINNED_PUBLISH_PORT` | `FORM_PINNED_PUBLIC_PUBLISH_PORT` |
| Compose app      | `PUBLISHED_PORT`           | `FORM_PUBLIC_PUBLISH_PORT`        |

Alle aktivierten Swarm-Hostports müssen verschieden sein; deaktiviertes Pinning veröffentlicht
keinen gepinnten Port. `PUBLISH_MODE` gilt für beide Listener. Compose nutzt `BIND_ADDR`
(Standard 127.0.0.1), Swarm unterstützt nur alle Host-IPs. Die Setup-/Update-Skripte rendern die
optionalen Portlisten; direktes `docker compose -f compose.yaml up` verwendet keine Hostports.
Die neuen skalaren Listenerwerte unterstützen wie die vorhandenen Werte `_FILE`-Overrides;
Passwörter und Schlüssel behalten ihre nativen Dateischnittstellen.

## Voraussetzungen und Installation

Linux mit rootful Docker Engine, Bash, curl, OpenSSL und Git; für Compose das v2-Plugin mit
`up --wait --wait-timeout`. Für Swarm auf einem aktiven Manager ausführen. Bei privatem
Registry-Paket vorher `docker login ghcr.io` mit dem ausführenden Benutzer. Docker-Zugriff
entspricht administrativen Host-Rechten. Rootless und User-Namespace-Remapping sind nicht geprüft.

Extern vorab bereitstellen:

- MariaDB mit existierender Datenbank und Benutzer. Der Benutzer benötigt die Rechte für
  Anwendung und DDL-Migrationen. Setup legt **weder Datenbank noch Benutzer** an und ändert
  kein DB-Passwort. Die normale App migriert nicht beim Start.
- `max_allowed_packet` der MariaDB mindestens **64 MiB** (`max_allowed_packet=64M` in der Serverkonfiguration oder
  `--max-allowed-packet=67108864` am Serverstart, bei Compose-betriebener MariaDB als `command:`). Uploads sind bis 20 MB
  erlaubt (Paket ≈ 27 MB, Anfragelimit 32 MiB) und werden als ein Wert geschrieben; beim Standard von 16 MiB trägt die
  Datenbank nur etwa 12 MB große Anhänge. Die Einsendung wird nie als angenommen bestätigt, wenn ihre Daten nicht gespeichert
  werden können: Ist ein versiegeltes Paket größer als das `max_allowed_packet` der Verbindung (plus 64 KiB Reserve), antwortet
  der Ingest VOR dem Schreiben mit 413 `payload_too_large`, speichert nichts und loggt den Betreiberhinweis; beim Start warnt
  der Dienst („max_allowed_packet X MiB < ingest limit Y MiB“). Ein zu kleiner Wert bedeutet also abgelehnte große Uploads,
  keine verlorenen (siehe Übergaben QA-15C5D5E9 und Upload-Verlust). Unabhängig vom Serverwert kann der Treiber (MySQLNIO 1.9.x) kein
  einzelnes Statement und keine einzelne Ergebniszeile ab 16 MiB − 1 übertragen (Paketlänge ohne Aufteilung); versiegelte Objekte werden
  deshalb in 4-MiB-Stücken geschrieben und gelesen (`ChunkedBlob`, Übergabe `docs/handoffs/Grosse-Uploads-500.md`). Mit 64 MiB sind Uploads
  bis 20 MB belegt (Test `LargeUploadIngestTests`: 12 bis 19,999999 MB angenommen, Hash und Entschlüsselung über den Anhang-Endpunkt byte-genau,
  Aufbewahrung löscht sie). Der Umstieg-Import schreibt große Zellen stückweise (`CONCAT`), MariaDB prüft das Ergebnis
  gegen die Grenze (Fehler 1301). Der Prüflauf meldet eine zu kleine Grenze vorab als `target_packet_too_small`, die
  Quellprüfung warnt. Nach einer Änderung Datenbank und App neu starten.
- DB-Netzwerkzugriff von allen App-/Migrations-Nodes und vom Client für Backup/Restore.
  DB-Host muss im Container auflösbar sein; `localhost` bezeichnet dort den Container.
- TLS-Reverse-Proxy, öffentliche HTTPS-Origin und passende Passkey-RP-ID. Proxy-Anforderungen unten.

```bash
git clone --branch deploy --single-branch https://github.com/magicalwig34653/form-backend.git
cd form-backend
# Swarm: nur bei bisher inaktivem Cluster vorher docker swarm init ausführen.
deploy/swarm/setup.sh --dry-run
deploy/swarm/setup.sh --db-password-file /geschuetzt/db_password
# Alternative Einzelserver ohne Swarm:
sudo deploy/compose/setup.sh --dry-run
sudo deploy/compose/setup.sh --db-password-file /geschuetzt/db_password
```

Das Erstsetup fragt Stack-/Projektname, HTTPS-Origin, RP-ID, externen DB-Host, Port, Benutzer,
Datenbank, TLS und Image-Tag ab. Swarm fragt zusätzlich Replikate. Ohne Passwortdatei wird
das **bereits gültige** DB-Passwort verdeckt abgefragt, niemals generiert. Einen vorhandenen
Server-Key mit `--server-key-file DATEI` übernehmen. Ohne vorhandenen Key erzeugt Setup 32
zufällige Byte als 64 Hexzeichen. Eine explizit angegebene fehlende Quelldatei ist ein Fehler;
sie wird nicht stillschweigend durch einen neuen Schlüssel ersetzt.

Vorbereitetes Setup ohne Dialog:

```bash
cp deploy/swarm/stack.env.example deploy/swarm/stack.env
chmod 600 deploy/swarm/stack.env
# Platzhalter/Parameter bearbeiten, Passwortdatei bereitstellen, dann:
deploy/swarm/setup.sh --non-interactive --db-password-file /geschuetzt/db_password --dry-run
deploy/swarm/setup.sh --non-interactive --db-password-file /geschuetzt/db_password
```

Compose analog mit `.env.example` → `.env` unter `deploy/compose/`, echte Befehle typischerweise
mit sudo. Setup benötigt dort root, um Secret-Dateien der App-UID zuzuordnen; die tatsächlichen
Hostrechte sind bei Compose-Dateimounts maßgeblich. Quellen werden dabei auf 0400 gesetzt und
bei Compose auf `APP_UID:APP_GID` umgestellt. Bereits konfigurierte Swarm-Secrets werden erhalten.
Benötigte Originaldateien vorab separat sichern; keine produktiven Secrets in Git ablegen.

Die Skripte prüfen das Docker-Netz `NETWORK_NAME` und legen es bei Bedarf an (Swarm: attachable
overlay, Compose: bridge). Externe DB-Verbindungen benötigen ausgehendes Routing; das Netz ist
absichtlich nicht `internal`. Ein vorhandenes Netz mit anderem Treiber wird abgelehnt.
Es gibt keine DB-Volumes, keine DB-Node-Labels und keinen DB-Root-Secret-Vertrag mehr.

## ENV-Vertrag und Defaults

Die vollständigen, kommentierten Inventare stehen in `deploy/swarm/stack.env.example` und
`deploy/compose/.env.example`. Jede direkt in AppConfig/main gelesene Variable ist enthalten,
einschließlich `FORM_DB_PASSWORD` als kommentierter Secret-Alternative. Die Dateien sind
`KEY=VALUE`, optional mit passenden Quotes; keine Shell-Expansion, Befehle oder mehrzeiligen
Werte. Das Skript parst sie ohne `source`. Priorität: Defaults < gespeicherte Datei < Prozess-ENV
< CLI-Image-/Dateioptionen. Die gespeicherte Datei wird atomar mit Modus 0600 geschrieben;
die vorherige Fassung liegt ebenfalls geschützt als `.bak`. Passwörter/Schlüsselwerte werden
nicht gespeichert, nur sichere Pfad-/Secretnamen. `--dry-run` erzeugt/ändert keine Dateien,
Secrets, Netze oder Container und führt keine Docker-/Registry-/Verbindungstests aus.

| Bereich                   | Parameter und Wirkung                                                                                                                            |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Image                     | `FORM_IMAGE_REPOSITORY`, `FORM_IMAGE_TAG`, optional vollständiges `FORM_IMAGE`; bei Erfolg gespeicherter Digest                                  |
| Externe DB                | `FORM_DB_HOST`, `FORM_DB_PORT`, `FORM_DB_USER`, `FORM_DB_NAME`, `FORM_DB_TLS`, `FORM_DB_PASSWORD_FILE`                                           |
| HTTP/PWA                  | `FORM_HTTP_HOST`, `FORM_PUBLIC_PORT`, `FORM_INTERNAL_PORT`, `FORM_LOG_LEVEL`, `FORM_PUBLIC_DIR`, `FORM_SCHEMA_FILE`, `FORM_SDK_DIR`, `LOG_LEVEL` |
| Anmeldung                 | `FORM_ADMIN_ORIGIN`, `FORM_RP_ID`, `FORM_SERVER_KEY_FILE`, `FORM_BOOTSTRAP_PASSWORD_FILE`                                                        |
| Rechte an Weiterleitungen | `FORM_TRUSTED_PROXIES`, `FORM_MAIL_ALLOWED_NETS`, `FORM_ALLOW_INSECURE_DEV`                                                                      |
| Secret-Quellen            | `DB_PASSWORD_SOURCE_FILE`, `SERVER_KEY_SOURCE_FILE`, `BOOTSTRAP_PASSWORD_SOURCE_FILE`: Hostpfade                                                 |
| Swarm-Secrets             | `DB_PASSWORD_SECRET`, `SERVER_KEY_SECRET`, `BOOTSTRAP_PASSWORD_SECRET`; leer: aus STACK ableiten                                                 |
| Ressourcen                | `APP_CPUS`, `APP_MEMORY`, `APP_RESERVE_CPUS`, `APP_RESERVE_MEMORY`, `MIGRATION_CPUS`, `MIGRATION_MEMORY`                                         |
| Skalierung                | `FORM_REPLICAS`: Swarm Standard 3, Compose mit festem Hostport hier genau 1                                                                      |
| Hostzugang                | `BIND_ADDR`, `PUBLISHED_PORT`, `PUBLISH_MODE` (host/ingress, Swarm); interne/öffentliche Containerziele gemäß Listener-Tabelle                   |
| Netz                      | `STACK`, `NETWORK_NAME`, `NETWORK_DRIVER`; Name frei, Treiber passend zur Variante                                                               |
| Update                    | `UPDATE_PARALLELISM`, `UPDATE_ORDER`, `UPDATE_MONITOR`, `UPDATE_DELAY`, `UPDATE_FAILURE_ACTION`                                                  |
| Rollback/Neustart         | `ROLLBACK_PARALLELISM`, `ROLLBACK_ORDER`, `ROLLBACK_MONITOR`, `RESTART_CONDITION`, `RESTART_DELAY` (Swarm)                                       |
| Prüfung                   | `HEALTH_INTERVAL`, `HEALTH_TIMEOUT`, `HEALTH_RETRIES`, `HEALTH_START_PERIOD`, `HEALTHCHECK_URL`, `WAIT_SECONDS`                                  |
| Laufzeitpfade/-benutzer   | `FORM_APP_BINARY`, `ENTRYPOINT_PATH`, `HEALTHCHECK_PATH`, `APP_UID`, `APP_GID`                                                                   |
| DB-Client                 | `DB_CLIENT_IMAGE`, `DB_CLIENT_MODE`, `DB_CLIENT_NETWORK`, `DB_CLIENT_MEMORY`, `DB_CONNECT_TIMEOUT`, `DB_TLS_CA_FILE`, `DB_CLIENT_CA_PATH`        |

Pfade `FORM_*_FILE` in Stack/Compose sind **Containerpfade**, die Secret-Quellen dagegen
Hostpfade. Relative Host-Quellen werden relativ zur gewählten Env-Datei aufgelöst. Native
Dateipfade müssen für die App lesbar sein, der Server-Key nur mit 0400/0600. Standard-UID ist
10001; eigene Images müssen den gewählten Benutzer und lesbare Image-Verzeichnisse unterstützen.

Compose erlaubt die Bind-Adresse `127.0.0.1` (Standard) oder eine private Host-IP. **Swarm
Published Ports unterstützen keine einzelne Host-IP-Bindung**: `BIND_ADDR` muss dort
`0.0.0.0` sein, andere Werte werden ausdrücklich abgelehnt. `PUBLISH_MODE=ingress` publiziert
über alle Nodes; `host` publiziert auf Nodes mit Tasks, mit festen Ports höchstens ein Task
je Node. Deshalb passt `host` nicht zu beliebiger Replikazahl/start-first auf einem Einzelknoten.
Firewall und Proxy-Zielknoten entsprechend planen; das Skript öffnet keine Firewallregeln.
Compose hat bei festem Hostport keine Mehrreplika-/Rolling-Update-Zusage; Swarm-Updateparameter
sind in Compose-Vorlagen zur gemeinsamen Konfiguration dokumentiert, wirken dort aber nicht.

### Swarm-Platzierung

Stand 03.11.2026: Nutzerauftrag im Hauptverzeichnis auf Branch `main`, Änderungen nur in
`deploy/swarm/{stack.yaml,stack.env.example,setup.sh,update.sh,lib.sh}`,
`scripts/check-deploy.py` und diesem Abschnitt. Kein Commit, kein Deployment, keine laufenden
Jobs. Die folgenden Angaben ersetzen für Swarm die älteren Hostport-Angaben in diesem Dokument.
P11-A ersetzt den früheren einzelnen Hostport durch zwei optionale Veröffentlichungen.

| ENV                          | Default   | Wirkung                                                                                                                         |
| ---------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `FORM_PLACEMENT_CONSTRAINTS` | leer      | Kommagetrennte harte Constraints für `app`, z.B. `node.role==worker,node.labels.disk==ssd`; alle müssen erfüllt sein            |
| `FORM_PLACEMENT_PREFERENCES` | leer      | Kommagetrennte weiche Präferenzen für `app`, z.B. `spread=node.labels.zone,spread=node.labels.rack`; keine Platzierungsgarantie |
| `FORM_PINNED_NODE`           | leer      | Exakter Hostname oder vollständige Swarm-Node-ID; leer deaktiviert Pinning                                                      |
| `FORM_PINNED_REPLICAS`       | `1`       | Positive Anzahl zusätzlicher Replikate auf diesem Knoten                                                                        |
| `FORM_EXCLUDE_LABEL`         | leer      | Label-Schlüssel, z.B. `reserved`; ergänzt automatisch `node.labels.reserved!=true` bei `app`, DB-Prüfung und Migration          |
| `FORM_PUBLISH_PORT`          | leer      | Optionaler TCP-Hostport für `app` (1–65535); leer = keine Veröffentlichung                                                      |
| `FORM_PINNED_PUBLISH_PORT`   | leer      | Optionaler anderer TCP-Hostport für `app-pinned`; nur bei aktivem Pinning veröffentlicht                                        |
| `PUBLISH_MODE`               | `ingress` | Modus für alle aktivierten Veröffentlichungen: `ingress` oder `host`                                                            |
| `FORM_PUBLISH_BIND`          | leer      | Nur leer oder `0.0.0.0`: Swarm unterstützt keine Bindung an eine einzelne Host-IP                                               |

`app` behält `FORM_REPLICAS` (Default 3). `app-pinned` erbt Image, Environment, Secrets,
Configs, Healthcheck, Ressourcen und Update-/Rollback-Konfiguration über YAML-Anker.
Der gepinnte Dienst erhält ausschließlich die harte Knoten-Constraint, keine App-Constraints,
keine App-Präferenzen und keinen Label-Ausschluss. Vollständige IDs mit 25 Kleinbuchstaben/Ziffern
werden als `node.id==...` interpretiert, andere zulässige Namen als `node.hostname==...`.
Bei einem entsprechend aussehenden Hostnamen die tatsächliche Node-ID verwenden.
Hostnamen müssen im Cluster eindeutig sein.

Bei leerem `FORM_PINNED_NODE` bleibt `app-pinned` mit **replicas 0** im Stack. So skaliert ein
Update auch einen zuvor aktivierten gepinnten Dienst zuverlässig auf null. Gesamtzahl im
Normalzustand: **FORM_REPLICAS + FORM_PINNED_REPLICAS**, bei ausgeschaltetem Pinning nur
FORM_REPLICAS; während `start-first` können vorübergehend zusätzliche Tasks laufen.
Pinning reserviert die gewünschte Task-Anzahl auf dem Knoten; bei Ausfall, Drain oder fehlenden
Ressourcen können dort keine Container laufen. Swarm lässt Tasks dann ausstehend statt sie
auf andere Knoten zu verschieben. Setup/Update warten auf beide Dienste und melden einen
Timeout/Fehler, wenn die gewünschte Replikazahl nicht erreicht wird. Ein App-Rollback allein
rollt `app-pinned` nicht zurück; bei Wartung/Backup beide Dienste stoppen.

**(a) Proxy im Overlay:** Beide Dienste verwenden `${STACK}-public` und `${STACK}-internal`
als gemeinsamen Alias auf `NETWORK_NAME`. Ohne veröffentlichte Ports bleibt `endpoint_mode: dnsrr`
aktiv; der Proxy löst Task-Adressen auf. Proxy mit dem Overlay verbinden und auf
`${STACK}-public:${FORM_PUBLIC_PORT}` bzw. `${STACK}-internal:${FORM_INTERNAL_PORT}` zeigen lassen. DNS regelmäßig neu
auflösen und mehrere Adressen sowie deren Ausfall behandeln; der Alias garantiert keine
gleichmäßige Lastverteilung. Beide Veröffentlichungsvariablen können leer bleiben (Default).

**(b) Proxy außerhalb des Overlays:** Hostports explizit aktivieren, beispielsweise:

```dotenv
FORM_PUBLISH_PORT=18080
FORM_PINNED_NODE=worker-a
FORM_PINNED_PUBLISH_PORT=18081
PUBLISH_MODE=ingress
FORM_PUBLISH_BIND=
```

Der Proxy kann dann beliebige erreichbare Swarm-Node-IPs an Port 18080 für `app` und
Port 18081 für `app-pinned` verwenden. Das Routing-Mesh verteilt **nur innerhalb des jeweiligen
Dienstes**. Für Verteilung auf beide Dienste im Proxy **zwei Upstreams** eintragen, z.B.
`swarm-node.example.org:18080` und `swarm-node.example.org:18081`; zusätzliche Node-Ziele und
Healthchecks nach Proxy-Konzept einrichten. Nur ein aktivierter Port erreicht nur dessen Dienst.
Bei Ingress-Publish stellt der Renderer den betreffenden Dienst automatisch auf `endpoint_mode: vip`,
weil Swarm Ingress-Veröffentlichung mit `dnsrr` ablehnt. Der Overlay-Alias bleibt vorhanden.
Bei deaktiviertem Pinning wird auch ein konfigurierter `FORM_PINNED_PUBLISH_PORT` nicht
veröffentlicht, und der gepinnte Dienst bleibt bei `dnsrr` und null Replikaten.

Die Ports müssen unterschiedlich sein; gleiche Portnummern (auch mit führenden Nullen)
werden vor Docker-Aufrufen abgelehnt. Ein Ingress-Publish-Port ist im Swarm dienstübergreifend
belegt. Netzwerk-Aliasse dürfen dagegen von mehreren Diensten geteilt werden.

**(c) `mode host` nur für den gepinnten Dienst:** Hauptdienst über den Overlay-Alias erreichen,
`FORM_PUBLISH_PORT` leer lassen und nur den gepinnten Dienst veröffentlichen:

```dotenv
FORM_PUBLISH_PORT=
FORM_PINNED_NODE=worker-a
FORM_PINNED_REPLICAS=1
FORM_PINNED_PUBLISH_PORT=18081
PUBLISH_MODE=host
UPDATE_ORDER=stop-first
ROLLBACK_ORDER=stop-first
```

Der externe Proxy zeigt auf die IP von **worker-a:18081**; auf anderen Nodes lauscht dieser
Hostport nicht. Es gibt kein Routing-Mesh. Ein fester Hostport erlaubt höchstens einen Task
je Knoten; deshalb hier genau eine gepinnte Replika und `stop-first` für Update und Rollback
verwenden. Während des Ersetzens entsteht eine Unterbrechung. `PUBLISH_MODE` gilt gemeinsam
für alle aktivierten Ports; bei zusätzlich gesetztem `FORM_PUBLISH_PORT` würde auch `app`
im Host-Modus veröffentlicht. Dann müssen Proxy-Ziele, Platzierung, höchstens ein Task je
Node und Update-Kapazität entsprechend geplant werden.

**Bindung und Umstieg:** Swarm-Publish bietet keine Bindung an eine einzelne Host-IP,
auch nicht im Host-Modus. `FORM_PUBLISH_BIND` ist deshalb nur leer oder `0.0.0.0` zulässig;
es wird kein irreführendes `host_ip` gerendert. Veröffentlichte Ports sind auf allen Host-IPs
zugänglich; Zugriff auf den externen Proxy per Host-/Netz-Firewall begrenzen.
`BIND_ADDR=0.0.0.0` bleibt als bisheriger Konfigurationswert lesbar. Der frühere Swarm-Eintrag
`PUBLISHED_PORT` entfällt: aus bestehenden `stack.env` entfernen und bei gewünschter
Veröffentlichung durch `FORM_PUBLISH_PORT` ersetzen. Alte Dateien mit dem entfernten Namen
werden vom strikten Parser abgelehnt. Leere neue Ports entfernen eine bestehende
Veröffentlichung beim Update; Proxy-Ziele daher vorab passend konfigurieren.

Quellen: [Docker Routing Mesh, Host-Modus und externe Loadbalancer](https://docs.docker.com/engine/swarm/ingress/),
[Docker Service-Aliasse](https://docs.docker.com/reference/compose-file/services/#aliases),
[SwarmKit-Portprüfung](https://github.com/moby/swarmkit/blob/master/manager/controlapi/service.go).

Setup und Update fragen Platzierung, Ports, Publish-Modus und Bind-Wert interaktiv ab; Enter übernimmt den angezeigten
Wert, `-` löscht einen optionalen Wert. Mit `--non-interactive` gelten ausschließlich
Vorlage, gespeicherte Datei und Prozess-ENV in der üblichen Priorität. Der Trockenlauf nennt
Constraints, Präferenzen, Ausschluss, Pinning, Gesamtzahl, Overlay-Ziel und wirksame
Veröffentlichungsports, ohne Docker aufzurufen.
Beispiel (Update benötigt eine bereits angelegte `stack.env`):

```bash
FORM_PLACEMENT_CONSTRAINTS='node.role==worker' \
FORM_PLACEMENT_PREFERENCES='spread=node.labels.zone' \
FORM_PINNED_NODE=worker-a FORM_PINNED_REPLICAS=1 FORM_EXCLUDE_LABEL=reserved \
  deploy/swarm/update.sh --non-interactive --dry-run
# Pinning ausschalten (leere Prozess-ENV überschreibt den gespeicherten Wert):
FORM_PINNED_NODE= deploy/swarm/update.sh --non-interactive --dry-run
```

Listen, optionale Ports, Endpoint-Modi und die abgeleitete Knoten-Constraint werden von `lib.sh` gerendert. Die rohe
`stack.yaml` hat gültige sichere Defaults, verarbeitet diese Platzierungs-ENV aber nicht
allein. Für den Betrieb immer Setup/Update verwenden. Manuelle Renderprüfung ohne Daemon:

```bash
FORM_PINNED_NODE=worker-a FORM_EXCLUDE_LABEL=reserved bash -c '
set -euo pipefail
BASE="$PWD/deploy/swarm"; MODE=swarm; ACTION=setup
source "$BASE/lib.sh"
initialize --dry-run --non-interactive
render_swarm | docker stack config -c -
'
# Analog mit FORM_PINNED_NODE= und/oder ohne FORM_EXCLUDE_LABEL prüfen.
```

**Opt-in-Knoten:** Swarm kennt keinen Knoten, der „nur auf ausdrücklichen Wunsch“ belegt wird.
Ein organisationsweit vereinbartes Label-Muster kann das für die eigenen Stacks abbilden:

```bash
docker node update --label-add reserved=true NODE
# In allen eigenen Stacks standardmäßig FORM_EXCLUDE_LABEL=reserved setzen.
# Dienste, die gezielt dorthin sollen: node.labels.reserved==true
# Bei app über FORM_PLACEMENT_CONSTRAINTS zusätzlich FORM_EXCLUDE_LABEL= leeren,
# sonst würden sich ==true und !=true widersprechen.
# app-pinned ist automatisch vom Ausschluss ausgenommen.
```

Andere Stacks ohne diese Ausschluss-Constraint können weiterhin auf dem reservierten Knoten
landen. **Hartes Sperren:** `docker node update --availability drain NODE`; dann laufen dort
gar keine Tasks, auch keine ausdrücklich gewünschten oder gepinnten. Das Label ist keine
clusterweite Zugriffssperre. Die temporären DB-/Migrationsjobs brauchen bei aktivem Ausschluss
mindestens einen anderen geeigneten aktiven Knoten.

Prüfstand dieses Pakets: `bash -n`, ShellCheck, Setup-/Update-Trockenläufe und
`python3 scripts/check-deploy.py` einschließlich sechs Platzierungs- und sieben Veröffentlichungsvarianten mit echtem
`docker stack config` (kein Pinning/Hostname/Node-ID, mit/ohne Ausschluss-Label; keine/einzelne/beide
Ports, Ingress/Host und deaktiviertes Pinning trotz konfiguriertem Port) sowie ungültiger Eingaben,
Pinning-Deaktivierung und fehlender gepinnter Tasks mit Kommando-Doubles. Der Docker-Socket
ist mit „permission denied“ gesperrt; kein echter Swarm-/DNS-/Proxy-Lauf nachgewiesen.
Nächster Schritt: isolierte Swarm-Probe mit Overlay- und externem Proxy, Ingress-/Host-Ports,
Proxy-DNS-Erneuerung, Knoten-Ausfall, Pinning an/aus und Rollback beider Dienste. Keine produktive Migration ausführen.

### TLS zur externen DB

Standard `FORM_DB_TLS=verify`: Swift verwendet NIOSSL-Clientkonfiguration mit Systemvertrauen
und Zertifikatsprüfung, der DB-Hostname muss zum Zertifikat passen. Es existiert **keine native
Variable für eine eigene CA-Datei**. Bei privater CA diese in das Runtime-Image/Systemvertrauen
aufnehmen und dies separat auf `main` vorbereiten. Keine Änderung an `main` erfolgt hier.

**TLS ist zwingend, kein Rückfall auf Klartext.** Bietet der DB-Server in seiner Begrüßung kein `CLIENT_SSL` an
(Server ohne TLS oder von einem Angreifer im Netz entferntes Flag), bricht der Treiber die Verbindung ab, bevor
Zugangsdaten gesendet werden (`secureConnectionRequired`); der Start/Pool schlägt dann fehl. Das gilt für
`verify` und für die Quellverbindung des Umstiegs mit TLS. Grundlage ist der gepatchte, lokal eingebundene
Treiber `backend/Vendor/mysql-nio` (Patches und Update-Hinweis: `backend/Vendor/README.md`). Zusätzlich
serverseitig `REQUIRE SSL` für das DB-Konto setzen.

Treiber-Logging: SQL-Bind-Werte (Passwort-Hashes) werden nie protokolliert (`sqlLogLevel: nil`) und der
Paket-Trace des Treibers gibt keine Payload-Bytes mehr aus, auch nicht bei `FORM_LOG_LEVEL=debug` oder `trace`.

`FORM_DB_TLS=disable` funktioniert ausschließlich mit `FORM_ALLOW_INSECURE_DEV=1`.
Diese Entwicklungsfreigabe erlaubt zugleich unsichere SMTP-/HTTP- und SDK-Deploy-Ziele und
ist keine isolierte DB-Ausnahme. Im normalen externen Betrieb `verify` und Freigabe `0` lassen.

DB-Prüfung und Backups nutzen den MariaDB-Client mit `--ssl --ssl-verify-server-cert` oder
bei ausdrücklich deaktiviertem TLS `--skip-ssl`. `DB_TLS_CA_FILE` kann **clientseitig** eine
Host-CA-Datei angeben. Compose/Backup mounten sie in den Einmal-Client; Swarm repliziert sie
als inhaltsbenannte Docker-Config in den Prüfjob. Das ändert nicht das Vertrauen der Swift-App.
Ein erfolgreicher Client-Test allein ist daher kein Beweis identischer TLS-Vertrauensspeicher.

## Entrypoint und Dateisecrets

`deploy/docker-entrypoint.sh` ergänzt den bestehenden Swift-Dateivertrag:

- `FORM_DB_PASSWORD_FILE` bleibt nativ, ein zusätzliches direktes `FORM_DB_PASSWORD` ist
  ein Fehler statt stiller Priorität. Im Stack werden nur die Dateien weitergegeben.
- `FORM_SERVER_KEY_FILE` und `FORM_BOOTSTRAP_PASSWORD_FILE` bleiben Dateipfade.
  Direkte Alternativen `FORM_SERVER_KEY` und `FORM_BOOTSTRAP_PASSWORD` werden bei eigenständiger
  Nutzung des Wrappers in private temporäre Dateien umgewandelt; direkte und Dateiquelle
  zugleich sind ein Fehler. Setup nimmt diese ENV-Werte ebenfalls als Quelle neuer Secrets an.
- Weitere skalare Laufzeitwerte unterstützen optional `<NAME>_FILE` (in beiden Vorlagen
  aufgelistet), z. B. `FORM_ADMIN_ORIGIN_FILE`. Mit Ausnahme der drei Portvariablen (siehe unten) überschreibt die explizite Datei den skalaren
  Default. Sie muss zusätzlich im Container verfügbar gemacht werden; Dateipfade erzeugen
  keine zusätzlichen Mounts/Swarm-Secrets automatisch. Keine rekursive Interpretation nativer
  Pfadvariablen. Port-/DB-Overrides müssen zur Hostkonfiguration des Deployments passen, da
  Published-Port-Ziel und externe DB-Prüfung die skalaren Deploymentwerte verwenden.

**Der Wrapper muss später auf `main` in das Runtime-Dockerfile aufgenommen werden**:

```dockerfile
# Runtime stage, before USER; keep existing CMD ["serve"].
COPY --chmod=0555 deploy/docker-entrypoint.sh /usr/local/bin/form-entrypoint
ENTRYPOINT ["/usr/local/bin/form-entrypoint"]
```

Bis dieses Image verfügbar ist, binden die gelieferten Dateien denselben Wrapper als
Swarm-Config bzw. Compose-Dateimount ein und setzen den Entrypoint explizit auf Bash.
Damit funktioniert der hier dokumentierte Vertrag auch mit dem bisherigen Image.
Config-Namen enthalten eine Inhaltsrevision; geänderte Wrapper/Healthchecks überschreiben
keine unveränderlichen Swarm-Configs. Alte unbenutzte Configs erst nach Prüfung gezielt entfernen.

Es werden zwei erforderliche Secrets angelegt: vorhandenes DB-Passwort und Server-Key.
Das zusätzliche Bootstrap-Secret enthält ohne Betreiberquelle ausschließlich den Marker
`FORM_OPTIONAL_UNSET`. Der Wrapper entfernt in diesem Fall die Dateivariable; bei manuellem
`bootstrap-admin` generiert main weiterhin ein einmal angezeigtes Passwort. Ein echter
Bootstrap-Wert wird nur bei expliziter Quelldatei/ENV übernommen. Bestehende Secrets werden
nie überschrieben; Rotation erfordert neue Namen und einen bewusst vorbereiteten Rollout.
Kein DB-Root-Passwort wird benötigt. Swarm-Secrets sind später nicht auslesbar.

## Anforderungen an den externen Reverse Proxy

Der Proxy terminiert HTTPS mit gültigem Zertifikat. Die öffentliche Origin geht an den
öffentlichen Listener, die interne Admin-Origin an den internen Listener; siehe Tabelle oben.
`FORM_ADMIN_ORIGIN` exakt auf die Login-Origin setzen. Den ursprünglichen Host erhalten und
Forwarded-Header nur aus verifizierten Werten setzen. Die Trusted-Proxy-Netze je Listener
explizit eintragen, keine pauschale Freigabe `0.0.0.0/0`. Docker-NAT/Routing-Mesh kann die
sichtbare Peer-IP verändern: tatsächliche Peer-Netze erheben und direkten App-Zugriff begrenzen.

WebSocket-Weiterleitung ist für den geprüften Anwendungsstand **nicht nötig**. Normale
HTTP-Weiterleitung genügt. Uploadlimits, Antwort-/Idle-Timeouts und Log-Aufbewahrung passend
zum Betrieb festlegen, keine personenbezogenen Debugmitschnitte dauerhaft aktivieren.
Ein vollständiger Konfigurationsausschnitt mit zwei HTTPS-Hosts steht unter
[deploy/proxy/nginx.conf.example](../deploy/proxy/nginx.conf.example):
öffentlicher Host → `form-public:8080`, interner Host → `form-internal:8081`.
Für einen Proxy auf dem Compose-Host z.B. `FORM_PUBLIC_PUBLISH_PORT=18080`,
`PUBLISHED_PORT=18081`, `BIND_ADDR=127.0.0.1` setzen und die Upstreams auf
`127.0.0.1:18080` bzw. `127.0.0.1:18081` ändern. Swarm-Hostports liegen auf
allen Host-IPs und erfordern eine Firewallbegrenzung auf den Proxy.

### Betriebshärtung des Proxys (Todolino 2000434E)

**Sicherheitsheader.** Die Vorlage setzt HSTS (`max-age=31536000; includeSubDomains`, bewusst
ohne `preload`), `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` und eine
`Permissions-Policy` (Kamera, Mikrofon, Standort, Zahlung, USB aus; WebAuthn bleibt erlaubt).
`includeSubDomains` setzt voraus, dass alle Subdomains der Origin HTTPS können. Das Backend
setzt `nosniff` und `Referrer-Policy` bereits selbst (`StaticSite.swift`, `Routes.swift`); die
Vorlage verbirgt diese Backend-Header und setzt sie einmal neu, damit nichts doppelt ankommt.
Die CSP der App-Shell (same-origin, `frame-ancestors 'none'`) liefert das Backend für HTML;
der Proxy ergänzt nur für Antworten ohne CSP (API/JSON) `frame-ancestors 'none'`. Kein
`add_header` in `location`-Blöcken ergänzen (verdrängt die Server-Header).

**Prüfung.** `deploy/proxy/check-headers.sh URL [curl-Argumente]` (Exit ≠ 0 bei fehlendem,
doppeltem oder falschem Header, auch HSTS-`preload`). Gegen den Produktivhost nach jedem
Proxy-Change ausführen. `deploy/proxy/test-template.sh` prüft die Vorlage lokal in einem
nginx-Container (`nginx -t`, Header je Host/Pfad, IP-Kürzung, Access-Log); Docker und openssl
nötig, bisher nicht Teil von CI.

**Proxy-Logs.** Das Access-Log der Vorlage kürzt IPs (IPv4 letztes Oktett auf `.0`, IPv6 auf
/48) und enthält `$uri` ohne Query-String und ohne Referer. Das Backend erhält weiterhin die
ungekürzte Peer-IP (Drosselung/Missbrauchsschutz). Frist 7 Tage: `deploy/proxy/logrotate.example`
(`daily`, `rotate 7`, `maxage 7`, USR1 nach Rotation). Betreiber mit Docker-Logging statt Dateien:
`json-file` kennt nur Größen-, keine Zeitgrenzen (`max-size`/`max-file` so wählen, dass etwa
7 Tage abgedeckt sind) oder Logs per Treiber in ein System mit 7-Tage-Retention leiten. Die
Anwendungslogs (Level `FORM_LOG_LEVEL`) unterliegen derselben Betreiberpflicht; Docker-Logs der
App-Container sind nicht automatisch begrenzt. Keine Debugmitschnitte dauerhaft aktivieren.

**Interner Listener.** `form-internal:8081` darf nur über VPN/Firewall erreichbar sein (interne
Adresse im `listen`, Hostport-Bindung auf 127.0.0.1/Proxy-Netz, Swarm-Hostports per Firewall).
`FORM_INTERNAL_SECOND_FACTOR=0` (Default) ist laut ADR 0022/P11-G für den internen Listener
korrekt, weil dort Passkey mit Pflicht-UV genügt; diese Annahme trägt der Netzschutz. Wird das
Dashboard öffentlich gemountet (`FORM_PUBLIC_DASHBOARD=1`), ist Passkey plus Passwort Pflicht.
Der Code erzwingt das bereits: `AuthConfig.secondFactorRequired` ist für Listener `public`
immer wahr (`FormAuth/AuthGuard.swift`), unabhängig vom internen Schalter; ein Konfigurationsfehler
dagegen ist nicht möglich. Nicht erzwungen: dass der interne Port netzseitig begrenzt ist; wo der
interne Listener nicht strikt per VPN/Firewall geschützt werden kann, `FORM_INTERNAL_SECOND_FACTOR=1`
setzen.

Die Listen vertrauen **Socket-Peers des Proxys**, nicht den Clientnetzen. Beispiel für
zwei feste, tatsächlich am Backend sichtbare Proxy-Adressen:
`FORM_PUBLIC_TRUSTED_PROXIES=192.0.2.10/32` und
`FORM_INTERNAL_TRUSTED_PROXIES=192.0.2.11/32` (Dokumentationsadressen, ersetzen).
Alternativ beide weglassen und `FORM_TRUSTED_PROXIES` setzen. Bei leerer oder falscher
Freigabe wird X-Forwarded-For ignoriert; alle Clients hinter demselben Peer teilen dann
dessen IP-Rate-Limit. Nach NAT/Routing-Mesh die tatsächlichen Peer-Adressen und
Client-IP-Trennung mit zwei synthetischen Clients prüfen; keine breiten Docker-/LAN-Netze
pauschal vertrauen. Wer diese Netze erreichen kann, könnte sonst Forwarded-IPs fälschen.

Bei einem weiteren vertrauenswürdigen vorgeschalteten Proxy dessen Client-IP vorher mit
korrekt eingeschränkten nginx-Real-IP-Regeln ermitteln. Eine auskommentierte Traefik-
Service-Port-Labelskizze steht im Swarm-YAML; sie erstellt keinen Proxy. Zugang zum Published
Port per Firewall ausschließlich vom Proxy zulassen. Hier werden keine TLS-Zertifikate verwaltet.

## Update, Migration und Rollback

```bash
git pull --ff-only
# Vorher DB und Schlüssel sichern, alten Digest und Schema-Kompatibilität prüfen.
deploy/swarm/update.sh --tag GEWUENSCHTE_COMMIT_SHA --dry-run
deploy/swarm/update.sh --tag GEWUENSCHTE_COMMIT_SHA
# Alternativ vollständige Referenz:
sudo deploy/compose/update.sh --image ghcr.io/magicalwig34653/form-backend:GEWUENSCHTE_COMMIT_SHA
```

Der Image-Workflow auf `main` publiziert `latest` und vollständige Commit-SHAs. Update kann
einen Tag, eine vollständige Referenz oder Prozess-ENV nutzen, z. B.
`FORM_IMAGE_TAG=GEWUENSCHTE_COMMIT_SHA deploy/swarm/update.sh`. Eine gespeicherte Digest-Referenz
bleibt ohne neue Auswahl erhalten. Kein stilles Registry-Raten nach Release-Namen.
Image wird gezogen und zum Digest fixiert; genau dieser Digest gilt für Migration und App.

Reihenfolge: exklusive Sperre → Netz/Secrets → DB-Client `SELECT 1` → genau eine Migration
mit neuem Image → erst bei Exitcode 0 App-Rollout → internes `/ready`. Die DB-Prüfung
verifiziert vorhandene DB und Anmeldung, nicht nur einen offenen TCP-Port. Setup erzeugt
keine DB; ausschließlich das anschließende ausdrücklich angeforderte `migrate` ändert das
Schema in der bestehenden Datenbank. Beim Update bedienen alte App-Replikate währenddessen
weiter Anfragen. Destruktive Schemaänderungen benötigen Wartungsfenster oder mehrere Releases.

Swarm führt `<STACK>_dbcheck` und `<STACK>_migrate` als einzelne Services ohne automatischen
Restart aus. Beide werden nach Erfolg entfernt; Migration ist kein Dauerdienst im Stack.
Es gibt keinen Infrastruktur-Stack und keine App-Replika vor erfolgreicher Erst-Migration.
Compose benutzt einen einmaligen DB-Client, anschließend `compose run --rm --no-deps migrate`
und `up --wait app`. Kein erneuter Start von Proxy/DB. Compose ersetzt die eine App mit kurzer
Unterbrechung. Der Healthcheck prüft `/ready` per Bash-TCP ohne curl im Image.

Deploy-Sperre Swarm: Config `<STACK>_deployment_lock`; Compose: Verzeichnis
`<ENV_DATEI>.deploy-lock`. Bei unklarem Migrations-/Rolloutstatus bleibt sie erhalten.
Vor Wiederholung Task/Container, Exitcode und Schema prüfen. Beispiele für Standard-Stack:

```bash
docker service ps --no-trunc form_migrate
docker service ps --no-trunc form_dbcheck
docker service inspect form_app --format '{{json .UpdateStatus}}'
sudo docker compose --env-file deploy/compose/.env -f deploy/compose/compose.yaml ps -a
```

Erst nach gesichertem Ende eigener Jobs/Rollouts übrig gebliebene Prüf-/Migrationsservices
gezielt entfernen und die eigene Sperre lösen (`docker config rm form_deployment_lock`
bzw. `sudo rmdir deploy/compose/.env.deploy-lock`). DB-Prüfung macht keine Schreiboperationen;
Migrations- und Rolloutabbrüche brauchen fachliche Prüfung. Kein globales Prune.

Die Env-Datei wird beim Update erst nach vollständigem Erfolg auf den neuen Digest gesetzt.
Nach einem Fehler kann die App bereits teilweise aktualisiert sein. Laufende Spezifikation
prüfen; eine alte Env-Datei beweist kein abgeschlossenes Rollback. Swarm:
`docker service rollback form_app` nur bei kompatiblem Schema, anschließend Status und `/ready`
prüfen und die Env-Datei passend nachführen. **Image-Rollback setzt kein Schema zurück.**
Compose kann nach Kompatibilitätsprüfung das vorige Image über `update.sh --image ...`
verwenden, dabei wird auch dessen Migration erneut gestartet. Bei inkompatiblem Schema
isolierten Restore mit passendem Image vorbereiten und kontrolliert umschalten.

## Umstieg: Schreibpause des Altsystems (ADR 0043)

Der Import ist ein Einmal-Snapshot, es gibt kein Delta. Das Altsystem muss von „Prüflauf starten“ bis zum Ende
des Imports (und bis zur Umschaltung) ruhen. Der Code prüft das: Der Prüflauf speichert einen
Quellen-Fingerabdruck (SHA-256 über `CHECKSUM TABLE` und `COUNT(*)` aller Tabellen; nur ein Hash im
Bericht). Der Import rechnet ihn vor dem ersten Schreiben und nach dem letzten Objekt neu. Abweichung vor dem
Schreiben: `source_changed`, nichts geschrieben, „Prüflauf wiederholen“. Abweichung während des Imports:
`source_not_quiesced`, Lauf `failed`, Ziel aus der Sicherung wiederherstellen. Anderer Snapshot-Hash auf bestehendem
Namespace: `snapshot_changed`. Das Quell-Konto braucht nur `SELECT`. Die Messung liest jede Tabelle einmal
vollständig (je Messpunkt etwa so lange wie das Zählen der Zeilen). Details: `docs/UMSTIEG-CHECKLISTE.md`.

## Aufbewahrung nach dem Umstieg (QA 13.11.2026)

Importierte Einsendungen tragen keine Löschfrist (`retention_due_at = NULL`) und werden vom Aufbewahrungsjob nicht angefasst.
Der Prüf-/Importbericht nennt, wie viele bei der Standardfrist (3 Tage) sofort fällig wären. Frist bewusst setzen: Formular,
Datenschutz, Aufbewahrung; nur mit dem Häkchen „auch auf importierte Einsendungen anwenden“ (Bestätigung mit Zahl der sofort
fälligen) wirkt sie auf importierte Einsendungen und löscht endgültig. Vor dem Import immer eine Sicherung der Ziel-Datenbank
(UMSTIEG-CHECKLISTE, Rollback). `migrate` führt das Upgrade `0035-imported-no-retention` aus (idempotent).

## Mailserver mit selbstsigniertem Zertifikat (ADR 0044)

Je SMTP-Verbindung kann die Zertifikatsprüfung abgeschaltet werden („Eigene/selbstsignierte Zertifikate erlauben“, `verifyCertificate:false`),
auch im Produktivbetrieb und ohne `FORM_ALLOW_INSECURE_DEV`. Standard ist „prüfen“. Die Verbindung bleibt TLS/STARTTLS-verschlüsselt (kein Klartext-Rückfall;
`security: plain` bleibt nur mit Entwicklungsschalter). Anlegen und Zurückschalten brauchen `system.manage` plus frische Anmeldung und werden im Audit
protokolliert (`connection.tls-verification-off` / `connection.tls-verification-on`, nur mit Verbindungs-ID). Zurückschalten per PWA (Verbindungen, Menü der Zeile) oder
`PUT /connections/{id}/tls-verification`. Beim Umstieg wird der Altwert `SMTPallowSelfSigned = 1` übernommen. Übernommene Verbindungen sind deaktiviert; „Verbindung aktivieren“ (`PUT /connections/{id}/enabled`, `system.manage`, frische Anmeldung, Audit `connection.enable`, bei abgeschalteter Prüfung zusätzlich `connection.tls-verification-off`) prüft die Konfiguration und wandelt Altformat-Zeilen einmalig um (`docs/UMSTIEG-CHECKLISTE.md` Nr. 6a). Betrieb: ausgeschaltete Prüfungen in der
Verbindungsliste („Zertifikat wird nicht geprüft“) regelmäßig durchsehen; wo möglich die CA des Mailservers statt der Abschaltung bevorzugen.

## Backup/Restore gegen die externe DB

Skripte benötigen `FORM_DB_HOST`, `FORM_DB_PORT` (3306), `FORM_DB_USER` (form), `FORM_DB_NAME`
(form), `FORM_DB_TLS` (verify) und entweder `FORM_DB_PASSWORD_FILE` als **Hostdatei** oder
`FORM_DB_PASSWORD` aus der geschützten Prozessumgebung. Alternative `DB_PASSWORD_SOURCE_FILE`
hat dieselbe Host-Dateibedeutung und Vorrang vor dem Containerpfad. Beide Passwortquellen
zugleich werden abgelehnt. Es gibt kein `DB_CONTAINER`, kein Docker-exec in eine DB und
keinen impliziten Root-Login.

Standard `DB_CLIENT_MODE=docker`: `docker run --rm -i` mit `DB_CLIENT_IMAGE=mariadb:12.3`,
**nur Clientwerkzeuge**, kein Serverprozess. Passwortdatei wird read-only eingebunden und
innerhalb des Containers als `MYSQL_PWD` gelesen. Direkte Passwort-ENV wird vorübergehend
in einer 0600-Datei gemountet und nach Ende entfernt; keine Passwortwerte in Docker-Argumenten
oder Dumps. Docker-Daemon muss Hostdateien desselben Rechners sehen. `DB_CLIENT_NETWORK` kann
ein bereits vorhandenes attachable Netz wählen; sonst `NETWORK_NAME` oder Docker-Standardnetz.
`DB_CLIENT_MODE=local` nutzt installierte `mariadb`/`mariadb-dump` mit denselben TLS-Regeln.

```bash
export FORM_DB_HOST=mariadb.example.org FORM_DB_PORT=3306 FORM_DB_USER=form FORM_DB_NAME=form
export FORM_DB_TLS=verify FORM_DB_PASSWORD_FILE=/geschuetzt/db_password
scripts/backup-db.sh /geschuetzt/neues-backup --dry-run
scripts/backup-db.sh /geschuetzt/neues-backup
# Restore-Zugangsdaten separat mit CREATE-Recht für die neue DB bereitstellen.
# Bevorzugt auf einem isolierten Wiederherstellungsserver:
FORM_DB_HOST=restore-db.example.org FORM_DB_USER=restore_operator \
  FORM_DB_PASSWORD_FILE=/geschuetzt/restore_password \
  scripts/restore-db.sh /geschuetzt/neues-backup restore_probe
```

Schreibzugriffe und Hintergrundjobs für **Dump UND Zeilenzählung** pausieren; Ingress sperren
und App-Replikate stoppen/auf null skalieren. DDL verhindern. Das Skript erzwingt diese
Wartungspause nicht. Dump: `--single-transaction --quick --hex-blob`, Routinen, Events und
Trigger; Transaktionskonsistenz gilt für InnoDB. Benutzer braucht Leserechte und passende
Rechte für Metadaten/Routinen/Events; kein genereller Root-Zwang.

Backups sind **verschlüsselt (fail-closed)**. Ohne Empfänger bricht `backup-db.sh` vor dem
Dump ab. Bevorzugt age: `FORM_BACKUP_AGE_RECIPIENTS_FILE` (nur öffentliche Schlüssel `age1...`;
der private Schlüssel liegt nicht auf dem Server, sondern offline/beim Betreiber). Alternative gpg:
`FORM_BACKUP_GPG_RECIPIENT` plus `FORM_BACKUP_GPG_PUBKEY_FILE` (öffentlicher Schlüssel, wird in
ein temporäres Schlüsselbund importiert). Der Dump läuft per Pipe direkt in den Verschlüsseler
(umask 077); Klartext-SQL wird nie auf die Platte geschrieben. Nur für Entwicklung gibt es
`FORM_BACKUP_ALLOW_PLAINTEXT=1` (laute Warnung; Restore verlangt dieselbe Variable).

Neues Backupverzeichnis 0700 enthält `database.sql.age` bzw. `database.sql.gpg`, `counts.tsv`
(exakte Basistabellenzeilenzahlen, Tabellennamen im Klartext), `source-database`, `SHA256SUMS`
(deckt Chiffrat, Zählung und Quellnamen), Dateien 0600. Empfohlener Verzeichnisname:
`form-backup-YYYYMMDDTHHMMSSZ` (UTC; nur solche Namen verarbeitet `backup-prune.sh`).
DB-Benutzer/Grants und Server-Konfiguration separat sichern. App erst nach abgeschlossener
Sicherung wieder starten.

**Offsite** (`scripts/backup-offsite.sh BACKUP [--dry-run]`): `FORM_BACKUP_OFFSITE_METHOD=rclone|rsync`,
`FORM_BACKUP_OFFSITE_TARGET`. rclone: `rclone copy` + `rclone check` (deckt auch sftp-/S3-Ziele
über die rclone-Konfiguration); rsync: über ssh (`FORM_BACKUP_OFFSITE_SSH_OPTS`), danach
prüfsummenbasierter Vergleich. Das Skript prüft lokal die Prüfsummen vor dem Upload, verweigert
Klartext-Backups und fremde Dateien. Zielwahl ist Betreiberentscheidung. Kriterien: Standort EU,
AVV mit dem Anbieter, Verschlüsselung beim Betreiber (clientseitig, wie hier; serverseitige
Anbieterverschlüsselung allein genügt nicht), Append-only bzw. Objektsperre (Object Lock) wenn
möglich, damit ein kompromittierter Server Backups nicht löschen kann; Zugangsdaten des Ziels
nur mit Schreib-/Listenrecht, ohne Löschrecht.

**Aufbewahrung** (`scripts/backup-prune.sh WURZEL [--dry-run] [--offsite]`): löscht lokal
Backups älter als `FORM_BACKUP_RETENTION_DAYS`. **Standard 30 Tage ist nur eine Voreinstellung;
die Frist legt die Klinik fest (AVV § 12).** Alter kommt aus dem Verzeichnisnamen, das jüngste
Backup bleibt immer, andere Verzeichnisse und Namen ohne Muster oder `SHA256SUMS` werden nie
angefasst. `--offsite` löscht zusätzlich am rclone-Ziel; bei Objektsperre/Append-only regelt der
Anbieter per Lifecycle-Regel. Restore-Nachweis: `docs/betrieb/restore-probe-2026-11-12.md`,
wiederholbar mit `scripts/test-backup-crypto.sh` (Docker nötig, Wegwerf-DB).

Restore: age `FORM_BACKUP_AGE_IDENTITY_FILE` (privater Schlüssel nur auf dem
Wiederherstellungsrechner), gpg `FORM_BACKUP_GPG_HOME` (Schlüsselbund mit privatem Schlüssel,
Standard `~/.gnupg`). Entschlüsselung per Pipe ohne Klartextdatei; ein falscher Schlüssel
bricht vor `CREATE DATABASE` ab. Privaten Schlüssel getrennt vom Server und vom Offsite-Ziel
sichern (mindestens zwei Aufbewahrungsorte); ohne ihn sind alle Backups wertlos.

Restore prüft die Prüfsummen, verlangt `restore_*`, führt `CREATE DATABASE` ohne
`IF NOT EXISTS` aus und importiert erst danach in diese neue DB. Existiert sie bereits,
endet das Skript vor dem Import. Kein DROP oder Überschreiben vorhandener DBs. Bei Fehlern
bleibt die neue DB zur Prüfung erhalten; vor Wiederholung anderen neuen Namen wählen.
Nur vertrauenswürdige eigene Dumps verwenden: Routinen/Events/Views können qualifizierte
Quellverweise enthalten, deshalb isolierter Restore-Server und deaktivierter Event-Scheduler.
Prüfsummen beweisen keine Herkunft. Zeilenzahlen beweisen keine identischen Inhalte;
zusätzlich Constraints, Binärdaten, Schema, Entschlüsselung und Anmeldung prüfen.

## Datenschutz und Schlüsselwiederherstellung

**Server-Key separat verschlüsselt sichern und denselben Key zur DB wiederherstellen.**
Er schützt serverseitige Secrets und gespeicherte Verschlüsselungspakete. Ein neu erzeugter
Key macht vorhandene Chiffrate nicht lesbar. Swarm-Secrets können später nicht ausgelesen
werden; lokale Originale erst nach geprüftem Backup entfernen. Compose benötigt seine
Secret-Dateien weiter für den Betrieb. Browser-/Kontoschlüssel und Recovery-Codes separat
nach Anwendungskonzept sichern; der Server-Key ersetzt diese nicht.

RP-ID bindet Passkeys an die Domain; nicht als gewöhnlichen umbenennbaren Hostparameter
behandeln. Gleiche kontrollierte RP-Domain und Origin beim Wiederanlauf verwenden. Dumps
können personenbezogene Metadaten und verschlüsselte Inhalte enthalten. Zugriff begrenzen,
Offsite-Backups verschlüsseln, Löschfristen definieren; keine Daten, Secrets oder Debuglogs in Git.

## Branch-Export und Übergabe

`.github/workflows/deploy-branch.yml` läuft nach Übernahme auf `main`. Explizite Dateiliste:
Deploy-Skripte, Entrypoint, YAML-/ENV-Vorlagen, Betriebsskripte/Prüfskript, diese Datei, README,
Gitignore und LICENSE. README/Gitignore werden aus `deploy/branch/` an die Wurzel kopiert.
Nur bei inhaltlicher Änderung entsteht ein Commit, bestehender Branch wird linear ergänzt,
kein Force-Push. Im erzeugten Branch selbst ist der Workflow nicht nötig.

Nächster Schritt: Review, Wrapper-/Deploy-Dateien und Workflow bewusst auf `main` übernehmen,
Image-Integration dort separat vornehmen und isolierte Laufzeitprobe mit externer TLS-DB und
Proxy durchführen. Hier sind keine weiteren Worktrees geändert und keine Jobs aktiv.

## Lokale Prüfungen und Grenzen

Prüfbefehle:

```bash
for file in deploy/docker-entrypoint.sh deploy/swarm/*.sh deploy/compose/*.sh scripts/*.sh; do bash -n "$file"; done
shellcheck -x deploy/docker-entrypoint.sh deploy/swarm/*.sh deploy/compose/*.sh scripts/*.sh
python3 scripts/check-deploy.py
docker compose --profile tools --env-file deploy/compose/.env.example -f deploy/compose/compose.yaml config --quiet
# Swarm nutzt exportierte Defaults; initialize parst die Vorlage, ohne sie auszuführen:
bash -c 'set -euo pipefail; BASE="$PWD/deploy/swarm"; MODE=swarm; ACTION=setup; source deploy/swarm/lib.sh; initialize --dry-run --non-interactive; docker stack config -c deploy/swarm/stack.yaml >/dev/null'
```

Die Prüfungen decken Shell-Syntax/ShellCheck, Help/Trockenläufe, Docker-Konfigurationsrendering,
Environment-Inventar, Wrapper-Datei-/Secretverhalten und Kommando-Doubles für DB-Prüfung vor
Migration vor Rollout, Migrationsfehler ohne App-Update, Digest/0600, Backup-Prüfsummen und
Restore nur nach erfolgreicher Neuanlage ab. YAML-/Bash- und Exportprüfung des GitHub-Workflows
wurden lokal ausgeführt (21 erlaubte Exportdateien, keine lokalen Konfigurationen/Secrets),
ohne Ausführung auf GitHub. Zusätzlich wurden abweichende HTTP-/DB-Ports, Secret-/Wrapperpfade,
Netzname, Ressourcen und Swarm-Updateparameter im gerenderten Modell geprüft.

Der Zugriff auf den lokalen Docker-Socket war zuvor mit „permission denied“ abgewiesen.
Es gibt daher keinen behaupteten echten DB-/TLS-/Restore-/Swarm-/Proxy-Nachweis. Vor
Produktivbetrieb diese Integration inklusive Node-Ausfall, Rolling Update, fehlerhafter
Migration, Rollback und vollständiger Schlüssel-/DB-Wiederherstellung isoliert prüfen.

## MCP OAuth (P11-E, ADR 0022)

Bei getrennten öffentlichen/internen Domains `FORM_OAUTH_ISSUER` auf die öffentliche HTTPS-Origin
setzen. `FORM_OAUTH_AUTHORIZE_BASE_URL` ist die interne HTTPS-Admin-Origin (Default FORM_ADMIN_ORIGIN)
oder eine explizit aktivierte öffentliche Dashboard-Origin. Metadaten zeigen diese Origin als
Authorization-Endpoint; der Browser muss sie erreichen können. Beide Änderungen erfordern Neustart.
`FORM_ADMIN_REQUEST_LIMIT_IP` (Standard 600/min je Client-IP, alle Admin-Anfragen) und `FORM_ADMIN_REQUEST_LIMIT_ACCOUNT`
(Standard 300/min je angemeldetem Konto) begrenzen die Admin-API; ganze Zahl 1 bis 100000, sonst Startfehler, Neustart nötig.
Hinter Proxy/NAT teilen sich Nutzer eine IP, die SPA braucht rund 12 Aufrufe je Seitenladung; Anmelde- und Fehlversuchsgrenzen
bleiben unverändert. Bei Überschreitung zeigt die PWA „Zu viele Anfragen. Bitte in N Sekunden erneut versuchen.“
`FORM_MCP_TOKEN_RATE_LIMIT` überschreibt die DB-Einstellung `mcp.requestsPerMinute`, Default 60/min
je persönlichem oder OAuth-Access-Token. Clientprofil, DB-Upgradegrenze und Abnahme:
`docs/handoffs/P11-E.md`. Keine Header-/Body-/Tokenlogs für OAuth/MCP aktivieren.

## P11-G: Anmeldung je Listener (ADR 0022)

Intern reicht standardmäßig der Passkey mit Geräte-PIN/Biometrie.
`FORM_INTERNAL_SECOND_FACTOR=1` verlangt auch dort das Kontopasswort (ENV-only,
Neustart erforderlich; Standard `0`). Compose/Swarm und `_FILE` unterstützen
den Schalter. Öffentliches Dashboard verlangt immer Passkey plus Passwort.
Vor öffentlicher Freigabe für bestehende Konten ohne Passwort dieses nach interner
Anmeldung unter Konto setzen. Bootstrap generiert nur bei aktiver Faktorpflicht
ein Startpasswort; `FORM_BOOTSTRAP_PASSWORD_FILE` bleibt optional explizit nutzbar.

Beim Upgrade werden bestehende Sitzungen ungültig. Internes Cookie gilt öffentlich
nicht, auch bei gleichem Host. Interner Port muss per Netz/Firewall/Proxy begrenzt
bleiben: Passkey-/Gerätekompromittierung hat ohne unabhängiges Passwort größere
Folgen. Vollständige Risikobewertung und Schutzmaßnahmen: ADR 0022.

## Deploy-ENV-Erweiterung (Todolino 8B72B9D6, 03.11.2026)

Die Inventare spiegeln alle nichtleeren ENV-Namen aus
`backend/Sources/FormCore/SettingsRegistry.swift`: Betriebsalarme, Missbrauchsschutz,
Mail-Empfängerschranke, Migrationsnetze, Webhookquoten, MCP-Tokenlimit und OAuth.
Optionale Registry-ENVs sind auskommentiert: fehlend bedeutet ENV > **DB > Default**,
gesetzt (auch leer) bedeutet ENV gewinnt und sperrt die PWA-Einstellung. Die beim
Deploy erforderlichen `FORM_ADMIN_ORIGIN` und `FORM_RP_ID` bleiben bewusst ENV-gepinnt.
`FORM_LOG_LEVEL`, Mail-Netze und SDK-Pfad sind jetzt ebenfalls optional. Alte gespeicherte
ENVs bleiben wirksam; zum Freigeben für die PWA die betreffenden Zeilen entfernen.
`setup.completed`, `setup.step`, `setup.mailPending` und `migration.enabled` haben
keine ENV-Namen: über die autorisierte interne Settings-API/PWA bearbeiten, keine
erfundenen Deploy-Schalter. `FORM_MIGRATION_ALLOWED_NETS` ist standardmäßig nicht
gesetzt und damit leer/gesperrt für Quellverbindungen; nur konkrete freigegebene Netze
eintragen. Das ist weder ein Importstart noch eine Cutoverfreigabe (ADR 0030).

Optionale YAML-Environment-Einträge ohne Wert übernehmen nur vorhandene Prozess-ENVs.
Die Skripte exportieren und speichern nur ausdrücklich gesetzte optionale Werte.
Auskommentierte Inventarwerte sind Beispiele, keine stillen Laufzeitdefaults.
JSON-Listen können in der Env-Datei mit einfachen Quotes umschlossen werden;
Werte mit gleichzeitig einfachen und doppelten Quotes unterstützt der Deploy-Parser nicht.
Die aufgelisteten skalaren Einstellungen unterstützen gemountete `*_FILE`-Overrides;
Pfade sind Containerpfade, zusätzliche Mounts/Configs müssen Betreiber ergänzen.

**Ausnahme Ports:** `FORM_PUBLIC_PORT_FILE` und
`FORM_INTERNAL_PORT_FILE` werden von Deploy-Skripten und Entrypoint abgelehnt,
bevor die App startet. Sie werden nicht in YAML weitergereicht. Ports ausschließlich
direkt setzen, damit Portfreigabe, Healthcheck und Listener dieselben Werte verwenden.
Ein nachträglicher Datei-Override könnte sonst den internen Listener auf das öffentliche
Portziel verschieben. Beim Umstieg entsprechende Dateivariablen entfernen und die
gewünschten Werte direkt eintragen. Andere Datei-Overrides bleiben verfügbar.
