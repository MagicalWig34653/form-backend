# P2-3: Migrationsabbildung und wiederholbarer Dumpimport

Stand: 26.10.2026. SPDX-License-Identifier: AGPL-3.0-only.

**Entwurf, nichts ausgeführt.** Zieltabellen und Spalten stehen in [schema-entwurf.sql](schema-entwurf.sql), Besitz/Constraints/Offenpunkte in [schema-entwurf.md](schema-entwurf.md). Neue Transformations-/Importdetails sind **OFFEN zur Abnahme**; bestätigte ADR-Vorgaben sind ausdrücklich benannt. Es wurden keine Datenbank, Dumps, Secrets, Produktivdaten oder Schlüssel geprüft. Dieses Dokument autorisiert weder Dumpbeschaffung noch Import, Schlüsselrotation, Löschung oder Cutover.

## Quellen und belastbare Ausgangslage

Maßgeblich: ADR 0001–0004, `docs/MIGRATION.md`, `docs/PARITAET.md`, `docs/paritaet/C-daten-migration.md`, **ergänzend und korrigierend `review-C.md`**, `B-funktionen-felder.md` sowie P0-D/Review D. Die Pfade `ALT/...` bezeichnen das ausschließlich lesend betrachtete `form-backend_bvk`, nicht dieses Repository. Statische Direktstichproben siehe Schemaentwurf; insbesondere `ALT/providers/AnfrageIngest.php:771–932,1009–1027` und `ALT/providers/WebhookOutboxEinsteller.php:33–42,83–126` ergänzen das reine SQL-Inventar.

Die Baseline ist kein Beweis des tatsächlichen Quellschemas. Dokumentierter Sollendstand: Baseline plus vorhandene SQL-Migrationen 001–040, **025 fehlt absichtlich**. `schema_migrations` entsteht im Runner. 008/012/013/023 ändern Daten, 024 verbreitert vier Anfragepaketspalten, 026 löscht Sequenzinformation ohne Bestandsabbildung, 033 vereinheitlicht nur vier Tabellen, 037 ändert `statistics` nicht. Der heutige Dump und seine Migrationshistorie sind OFFEN.

Keinen alten Runner auf der Quelle starten: `migrate.php` ist nicht atomar, kennt kein automatisches Rollback und setzt bei 026 keine Tabellenleerheit durch. `verify.php` prüft nur eine feste Auswahl und akzeptiert leere Prüfsummen. Ein dortiger Erfolg wäre kein Entschlüsselungs-, Zustell- oder vollständiger Paritätsnachweis (Review C, Abschnitte Werkzeuge).

## Quellidentität und gemeinsame Transformationsregeln

Ein Importplan fixiert Quellnamespace, Dump-SHA-256, Quellschemamanifest, Mappingversion/-hash, Importerversion, Zuordnungsentscheidungen und Cutoverzeitpunkt. Quellnamespace bezeichnet **denselben logischen Altbestand über mehrere Dumps hinweg**, nicht den jeweiligen Dateinamen/Hash. Tabellen-/Spaltennamen und null/leer/0 sind exakt zu unterscheiden. Alle Zuordnungen sind mandantenbezogen; kein automatischer Kunde aus Formularname, Domain oder zuständigem Benutzer.

UUIDs bleiben auf den Schnittstellen erhalten; DDL schlägt `BINARY(16)` vor. Numerische Quell-IDs werden in `migration_objects.source_key` aufbewahrt. Zusammengesetzte Quellschlüssel bekommen eine eindeutige längenkodierte Serialisierung, keine mehrdeutige Verkettung. Nicht-UUID-Quellen erhalten im getrennten Importplan fest zugeordnete Ziel-UUIDs; Wiederholung verwendet dieselben. Nichts bei jedem Retry neu würfeln. Quell-UUIDs ohne UNIQUE, besonders Statistik, nicht allein zur Deduplizierung benutzen.

Unixzeit explizit nach UTC; Dump-TIMESTAMP und DATETIME anhand dokumentierter Quellzeitzone umrechnen. `0`/NULL für unbekannte Erstellzeit nicht als heutige Zeit übernehmen. Negative/überlaufende Zeit-/Zählerwerte, ungültige UUIDs, kaputtes JSON und fehlende Eltern werden als `migration_issues` mit sicherem Code erfasst und blockieren abhängige Freigabe. Keine stillen Stringkürzungen, Konvertierung ungültiger Bytes, `INSERT IGNORE` oder erfundene Defaultkunden.

Kollationen vorab vergleichen: `username`, Feldnamen, Idempotenz und Zustellidentität dürfen durch den vorgeschlagenen binären Zielvergleich weder zusätzliche Konten noch Doppelversand zulassen. Normalisierung mit Vorher-/Nachher-Kollisionsbericht, expliziter Entscheidung und aktualisiertem Mappinghash. Domainnormalisierung (IDNA/Kleinschreibung/Punkt/Port) ist OFFEN; zugelassene Quellwerte nicht still verwerfen. Keine Host-/Proxy-Konfiguration aus ungeprüften Requestheadern übernehmen.

## Formular, Mandant, Felder und Verbindungen

| Alttabelle / Spalte | Ziel | Transformation / Grenze |
| --- | --- | --- |
| `formulare.ID`, `UUID`, `name`, `active` | Ledger; `forms.id/name/active/customer_id` | UUID erhalten; Kunde aus freigegebener Zuordnung. Import zunächst ohne aktive Laufzeitfreigabe; Quellaktivität im Plan erhalten. Menschliche Aktivierung separat. |
| `formulare.domains`, `modes` | `domain_bindings.host_ascii/environment/enabled`, Adapteranteil `form_versions.definition_json` | JSON-Struktur und bestehende Produktions-/Test-/Autorisierungssemantik aus P0-B erhalten. ADR 0004 H04: Ansichtshosts eindeutig einem Formular zuordnen, gemeinsame API-Hosts nach api_hosts/api_host_forms über signiertes Formular abbilden. Unklare Quellfunktion als migration_issues melden, nicht willkürlich ein Formular wählen. Keine DNS-Besitzprüfung erfinden (ADR 0003 Nr. 8). |
| `fromName`, `betreff`, exakt `betreffToFIller`, `toProductionMails`, `toTestingMails`, `formularSendMailToFiller` | `form_versions.definition_json` bzw. versionierter Mailanteil `workflow_versions.graph_json` | Absender, beide Betreffe, Empfängerlisten und Bestätigungsflag strukturiert übernehmen. JSON-Array-/Stringprüfung; nicht pauschal nach Komma spalten, wenn bereits JSON gespeichert. Empfänger-/Templatekonfiguration ist zugriffsgeschützt. |
| `formulare.mailBody`, `mailBodyFiller` | versionierte Vorlagen in Definition/Graph | Vorlagen sind Konfiguration, nicht die verschlüsselten gleichnamigen Anfragepakete. Platzhalter `#=[Name]=#`, Reihenfolge/abgeleitete Handlerwerte und bestehende Ausgabe gegen P0-B vergleichen. Keine automatische Skriptausführung. |
| `formulare.essentialPostFields` | `form_versions.definition_json` mit gekennzeichnetem Legacy-Fallback | Effektive Feldliste bevorzugt aus `formularFelder`; leeres Schema/Fallback gesondert bewahren. Kein erneuter Lauf von 012/013 auf Quelle. Bestehendes `isset`-/Leerstringverhalten nicht still verschärfen. |
| `formulare.besondereKategorien` | `form_versions.special_categories` | Gehört zum Formular, nicht zu `anfragen`; tatsächlichen Wert übernehmen. Regeln aus 008 nicht erneut nach Namen anwenden. |
| `formulare.cloudflareKeys` | sichere Secretablage und Referenz in Definition | Öffentlichen Site-Key von geheimem Anteil trennen. Werte nur durch später autorisiertes Migrationswerkzeug über sicheren Kanal, nie Bericht/Fixture/Repo. |
| `outgoingProductionServer`, `outgoingTestingServer` | `form_connections` und Release-Verbindungsalias | Typ/ID je SMTP oder Proxy anhand Quellvertrag eindeutig auflösen; unbekannte Namen/UUIDs sind OFFEN. Freigegebene Kundenverbindung zwingend. |
| `formularFelder.ID/formularUUID/feldName/typ/pflicht/regel/reihenfolge` | `form_versions.definition_json.fields` und Ledger | Alle sieben Typen erhalten; Reihenfolge nach `reihenfolge,ID`; stabile Feld-ID einmalig zuordnen; Feldname bleibt SDK-Mappingname. Regel-JSON und PHP-Regelsemantik bewahren, PCRE nicht ungeprüft als JS-/JSON-Schema-Regex ausgeben. |
| spezialisiertes Handlerverhalten (keine eigene Tabelle) | `workflow_versions.graph_json`, ggf. Formularentwurf | Drei Spezialhandler und generischer Handler gemäß P0-B separat abbilden: Zustimmungen, Behandlungskombination, Datums-/Namensableitung, Betreff/Bestätigung und Upload. Unverstandene Logik OFFEN, keine automatische Veröffentlichung. |
| keine historische Versionstabelle | `form_versions`, `view_versions`, `workflow_versions` | Importierte aktuelle Konfiguration als Entwurf; neue Ansicht nicht als historisch vorhandene Ansicht ausgeben. Veröffentlichungs-/Releasebezug alter Anfragen bleibt unbekannt. |
| `outgoingMailServer.ID/UUID/name/fromMail/SMTPHost/SMTPPort/SMTPSecurity/SMTPUsername/SMTPPassword/SMTPallowSelfSigned` | `connections` (`kind='smtp'`) und `customer_connections` | Nichtgeheime Parameter in `safe_config_json`; Benutzer-/Passwortdaten je Schutzklasse in `credential_ref`. Port als geprüfter Zahlwert; `SMTPallowSelfSigned` = 1 (nur dieser Wert) wird `verifyCertificate:false` der Verbindung (ADR 0044) und im Umstieg sichtbar gemeldet; 0, 2, leer, NULL, unbekannt = Zertifikat prüfen. |
| `outgoingMailProxy.ID/UUID/name/fromMail/proxyURL/proxyAuth` | `connections` (`kind='mail-proxy'`) | URL prüfen, Auth in sicherer Ablage; Query-/URL-Secrets nicht in sichere Konfiguration kopieren. Keine Zieltests beim Import. |
| `config.ID/name/value/manageable` | `settings.scope_key/setting_key/safe_value_json/secret_ref/manageable` | Allowlist je Name, globale Werte unter `system`; alte RSA-/MFA-/Cron-/Benachrichtigungssecrets nicht pauschal JSON-serialisieren. RSA-Altmaterial nur Importwerkzeug, kein Laufzeitfallback. Unbekannte Schlüssel OFFEN. |
| `mailZielVerifikationen.host/verifiedAt` | OFFEN: neuer Zielprüfungs-Cache; vorerst kein Laufzeitimport | DNS-/Mailzielcache ist kein Domainbesitznachweis. Vorschlag: nach Cutover neu validieren; bewusste Nichtübernahme und Mengen im Bericht, keine bereits beschlossene Datenverwerfung. |
| `formularSchluesselTrefferweg.ID/formularUUID/beobachtungsTag/treffer...` | OFFEN: sichere historische Betriebszählung in `audit_events.safe_details_json` | Drei Zähler und Tag ohne Schlüsselwerte bewahren, falls Betriebsnachweis gewünscht. Nicht als Besuch/Absenden zählen. Entscheidung über Übernahme/Frist fehlt. |

