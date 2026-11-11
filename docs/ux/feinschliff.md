# UI-Feinschliff-Konzept: Dashboard und Verwaltung

Stand: 06.11.2026 · Todolino-Task 8B72B9D6 · Nur Konzept, kein Anwendungscode · AGPL-3.0-only.
Ergänzt `docs/ux/konzept.md` (Informationsarchitektur bleibt gültig); dieses Dokument regelt Optik, Muster und Umsetzungsreihenfolge. Nutzerwunsch: besonders wichtig, darf einen Wow-Effekt haben, **Bedienung und Lesbarkeit gehen vor Effekt**.

Referenzen (nur gelesen): thermoctl (`docs/bilder/anlage-startseite.png`, `anlage-betrieb.png`, `anlage-geraete.png`, `kiosk-dashboard.png`, `wohnung-startseite-mobil.png`) und timetrack-pwa (`src/routes/layout.css`, `src/lib/components/{app,shell,stats}`: `KpiCard`, `PageHeader`, `Panel`, `StatusChip`, `Banner`, `EmptyState`, `FilterBar`, `Segmented`, `GlowSwitch`, `SettingsShell`).
Ist-Screenshots: `docs/ux/bilder-ist/*-desktop.jpg` (1280) und `*-mobil.jpg` (390), erzeugt über temporäre Playwright-Skripte mit den Mock-Helfern aus `pwa/e2e/admin.spec.ts` (nicht im Repo). Hinweis: Der Mock liefert für `/settings`, `/ops`, `/migration` keine Daten (404 bzw. leere Antwort); „Einstellungen: Nicht gefunden“ ist daher ein Mock-Artefakt, die Fehlerdarstellung selbst bleibt aber relevant (Befund 5).

## (a) Befund je Seite

Querschnitt (alle Seiten):

- Es gibt **keine Seitenkopf-Komponente**: Titel, Untertitel und Aktionen sind je Seite anders (Kunden: Titel + Zeile + Button; Umstieg: gar kein Titel; Konto: h1 + h2 ohne Karten). Kein Breadcrumb, kein Untertitel-Stil wie in thermoctl/timetrack.
- **Seitenleiste** (`SidebarNav.svelte`): flache Liste mit neun Einträgen unter „Arbeitsbereich“; „Einrichtung“ und „Umstieg“ stehen oben vor „Kunden“ und teilen sich dasselbe Settings-Symbol mit „Einstellungen“; „Verbindungen“ und „Mitglieder“ haben anderes Format (kein Icon, 12 px Padding statt `min-h-11`). Keine Gruppen, keine Suche, Statistik zeigt bei Nicht-Formular-Kontext auf die Formularliste (`active: false` immer).
- **TopBar**: natives `<select>` für Kunde, Darstellungs-Icons (Mond/Kontrast) ohne Text, „Hilfe und Dokumentation“ als nackter Text, Version als Pille, Abmelden als nackter Text. Wenig Hierarchie, kein Breadcrumb, auf Mobil bricht die Leiste in zwei Zeilen um (Hilfe/Version wandern in eine eigene Zeile, siehe `formular-ueberblick-mobil.jpg`).
- Globaler Warntext („Der Zugriff auf Einsendungen ist gesperrt …“) steht als nackter Absatz über jeder Seite, ohne Banner-Rahmen, Icon oder Schließen/Aktion; er verschiebt den Inhalt ca. 60 px nach unten und ist visuell mit dem Untertitel verwechselbar.
- Sidebar endet im Vollseiten-Screenshot bei 800 px (nicht über die volle Höhe der langen Seite): prüfen, dass sie `sticky; top:0; height:100dvh` ist (Screenshot-Artefakt nicht ausgeschlossen, im Konzept 1 mit absichern).
- Karten: `rounded-xl border` mit **harten dunklen Rahmen** (z. B. Passkey-Liste, Kennzahlen, Einsendungskarten wirken schwarz umrandet) statt feinem `--border`; Karten in Karten (Einsendungen: „Lokale Suche“, „Filter“, Zeile, „Aufbewahrung“ alle als eigene große Rahmen mit viel Leerraum unten).
- Typografie: h1 ≈ 24 px fett, h2/h3 kaum abgesetzt (alles ≈ 16–18 px), Beschreibungen im selben Grau/Gewicht wie Inhalte; keine definierte Skala.
- Leere/Fehlerzustände: „Nicht gefunden.“ als nackter Text mit zentriertem Textlink; kein Icon, kein erklärender Hinweis, keine Primäraktion. „Nicht verfügbar“ in Tabellenzellen (Kunden) liest sich wie ein Defekt.
- Ladezustände: nur Text („Wird geladen …“), keine Skeletons, Layoutsprünge.
- Dunkelmodus funktioniert (axe-geprüft), ist aber ein reines Invertieren der Zinc-Tokens ohne Tiefenstaffelung (Karte = Hintergrund, Rahmen 10 %).

Je Seite:

1. **Anmeldung** (`anmeldung-*.jpg`): Ruhig, Akzent-Verlauf vorhanden (gut). Schwächen: „SICHERER ZUGANG“-Überschrift und Slogan stehen außerhalb der Karte ohne Logo; in der Karte „Mit Passkey bestätigen“ als loser fetter Text über dem Button (Rolle unklar); „Hilfe“ als nackter Text; Kopfleiste zeigt Dokumentation/Mond/Kontrast ohne Beschriftung.
2. **Kunden** (`kunden-*.jpg`): Funktional, aber Filter (Name/Status) sind große Voll-Breite-Felder mit Label oben statt kompakter FilterBar; Tabelle mit „Nicht verfügbar“ in zwei von vier Spalten; „Öffnen“ als Textlink statt Button; leerer Tabellenfuß mit Restfläche; Fußnote erklärt ein API-Defizit statt es zu verbergen.
3. **Formulare** (`formulare-*.jpg`): kein Kopf mit Kennzahlen; Listenzeilen ohne Status-Badge/Aktivitätsindikator; Aktionen „Einrichtung fortsetzen“ etc. nicht priorisiert.
4. **Formularseite/Überblick** (`formular-ueberblick-*.jpg`): Beste Seite, aber: Kopf mit drei Textzeilen (Titel / Aktiv · Version / Entwurf) statt Statusbadges; Tab-Leiste wirkt unfertig (Unterstrich dünn, auf Mobil zweizeilig umbrechend); „Überblick“-Karte enthält untergeordnet Schalter, Aktionen, Mail/Einbindung, Statistik, Google Ads in einer endlosen Spalte (keine Gruppen); fünf Kennzahlen als Rahmenkästen mit schwarzem Rand, Zahl ohne Trend/Sparkline; Linien-Diagramm zeigt bei zwei Datenpunkten zwei unlesbare Diagonalen, Legende/Strichmuster statt Direktbeschriftung, Datentabelle mit Balkenzellen die überlappen (Spaltenüberlauf auf Mobil: „Ab…“ abgeschnitten); „Google Ads – Nicht gefunden. Erneut versuchen“ wirkt wie ein Fehler, obwohl es ein optionaler Block ist; Mobil: Hilfe/Version-Zeile über dem Inhalt, Kennzahlen 2-spaltig mit verwaister fünfter Karte.
5. **Felder & Ansicht / Veröffentlichen / Mail** (`felder-*.jpg`, `veroeffentlichen-*.jpg`): Funktional, Zwei-Spalten-Editor ohne klare Karten-Hierarchie; Prüfliste ohne Statusikonen (Ok/Warnung/Fehler nur Text); Primäraktion sticht nicht hervor außer im Kopf.
6. **Einsendungen** (`einsendungen-*.jpg`): Die Seite verlangt viel Scrollen: erst große Karte „Lokale Suche und Auskunft“ (viel Leerraum unten), dann eingeklapptes „Filter“, dann Liste, dann „Aufbewahrung“. Einsendungszeile ist eine große Karte (≈ 170 px) mit Checkbox, Zeit, Status, Schutz-Chip, drei Buttons und Hinweis; bei vielen Einträgen unbrauchbar lang. Datumsfelder nativ (`mm/dd/yyyy`, US-Format in deutscher UI). Deaktivierter „Öffnen“-Button ohne direkt am Button stehende Begründung. Mobil: lang, aber bedienbar.
7. **Einstellungen** (`einstellungen-*.jpg`): ungestylt (Überschrift + zwei Absätze), Rangfolge-Hinweis als Fließtext, Fehler als nackter Text, „Neu laden“ ohne Button-Optik. Echte Zustände (Liste mit Quelle ENV/DB/Default) benötigen Tabellen-/Badge-Muster.
8. **Umstieg** (`umstieg-*.jpg`): am stärksten unfertig: kein h1, keine Karten, Überschriften sind normaler Text, Eingabefelder erscheinen ohne sichtbare Rahmen (Labels und Felder laufen in einer Zeile ineinander), Phasenfolge („Quelle geprüft → …“) als Text statt Stepper, Warnung („Die Verbindung wurde unterbrochen …“) ohne Alert-Optik, Rollback-Hinweise als Textwand. Mobil identisch lang.
9. **Mein Konto** (`konto-*.jpg`): Abschnitte (Sicherheit, Authenticator, Passkeys, Neues Konto) nur durch Überschriften getrennt; Passkey-Zeilen mit hartem Rahmen, Aktionen rechts klein, „App einrichten“/„Passwort … setzen“ als volle Breite-Ghost-Buttons; kein Statusbadge („entsperrt Datenschlüssel“ als Fließtext).
10. **Betrieb / Tokens / Verbindungen / Mitglieder** (`betrieb-*`, `tokens-*`, `verbindungen-*`, `mitglieder-*`): gleiche Muster wie oben, eigene Abstände; Betrieb ohne Statuspunkte; Mitglieder-Rechte als lange Checkbox-Liste ohne Gruppen.

Positiv (beibehalten): Inter, Zinc-OKLCH-Tokens, Akzentsystem (`--ui-accent*`), reduced-motion-Reset in `app.css`, Fokusring, axe-grüne Seiten, Passkey-Anmeldeverlauf, Datentabellenalternative zum Diagramm.

## (b) Designziele und Tokens

### Ziele

1. **Ruhig und lesbar**: Weißraum, eine Akzentfarbe, große Kennzahlen, wenig Rahmen. Farbe nie als einziger Bedeutungsträger (immer Text oder Icon dazu).
2. **Eine Seitenstruktur**: `PageHeader` (Breadcrumb, h1, Untertitel, Aktionen) → optionales Banner → Inhalt in `Panel`-Karten. Maximal 1240 px Inhalt, Formulare 820 px.
3. **Status auf einen Blick**: Punkt-Badges (aktiv, Entwurf, Fehler, wartet) und Kennzahlen mit Trend.
4. **Wow nur dort, wo es hilft**: Dashboard (Kacheln, Sparklines, Zählanimation), Kopfbereich (Verlauf), Befehlspalette. Alle Effekte abschaltbar über `prefers-reduced-motion` und eine Einstellung „Effekte: Aus/Dezent“.
5. **Kein Layoutsprung**: Skeleton in Zielgeometrie, feste Mindesthöhen.

### Tokens (Ergänzungen zu `pwa/src/app.css`)

Bestehende shadcn-Tokens bleiben unverändert (Kompatibilität mit `ui/*`). Neu hinzu kommen semantische Status-, Flächen- und Skalen-Tokens. Vorschlag zum Einfügen in `:root` bzw. `.dark` (Werte so gewählt, dass Text auf der jeweiligen Soft-Fläche mindestens 4,5:1 erreicht; im Schritt 1 per Kontrastskript gegen die tatsächlichen Hintergründe prüfen):

