# Formulare, Abläufe und Integration

## Definitionen und Versionen — Vorschlag

Ein Formular enthält stabile technische Feldkennungen, Feldtypen, Validierungsregeln und Bezug zum Kunden. Eine Ansicht beschreibt Anordnung, Abschnitte, Schritte, Sichtbarkeit, Beschriftung und Theme. Ein Ablauf beschreibt Verarbeitung. Die Veröffentlichung bindet konkrete Versionen dieser Definitionen; Einsendungen speichern diesen Bezug.

Entwurf, Vorschau, Prüfung, Veröffentlichung und Rollback vorsehen. Gemeinsam genutzte Teilabläufe werden versioniert referenziert. Eine Änderung an einem Teilablauf aktualisiert keine produktiven Formulare ungefragt. Laufende Durchläufe arbeiten mit ihrer fixierten Version weiter.

Zwei verbundene Editoren vorgeschlagen: Formular-/Ansichtseditor und Ablaufdiagramm. Zunächst kontrollierte Komponenten und Designparameter; beliebiger HTML-/JS-Code und freie Skriptknoten sind offene Erweiterungen.

## Kundenintegration

PHP-SDK bleibt eigenständig nutzbar. Es kann veröffentlichte Definitionen abrufen, HTML rendern oder vorhandene Feldnamen auf stabile Kennungen abbilden, Eingaben prüfen, signieren und optional symmetrisch verschlüsseln. Ein optionaler Vanilla-JS-Helfer übernimmt dynamische Felder/Bedingungen und Browserverschlüsselung; kein Svelte auf der Kundenseite erforderlich.

Bestehende HTML-Seiten benötigen einen definierten Einfügebereich oder Feldzuordnungen. Ohne JS greifen dynamische Konfigurationsänderungen beim nächsten PHP-Rendern, nicht während der Eingabe. Ausgeblendet, schreibgeschützt, deaktiviert und serverseitig festgelegt sind getrennte Regeln. Browserattribute sind kein Integritätsschutz.

Optionaler Docker-Kundenagent: lokale Integrationen, aufwendigere Verarbeitung, Zustellung und Ausführung ausgewählter Bausteine. Kein Ersatz oder Pflichtdienst für das PHP-SDK. Gleiche Protokollverträge und Fähigkeiten aushandeln.

## Ablaufbausteine

Vorgeschlagene Vertragsbestandteile: Kennung/Version, Ein-/Ausgabeschema, Konfiguration, Berechtigungen, benötigte Verbindungen, Klartextbedarf, erlaubter Ausführungsort, Zeitlimit, Retry-/Idempotenzverhalten, Ereignisse sowie Debugdarstellung und Redaktionsregeln.

Mögliche Orte: Browser, PHP-Kundenserver, Docker-Kundenagent, Backend-API, Backendworker, entsperrter Adminbrowser. Das gewählte Sicherheitsprofil begrenzt die zulässige Platzierung. Nicht jeder Baustein muss überall implementiert werden. Ein Graph darf erst veröffentlicht werden, wenn benötigte Fähigkeiten vorhanden sind.

Vorgeschlagene Startbausteine: Eingang, Feldprüfung, Feldzuordnung, Bedingung, Mailvorlage, Verschlüsselung, Speicherung, SMTP/Proxy, Webhook, Benachrichtigung. Für den ersten Stand azyklische Graphen bevorzugen; Schleifen, lange Wartezeiten und manuelle Freigaben sind vor Umsetzung ausdrücklich zu entscheiden.

Beispiel: Eingang → optionale Transportentschlüsselung → Prüfung → Verzweigung → Mailaufbau → verschlüsselte Speicherung → Zustellung → Ergebnisereignis. Exakte Reihenfolge und Fehlersemantik werden im Profil/Ablauf festgelegt; keine einzig zulässige globale Pipeline.

## Import/Export und KI/MCP

Versioniertes Paket mit Formular, Ansichten, Abläufen, Modulanforderungen, Vorlagen und Referenzen auf Verbindungen. Keine Credentials oder privaten Schlüssel standardmäßig exportieren. Import prüft Paketversion und Abhängigkeiten, zeigt Konflikte/Vorschau und verlangt Zuordnung vorhandener oder neuer Verbindungen. Wiederholter Import darf keine unbeabsichtigten Duplikate erzeugen.

MCP verwendet dieselben Dienste/Rechte wie REST. Vorgeschlagene Fähigkeiten: Bausteinschemas lesen, Definitionen lesen, Entwürfe erzeugen/ändern, Pakete importieren, validieren, synthetische Tests starten und Versionsunterschiede anzeigen. Veröffentlichung und echte Außenwirkungen brauchen eigene Rechte und erkennbare Aktionen.

KI liest bestehende PHP-Skripte als Quellmaterial und übersetzt erkannte Felder, Bedingungen, Empfänger, Vorlagen und API-Aufrufe in Entwürfe. Keine garantierte verlustfreie automatische Konvertierung beliebigen PHP-Codes. Nicht verstandene Stellen als offene Zuordnung melden. Abnahme durch synthetische Vergleichsfälle gegen das alte Verhalten. Isolierter PHP-Kompatibilitätsbaustein im Kundenagenten ist eine mögliche Übergangslösung, noch kein Beschluss.

## Einrichtungsassistent

Kunde → Vorlage → Felder/Ansicht → Ablauf → Verschlüsselungsprofil/Speicher → Einbindung oder Domainzuordnung → Pairing → Testeinsendung → Veröffentlichung. Entwurf und Fortschritt serverseitig speichern. Nur relevante Schritte anbieten. Verbindungs-/Schlüsselstatus und Fehler verständlich zeigen. Reverse Proxy und Zertifikate werden nicht eingerichtet.