Neue Speicheradapter haben keinen belegt gespeicherten Altgegenpart. DB bleibt Zielstandard; Import in S3/SFTP bzw. spätere Verlagerung bedarf expliziter Zuordnung und eigener Kopier-/Hash-/Löschabnahme. Neue feste/verborgene Feldattribute nicht aus unbekannten UI-Eigenschaften ableiten; sie sind neue Entwurfswerte mit Reviewbedarf.

## Konten, Rechte, Passkeys und Schlüssel

| Alttabelle / Spalte | Ziel | Transformation / Grenze |
| --- | --- | --- |
| `users.DBID/UUID/username/password/userType/aktiv/erstelltAm/letzteAnmeldung/mcpErlaubt` | `accounts` und Ledger | UUID/Passworthash erhalten; admin/staff/customer als Vorlagenherkunft, belegte Altbefugnisse explizit in Einzelgrants abbilden, kein Rollennamen-Bypass. Unbekannte Rollen OFFEN statt Hochstufung. Null/0-Zeiten bewahren. Hashalgorithmus/Swift-Verifikation vor Aktivierung synthetisch prüfen; Passwort nicht aus Hash neu erzeugen. |
| `users.MFAKey` | `accounts.mfa_secret_ref` | 011 erweitert nur die Spalte. NULL, Alt-Klartext und `MFAKEYv1|` unterscheiden; letzteren ausschließlich im Werkzeug korrekt öffnen (CBC-Ciphersegment doppelt Base64). Sicher neu verpacken, nicht in neue Klartextspalte schreiben. Fehlender Schlüssel/unklares Format sperrt MFA-Migration. |
| `userFormularAccess.userUUID/formularUUID/grantedAt` | `customer_memberships`, `form_access` | Kunden aus Formularzuordnung, `access_scope='assigned-forms'`, alle einzelnen Formulare erhalten. Gemeinsamer Kunde erzeugt keine neuen Zugriffe. Aufwertung auf `all-forms` nur separate Entscheidung. |
| `benutzerEinstellungen.userUUID/key/value/modifiedAt` | `account_preferences` | zugelassene Schlüssel und exakte Wertsemantik; nicht jeder alte Text ist gültiges JSON. Gegebenenfalls als JSON-String kodieren; keinen Inhalt ausführen. |
| `benutzerPasskey.ID/userUUID/credentialId/publicKey/signCount/bezeichnung/erstelltAm/letzteNutzung` | `passkeys` | Credentialbytes und Public-Key-Serialisierung unverändert mit Encodingkennung; Konto-ID/UserHandle-Bindung erhalten. **VORGESCHLAGEN (ADR 0006 Nr. 12):** `user_handle` = UTF-8-Bytes des UUID-**Textes** des Kontos (36 ASCII-Bytes, nicht die 16 Bytes von `accounts.id`); wird aus dem Alttext `userUUID` byteweise unveraendert uebernommen, Bindung zum Konto per CHECK (Hex ohne Bindestriche gleich `accounts.id`, gross/klein-unabhaengig); je Konto genau ein Handle fuer alle Passkeys (Import-Pruefung). **OFFEN:** Gross-/Kleinschreibung des Alt-UUID-Textes (und des im Alt als UserHandle ausgegebenen Textes) ist nicht belegt; der Importer muss die Schreibweise der Altspalte vor Cutover pruefen und uebernehmen, nicht normalisieren; abweichende Schreibweisen je Konto = Sperrfall. `public_key_encoding` fest `'pem-spki'`; sonstiges Altformat (P0 D offen) = Sperrfall. `cose_algorithm` aus dem PEM abgeleitet (EC P-256 = -7, RSA = -257, Ed25519 = -8), anderes = Sperrfall; RSA unter 2048 Bit = `migration_issues` (Mindestlaenge im Verifier, Bestand unbekannt). signCount-Regel: akzeptiert wird `(alt==0 && neu==0) || neu>alt`, Fortschreibung bedingtes UPDATE (`sign_count < neu OR (sign_count=0 AND neu=0)`) in derselben Transaktion; alt=2^32-1 sperrt weitere Anmeldung (wie Alt, Reset OFFEN). Unsigned signCount bis 2^32−1, **0/0 ist gültig**. RP-ID aus unveränderter Admin-Konfiguration übernehmen, nicht aus Kundenhosts. |
| `kontoschluessel.userUUID/publicKey/erstelltAm` | `account_keys` | 32 Public-Key-Bytes exakt, kein neues Kontoschlüsselpaar. |
| `kontoschluesselWrap.ID/userUUID/credentialId/prfSalt/iv/wrap/erstelltAm` | `account_key_wraps` und Ledger | Credentialbindung, PRF-Salt 32, IV 12, Wrap 48 Bytes exakt. Zusammen mit Passkeys migrieren; fehlendes Konto/Credential ist Sperrfall. |
| `datenschluessel.kid/publicKey/status/erstelltAm/erstelltVon` | `customer_key_generations` | aktiv→active, auslaufend→retiring; Public-Key und kid prüfen, Generationnummer einmalig stabil zuordnen. Bisher globaler Schlüsselbestand muss vor Import kundenbezogen geklärt sein, siehe unten. |
| `datenschluesselZugang.ID/kid/userUUID/enc/versiegelt/erteiltVon/erteiltAm` | `data_key_access` | HPKE-enc 32 und Hülle 48 Bytes exakt, wenn Schlüsselidentität unverändert. Kunden- und aktuelle Berechtigungszuordnung separat prüfen; Zugriff nicht blind vervielfachen. **Nicht importiert:** Hüllen sind an alte Kontoschlüssel versiegelt; Zugang entsteht durch Übernahme im Browser (ADR 0037). |
| `datenschluesselRecovery.kid/salt/iterationen/iv/wrap/erstelltAm` | `data_key_recovery` | KDF PBKDF2-HMAC-SHA256 kennzeichnen; Salt/Iteration/IV/Wrap exakt erhalten. Bestandsvertrag 600000 Iterationen; Recovery-UI entfernt Bindestriche/Whitespace und schreibt groß **vor** KDF (Review D). Kein KDF-Neulauf ohne berechtigten Schlüsselzugang. **Umgesetzt (ADR 0037):** Format gleich `keys.ts wrapRecovery`; Import bytegleich nur für die im Plan zugeordnete, im Lauf importierte Generation, nur `iterationen=600000`, nie Ersetzen einer neuen Recovery. |
| `datenschluesselProtokoll.ID/zeit/userUUID/aktion/kid/betroffenUUID` | `audit_events` | Historische Schlüsselaktionen inkl. Einrichtung/Rotation/Umstieg erhalten; Einführung darf nicht allein aus noch vorhandenen Generationen abgeleitet werden. Actor-/Objekt-IDs als Snapshot ohne FK. |
| `datenschluesselUmstiegAusnahme.anfrageUUID/grund/gemeldetVon/gemeldetAm` | `migration_issues` plus `audit_events` | Jede Ausnahme einzeln nachweisen, freien Grund vor sicherer Projektion prüfen. Kein Runtime-Ausnahmeflag zum Lesen von :1/CBC. Bereits verwaiste Ausnahme dokumentieren, nicht künstliche Anfrage anlegen. |
| `formularSchluessel.ID/formularUUID`, aktuelle/vorherige UA-/IP-/Ed25519-Werte, drei `...VorherigGueltigBis`, `erzeugtAm/rotiertAm` | `form_protocol_keys` | Je Zweck/Generation eine Zeile; Secretwerte sicher referenzieren, Public Key streng Base64→32 Bytes. Alle drei Fristen einzeln aus Unixsekunden übernehmen, nicht bei Import verlängern. Aktuell/vorherig widerrufbar, keine globalen v1-Rohstrings als v2-Key ausgeben. |
| Altformular ohne Ed25519-Public-Key | `form_protocol_keys` oder `signature_exceptions` | ADR 0002: provisionieren oder ausdrücklich befristete, protokollierte, widerrufbare Formularausnahme. Fehlender Key wird nicht implizit weiter akzeptiert. |
| `vertrauenswuerdigeNetze.ID/bereich/bezeichnung/erstelltAm/angelegtVon` | `trusted_networks` | CIDR/IP normalisieren und Konflikte melden; keine kundenübergreifenden Rechte aus Netzvertrauen ableiten. |
| `otpAttempts.UUID/failedAttempts/lockedUntil/lastAttempt` | OFFEN: `auth_throttles` oder bewusster Neustart | Alte OTP-Sperren und mögliche Passwort-/IP-Sperren nicht kommentarlos löschen. Format/HMAC-Zuordnung, Lockoutschwellen und Übernahme im Cutover mit P2-5 entscheiden. |

