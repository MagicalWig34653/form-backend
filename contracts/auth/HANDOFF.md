# Übergabe P2-5

Stand: 26.10.2026. SPDX-License-Identifier: AGPL-3.0-only.

## Ergebnis und Dateibesitz

Vertragsentwurf ausschließlich unter `contracts/auth/`: README, Rollenmatrix,
Anmeldung/Sitzungen, OpenAPI, MCP/Token/OAuth, Domain-/Proxyvertrag und dieses
Handoff; zusätzlich ein Offline-Prüfskript. OpenAPI: 55 Ressourcenpfade mit
66 Operationen; jede Operation hat Aktionsrechte und fachliche Altzuordnung oder
explizit „NEU“. Bestätigte Nutzerentscheidungen sind von **VORGESCHLAGENEN**
Feinrechten, Werten und Protokolldetails getrennt. Keine Produktimplementierung,
kein abgeschlossener P3-Durchstich und keine Produktionsfreigabe.

Ein schreibender Agent, keine Delegation, keine weiteren Reservierungen oder
laufenden Jobs/Prozesse. Bestehender Checkout auf `main`, kein neuer Branch oder
Worktree, kein Commit/Remote. Die ausdrückliche Schreibgrenze umfasst keine
Git-Metadaten. Vor Arbeitsbeginn waren Projektdateien unversioniert; nichts davon
gestaged, gelöscht oder übernommen. Ausschließlich Dateien unter `contracts/auth/`
neu geschrieben. STATUS, ARBEITSPLAN und ADRs bleiben wegen der ausdrücklichen
Auftragsgrenze unverändert; dieses Handoff sichert den Fortsetzungsstand.

Gelesen: AGENTS, STATUS, ARBEITSPLAN, ENTWICKLUNG, ADR 0001–0003, ANFORDERUNGEN,
SICHERHEIT-UND-DATEN, PARITAET und A/review-A/B; ergänzend bestehende P2-Ingest-/Flow-
Verweise, Flow-Release-/Graph-/Form-/Debugschemas und synthetisches Releasebeispiel.
Gezielte statische Altlektüre von `providers/FormAccess.php` und
`providers/Passkey.php` unter `form-backend_bvk`, keine Ausführung oder Änderung.
`secrets/`, produktive Konfiguration, Kundendatensätze und reale Schlüssel wurden
nicht geöffnet oder übernommen.

## Tatsächlich ausgeführte Prüfungen

Befehl: `python3 contracts/auth/validate.py` mit bereits lokal vorhandenen
PyYAML/jsonschema/referencing/jsonschema-specifications; nichts installiert,
kein Netzwerk. Letzter Lauf erfolgreich:

- YAML geladen, doppelte YAML-Schlüssel ausgeschlossen, eindeutige operationIds,
  66 Operationen und ihre Pfadparameter, deklarierte Rechte/Scopes gegen Matrix,
  CSRF-Parameter aller Mutationen und Sitzungsbindung menschlicher Aktionen geprüft.
- 981 Referenzvorkommen rekursiv aufgelöst, sieben lokale Dokumente einschließlich
  OpenAPI und Flowreferenzen. Ein öffentliches Draft-2020-12-Metaschema wird aus
  lokal installierten Bibliotheksressourcen verwendet; kein Onlineabruf.
- Alle Komponenten-Schemas gegen Draft-2020-12-Metaschema geprüft.
- 29 gezielte gültige/ungültige Payloadfälle geprüft: Releasebestätigung fehlt,
  Hash/Revision/UUID falsch, zusätzliche actorKind-/confirmed-Eigenschaften,
  unzulässiger Veröffentlichungs-Scope, Tokenfrist/Bereich, TOTP-/Faktorform,
  Debugmodus/Klartextfeld, produktive Domainneuanlage und doppelte Export-IDs.
  Synthetisches P2-4-Release akzeptiert, actorKind=token durch dessen Schema abgelehnt.