```css
:root {
  /* Flächenstaffelung: Seite < Karte < erhöht */
  --surface-page: oklch(0.985 0.002 286);
  --surface-card: oklch(1 0 0);
  --surface-raised: oklch(1 0 0);
  --surface-sunken: oklch(0.967 0.001 286.375);
  --border-subtle: oklch(0.94 0.004 286.32);

  /* Status (Text/Punkt auf Soft-Fläche) */
  --ok: oklch(0.52 0.13 155);
  --ok-soft: oklch(0.96 0.04 155);
  --warn: oklch(0.55 0.14 70);
  --warn-soft: oklch(0.97 0.05 85);
  --danger: oklch(0.52 0.2 27);
  --danger-soft: oklch(0.97 0.03 25);
  --info: oklch(0.5 0.16 255);
  --info-soft: oklch(0.96 0.03 255);
  --idle: oklch(0.55 0.01 286);
  --idle-soft: oklch(0.967 0.001 286);

  /* Radien (Basis bleibt 0.625rem) */
  --r-chip: 999px;
  --r-ctl: 0.5rem;
  --r-card: 0.875rem;
  --r-pop: 1rem;

  /* Schatten */
  --shadow-card: 0 1px 2px #0000000a, 0 1px 1px #00000005;
  --shadow-hover: 0 4px 16px #0000000f;
  --shadow-pop: 0 12px 40px #0002;

  /* Verlaufs-/Glas-Akzent im Seitenkopf (nur Dekor, hinter Text) */
  --hero-wash: radial-gradient(
    60rem 14rem at 15% -40%,
    color-mix(in srgb, var(--ui-accent) 14%, transparent),
    transparent 70%
  );
  --glass-edge: color-mix(in srgb, #fff 55%, transparent);

  /* Typografie-Skala (Inter Variable) */
  --fs-display: 2rem; /* Kennzahl groß, 32/36, 650, tabular-nums */
  --fs-h1: 1.75rem; /* Seitentitel, 28/34, 650, tracking -0.02em */
  --fs-h2: 1.125rem; /* Kartentitel, 18/26, 600 */
  --fs-body: 0.9375rem; /* 15/22 */
  --fs-small: 0.8125rem; /* 13/18, muted */
  --fs-micro: 0.6875rem; /* 11/14, Versalien, +0.06em, Bereichsüberschriften */

  /* Abstände (4-px-Raster) */
  --sp-1: 0.25rem;
  --sp-2: 0.5rem;
  --sp-3: 0.75rem;
  --sp-4: 1rem;
  --sp-6: 1.5rem;
  --sp-8: 2rem;
  --sp-12: 3rem;
  --gutter: 1rem; /* mobil */
  --sidebar-w: 16rem;
  --topbar-h: 3.75rem;

  /* Bewegung */
  --ease-out: cubic-bezier(0.2, 0.8, 0.2, 1);
  --dur-fast: 120ms;
  --dur-base: 200ms;
  --dur-slow: 600ms;
}
.dark {
  --surface-page: oklch(0.12 0.005 285.8);
  --surface-card: oklch(
    0.17 0.006 285.8
  ); /* Karte hebt sich ab: heute = Hintergrund */
  --surface-raised: oklch(0.2 0.006 285.8);
  --surface-sunken: oklch(0.14 0.005 285.8);
  --border-subtle: oklch(1 0 0 / 8%);
  --ok: oklch(0.78 0.15 155);
  --ok-soft: oklch(0.28 0.06 155);
  --warn: oklch(0.82 0.14 85);
  --warn-soft: oklch(0.3 0.06 80);
  --danger: oklch(0.74 0.17 22);
  --danger-soft: oklch(0.3 0.07 25);
  --info: oklch(0.76 0.12 255);
  --info-soft: oklch(0.28 0.06 255);
  --idle: oklch(0.7 0.01 286);
  --idle-soft: oklch(0.25 0.006 286);
  --shadow-card: 0 0 0 1px oklch(1 0 0 / 6%);
  --shadow-hover: 0 6px 20px #0006;
  --glass-edge: color-mix(in srgb, #fff 12%, transparent);
  --hero-wash: radial-gradient(
    60rem 14rem at 15% -40%,
    color-mix(in srgb, var(--ui-accent) 22%, transparent),
    transparent 70%
  );
}
```

Dunkelmodus-Feinschliff: dreistufige Flächenstaffelung (page < card < raised) statt gleicher Farbe; Rahmen 8 %/Statusflächen gedämpft; Akzentfläche (`--ui-accent-soft`) in Dunkel 16 % statt 9 %; Diagrammfarben über `--chart-*` mit gleichem Kontrast (Linien ≥ 3:1 gegen Karte). Logo-/Seitenkopf-Verlauf in Dunkel stärker, in Hell dezent.

Regeln: Karten haben `border: 1px solid var(--border-subtle)` + `--shadow-card`, nie dunkle Vollrahmen (Ausnahme: Fokus/Auswahl). Rot nur für Fehler/destruktiv; Akzent nur für aktive Navigation, Primäraktion, Links, aktive Tabs und Diagrammserie 1. Mindest-Trefferfläche 40 px (Eingaben/Buttons), Navigation 36 px Desktop / 44 px Mobil.

## (c) Wow-Elemente, die funktional bleiben

Jedes Element hat einen Nutzen und eine Rückfalloption.

1. **Kennzahlenkacheln mit Sparklines (Übersicht)**: große Zahl (`--fs-display`, `tabular-nums`), Label mit Hilfe-Tooltip, Delta zur Vorperiode (Pfeil + Text „+3 ggü. Vorwoche“, nie nur Farbe), darunter 14-Tage-Sparkline als reines inline-SVG (`<svg role="img" aria-label="Einsendungen der letzten 14 Tage: …">`, Pfad + dezente Fläche, Endpunkt markiert). Ohne Daten: „–“ + Hinweis, nie eine erfundene Null. Mit Datentabelle als Alternative hinter „Werte anzeigen“ (wie heute).
2. **Zählanimation**: Zahlen laufen beim ersten Erscheinen 600 ms von 0 zum Wert (`requestAnimationFrame`, `--ease-out`); bei `prefers-reduced-motion` oder Einstellung „Effekte: Aus“ direkt Endwert; Screenreader erhalten nur den Endwert (`aria-live` aus, Animation `aria-hidden`).
3. **Einblenden**: Karten staffeln 40 ms (max. 8 Stufen), nur `opacity` und `translateY(6px)`; kein Einblenden bei Navigation zwischen bereits sichtbaren Teilen, nur beim ersten Laden einer Seite.
4. **Statuspunkte mit Puls**: Punkt (8 px) + Text, Farben aus Status-Tokens; Puls (Ring-Skalierung, 2 s) nur bei „live/wartet“ (z. B. „Zustellung läuft“), nicht bei Fehlern; unter reduced-motion statisch.
5. **Befehlspalette Cmd/Ctrl+K**: Dialog (bestehender `ui/dialog` bzw. bits-ui Combobox) mit Suche über Navigationsziele, Kunden, Formulare (nur bereits geladene Listen, keine entschlüsselten Inhalte), Aktionen („Formular anlegen“, „Darstellung wechseln“, „Abmelden“); Pfeiltasten/Enter/Esc, `role="dialog"` + `combobox`/`listbox`, sichtbarer Auslöser in der Seitenleiste („Suchen … ⌘K“) für Maus/Touch. Fokus-Rückgabe an Auslöser.
6. **Skeleton-Loader**: `Skeleton`-Komponente (`aria-hidden`, Hintergrund `--surface-sunken`, Schimmer 1,4 s nur ohne reduced-motion), je Karte/Tabellenzeile in Zielhöhe; Container trägt `aria-busy="true"`.
7. **Verlaufs-/Glas-Akzent im Seitenkopf**: `--hero-wash` hinter `PageHeader` der Übersicht und der Formularseite (Textfläche bleibt einfarbig-kontraststabil: Text liegt auf `--background`-nahen Werten, der Verlauf läuft am Rand aus); Glas (`backdrop-filter: blur(12px)`) nur für TopBar beim Scrollen und Befehlspalette, mit deckendem Fallback per `@supports not (backdrop-filter: blur(1px))`.
8. **Karten-Hover**: Anhebung 1 px + `--shadow-hover` nur bei klickbaren Karten (Kunde, Formular); Fokuszustand zusätzlich Ring.
9. **Akzentwahl und Effektstufe** (Vorbild `GlowSwitch`/`AppearanceMenu`): bestehendes Akzentsystem beibehalten; neue Option „Effekte: Aus / Dezent / Voll“ im Darstellungsmenü (Standard „Dezent“; „Aus“ erzwingt auch ohne OS-Einstellung statische Darstellung). Speicherung wie die anderen Darstellungsoptionen (`localStorage`, try/catch).
10. **Dunkelmodus-Feinschliff** wie oben; zusätzlich Ladeblitz vermeiden (Klasse `dark` vor dem ersten Paint setzen, falls nicht schon in `index.html`).