**Admin-Domain, WebAuthn-RP-ID und erlaubte Admin-Origin bleiben unverändert (ADR 0003 Nr. 12).** Ebenso UserHandle, Credential-ID, Public Key, SignCount und PRF-/Konto-Key-Hüllen. Neue Kundenhosts werden keine zusätzlichen WebAuthn-Origins. Unveränderte RP-ID allein beweist PRF-Kompatibilität nicht; Browser-/Authenticatorprüfung bleibt nötig. Sessions neu anmelden zu lassen ist von Passkey-/Datenzugangsverlust zu unterscheiden.

**OFFEN, importblockierend:** Derselbe globale Datenschlüssel kann bisher Daten mehrerer zukünftiger Kunden schützen. Bloßes Duplizieren von `kid`, Zugängen und Recovery in zwei Kundenzeilen erhält den gemeinsamen privaten Schlüssel und damit zu breite Entschlüsselbarkeit. Zulässig zu entscheiden ist eine echte Kundenschlüsseltrennung durch berechtigte Migration/Rotation mit passender Paketumhüllung und neuen Zugängen/Recovery. Dabei bestehende Konto-/PRF-Schlüssel nicht ändern. Für unverändert nur einem Kunden zugeordnete Generationen ist bytegleiche Übernahme möglich. Ob ein übergangsweise geteilter Altbestand akzeptabel wäre, ist keine Entscheidung dieses Pakets und wird nicht implementiert.

## Anfragen und Altformatumstellung

| Altspalte `anfragen` | Ziel | Regel |
| --- | --- | --- |
| `ID`, `UUID`, `formularUUID`, `time` | Ledger; `submissions.id/form_id/customer_id/received_at` | UUID erhalten, Formular-/Kundenbezug auflösen. Da alter Anfrage-Formular-FK fehlt, sind NULL/verwaiste Referenzen möglich: OFFEN, nicht auf beliebiges Formular umhängen. |
| kein damaliger Versionsbezug | `release_id=NULL`, `release_evidence='legacy-unknown'` | Aktuelle Konfiguration nicht rückwirkend als zum Eingang gültiges Release ausgeben. Umgebung nur bei Beleg aus Versand-/Konfigurationshistorie, sonst `legacy-unknown`. |
| `data` | `stored_objects` Rolle `data` | NULL bleibt abwesend; Chiffratformat pro Paket prüfen; JSON_FORCE_OBJECT-Klartextbytes bei Umstellung unverändert erhalten, keine erneute JSON-Kanonisierung. |
| `file1Enc`, `file1`, `file1Name` | Rolle `attachment`, verschlüsselte Metadaten | Verschlüsseltes Paket übernehmen/umstellen; offener Blob vor Zielpersistenz auf :2 verschlüsseln. Wenn Blob und Paket existieren: berechtigt Gleichheit prüfen; bei Unterschied beide sicher im Staging erhalten und OFFEN statt eines still zu überschreiben. Dateiname nicht als offenen Object-Key speichern. |
| `mailBody`, `mailBodyFiller` | Rollen `mail-organisation`, `mail-filler` | Nach Entschlüsselung enthaltene Base64-/trim-Repräsentation bytegleich neu verpacken (`content_encoding='legacy-base64-trimmed-mail'`), nicht doppelt encodieren oder als unbearbeitetes HTML interpretieren. |
| `errors` | sichere Projektion in `audit_events`, ggf. :2-Objekt `legacy-errors` | Nicht mit Tabelle `errors` verwechseln. Freitext auf Inhalte/Secrets prüfen, keine Klartextkopie ins Audit. Unbekannte Semantik OFFEN. |
| `sentServer` | `submissions.legacy_sent_server`, ggf. Zustellabgleich | Historischen Wert nur nach Prüfung als sichere Transportkennung übernehmen; er allein beweist keine erfolgreiche Zustellung. Kein Zustellobjekt aus leerem Wert erfinden. |
| `removable` | `submissions.removable` | Exakt erhalten, insbesondere Holds; anwendbare Anfragefrist aus sicher geprüfter Konfiguration, kein Neustart der Frist bei Import. Hold-/Umhängevertrag beachten. |
| `malwareScanStatus` | `submissions.malware_scan_status` | Textstatus erhalten, nicht alle Altanhänge als geprüft deklarieren; 010 markierte vorhandene verschlüsselte Uploads als nicht_geprueft. |

Pro Inhaltsspalte unabhängig klassifizieren: CBC (drei Segmente ohne Präfix), `KUBUS-AEAD:1` (fünf Segmente), `KUBUS-AEAD:2` (sieben Segmente, hpke/sym), NULL/leer/defekt bzw. erkannter Klartext. Nicht jedes unbekannte Format als CBC behandeln. Paketparser, Längen, kanonisches Base64 und `kid` prüfen; reale Daten können gemischte Formate innerhalb derselben Anfrage haben.

ADR 0001 bestätigt: **Nur das getrennte Migrationswerkzeug liest :1/CBC-Inhalte; v1-Header zusätzlich ausschließlich im befristeten Docker-Adapter nach ADR 0004; neue Laufzeit liest/schreibt ausschließlich :2.** :1/CBC im berechtigt entsperrten Werkzeug öffnen, Originalklartextbytes ohne Normalisierung auf :2 umstellen. CBC hat keinen Authentizitätsnachweis: erfolgreiche Padding-/JSON-Prüfung allein ist kein Integritätsbeweis. RSA-OAEP-/MGF1-/PEM-Defaults sind laut Review D noch unverifiziert; synthetische Vektoren vor echter Konvertierung. Originaldump unverändert und sicher halten, private Passphrasen ausschließlich flüchtig, keine CLI-Argumente/Logs/temporären Klartextdateien.

Bereits :2-Pakete sind bytegleich übertragbar, **wenn Kundengeneration und Rechte passen**. Rewrap bei Schlüsseltrennung nur mit autorisiertem Schlüsselzugang; bei zulässigem Umhängen IV/Nutzchiffrat/Tag erhalten und Übergänge hpke→hpke, hpke→sym, sym→sym prüfen, niemals sym→hpke. Jede Änderung der Hülle separat im Ledger erfassen; Klartextbytegleichheit im geschützten Prüflauf nachweisen, nicht aus unterschiedlichen Paket-Hashes ableiten. Zufällige Verschlüsselung nicht bei jeder Importwiederholung neu ausführen: fertiges Zielpaket mit stabiler Objekt-ID sicher wiederverwenden.

