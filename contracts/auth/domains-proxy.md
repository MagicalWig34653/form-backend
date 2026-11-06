# Domains, feste Admin-Domain und Proxyvertrauen

Stand: 26.10.2026. SPDX-License-Identifier: AGPL-3.0-only.
**BESCHLOSSEN** (ADR 0003 Nr. 8/12): Administrator trägt Domains manuell ein,
kein DNS-Besitznachweis; Proxy/TLS extern; Host nur aus vertrauenswürdig
konfiguriertem Proxy; Admin-Domain und RP-ID beim Umstieg unverändert.
Die folgenden Details sind **VORGESCHLAGEN**.

## Domainzuordnung und Admin-Origin

Datensatz: `id`, `tenantId`, normalisierter `hostname`, `formId`, `viewId`,
`releaseId` (vor aktiver Auslieferung), `mode=testing|production`, `enabled`,
`revision`, Änderungsakteur/-zeit. Formular, Ansicht und Release gehören zum
selben Kunden. Hostname als IDNA-ASCII in Kleinbuchstaben, ohne Port, Pfad,
Benutzerinfo, Wildcard oder abschließenden Punkt speichern. Unicodeverarbeitung
und Kollisionsregeln vor Implementierung durch Bibliothekswahl konkretisieren.
ADR 0004 H04: Ein Ansichtshost gehört eindeutig zu genau einem Formular; konkurrierende Belegung ergibt 409
über eindeutigen DB-Constraint, keine Übernahme durch erneutes Speichern.

Getrennte Datensätze: `domain_bindings` ausschließlich Ansichtshosts mit
UNIQUE(host_ascii), `api_hosts` globale explizit erlaubte API-Hosts und
`api_host_forms` deren Formularallowlist. Gemeinsamer API-Host darf viele
Formulare bedienen. Er löst den Kunden niemals allein aus Host auf: zuerst
Formular-ID laden, registrierten formularbezogenen Signaturschlüssel prüfen,
danach Formular-/Hostfreigabe und Herkunft prüfen. Ungültige Signatur niemals
auf anderes Formular oder eine Hostdefaultzuordnung zurückfallen lassen.
Ansichtshost und gemeinsamer API-Host werden nicht vermischt; Neuzuordnung eines
Ansichtshosts erst nach ausdrücklich aufgehobener alter Bindung, kein Upsert.

Nur `domain.manage` und menschliche Bestätigung dürfen registrieren, ändern,
deaktivieren. Neuanlage ist inaktiv/testing; produktive Zuweisung verlangt ein
bereits menschlich bestätigtes Release und eine neue explizite Bestätigung.
Zuordnung darf keine ungeprüften Entwürfe live schalten. Hostwechsel oder Release-
Wechsel invalidiert ausstehende Bestätigungen. Keine Mandantenauswahl aus
Queryparameter, beliebigem Origin, Tokenbehauptung oder angegebener tenantId.

Admin-Origin ist eine separate feste Betriebsgröße; weder Kundenhost noch
Formularzuordnung kann Login, OAuth-Aussteller, Redirectbasis oder RP-ID verändern.
Admin-REST, PWA-Kontoseiten, MCP und OAuth nur dort erreichbar. Kundenhosts liefern
nur freigegebene Formularansichten und freigegebene öffentliche Eingangsrouten,
keine Verwaltungsrouten oder Admincookies. Adminhost darf nicht als Kundendomain
registriert werden. Unbekannter/deaktivierter Host: 421, kein Redirect anhand
eines untrusted Hosts; unbekannte Ressource: 404. Caches nach Host UND Release
trennen, Verwaltungsantworten nicht cachen.

Bestehende RP-ID und Origin müssen vor Cutover aus freigegebener Betriebskonfiguration
übernommen werden; konkrete Werte sind **OFFEN**, kein Beispielwert ersetzt sie.
Gezielter Altbeleg: `providers/Passkey.php:82` liest `app.rp_id`, sonst SERVER_NAME;
`:233` liest `app.origin`, sonst HTTPS plus RP-ID. Neubau verlangt explizite Werte,
keinen Requestfallback. Origin exakter konfigurierter Scheme/Host/Port-Vergleich,
RP-ID separat ohne Scheme/Port. Keine Suffixprüfung oder automatische Erweiterung
auf Kundenhosts. Passkeys, UserHandles und PRF-Wraps müssen unverändert nutzbar
bleiben (Abnahme in P3/P9, derzeit nicht getestet).

