# ADR 0045: Eigentümer je API-Host

14.11.2026. Status: umgesetzt (Agent), Review durch Lino steht aus. Todolino A4EDE0BE-0503-4BF2-9E35-5D2E8EDE73CE. SPDX-License-Identifier: AGPL-3.0-only.
Ergänzt ADR 0015 (API-Hosts). Anlass: Opus-Sicherheitsprüfung, Abschnitt 3 (Mandant B erkannte, hängte sich an und blockierte Hosts von Mandant A).

## Entscheidung

- `api_hosts.owner_customer_id` (nullable, Upgrade `0036-api-host-owner.sql`). Beim Anlegen ist es der Kunde der Anfrage (`tenantId`).
- `POST /api-hosts`: Ist der Host bekannt und gehört nicht dem Kunden der Anfrage (oder hat keinen Eigentümer), antwortet der Server mit **404**, unabhängig von `expectedRevision`. Ausnahme: Konto mit `system.manage` (System-Scope) darf Formulare des angegebenen Kunden anhängen und schalten.
  Ein unbekannter Host mit `expectedRevision != 0` antwortet ebenfalls 404 (statt 412), damit 412/200 keine Existenz verraten.
- `POST/PATCH /domains`: Kollidiert der Hostname mit einem Host oder einer Domain eines **anderen** Kunden, 404; mit dem eigenen Kunden weiterhin 409.
- Folge: Ein Kunde kann den Aktivierungszustand seines Hosts nicht mehr durch fremde Anhänge blockieren (kein 403 mehr beim Schalten). Der Schutz „fremde Zuordnungen verhindern Schalten“ greift nur noch für den `system.manage`-Pfad.
- Bestehende Hosts: Upgrade weist den Kunden des ältesten Audit-Ereignisses `domain.api.configure` des Hosts zu (Ersteller), sonst den der ältesten Formularbindung (`changed_at`, `binding_revision`, `customer_id`). Mehrdeutig sind Hosts, an denen mehrere Kunden gebunden sind: der älteste gewinnt, die anderen verlieren das Schreibrecht, ihre Bindungen bleiben bestehen (Ingest unverändert). Hosts ohne Audit und ohne Bindung bleiben ohne Eigentümer (nur `system.manage`).
- Vertrag: Statuscodes oben; Request-/Response-Formate unverändert. Die PWA benutzt `/api-hosts` nicht (keine Anzeigeänderung nötig).

## Grenzen (ehrlich)

- Kein DNS-Nachweis für Hostnamen (im Projekt nicht vorhanden): Wer `domain.manage` für einen Kunden hat, kann einen **freien** Namen belegen (Squatting bleibt möglich), und ein Anlegeversuch mit Erfolg (200) gegenüber 404 verrät, dass der Name frei war. Die Eigentümerbindung verhindert Übernahme, Blockade und Erkennung eines **belegten** Namens über Änderungen, nicht Vorabbelegung. Ein DNS-TXT-Nachweis wäre ein eigenes Paket.
- Eigentümerwechsel/Übertragung gibt es nicht (nur per Datenbank oder neuer Funktion).