Nicht entschlüsselbare/ausgenommene Pakete bleiben ein sichtbarer, blockierender Fehler. OFFEN ist deren fachliche Behandlung (Klärung/gesonderte sichere Archivierung/ausdrücklicher Verzicht); kein stiller Verlust und kein :1/CBC in der neuen Laufzeit. Ein vorheriger Umstieg darf den unveränderbaren Originaldump nicht überschreiben.

**Header-Schlüssel sind keine Anfragepakete.** Alte CBC-Header oder v1-Rohstrings lassen sich nicht durch Base64-Umbenennung in :2 umstellen. SDK-/Adapterrollout und neue Provisionierung müssen vor Annahmefreigabe kompatibel sein. ADR 0004 H11 erlaubt den befristeten Headeradapter nach ../ingest/legacy-adapter.md; dieses Datenpaket führt keinen dauerhaften Altleser ein. Aktuelle/vorherige v2-Schlüssel und Ablaufzeiten sicher erhalten, globale alte Rohschlüssel ausschließlich im Werkzeug; Adapter nur mit formularbezogenen Schlüsseln und explizitem Ablauf/Widerruf aktivieren.

## Annahmeidempotenz: SQL-Spalte enthält mehrere Formate

| Altbestand `anfrageIdempotenz` | Ziel / Transformation |
| --- | --- |
| `ID/formularUUID/anfrageUUID/createdAt`, früherer Rohkey in `idempotenzSchluessel` | Eine `ingest_idempotency`-Zeile: `key_digest=SHA256(trimmed original bytes)`, `legacy_raw_key` bei nötiger Legacyvergleichbarkeit, `digest_evidence='legacy-missing'`, `request_digest=NULL`, `state='complete'`. Fehlenden Hash nicht erfinden; ursprüngliche Anfrageidentität erhalten. |
| `v2-key:<64 hex>` plus `v2-open:<keyhash>:<bodyhash>` | Zwei Quellzeilen auf eine Zielreservierung mit binärem Key-/Requestdigest zusammenführen, `digest_evidence='verified'`, Zustand vorerst `review`; unveränderter Anfragebezug. Geschlossene Grammatik und Paarbezug prüfen, nicht jeden Präfixstring blind umdeuten. |
| `v2-key:<64 hex>` plus `v2-done:<keyhash>:<bodyhash>` | Gleiche Zusammenführung, Zustand `complete`; Hashwerte dekodieren, nicht nochmals hashen. |
| fehlender Partner, mehrere widersprüchliche Partner, verwaister Anfragebezug, Rohkey-/Namespacekollision | `migration_issues`, keine stille Neureservierung/Neuanfrage. Die Quelle speichert Nutzlaststatus in Schlüsseln, nicht in zusätzlichen SQL-Spalten. |

Beleg: `ALT/providers/AnfrageIngest.php:19–33,771–932,1009–1027`; Migration 014 allein zeigt dieses Format nicht. Schlüsselgrenze nach PHP-Trim ist 190 Byte; Hexhash ist kein rekonstruierter Originalkey. Source-FK kann Anfragen/Idempotenz bereits gemeinsam entfernt haben. Beim alten Rohkeyvergleich kann `general_ci` vom neuen Bytevergleich abweichen: Sonderfall ist OFFEN mit P2-1, keine pauschale Behauptung identischer Deduplizierung.

OFFEN: Rohkeytreffer ohne Requestdigest nach autorisiertem Request wie bisher mit 200 zurückgeben oder sichtbar neu behandeln. Neuer Byte-/Payloadvergleich darf keinen erfundenen Konfliktnachweis behaupten. Aktive/unvollständige Reservierungen nach Quiesce auf fachlichen Abschluss abgleichen; Lease nicht als Erlaubnis zu erneutem Versand auslegen. Abgeschlossene Anfrage und vorhandene vorgemerkte Outbox gegebenenfalls freigeben, nie neu erzeugen. Digestnormalisierung gemäß Ingest-Kanonisierung, nicht aus entschlüsseltem historischem `data` nachberechnen (Botfelder/Dateimetadaten können fehlen).

## Zustellungen: Identität, Status und Quiesce

### Mail

`mailZustellung.ID/anfrageUUID/versandModus/versandArt/transportweg/status/versuche/naechsterVersuch/letzterFehler/erstelltAm/aktualisiertAm` → `mail_deliveries` und Ledger. Anfrage/Formular/Kunde auflösen; neue ID einmalig zuordnen, `identity_scope='legacy'`; Modus/Art als exakte Identitätsbytes erhalten. `versuche` und alle Zeitpunkte bleiben erhalten, Fehlertext wird sicherer Code bzw. gesondert geschützter Altbefund. **UNIQUE bleibt fachlich Anfrage + Modus + Art**, Transport ist kein Identitätsteil (026).

| Quellstatus | Zielstatus / Freigabe |
| --- | --- |
| `ausstehend` | `pending`, für importierte Mail ausschließlich manuelle Fortsetzung; vor Außenwirkung ursprüngliche Annahme-/Versandlage prüfen |
| `inBearbeitung` | `uncertain`, alte Übernahme nach Quiesce auflösen; niemals pauschal als nicht versendet zurücksetzen |
| `fehlgeschlagen` | `waiting-manual`; **offen** und zu übernehmen, Versuche/Fälligkeit erhalten |
| `zugestellt` | `smtp-accepted`, `legacy_status='zugestellt'`; Import bewahrt Altbehauptung, behauptet keinen Lesebeleg |
| `aufgegeben` | `abandoned`, bleibt sichtbar und wird mitübernommen; manueller erneuter Versand nur nach separat geprüfter Regel |

Alle ursprünglichen Status zusätzlich in `legacy_status` bewahren. Neue Statusnamen sind OFFEN zur Abnahme; kein Cron darf `pending`/`waiting-manual` automatisch versenden. ADR 0002 Nr. 19 verlangt berechtigten manuellen Resend mit Passphrase, keinen serverseitig gespeicherten Klartext. Aus `fehlgeschlagen` keine neue Mail-ID oder neue Art anlegen. Endgültige und bereits angenommene Vorgänge sind ebenfalls Teil des Paritäts-/Deduplizierungsnachweises und dürfen durch Wiederholung nicht reaktiviert werden.

**Sperre bei Quellstand vor/inkonsistent nach 026:** vorhandenes `versandSequenz` nicht blind auf Art abbilden, leere Art und Kollisionen prüfen. 026 setzt laut Kommentar leere Tabelle voraus, erzwingt das aber nicht; verlorene Sequenzinformation kann nicht rückwirkend ausgedacht werden. Quellcode-/Zustellbeleg und explizite Zuordnung erforderlich, sonst OFFEN und Cutover blockiert.

### Webhooks

`formularWebhooks.ID/UUID/formularUUID/zielUrl/aktiv/ed25519PrivatSchluessel/ed25519OeffentlicherSchluessel/erstelltAm/erstelltVonUserUUID` → `webhook_endpoints`: UUID und öffentlicher Schlüssel erhalten, privater Schlüssel sicher referenziert. Neue URL-/SSRF-Prüfung ohne Versand; Änderungen am Ziel/Signaturschlüssel sind kein stiller Teil des Imports.

`webhookOutbox.ID/UUID/webhookUUID/formularUUID/anfrageUUID/eingegangenAm/status/versuche/naechsterVersuchAm/claimToken/leaseUntil/letzterFehler/createdAt/abgeschlossenAm` → `webhook_outbox`: **Outbox-UUID bleibt Zustellidentität**, Anfrage-/Formularsnapshot erhalten, Zähler/Zeiten übertragen. Kein UNIQUE `(webhookUUID,anfrageUUID)` hinzuerfinden und keine vorhandenen Mehrfachzeilen deduplizieren. Kein Trigger aus 018 importieren; 019 entfernte ihn. Bestehende Jobs direkt übernehmen, nicht durch neue Anfrage-INSERTs erneut erzeugen.

| Quelle | Ziel |
| --- | --- |
| `offen`, fachlich freigegeben, nachweislich kein I/O mehr aktiv | `ready`, alte Claimdaten erst nach Quiesce entfernen, neuen Fence/Token erst beim neuen Claim erzeugen |
| `offen`, `naechsterVersuchAm=2147483647` **und** Marker `Wartet auf fachlichen Abschluss.` | `prepared`; Sentinel nicht als normalen Fälligkeitstermin oder pauschal ready importieren |
| `offen` mit nicht aufgelöstem Claim/Lease oder unklarer externer Annahme | `uncertain`; manuell/über Empfängerdeduplizierung klären, nicht allein nach Ablauf der Lease wieder senden |
| `erfolgreich` | `succeeded`, abgeschlossenen Status erhalten |
| `fehlgeschlagen_endgueltig` | `failed-terminal`, keine automatische Reaktivierung |