Bewusst **nicht**: Partikel, Parallax, Dauerschleifen-Animationen ohne Funktion, Bewegung von Textblöcken, animierte Diagramme mit über 800 ms.

## (d) ASCII-Wireframes

Legende: `[ ]` Button, `( )` Badge, `●` Statuspunkt, `▁▃▅` Sparkline, `ⓘ` Hilfe-Tooltip.

### Gemeinsame Shell (Desktop 1280)

```text
┌─────────────┬──────────────────────────────────────────────────────────┐
│ ▤ Formular- │ Kunde A  ›  Kontakt  ›  Einsendungen      ⌘K  ☾  ?  (u)  │  TopBar 60 px, Breadcrumb, Konto-Menü
│   Backend   ├──────────────────────────────────────────────────────────┤
│ [🔍 Suchen ⌘K]│ ⚠ Zugriff auf Einsendungen gesperrt.  [Neu anmelden] [x]│  Warn-Banner (Rahmen, Icon, Aktion)
│ ARBEIT      │                                                          │
│ ⌂ Übersicht │ Seitentitel                          [Sekundär] [Primär] │  PageHeader
│ ▤ Formulare │ Untertitel in einem Satz                                 │
│ ⇩ Einsendun.│ ──────────────────────────────────────────────────────── │
│ ▥ Statistik │  Inhalt in Panel-Karten                                  │
│ KUNDE       │                                                          │
│ ⚇ Mitglieder│                                                          │
│ BETRIEB     │                                                          │
│ ⚙ Kunden    │                                                          │
│ ⇄ Umstieg   │                                                          │
│ ────────    │                                                          │
│ ⚙ Konto     │                                                          │
│ ? Hilfe     │                                                          │
│ ● Online    │                                                          │
└─────────────┴──────────────────────────────────────────────────────────┘
```

Mobil (390): TopBar mit ☰, Breadcrumb auf letztes Segment gekürzt, ⌘K-Symbol, Konto-Menü; Hilfe/Version wandern ins Konto-Menü. Seitenleiste als Drawer (bestehendes Muster, Fokusfalle bleibt). Banner einzeilig, Aktion darunter.

### Übersicht / Startseite (neu, `/t/:tenant`, pro Kunde)

```text
Kunde A                                         [+ Formular anlegen]
Übersicht für die letzten 14 Tage · Stand 10:42   (Verlaufs-Kopf)
┌ Einsendungen ⓘ ┐ ┌ Besuche ⓘ ──────┐ ┌ Conversion ⓘ ──┐ ┌ Offene Zustell. ┐
│ 128            │ │ 1 042           │ │ 12,3 %         │ │ 2   (● wartet)  │
│ ▁▂▃▃▅▆▅▇▆▅▇█▆▇ │ │ ▃▃▄▅▅▆▅▆▇▆▆▇▇▆ │ │ ▅▅▄▅▄▄▅▄▅▄▅▅▄▅ │ │ [Prüfen]        │
│ ▲ +14 Vorwoche │ │ ▲ +6 %          │ │ ▼ −0,8 Pkt.     │ │                 │
└────────────────┘ └─────────────────┘ └─────────────────┘ └─────────────────┘
┌ Auffälligkeiten ─────────────────────┐ ┌ Einrichtung 4/6 ────────────────────┐
│ ⚠ Kontakt: 2 Mails nicht zugestellt   │ │ ████████░░░░ 67 %                   │
│     [Zustellungen prüfen]             │ │ ✓ Datenzugang  ✓ Formular           │
│ ● Anfrage: seit 9 Tagen keine         │ │ ✓ Mail         ✓ Veröffentlicht     │
│     Einsendung  [Einbindung prüfen]   │ │ ○ Einbindung testen  ○ Domain       │
│ Keine weiteren Hinweise.              │ │ [Nächsten Schritt öffnen]           │
└───────────────────────────────────────┘ └─────────────────────────────────────┘
┌ Letzte Einsendungen ──────────────────────────────── [Alle ansehen] ┐
│ Kontakt   vor 12 Min.   (Angenommen)          Öffnen ›              │
│ Kontakt   gestern 16:03 (Angenommen) (Geschützt)  Öffnen ›          │
│ Anfrage   31.10.        (Angenommen)          Öffnen ›              │
└──────────────────────────────────────────────────────────────────────┘
┌ Formulare ───────────────────────────────────────────────────────────┐
│ ● Kontakt    v3 · aktiv        ▂▃▅▇▆▅▇  42 / 14 Tage     [Öffnen]    │
│ ○ Anfrage    Entwurf           –                          [Fortsetzen]│
└──────────────────────────────────────────────────────────────────────┘
```

Datenvertrag: Phase 1 nutzt vorhandene formularbezogene APIs (`/forms`, `/forms/:id/statistics`, `/entries`, `/mail-deliveries`) mit parallelem Laden für höchstens 8 Formulare und klarer Kennzeichnung „Summe der geladenen Formulare“; fehlt eine Quelle, zeigt die Kachel „–“ + Grund (kein Nullwert). Ein kundenweiter Aggregationsendpunkt ist eine **separate Vertragsentscheidung** (konzept.md Abschnitt 2). Letzte Einsendungen zeigen nur Metadaten (Zeit, Status, Schutz), keine entschlüsselten Inhalte. Sparkline-Werte aus `days[].count`, fehlende Tage als 0 nur wenn der Server den Zeitraum bestätigt, sonst Lücke. Mobil: Kacheln 2 × 2, Auffälligkeiten vor Einrichtung, Sparklines bleiben.

### Formularseite

