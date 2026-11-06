# P2-3: Datenmodell für MariaDB

Stand: 26.10.2026. SPDX-License-Identifier: AGPL-3.0-only.

Vertragsentwurf, keine Implementierung. [schema-entwurf.sql](schema-entwurf.sql) enthält Spalten, Typen, Schlüssel, Indizes und Constraints; [migration-mapping.md](migration-mapping.md) beschreibt die Überführung. SQL wurde **nicht ausgeführt**, weder geparst noch gegen MariaDB/Fluent geprüft. Keine Zusage, dass es auf einer bestimmten MariaDB-Version ausführbar ist. Alle hier neu vorgeschlagenen Tabellen-/Spaltennamen, Enums, Serialisierungen, Schlüssel-, Index-, Lösch- und Transaktionsdetails sind **OFFEN zur Vertragsabnahme**. Bestätigte Anforderungen werden dadurch konkretisiert, aber keine neuen Architekturentscheidungen beschlossen.

## Auftrag, Quellen und Rangfolge

Dateibesitz dieses Pakets: ausschließlich diese Datei, `schema-entwurf.sql` und `migration-mapping.md` unter `contracts/data/`. Ziel: prüfbares Zielmodell, vollständige Zuordnung des dokumentierten Altinventars und wiederholbares Importverfahren. Kein Code, keine DB, keine Migration, keine Veröffentlichung. Maßgeblich sind [ADR 0001](../../docs/decisions/0001-grundentscheidungen-p1.md), [ADR 0002](../../docs/decisions/0002-sicherheit-und-cutover.md) und [ADR 0003](../../docs/decisions/0003-produkt-und-betrieb.md) vor älteren Vorschlägen.

Gelesene Basis: [AGENTS](../../AGENTS.md), [STATUS](../../docs/STATUS.md), [ARBEITSPLAN](../../docs/ARBEITSPLAN.md), [ENTWICKLUNG](../../docs/ENTWICKLUNG.md), [ARCHITEKTUR](../../docs/ARCHITEKTUR.md), [MIGRATION](../../docs/MIGRATION.md), [PARITAET](../../docs/PARITAET.md), [P0-C](../../docs/paritaet/C-daten-migration.md), [Review C](../../docs/paritaet/review-C.md), [P0-B](../../docs/paritaet/B-funktionen-felder.md), ergänzend Anforderungen, Sicherheit/Daten, Formulare/Abläufe und P0-D mit Review D. Review C korrigiert C insbesondere bei offenen Mailstatus, MFA, Kaskaden und Migration 026. Bestehende P2-Entwürfe [Ingest](../ingest/README.md) und [Flow](../flow/README.md) sind Abgleichsquellen, keine bereits freigegebenen Entscheidungen.

Altpfade im Mapping sind relativ zu `<workspace>/form-backend_bvk`. Statische Stichproben: `db/schema.sql`, Migrationen 018/026/034/036/037/040 sowie die Idempotenz- und Outbox-Vormerkung in `providers/AnfrageIngest.php` und `providers/WebhookOutboxEinsteller.php`. Ausschließlich Quelltext gelesen; `secrets/` und Datenbank nicht geöffnet.

## Bestätigter Rahmen

| Quelle | Verbindliche Vorgabe | Modellabbildung |
| --- | --- | --- |
| ADR 0001 Nr. 3 | Kunde ist Mandant; Kunde besitzt Formulare; Admin/Betreuer/Kunde | `customers`, `forms.customer_id`, globale Konten, Mitgliedschaften und Formularzuordnung |
| ADR 0001/0003 Nr. 4 | Laufzeit nur `:2`, Kundenschlüssel mit Generationen, HPKE bzw. sym, Recovery | `customer_key_generations`, Zugänge/Recovery und nur `:2` in `stored_objects` |
| ADR 0002 Nr. 15/16 | Signaturpflicht mit befristeter widerrufbarer Ausnahme; Login-Lockout/Backoff | Protokollschlüssel, `signature_exceptions`, gemeinsame DB-Zähler |
| ADR 0002 Nr. 18/19 | Quiesce, stabile Zustellidentität, Mail nur interaktiv erneut senden | Zustelltabellen mit Herkunftsstatus, `waiting-manual` und `uncertain` |
| ADR 0003 Nr. 5/13 | voller Editor; Veröffentlichung nur Mensch mit Bestätigung | versionierte Graphen, feste Releases, dauerhafte Läufe/Freigaben/Effekte |
| ADR 0003 Nr. 8/11 | manuelle Domains; DB Standard, S3/SFTP pro Formular; Zielausfall lehnt Annahme ab | Domainzuordnung, versioniertes Speicherziel, Objektreferenzen |
| ADR 0003 Nr. 9/10 | Debug 15 Minuten; pseudonyme Statistik ohne IP, 13 Monate, Altstatistik erhalten | DB-Debugaufträge/-ereignisse, neue Ereignisse getrennt vom Altbestand, unabhängige Löschprotokolle |
| ADR 0003 Nr. 12 | Dumpimport wiederholbar; Admin-Domain/RP-ID unverändert | Importledger, bytegenaue Passkey-/PRF-Übernahme |
| Auftrag / Architektur | Sessions, Job-Leases und Debugaufträge in DB; jede Tabelle hat Besitzer | nachfolgend vollständige Besitzliste |

