# Einzelrechte, Rechtegruppen und gemeinsame Autorisierung

Stand: 26.10.2026. SPDX-License-Identifier: AGPL-3.0-only.
**BESCHLOSSEN ADR 0004 H02:** Jede Funktion ist einzeln berechtigbar.
Nutzer können Rechtegruppen selbst anlegen und ändern. Admin/Betreuer/Kunde
sind nur Vorlagen; Rollenname, Mitgliedschaft oder Formularzuordnung erteilt
kein implizites Aktionsrecht. Die folgende frühere Matrix ist ausschließlich
**VORGESCHLAGENE Vorlagenbelegung**, keine feste Rollenmatrix oder Ausschlussregel.
Jede Spalte darf durch Einzelrechte/Gruppen konfiguriert werden; H-/K-Gates
bleiben unabhängig von der Vorlage verbindlich.

## Bereich und Vorlagen

Rechtekatalog in OpenAPI `Permission`: nur registrierte Einzelrechte zulässig,
keine Wildcards oder freien Rechtetexte. Unbekannte Rechte werden in UI/REST/MCP,
Import, Gruppeneditor und Persistenz abgelehnt (422 im API-Entwurf). Neue
Funktionen brauchen vor Freigabe einen Katalogeintrag; Gruppen erfinden keine
neuen ausführbaren Rechte. Gruppen dürfen frei benannt werden.

VORGESCHLAGENER technischer Vertrag: `PermissionScope` ist systemweit oder ein
konkreter Kunde mit optional genau einem Formular desselben Kunden. Systemweite
Vergabe bedarf systemweitem `identity.manage`; kundenbezogene Administration
kann nur innerhalb ihres Bereichs delegieren. Eine Formulargruppe darf weder
fremde Kunden noch systemweite Aktionen freischalten. Kontoselbstverwaltung
bleibt auf das eigene Konto begrenzt. Änderungen nur mit aktuellem
`identity.manage` für den gesamten betroffenen Bereich und menschlicher Sitzung;
keine Selbstprivilegierung über eigene Grantmenge/Gruppenänderung hinaus.
Vorlagen werden ausdrücklich in normale Grants kopiert; spätere Vorlagenänderung
ändert keine bestehenden Grants.

Direktgrant und Gruppenmitgliedschaft enthalten denselben Scope und
`revokedAt`; Gruppen enthalten Katalogrechte, eigene Revision und Widerrufsstatus.
Effektiver Bereich ist Schnittmenge aus Gruppenbereich und Zuweisungsbereich;
Zuweisungen außerhalb der Gruppe ablehnen. Kunde ohne formId umfasst alle seine
Formulare; Formularscope nur dieses Formular. Scopeerweiterung ist eine neue
bewusste Vergabe. Zusammenführung gültiger Grants als Vereinigung, danach
Schnittmenge mit Tokenbereich/-Scopes und Objektbesitz. Keine implizite
Vererbung von Schlüsselzugang oder menschlichen Aktionen.

Gruppenänderung/-widerruf und Mitgliedschafts-/Einzelentzug erhöhen atomar die
`accounts.rights_version` aller Betroffenen und die Gruppenrevision; Commit
serialisiert mit Autorisierung. Jede Replika prüft aktuelle Revisionen vor
Aufruf, Download, Jobausgabe und Effektcommit; ein veralteter Cache allein ist
kein Erlaubnisbeleg. DB-Ausfall verweigert geschützte Aktionen. Entzug beendet
noch nicht begonnene Effekte, kann bereits begonnene externe I/O nicht rückrufen.
Bereits heruntergeladene Schlüssel/Klartexte sind nicht rückrufbar.

Legende: **J** im jeweiligen Bereich; **G** nur mit explizitem Aktionsrecht im
Bereich; **–** ausgeschlossen. **H** zusätzlich interaktive menschliche Sitzung,
frische Bestätigung und CSRF. **K** zusätzlich aktive Schlüsselberechtigung für
Kunde und benötigte Generationen sowie lokal entsperrter Schlüssel. J ist niemals
ein Schlüssel- oder Klartextrecht. Alle Rechte gelten zusätzlich zum Objektbereich.