Marker-/Sentinelinterpretation ist statisch in `WebhookOutboxEinsteller.php` belegt; andere ferne Fälligkeit ohne Marker ist nicht automatisch Vormerkung. Alter Payload besitzt Ereignis, Zustell-/Formular-/Anfrage-ID und Zeit, keine Formularwerte. Signatur-/Payloadbytes und stabile Zustell-ID vor Receiververgleich prüfen. Ohne dokumentierte Receiver-Idempotenz sind HTTP-Retries nach unklarer Antwort ebenfalls möglicherweise doppelte Effekte.

### Späteres Quiesce-Verfahren (ADR 0002 Nr. 18; hier nur beschrieben)

1. Probeimport und Mappingabnahme abschließen, Rollbackfenster und Verantwortliche festlegen. SDK-/Signatur-/Admin-Origin-Kompatibilität nachweisen. Neue Worker/Annahme bleiben aus.
2. Alle alten schreibenden Eingänge pausieren: Submit, Resend, Admin-/MCP-Konfigurationsänderungen, Schlüsselrotation, Cron-/Webhookworker, Retention und weitere Jobs. Bereits laufende Requests kontrolliert abschließen oder als unklar inventarisieren. Nur gestoppte Timer ohne beendete Prozesse reichen nicht.
3. Keine neuen Claims; laufende Zustellungen beenden lassen, Quellstatus/Receiverbelege aufnehmen. Bei Absturz/Timeout unklare Mail-/Webhookvorgänge festhalten. Ablauf einer Lease ist kein Versandnachweis. Alten Workerzugriff technisch gesperrt halten, bevor Zielworker starten.
4. Konsistenten finalen Dump mit Schema, Tracking, Zeitzone und stabiler Quellidentität erstellen lassen; Quiescezeit und letzte Writes beweisen. Kurzes Fenster gemäß ADR 0003, exakte Dauer OFFEN. Keine Langläufer-Konvertierung ungeplant in dieses Fenster verlagern.
5. Finale Änderungen einschließlich Löschungen mit dem Probeimport abgleichen, sichere Importtransaktionen wiederaufnehmen. Keine Altsystem-Cronjobs, Trigger oder Empfängeraktionen im Ziel auslösen. Verbleibende Claims nur nach bewiesenem Stillstand abbilden, `uncertain` bleibt gesperrt.
6. Mengen-, Referenz-, Hash-, Berechtigungs-, Krypto-, Statistik- und Zustellparität prüfen; alle importblockierenden OFFEN-Punkte beheben. Mensch bestätigt vorbereitete Aktivierung; Admin-Domain/RP-ID unverändert. Zunächst genau ein aktives System, Zielworker kontrolliert freigeben; Mail bleibt manuell.
7. Wiederholversuche mit denselben IDs beobachten. Bei Rückfall neue Zielanfragen/-effekte/-Statistiken sichern und bewusst rückführen/abgleichen. Einfaches Zurückschalten würde neue Daten verlieren oder Effekte doppeln. Kein Dual Write ohne gesonderten Beschluss.

## Statistik, Audit und übriges Altinventar

| Alttabelle / Spalten | Ziel | Transformation / Entscheidung |
| --- | --- | --- |
| `statistics.ID/UUID/timestamp/formularUUID/status/type/domain` | `legacy_statistics.source_id/legacy_uuid/occurred_at/form_id/customer_id/legacy_status/legacy_type/domain` | Quellnamespace+ID eindeutig; UUID nicht als UNIQUE voraussetzen. Alle zehn Status und `ANFRAGE`/`VISIT`/NULL erhalten. Keine historischen `begin`/`abandon`, Releases, Umgebungen oder Besuchspseudonyme erfinden. |
| `statistics.gclid/userAgent` | `legacy_statistics.metadata_object_id`, Herkunft legacy | Ads-/Altfilterfähigkeit nicht still verwerfen. ADR 0004: Nicht-IP-Metadaten vollständig als geschützte Altprojektion mit origin=legacy erhalten, keine 13-Monatsfrist. Neues Ereignismodell bleibt getrennt; künftiger Conversionexport/Format bleibt OFFEN. IP-Werte, die der Dump tatsächlich enthält (Spalte, Metadaten, Freitext/Domain), gehören nach ADR 0005 D7 zur Übernahme (siehe Absatz darunter, M04); sie werden nie ergänzt oder abgeleitet, keine UA als Pseudonym hashen. |
| `statistikLoeschprotokoll.ID/UUID/geloeschtAm/geloeschtVonUserUUID/geloeschtVonUsername/anzahl/statistikUUIDs/filter` | `deletion_records`, Kategorie statistics | UUID/Quelle, Zeit, Akteur und Anzahl erhalten, zulässige gelöschte IDs/Filter als geprüfte Snapshotprojektion. Nicht zum Löschen der übrigen Statistik missdeuten. Löschprotokoll bleibt (ADR 0003 Nr. 10), keine Kopie von UA/GCLID/Pseudonymen. Namen/Filterminimierung OFFEN. |
| `anfragenLoeschprotokoll.ID/UUID/deletedAt/deletedByUserUUID/deletedByUsername/anfrageUUID/anfrageZeitpunkt/formularUUID/formularName/rechtsgrundlage/notiz` | `deletion_records`, Kategorie submission | drei Rechtsgrundlagen erhalten, Anfrage-/Formularsnapshot und historische Anfragezeit in sicherer Projektion, keine FK-Kaskade. Notiz/Namen auf sensible Inhalte prüfen; Minimierung vs. Nachweiserhalt OFFEN, keine stillen Verluste. |
| `exportProtokoll.ID/UUID/exportiertAm/exportiertVonUserUUID/exportiertVonUsername/formularUUID/formularName/format/anzahlAnfragen/vonDatum/bisDatum` | `audit_events`, Kategorie export | csv/json, Zahl, Zeitraum, Akteur/Objekt-/Namenssnapshot nach freigegebener Projektion; kein Exportinhalt. Exportanforderung ist kein belegter abgeschlossener Download. |
| `konfigurationsProtokoll.ID/UUID/geaendertAm/geaendertVonUserUUID/geaendertVonUsername/configName/aktion/alterWert/neuerWert` | `audit_events`, Kategorie configuration | Aktion erstellt/geaendert/geloescht und Name/Actor/Zeit erhalten. Alt-/Neuwerte nur Allowlist und Maskierung, Secretwerte nicht als Audittext. Vollständige Archivierung sensibler Altwerte ist OFFEN, nicht automatisch verwerfen. |
| `anmeldeProtokoll.ID/zeitpunkt/userUUID/weg/erfolg/clientIP/grund` | OFFEN: sichere `audit_events`-Projektion, Kategorie authentication | passwort/passkey/totp und Ergebnis erhalten, IP nicht in Statistik mischen; Alt-IP-Aufbewahrung/Redaktion und freie Gründe mit P2-5 entscheiden. P0-B nennt 90 Tage, keine neue Freigabe dieses Pakets. |
| `errors.ID/UUID/formUUID/anfrageUUID/clientIP/time/errorCode/errorMsg/correlationId/event/operation/safeMessage` | OFFEN: sichere `audit_events`-Projektion bzw. getrennte Betriebsablage | Korrelation, sichere Ereignis-/Operationscodes und IDs nutzbar; freie Nachricht, vermeintlich sichere Nachricht und IP trotzdem prüfen. Keine pauschale Übernahme von Klartext-/Secretwerten. Altzeit `varchar` explizit parsen. Nicht mit `anfragen.errors` verwechseln. |
| `hitLogCritical.ID/UUID/time/clientIP/clientUA/removable/count` | OFFEN: begrenzte Sicherheitsmigration in `auth_throttles`/sicheres Audit, sonst dokumentierte Nichtübernahme | Kein Statistikereignis; fachliche Sperr-/Zählerbedeutung erst klären. Alte UUID nicht UNIQUE. Keine ungeprüften IP-/UA-Debugkopien. |
| `hitLogMemory.ID/time/clientIP` | OFFEN: bewusster Neustart gemeinsamer `auth_throttles` | Alte MEMORY-Zeitfenster nicht pro Zielreplika importieren. Frist, Sperrkontinuität und Missbrauchsschutz beim Cutover entscheiden. |
| `blockList.ID/clientIP/blockedUntil/createdAt` | OFFEN: `auth_throttles` als Sperrprojektion | gültige Sperren nicht ungefragt aufheben. Subject-HMAC/Scope/Laufzeit und historische Behandlung aus P2-5; 007 hat Bestandsfristen einmalig gekappt, kein neuer pauschaler 30-Tage-Vertrag. |
| `mcpToken.ID/UUID/userUUID/tokenHash/.../grantUUID` | **nicht übernommen** (ADR 0005 D4) | Alte manuelle MCP-Tokens verfallen mit dem Cutover; Neuausstellung durch Nutzer. Kein Hash-, Scope- oder Grantimport. Anzahl nur im Importbericht (ohne Werte). Ob handerzeugte Tokens unter D4 fallen, ist aus dem ADR-Wortlaut abgeleitet (Rückfrage im Handoff). |
| `mcpTokenProtokoll.ID/UUID/zeitpunkt/userUUID/ereignis/...` | `audit_events`, Kategorie mcp | manuelle und OAuth-Ereignisse, IDs und Zeit sicher projizieren; keine Tokens/Secrets. Übernahme/Frist der Historie OFFEN. |
| `mcpOauthClient.*` | **nicht übernommen** (ADR 0005 D4) | Neuanmeldung/neue Clientregistrierung nach Cutover; kein `origin=legacy`. |
| `mcpOauthGrant.*` | **nicht übernommen** (ADR 0005 D4) | Altgrants verfallen; keine Scope-/Resource-Ableitung, kein Consentimport. |
| `mcpOauthCode.*` | **nicht übernommen** (ADR 0005 D4) | Codes (kurzlebig) werden nicht importiert. |
| `mcpOauthRefresh.*` | **nicht übernommen** (ADR 0005 D4) | Keine Refreshfamilien- oder Replayhistorie importieren; alle Altwerte sind am neuen System ungültig. |
| `schema_migrations.dateiname/checksum/angewandt_am` | `migration_runs.report_json`, referenziertes Quellschemamanifest | Tracking/Dateihashes als Quellbeleg, **nicht** als Ziel-DDL-Migrationen verbuchen. NULL/leer/abweichend sichtbar; weder fehlende Historie erfinden noch 025 ergänzen. |
| alte prozess-/dateibasierte Sessions, Timer (keine belegte zu importierende Fachtabelle) | OFFEN: bewusster Sessionneustart; neue `sessions`/`job_leases` | keine Prozess-/Lease-/Cookiekopie zwischen Systemen. Neue Sessions nach Anmeldung, Jobs erst nach Aktivierung. Prüfpflicht für beabsichtigte Invalidierung; Passkeys/PRF bleiben erhalten. |