## Nachtrag 31.10.2026: `account_enrollments` (VORGESCHLAGEN)

Einmalige Einrichtungs-Tokens für den ersten Passkey eines Kontos (`first-passkey`, vom Betreiber-Kommando `bootstrap-admin`) und für den Ersatz bei verlorenem Gerät (`recovery-passkey`, Kommando `enroll-passkey`). Nur der SHA-256 des Tokens wird gespeichert; Gültigkeit höchstens 7 Tage (CHECK), Verbrauch einmalig. Besitz: Kunden und Rechte.

## Nachtrag 31.10.2026: `managed_secrets` (VORGESCHLAGEN, setzt ADR 0006 Nr. 6 um)

Geheimnisse, auf die `secret_ref`-Spalten verweisen (zunächst `digest-hmac` des Eingangs), liegen AES-256-GCM-verschlüsselt in der Datenbank. Der Schlüssel wird per HKDF aus dem Serverschlüssel der Betriebsumgebung (`FORM_SERVER_KEY_FILE`) abgeleitet; die Referenz ist als AAD gebunden, ein vertauschter Eintrag lässt sich also nicht öffnen. Referenzformat `s1:<uuid>`. Ein Verlust oder Wechsel des Serverschlüssels macht die Einträge unlesbar (Rewrap-Verfahren nicht umgesetzt).

## Technische Konventionen — OFFEN

InnoDB und explizites `utf8mb4_bin` statt stiller Übernahme von `utf8mb4_general_ci`. UUIDs werden als 16 RFC-4122-Bytes in `BINARY(16)` vorgeschlagen, auf Schnittstellen weiter als UUID-String. Keine MySQL-spezifische UUID-Byteumsortierung. Dumpwerte über einen festzulegenden Parser dekodieren, nicht Speicherlayout des MariaDB-`uuid`-Typs kopieren. Keine SQL-UUID-Defaults: stabile IDs entstehen im Anwendungs-/Importdienst. Ehemalige numerische IDs bleiben im Importledger.

Zeitpunkte sind `DATETIME(6)` in UTC; `NULL` bewahrt unbekannte Zeit statt erfundener Historie. Unixsekunden explizit nach UTC, Quell-TIMESTAMPs unter dokumentierter Dump-Zeitzone. Nicht einfach lokale DATETIME-Werte als UTC behandeln. `JSON` ist MariaDB-Syntax für validierten JSON-Text, kein MySQL-Binärformat. Maximalgrößen und geschlossene fachliche JSON-Schemas bleiben Prüfpflicht des Besitzermoduls. `VARBINARY(n)` braucht für feste Kryptolängen zusätzliche CHECKs; diese stehen bei Rohschlüsseln/Hüllen im Entwurf.

`BIGINT UNSIGNED` für Zähler und Revisionen; konkrete Fluent-Abbildung, Client-Zahlenbereiche und Überlaufbehandlung sind OFFEN. `LONGBLOB` bewahrt Paketbytes ohne Textkonvertierung; es ist keine Erlaubnis für unbegrenzte HTTP- oder RAM-Puffer. Das Anwendungs-/Proxy-Limit ist separat zu prüfen. Paketkennungen, Digest-/Credentialbytes und Idempotenz sind binär vergleichbar. Namens- und Domainnormalisierung, Groß-/Kleinschreibung und Kollisionsbehandlung sind vor Import zu entscheiden; Änderung einer Kollation darf keine Rechte oder Deduplizierung ändern.

## Fachlicher Besitz aller Tabellen