```text
Kunde A › Formulare › Kontakt
Kontakt  ● Aktiv  (Version 3)  (Entwurf: Stand 8 gespeichert)    [Entwurf bearbeiten] [Prüfen & veröffentlichen]
Beschreibung/URL in einem Satz
[Überblick] [Einsendungen] [Konfiguration] [Einbindung] [Statistik]     ← Tabs, mobil horizontal scrollbar
┌ Besuche 20 ┐┌ Beginn 12 ┐┌ Absenden 5 ┐┌ Abbruch 3 ┐┌ Conversion 25 % ┐  Kennzahlen + Mini-Sparkline
┌ Verlauf (Linien, Direktbeschriftung) ─────────┐ ┌ Einrichtung ─────────┐
│ Besuche ─ Absenden ─  (Hover/Fokus: Tooltip)   │ │ ✓ Datenzugang        │
│ [30 Tage v]   [Datentabelle anzeigen]          │ │ ○ Mail zuweisen  ›   │
└────────────────────────────────────────────────┘ │ ○ Einbindung prüfen ›│
┌ Zustellungen ──────────┐ ┌ Optional: Google Ads ┐ └──────────────────────┘
│ 2 offen  [Prüfen]      │ │ Nicht verbunden [Verbinden] (Hinweis, kein Fehler)│
```

Aktionen (Pausieren, neuer Entwurf) wandern in ein Karten-Menü „Weitere Aktionen“; Pausieren bleibt mit Statusschalter sichtbar im Kopf.

### Einsendungen

```text
Kunde A › Kontakt › Einsendungen                 [Verschlüsselt exportieren]
Einsendungen  Verschlüsselt gespeichert; Lesen nach Anmeldung.
┌ FilterBar: [🔍 Suchbegriff (lokal)] [Von ▭] [Bis ▭] [Status v] [Zurücksetzen] ┐
│ Datumsfelder: eigenes TT.MM.JJJJ-Format oder deutsch lokalisiert              │
└───────────────────────────────────────────────────────────────────────────────┘
[☐ Alle]  2 ausgewählt:  [Löschschutz] [Löschen]                (Aktionsleiste nur bei Auswahl)
 ☐  31.10.2026 11:00   (Angenommen)  (Nicht geschützt)           [Öffnen]  ⋯
 ☐  30.10.2026 09:14   (Angenommen)  (Geschützt 🔒)               [Öffnen]  ⋯
 Zeilenhöhe 44 px; ⋯ = Löschschutz/Löschen; gesperrt: Öffnen mit Begründung "Datenzugang fehlt" direkt daneben
▸ Aufbewahrung (90 Tage)    ← einklappbare Panel-Zeile am Ende
```

Mobil: Zeilen als kompakte Karten (Zeit + Badges oben, Aktion unten), Filter in „Filter (2)“-Dialog/Disclosure.

### Einstellungen (Betrieb)

```text
Systemeinstellungen   Rangfolge: ENV > Datenbank > Standard
[🔍 Einstellung suchen]  [Quelle: Alle v]
┌ Mail ───────────────────────────────────────────────────┐
│ mail.from           info@…           (Datenbank)  [Ändern]│
│ ingest.rate         60/min           (Standard)   [Ändern]│
│ bootstrap.secretKey ••••             (ENV, gesperrt 🔒)   │
└─────────────────────────────────────────────────────────┘
Fehler: Banner (Rot, "Konnte nicht geladen werden") + [Erneut versuchen]
```

Quellen-Badges mit Text (ENV/Datenbank/Standard), Formularbreite 820 px, Gruppen als Panels, pro Gruppe ein Speichern.

### Umstieg

```text
Umstieg            ● Kein Umstieg gestartet
Nur lesender Zugriff auf einen eingefrorenen Snapshot.
Stepper: (1 Quelle) ── (2 Zuordnung) ── (3 Import) ── (4 Prüfung) ── (5 Umschaltung)   ← aktuelle Phase fett, aria-current="step"
┌ Quelle (nur lesend) ─────────────┐   ┌ Hinweise ──────────────────────┐
│ Host [        ] Port [ 3306 ]    │   │ ⚠ Private Netze nur über       │
│ Datenbank [    ] Benutzer [    ] │   │   migration.allowedNets        │
│ Passwort [      ] TLS [ v ]      │   │ ⓘ Abbruch und Rückkehrplan ›   │
│ [Verbindung prüfen]              │   └─────────────────────────────────┘
└──────────────────────────────────┘
┌ Inventar & Zuordnung ──┐ ┌ Fortschritt ─────────────┐
Fehler: Alert (Rot) "Verbindung unterbrochen. Bestätigter Fortschritt bleibt erhalten." [Erneut versuchen]
```

Rückkehrplan als einklappbare Panels statt Textwand; Rohfelder („JSON“) in „Erweitert“-Disclosure.

### Anmeldung

```text
            ▤  Formular-Backend           (Logo in der Karte, Verlauf im Hintergrund)
        ┌────────────────────────────────┐
        │ Anmelden                       │
        │ Mit Passkey: ein Fingerabdruck │
        │ oder Gerätecode genügt.        │
        │ [ Mit Passkey anmelden ]       │   Primär, volle Breite
        │ ── oder ──                     │
        │ [ Andere Anmeldemöglichkeit ]  │   Sekundär
        │ Probleme beim Zugang? Hilfe    │
        └────────────────────────────────┘
   Status: "Anmeldung wird geprüft …" (aria-live=polite, Skeleton im Button)
```

## (e) Umsetzung in 6 Schritten (Dateibesitz)

Jeder Schritt = ein Paket mit einem schreibenden Agent je Datei (AGENTS.md). Reihenfolge: 1 zuerst (Tokens/Shell sind Vertrag für alle); 2–6 danach parallelisierbar, wenn die gemeinsamen Komponenten aus Schritt 1 (Tokens) und 2 (Kennzahlen) stehen; Schritte 3 und 4 benötigen `PageHeader`/`Panel`/`StatusChip`/`Banner`/`Skeleton`, die in Schritt 1 angelegt werden. Tests je Schritt: vorhandene Vitest- und Playwright-Tests (inklusive axe) bleiben grün; Texte nur in `pwa/src/lib/i18n/de.ts`.