| Fähigkeit / Recht | Admin | Betreuer | Kunde |
| --- | --- | --- | --- |
| Kunden, Konten, Rechtegruppen, Formularzuordnungen (`identity.manage`) | J H | – | – |
| Globale Konfiguration, SMTP/Proxy, Vertrauensnetze (`system.manage`) | J H | – | – |
| Domains manuell registrieren/zuordnen (`domain.manage`) | J H | – | – |
| Formular-/Ablaufkonfiguration ohne Secrets lesen (`form.read`) | J | J | J |
| Formular zunächst inaktiv anlegen (`form.create`) | J | – | – |
| Konfiguration/Felder/Ansichten/Abläufe als Entwurf ändern (`draft.write`) | J | J | G |
| Import/PHP-Konvertierung in Entwurf (`draft.write`) | J | J | G |
| Konfigurationspaket exportieren, ohne Inhalte/Secrets (`draft.export`) | J | J | G |
| Tests ohne Produktionseffekte (`test.run`) | J | J | G |
| Testziele verwalten (`test-target.manage`) | J H | G H | – |
| Veröffentlichen, aktivieren, Rollback, Produktionsmodus (`release.publish`) | J H | G H | – |
| Verlauf/Status/Metadaten lesen (`content.read`) | J | J | J |
| Chiffrate/Anhänge zur lokalen Entschlüsselung (`content.decrypt`) | G K H | G K H | G K H |
| Klartextdarstellung lokal (`content.decrypt`) | G K H | G K H | G K H |
| Manueller Resend (`content.resend` UND `content.decrypt`) | G K H | G K H | G K H |
| Inhalts-/Chiffratexport (`content.export` UND `content.read`) | G H | G H | G H |
| Klartextexport zusätzlich `content.decrypt` | G K H | G K H | G K H |
| Löschschutz/Nachschutz ändern (`content.hold`) | J H | G H | G H |
| Einzel-/Stapel-Inhaltslöschung (`content.delete`) | J H | G H | G H |
| Betroffenenrechte (`privacy.manage`) | J H | – | – |
| Statistik inkl. Bestands-Ads ohne Inhaltswerte (`statistics.read`) | J | J | J |
| Statistik löschen (`statistics.delete`) | J H | – | – |
| Debug starten/lesen/abbrechen, maskiert (`debug.read`) | J | G | – |
| Debugklartext zusätzlich `debug.plaintext` UND `content.decrypt` | G K H | G K H | – |
| Debugexport ausschließlich maskiert (`debug.export` UND `debug.read`) | J | G | – |
| Schlüsselzugänge/Generationen/Recovery verwalten (`key.manage`) | J H | – | – |
| Eigene Kontoeinstellungen/Sitzungen (`account.manage`) | J H | J H | J H |
| Eigene MCP-Tokens/Grants bei MCP-Erlaubnis (`token.manage`) | J H | J H | J H |
| Anmelde-/MCP-/Änderungsaudits, nur Metadaten (`audit.read`; Zeilen je Grant-Bereich, Systemgrant zusätzlich Zeilen ohne Kunde) | J | J | J |

`key.manage` verleiht keine Entschlüsselung: Erteilen eines Zugangs braucht die
kryptografischen Voraussetzungen des Krypto-Vertrags. Adminstatus ist weder
Schlüsselbesitz noch Recovery-Passphrase. Nach Entzug sind neue Abrufe verboten;
bereits heruntergeladene Klartexte/Schlüssel können nicht zurückgerufen werden.
Die letzte aktive Administration und der letzte erreichbare Datenzugang dürfen
nicht unbeabsichtigt entfernt werden (Altbestand B, Benutzerverwaltung).

## Ein Prüfpfad für REST, MCP und UI

**VORGESCHLAGEN:** Alle Adapter erzeugen denselben serverseitigen Kontext:
`subjectId`, `actorKind` (human/token/service), `sessionId` oder `tokenId`, effektive Grants/Gruppen,
aktuelle Berechtigungsrevision, Kunden-/Formularbereich, Token-Scopes/-Bereich,
Authentifizierungsstärke und Bestätigungszeit. Der Client darf diese Werte nicht
festlegen. MCP-Tokens bleiben `actorKind=token`, auch wenn sie einem Admin gehören.

Die gemeinsame Fachschicht prüft in dieser Reihenfolge:

1. Aktives Konto und gültige, nicht widerrufene Sitzung/Token; MCP zusätzlich
   aktuelle MCP-Erlaubnis und ggf. aktiver OAuth-Grant.
2. Ressourcen aus DB laden; tenantId aus Besitzkette Kunde > Formular > Eintrag,
   Entwurf, Debugauftrag oder Job ableiten. URL-/Body-IDs sind keine Berechtigung.
   Form, Ansicht und Flow eines Releases müssen zum selben Kunden gehören.
3. Aktuelle Einzelrechte, Gruppenrevisionen und deren Scope prüfen. Bei Tokens
   zusätzlich Schnittmenge aus Tokenbereich, Scopes und aktuellen Benutzerrechten.
   Nie Rechte aus Tokenanlagezeit konservieren; Widerruf wirkt auf jeder Replika.
4. H-/K-Bedingungen, Test-/Produktionsmodus, TTL, Hold, Generationen und erlaubte
   Außenwirkungen prüfen. Tests dürfen nicht durch freie Ziel-/Moduswerte senden.