Besitz bedeutet: genau dieses Modul verantwortet Schreibdienste, Validierung, Rechte und Löschregeln. Andere Module referenzieren über gemeinsame Verträge. Der SQL-Tabellenkommentar nennt denselben Besitzer. Gemeinsames Schema verleiht REST, MCP oder UI keine Sonderrechte.

| Besitzer | Tabellen | Zweck / zentrale Eindeutigkeit |
| --- | --- | --- |
| Kunden und Rechte | `customers`, `accounts`, `customer_memberships`, `form_access` | Mandant, globale Konten, Rolle und Sicht; Mitgliedschaft `(customer,account)`, Formularrecht `(customer,account,form)` |
| Kunden und Rechte | `account_preferences`, `passkeys`, `sessions`, `auth_throttles` | Kontooptionen; Credentialbytes global eindeutig; nur Sessionhash; atomare Konto-/IP-/TOTP-/Admin-Routenzähler |
| Formulardefinitionen | `forms`, `form_drafts` (P5-B E1, VORGESCHLAGEN), `form_versions`, `view_versions`, `releases`, `release_views` | stabile Formular-ID; unveränderliche Versionen; veröffentlichte Kombinationen und mehrere Ansichten |
| Domainzuordnung | `domain_bindings` | normalisierte Hostzuordnung zu Formular, Umgebung und Ansicht |
| Integrationen | `connections`, `customer_connections`, `form_connections`, `settings` | globale verwaltete Verbindungen, explizite Kundenfreigabe, Formularbindung, sichere Konfiguration |
| Integrationen | `migration_runs`, `migration_objects`, `migration_issues` | Importmanifest, 1:n-Quell-/Zielzuordnung, Fortschritt und sichere Fehlercodes |
| Kryptografie | `account_keys`, `account_key_wraps` | Konto-Public-Key und credentialgebundene PRF-Hüllen |
| Kryptografie | `customer_key_generations`, `data_key_access`, `data_key_recovery`, `form_protocol_keys` | Daten- und SDK-Schlüssel, Generationen, Überlappung; Geheimnisse nur Hüllen oder sichere Referenzen |
| Eingang | `signature_exceptions`, `submissions`, `ingest_idempotency`, `trusted_networks` | Signaturausnahme, Anfrage, Annahmereservierung, Netze |
| Speicher | `stored_objects` | Anfragepakete, Anhänge und Mailvorschauen, DB-/S3-/SFTP-Objekte und Löschzustände |
| Ablaufengine | `workflow_versions`, `workflow_runs`, `workflow_approvals`, `workflow_effects` | Graphen inkl. Schleifen/Skripten/Warten, Checkpoints, Budgets, Freigaben und Effektledger |
| Ablaufengine | `job_leases`, `debug_requests`, `debug_events` | replikaübergreifende Jobs, Debugzuordnung und maskierter Trace |
| Zustellung | `mail_deliveries`, `webhook_endpoints`, `webhook_outbox` | stabile Mail-/Webhookidentitäten, Versuche und Leases |
| Statistik und Audit | `statistics_events`, `legacy_statistics`, `audit_events`, `deletion_records` | neue Ereignisse, historische Originalsemantik, Audit und unabhängige Löschnachweise |

OAuth-/MCP-Credentialpersistenz ergänzt ADR 0004 M05: `oauth_clients`,
`oauth_grants`, `oauth_codes`, `oauth_refresh_tokens`, `mcp_tokens` (Besitzer
Kunden und Rechte). ADR 0005 D4: Keine Übernahme von Altcredentials (Neuanmeldung, alle Altgrants
verfallen); die Tabellen nehmen nur neue Credentials (`origin='native'`, strikte
`resource`, `family_id` NOT NULL). Sichere Secretablage bleibt OFFEN (D9). Modul-/Baustein-/Skript-/Sandboxversionen werden im Release-Manifest exakt mit Hash fixiert; Artefaktablage und die vier Aktivierungsstufen sind OFFEN zur Integration mit P2-4. Kein ausführbares Skript allein durch DB-Import.

## Mandantengrenzen und Rechte

Jedes Formular besitzt genau einen nicht-null Kunden. Zusammengesetzte UNIQUE-/FK-Paare binden Versionen, Releases, Inhalte, Läufe und Verbindungen an denselben Kunden und dasselbe Formular. Konto-, Session-, Systemkonfigurations- und Schedulerzustand ist ausdrücklich global. `scope_key` verwendet kanonisch `system` oder `customer:<UUID>`; das Besitzermodul muss Existenz und Berechtigung prüfen, da kein polymorpher FK existiert. Audit/Löschnachweise haben nur Snapshot-IDs ohne FKs, damit Löschung den Nachweis nicht mitlöscht.