Kein vollständiger OpenAPI-Spezifikationsvalidator lokal verfügbar; keine solche
Validierung behauptet. Schema-/Deklarationsprüfungen belegen keine korrekte
Autorisierungsimplementierung. Keine DB-, Mehrreplika-, HTTP-, Browser-, WebAuthn-,
OAuth- oder Verschlüsselungsintegration getestet. Das Projekt hat weiterhin
keinen Anwendungsbuild und keine implementierte Authentifizierung.

## Offene Entscheidungen und Integrationsgrenzen

1. Matrix inklusive Betreuer-Entwurfsrechten, kundenseitigen G-Rechten,
   Veröffentlichung durch zugewiesene Betreuer, Export-/Lösch-/Debugrechten
   abnehmen. Keine dieser Feinheiten als bestehende Nutzerfreigabe behandeln.
2. Alle vorgeschlagenen Lockout-/Backoff-/Raten-/Sitzungs-/Tokenwerte bestätigen;
   insbesondere Abweichung von langer „remember me“-Sitzung des Altbestands,
   MFA-Pflicht und Notfall-/Passwortwiederherstellung entscheiden.
3. Unveränderte tatsächliche Admin-Origin/RP-ID vor Cutover aus gesondert
   freigegebener Betriebskonfiguration übernehmen; hier bewusst keine Werte
   geraten. Trusted-Proxy-CIDRs und ggf. mehrstufige Headerkette festlegen.
4. Mit P2-2/P2-3 abstimmen: Kundenschlüsselgenerationen, verschlüsselte Wrapformate,
   Schlüsselzugang und -entzug, exportierte Chiffrate/Anhänge, Debugklartexthüllen,
   Hold/Nachschutz, Audit-/Jobtransaktionen und Löschzustände für S3/SFTP.
   Insbesondere Resend-Originalbindung: sourceHash ist kein kryptografischer
   Nachweis, dass Browserklartext zum Original gehört. Kein fertiger Sicherheits-
   oder Implementierungsvertrag für diesen Teil vorgeben.
5. P2-4-Abgleich: Kandidatenhash-/Revisionsbildung, Unveränderlichkeit, Bindung von
   Formular/Ansicht/Graph/Modulen/Testzielen und Produktionswebhooks an Release;
   Test-/Debugmodus darf test.run bzw. Testsandbox nicht umgehen. Serverseitige
   publication-Metadaten dürfen nicht aus einem importierten Paket autorisiert werden.
6. MCP-Transport-/Versionsprofil, Zielclient-Kompatibilität, OAuth-Ressource für
   denselben REST/MCP-Resource-Server, Redirect-Allowlist und optionale Loopback-
   Clients vor Implementierung mit aktuellen offiziellen Spezifikationen prüfen.
   Alten Grants/Token niemals Schreibrechte automatisch hinzufügen.
7. OpenAPI-Listenantworten sind bewusst Ressourcenprojektionen, WebAuthn-Bodies
   bewusst vorläufige Objekte: genaue DTOs, Filter, Pagination, Attachmentencoding,
   Exportjob-TTL, Testresultate und Bytegrenzen in Folgepaketen konkretisieren.
   Danach vollständigen OpenAPI-Validator einsetzen. Die vorhandenen statischen
   Prüfungen ersetzen diesen Schritt nicht.

## Noch auszuarbeitende Paritätsaktionen, keine Streichungen

