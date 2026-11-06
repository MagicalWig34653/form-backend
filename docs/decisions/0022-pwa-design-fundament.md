# ADR 0022: PWA-Designfundament (P12-A Schritt 1)

Status: Nutzerauftrag vom 03.11.2026 umgesetzt, Browserabnahme offen.

## Entscheidung und Begründung

Die bestehende Svelte-5-/Tailwind-4-PWA erhält das vom Nutzer gewählte
Zinc-Design aus `timetrack-pwa`: OKLCH-Tokens, lokale variable Inter-Schrift,
helle/dunkle/Systemdarstellung und vier speicherbare Akzentfarben. Dies bleibt
Präsentation; API-, Rechte-, Sitzungs- und Routingverträge bleiben bestehen.
Die vorhandenen bits-ui-Dialoge übernehmen Fokusbindung, Escape und Rückgabe
des Fokus auch für die mobile Drawer-Navigation. Native Formelemente bleiben
für Eingaben und Auswahl erhalten. Die UI-Basis liegt unter
`pwa/src/lib/components/ui`, die Shell unter `components/shell`.

Einsendungen und Statistik sind weiterhin formularbezogen. Sidebar-Verweise
führen im aktuellen Formular zur Einsendungsliste bzw. zum Statistikabschnitt
des Überblicks; ohne Formular zur bestehenden Formularauswahl. Es werden keine
kundenübergreifenden Aggregationen oder neuen Routen eingeführt. Alle bisherigen
Verwaltungsseiten werden innerhalb der neuen Shell gerendert.

## Lizenz und Grenze

Die Referenz wurde ausschließlich gelesen. Adaptierte Zinc-Tokens sind im CSS
gekennzeichnet; der vollständige MIT-Hinweis liegt in `pwa/SHADCN-LICENSE.md`.
Inter liegt lokal mit OFL-Lizenz unter `pwa/public/fonts`. Die Anwendung bleibt
AGPL-3.0-only. Shell und geometrische SVG-Symbole sind projektspezifisch; keine
zusätzliche npm-Abhängigkeit. Schlüsselbezogene Dateien/Panels gehören P12-B
und sind ausgeschlossen. Schritt 2 gestaltet die übrigen Seiten.

Prüfstand, Dateibesitz und offene Abnahme: `docs/handoffs/P12-A.md`.