ADR 0004 ersetzt feste Rollen: Admin/Betreuer/Kunde sind ausschließlich Vorlagen. `supervisor` entspricht Betreuer, `customer` Kunde. Eine Mitgliedschaft mit `assigned-forms` gibt ausschließlich die separat zugeordneten Formulare frei. Aus altem Formularzugriff darf kein kundenweiter Zugriff entstehen. Einzelrechte/Gruppen und Widerruf stehen in ../auth/rechte.md; `form_access` ist kein Ersatz für Publish-/Inhalts-/Debugrechte. Schlüsselzugang ist außerdem kein Rechtebeleg: `data_key_access` erteilt selbst kein Aktionsrecht; der Dienst prüft aktuelle Grants/Gruppenrevisionen und Scope bei jeder Ausgabe. Kontosperre/Widerruf müssen Sessions, Tokens und Schlüsselzugänge gemeinsam unwirksam machen; Schutz des letzten berechtigten Admins beachten.

OFFEN: sichere Kundenzuordnung des bisherigen Bestands, verwaiste Anfragen/Referenzen und globale Datenschlüssel, die mehrere neue Kunden umfassen. Import bleibt bei ungeklärtem Besitz gesperrt. Ein generischer Sammelkunde oder blindes Kopieren desselben privaten Datenschlüssels in mehrere Mandanten erfüllt die neue Isolation nicht.

## Versionen, Veröffentlichung und Historie

Formularversion enthält Feld-IDs/-namen, Typen, Pflicht-/Fixierungs-/Verbergungsregeln, sichere Vorlagen-/Empfängerkonfiguration und Adaptervertrag als validiertes `definition_json`. Ansicht enthält Darstellung, Ablaufversion Graph und feste Teilablaufreferenzen. Entwürfe entstehen als neue Versionen. Mutationen bereits gebundener Versionen sind durch Dienstrechte/Transaktionen zu verbieten; DDL allein erzwingt keine Unveränderlichkeit. Versionsnummern sind interne Zähler; Abbildung der P2-4-Vertragsversionen ist OFFEN.

Ein Release bindet eine Formularversion, eine Ablaufversion und mindestens eine genaue Ansichtsversion; das Manifest fixiert zusätzlich Modul-/Baustein-/Skript-/Sandboxversionen und Hashes. Referenzabschluss, mindestens eine Ansicht und Hashkonsistenz benötigen eine Dienstprüfung. `confirmed_by`, Bestätigungszeit und Auditbezug dürfen ausschließlich nach menschlicher Bestätigung geschrieben werden, niemals durch REST-/MCP-Token allein. Aktivierung wechselt `forms.current_release_id` atomar mit Audit; Rollback wählt ein geprüftes altes Release, laufende Durchläufe behalten ihr Release.

Historische Anfragen haben meist keinen beweisbaren damaligen Versionsstand. `release_evidence='legacy-unknown'` und `release_id=NULL` verhindern erfundene Referenzen. Ein aus heutiger Altkonfiguration erzeugter Entwurf ist kein historisch belegtes Release. Für neue Annahmen sind Release und Umgebung bekannt und obligatorisch im Dienst. Neue Veröffentlichungen oder eine ausnahmsweise Cutover-Aktivierung importierter Konfiguration verlangen getrennte menschliche Freigabe.

## Anfragen, Speicher und Schlüssel

`submissions` enthält Rechte-/Status-/Retentionmetadaten; Inhalte liegen in `stored_objects` pro Rolle/Ordinal. `data`, Anhang und beide Mailvorschauen können unterschiedliche `kid`/Wraps besitzen. Nicht nur eine Anfragegeneration speichern. Dateiname/MIME und gegebenenfalls freie Altfehler gehören verschlüsselt in Metadaten/Objekte; keine personenbezogenen Dateinamen als offene Objektpfade. `ciphertext_sha256` prüft Paketbytes, nicht Klartextgleichheit nach Umstellung.