| Altbereich | Hier enthalten | Offene REST-Detailoperationen / Anschluss |
| --- | --- | --- |
| `/schluessel/` | kundengebundene Zugangsrechte, Gewähren/Entziehen | eigenes Kontoschlüssel-/Passkey-Wrapping, Recovery und generationsweise Rotation mit Block-/Abschlusszuständen: P2-2 abstimmen |
| `/formular-schluessel/`, `/api/v2/key/` | key.manage, Signaturpflicht und getrennte Eingangsautorisierung | SDK-Provisionierung/-Rotation/-Reset und befristete Signaturausnahmen: Ingest/Krypto; kein v1-Header-Laufzeitpfad gemäß ADR 0001 |
| `/mail-server/`, `/benutzer/netze/` | system.manage, test-target.manage und Proxy-/MFA-Abhängigkeit | SMTP-/Proxyprofile, geheime Referenzen, Transporttests, verwaltete Testziele und Vertrauensnetze spezifizieren; kein Ausführen beliebiger Netzwerkziele |
| `/webhooks/` | draft.write für Entwurf, release.publish für Produktionswirkung | eigenes Webhook-DTO, Signaturschlüssel, sichere Zielbindung und Testzielverwaltung; kein Live-Toggle durch Token |
| `/history/`, `/betroffenenrechte/` | Metadaten, Chiffrat, Anhang, Einzelresend/Hold/Löschung, Betroffenenlöschauftrag | Suchblöcke/lokale Auskunft, Mailvorschau, Stapel-Resend mit Teilergebnissen, reguläre Stapellöschung, delete-old und atomarer Hold/Nachschutz detaillieren |
| `/home/`, `/statistics/`, `/error-log/` | Statistikprojektionen, Adminaudit | Dashboardalarme, scoped Fehlerprojektion, Ads/GCLID-Paritätsfelder und Benachrichtigungen spezifizieren; keine Kundenwerte rekonstruieren |
| `/konfiguration/` | sichere Konfigurations-Allowlist lesen/setzen | Änderung/Löschung mit konkreten DTOs und Versionsbezug, geschützte Systemwerte separat behandeln |
| `/api/doCronCycle.php`, `/api/doWebhookCycle.php`, `/api/health.php` | ausdrücklich außerhalb menschlicher Verwaltung | Dienstauth/Health/Betriebsvertrag; Mail-Cron nur Übersicht, keine Resend-Passphrase |
| `/endpoint/`, `/api/getFormData.php`, `/api/v2/form/`, `/api/v2/submit/` | separater Ingestvertrag referenziert | v1/v2-Adapter, direkte Skriptadressen und Antwortkompatibilität separat abnehmen |
| `/manifest.webmanifest`, `/sw.js`, `/src/*` | nur statische PWA-Cachegrenze | Routing-/Assetvertrag und review-A-Fallback-Unterschiede in PWA/Kompatibilitätsmodul erhalten |

## Nächster konkreter Schritt und erforderliche Verhaltensprüfungen

Koordination liest README plus offene Liste, führt Paket-/Konsistenzreview durch
und verlinkt dieses Ergebnis in STATUS/ARBEITSPLAN. Neue Detailentscheidungen erst
nach Nutzerbestätigung in ADRs übernehmen. Anschließend P3 mit synthetischen Daten:

- Gleiche Allow/Deny-Entscheidung für UI/REST/MCP; Kunde A kann Kunde B auch über
  Child-ID, Filter, Summen, Export, Anhang und Mischstapel nicht erreichen.
- Kontosperre, Rechte-/Schlüsselentzug und OAuth-Grantwiderruf wirken zwischen
  zwei Replikas sofort; letzte Administration und Datenzugang bleiben erreichbar.
- Gleichzeitige Passwort-/TOTPversuche, Challengeverbrauch, Lockoutablauf,
  Sessionrotation, CSRF, OTP-Replay und DB-Ausfall wirklich prüfen.
- OAuth-Code-/Refresh-Replay und paralleler Refresh, Scope-/Resource-/Redirect-
  Verwechslung und nicht freigegebene Clientregistrierung ablehnen.
- Admin-Token darf weder direkt noch über Entwurf, Import, Domain, Modus,
  Rollback oder Job veröffentlichen; falsche/abgelaufene/wiederverwendete
  Hashbestätigung ablehnen, legitime Wiederholung ohne doppelten Release.
- Gefälschte Proxyheaders/Peers und Kundendomainzugriff auf Adminrouten ablehnen;
  Bestands-WebAuthn-/PRF-Zugriff mit unveränderter RP-ID nachweisen.
- Debug-TTL 900 Sekunden, Maskierung und stets maskierten Export, keine Secrets
  in Trace/Audit, Resend ohne persistierten Klartext oder automatischen Retry
  sowie generationengebundenen Schlüsselzugang über echte Integration prüfen.


## Technische Reviewkorrekturen 27.10.2026

Status: **VORGESCHLAGEN als Vertragsentwurf**, keine Produktimplementierung oder
neue Nutzerentscheidung. Enger Auftrag ausschließlich unter `contracts/`.

### Änderungen