ADR 0004 M04 entscheidet den bisherigen Fristkonflikt: Gesamter Altbestand
mit Herkunft `legacy` übernehmen, keine 13-Monatsfrist auf Altzeilen anwenden.
**ADR 0005 D7 (BESCHLOSSEN) ersetzt die frühere Vorgabe „IP-Bezug nicht importieren":**
Der Altbestand wird komplett übernommen, **einschließlich möglicher IP-Bezüge**;
das ist ausdrücklich gewollt, obwohl IP-Adressen personenbezogen sind und ADR 0003
IP-Speicherung für neue Statistik ausschließt. 13 Monate gelten nur für neu erhobene
Daten. Bedingungen (Formulierung der technischen Umsetzung VORGESCHLAGEN):

1. **Bestandsprüfung vor dem Import (Importvoraussetzung):** Am echten Dump wird
   geprüft, ob und wo IP-Bezüge vorkommen (eigene Spalte, in `gclid`/`userAgent`,
   `domain`, Freitext, Verknüpfungen). Ergebnis (Zählwerte je Spalte/Muster, keine
   Originalwerte) wird als freigegebener Prüfbericht festgehalten; ohne ihn kein
   Importlauf für `statistics`. Die Prüfung ist nicht ausgeführt.
2. **Herkunft:** jede Zeile `origin='legacy'`; IP-Werte nie in `statistics_events`.
3. **Ablage:** IP-Werte nicht in Klartextspalten, sondern als Feld im
   verschlüsselten `statistics-metadata`-Objekt (`metadata_object_id`, geschützte
   Hülle). Ein inhaltsfreies Flag `has_ip_reference` darf ergänzt werden, analog
   `has_gclid`/`has_user_agent`; die `has_*`-Flags bleiben.
4. **Beschränkter Zugriff:** Werte nur lokal im Browser nach Abruf des Objekts mit
   `statistics.read` UND `content.decrypt`; kein MCP-/Token-Pfad, kein Export der
   IP-Werte ohne `content.export`, kein Serverklartext.
5. **Keine Personenebenenauswertung:** keine Filter, Gruppierungen, Joins,
   Suchen oder Exporte nach IP-Wert; Aggregatsichten und Berichte enthalten nur
   `has_*`-Flags und Zählwerte; keine IP-Hash- oder Pseudonymbildung als Umgehung.
6. **Importbericht ohne Originalwerte:** `migration_runs.report_json` /
   `migration_issues` führen Zählwerte, Spaltenherkunft und Herkunft `legacy`,
   nie IP-/UA-/GCLID-Werte.
Fehlende historische begin/abandon/Pseudonyme nicht erfinden. Alt- und Neusemantik
mit Herkunftsfilter getrennt anzeigen, keine rückwirkende Conversion behaupten.

## Referenzen und Löschung vor dem Import prüfen

Review C dokumentiert: alte echte FKs haben CASCADE, aber nicht jede gleichnamige UUID-Spalte einen FK. Anfrage hat keinen Formular-FK; Outbox keinen Anfrage-/Formular-FK, nur Endpunkt-FK; Audit/Löschlogs und zahlreiche Konto-/Schlüsseltabellen besitzen keine FKs. Deshalb alle Referenzen separat prüfen, nicht einfach `FOREIGN_KEY_CHECKS=0` setzen und nachher Erfolg melden.

Alt-CASCADE: Statistik→Formular; Formularzugriff→Konto/Formular; Felder/Protokollschlüssel/Trefferweg→Formular; Idempotenz→Formular/Anfrage; Mail→Anfrage; Webhook→Formular und Outbox→Webhook; Fehler→Anfrage. Verwaiste `errors` wurden durch 005 einmalig gelöscht. Neue RESTRICT-Vorschläge verlangen einen abgestimmten Löschdienst; keine Produktparität ohne Review. Outboxeinträge zu bereits gelöschter Anfrage können fachlich legitim sein und werden mit Snapshot übernommen, nicht wegen fehlender Anfrage verworfen. Umstiegsausnahmen und unabhängige Nachweise dürfen ebenfalls verwaist sein.

Wenn ein finaler Dump gegenüber Probeimport Objekte nicht mehr enthält, Abwesenheit ausdrücklich abgleichen: zulässige Löschung/Retention mit Nachweis anwenden oder Konflikt melden, nicht einfach Probeimportreste aktivieren. Ein alter Dump darf nach Löschantrag keine gelöschten Datensätze wiederbeleben. Sicherheits-/Löschtombstones bzw. finale Snapshotzugehörigkeit im Importplan vor Aktivierung berücksichtigen; genaue Ledgererweiterung ist OFFEN.

## Importprotokoll: Idempotenz und Wiederholbarkeit

Dies ist ein Entwurf für P9, kein ausgeführter Importbefehl:

1. **Plan/Prüflauf:** immutable freigegebenen Dump offline inventarisieren, Quellstruktur/Tracking/Counts prüfen; Parser darf keine beliebigen Dump-DDLs, Trigger, Routinen oder Fremdbefehle in der neuen Laufzeit ausführen. Getrenntes isoliertes Staging/Restore nur nach späterer Freigabe. Prüflauf erzeugt Plan, Mengen/Abweichungscodes und offene Zuordnungen, keine Seitenwirkungen/Schlüsselrotation.
2. **Einzellauf sperren:** Importdienst nimmt schemaspezifische exklusive Sperre/Lease; genau ein Writer. Neues Ziel bleibt für Annahme/Worker/Retention deaktiviert. `migration_runs` identifiziert Quelle+Dump+Mapping+Importer eindeutig. Wiederholung desselben Plans setzt denselben Lauf fort; ein Mappingwechsel erzeugt kontrolliert einen neuen Plan.
3. **Abhängigkeiten:** Kunden-/Besitzplan → Konten/Mitgliedschaften → Passkeys/Kontohüllen → Kundengenerationen/Zugänge/Recovery → Verbindungen → Formularstämme/Zugriff/Protokollschlüssel → Definitionen/Ansichten/Abläufe als Entwurf → Anfragen/Pakete/Idempotenz → Webhookendpunkte und vorhandene Zustellungen → Altstatistik/Audit/Nachweise. Audit-Snapshots brauchen keine lebenden Akteure. Releases erst nach menschlicher Bestätigung, nicht als Importnebenwirkung.
4. **Objektweise Transaktion:** Zielschreibsatz und alle `migration_objects`-Zuordnungen gemeinsam committen. Eine Quellzeile kann mehrere Rollen/Zieltupel erzeugen (`target_slot`), zwei Idempotenzzeilen können eine Reservierung ergeben. Mehrfachzuordnungen zählen nicht als zusätzliche Anfragen. Für Geheimnis-/Paketnachweise keyed HMAC über definierte Bytes/Struktur statt öffentlicher Hashes niedrigentropischer Werte; Import-HMAC-Schlüssel sicher referenziert und für Wiederholung stabil. Dumpdateihash bleibt SHA-256, Schlüssel nie im Manifest.
5. **Wiederholung:** gleicher Namespace/Tabellenschlüssel/Slot mit gleichem Quell-HMAC → Ziel-HMAC und Existenz prüfen und überspringen. Abweichung auf beiden Seiten ist Konflikt, kein blindes UPSERT. Fehlendes Ziel bei vorhandener Zuordnung ist Reparatur-/Löschfall, nicht automatisch neu anlegen. Abbruch vor Commit erzeugt kein Ledger; nach Commit darf wiederholter Lauf keine ID, Hülle, Zustellung oder Statistik duplizieren. Fortschrittscursor ist nur Beschleunigung, Ledger/Datenvergleich bleiben maßgeblich.
6. **Externe Objekte/Secretablage:** stabiles Objekt-/Secretziel vorbereiten, vollständiges Chiffrat/Referenz prüfen, dann DB-Zuordnung committen. Absturz dazwischen hinterlässt höchstens ein wiedererkennbares vorbereitetes Objekt, niemals positive Annahme ohne Daten. Bereinigung/Retry darf keinen verwendeten Schlüssel oder erfolgreich übernommenes Objekt löschen. Quellseitig nichts ändern.
7. **Finaler Dump:** auf inaktivem Staging belegte Quelländerungen kontrolliert anwenden, Mappingidentität/IDs behalten; fehlende Zeilen als eigene Differenz behandeln. Geänderte abgeschlossene Zustellung wird aus finalem Beleg übernommen, nicht reaktiviert. Bereits aktive Zielbestände dürfen durch erneuten Import nicht überschrieben oder durch einen älteren Dump zurückgesetzt werden. Solcher Lauf ist gesperrt und benötigt gesonderte Abgleichstrategie.
8. **Prüfen/Aktivieren:** erst alle Invarianten und sicheren Paritätsberichte, dann `verified`; `activated` erst nach separater menschlicher Cutoverfreigabe. Fehlerberichte enthalten nur technische IDs, Codes, Counts und sichere Referenzen, keine SQL-Zeilen, Schlüssel oder Feldwerte. Offene Blocker lassen Lauf unaktiviert. Bericht fasst übernommen/nicht übernommen/ausgenommen/fehlgeschlagen je Alttabelle zusammen, einschließlich aller bewussten Invalidierungen.

## Geplante Abnahmefälle — NICHT ausgeführt

| Prüfbereich | Nachweis / Negativfall |
| --- | --- |
| Inventar/Vollständigkeit | Jede oben genannte Alttabelle und tatsächlich vorhandene Zusatzspalte hat Importregel oder explizite offene Ausschlussentscheidung; Quelltracking samt fehlenden/abweichenden Hashes dokumentiert. Kein Baseline-only-Import. |
| Mengen/Referenzen | Counts und stabile Mengen-IDs pro Kunde/Formular/Rolle/Status; UUID-Duplikate, verwaiste Bezüge und Nullzeiten; 1:n-Paketabbildung und 2:1-Idempotenz berücksichtigen. Kein neuer kundenübergreifender FK/Zugriff. |
| Konfiguration/Felder | Alle sieben Feldarten, Reihenfolge, NULL/Leerstring, Regeltypen/PCRE, unbekannte POST-Felder, erste Datei/E-Mail, drei Spezialhandler, beide Mailvorlagen/-ziele und Produktions-/Testmodus synthetisch vergleichen. Neue strengere Validierung nicht als Parität deklarieren. |
| Krypto | Synthetische CBC/:1/:2-hpke/:2-sym sowie gemischte Anfrage; leeres Nutzchiffrat, beschädigte Pakete, falscher kid, fehlender Schlüssel, Hold und Migrationausnahme. Unveränderte :2-Bytes bzw. entschlüsselte Originalbytes nach Umstieg, einschließlich Base64-Mailvorschau und Blobdatei. Kein Altformat im Laufzeitziel. |
| Konto/PRF/Recovery | Passworthash, MFA-Alt-/Präfixformat, Doppel-Base64; Passkey-ID/Public Key/UserHandle, unsigned Zähler und 0/0; unveränderte RP-ID/Admin-Origin, PRF-Hülle und normalisierte Recovery im echten Browser. Getrennter Kunde darf fremde Generation nicht entschlüsseln. |
| Idempotenz | Rohkey, v2-key/open/done, fehlender Partner, Prefixkollision, 190/191 UTF-8-Byte, alter Kollationsvergleich, Nutzlastabweichung; Replay und Leaseübernahme behalten Anfrage-/Outboxidentität und starten keinen weiteren Effekt. |
| Mail-Cutover | Alle fünf Status einschließlich fehlgeschlagen; 026 mit nichtleerem/unklarem Bestand; laufender SMTP-Aufruf beim Stoppen; unklare Annahme bleibt gesperrt; Resend nur mit aktueller Berechtigung/Passphrase, Cron meldet nur. |
| Webhook-Cutover | offene/terminale Jobs, zwei gleiche webhook/anfrage-Paare, Vormerksentinel, ausstehender fachlicher Abschluss, alter Claim nach Zielstart, bereits gelöschte Anfrage; stabile Outbox-ID/Signatur und keine Trigger-Neuerzeugung. |
| Mehrworker/Crash | Gleichzeitiger Claim, Crash vor/nach Commit und externer Annahme, Leaseverlust/alter Fence, verspäteter Commit, Uhr-/Deadlinegrenzen, keine Budgetrücksetzung nach Warten/Schleife. Keine SMTP-Genau-einmal-Behauptung. |
| Statistik | Originalcount nach Formular/Domain/Status/Typ/Tag, NULL-Typ und gleiche UUID mit verschiedenen IDs; keine erfundenen neuen Events; Conversion getrennt, Nenner null; IP-Bezüge (falls im Dump) geschützt übernommen, Importbericht ohne Originalwerte, kein IP-Wert in Aggregaten, 13-Monatsgrenze nur für Neudaten, offene Altzeilen/Ads nicht unbemerkt wegwerfen. Löschprotokoll bleibt. |
| Löschung/Retention | Holds unverändert, Anfrage-/Outboxlebensdauer und unabhängiges Audit; finale Löschung zwischen Probe- und Finaldump; erneuter Altimport darf Löschung nicht rückgängig machen. S3-/SFTP-Teilfehler nachvollziehbar. |
| Wiederholung | Gleichen Dump zweimal, Abbruch zwischen zwei Objekten und nach Zielcommit vor Fortschrittscursor; identische IDs/Paketbytes/Counts, keine neue Mail/Webhookaktion, keine neue Schlüsselgeneration; abweichendes Mapping/Quelle/Ziel führt sichtbar zum Konflikt. |
| Rückfall | Zielwrites seit Aktivierung und externe Effekte inventarisieren; kein blindes Zurücksetzen. Wiederanlaufplan mit klarer Systemführerschaft. |

## Fortsetzung und Grenzen

Tatsächlich geprüft: statischer Abgleich mit den angegebenen Dokumenten und gezielten SQL-/Providerquellen; Textprüfung der drei Ergebnisdateien. Keine ausgeführten Produkt-, Import-, SQL-, DB-, Entschlüsselungs-, Browser-, Versand- oder Crashprüfungen. Kein Quell-/Zieldump oder tatsächlicher Migrationsstand geprüft. Keine Behauptung ausführbaren DDLs oder erfolgreicher Migration.

OFFEN vor Implementierung: Kunden-/Schlüsselzuordnung; MariaDB-/Fluent-/Kollationsvertrag; Krypto-/Headerübergang; unbekannte Historie/Referenzen; Menschfreigabe importierter Aktivität; Definition-/Handlerparität; Retention/Altstatistik/Ads; OAuth-/Session-/Sperrkontinuität; feine Rechte, Leasewerte und Rollback. Nächster Schritt: unabhängiges Review und Abstimmung P2-1/2/4/5; danach erst synthetischer P3-/P9-Probelauf mit separater Freigabe.

Dateibesitz/Arbeitsstand: ausschließlich die drei Dateien in `contracts/data/`, bestehender Checkout `main`, kein Branch/Worktree/Commit/Remote neu angelegt, keine Delegation oder laufenden Jobs dieses Pakets. Die strikte Schreibgrenze hat Vorrang vor den allgemeinen STATUS-/ARBEITSPLAN-Aktualisierungen; Koordination übernimmt diesen Fortsetzungsstand in die zentralen Dokumente. Altprojekt unverändert, keine Code-/SQL-Ausführung und kein Zugriff auf `secrets/`.