5. Bei Mutation Zustand und Rechte vor Commit unter geeigneter Sperre/Version
   erneut prüfen; Audit und fachliche Änderung gemeinsam sichern. Downloads und
   asynchrone Jobausgaben beim Abruf erneut autorisieren.

Listen, Summen, Suchfilter, Autocomplete, Downloads, Export und Stapelaktionen
verwenden dieselbe Bereichseinschränkung vor Query/Paginierung. Fremde
Ressourcen liefern 404; erlaubtes Objekt mit fehlendem Aktionsrecht 403. Bei
atomaren Stapelaktionen führt ein fremdes Objekt zum vollständigen Abbruch;
Resend liefert erst nach vollständiger Bereichsprüfung einzelne Versandresultate.

UI-Rechteanzeigen sind nur Bedienhilfe. Keine Geschäftslogik oder Autorisierung
nur in Svelte, REST-Controller oder MCP-Werkzeug duplizieren. Keine privilegierte
Hintertür für interne Aufrufe. Dienste für Retention/Outbox haben einen separaten
engen Arbeitsauftrag, keine menschlichen Release-/Resend-/Klartextrechte.

## Klartext, Export und Veröffentlichung

Klartext entsteht für die Anzeige lokal nach erlaubtem Chiffrat-/Wrapabruf. Es gibt
keine allgemeine serverseitige Entschlüsselungs-API und keine Passphrase in einem
REST-/MCP-Request. Resend erhält bewusst vom Browser entschlüsselte Daten nur im
RAM über TLS, prüft Eintrag, Kunde, Version, Modus, Versandumfang und Empfänger.
Nicht in Queue/Logs/Audit persistieren; keine automatischen Mail-Retries.
Verbindliche Originalbindung, CEK-Prüfvorschlag, Freigabe nach Warten/Crash und
separater bearbeiteter Neuversand: [wiederanlauf.md](../flow/wiederanlauf.md).
`flow.execute`, `flow.approve`, `flow.resume` sind getrennte konfigurierbare
Einzelrechte; approve/resume zusätzlich H, bei Entschlüsselung zusätzlich
`content.decrypt` und K. Tokens erhalten dadurch keine menschliche Freigabe.

Inhaltsexport darf weder generische Chiffrat-Listen noch Anhangrouten als
Exportrecht-Umgehung anbieten: paginierte Einzelabrufe bleiben selbst zu auditieren
und zu begrenzen. Debugexport bleibt auch bei Schlüsselbesitz maskiert; Debug-TTL
15 Minuten ist beschlossen, gilt ebenso für daraus abgeleitete Downloads.
Statistiken enthalten keine IP; 13 Monate gelten nur für neu erhobene Daten.
Altbestand vollständig mit Herkunft legacy erhalten (ADR 0005 D7), auch mögliche
IP-Bezüge nach Bestandsprüfung am Dump, nur geschützt (statistics.read plus
content.decrypt), ohne Personenebenenauswertung. Löschprotokoll bleibt.

Produktionsänderungen gehen über einen unveränderlichen Releasekandidaten. Dazu
zählen Formulare, Felder, Skripte, Mailvorlagen/-empfänger, Live-Webhookziele,
Ansichten, Moduswechsel und Rollback. Neue Entwürfe/Tests verändern aktive Releases
nicht. Menschen bestätigen konkreten Hash und Version; eine freie Eigenschaft
`confirmed=true` oder `actorKind=human` ist kein Beleg. Details in `mcp.md`.

Technischer Nachtrag Hold (VORGESCHLAGEN): `HoldInput.objects` und
`../data/objektinventar.md` beschreiben vollständigen atomaren Nachschutz.
Lokales Erzeugen eines sym-Wraps benötigt entsperrten Schlüssel. `content.hold` und bei notwendigem lokalem Rewrap `content.decrypt` sowie K
sind unabhängig konfigurierbar; keine Rollenfreigabe. Originalbindung siehe Wiederanlaufvertrag.

## Vertragsrunde 3 — R04 Nachtrag (VORGESCHLAGEN)

`test-target.manage` ist Teil des geschlossenen Katalogs (OpenAPI `Permission`,
SQL-Seed `permission_catalog`) und schützt `createTestTarget`/`updateTestTarget`
(`admin-api.openapi.yaml`, Pfade `/tenants/{tenantId}/test-targets`); `listTestTargets`
verlangt `test.run`. Das Recht verleiht keine Testausführung und keine
Klartextrechte; `system.manage` ersetzt es nicht. Kryptoaktionen (Einrichtung,
Rotation, Zugang, Schutz der letzten handlungsfähigen Identität) sind in
`../crypto/schluessel.md` (Abschnitt R04) auf `key.manage` im Kundenscope
übersetzt; kein Pfad prüft `template_name`.