- H01: gemeinsamer Ressourcen-UUID-Typ in `admin-api.openapi.yaml`.
- H03: Persistenz-/Verbrauchs-/Rotationsvertrag in `anmeldung.md` und `mcp.md` an DDL angeschlossen.
- H10: `HoldInput.objects` mit Objekt-ID, Revision, Digest, Ausgangsgeneration und optionalem Ersatzpaket; offene Rechtefragen in `rechte.md` erhalten.
- M03: Aktionsledger-/Replay-/Publikationsbindung dokumentiert.
- M06: Exportantwort direkt `../flow/package.schema.json`; transitive erlaubte Abhängigkeiten dokumentiert.
- Dateien: `admin-api.openapi.yaml`, `anmeldung.md`, `mcp.md`, `rechte.md`, `validate.py`, dieses `HANDOFF.md`.

### Prüfungen

Beide vorhandenen Validatoren ausgeführt: Exitcode jeweils 0. Vollständige,
unveränderte Ausgaben und Prüfgrenzen: [VALIDIERUNG.md](../data/VALIDIERUNG.md).
Flow: 12 Schemas, 21 Beispiele, 46 erwartete Negativfälle. Auth: 66 Operationen,
1132 Referenzvorkommen, 11 lokale Dokumente, 37 Payloadfälle. Keine DB-/Krypto-/
Autorisierungs-/Mehrreplika-/Sandbox-Laufzeitprüfung, kein Produktionsreifeurteil.
Ältere Prüfzahlen/Offenlisten oben beschreiben den vorherigen Stand; dieser
Nachtrag ist der aktuelle Fortsetzungsstand.

### Offen und nächste Abnahme

- **OFFEN, nicht entschieden:** H02, H04, H05, H07, H09, H11, M04, M05 und alle Nutzerentscheidungen.
- **M02 nur teilweise:** technische Reihenfolge/Feldausschluss korrigiert; Legacytypen, Leerwerte, Spezialhandler/418/424, Scanner-/Mehrdateipolitik bleiben OFFEN.
- **M07 nur teilweise:** Regex korrigiert; Runtime-/Schemaquoten, IPC/Capabilities und unabhängige Sandboxabnahme bleiben OFFEN.
- Fristen/Retention, feine Rollen-/Aktionsrechte, Kunden-/Altschlüsselschnitt und MFA-/Secretprovider bleiben OFFEN; vorgeschlagene technische Details sind keine Beschlüsse.
- Gemeinsame Anschlussverträge: [abbildung.md](../data/abbildung.md) und [objektinventar.md](../data/objektinventar.md). Nächster Schritt: unabhängiger Vertragsabgleich und gesondert autorisierte synthetische P3-DB-/Replay-/Krypto-/TTL-Prüfungen, zuvor erforderliche Nutzerentscheidungen einholen.

Dateibesitz: ein schreibender Codex-Agent für die fünf beauftragten Vertragspakete,
keine Delegation. Gemeinsamer Checkout auf `main`, kein Branch-/Worktreewechsel,
keine Git-Metadatenänderung, kein Commit, keine laufenden Jobs. Altprojekt nur
für die zwei benannten technischen Feldstellen gelesen; keine Secrets oder
Kundendaten geöffnet/übernommen. STATUS/ARBEITSPLAN bleiben wegen expliziter
Schreibgrenze unverändert; Koordination muss diese Handoffs dort verlinken.


## Vertragsrunde 2 — Nutzerentscheidungen ADR 0004, 27.10.2026

Aktueller Fortsetzungsstand: Dieser Nachtrag ersetzt die früheren Offenlisten
zu H02/H04/H05/H07/H09/H11/M04/M05. **Produktentscheidungen BESCHLOSSEN gemäß
ADR 0004; neue technische Details VORGESCHLAGEN**, keine Produktimplementierung.

### Änderungsliste