Technischer Nachtrag 27.10.2026 (**VORGESCHLAGEN**): gemeinsame Identitäts-/
Versions-/Generationszuordnung, Authpersistenz und Idempotenz siehe
`abbildung.md`; Gesamtinventar und Holdliste siehe `objektinventar.md`.
Diese Nachträge ersetzen widersprechende ältere technische Aussagen; alte
Tabellenzahlen/Prüfstände oben beschreiben ausschließlich den vorherigen Stand.
Die frühere Offenliste ist durch ADR 0004 ersetzt; technische Detailprüfungen bleiben offen gemäß Nachtrag unten.


## ADR 0004 — aktueller Importvertrag

- H02: alte Rollennamen ausschließlich als Vorlagenherkunft in template_name,
  bisherige objektbezogene Berechtigungen als explizite permission_assignments
  im belegten Kunden-/Formularscope materialisieren. Keine pauschale Umwandlung
  einer Altzuordnung in alle neuen Funktionsrechte; konkrete Alt→Einzelrecht-
  Zuordnung als VORGESCHLAGEN vor Rechteparitätsabnahme prüfen. Gruppen frei
  anlegbar/änderbar, kein Template-/system_role-Bypass; unbekannte Rechte ablehnen.
- M02: jedes Altformular mit validation_profile=legacy-v1 und gehashtem,
  unveränderlichem legacy_adapter_ref; typisierte Neudefinition als separate
  bewusste Umstellung. Spezialhandler/Leerwerte/Bools/erste Datei beibehalten.
  Scannerentscheidung/418/424 OFFEN, bis Entscheidung Altverhalten.
- H07/H09: importierte Läufe/Zustellungen nicht automatisch reaktivieren;
  menschliche Freigabe nach ../flow/wiederanlauf.md. Resend nur bei belegtem
  Original-/Versandmanifest, keine rückwirkend erfundenen Empfänger/Vorlagen.
  Bearbeiten als neue Einsendung mit source_submission_id, Original bleibt.
- M05: Clients, Grants, Codes, Access-/persönliche Tokens und Refreshdaten
  gemeinsam aus demselben quieszierten Snapshot importieren. Ledger bindet
  jede Quellidentität stabil; fehlende UUID einmal zuordnen, nicht Hash als ID.
  Hashbytes nicht neu hashen, kürzen oder als Klartexttoken interpretieren.
  hash_format benennt das tatsächlich synthetisch verifizierte Altformat.
  Länge/Encoding, Hashfunktion, etwaiger Pepper/Secretbezug, Tokenpräfix,
  PKCE-Methode und Vergleichssemantik sind **OFFENER Prüfauftrag**. Benötigte
  Secrets nur außerhalb des Repos über sicheren Provider übertragen.
  255-Byte-DDL-Grenze ist VORGESCHLAGEN; inkompatibles Format sichtbar blockieren,
  niemals still abschneiden. Client-/Grant-/Kontobezüge redundant abgleichen,
  Resource/Scopes dürfen nicht erweitert, Ablaufzeiten nicht verlängert werden.
  Keine erneute Zustimmung erforderlich; offener Formatbefund sperrt Aktivierung
  des betroffenen Imports und ist keine beschlossene Neuausstellung.

Abnahme zusätzlich: noch gültiges altes Token/Refresh funktioniert nach
verifiziertem Import mit gleichen Rechten; abgelaufene/widerrufene/ersetzte/
verbrauchte Credentials bleiben gesperrt; paralleler Refresh bleibt ein Verbrauch;
wiederholter Import reaktiviert keinen Widerruf/Verbrauch. Zielseitig jüngeren
Widerrufs-/Verbrauchsstatus nicht durch älteren Dump zurücksetzen. Keine
Credentialwerte in Fixtures/Logs/Berichten. Nicht ausgeführt.

## Vertragsrunde 3 — R08, M04, M05 (VORGESCHLAGEN, 28.10.2026)

### R08 / ADR 0005 D4 OAuth/MCP: keine Übernahme (BESCHLOSSEN)

Der Entwurf eines Legacy-OAuth-Profils (`resource_binding='legacy-unbound'`,
Importregeln für Resource, Refreshfamilie ohne Familienbezug, Hash-/Pepper-/PKCE-
Formatimport) ist **entfernt**. ADR 0005 D4 ersetzt ADR 0004 Nr. 8: Altcredentials
(OAuth-Clients, -Grants, -Codes, -Refreshwerte, MCP-Tokens) werden nicht migriert.

- **Cutover-Folge:** Alle MCP-/OAuth-Clients melden sich nach dem Cutover neu an;
  Altgrants und -tokens verfallen, nichts wird verlängert, aufgefüllt oder
  zwischengespeichert. Der Importbericht nennt höchstens Zählwerte der nicht
  übernommenen Zeilen, keine Hashes, Tokens oder Clientgeheimnisse.
- **Hashformat-/Pepperprüfung entfällt** als Importvoraussetzung (kein Secret aus
  dem Altbestand wird gebraucht). Der Altquellcode bleibt nur Referenz für das
  Verhalten neuer Credentials.
- **Neu (bleibt):** strikte Resource-Bindung für neue Credentials, Replay-/Parallel-
  Refresh-Schutz und Grantwiderruf wie in `../auth/mcp.md`.
- **Abnahme (nicht ausgeführt):** Alttokenwerte am neuen System abgelehnt;
  Neuanmeldung mit `resource` erfolgreich; Zeilenzähler `oauth_*`/`mcp_tokens`
  aus Import = 0.


### M04 Projektion der Altstatistik (Ads, Metadaten, Filter)

- Inhaltsfreie Sicht (`statistik_ads`, `GET statistics?kind=ads`, MCP): ausschließlich
  Aggregate aus `legacy_statistics` (`occurred_at`, `legacy_status`, `legacy_type`,
  `domain`, `has_gclid`, `has_user_agent`). Beispiel: Anzahl Anfragen mit GCLID je
  Zeitraum. Keine GCLID/UA-/IP-Werte, keine Pseudonyme, keine Hashes davon.
- Herkunftsfilter `origin=legacy|native|all` (Standard `all`, aber die Antwort
  trennt Reihen je Herkunft; keine gemeinsame Conversionquote über beide
  Semantiken). Zeitfilter wirkt auf die Originalzeit `occurred_at`; Altzeilen
  unterliegen keiner 13-Monatsfrist und keiner Löschung durch den TTL-Job.
- Zugriff auf verschlüsselte Altmetadaten (Werte): nur lokal im Browser nach
  Abruf des `statistics-metadata`-Objekts; Rechte `statistics.read` UND
  `content.decrypt` (Schlüsselzugang K, H); kein Token-/MCP-Pfad, kein
  Serverklartext, kein Export als unmaskierte Liste ohne `content.export`.
  Kein neues Recht erfunden; die Kombination ist eine VORGESCHLAGENE Bindung an
  bestehende Einzelrechte.
- Importzeit setzt `has_*`-Flags aus dem Quellwert, bevor dieser verschlüsselt wird.
  Quellwerte mit IP-Bezug werden nach ADR 0005 D7 mitverschlüsselt (Feld im selben Objekt, `has_ip_reference`), nie in Aggregaten; Voraussetzung ist die Bestandsprüfung am Dump.
- Keine erfundenen begin/abandon/Pseudonyme, keine Rückrechnung neuer Conversion.
- **OFFEN (Produkt):** Format eines künftigen Conversion-/Ads-Exports (z. B. CSV für
  Google Ads) – nicht ohne Anforderung erfunden.

### M05 Funktionsbesitz (je Funktion Besitzer, DTO, Persistenz, Abnahme)

| Funktion | Besitzer | DTO / Vertrag | Persistenz | Abnahme |
| --- | --- | --- | --- | --- |
| OAuth-Neuanmeldung (ADR 0005 D4, keine Übernahme) | data + auth | `mcp.md` | `oauth_*` mit strikter `resource`, `origin='native'` | Altwerte abgelehnt, Neuanmeldung, Replay/Parallelrefresh |
| Persönliche MCP-Tokens | data + auth | `mcp_tokens`, `hash_format` | `mcp_tokens` | neue Tokens; Alttokens am neuen System abgelehnt (D4) |
| MFA-/Integrationssecretprovider | auth + Betrieb | **OFFEN** Providerwahl | `mfa_secret_ref` | Betriebsentscheidung nötig |
| Paritäts-DTOs (siehe auth/HANDOFF) | auth | je Aktion in `admin-api.openapi.yaml` | je Funktion | Fortlaufend P3-5 |
