# ADR 0020: Öffentlicher und interner Listener

Datum: 03.11.2026. Status: beschlossen durch Nutzerauftrag P11-A.
Todolino: B2ED9B9A-6F39-4F80-8F7B-EDC37166849B.

## Anlass und Entscheidung

Öffentliche Protokolle dürfen keinen durch Host-Manipulation erreichbaren Verwaltungsrouter
besitzen. Eine Vapor-Application betreibt deshalb zwei HTTPServer mit getrennten, beim Start
erfassten Routen-/Middleware-Beständen. DB-Pool, Eventloops, Konfiguration, SecretStore,
Dienste und Scheduler existieren jeweils einmal. Die Porttrennung hängt nicht vom Host ab.

Öffentlich (`FORM_PUBLIC_PORT`, 8080): Ingest einschließlich index.php-Alias, Statistik-Collector,
MCP und vorhandene Protected-Resource-Metadaten, `/healthz`. Intern (`FORM_INTERNAL_PORT`, 8081):
PWA, Admin-API, übrige Routen einschließlich Readiness und bisheriger `/health`-Route.
**Ingest, Collector und MCP sind ausschließlich öffentlich**, intern 404. Beide Ports bieten
`/healthz`. `FORM_HTTP_PORT` war anfangs Fallback für den internen Port und ist seit 07.11.2026 entfernt
(nur noch `FORM_INTERNAL_PORT`). Gleiche Ports sind ein Startfehler. Beide binden an `FORM_HTTP_HOST`.
CLI-Bind-/Port-Overrides werden abgewiesen, damit sie diesen Vertrag nicht überschreiben.
Beim Fehler des zweiten Bindings wird der bereits gestartete erste Server geschlossen;
beim Shutdown werden beide vor der gemeinsamen Application heruntergefahren.

MCP erhält ausdrücklich den internen Responder für bereits autorisierte interne Tool-Aufrufe.
Dieser wird nicht als öffentlicher Router verwendet. Autorisierung/Fachlogik bleiben gemeinsam.
`FormAdmin.registerPublic` bietet einen Callback zur Registrierung künftiger öffentlicher
OAuth-Routen (`/.well-known`, `/oauth/token`, `/oauth/register`). Keine OAuth-Implementierung
oder öffentliche Autorisierungs-/Consent-Seite in P11-A.

## Öffentliches Dashboard

Standard aus. `FORM_PUBLIC_DASHBOARD=1` registriert Admin-API und PWA zusätzlich öffentlich;
es erfordert eine explizite gültige `FORM_PUBLIC_DASHBOARD_HOSTS`-Liste beim Konfigurationslesen.
Exakte Hosts ohne Schema/Port/Wildcards. Die Dashboard-Middleware lässt nur gelistete Hosts zu;
vorhandene Origins müssen HTTPS und identisch mit der effektiven Host-Authority sein. Danach
bleiben Sitzung, CSRF-Token und Rechteprüfung erforderlich. Öffentliche Cookie-Mutationen
akzeptieren nur Origins gelisteter Hosts; intern gilt weiterhin die genaue Admin-Origin.
Öffentliche Protokollrouten sind vom Dashboard-Hostfilter ausgenommen. Die Hostliste erweitert
keine WebAuthn-Origin; Passkeys bleiben an FORM_ADMIN_ORIGIN/RP-ID gebunden.

Je Listener gelten eigene Trusted-Proxy-CIDRs (`FORM_PUBLIC_TRUSTED_PROXIES`,
`FORM_INTERNAL_TRUSTED_PROXIES`); fehlen sie, greift `FORM_TRUSTED_PROXIES` als Legacy-Fallback.
Explizit leer schaltet Vertrauen ab. Öffentliche Dashboard-Forwarded-Hosts werden ausschließlich
von vertrauenswürdigen Socket-Peers mit eindeutigem HTTPS-Proto/Host akzeptiert. Doppelte
Host-/Origin-Header und hostübergreifende Origins sind verboten.

## Betrieb und Folgen

Swarm und Compose erhalten `<stack>-public` und `<stack>-internal`. Aliasse isolieren keine
Netze; Proxy-Upstreams müssen den richtigen Port wählen. Healthcheck intern über `/ready`,
Liveness beidseitig über `/healthz`. Optional je Port veröffentlichen, standardmäßig keine
Hostfreigabe. Bestehende Veröffentlichungsnamen bleiben interne Ziele; neue öffentliche
Veröffentlichungsvariablen siehe BETRIEB. Alte Einport-Konfiguration mit 8080 benötigt einen
expliziten Portwechsel, um die neue Default-Kollision zu vermeiden. Keine Schemaänderung.

Abnahme: echte Routenregistrierungen mit XCTVapor ohne DB-Zugriff, Host-/Proxy-Negativfälle,
Konfigurationsfehler und Build einschließlich aller Tests. DB-, reale Socket-/Proxy-/Swarm-
Laufzeitabnahme und unabhängiges Sicherheitsreview bleiben separat erforderlich.

## Deploy-Härtung 03.11.2026 (Audit 8B72B9D6)

Die Wrapper-Erweiterungen FORM_PUBLIC_PORT_FILE und
FORM_INTERNAL_PORT_FILE entfallen: Entrypoint und Deploy-Validierung lehnen
nichtleere Angaben ab. Container-Portziele werden vor dem Appstart gerendert;
eine erst danach eingelesene Datei könnte öffentlichen und internen Listener
vertauschen. Direkte Port-ENVs bleiben der gemeinsame Vertrag für Rendering,
App und Healthcheck. Keine Änderung an AppConfig oder Listener-Routing.

Per-Listener-Proxy-ENVs bleiben in Vorlagen standardmäßig ungesetzt (optionales
ENV-Passthrough), damit der Legacy-Fallback inklusive FORM_TRUSTED_PROXIES_FILE
wirksam bleibt. Explizit leer ist weiterhin eine bewusste Vertrauenssperre.
Gespeicherte Altdateien mit leeren Listener-Listen benötigen eine manuelle
Bereinigung, wenn der Legacy-Fallback gewünscht ist. Gründe, Umstieg und
konkrete Proxy-CIDR-Beispiele: docs/BETRIEB.md.