## Eingang am externen Proxy

**VORGESCHLAGEN: genau ein expliziter Headervertrag** statt mehrdeutiger Auswertung
von `Forwarded` und `X-Forwarded-*` gleichzeitig:

| Quelle / Header | Vertrag |
| --- | --- |
| Socket-Peer | Nur freigegebene CIDRs bzw. konkret vereinbarte Proxyidentität; Liste **OFFEN**. DB/Rate-Limit verwendet Peer vor Headerauswertung. |
| `X-Forwarded-Host` | Proxy setzt genau einen validierten externen Authority-Wert; kein Komma/keine Liste, Steuerzeichen, Userinfo oder Pfad. Nur konfigurierte Hosts zulassen. |
| `X-Forwarded-Proto` | Genau `https`; extern HTTP wird am Proxy beendet/umgeleitet. |
| `X-Real-IP` | Genau eine syntaktisch gültige IPv4/IPv6 des Clients, am äußersten vertrauenswürdigen Rand bestimmt; keine Liste. |
| `Host` / HTTP/2 `:authority` | Backendinterne Authority nur Transportinformation; niemals alleinige Quelle für externe Hostauflösung. Doppelte/widersprüchliche Authority am Rand ablehnen. |
| `Forwarded`, `X-Forwarded-For`, `X-Forwarded-Port` | In diesem Profil nicht als zweite Quelle verwenden; Proxy entfernt clientgelieferte Varianten und setzt nur vereinbarte Header. |
| `CLIENTIP-ENCRYPT`, `CLIENTUA-ENCRYPT` | SDK-Metadaten aus Ingestvertrag, kein Proxyvertrauensanker; dürfen Adminlimits, CSRF, Origin oder Passkey-Netzausnahme nicht beeinflussen. |

Untrusted Peer: Header nicht verwenden, Anfrage zum Anwendungslistener ablehnen
(403). Vertrauenswürdiger Peer mit fehlendem, mehrfach vorhandenem oder fehlerhaftem
Pflichtheader: 400; wohlgeformter unbekannter Host: 421. Keine implizite
Vertrauensfreigabe für alle privaten Netze/Swarm-Peers. Betrieb sperrt direkten
öffentlichen Listenerzugriff. Bei mehreren Proxyhops muss der letzte Peer
clientgelieferte Werte überschreiben und den äußersten Client aus einer explizit
vertrauenswürdigen Kette bestimmen; Kettenalgorithmus und Netze **OFFEN**, bis dahin
keine Freigabe mehrstufiger Deployments. Interne Healthchecks können einen separaten
Listener ohne Mandanten-/Adminrouting erhalten; das ist ebenfalls VORGESCHLAGEN.

Host/Origin-Allowlist allein beweist keinen Domainbesitz. Sie ergänzt die
beschlossene Ed25519-Pflicht und Herkunftsautorisierung aus Ingest. Nichtbrowser
können Origin frei setzen; fehlender Origin im SDK-Pfad ist kein Ersatz für
Signaturprüfung. Admin-CSRF prüft feste Admin-Origin unabhängig vom Proxyhost.
Weiterleitungen, absolute Links und OAuth-Metadaten werden aus festen zulässigen
Betriebswerten erzeugt, nie ungeprüft aus Headern.

## Erforderliche Abnahme

Fremder Peer mit gefälschtem Host/IP, fehlender Header, Hostliste, Konflikt bei
Zuordnung, falsche Ansicht/Kunde, Adminhost als Kundenhost, gespoofte MFA-Netzausnahme,
CRLF/Unicode/Port-Varianten und Zugriff auf Adminpfade über Kundendomains ablehnen.
RP-ID/Origin und bestehendes Credential samt PRF-Zugang über Proxy unverändert
gegen synthetische Migrationsfixtures und reale Browser testen. Keine solchen
Laufzeitprüfungen sind in diesem Dokumentationspaket erfolgt.