Für DB-Persistenz werden Anfrage, Pakete, Idempotenz und vorgemerkte Outbox atomar geschrieben. Externe Ziele benötigen zunächst erfolgreich gespeicherte und überprüfte Chiffrate, danach DB-Commit und erst dann erfolgreiche Antwort. Scheitert Ziel/Commit, keine positive Annahme; vorbereitete externe Objekte werden anhand stabiler Identitäten bereinigt. Ein verlorenes HTTP-Ergebnis nach Commit wird über Idempotenz aufgelöst. Keine stillen lokalen Ersatzdateien. Speicherverlagerung ist ein eigener berechtigter, wiederholbarer Kopier-/Prüf-/Umschalt-/Löschvorgang, kein Nebeneffekt geänderter Formularversionen.

Genau eine aktive Schlüsselgeneration pro Kunde wird durch den vorgeschlagenen generierten `active_slot` maximal begrenzt; mindestens eine für aktive Annahme muss der Dienst erzwingen. `kid` muss dem Public-Key-Hash entsprechen. Rotation/Zugangsprüfung/Recovery benötigen gemeinsame Sperren und P2-2-Vertrag; vor Löschen alter Generationen alle Objektrollen prüfen. DB speichert keine privaten Daten-/Kontoschlüssel, Recovery-Passphrasen oder PRF-Ausgaben. SMTP-/Proxy-/Webhook-/MFA-Secrets werden ausschließlich über sichere Referenzen eingebunden; deren Provider und At-rest-Verschlüsselung sind OFFEN, keine neuen Klartextspalten als Abkürzung.

`removable=0` blockiert Retention. Das alte Hold-Verhalten kann Umhängen HPKE→sym voraussetzen; Flag und geprüfte neue Hüllen müssen gemeinsam aktualisiert werden. Kein pauschales `UPDATE removable` ohne diese Prüfung. Anfragefrist/Schlüssellöschfolge bleiben OFFEN; der bisherige 72h-Fallback ist keine neue Produktentscheidung.

## Annahmeidempotenz und Ablaufzustand

`ingest_idempotency.key_digest` ist der SHA-256 über die nach PHP-Trim gültigen maximal 190 **Byte** des Clientkeys. Schema und Digestkanonisierung sind OFFEN zur Bestätigung mit P2-1. Vorhandene Hashreservierungen lassen sich damit übernehmen, ohne den nicht mehr gespeicherten Clientkey zu erfinden. Frühere Rohkeys bleiben bei Bedarf zusätzlich `legacy_raw_key`; fehlender Nutzlasthash ist ausdrücklich `legacy-missing`, niemals ein erfundener Nullhash. Wiederholtes Ergebnis, Konflikt, Reservierung und Altsonderfall stehen im Mapping.

Reservierung darf vor der Anfrage existieren, daher bewusst kein FK auf `submission_id`; der Dienst muss nach Abschluss den passenden Anfragebezug prüfen und bei Löschung Replay-/Reservierungsregeln koordiniert anwenden. Retention ist OFFEN: P0-B nennt sieben Tage, P2-1 schlägt Bindung an Anfragelebensdauer vor, P2-4 zeigt sieben Tage als Beispiel. Kein stilles Auswählen eines dieser Vorschläge.

`workflow_runs` hält unveränderlichen Releasebezug, Checkpoint, dauerhafte Schleifen-/Besuchs-/Versuchszähler, absolute Deadline und bereits verbrauchte Budgets. `checkpoint_json` enthält nur verschlüsselte Objektreferenzen und technische Zustände, keinen Formularklartext. Freigaben sind an Lauf/Knoten/Besuch gebunden und genau einmal mit erneuter Rechteprüfung konsumierbar. Effekte besitzen stabile `(run,node,visit,slot)`-Identität; Retry erhöht Versuch, ein neuer Schleifenbesuch erhält neue Besuchsnummer. Gemeinsame Rootbudgets bei Teilabläufen, Sandboxgrenzen und JSON-Formen sind OFFEN mit P2-4; Zustand ist kein Ausführungsrecht.

## Leases, Zustellung und Wiederanlauf

Gilt für Läufe, Mail, Outbox, Jobs, Idempotenz und Debug: Claim in kurzer Transaktion mit Zeilensperre bzw. bedingtem Update, DB-Zeit, neuem zufälligem Token und monoton erhöhtem `fence`. Zustandscommit/Verlängerung ausschließlich bei passendem Token, Fence und noch gültiger Lease; genau eine betroffene Zeile erwarten. Kein Netzwerk-I/O unter langer DB-Transaktion. `SKIP LOCKED` nur nach Versionsprüfung; konkretes Claim-SQL und Lease-/Backoffwerte sind OFFEN. Globale Jobs besitzen eindeutige `(scope_key,job_key)`-Identität und laufen nicht pro Replika nochmals.