| #   | Paket                                                        | Dateibesitz (exklusiv)                                                                                                                                                                                                                                                                                                                                                                                                                                             | Inhalt                                                                                                                                                                                                                                                                                                                                                                                          |
| --- | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Tokens, Shell, Seitenleiste, TopBar, Befehlspalette          | `pwa/src/app.css`; `pwa/src/lib/components/shell/*` (SidebarNav, TopBar, AppearanceMenu, HelpDialog, VersionInfo, NavIcon, neu `CommandPalette.svelte`); `pwa/src/routes/admin/Shell.svelte`; neue gemeinsame Bausteine `pwa/src/lib/components/admin/{PageHeader,Panel,StatusChip,Banner,EmptyState,Skeleton,Breadcrumb}.svelte`; `pwa/src/lib/i18n/de.ts` (nur Abschnitte `shell`, `palette`, `common`)                                                          | Tokens aus (b); Seitenleiste mit Gruppen (Arbeit / Kunde / Betrieb), Suche + ⌘K-Auslöser, Konto-/Hilfe-/Onlinestatus unten, Symbole einheitlich; TopBar mit Breadcrumb, Kundenwahl als durchsuchbare Combobox (bei einem Kunden statisch), Konto-Menü (Hilfe, Version, Darstellung, Abmelden); globales Sperr-Banner als `Banner`; Befehlspalette; Effekt-Einstellung; mobiler Drawer erhalten. |
| 2   | Übersicht, Kennzahlen, Sparkline                             | `pwa/src/routes/admin/Forms.svelte` (wird zur Kundenübersicht), neu `pwa/src/routes/admin/overview/{TenantOverview,KpiTile,Sparkline,CountUp,AttentionList,SetupProgress,RecentEntries}.svelte` und zugehörige `*.test.ts`; `pwa/src/lib/stats/*` (neue reine Aggregations-/Zeitreihenhilfen)                                                                                                                                                                      | Wireframe „Übersicht“; Sparkline als reines SVG (kein Chart-Paket); `CountUp` mit reduced-motion; paralleles Laden mit Obergrenze, Teil-Ausfälle je Kachel; Formularliste mit Status-Badge/Sparkline. Aggregationsendpunkt nicht vorwegnehmen.                                                                                                                                                  |
| 3   | Formularseite, Tabs, Karten                                  | `FormPage.svelte`, `OverviewTab.svelte`, `StatisticsChart.svelte`, `AdsStatisticsPanel.svelte`, `AdsStatisticsTable.svelte`, `PublishTab.svelte`, `FieldsTab.svelte`, `KeysTab.svelte`, `Installation.svelte` (alle unter `pwa/src/routes/admin/`)                                                                                                                                                                                                                 | Kopf mit Statusbadges, Tabs mit Scroll auf Mobil, Kennzahlenkacheln (nutzt `KpiTile` aus 2 als Import, nicht ändern), Diagramm mit Direktbeschriftung und lesbarer Darstellung bei wenigen Punkten, Datentabelle ohne Überlauf, Google-Ads-Block als optionaler Hinweis, Einrichtungsliste mit Statusikonen.                                                                                    |
| 4   | Einsendungen, Listen/Tabellen, Filter                        | `EntriesTab.svelte`, `Export.svelte`, `SealedExport.svelte`, `Suche.svelte`, `Tenants.svelte`, `pwa/src/lib/components/admin/{FilterBar,DataTable}.svelte` (neu), `pwa/src/lib/components/ui/table/*`                                                                                                                                                                                                                                                              | Wireframe „Einsendungen“; kompakte 44-px-Zeilen, Auswahlleiste, `FilterBar`, lokalisierte Datumseingabe, Begründung direkt am deaktivierten Button, Kundenliste mit echten Zuständen statt „Nicht verfügbar“ (nur wenn Daten vorliegen, sonst Spalte ausblenden).                                                                                                                               |
| 5   | Einstellungen, Umstieg, Konto, Betrieb, Tokens: Formularstil | `Settings.svelte`, `Migration.svelte`, `Account.svelte`, `Ops.svelte`, `AbusePanel.svelte`, `ApiTokens.svelte`, `Connections.svelte`, `Members.svelte`, `MailTab.svelte`, `WebhooksPanel.svelte`, `KeyringPanel.svelte`, `RotationPanel.svelte`, `AccessStatus.svelte`, `ActiveSwitch.svelte`, `pwa/src/lib/components/admin/{Row,Notice,Select,Textarea,FormSection,Stepper}.svelte`, `pwa/src/lib/components/ui/{input,label,select,textarea,switch,checkbox}/*` | Einheitliches Formularraster (Label oben, Hilfetext, Fehler, 820 px), `FormSection`-Panels, Stepper für Umstieg, Quellen-Badges in Einstellungen, Rechtegruppen bei Mitgliedern, harte Rahmen durch `--border-subtle` ersetzen. Sicherheitslogik unverändert.                                                                                                                                   |
| 6   | Anmeldung, Setup, Leer-/Fehler-/Ladezustände                 | `pwa/src/routes/Login*.svelte` bzw. Anmelderoute und `pwa/src/lib/components/shell/AuthShell`-Äquivalent (Datei vor Start per `grep` festlegen), `pwa/src/routes/admin/{Installation,DraftGate,Notice}`-Ladepfade nur für Zustände, `pwa/src/lib/components/admin/{EmptyState,ErrorState,Skeleton}.svelte` (Feinschliff), `pwa/src/lib/i18n/de.ts` (Abschnitte `auth`, `states`)                                                                                   | Wireframe „Anmeldung“; einheitliche Zustände: Skeleton (Laden), `EmptyState` mit Primäraktion, `ErrorState` mit „Erneut versuchen“, 401/403/404-Texte aus konzept.md; Anmeldekarte mit Logo.                                                                                                                                                                                                    |

Abhängigkeiten: Schritt 5 und 6 ändern keine Dateien aus 1–4; `de.ts` ist geteilt: jeder Schritt besitzt nur seine genannten Abschnitte, Konflikte beim Merge durch den Koordinator. Schritte 3 und 4 importieren aus 1 und 2, ändern sie nicht. Falls Schritt 2 hinter 3 liegt, liefert Schritt 3 temporär die Kennzahlenkacheln selbst und wird bei der Integration auf `KpiTile` umgestellt (Koordinator entscheidet).

## (f) Abnahmekriterien