- H02: rechte.md auf frei konfigurierbare Einzelrechte/Gruppen umgestellt, Rollen nur Vorlagen; Scope, Gruppenänderung, Widerruf/Rechteversion, unbekannte Rechte und Flowrechte geregelt.
- OpenAPI: geschlossener Permission-Katalog, Scope-/Gruppen-/Zuweisungs-/Widerrufs-DTOs und Operationen; Benutzergrants nicht länger freie Strings, template statt verbindlicher role.
- H04: Domains als eindeutige Ansichtshosts, separate API-Hostfreigabe mit signiertem Formular.
- H07/H09: menschliche Execute/Approve/Resume-Operationen, vollständiger Originalobjektnachweis im Resend statt bloßem sourceHash; Bearbeiten ist separater neuer Versand. Objektschlüssel ausschließlich writeOnly/RAM im vorgeschlagenen Nachweis.
- M04/M05: Legacyfrist/IP-Ausnahme und Credentialübernahme samt offenem Hash-/Formatprüfauftrag angeschlossen; keine neuen Tokenrechte/Fristverlängerungen durch Migration.
- Dateien: README.md, rechte.md, domains-proxy.md, mcp.md, admin-api.openapi.yaml, validate.py, dieses HANDOFF.md. Prüfer bezieht zusätzlich Ingest-YAML und DDL-Katalog-/Legacyfristregeln ein.

### Tatsächliche Prüfungen

`python3 contracts/flow/validate.py`: Exitcode **0**, 12 Schemas, 21 Manifest-
beispiele, 51 erwartete Negativfälle; zusätzlicher positiver Crashzustand.
`python3 contracts/auth/validate.py`: Exitcode **0**, 76 Operationen,
1863 Referenzvorkommen, 12 lokale Dokumente, 66 gezielte Payloadfälle.
Exakte vollständige Ausgaben und zusätzliche statische DDL-Prüfung:
[VALIDIERUNG.md](../data/VALIDIERUNG.md), Abschnitt Vertragsrunde 2.
Keine DB-/Krypto-/Autorisierungs-/Docker-/HTTP-/Migrationsintegration ausgeführt;
kein vollständiger OpenAPI-Spezifikationsvalidator, keine Produktionsreife.

### Teilweise / OFFEN / nächste Abnahme

- H02/H04 als Vertrag eingearbeitet; Rechtewiderruf/Gruppenänderung über zwei
  Replikas, Bereichs-/Selbstprivilegierungsprüfung und Hostkonflikte echt testen.
- H05/H07/H09/H11 technisch spezifiziert, unabhängiges Krypto-/Vertragsreview
  und synthetische Kreuz-/Crash-/Replay-/Originalbindungsprüfungen fehlen.
  Sicherer Transportkey-Provider/Provisionierung OFFEN; Adapterlaufzeit
  90 Tage nur VORGESCHLAGEN, keine automatisch bestätigte Frist.
- M02: Legacyadaptersemantik festgelegt, vollständige Handler-/PHP-Typfixtures
  und Implementierung fehlen. Scannerentscheidung und Ersatz für 418/424
  bleiben OFFEN; bis Nutzerentscheidung gilt ausdrücklich Altverhalten.
- M04: vollständiger Nicht-IP-Altstatistikerhalt beschlossen; tatsächlicher
  IP-Bezug muss vor Import geprüft werden, nicht übernehmen, als OFFEN melden.
  Geschütztes Metadatenformat/Ads-Zugriff bleibt technischer Prüfauftrag.
- M05: Übernahme beschlossen, Hash-/Geheimnis-/PKCE-Formatprüfung und echte
  Token-/Grant-/Refreshkontinuitätsabnahme OFFEN; kein Neufreigabe-Zwang.
- Zahlenwerte/Fristen aus Nr. 21, Kunden-/Altschlüsselschnitt und nicht
  migrierbare Zeilen aus Nr. 28 sowie M07-Sandboxabnahme weiterhin OFFEN.
  Bearbeiten-DTO bleibt OFFEN; kein stilles Editieren über Resend.

Ein schreibender Codex-Agent besitzt für dieses abgeschlossene Paket
contracts/{ingest,crypto,data,flow,auth}; keine Delegation/weiteren
Dateireservierungen. Gemeinsamer Checkout auf main, kein Branch-/Worktreewechsel,
keine Git-Metadatenänderung, kein Commit, keine laufenden Jobs.
Altprojekt, secrets/ und keys/secrets.ini in dieser Runde nicht geöffnet;
keine realen Schlüssel/Kundendaten. Ausschließlich unter contracts/ geschrieben.
STATUS/ARBEITSPLAN bleiben wegen expliziter Schreibgrenze unverändert;
Koordination soll diese Handoffs dort verlinken. Nächster Schritt: unabhängiges
Review dieser Verträge, anschließend gesonderte synthetische Integrationsabnahme.


