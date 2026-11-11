# Architektur — Vorschlag

## Grundstruktur

Modularer Monolith in Swift; Vapor und Fluent/MySQL sind naheliegende Kandidaten aufgrund Timetrack, aber vor Implementierung als ADR festzulegen. Svelte mit shadcn-svelte, statisch gebaut; Node nur zum Entwickeln/Bauen vorgesehen. Gemeinsames Repository mit Backend, PWA, SDK und Verträgen.

API und Hintergrundworker können getrennte Prozesse desselben Images sein. Kein Microservice-Zwang und kein frei hochladbarer Fremdcode im Backend als Ausgangspunkt. Fachmodule besitzen ihre Datenzugriffe und bieten definierte Dienste; HTTP, MCP und UI-Aktionen nutzen dieselben Berechtigungen und Anwendungsdienste.

## Grenzen

| Modul                | Verantwortung                                                   |
| -------------------- | --------------------------------------------------------------- |
| Kunden und Rechte    | Mandanten, Konten, Rollen, Zuständigkeiten                      |
| Formulardefinitionen | Feldmodell, Ansichten, Versionen, Veröffentlichung              |
| Darstellung          | gehostete Formulare, PHP-/Vanilla-Integration, Themes           |
| Domainzuordnung      | bekannte Hostnamen auf Formular/Ansicht/Umgebung abbilden       |
| Ablaufengine         | Definitionen, Bausteine, Durchläufe, Zustände, Debug            |
| Eingang              | Protokolladapter, Prüfung, Annahme und Idempotenz               |
| Zustellung           | Mailaufbau, SMTP/Proxy, Webhooks und Wiederholungen             |
| Speicher             | MariaDB als Standard, S3/SFTP optional                          |
| Kryptografie         | Profile, Schlüsselhüllen, Rotation, Datenzugang und Recovery    |
| Statistik und Audit  | fachliche Ereignisse, Aggregate, Betriebskennzahlen, Protokolle |
| Integrationen        | Legacy/v2/neue API, MCP und Kundenagenten                       |

Genaue Paket-/Target-Grenzen erst nach Funktionsinventar und Vertragsentwurf. Keine Tabelle ohne dokumentierten fachlichen Besitzer.

## Mehrere Replikas

Keine dauerhaften lokalen Sitzungen, Dateien, Rate-Limits oder Jobzustände auf einer API-Replika voraussetzen. MariaDB speichert Fachdaten und zunächst vorgeschlagen auch Sitzungen, Outbox, Job-Leases und Debugaufträge; Redis ist keine bestätigte Pflicht.

Worker benötigen atomare Auftragsübernahme, begrenzte Leases, Wiederanlauf, Retry/Backoff und sichtbare dauerhaft gescheiterte Jobs. Externe Effekte sind idempotent zu gestalten, soweit der Empfänger dies unterstützt. Genau-einmal-Zustellung von SMTP nicht behaupten: Ein Absturz nach Annahme vor Statusspeicherung kann ein unklares Ergebnis erzeugen.

Schemaänderungen als einmalig koordinierter Deployment-Schritt. Geteilte Caches müssen bei Modul-, Schlüssel- und Konfigurationsänderungen verlässlich aktualisiert werden. Health-/Readiness-Endpunkte unterscheiden Prozesszustand von Bereitschaft. API-Replikas allein machen MariaDB nicht hochverfügbar.

## Domains

Reverse Proxy/TLS sind extern. Das Backend verwaltet nur verifizierbare Zuordnung und Status der Hostnamen. Unbekannte Hosts ablehnen; weitergeleitete Host-/Clientinformationen nur von explizit vertrauenswürdigen Proxys übernehmen. Domainbesitzprüfung und genaue Proxy-Header-Vereinbarung sind offen. Stabile eigene Admin-Domain vorgeschlagen, Kundenhosts ausschließlich für Formulare.

## Module

Unterscheiden: installiert, serverweit verfügbar, kundenseitig freigegeben, formularbezogen aktiv. Beim Deaktivieren festlegen, ob wartende Durchläufe auslaufen, pausieren oder abbrechen; nie still verlieren. Ein Modulmanifest beschreibt Kennung, Version, Konfigurationsschema, Rechte, Abhängigkeiten, Bausteine und Gesundheitsstatus. Aktivierung wird serverseitig durchgesetzt, nicht nur in der Navigation.