Leaseverlust nach externem Effekt ist **kein** Beweis für Nichtversand. Effekt vor I/O als `in-flight` protokollieren, danach Erfolg bedingt bestätigen; Absturz/unklare Annahme führt zu `uncertain`. Ohne Empfängerdeduplizierung oder belegbare Statusabfrage ist manuelle Klärung erforderlich. SMTP bietet keine zugesagte Genau-einmal-Zustellung. `smtp-accepted` bezeichnet Annahme durch Transport, keinen Lesebeleg.

Mail behält für importierte Vorgänge `(submission_id,environment,mail_kind,identity_scope='legacy')` als eindeutige Identität. Keine neue Versandart aus Sequenz/Transport erfinden. Neue Graph-Effekte erhalten einen eigenen stabilen Scope und `effect_id`, damit Schleifen echte neue Effekte unterscheiden können; Ableitung ist OFFEN mit P2-4. Cron meldet fällige Fehler, sendet sie nicht. Manuelles Resend prüft Rechte und bewussten Passphrase-/Schlüsselzugang erneut, beansprucht denselben Vorgang und persistiert keinen Klartext für spätere automatische Wiederholung.

Webhooks bewahren Outbox-UUID und minimale Metadatenpayload. Keine zusätzliche Eindeutigkeit `(webhook,submission)` für Altzeilen: sie existiert im Alt-DDL nicht. Neue Effekte werden über `effect_id` dedupliziert. `prepared` bleibt bis fachlichem Abschluss gesperrt; Import und Replay dürfen vorhandene Jobs nicht neu generieren. Auf Anfrage-/Formularsnapshot der Outbox bewusst kein Anfrage-FK; Anfrage-Löschung darf den Zustellnachweis nicht automatisch entfernen. Endpunktlöschung, offene Zustellungen und Formularlöschung verlangen einen expliziten Dienstablauf.

## Debug, Sessions, Statistik und Audit

Sessions leben in DB, Cookie enthält nur ein opakes Token; DB nur Digest, verschlüsseltes CSRF-Geheimnis und Authentifizierungs-/Ablaufzustand. Leerlauf-/Absolutgrenzen und erneute Rechteprüfung sind OFFEN mit P2-5. Rate-/Lockoutzähler sind gemeinsam und atomar, keine replikaeigene MEMORY-Tabelle. IP-bezogene Abwehr verwendet zweckgebundene HMAC-Identitäten, nicht Statistikereignisse; Geheimnisrotation, Fristen und Altblocklisten sind OFFEN.

Debugauftrag fixiert Kunde/Formular/Release, Benutzer, Umgebung und Testziel. Genau eine Replika ordnet eine passende Anfrage atomar zu. Sensible Inhalte bleiben maskiert; JSON wird gegen den geschlossenen P2-4-Ereignisvertrag geprüft. Keine Header, Cookies, Secrets, freie Stacktraces oder Klartextcheckpoints speichern. Klartextanzeige ist ein eigener berechtigter Zugriff auf verschlüsselte Originale mit Schlüssel; Export maskiert. Vorschlag OFFEN: TTL ab Aufzeichnungsbeginn, `expires_at=start+15 min`, nicht verlängerbar; Wartefrist vor Beginn separat festlegen. Lesen/Schreiben ab Ablauf sperren und Ereignisse, Auftrag und Cachekopien fristgerecht löschen. Ein CHECK und ein verspäteter Cron allein erfüllen die physische TTL nicht; Löschscheduler und Ausfallverhalten müssen noch abgenommen werden.

Neue Statistik: ausschließlich Besuch/Beginn/Absenden/Abbruch, zufälliges bzw. zweckgebundenes Besuchspseudonym, Formular/Release/Ansicht/Domainalias/Umgebung. **Keine IP, UA, GCLID, freien URLs oder Formularwerte** im neuen Ereignismodell. Verbot von UA/GCLID ist als P2-4-Konkretisierung OFFEN, IP-Verbot bestätigt. Ereignis-ID und Besuch/Ereignis-UNIQUE verhindern Doppelerfassung; Absenden zusätzlich Anfragebindung, Resend/Retry erzeugen keine neue Conversion. Eine Submit-ID wird im Dienst gegen dasselbe Formular geprüft; kein FK bewahrt Statistik unabhängig von späterer Anfragelöschung. Domainalias muss zur selben Formularzuordnung gehören; Dienstprüfung ist nötig.