## Vertragsrunde 3 — R01: Auslieferungsstand der Domainbindung (VORGESCHLAGEN)

Stand 28.10.2026. Persistenz: `domain_bindings` mit `release_id`, `view_id`
(zusammengesetzter FK auf `release_views`, damit Kunde/Formular/Release/Ansicht
konsistent sind), `revision`, `changed_by/changed_at` und `confirmation_audit_id`
(`../data/schema-entwurf.sql`).

- **Auslieferung:** Ein Ansichtshost liefert genau `(release_id, view_id)` seiner
  aktiven Bindung. `forms.current_release_id` wird für Hostauslieferung nie
  herangezogen und überschreibt eine bestätigte Bindung nicht. Eine neue
  Veröffentlichung ändert keine Domainbindung; eine Bindung wird nur durch
  `updateDomain` (`domain.manage`, menschliche Bestätigung) auf ein anderes
  bestätigtes Release gelegt. Der Bestätigungsdialog der Veröffentlichung darf die
  Umstellung betroffener Produktivdomains als zusätzliche, ausdrücklich bestätigte
  Aktion anbieten; dann laufen beide Änderungen in einer Transaktion.
  **BESCHLOSSEN ADR 0005 D1:** Eine Domain folgt einem neuen Release nicht
  automatisch; die Umstellung erfolgt bewusst (bestätigte Domainänderung, optional
  im Dialog der Veröffentlichung).
- **Aktivierung:** `enabled=1` verlangt `release_id` und `view_id`
  (DB-CHECK; OpenAPI `DomainInput` verlangt `releaseId` bei `enabled=true`).
  Produktiv zusätzlich Audit-Beleg der Bestätigung dieser `revision`. `testing` ist
  ohne produktive Bestätigung nur mit einem Release des Formulars zulässig und liefert
  nie produktive Antworten.
- **Atomarer Wechsel:** eine Transaktion mit `SELECT … FOR UPDATE` der Bindung;
  `If-Match` = `revision`; Release/Ansicht gegen `releases`/`release_views` des
  Kunden/Formulars prüfen; Bestätigung ist an `(domainId, revision,
  hostname, releaseId, viewId)` gebunden und wird mit dem Schreiben verbraucht;
  `revision+1`; Audit. Ein konkurrierender Host- oder Releasewechsel erhöht die
  Revision, die ausstehende Bestätigung ist damit ungültig (412/409), ohne weiteren
  Löschvorgang.
- **Inaktive Bindung:** `enabled=0` liefert 421; Release/Ansicht bleiben als
  Belegzeile erhalten und werden bei Reaktivierung neu bestätigt (neue Revision).
- **Rollback eines Releases:** die Domain bleibt auf ihrem gebundenen Release,
  bis sie bewusst umgestellt wird.
- **Abnahme (nicht ausgeführt):** zwei Replikas ändern gleichzeitig Host und Release;
  Veröffentlichung während ausstehender Domainbestätigung; Ansicht eines
  fremden Releases wird abgelehnt; Auslieferung ändert sich nicht durch
  `forms.current_release_id`.

## ADR 0005 D1 — Release-Bindung auch für Zugriffsadressen (API-/Ingest-Hosts)

Stand 29.10.2026. **BESCHLOSSEN (ADR 0005 D1):** Domain folgt Release nicht
automatisch; die Release-Bindung muss auch an Zugriffsserver/Zugriffsadressen
(API-/Ingest-Hosts) koppelbar sein. **Die Form der Kopplung unten ist
VORGESCHLAGEN** (Review nötig, keine Produktentscheidung über das ADR hinaus).