## Vertragsrunde 3 — Anschlussbefunde R01–R08, 28.10.2026

Status: **VORGESCHLAGEN**, keine Produktentscheidung getroffen. Ein schreibender Agent,
gemeinsamer Checkout `main`, kein Commit, keine Jobs.

### Änderungsliste

- `admin-api.openapi.yaml`: `test-target.manage` im Katalog; Operationen `listTestTargets`, `createTestTarget`, `updateTestTarget`, `listEntryObjects`, `getObjectCiphertext`, `getResumeContext`, `getRunCheckpointCiphertext` (76 → 83); `DomainInput` verlangt `releaseId` bei `enabled=true`; `FlowExecuteInput.originalProof`; Schemas `TestTargetInput`, `StoredObjectRef`, `EntryObjects`, `StoredObjectCiphertext`, `ResumeContext`.
- `domains-proxy.md` (R01), `rechte.md` (R04), `mcp.md` (R08 Legacyprofil).
- `validate.py`: neue Prüfungen für Katalog/Operationen/DTOs/DDL/Manifest/Legacy-Fixtures (+27 Payloadfälle).

### Tatsächliche Prüfungen

`python3 contracts/flow/validate.py` (venv-Python mit jsonschema/pyyaml): Exitcode **0**,
12 Draft-2020-12-Schemas, 21 Beispiele, 53 Negativfälle (zusätzlich drei positive
`security.transport`-Varianten). `python3 contracts/auth/validate.py`: Exitcode **0**,
83 Operationen, 1988 Referenzvorkommen, 12 lokale Dokumente, 93 gezielte Payloadfälle.
Zusätzlich im Auth-Prüfer: Manifest-Schema und Beispiel mit fünf Negativfällen,
Schema/Fixtures der Legacy-Validierung, statische DDL-Textprüfungen. Nicht ausgeführt:
SQL/MariaDB, Krypto, PHP, HTTP, Mehrreplika, Sandbox; kein vollständiger
OpenAPI-Validator. Details: [VALIDIERUNG.md](../data/VALIDIERUNG.md), Abschnitt Vertragsrunde 3.
Übergreifende Entscheidungsliste: [vertragsrunde-3-offen.md](../../docs/handoffs/vertragsrunde-3-offen.md).

### Offen / nächste Abnahme

D1, D2, D4, D9. Weiterhin Folgearbeit: Paritäts-DTOs einzelner Aktionen (siehe oben Abschnitt „Noch auszuarbeitende Paritätsaktionen“), Bearbeiten-DTO für Neuversand.

## ADR 0005 Einarbeitung (29.10.2026)

- D1 (Form VORGESCHLAGEN): `domains-proxy.md` neuer Abschnitt "Release-Bindung auch für Zugriffsadressen"; OpenAPI `ApiHostInput.releaseBindings/confirm`, neue DTOs `ApiHostReleaseBinding`, `ApiHostBinding`, `PublishRebindInput` (`PublishInput.rebind`). Domain folgt Release nicht automatisch; gebundene Hosts nie nach `forms.current_release_id`; Auflösung weiter über das signierte Formular (ADR 0004 Nr. 5).
- D4 (BESCHLOSSEN): `mcp.md` Abschnitt R08 ersetzt durch "Neuanmeldung statt Legacyprofil" mit Cutover-Folge; Strikte Resource-Pflicht für neue Credentials bleibt. `validate.py` prüft nun Abwesenheit von `legacy-unbound`/`resource_binding` und die neue `api_host_forms`-DDL.
- D7: `rechte.md` angepasst (IP-Bezüge geschützt übernommen).
- Hinweis: `configureApiHost` liefert weiter das generische `Result`; eine Antwort mit `ApiHostBinding[]` ist Folgearbeit.