Conversion ist `Absenden / Besuch` mit gleichen Dimensionen/Zeiträumen; bei Nenner null undefiniert, Testdaten getrennt. Späte Annahme muss einen abgeleiteten Abbruch für dieselbe Besuchsidentität auflösen. Fehlende historische Beginn-/Abbruch-/Besuchspseudonyme nicht synthetisieren. `legacy_statistics` bewahrt Status/Typ einschließlich NULL und historischen Domainfilter; Original-ID ist zusammen mit Quellnamespace eindeutig, alte UUID nicht als UNIQUE angenommen. Kein Zusammenzählen beider Modelle für denselben historischen Zeitraum ohne Herkunftsregel.

ADR 0004 M04: 13 Monate gelten ausschließlich für neu erhobene Daten,
einschließlich rekonstruierbarer Zusatzmetadaten/Aggregate. UTC-Kalendermonate
mit Monatsendekappung sind VORGESCHLAGEN. Gesamter Altstatistikbestand bleibt
mit `legacy_statistics.origin=legacy` einschließlich sicherer Metadaten erhalten;
keine expires_at-Spalte und keine neue 13-Monatslöschung für diese Tabelle oder
zugehörige statistics-metadata-Objekte. ADR 0005 D7: Altbestand komplett inklusive möglicher
IP-Bezüge übernehmen, nur mit Herkunft legacy, in geschützter verschlüsselter
Hülle (`metadata_object_id`, Flag `has_ip_reference`), beschränktem Zugriff, ohne
Personenebenenauswertung; vorherige Bestandsprüfung am Dump ist Importvoraussetzung,
Importbericht ohne Originalwerte. Kein IP-Hash als Ersatz. Format/Zugriff der geschützten Ads-/UA-Projektion bleibt Prüfauftrag,
kein stiller Verlust von Nicht-IP-Bestandskennzahlen.


`deletion_records` bleibt unabhängig von Anfrage/Statistik/Konto bestehen, ohne gelöschte Werte oder Besuchspseudonyme. Löschgrund, Zahl, Zeitraum, IDs und zulässige Momentaufnahme bleiben nachweisbar. `audit_events` erfasst Änderungen, Veröffentlichung, Import/Export, Schlüsselzugang, privilegierte Aktionen und Debugzugriff ohne Secrets/Formularklartext. Freie historische Fehler-/Konfigurationswerte nicht ungeprüft übernehmen. Keine FKs oder Kaskaden auf Snapshotobjekte. Minimale Personenbezüge, Maskierung historischer Namen/Notizen und Auditretention sind OFFEN; das bestätigte Statistik-Löschprotokoll darf nicht zusammen mit Ereignissen entfernt werden. Das Modell ist kein Manipulationssicherheitsnachweis.

## Lösch- und Integrationsregeln — OFFEN zur Abnahme

DDL verwendet standardmäßig RESTRICT statt Alt-CASCADE. Damit werden Inhalte/Jobs nicht nebenbei durch Stammdatenlöschung verworfen; dies ist eine bewusste **noch nicht beschlossene** Änderung. Dienste müssen Kindobjekte, Holds, externe Speicher, Idempotenz, Schlüsselzugänge und offene Effekte koordiniert prüfen/löschen; Audit/Löschnachweise bleiben. Alte Kaskaden und bewusste Ausnahmen sind im Mapping belegt. Große Löschläufe benötigen wiederholbare Batches und Nachweise auch bei teilweise fehlgeschlagener externer Löschung.

Verbindungen sind global administriert und explizit für Kunden freigegeben. Freigabe einer globalen Verbindung gewährt keinen Zugriff auf Credentials oder andere Kundendaten. Veränderliche `form_connections` sind Betriebsbindungen; reproduzierbare Releases müssen die zulässige Konfigurationsrevision bzw. bewusst dynamische Bindung im Manifest dokumentieren. Genaues Revisionsmodell, Zieltypprüfung (`smtp`/`s3` etc.) und Testzielverwaltung bleiben OFFEN. DNS-Verifikationscache ist keine manuelle Domainbesitzprüfung.

## Abnahme, offene Punkte und Fortsetzungsstand