- **Modell:** Die Bindung liegt je (API-Host, Formular) in `api_host_forms`
  (`release_id` NULL-fähig, `binding_revision`, `changed_by/changed_at`,
  `confirmation_audit_id`), nicht am Host allein, weil ein gemeinsamer API-Host
  mehrere Formulare bedient (ADR 0004 Nr. 5 / H04). `release_id` NULL =
  ungebunden (bisheriger Ingestvertrag, keine neue Zusage); gesetzt = gebunden.
  Zusammengesetzter FK `(customer_id, form_id, release_id)` auf `releases`
  stellt Kunde/Formular/Release-Konsistenz her. Der Host selbst (`api_hosts`)
  behält `enabled`/`revision` für die Hostfreigabe; Bindungsänderungen laufen
  über `binding_revision` der Zeile, damit parallele Änderungen verschiedener
  Formulare am selben Host sich nicht gegenseitig invalidieren.
- **Auflösung (gemeinsamer API-Host, vereinbar mit ADR 0004 Nr. 5):** (1) Formular-ID
  aus der signierten Anfrage laden, (2) registrierten formularbezogenen
  Signaturschlüssel prüfen, (3) `api_hosts.enabled` und Zeile in `api_host_forms`
  für (Host, Formular) prüfen, (4) Herkunft prüfen, (5) erst dann die Bindung der
  Zeile anwenden. Fehlende Zeile → Ablehnung wie bisher; ungültige Signatur fällt
  nie auf ein anderes Formular zurück. Der Host wird nie zur Kundenauflösung
  benutzt, eine Bindung gibt dem Host keine Mandanteneigenschaft.
- **Auslieferungsregel:** Für eine gebundene Zeile werden Formularkonfiguration
  und Antworten dieses Hosts (insbesondere Formularabruf `/form/` und die für die
  Einsendung maßgebliche Formularversion) ausschließlich aus `release_id` der
  Zeile genommen. `forms.current_release_id` wird für gebundene Hosts **nie**
  herangezogen und überschreibt die Bindung nicht. Ein gebundenes Release, das
  nicht mehr auslieferbar ist (zurückgezogen/widerrufen), liefert 421/Ablehnung
  mit Audit, kein stiller Rückfall auf `current_release_id`. Für ungebundene
  Zeilen ändert dieser Vorschlag den bisherigen Ingestvertrag nicht.
- **Ansichtshost und API-Host bleiben getrennt;** gleiche Hostnamen sind in beiden
  Tabellen nicht erlaubt (Dienstprüfung, vor Implementierung per Constraint oder
  Transaktionsregel zu sichern). Caches nach Host, Formular UND Release trennen.
- **Ändern der Bindung:** `configureApiHost` (`domain.manage`, menschliche
  Bestätigung) mit `releaseBindings[]` (`ApiHostReleaseBinding`: `formId`,
  `releaseId` oder null zum Lösen, `expectedBindingRevision`). Eine Transaktion:
  Zeilen `FOR UPDATE`, Revision prüfen, Release gegen Kunde/Formular prüfen und
  menschlich bestätigt voraussetzen, Bestätigung an `(apiHostId, formId,
  expectedBindingRevision, releaseId)` binden und verbrauchen,
  `binding_revision+1`, Audit. Neuanlage ist ungebunden. Konkurrierende Änderung
  → 409/412, ausstehende Bestätigung ungültig.
- **Veröffentlichungsdialog:** `PublishInput.rebind` kann sowohl Ansichtsdomains
  (`domains`) als auch API-Host-Bindungen (`apiHostBindings`) ausdrücklich
  mitumstellen; die Hash-Bestätigung deckt die Zielliste ein, alles läuft in einer
  Transaktion. Ohne `rebind` ändert eine Veröffentlichung keine Bindung.
- **Abnahme (nicht ausgeführt):** Veröffentlichung ändert weder Domain- noch
  API-Host-Auslieferung; zwei Replikas ändern gleichzeitig Bindung und Release
  (eine verliert mit 409/412); gebundener API-Host liefert Release A während
  `current_release_id`=B; fremdes Release wird abgelehnt (422); Signatur eines
  Formulars fällt nie auf Hostbindung eines anderen zurück; ungebundener Host
  verhält sich unverändert; Bestätigungsdialog mit `rebind`-Liste atomar.