- **WCAG 2.2 AA**: axe-Läufe in `pwa/e2e/admin.spec.ts` (hell und dunkel, alle gelisteten Seiten) bleiben ohne Verstöße; zusätzlich neue Seiten (Übersicht, Einstellungen, Umstieg) in die Liste. Kontrast Text ≥ 4,5:1, UI-Komponenten und Diagrammlinien ≥ 3:1 (Skript mit den Tokens gegen `--surface-*`). Fokus sichtbar (2 px Ring, nicht verdeckt durch sticky TopBar: `scroll-padding-top`), Zielgröße ≥ 24 px (Ziel 40 px).
- **Tastatur**: alle Funktionen ohne Maus; ⌘/Ctrl+K öffnet/schließt Palette, Esc schließt und gibt Fokus zurück; Tab-Reihenfolge folgt der Optik; Skip-Link „Zum Inhalt“; Tabs und Combobox mit Pfeiltasten; Drawer behält Fokusfalle.
- **Bewegung**: Bei `prefers-reduced-motion: reduce` und Effekt-Einstellung „Aus“ keine Zählanimation, kein Puls, kein Schimmer, kein Einblenden (Playwright mit `emulateMedia({ reducedMotion: 'reduce' })` prüft, dass `CountUp` sofort den Endwert zeigt). Keine Animation länger als 1 s; nichts blinkt.
- **Reflow**: bei 320 px Breite kein horizontales Scrollen der Seite (Tabellen scrollen in eigenem Container oder werden Karten); Text 200 % Zoom ohne Verlust; Tests mit Viewport 320 × 640 für Übersicht, Formularseite, Einsendungen, Umstieg.
- **Zustände**: jede Datenquelle hat getestete Lade-/Leer-/Fehlerdarstellung ohne falsche Null (Hinweis aus konzept.md Abschnitt 3 bleibt gültig); Skeleton-Höhe verursacht keinen Sprung (CLS-Sichtprüfung).
- **Performance**: keine neue Laufzeit-Abhängigkeit; Sparklines und Zähler selbst als SVG/TS; Befehlspalette mit vorhandenem `bits-ui`/`ui/dialog`. Ausnahmen nur mit Begründung und AGPL-kompatibler Lizenz in `docs/decisions/`. Bundle-Zuwachs der Hauptroute ≤ 15 KB gzip (mit `npm run build` vergleichen), Schriften unverändert (Inter, bereits lokal), keine Bild-/Webfont-Zusätze; Animationen nur über `transform`/`opacity`.
- **Dunkelmodus**: Screenshot-Sichtprüfung beider Modi je Schritt; Kartenstaffelung erkennbar.
- **Sicherheit/Fachlogik unverändert**: Kein Schritt ändert Autorisierung, Krypto, API-Verträge; kein Entschlüsseln für Dashboard-Kacheln; Kennzahlen nur aus bestehenden, rechtegeprüften Endpunkten.
- **Prüfbefehle je Schritt**: `npm run check`, `npm run lint`, `npm test`, `npm run test:e2e` in `pwa/`; Ergebnis im Handoff nach `docs/handoffs/TEMPLATE.md`.

## Offene Entscheidungen für den Koordinator

1. Kundenweiter Aggregationsendpunkt (Statistik/Einsendungen) ja/nein; bis dahin Phase-1-Lösung mit Obergrenze (siehe (d)).
2. Standard der Effektstufe („Dezent“ vorgeschlagen) und ob sie pro Gerät oder Konto gespeichert wird (Vorschlag: Gerät, `localStorage`).
3. Befehlspalette: bits-ui-Combobox oder eigener Dialog (kein neues Paket in beiden Fällen).

### Entscheidungen des Koordinators (06.11.2026)

1. Kein kundenweiter Aggregationsendpunkt jetzt: Übersicht lädt Statistik/Einsendungen parallel je Formular (Obergrenze 8, Rest nachladen). Endpunkt bleibt Option für später.
2. Effektstufe: Standard „Dezent“, gespeichert pro Gerät (`localStorage`); „Aus“ folgt automatisch aus `prefers-reduced-motion`.
3. Befehlspalette als eigener Dialog auf `ui/dialog`, ohne neues Paket.

## UI-Note: Bewertung und Feinschliff (11.11.2026, Todolino 52B48C94)

Methode: Screenshots aller 22 Seiten (hell/dunkel, 1280/390 px, `SHOTS=dir npx playwright test e2e/screens.spec.ts`) plus Menüs/Dialoge (Bereichsauswahl per G, B bzw. mobiler Drawer, Palette, Darstellung; `-g menus`). Eigenbewertung durch Sichtprüfung; unabhängige Zweitbewertung durch einen Agenten mit frischem Kontext, nur Screenshots.

**Noten.** Eigen (Skala 1-5, 5 = best): Gesamt vorher ca. 4,5 (deckt sich mit dem externen Review); nachher unverändert ca. 4,5, weil nur kleine Mängel behoben wurden. Das Ziel 4,7 je Seite ist NICHT belegt erreicht. Die Zweitbewertung lieferte Noten von 2,0 bis 3,3 (Gesamt 2,6) ohne eindeutig festgelegte Skalenrichtung und stark abweichend von Eigen- und externem Urteil; sie ist als Mängelquelle brauchbar, als Zahl nicht belastbar. Eine Wiederholung nach den Fixes fand nicht statt.

**Behoben (Commits im Worktree-Branch):**

- KPI-Kachel ohne Verlauf (Conversion bei zu wenigen Tagen mit Besuchen) zeigt sichtbar „Kein Verlauf verfügbar“ statt Leerfläche (`KpiTile.svelte`, Test in `overview.test.ts`).
- Passkey-Zeile: Name hervorgehoben, Metadaten gedämpft (`Account.svelte`, `Account.test.ts`).
- Befehlspalette: Tastaturhinweis bei Touchgeräten (`pointer: coarse`) ausgeblendet (`CommandPalette.svelte`, Test).
- Screenshot-Spec um Menüs/Dialoge erweitert.

**Bewusst offen (aus beiden Bewertungen, nach Wirkung/Aufwand; ungeprüft bis auf Sichtbefund):**

1. Mobil: Formular-Übersicht stellt Einrichtung/Aktionen vor die Zeitreihe; Kopfbuttons mobil gekürzt („Bearbeiten“/„Veröffentlichen“).
2. Einsendungen: „Lokale Suche“ als zweite große Karte mit eigenem Zeitraum neben dem Filter; mobil Buttons nicht volle Breite.
3. Redundanz „Versandweg wählen“ in Auffälligkeiten, Einrichtung und Prüfpunkten.
4. Mikrotexte/Kontrast kleiner grauer Hilfetexte (hell und dunkel) und deaktivierte Buttons ohne Begründung (Mitglieder, Weiter).
5. Einstellungen: Metazeilen je Eintrag dicht; „Auf Standard“ ohne Button-Optik.
6. Betrieb: Filterkarte vor Ergebnis; Priorität „1“ ohne Beschriftung; „Jetzt bereinigen“ ohne Warnstil.
7. Konten mobil: Halb-Liste/Halb-Tabelle; Kunden: Rechte als Kommaliste statt Chips.
8. Mail-Seite nur ca. 510 px breit; Speicherverhalten nicht sichtbar (Gegenprüfung nötig, ob Autosave/Entwurfslogik; Befund der Zweitbewertung ungeprüft).
9. Umstieg (nicht angefasst, anderer Agent): Stepper mobil nur aktueller Schritt beschriftet; Fußzeile „Schritt 1 von 5 · …“ bricht unschön um; disabled „Weiter“ im Dunkelmodus kaum erkennbar. Einrichtung/Setup: keine Befunde über die Screenshots hinaus.

