# Referenzen und Grenzen der Sichtung

Erste lesende Sichtung am 25.10.2026, keine Tests, Builds, Datenbankabfragen oder produktiven Prüfungen.

## Bisheriges Formularbackend

Quellen: README.md, CLAUDE.md, docs/roadmap/07-arbeitsstand.md und 09-sdk-backend-protokoll.md, Browserentschlüsselungsdesign vom 17.09.2026, db/schema.sql sowie Migrationsdateiliste, zentrale Provider für Feldschema, Handler, Ingest, Verschlüsselung, HPKE/Paketformat, Schlüsselverwaltung und Docker-Kompatibilitätsstack.

Befund: v1/v2 bereits auf gemeinsamem fachlichem Kern; deklarative Feldschemata und zentrale Handlerregistry vorhanden. Verschlüsselungsstand neuer als README: HPKE/:2 und Browserentschlüsselung implementiert, älterer RSA-/CBC-/AEAD:1-Bestand und Umstieg weiter relevant. Produktionszustand nicht geprüft. Datierten frühen Reviews und Bestandszahlen nicht ungeprüft vertrauen; sie können aktuellen Code nicht mehr abbilden.

## Timetrack Backend/PWA

Vom Nutzer als Architektur-/UI-Orientierung benannt. Gelesen: Agent-Einstiege, README, ausgewählte Status-/Architektur-/Arbeitsplandokumente, Package.swift, StorageBackend und Backendtypen; PWA-Paketdefinition, Modul-/Routenkarte und Onboardingplan.

Nutzbare Muster: modularer Swift/Vapor-Kern, MariaDB, statische Svelte-PWA, REST/MCP über gemeinsamen Diensten, Module server-/clientseitig, DB-Leases, einheitliche Speicheradapter und geführte Einrichtung. Im gelesenen Code Speicherarten db/s3/local; SFTP ist für dieses neue Projekt zusätzlich zu entwerfen. Referenzstatus benennt selbst noch nicht real geprüften Swarm-Betrieb; keine Produktionsreife übernehmen oder behaupten.

## thermoctl

Gelesen: README, Frontendpaket, MCP-Beschreibung und ausgewählte UI-Redesignunterlagen. Nutzbare Muster: unterschiedliche Sichten bei gemeinsamen Diensten/Rechten, nachvollziehbarer Test-/Betriebszustand, Konfiguration und MCP. Ältere Redesignunterlagen nennen einen überholten UI-Stack gegenüber aktuellem README; als UX-Ideen, nicht als verbindliche technische Architektur verwenden.

## Externe Erstorientierung

In der Brainstormingphase wurden offizielle Dokumentationen zu shadcn-svelte (`https://www.shadcn-svelte.com/docs`) und Vapor (`https://docs.vapor.codes/fluent/overview/`, `https://docs.vapor.codes/advanced/sessions/`) konsultiert. Vor konkreter Implementierung gewählte Versionen, API-Details und Sicherheitsvoraussetzungen erneut prüfen.

Keine Implementierung aus Referenzprojekten kopiert. Diese Quellen wurden nicht verändert.