Abnahme des Entwurfs: alle Zieltabellen mit Besitzer, zusammengesetzte Mandantenreferenzen, Versionen/Historielücken, DB-Leases, sichere Inhalte, getrennte Altstatistik und vollständiges Quellinventar im Mapping. Tatsächlich erfolgt ist ausschließlich statische Lektüre und Text-/Referenzabgleich. Historischer P2-3-Stand: 46 Tabellenentwürfe; der ADR-0004-Nachtrag ergänzt weitere Tabellen mit Besitzerkommentaren. Genau die drei beauftragten Dateien liegen in diesem Paket. Keine SQL-/PHP-/Swift-/Browserausführung, keine DB-/Migrations-/Nebenläufigkeits-/Entschlüsselungsprüfung, keine installierten Abhängigkeiten.

Vor Implementierung offen: MariaDB-/Fluent-Version und SQL-Probe; feine Rechte/Grantwiderruf; Kunden-/Schlüsselschnitt; tatsächlicher Dump-/Migrationsstand; Username-/Idempotenzkollation; Krypto-/Secretprovider; Altversions-/Handlerkonvertierung; Lease-/Backoff-/Retentionwerte; TTL-Löschgarantie; IP-Prüfung/Ads-Format der Altstatistik; Hash-/Formatabnahme der beschlossenen OAuth-/MCP-Übernahme; fehlende Referenzen und unklare Außenwirkungen. Die Prüffälle im Mapping sind notwendige zukünftige Integrationsabnahme, keine bestandenen Tests.

Übergabe: bestehender gemeinsamer Checkout auf `main`, kein neuer Branch/Worktree wegen Schreibfreigabe nur `contracts/data/`, kein Commit/Remote. Keine delegierten Agents oder laufenden Jobs dieses Pakets. Vorgefundene unversionierte Dateien bleiben unberührt. `docs/STATUS.md`, `docs/ARBEITSPLAN.md` und ADRs wurden gemäß ausdrücklicher Schreibgrenze nicht geändert; Koordination muss diesen Fortsetzungsstand dort verlinken. Nächster Schritt: P2-1/2/4/5 gemeinsam gegenlesen, OFFEN-Punkte entscheiden, unabhängiges Vertragsreview; danach synthetische MariaDB-/Krypto-/Crashprüfungen in P3/P9, weiterhin kein produktiver Cutoverauftrag.


Technischer Nachtrag 27.10.2026 (**VORGESCHLAGEN**): gemeinsame Identitäts-/
Versions-/Generationszuordnung, Authpersistenz und Idempotenz siehe
`abbildung.md`; Gesamtinventar und Holdliste siehe `objektinventar.md`.
Diese Nachträge ersetzen widersprechende ältere technische Aussagen; alte
Tabellenzahlen/Prüfstände oben beschreiben ausschließlich den vorherigen Stand.
Produktentscheidungen H02/H04/H05/H07/H09/H11/M04/M05 sind durch ADR 0004 entschieden; technische Abnahmegrenzen stehen im aktuellen Nachtrag.


## DDL-Nachtrag ADR 0004 (technische Struktur VORGESCHLAGEN)

`permission_catalog`, `permission_groups`, `permission_group_rights` und
`permission_assignments` gehören Kunden und Rechte. Katalog-FKs lehnen unbekannte
Rechte ab; Scope-/Selbstprivilegierungs-/Revisionsprüfung bleibt Fachschichtpflicht.
`template_name` ist kein Laufzeitrecht, `form_access` nur Bestandszuordnung.
`domain_bindings` sind eindeutige Ansichtshosts; `api_hosts/api_host_forms`
(Besitzer Domainzuordnung) binden gemeinsame Hosts über signierte Formulare.
ADR 0005 D1 (VORGESCHLAGEN): `api_host_forms.release_id` (NULL = ungebunden) mit
`binding_revision` und Bestätigungsbeleg koppelt Zugriffsadressen an ein Release;
gebundene Hosts nie nach `forms.current_release_id`.
`transport_replays`, `legacy_adapter_bindings` (Eingang) und
`workflow_resumptions` (Ablaufengine) enthalten nur sichere Metadaten und
Secretreferenzen. Neue Speicherprofile nur hpke-v2; `validation_profile` wählt
neue typisierte versus unverändert adaptierte Legacyvalidierung.
Diese Definitionen ersetzen widersprechende ältere Offenlisten im Dokument;
offen bleiben Umsetzung/Integration, Zahlenwerte, Secretprovider, tatsächliche
Hashformate und unabhängig geprüfte Parität. DDL nicht ausgeführt.