### Runde 2 (11.11.2026)

Geprüft statt angenommen: „Kein Speichern-Button“ ist kein Mangel (Speicherleiste `SaveBar` erscheint erst bei Änderungen); „Ablauf gleich Formular“ ist ein Screenshot-Artefakt (Route `flow` existiert nicht, Fallback). Betrieb: Priorität hat `title`, „Jetzt bereinigen“ hat bereits einen Bestätigungsdialog; „Auf Standard“ ist bereits ein Button; Kunden-Rechtespalte ist mobil ausgeblendet.

Umgesetzt (mit Vitest und Playwright `e2e/ui-feinschliff.spec.ts`, 320 px und axe hell/dunkel):

- Formularseite mobil: Einrichtung, Kennzahlen, Zeitreihe, dann Aktionen (vorher Aktionen vor der Zeitreihe); Desktop unverändert.
- Auffälligkeiten ab vier Einträgen einklappbar („n weitere anzeigen“).
- Lokale Suche mobil: Buttons über die volle Breite (`FilterBar` trailing).
- Kundenrechte als Chips; Mail-Formular 720 statt 560 px; „Jetzt bereinigen“ im Warnstil; deaktivierte Primärbuttons mit Rahmen.
- Einstellungen: Quellen-Chip „Standard“ entfällt (Quelle bleibt für Screenreader und in der Zeile „Standard: …“).
- Kartenkopf ohne Beschreibung hält Aktionen mobil neben dem Titel.
- Umstieg/Schritt-Navigation (`StepNav.svelte`, nicht `Migration.svelte`): Zähler und Begründung als ein Satz mit Trenner, Buttons darunter.

Noten (Skala 1-5, 5 = bestmöglich, unabhängige Zweitbewertung mit frischem Kontext, nur Screenshots): Gesamt 4,0 (Desktop/Mobil je Seite 3,2 bis 4,3; z. B. Gesamt 4,3/4,2, Aufbewahrung 4,3/4,2, Mail 3,6/3,7, Einstellungen 3,7/3,2, Umstieg 3,8/3,6, Tokens 4,1/3,6). Die Zweitbewertung ist deutlich strenger als der externe Profi (4,5) und dessen Vorgänger; die Skalen sind nicht gleichgesetzt. Die erste Zweitbewertung hatte keine Skalenvorgabe und ist nicht vergleichbar. Der Screenshot-Stand der Runde 2 enthielt die StepNav-Trenner- und Quellen-Chip-Änderung noch nicht.

Ziel 4,7 je Seite: NICHT erreicht. Bewusst offen: Einstellungen mobil (Metazeilen dicht), Mail überlang/„3 Angaben unvollständig“ ohne Nennung, mobile Tab-Leiste (abgeschnittene Tabs), mobile Tabellenspalten (Konten, Formularverzeichnis), Einbindung mobil (Codeblock horizontal scrollend), dünne Desktop-Tabellen ohne Zusatzspalten, doppelte Datumsfilter in Einsendungen, Stepper mobil nur aktueller Schritt beschriftet (bewusst, Platz), Zeitreihe mit einem Datenpunkt.

### Runde 3 (11.11.2026)

Umgesetzt (Vitest, Playwright `ui-feinschliff.spec.ts` mit 28 Tests inkl. 320 px und axe hell/dunkel): Einstellungen mobil mit Schalter „Technische Angaben“; Mail nennt fehlende Angaben und begründet „Versandweg zuweisen“; lokaler Zeitraum der Suche per Schalter; Hinweis bei dünner Statistik; Tab-Leiste mit Snap; DataTable-Zusatzzeilen mit Spaltenname; Code in Einbindung bleibt horizontal scrollbar (der Umbruchversuch wurde nach der Bewertung zurückgenommen, weil er Bezeichner zerriss).

Zweitbewertung Runde 3 (Skala 1-5, 5 = best, frischer Agent): Gesamt 4,1; Desktop/Mobil u. a. Gesamt 4,3/4,2, Tokens 4,3/4,3, Aufbewahrung 4,3/4,2, Mail 3,6/3,6, Felder 3,9/3,8, Einstellungen 3,8/4,2, Einbindung 4,1/3,6, Konten 4,1/3,9. Ziel >= 4,5 im Schnitt NICHT erreicht (4,1). Darunter bleiben ehrlich: Mail (lange Formularwand ohne Gruppierung), Felder, Einstellungen Desktop (immer sichtbare Technikzeilen), Konten mobil (Spalten in Namenszelle), leere Conversion-Karte, Einbindung mobil, lange Seite „Formulare“, Leerflächen kurzer Seiten, deaktivierte Primärbuttons nur grau. Die Skala der Zweitbewertung ist strenger als der externe Profi (4,5).

### Runde 4 (11.11.2026)

Umgesetzt: Conversion-Karte nennt „Einsendungen ÷ Besuche“ statt Leerfläche; Mail-Absenderadresse/-name zweispaltig; Zusatzangaben in Tabellen mobil gebündelt unter dem Namen (Konten, Kunden). Einbindung-Code bleibt scrollbar mit Verlaufsrand und Kopieren-Button (bereits vorhanden). Nicht umgesetzt: Mail-Gruppierung/Einklappen, Felder-Seite, Einstellungen Desktop kompakter, Leerflächen kurzer Seiten, Einsendungen-Suchzeile.

Zweitbewertung Runde 4 (Skala 1-5, 5 = Linear/Stripe, 3,5 = shadcn-Standard): Gesamt 3,7 (Runde 3: 4,1). Die Zahl ist KEIN Rückschritt der UI: Der Bewerter war mit neuem Kontext deutlich strenger (Ankerskala im Prompt), Varianz zwischen frischen Bewertern ca. ±0,4. Schwächste: Mail 3,3/3,2, Einrichtung 3,4/3,4, Felder 3,6/3,4, Einstellungen 3,6/3,6, Formularverzeichnis 3,6/3,6. Ziel >= 4,5 nicht erreicht; mit dieser Methodik ist der Zahlenvergleich über Runden nicht belastbar.
