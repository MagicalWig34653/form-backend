# UI-Konzept: Formularzentrale

Eigenständiger Entwurf für eine selbst gehostete Admin-PWA auf Basis von Svelte 5, Tailwind und shadcn-svelte. Die Oberfläche ist deutsch, spricht Nutzende mit „Sie“ an und unterstützt Hell- und Dunkelmodus. Dieses Dokument beschreibt das angestrebte Produktverhalten; kryptografische Verfahren und Serverprotokolle müssen vor der Implementierung separat spezifiziert werden.

## 1. Leitidee und Designprinzipien

**Formularzentrale macht Formularbetrieb verständlich, ohne vertrauliche Einsendungen preiszugeben.** Die Hauptaufgaben sind: Probleme erkennen, Einsendungen bearbeiten, Formulare sicher ändern und Änderungen bewusst veröffentlichen.

1. **Orientierung vor Funktionsfülle.** Ein dauerhafter Bereichswähler und eindeutige Seitentitel zeigen, für welchen Kunden oder welches Formular eine Aktion gilt. Der Bereich „Gesamt“ umfasst ausschließlich zugängliche Ressourcen.
2. **Vertrauen durch präzise Zustände.** Anmeldung, Zugriffsrechte und Entschlüsselung sind getrennte Zustände. „Schlüssel gesperrt“ bedeutet nicht „abgemeldet“. Fehlende Messwerte werden als „—“ mit Erklärung gezeigt.
3. **Entwürfe sind sicher, Veröffentlichungen bewusst.** Änderungen an Feldern, Ablauf und Konfiguration werden als Entwurf gespeichert. Die aktive Version bleibt bis zur expliziten Veröffentlichung bestehen.
4. **Einfache Sprache, Details bei Bedarf.** „Verbindung prüfen“ statt „Healthcheck“, „Einsendungen“ statt „Payloads“. Technische Einzelheiten stehen in aufklappbaren Bereichen. Unvermeidbare Begriffe erhalten eine Erklärung.
5. **Aktionen am passenden Ort.** Eine primäre Aktion pro Arbeitsbereich. Massenaktionen erscheinen nach Auswahl, destruktive Aktionen werden optisch zurückgenommen und vor Ausführung erklärt.
6. **Barrierefreiheit ist Bestandteil jedes Musters.** Semantische Elemente, sichtbarer Fokus, Tastaturwege, Textalternativen und verständliche Fehler gehören zum Entwurf und zur Abnahme.
7. **Vertrauliche Inhalte sind flüchtig.** Entschlüsselte Werte bleiben im Arbeitsspeicher der entsperrten Sitzung. Sie erscheinen weder in URLs noch in Telemetrie, Logs, Benachrichtigungen oder persistentem PWA-Cache.
8. **Betrieb mit begrenzter Aufmerksamkeit.** Probleme werden priorisiert und mit konkreten nächsten Schritten versehen. Nicht jeder erfolgreiche Hintergrundvorgang erzeugt einen Toast.

### Verbindliche Produktentscheidungen

- „Kunde“ ist der organisatorische Mandant, „Formular“ die darunterliegende Ressource. Einsendungen gehören unveränderlich zu einem Formular und dessen veröffentlichter Schema-Version.
- Es gibt Systemadministration und explizite Kundenrechte. Systemadministration gewährt keine automatische Entschlüsselung fremder Einsendungen. Dafür ist ein separat berechtigter Schlüsselbund erforderlich.
- Der Server verarbeitet verschlüsselte Einsendungsinhalte und notwendige Betriebsmetadaten. Metadaten wie Kunde, Formular, Empfangszeit, Zustellstatus und Messereignisse sind nicht automatisch geheim; die UI benennt diesen Unterschied.
- Inhaltsbasierte Suche, Vorschau und Inhaltsprüfung finden ausschließlich lokal für tatsächlich entschlüsselte Datensätze statt. Serverseitig erfolgen Filter und Suche nur über erlaubte Metadaten.
- Benachrichtigungs-Mails enthalten keine Einsendungswerte, sondern konfigurierbare Metadaten und einen Link zur Admin-App. Webhooks übertragen verschlüsselte Einsendungen und vereinbarte Metadaten. Ein Klartextversand über den Server ist kein Bestandteil dieses Konzepts.
- Einsendungen werden bei Änderungen nicht rückwirkend in neue Feldschemata umgedeutet. Details verwenden die ursprüngliche Version und zeigen deren Kennzeichnung.

## 2. Informationsarchitektur und Navigation

### Hauptnavigation

| Gruppe | Ziel | Bereichsabhängigkeit | Sichtbarkeit |
|---|---|---|---|
| Arbeiten | Dashboard | Gesamt / Kunde / Formular | Alle angemeldeten Konten mit Ressourcenrecht |
| Arbeiten | Einsendungen | Gesamt / Kunde / Formular | Mit Leserecht; Inhalte zusätzlich schlüsselabhängig |
| Arbeiten | Statistik | Gesamt / Kunde / Formular | Mit Leserecht auf Betriebsmetadaten |
| Verwalten | Kunden | Liste aller erlaubten Kunden | Kundenanlage nur Systemadministration |
| Verwalten | Formulare | Gesamt: alle erlaubten; Kunde: dessen Formulare; Formular: Einzelressource | Nach Kundenrechten |
| Entwickeln | API-Tokens | Expliziter Geltungsbereich pro Token | Nur für eigene delegierbare Rechte |
| System | Verbindungen | Systemweit | Systemadministration |
| System | Einstellungen | Systemweit | Systemadministration |
| System | Betrieb | Systemweit | Systemadministration |
| System | Migration | Expliziter Zielkunde | Systemadministration und nötige Zielrechte |
| Fußbereich | Konto, Hilfe | Persönlich beziehungsweise global | Alle |

Installation, Ersteinrichtung, Anmeldung und Einladung liegen außerhalb der angemeldeten Shell. Die globale Suche hat eine eigene Ergebnisseite; die Befehlspalette ist ein ergänzender Dialog.

### Seitentypen und Hierarchie

- **Kunden:** Liste → Kundendetail mit Übersicht, Mitglieder & Einladungen, Rechte. Von der Übersicht führt eine gefilterte Verknüpfung zu Formularen.
- **Formulare:** Liste → Formulardetail mit neun Reitern: Übersicht, Felder, Einsendungen, Mail, Webhooks, Speicher & Aufbewahrung, Ablauf, Veröffentlichen, Schlüssel.
- **Einsendungen:** Liste → Detailseite. Die Formular-Reiteransicht verwendet dieselbe Listenkomponente mit festem Formularfilter.
- **Statistik:** eine Auswertungsseite mit Abschnitten für Verlauf, Status, Formularvergleich und Quellen.
- **API-Tokens:** Liste → Erstellen im Dialog → einmalige Geheimnisanzeige im Dialog.
- **Verbindungen:** Übersicht → Verbindungsdetail für SMTP, Domain oder Dienst.
- **Betrieb:** Übersicht mit Warteschlangen, Mail-Zustellung, Backups und Versionen als Unteransichten.
- **Migration:** Import-Assistent mit Prüfbericht und abschließender Übernahme.
- **Konto:** Sicherheit, Schlüsselbund & Wiederherstellung, Sitzungen, Darstellung & Sprache.

### Bereichswähler und Navigationsregeln

Der Kopfbereich enthält einen durchsuchbaren `Popover` mit `Command`: „Gesamt“, Kunden und darunter Formulare. Für bis zu etwa 1.500 Formulare wird nicht der gesamte Baum aufgeklappt; Suchtreffer zeigen „Formular · Kunde“. Auswahl und Tastaturfokus sind getrennt. Enter bestätigt, Escape schließt ohne Änderung.

- Dashboard, Einsendungen und Statistik übernehmen den Bereich unmittelbar. Zeitraum und verträgliche Filter bleiben bestehen; unvereinbare Filter werden entfernt und knapp erläutert.
- Der Bereich steht in der URL und ist teilbar. Konkrete Ressourcenpfade enthalten stabile Kunden- und Formular-IDs. Klartextinhalte, Suchtexte über Einsendungswerte und Geheimnisse stehen nie in der URL.
- Beim Öffnen eines Formulars wechselt der Bereich auf dieses Formular. „Formulare“ führt von dort zur Liste des zugehörigen Kunden. Ein Bereichswechsel innerhalb der Formularreiter führt beim Ziel „Formular“ zum entsprechenden zulässigen Reiter, bei „Kunde“ zur Formularliste und bei „Gesamt“ zur Gesamtliste.
- Bei systemweiten und persönlichen Seiten steht neben dem weiterhin sichtbaren Bereichswähler „Diese Seite gilt systemweit“ beziehungsweise „Persönliche Einstellungen“. Der Bereich bleibt für die Rückkehr gespeichert, begrenzt aber diese Seiten nicht.
- Breadcrumbs beschreiben die Ressourcenhierarchie, nicht die Klickhistorie. Browser-Zurück stellt Filter, Scrollposition und Fokus wieder her.
- Ohne Ressourcen erscheint eine Startansicht mit dem passenden nächsten Schritt: „Kunden anlegen“ für Systemadministration oder „Sie haben noch keinen Bereich zugewiesen“ für andere Konten.

### Rechte und Sichtbarkeit

| Recht je Kunde | Erlaubt | Erlaubt für sich allein nicht |
|---|---|---|
| Lesen | Ressourcen, Metadaten, Statistik; Einsendungen bei vorhandenem Schlüssel anzeigen und exportieren | Konfiguration verändern, Schlüssel verteilen |
| Bearbeiten | Formulare als Entwurf bearbeiten; Einsendungen markieren, löschen und Aufbewahrung konfigurieren | Veröffentlichen, neue Formulare anlegen |
| Veröffentlichen | Geprüfte Entwurfsversion aktivieren oder ältere Version als neuen Entwurf übernehmen | Entwurf bearbeiten, Rechte vergeben |
| Schlüssel | Schlüsselzuweisungen, Rotation und Wiederherstellungsprozesse verwalten | Inhalte ohne passenden privaten Schlüssel lesen |
| Anlegen | Neue Formulare im Kunden anlegen | Neue Kunden anlegen |

Lesen ist Voraussetzung für weitere Kundenrechte. „Kundenmitglieder verwalten“ ist eine zusätzliche ausdrücklich zugewiesene Verwaltungsbefugnis; sie umfasst keine automatische Schlüsselweitergabe. Neue Konten erhalten vorgeschlagen „Lesen“, weitere Rechte werden bewusst ergänzt. Niemand kann mehr Rechte delegieren, als er selbst verwalten darf. Einladungen unterscheiden „Zugang eingerichtet“ und „Schlüsselzugriff ausstehend“.

Nicht relevante Navigationsziele sind verborgen. Auf einer grundsätzlich zugänglichen Seite sind fehlende Aktionsrechte mit Erklärung sichtbar, etwa „Zum Veröffentlichen benötigen Sie das entsprechende Kundenrecht“. Direkte unberechtigte URLs zeigen eine eigene Zugriffsseite; der Server erzwingt alle Rechte unabhängig von der UI.

## 3. Layout-Shell und responsives Verhalten

### Desktop

- Seitenleiste: 248 px, einklappbar auf 64 px; Textlabels bleiben für Assistenztechnik erhalten. Aktueller Eintrag mit Fläche, linker Markierung und `aria-current`.
- Kopfzeile: mindestens 64 px; Bereichswähler links, globale Suche, Schlüsselstatus, Konto und Hilfe rechts. Keine dauerhaft zweite horizontale Werkzeugleiste.
- Inhaltsbereich: 32 px Außenabstand, maximal 1.440 px breit. Tabellen dürfen die verfügbare Breite nutzen; Fließtext und einfache Formulare höchstens 720 px.
- Seitenkopf: Breadcrumbs, H1, erklärender Satz, daneben primäre Aktion. Filter und Reiter darunter. Klebende Werkzeugleisten erhalten einen Hintergrund und verdecken weder Fokus noch Ankerziele.
- Formularreiter werden auf mittleren Breiten in eine zweite Zeile oder ein beschriftetes Reitermenü überführt; keine neun gequetschten Textlabels.

### Tablet und Mobil

- Ab 1.200 px dauerhafte Seitenleiste; 768–1.199 px einklappbare Leiste; darunter öffnet „Menü“ ein modales `Sheet` mit Fokusfang und Rückkehr zum Auslöser.
- Auf kleinen Displays bleibt in der Kopfzeile Platz für Menü, verkürzten Bereichswähler und Schlüsselstatus. Suche und Konto sind über klar beschriftete Schaltflächen erreichbar. Der Schlüsselstatus verschwindet nie im Menü.
- Inhaltsabstand mobil 16 px. Karten bilden eine Spalte, Aktionsleisten umbrechen. Primäre Aktionen sind mindestens 44 × 44 px groß. Kein horizontales Scrollen der Gesamtseite bei 320 CSS-Pixeln Breite.
- Listen nutzen mobil definierte Zusammenfassungen mit denselben Informationen: Hauptkennung, Kunde/Formular, Zeitpunkt, Status. „Details“ öffnet die Zeile; ein separates Kontrollkästchen dient der Auswahl. Komplexe Tabellen erhalten alternativ einen bezeichneten horizontalen Scrollbereich.
- Formulareditor: Felderliste, Eigenschaften und Vorschau werden zu drei expliziten Ansichten. „Zurück zu den Feldern“ erhält den Bearbeitungsstand. Vorschau ist nie Voraussetzung zum Bedienen.
- Dialoge erscheinen auf kleinen Displays fast bildschirmfüllend und scrollen im Inhalt. Titel und Schließen bleiben erreichbar; die Bildschirmtastatur verdeckt keine Fehler oder Aktionen.
- Mobile Sammelaktionen sind als Leiste oberhalb der Liste sichtbar. Keine ausschließliche Wischgeste, kein Hover-Zwang.

### Persistente Statusbereiche

Schlüsselanzeige: „Gesperrt“, „Teilweise entsperrt · 2 von 4 Formularen“ oder „Entsperrt“. Das Menü zeigt den Umfang, die letzte Entsperrung und „Jetzt sperren“. Ein Schloss-Symbol ist durch Text ergänzt. Bei wenig Platz ist „Schlüssel: gesperrt“ zugänglich beschriftet; der sichtbare Kurztext lautet „Gesperrt“.

Ein Offline-Banner steht direkt unter der Kopfzeile: „Sie sind offline. Änderungen und neue Daten sind derzeit nicht verfügbar.“ Jede betroffene Ansicht zeigt zusätzlich ihren Datenstand. Verbindungs-, Rechte- und Schlüsselprobleme erhalten getrennte Meldungen.

## 4. Design-Tokens

Neutrale Flächen, dunkle Schrift und ein ruhiges Blau als Standardakzent. Rot bezeichnet Fehler und irreversible Folgen; Orange Handlungsbedarf; Grün belegten Erfolg. Farben werden stets mit Text oder Symbol kombiniert. Die folgenden Rollen sind für Tailwind und die shadcn-svelte-Themenzuordnung vorgesehen; sie sind keine vollständige Build-Konfiguration.

```css
:root {
  color-scheme: light;
  --background: #f8fafc;
  --foreground: #172033;
  --card: #ffffff;
  --card-foreground: #172033;
  --popover: #ffffff;
  --popover-foreground: #172033;
  --primary: #1d4ed8;
  --primary-foreground: #ffffff;
  --secondary: #e8edf5;
  --secondary-foreground: #24334c;
  --muted: #f1f5f9;
  --muted-foreground: #526176;
  --accent: #e8efff;
  --accent-foreground: #173eaa;
  --destructive: #b91c1c;
  --destructive-foreground: #ffffff;
  --border: #cbd5e1;
  --input: #64748b;
  --ring: #1d4ed8;
  --success: #166534;
  --success-surface: #ecfdf5;
  --warning: #854d0e;
  --warning-surface: #fffbeb;
  --info: #1e40af;
  --info-surface: #eff6ff;
  --error-surface: #fef2f2;
  --sidebar: #ffffff;
  --sidebar-foreground: #24334c;
  --sidebar-primary: #1d4ed8;
  --sidebar-primary-foreground: #ffffff;
  --sidebar-accent: #e8efff;
  --sidebar-accent-foreground: #173eaa;
  --sidebar-border: #cbd5e1;
  --sidebar-ring: #1d4ed8;
  --chart-1: #1d4ed8;
  --chart-2: #0f766e;
  --chart-3: #7e22ce;
  --chart-4: #a16207;
  --chart-5: #be185d;
  --radius: 0.5rem;
  --radius-sm: 0.25rem;
  --radius-md: 0.375rem;
  --radius-lg: 0.5rem;
  --radius-xl: 0.75rem;
  --font-sans: "Inter", system-ui, sans-serif;
  --font-mono: ui-monospace, "SFMono-Regular", monospace;
  --text-xs: 0.75rem;
  --text-sm: 0.875rem;
  --text-base: 1rem;
  --text-lg: 1.125rem;
  --text-xl: 1.25rem;
  --text-2xl: 1.5rem;
  --text-3xl: 1.875rem;
  --leading-body: 1.5;
  --leading-heading: 1.2;
  --space-1: 0.25rem;
  --space-2: 0.5rem;
  --space-3: 0.75rem;
  --space-4: 1rem;
  --space-6: 1.5rem;
  --space-8: 2rem;
  --space-12: 3rem;
  --control-height: 2.75rem;
  --shadow-card: 0 1px 3px rgb(15 23 42 / 0.08);
  --shadow-overlay: 0 12px 40px rgb(15 23 42 / 0.18);
  --motion-fast: 120ms;
  --motion-normal: 180ms;
}

.dark {
  color-scheme: dark;
  --background: #0b1220;
  --foreground: #e5edf8;
  --card: #111c2e;
  --card-foreground: #e5edf8;
  --popover: #152238;
  --popover-foreground: #e5edf8;
  --primary: #93c5fd;
  --primary-foreground: #102445;
  --secondary: #23334b;
  --secondary-foreground: #e5edf8;
  --muted: #18253b;
  --muted-foreground: #adbbcf;
  --accent: #203e67;
  --accent-foreground: #dbeafe;
  --destructive: #fca5a5;
  --destructive-foreground: #450a0a;
  --border: #40536d;
  --input: #8194ad;
  --ring: #93c5fd;
  --success: #86efac;
  --success-surface: #102e24;
  --warning: #fde68a;
  --warning-surface: #342a12;
  --info: #bfdbfe;
  --info-surface: #152f50;
  --error-surface: #391b25;
  --sidebar: #111c2e;
  --sidebar-foreground: #e5edf8;
  --sidebar-primary: #93c5fd;
  --sidebar-primary-foreground: #102445;
  --sidebar-accent: #203e67;
  --sidebar-accent-foreground: #dbeafe;
  --sidebar-border: #40536d;
  --sidebar-ring: #93c5fd;
  --chart-1: #93c5fd;
  --chart-2: #5eead4;
  --chart-3: #d8b4fe;
  --chart-4: #fde68a;
  --chart-5: #f9a8d4;
  --shadow-card: 0 1px 3px rgb(0 0 0 / 0.24);
  --shadow-overlay: 0 12px 40px rgb(0 0 0 / 0.4);
}
```

### Anwendung der Tokens

- Fließtext 16/24 px, Tabellen und Metadaten 14/21 px, Nebenlabels mindestens 12/18 px. Seitentitel 30/36 px, Abschnittstitel 20/26 px; mobil Seitentitel 24/30 px. Gewicht 400 für Text, 500 für Labels, 600 für Überschriften. Zahlen in Kennzahlen und Tabellen mit gleich breiten Ziffern.
- Schrift lokal ausliefern; kein externer Schriftabruf. Monospace nur für IDs, Geheimnisse und Einbettungsfragmente.
- Rhythmus: 4 px Basiseinheit, 8 px zwischen Label und Feld, 16 px zwischen Formularfeldern, 24 px zwischen Gruppen, 32 px zwischen großen Abschnitten.
- Kleine Badges Radius 4 px, Eingaben und Buttons 6 px, Karten 8 px, Dialoge 12 px. Pills nur für Status und kleine Filterchips.
- Fokus: mindestens 2 px Ring mit 2 px Abstand, in jeder Fläche sichtbar. Der dunklere `--input`-Token markiert interaktive Feldgrenzen; `--border` ist vorwiegend eine dekorative Trennlinie.
- Kontoeinstellung für Akzentfarben: Blau, Violett oder Petrol aus vorab geprüften Hell-/Dunkel-Paaren. Nur Primäraktion, Fokus und Auswahl wechseln; Statusfarben und Diagrammserien bleiben semantisch stabil. Keine freie Farbeingabe.
- Kontrastziel: mindestens 4,5:1 für normalen Text, 3:1 für große Schrift und relevante Bedienelemente. Alle tatsächlich eingesetzten Kombinationen einschließlich Hover, Fokus und Akzentvarianten werden geprüft. Diagramme verwenden zusätzlich Linienmuster, Marker und direkte Labels.
- Animationen kurz und funktional; bei reduzierter Bewegung entfallen Übergänge, Skeleton-Schimmern und Diagrammaufbau. Es gibt keine Information nur durch Animation.

## 5. Komponenten und wiederverwendbare Muster

Die Bezeichnungen orientieren sich an shadcn-svelte. Zusammengesetzte Muster wie DataTable, Bereichswähler und Diagrammkarte werden als eigene Svelte-Komponenten gebaut; sie sind keine als fertig angenommenen Bibliotheksfunktionen. Diagramm- und Tabellendaten bleiben unabhängig von der Darstellung.

| Seitentyp | shadcn-svelte-Bausteine | Eigenes wiederverwendbares Muster |
|---|---|---|
| Shell | Sidebar, Sheet, Breadcrumb, Dropdown Menu, Button, Separator, Tooltip | Bereichswähler aus Popover + Command; Schlüsselstatus; Offline-Banner |
| Dashboard | Card, Badge, Alert, Skeleton, Table, Progress | Kennzahlenkarte, Aufmerksamkeitsliste, Verlauf mit Datentabelle |
| Listen | Table, Checkbox, Input, Select, Popover, Calendar, Pagination, Dropdown Menu | DataTable mit serverseitigem Sortieren/Filtern, Datumsbereich, Massenaktionsleiste |
| Details | Card, Tabs, Badge, Accordion, Separator | Metadatenblock, versionsgebundene Werteanzeige, Änderungsstatus |
| Formulare | Field, Label, Input, Textarea, Select, Checkbox, Radio Group, Switch, Alert | Validierung mit Fehlersprungliste und nicht verlorenen Eingaben |
| Editor / Ablauf | Card, Collapsible, Button, Select, Dialog, Tabs | Feldliste mit Tastatur-Reihenfolge, Eigenschafteneditor, Bedingungszeilen, Vorschau |
| Diagramme | Chart, Card, Tabs, Table, Select | Beschriftete Chart-Karte mit gleichwertiger Tabelle und Datenqualitätsanzeige |
| Auth / Schlüssel | Card, Input, Input OTP, Progress, Alert Dialog | WebAuthn-Auslöser, Entsperrdialog, Wiederherstellungsprüfung |
| Assistenten | Card, Progress, Separator, Alert, Table | Benannte Schrittliste, Prüfbericht, fortsetzbarer Vorgang |
| Rückmeldungen | Alert, Sonner, Skeleton, Progress | Quellenfehler, leere Ansicht, Aktionsstatus |
| Overlay / Suche | Dialog, Alert Dialog, Command, Scroll Area | Globale Suche, Befehlspalette, kontextbezogene Hilfe |

Für kurze Statusmeldungen wird eine einzige Toast-Lösung verwendet. Tooltips ergänzen Beschriftungen, ersetzen sie aber nicht. `Tabs` dienen Ansichten derselben Ressource; Navigationsreiter mit eigener URL werden als Links mit aktivem Zustand umgesetzt. Fehlende Bibliotheksbausteine werden semantisch gleichwertig erstellt, ohne zusätzliche UI-Sprache einzuführen.

Kurze Komponenten-Skizzen:

```text
AppShell → Sidebar + Header(Bereich, Suche, Schlüssel) + Main + Statusmeldungen
SubmissionList → Filterleiste + DataTable/ListCards + Auswahlaktionen + Pagination
FormPage → ResourceHeader + FormNavigation + DraftStatus + Reiterinhalt
ChartCard → Titel + Datenstand + Chart + „Datentabelle“ + Quellenfehler
```

## 6. Seiten und ASCII-Wireframes

Die Wireframes zeigen die Inhaltsstruktur. `[Text]` bezeichnet eine Aktion oder Eingabe, `{Text}` einen Status. Die Desktop-Shell umschließt alle angemeldeten Seiten. Die mobilen Transformationen aus Abschnitt 3 gelten für jedes Wireframe. Alle Zahlen und Namen in diesem Abschnitt sind ausschließlich beschriftete Beispieldaten für den Entwurf, keine Ersatzwerte bei einem Ladefehler.

### 6.1 Gemeinsame Shell

```text
+--------------------+---------------------------------------------------+
| Formularzentrale   | [Bereich: Gesamt v] [Suche / Strg+K]              |
|                    | [Schlüssel: Gesperrt] [Hilfe] [Konto v]          |
| Dashboard          +---------------------------------------------------+
| Einsendungen       | Breadcrumb                                        |
| Statistik          | Seitentitel                    [Primäre Aktion]   |
| ------------------ | Beschreibung                                      |
| Kunden             |                                                   |
| Formulare          | Seiteninhalt                                      |
| API-Tokens         |                                                   |
| ------------------ |                                                   |
| Verbindungen       |                                                   |
| Einstellungen      |                                                   |
| Betrieb            |                                                   |
| Migration          |                                                   |
| Konto / Hilfe      |                                                   |
+--------------------+---------------------------------------------------+
Mobil: [Menü] [Bereich v] [Gesperrt] [Suche]
       Seitentitel
       [Primäre Aktion]
       Inhalt in einer Spalte
```

Komponenten: Sidebar, Sheet, Breadcrumb, Command, Popover, Dropdown Menu, Button, Alert.

### 6.2 Installation und Ersteinrichtung

```text
+-----------------------------------------------------------------------+
| Formularzentrale einrichten                 Schritt 2 von 5            |
| 1 Voraussetzungen > 2 Konto > 3 Schlüssel > 4 Verbindungen > 5 Prüfung |
|                                                                       |
| Erstes Administrationskonto                                           |
| Name [                         ]                                      |
| E-Mail [                       ]                                      |
| [Passkey erstellen]                  {Noch nicht eingerichtet}         |
|                                                                       |
| [Zurück]                                          [Weiter]            |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Field, Input, Progress, Alert, Button. Voraussetzungen prüfen HTTPS, erreichbare Dienste und Installationsstatus. Die erste Kontoanlage ist nur mit installationsgebundenem Einmalnachweis möglich; nach Abschluss ist sie geschlossen. Schritt 3 legt Schlüsselbund und Wiederherstellung an und verlangt eine erfolgreiche Wiederherstellungsprüfung. Schritt 4 erlaubt das Überspringen noch nicht nötiger Verbindungen. Schritt 5 zeigt konkrete Prüfergebnisse, offene Aufgaben und „Einrichtung abschließen“. Bei Unterbrechung wird nur nicht geheimes Fortschrittswissen gespeichert. Anschließend führt die App zur Kundenanlage.

### 6.3 Anmeldung

```text
+-----------------------------------------------+
| Willkommen bei Formularzentrale                |
| [Mit Passkey anmelden]                         |
|                                               |
| [Mit Authenticator-Code anmelden]              |
| [Hilfe bei der Anmeldung]                      |
| Status: Warten auf Ihre Bestätigung …          |
+-----------------------------------------------+
```

Komponenten: Card, Button, Alert; bedingt Input OTP und Passwort-Input. Standard ist Passkey ohne Passwortfeld. Falls ein Konto einen zusätzlichen Passwortfaktor verlangt, folgt dieser nach der ersten erfolgreichen Identifikation. TOTP ist nur nach ausdrücklicher Aktivierung ein alternativer Anmeldeweg; es gibt keinen Passwort-Allein-Login. Fehlgeschlagene Versuche bestätigen nicht die Existenz eines Kontos. Passkey-Abbruch zeigt „Anmeldung abgebrochen. Sie können es erneut versuchen.“ Nach alternativer Anmeldung bleiben Inhaltsschlüssel gesperrt. Geräte ohne nötige Passkey-Funktionen erhalten passende Anleitungen, keinen unbrauchbaren wiederholten Dialog.

### 6.4 Einladung und Enrollment

```text
+-----------------------------------------------------------------------+
| Einladung zu „Musteragentur“                                         |
| Zielkunde: Nordlicht     Rechte: Lesen, Bearbeiten                      |
| 1 Einladung prüfen > 2 Zugang > 3 Abschluss                            |
|                                                                       |
| [Passkey für neues Konto erstellen]                                   |
| [Mit bestehendem Konto annehmen]                                      |
| {Schlüsselzugriff wird separat freigegeben}                            |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Badge, Alert, Button. Abgelaufene, benutzte und widerrufene Links erhalten eigene Zustände. Der Einmal-Link wird nach erfolgreicher Annahme ungültig, aus der Adresszeile entfernt und nicht an andere Seiten weitergereicht. Wiederholtes Öffnen erklärt den Status. Eine Einladung erstellt keine Kopie privater Schlüssel. Nach Enrollment zeigt eine Aufgabenkarte, ob Schlüsselzugriff noch beantragt oder freigegeben werden muss.

### 6.5 Dashboard

```text
+-----------------------------------------------------------------------+
| Dashboard · Gesamt                    [Letzte 7 Tage v] [Aktualisieren]|
| {Datenstand 10:42}                                                    |
| [Besuche] [Beginne] [Absendungen] [Abbrüche] [Konversion]               |
| Je Karte: Wert / Vergleich zur Vorwoche / kleiner Verlauf              |
|                                                                       |
| Verlauf [Kennzahl v]                  Aufmerksamkeit                   |
| +-----------------------------+      ! SMTP-Test fehlgeschlagen       |
| | Diagramm                    |      ! Formular noch nicht bereit     |
| +-----------------------------+      [Problem öffnen]                 |
| [Datentabelle anzeigen]                                               |
| Letzte Einsendungen                  Einrichtung 3 von 5              |
| Zeit | Kunde | Formular | Status     [Nächsten Schritt öffnen]         |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Chart, Table, Alert, Badge, Progress. Letzte Einsendungen zeigen standardmäßig nur Metadaten; keine automatisch entsperrten Inhaltsvorschauen. Aufgaben sind nach Handlungsbedarf und Berechtigung sortiert. Unvollständige Metriken betreffen nur ihre jeweilige Karte; funktionsfähige Quellen bleiben nutzbar.

### 6.6 Kundenliste und Kundenanlage

```text
+-----------------------------------------------------------------------+
| Kunden                                          [Kunden anlegen]      |
| [Kunden suchen] [Status v]                                             |
| [ ] Name          Formulare     Einrichtung     Ihre Rechte      [...] |
| [ ] Nordlicht     12            Vollständig      Lesen, Bearbeiten     |
| [ ] Westufer       3            1 Aufgabe        Lesen                 |
| [Vorherige] Seite 1 von 2 [Nächste]                                   |
+-----------------------------------------------------------------------+
| Dialog: Kunden anlegen                                                |
| Name [                 ]  Interne Kennung [                  ]         |
| [Abbrechen]                                      [Kunden anlegen]     |
+-----------------------------------------------------------------------+
```

Komponenten: Table, Input, Select, Pagination, Dialog, Field. Anlage nur für Systemadministration. Nach Erstellung folgt die Kundenübersicht mit „Erstes Formular anlegen“ und „Mitglieder einladen“. Bei fehlendem Anlagerecht erscheint diese Aktion nicht; die Listenleere erklärt stattdessen fehlende Zuweisungen.

### 6.7 Kunde: Übersicht

```text
+-----------------------------------------------------------------------+
| Kunden / Nordlicht                                  [Bearbeiten]      |
| [Übersicht] [Mitglieder & Einladungen] [Rechte]                         |
| Formulare: 12     Offene Aufgaben: 1                                  |
| [Dashboard dieses Kunden] [Formulare öffnen]                           |
| Stammdaten                        Einrichtung                         |
| Name: Nordlicht                   [Formular anlegen]                  |
| Kennung: nordlicht                [Mitglieder einladen]                |
+-----------------------------------------------------------------------+
```

Komponenten: Navigationsreiter, Card, Badge, Dialog. Stammdatenbearbeitung übernimmt dieselbe Formularstruktur wie Anlage; Kennungsänderungen weisen gegebenenfalls auf betroffene externe Verknüpfungen hin.

### 6.8 Kunde: Mitglieder und Einladungen

```text
+-----------------------------------------------------------------------+
| Nordlicht / Mitglieder & Einladungen          [Person einladen]       |
| Person          Zugang         Schlüsselzugriff      Aktionen         |
| Alex Beispiel   Aktiv          Freigegeben           [Rechte] [...]  |
| Einladung …     Ausstehend     Ausstehend             [Widerrufen]    |
|                                                                       |
| Dialog: E-Mail [                ]                                     |
| Rechte [Lesen v]   Gültigkeit: 7 Tage                                  |
| [Abbrechen]                                   [Einladung erstellen]   |
+-----------------------------------------------------------------------+
```

Komponenten: Table, Badge, Dialog, Checkbox, Alert Dialog. Einladungslink nach Erstellung kopierbar; Versand nur über konfigurierte Mailverbindung. Versandfehler lassen die Einladung bestehen und bieten erneuten Versand. Entfernen einer Person widerruft deren Autorisierung; die UI erklärt, dass bereits heruntergeladene Klartexte oder Schlüsselkopien dadurch nicht zurückgeholt werden.

### 6.9 Kunde: Rechte

```text
+-----------------------------------------------------------------------+
| Nordlicht / Rechte                                                   |
| Person [Alex Beispiel v]                                             |
| [x] Lesen             [x] Bearbeiten                                  |
| [ ] Veröffentlichen   [ ] Schlüssel verwalten   [ ] Formulare anlegen  |
| [ ] Kundenmitglieder verwalten                                       |
| Effektiver Zugriff: 12 Formulare · Schlüssel für 8 Formulare           |
| [Änderungen prüfen]                                                  |
+-----------------------------------------------------------------------+
```

Komponenten: Select, Checkbox, Card, Alert Dialog. Änderungen zeigen Vorher/Nachher und verlangen erneute Passkey-Bestätigung. Die letzte handlungsfähige Systemadministration darf sich nicht selbst aussperren. Änderungen wirken serverseitig sofort; betroffene offene Sitzungen aktualisieren Rechte und verwerfen nicht mehr erlaubte Klartexte.

### 6.10 Formularliste und Anlage

```text
+-----------------------------------------------------------------------+
| Formulare · Nordlicht                            [Formular anlegen]   |
| [Suchen] [Status v] [Einrichtung v]                                    |
| Name        Veröffentlichung    Entwurf     Empfang       Aufgaben     |
| Kontakt     Version 4 aktiv     Geändert    Aktiv         Keine        |
| Bewerbung   Nicht veröffentlicht Neu       Inaktiv       Schlüssel    |
| [Vorherige]                                        [Nächste]          |
+-----------------------------------------------------------------------+
| Dialog: Formular anlegen                                             |
| Kunde [Nordlicht v]  Name [                     ]                     |
| [Abbrechen]                                    [Entwurf anlegen]      |
+-----------------------------------------------------------------------+
```

Komponenten: Table, Badge, Dialog, Field, Select. Kundenwahl ist im Kundenbereich vorbelegt, im Formularbereich wird der Elternkunde verwendet. Neue Formulare starten als Entwurf und führen zur Übersicht mit geführten Aufgaben. Status unterscheidet aktive Version, Änderungen im Entwurf und Empfang aktiv/pausiert.

### 6.11 Formular: Übersicht

```text
+-----------------------------------------------------------------------+
| Nordlicht / Kontakt                         {Version 4 aktiv}         |
| Übersicht | Felder | Einsendungen | Mail | Webhooks | Weitere v        |
| {Entwurf geändert · Gespeichert um 10:43}     [Veröffentlichung prüfen] |
| [Empfang aktiv]      [Absendungen] [Konversion] [Zustellprobleme]        |
| Einrichtung: Felder ✓ Schlüssel ✓ Domain ✓ Einbettung offen           |
| Aktive Version 4              Entwurf basiert auf Version 4            |
| [Integration öffnen]          [Entwurf weiterbearbeiten]               |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Badge, Progress, Navigationsreiter, Alert. Empfang pausieren ist eine unmittelbare Betriebsaktion mit Bestätigungsdialog und Auswirkungsbeschreibung; sie wartet nicht auf eine Entwurfsveröffentlichung. Das ist deutlich von Konfigurationsänderungen getrennt.

### 6.12 Formular: Felder

```text
+-----------------------------------------------------------------------+
| Kontakt / Felder                      {Entwurf gespeichert}           |
| [Feld hinzufügen v]                           [Vorschau öffnen]       |
| Felderliste              Eigenschaften              Vorschau          |
| 1 Name        [↑][↓]     Beschriftung [Name     ]    Name [       ]    |
| 2 E-Mail      [↑][↓]     Kennung [name          ]    E-Mail [     ]    |
| 3 Anliegen    [↑][↓]     Typ [Text v]               Anliegen [    ]    |
|                          [x] Pflichtfeld            [Absenden]        |
|                          [Weitere Einstellungen]                      |
|                          [Feld entfernen]                             |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Button, Input, Select, Checkbox, Accordion, Dialog. Typen: einzeiliger Text, mehrzeiliger Text, E-Mail, Telefon, Zahl, Datum, Einfachauswahl, Mehrfachauswahl, Kontrollkästchen/Einwilligung und Datei. Datei-Felder sind erst veröffentlichbar, wenn auch die Dateiverschlüsselung und Speichergrenzen eingerichtet sind. Auswahltypen haben stabile Optionskennungen; Labels dürfen geändert werden. Feldkennungen sind nach Erstveröffentlichung nicht frei umbenennbar.

Jedes Feld hat „Nach oben“, „Nach unten“ und „An Position verschieben“. Nach dem Verschieben bleibt der Fokus am Feld; eine höfliche Live-Meldung nennt die neue Position. Ziehen ist optional. Änderungen am Feldtyp oder das Entfernen bereits verwendeter Felder erklären die Wirkung auf neue Einsendungen; historische Einsendungen bleiben lesbar. Vorschau nutzt Testdaten, erzeugt keine echte Einsendung und sendet nichts an den Server.

### 6.13 Einsendungen: globale Liste und Formularreiter

```text
+-----------------------------------------------------------------------+
| Einsendungen · Gesamt                           [Exportieren]         |
| [Zeitraum v] [Status v] [Metadaten suchen] [Weitere Filter]            |
| {Schlüssel gesperrt} [Entsperren]                                      |
| [ ] Eingang       Kunde       Formular    Bearbeitung   Schlüssel      |
| [ ] Heute 10:40   Nordlicht   Kontakt     Neu           Gesperrt        |
| [ ] Heute 10:31   Westufer    Anfrage     Erledigt      Entsperrt       |
| Nach Auswahl: 2 ausgewählt [Status ändern] [Export] [Löschen]          |
| [25 pro Seite v] [Vorherige] Seite 1 [Nächste]                          |
+-----------------------------------------------------------------------+
```

Komponenten: Table, Checkbox, Popover, Calendar, Select, Input, Pagination, Badge. Der Formularreiter zeigt dieselbe Struktur ohne redundante Kunden-/Formularspalten. Suche über IDs und Metadaten ist sofort verfügbar. „Inhalte lokal durchsuchen“ ist ein eigener Modus nach Entsperrung; Umfang, geladene Anzahl und noch ungeprüfte Datensätze bleiben sichtbar. Der Modus erzeugt keinen falschen Anspruch auf vollständige globale Suche.

Bearbeitungsstatus: Neu, In Bearbeitung, Erledigt. Spamverdacht und Entschlüsselungsstatus sind separate Merkmale. Eine Kontaktnachricht ist kein Bearbeitungsstatus. Gesperrte Listen enthalten keine Inhalts-Sortierungen oder Inhalts-Snippets.

### 6.14 Einsendungsdetail

```text
+-----------------------------------------------------------------------+
| Einsendungen / E-1042                       [Vorherige] [Nächste]      |
| Kontakt · Nordlicht · Eingang 10.11.2026, 10:40                         |
| Bearbeitung [Neu v]        {Schema: Version 4}          [Aktionen v]   |
|                                                                       |
| {Inhalte gesperrt}                                                     |
| Entsperren Sie den Schlüssel für dieses Formular. [Entsperren]         |
| Nach Entsperrung: Name / E-Mail / Anliegen als beschriftete Werte       |
| Dateien: [Dateiname · Größe · Herunterladen]                           |
| Metadaten | Zustellung | Verlauf                                      |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Badge, Select, Accordion, Alert Dialog. Nutzerwerte sind Text, kein aktives HTML. URLs werden nur bei unterstütztem Schema als Links angeboten. Dateiinhalt wird vor einem Download lokal entschlüsselt; eine sichere Vorschau ist optional. „Wert kopieren“ meldet nur Erfolg, wiederholt den Wert nicht im Toast. Schlüsselverlust oder beschädigte Daten erscheinen pro Feld/Datei oder Einsendung, ohne andere Datensätze zu blockieren. Der Verlauf enthält betriebliche Aktionen und keine Klartextwerte.

### 6.15 Exportdialog

```text
+-----------------------------------------------------------------------+
| Einsendungen exportieren                                              |
| Umfang: 24 ausgewählte Einsendungen in 3 Formularen                    |
| ( ) CSV, entschlüsselt   ( ) JSON, entschlüsselt   (o) Verschlüsselt    |
| {Für CSV/JSON fehlen noch Schlüssel für 1 Formular} [Entsperren]       |
| [ ] Metadaten einschließen                                            |
| Exportdatei enthält vertrauliche Daten.                                |
| [Abbrechen]                                    [Export vorbereiten]   |
+-----------------------------------------------------------------------+
```

Komponenten: Dialog, Radio Group, Checkbox, Progress, Alert. Der verschlüsselte Export ist auch gesperrt möglich, sofern Leserechte vorliegen; er enthält einen Manifestbericht mit Schema-Versionen und Schlüsselkennungen, niemals private Schlüssel. Klartextexport wird lokal erzeugt. Bei unterschiedlichen Formularschemas enthält CSV ein Paket mit einer Datei je Formular/Schema und einer Übersicht, JSON behält die Struktur. Teilfehler erfordern eine bewusste Wahl zwischen Abbrechen und „Nur verfügbare Datensätze exportieren“; ein Bericht nennt Auslassungen. CSV schützt vor Tabellenformel-Ausführung; die Option wird verständlich als „Tabellenwerte sicher ausgeben“ erklärt und ist standardmäßig aktiv.

### 6.16 Spam- und Missbrauchsübersicht

```text
+-----------------------------------------------------------------------+
| Einsendungen / Spam & Missbrauch                                      |
| [Zeitraum v] [Formular v] [Signal v]                                   |
| [Verdachtsfälle] [Blockierte Anfragen] [Rate-Limit-Ereignisse]          |
| Zeitpunkt | Formular | Signal          | Entscheidung | [...]         |
| 10:18     | Kontakt  | Viele Anfragen   | Prüfen        | [Öffnen]     |
| [Ausgewählte als unbedenklich markieren] [Als Spam markieren]          |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Table, Badge, Select, Alert Dialog. Erreichbar aus Einsendungen über „Spam & Missbrauch“. Signale beruhen auf erlaubten Metadaten und konfigurierten Schutzmechanismen, nicht auf einer behaupteten serverseitigen Inhaltsanalyse. Blockierte Anfragen ohne gespeicherte Einsendung öffnen nur das Ereignisdetail. Fehlklassifikation und Korrektur sind nachvollziehbar; Löschung bleibt eine getrennte Aktion.

### 6.17 Statistik

```text
+-----------------------------------------------------------------------+
| Statistik · Gesamt                    [Zeitraum v] [Vergleich v]      |
| [Verlauf] [Status] [Formularvergleich] [Quellen & Kampagnen]            |
| Kennzahl [Konversion v]       Auflösung [Tag v]                        |
| +-------------------------------------------------------------------+ |
| | Beschriftetes Diagramm mit Legende und Markern                      | |
| +-------------------------------------------------------------------+ |
| [Datentabelle anzeigen]                  {Quelle / Datenstand}        |
| Datum/Quelle | Besuche | Beginne | Absendungen | Konversion            |
| [Aggregierte Daten exportieren]                                      |
+-----------------------------------------------------------------------+
```

Komponenten: Navigationsreiter, Chart, Table, Select, Card, Alert. Jeder Diagrammabschnitt besitzt eine direkt zugeordnete Tabelle mit denselben Filtern und Werten. Formularvergleich entfällt bei einem einzelnen Formular mit erklärendem Hinweis. Quellen umfassen Kampagnenparameter und aggregierte Herkunft, keine heimlich erfassten Einsendungswerte.

### 6.18 Formular: Mail

```text
+-----------------------------------------------------------------------+
| Kontakt / Mail                             {Entwurf gespeichert}      |
| [x] Benachrichtigungen senden                                        |
| Empfänger [verwaltung@beispiel.de                  ]                   |
| SMTP-Verbindung [Standard v] {Verbindung bereit}                       |
| Betreff [Neue Einsendung für {{Formularname}}       ]                  |
| Nachricht [Metadaten und sicherer Link …            ]                  |
| Erlaubte Platzhalter [anzeigen]        [Vorschau] [Test-Mail senden]   |
| Hinweis: Einsendungsinhalte werden nicht per Mail versendet.           |
+-----------------------------------------------------------------------+
```

Komponenten: Switch, Field, Input, Textarea, Select, Dialog, Alert. Platzhalter sind auf sichere Metadaten begrenzt. Test-Mail verwendet ausdrücklich Beispieldaten und markiert den Betreff als Test. Empfänger außerhalb der eigenen Organisation werden vor Veröffentlichung in der Zusammenfassung hervorgehoben. SMTP-Zugangsdaten stehen ausschließlich in den Verbindungen der Systemadministration.

### 6.19 Formular: Webhooks

```text
+-----------------------------------------------------------------------+
| Kontakt / Webhooks                               [Webhook hinzufügen]|
| Ziel                     Ereignisse       Status          [...]       |
| https://…/eingang        Neue Einsendung   Aktiv           [Öffnen]    |
|                                                                       |
| Ziel-URL [https://…                 ]                                  |
| Signatur {Eingerichtet} [Geheimnis ersetzen]                           |
| Ereignisse [x] Neue Einsendung                                        |
| [Testlauf mit Beispieldaten]                                          |
| Zustellprotokoll: Zeit | Versuch | HTTP-Status | Ergebnis | [Details]   |
+-----------------------------------------------------------------------+
```

Komponenten: Table, Dialog, Input, Checkbox, Badge, Accordion. Signaturgeheimnisse sind nur bei Erzeugung sichtbar. Der Testlauf kennzeichnet Ziel und verwendete Entwurfskonfiguration. Empfangende Systeme entschlüsseln nur mit selbst verwalteten Schlüsseln; die Admin-App übergibt keine privaten Schlüssel. Protokolle redigieren Geheimnisse und enthalten keine Klartexte. Wiederholung einer Zustellung warnt vor möglicher doppelter Verarbeitung; Ereignis-ID bleibt stabil. Zielvalidierung und Schutz interner Netze erfolgen serverseitig.

### 6.20 Formular: Speicher und Aufbewahrung

```text
+-----------------------------------------------------------------------+
| Kontakt / Speicher & Aufbewahrung                                     |
| [Speicher belegt] [Einsendungen] [Nächster Löschlauf]                    |
| Aufbewahrung (o) 90 Tage ( ) Unbegrenzt                                |
| Dateiobergrenze [10 MB v]  Gesamtgrenze [              ]               |
| Vorschau: 128 Einsendungen wären nach Aktivierung löschbar.            |
| [Änderung prüfen]                         [Bereinigung öffnen]        |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Radio Group, Input, Select, Alert Dialog. Änderungen sind Entwurfskonfiguration; aktive Regeln und geplante Änderungen stehen nebeneinander. Vor Veröffentlichung einer Verkürzung zeigt die App die betroffene Menge und den frühesten Löschzeitpunkt. Sofortige Bereinigung ist eine separate Betriebsaktion mit Passkey-Bestätigung. Löschung umfasst verschlüsselte Inhalte und Dateien; verbleibende Aggregate und die begrenzte Lebensdauer von Backupkopien werden ausgewiesen. „Unbegrenzt“ verlangt eine ausdrückliche Auswahl, es ist kein stiller Standard.

### 6.21 Formular: Ablauf / Flow

```text
+-----------------------------------------------------------------------+
| Kontakt / Ablauf                              {Entwurf gespeichert}   |
| Schritte                      Regeln für „Firma“                     |
| 1 Kontakt [↑][↓]              Wenn [Kundentyp v] [ist v] [Firma v]     |
| 2 Anliegen [↑][↓]             Dann [Schritt anzeigen v]               |
| 3 Abschluss [↑][↓]            [Bedingung ergänzen]                     |
| [Schritt hinzufügen]          [Regel prüfen]                           |
| Prüfbericht: Keine Zyklen · Alle Pflichtfelder erreichbar              |
| [Ablauf als Liste] [Vorschau mit Testfall]                             |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Select, Input, Button, Alert. Primäre Darstellung ist eine geordnete Liste; ein optionaler Graph ersetzt sie nicht. Regeln besitzen explizite UND-/ODER-Gruppen, Feldreferenzen und benannte Zielschritte. Prüfung erkennt fehlende Referenzen, Schleifen, unerreichbare Schritte und Pflichtfelder in widersprüchlichen Pfaden. Verborgene Pflichtfelder blockieren eine Einsendung nicht; der Prüfbericht erklärt die Regel. Beispieldurchläufe können einzelne Pfade prüfen.

### 6.22 Formular: Veröffentlichen und Integration

```text
+-----------------------------------------------------------------------+
| Kontakt / Veröffentlichen                                             |
| Aktiv: Version 4        Entwurf: Änderung 18, Basis Version 4           |
| Prüfung: Felder ✓ Ablauf ✓ Schlüssel ✓ Domain ✓                       |
| Änderungen: 1 Feld ergänzt, Mail-Empfänger geändert                   |
| Versionsnotiz [                                      ]                |
| [Entwurf prüfen]                      [Version 5 veröffentlichen]     |
|                                                                       |
| Integration der aktiven Version 4                                     |
| Domain [www.beispiel.de v] SDK {Version …}                             |
| [SDK-Datei herunterladen] [Einbettungscode kopieren/herunterladen]     |
| Versionsverlauf: 4 aktiv | 3 | 2     [Als neuen Entwurf übernehmen]     |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Table, Badge, Alert Dialog, Textarea. Der Prüfbericht unterscheidet Blocker und bestätigbare Hinweise. Veröffentlichung erfordert das passende Recht und erneute Passkey-Bestätigung. Angezeigte Revisionsnummern binden Prüfung, Bestätigung und Schreibzugriff an denselben Stand. Ändert sich der Entwurf, verfällt die Freigabe. Die Serverannahme ist atomar; bei unklarem Netzwerkergebnis prüft die App den tatsächlichen Stand statt blind erneut zu veröffentlichen.

Bei Konflikt: „Der Entwurf wurde inzwischen von einer anderen Person geändert.“ Optionen: Unterschiede anzeigen, eigenen Stand lokal als Datei sichern oder die neue Fassung laden. Kein stilles Überschreiben und kein ungeprüftes automatisches Zusammenführen von Ablauflogik. Aktivierung wird nach bestätigtem Serverstand als Erfolg gemeldet. Die Integrationssektion zeigt ausschließlich die aktive Version; unpublizierte Vorschauen sind separat markiert. Eine frühere Version wird erst durch erneute Prüfung und Veröffentlichung wieder aktiv.

### 6.23 Formular: Schlüssel

```text
+-----------------------------------------------------------------------+
| Kontakt / Schlüssel                         {Teilweise entsperrt}     |
| Aktiver Empfangsschlüssel K-05     Seit 02.11.2026                      |
| Ältere Schlüssel: K-01 bis K-04     Für historische Daten erforderlich |
| Person          Berechtigung      Schlüsselbereitstellung             |
| Alex Beispiel   Lesen             Bereit                              |
| Kim Beispiel    Lesen             Ausstehend [Freigeben]               |
| [Schlüssel rotieren] [Wiederherstellung prüfen] [Jetzt sperren]         |
+-----------------------------------------------------------------------+
```

Komponenten: Table, Badge, Alert Dialog, Progress. Rotation erzeugt einen neuen Schlüssel für neue Einsendungen, behält erforderliche ältere Schlüssel und zeigt Fortschritt, Abbruchmöglichkeiten und den Aktivierungszeitpunkt. Sie ersetzt keine schon verbreiteten Schlüsselkopien. Schlüsselweitergabe benötigt Verwaltungsrecht, vorhandenes Schlüsselmaterial und Empfängerprüfung. Ein serverseitiger Administrator kann keinen verlorenen privaten Schlüssel rekonstruieren. Ein Wiederherstellungsprozess benötigt das vorher angelegte Wiederherstellungsmaterial.

### 6.24 Globale Suche und Befehlspalette

```text
+-----------------------------------------------------------------------+
| Suche                                                                |
| [Kunden, Formulare oder Einsendungs-ID suchen                      ]   |
| [Alle] [Kunden] [Formulare] [Einsendungen]                              |
| Nordlicht                         Kunde                              |
| Kontakt · Nordlicht               Formular                           |
| E-1042 · Kontakt                  Einsendung                         |
| Inhalte: Gesperrt. [Entsperren und lokal durchsuchen]                  |
+-----------------------------------------------------------------------+
| Dialog: Befehle und Suche · Strg/Cmd+K                                |
| [Befehl oder Suchbegriff                                          ]   |
| > Zu Einsendungen wechseln                                           |
| > Bereich wechseln                                                   |
| > Schlüssel sperren                                                  |
| [Alle Suchergebnisse öffnen]                                         |
+-----------------------------------------------------------------------+
```

Komponenten: Command, Dialog, Input, Tabs, Badge. Globale Metadatensuche umfasst nur berechtigte Ressourcen und nennt deren Kundenkontext. Lokal entschlüsselte Inhalte sind getrennt mit dem untersuchten Umfang gekennzeichnet. Tastenkürzel wird nicht in Textfeldern abgefangen, außer dem expliziten Strg/Cmd+K. Die Palette führt riskante Aktionen nie unmittelbar aus, sondern öffnet deren Prüfansicht. Sie hat einen sichtbaren Auslöser und ist keine Voraussetzung für eine Funktion.

### 6.25 API-Tokens

```text
+-----------------------------------------------------------------------+
| API-Tokens                                        [Token erzeugen]   |
| Name         Geltungsbereich      Rechte     Letzte Nutzung   [...]    |
| Bericht      Nordlicht            Lesen      Gestern          Widerruf |
|                                                                       |
| Dialog: Name [           ]  Kunde/Formular [         v]                |
| Rechte [x] Metadaten lesen  [ ] Einsendungen exportieren               |
| Ablaufdatum [                 ]                                      |
| [Abbrechen]                                        [Token erzeugen]   |
+-----------------------------------------------------------------------+
| Einmalige Anzeige: [Geheimnis …] [Kopieren]                            |
| [ ] Ich habe das Token sicher gespeichert. [Anzeige schließen]        |
+-----------------------------------------------------------------------+
```

Komponenten: Table, Dialog, Field, Checkbox, Calendar, Alert Dialog. Rechte sind granular und nie umfassender als delegierbare Nutzerrechte. Tokens liefern keinen Entschlüsselungsschlüssel. Erzeugung und Widerruf erfordern Passkey-Bestätigung. Nach Schließen ist das Geheimnis nicht erneut abrufbar; verloren bedeutet neu erzeugen und das alte widerrufen. Das Bestätigungsfeld verhindert ein versehentliches Schließen, beweist aber keine sichere Speicherung. Bei verlorenem Netzwerkergebnis wird ein möglicherweise erzeugtes Token anhand der Vorgangskennung angezeigt und widerrufbar gemacht, sein Geheimnis nicht rekonstruiert.

### 6.26 Verbindungen: Übersicht

```text
+-----------------------------------------------------------------------+
| Verbindungen · Systemweit                  [Verbindung hinzufügen v]  |
| SMTP            Standard       {Bereit}           [Prüfen] [Öffnen]   |
| Domain          beispiel.de    {Prüfung offen}    [Prüfen] [Öffnen]   |
| Dienst          Speicher       {Nicht erreichbar}[Prüfen] [Öffnen]   |
| Letzter Test: Zeitpunkt · Ergebnis · Betroffene Formulare              |
+-----------------------------------------------------------------------+
```

Komponenten: Table, Badge, Dropdown Menu, Alert. Ein fehlgeschlagener Test ersetzt nicht den letzten belegten produktiven Zustand; Teststatus und Betriebsstatus werden getrennt angezeigt. Abhängigkeiten sind vor Deaktivierung sichtbar.

### 6.27 Verbindungsdetail: SMTP, Domain, Dienst

```text
+-----------------------------------------------------------------------+
| Verbindungen / Standard-SMTP                       [Speichern]        |
| Typ: SMTP     Host [          ] Port [   ] Verschlüsselung [TLS v]     |
| Benutzer [               ] Passwort {Gesetzt} [Ersetzen]               |
| Absender [               ]                                           |
| Testempfänger [          ] [Verbindung prüfen] [Test-Mail senden]     |
| Testergebnis: DNS ✓ Verbindung ✓ Anmeldung !                          |
| Verwendet von: 8 Formularen [Anzeigen]                                 |
+-----------------------------------------------------------------------+
```

Komponenten: Field, Input, Select, Alert, Table. Domainvariante: Domainname, erlaubte Ursprünge, Verifikationsnachweis, DNS-Anleitung, „Nachweis prüfen“. Dienstvariante: Typ, Endpunkt, geheime Zugangsdaten, erlaubte Verwendung, Verbindungstest. Alle drei verwenden denselben Detailrahmen, aber nur passende Felder. Gespeicherte Geheimnisse werden nie als Platzhaltertext zurückgesendet; „Unverändert lassen“, „Ersetzen“ und „Entfernen“ sind explizit. Systemkonfigurationsänderungen gelten direkt nach bestätigtem Speichern und zeigen ihre Reichweite; sie sind keine Formularentwürfe.

### 6.28 Systemeinstellungen

```text
+-----------------------------------------------------------------------+
| Einstellungen · Systemweit                        [Änderungen prüfen] |
| [Allgemein] [Sicherheit] [Grenzen] [Datenschutz]                        |
| Instanzname [Formularzentrale              ]                          |
| Öffentliche Basisadresse [https://…        ]                          |
| Sicherheitsvorgaben: Sitzungsdauer / erneute Bestätigung               |
| Standards: Aufbewahrung / Schutz vor Missbrauch                        |
| Datenschutz: Messereignisse / Protokollfristen                         |
| Hinweis: Änderungen wirken auf …                                     |
+-----------------------------------------------------------------------+
```

Komponenten: Navigationsreiter, Field, Input, Switch, Alert Dialog. Standardwerte ändern bestehende Formulare nicht unbemerkt. Sicherheitsrelevante Änderungen zeigen Vorher/Nachher und benötigen Passkey-Bestätigung. Deploymentgebundene Einstellungen sind lesbar, mit Herkunft „Serverkonfiguration“ und passender Betriebsanleitung statt eines wirkungslosen Eingabefelds.

### 6.29 Betrieb: Zustand

```text
+-----------------------------------------------------------------------+
| Betrieb · Systemweit                             [Aktualisieren]     |
| [Zustand] [Warteschlangen] [Mail] [Backups] [Versionen]                 |
| API {Bereit}   Datenbank {Bereit}   Speicher {Gestört}                  |
| Quelle: Dienstprüfung · Stand 10:42                                    |
| Aktuelle Vorfälle                                                     |
| ! Dateispeicher nicht erreichbar [Betroffene Vorgänge]                 |
| [Wartungsmodus vorbereiten]                                           |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Badge, Alert, Table. Jeder Dienst meldet seinen eigenen Zustand einschließlich „Unbekannt“. Wartungsmodus zeigt Auswirkungen auf Einsendungsempfang und Adminzugriff sowie eine kontrollierte Rückkehr. Diagnosedetails enthalten Vorgangs-IDs, keine Inhalte.

### 6.30 Betrieb: Warteschlangen

```text
+-----------------------------------------------------------------------+
| Betrieb / Warteschlangen                                              |
| [Warteschlange v] [Status v]                                          |
| [Wartend] [In Arbeit] [Fehlgeschlagen] [Ältester Auftrag]               |
| Auftrag | Typ | Alter | Versuche | Fehlercode | [Details]              |
| Auswahl: [Erneut versuchen] [Aufträge verwerfen]                        |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Table, Checkbox, Alert Dialog. Wiederholung nennt mögliche Nebenwirkungen und übernimmt eine stabile Vorgangs-ID. Teilfehler werden je Auftrag angezeigt. „Verwerfen“ erklärt, ob Daten oder nur die Zustellaufgabe betroffen sind.

### 6.31 Betrieb: Mail-Zustellung

```text
+-----------------------------------------------------------------------+
| Betrieb / Mail-Zustellung                                             |
| [Zeitraum v] [SMTP v] [Ergebnis v]                                     |
| Zeit | Formular | Empfänger | Versuche | Ergebnis | [Details]          |
| Detail: Fehlerklasse / nächster Versuch / redigierte Serverantwort     |
| [Erneut zustellen]                                                    |
+-----------------------------------------------------------------------+
```

Komponenten: Table, Select, Accordion, Alert Dialog. Kein Mailtext mit Einsendungswerten. Empfängeradressen werden entsprechend betrieblicher Berechtigungen gezeigt. Der Status „Angenommen“ bedeutet Übergabe an den Mailserver, nicht belegte Zustellung an die Person.

### 6.32 Betrieb: Backups

```text
+-----------------------------------------------------------------------+
| Betrieb / Backups                              [Backup starten]      |
| Letztes Backup: Erfolgreich · Letzter Wiederherstellungstest: Offen     |
| Zeitpunkt | Umfang | Größe | Prüfergebnis | [Details]                  |
| [Wiederherstellung vorbereiten]                                      |
| Hinweis: Private Schlüssel benötigen eine eigene Wiederherstellung.   |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Table, Progress, Dialog, Alert Dialog. Backupübersicht nennt Serverkonfiguration, Metadaten und verschlüsselte Inhalte als getrennte Bestandteile. Ein Serverbackup ersetzt keinen persönlichen Schlüsselbund. Wiederherstellung bietet Zielprüfung, Wartungsfenster, Sicherung des aktuellen Stands und eine abschließende Passkey-Bestätigung. Wenn die Installation keinen App-gesteuerten Restore erlaubt, zeigt die Seite einen exportierbaren Prüfplan und den externen Betriebsweg statt einer scheinbar ausführbaren Aktion.

### 6.33 Betrieb: Versionen

```text
+-----------------------------------------------------------------------+
| Betrieb / Versionen                                                   |
| Server: …    Admin-App: …    SDK: …    Datenbankschema: …              |
| Kompatibilität {Geprüft / Prüfung nicht verfügbar}                     |
| [Versionshinweise] [Update-Anleitung]                                  |
| {Neue App-Version verfügbar} [Neu laden]                              |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Table, Alert, Button. Kein unterstellter automatischer Server-Updater. Die App zeigt die tatsächlich installierten Versionen; fehlende Updateprüfung ist „Nicht geprüft“, nicht „Aktuell“. Ein Service-Worker-Update wird bei offenen Entwürfen oder laufenden Exporten zurückgestellt.

### 6.34 Migration

```text
+-----------------------------------------------------------------------+
| Migration · Schritt 3 von 5                                           |
| Quelle > Zuordnung > Prüfung > Übernahme > Ergebnis                    |
| Zielkunde [Nordlicht v]                                               |
| Prüfbericht: 320 gültig · 8 Konflikte · 2 nicht lesbar                  |
| Zeile | Ziel | Problem | Vorgeschlagene Lösung                         |
| [Bericht herunterladen] [Zuordnung korrigieren]                        |
| [Zurück]                                     [Übernahme vorbereiten] |
+-----------------------------------------------------------------------+
```

Komponenten: Progress, Field, Table, Select, Alert Dialog. Upload-/Dateiauswahl, Zuordnung, Prüfbericht, Übernahme und Ergebnis sind Schritte derselben Seite mit eigenen Zuständen. Klartext aus Altsystemen wird lokal geprüft und vor Übertragung mit dem Zielschlüssel verschlüsselt. Bei großen Mengen gibt es lokale Teilverarbeitung, Fortschritt und Abbruch; kein stiller Klartext-Upload als Ausweichweg. Bekannte verschlüsselte Formate benötigen den passenden lokalen Schlüssel.

Pflichtzuordnungen, Dubletten, Dateianhänge, Schemaabweichungen und fehlende Schlüssel werden vor der Übernahme geprüft. Übernahme zeigt Ziel und Umfang und verlangt Passkey-Bestätigung. Ein Lauf besitzt eine stabile Kennung, damit Wiederaufnahme keine Duplikate erzeugt. Ergebnis unterscheidet übernommen, übersprungen, fehlgeschlagen und noch offen. Ein Abbruch nimmt bereits übernommene Daten nicht still zurück; ein gezieltes Entfernen dieses Importlaufs wird separat angeboten, sofern dessen Daten nicht inzwischen weiterbearbeitet wurden.

### 6.35 Konto: Sicherheit

```text
+-----------------------------------------------------------------------+
| Mein Konto                                                           |
| [Sicherheit] [Schlüsselbund] [Sitzungen] [Darstellung & Sprache]        |
| Passkeys                                          [Passkey ergänzen] |
| Gerät | Angelegt | Letzte Nutzung | Ableitung verfügbar | [Entfernen]  |
| Zusätzlicher Passwortfaktor {Nicht aktiv} [Einrichten]                 |
| TOTP-Anmeldung {Nicht aktiv} [Einrichten]                              |
| Anmeldung und Entschlüsselung sind getrennte Vorgänge.                 |
+-----------------------------------------------------------------------+
```

Komponenten: Table, Dialog, Input, Input OTP, Switch, Alert Dialog. Neue Passkeys werden benannt und vor Abschluss getestet. Ein Passwort ist optionaler zusätzlicher Faktor; es ist kein alleiniger Anmeldeweg und wird nicht still als Entschlüsselungsschlüssel verwendet. TOTP wird erst nach Bestätigung eines Codes aktiviert, mit verständlicher Erklärung des alternativen Zugangs. Mindestens ein nutzbarer Passkey bleibt erhalten, damit sensible Aktionen bestätigt werden können. Entfernen, Faktoränderungen und Enrollment benötigen eine frische Passkey-Bestätigung.

### 6.36 Konto: Schlüsselbund und Wiederherstellung

```text
+-----------------------------------------------------------------------+
| Mein Konto / Schlüsselbund & Wiederherstellung                        |
| Schlüsselbund {Gesperrt}                           [Entsperren]        |
| Lokale Methode: Passkey-Ableitung / Wiederherstellungsmaterial         |
| Abgedeckte Kunden: 3 · Formulare: 28 · Ältere Schlüssel: Vorhanden      |
| [Wiederherstellungsmaterial erstellen/erneuern]                        |
| [Wiederherstellung prüfen] [Verschlüsserten Schlüsselbund exportieren] |
| Automatisch sperren nach [15 Minuten Inaktivität v]                    |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Table, Select, Dialog, Alert Dialog. Wiederherstellungsmaterial wird einmalig gezeigt oder heruntergeladen und durch eine echte lokale Wiederherstellungsprobe bestätigt. Export des verschlüsselten Schlüsselbunds allein genügt nicht zum Wiederherstellen; erforderliche Zusatzmittel stehen direkt am Download. Ohne Passkey-Ableitungsunterstützung ist ein getesteter alternativer lokaler Entsperrweg nötig. Anmeldung darf trotzdem funktionieren, ohne eine erfolgreiche Entschlüsselung vorzutäuschen.

### 6.37 Konto: Sitzungen

```text
+-----------------------------------------------------------------------+
| Mein Konto / Sitzungen                         [Andere Sitzungen beenden]|
| Gerät / Browser | Beginn | Letzte Aktivität | Status | Aktion          |
| Dieses Gerät    | Heute  | Jetzt            | Aktiv  | [Abmelden]      |
| Anderes Gerät   | Gestern| Vor 2 Stunden    | Aktiv  | [Beenden]       |
+-----------------------------------------------------------------------+
```

Komponenten: Table, Badge, Alert Dialog. Geräteangaben werden als Näherungswerte bezeichnet. Das Beenden anderer Sitzungen erfordert Passkey-Bestätigung. Eigene Abmeldung sperrt zuerst Schlüssel und löscht flüchtige Klartexte, anschließend endet die Serversitzung. Bei offline ausgelöster Abmeldung wird lokal sofort gelöscht und darauf hingewiesen, dass der serverseitige Widerruf erst bei erreichbarem Server bestätigt werden kann.

### 6.38 Konto: Darstellung und Sprache

```text
+-----------------------------------------------------------------------+
| Mein Konto / Darstellung & Sprache                                    |
| Erscheinungsbild ( ) Hell ( ) Dunkel (o) System                         |
| Akzentfarbe [Blau v]        [Vorschau]                                 |
| Sprache [Deutsch v]                                                   |
| Zeitzone [Europe/Berlin v]   Datumsformat: 10.11.2026, 14:30            |
| PWA: [App installieren]                                               |
+-----------------------------------------------------------------------+
```

Komponenten: Radio Group, Select, Card, Button. Einstellungen wirken direkt und werden als persönliche Präferenz gespeichert. Deutsch ist die initial verfügbare Sprache; weitere Sprachen werden erst bei vollständiger Übersetzung auswählbar. Nicht unterstützte Installation zeigt eine browserbezogene Anleitung; es gibt keinen dauerhaft deaktivierten Installationsknopf. Systemdesignänderungen werden nur im Modus „System“ übernommen.

### 6.39 Hilfe

```text
+-----------------------------------------------------------------------+
| Hilfe zu „Einsendungen“                                      [Schließen]|
| Was bedeutet „Gesperrt“?                                             |
| Entsperren Sie den passenden Schlüssel, um Inhalte lokal zu lesen.     |
| [Dokumentation öffnen] [Tastaturbedienung anzeigen]                    |
| Diagnosekennung [Kopieren]                                            |
| Formularzentrale · Version … · Lizenz AGPL-3.0                        |
| [Lizenztext] [Quellcode dieser Installation]                           |
+-----------------------------------------------------------------------+
```

Komponenten: Dialog, Accordion, Button, Separator. Kontextbezogene Kurzhilfe ist auch ohne externes Dokumentationsnetz erreichbar. Dokumentation und Quellcodeziel werden durch die Installation konfiguriert; die App zeigt nur vorhandene Ziele. Diagnoseinformationen enthalten keine Einsendungswerte, Token oder Schlüssel.

### 6.40 Zugriffs- und Fehlerseiten

```text
+-----------------------------------------------------------------------+
| Dieser Bereich ist für Sie nicht verfügbar.                           |
| Ihre Berechtigung wurde geändert oder die Ressource ist nicht         |
| mehr verfügbar.                                                      |
| [Zum Dashboard] [Anderen Bereich wählen]                              |
|                                                                       |
| Variante: Seite nicht gefunden / Server nicht erreichbar              |
| [Zurück] [Erneut versuchen]                     Diagnosekennung: …     |
+-----------------------------------------------------------------------+
```

Komponenten: Card, Alert, Button. Nicht berechtigte Personen erhalten keine zusätzlichen Ressourcendetails. Abgelaufene Sitzung ist ein eigener Zustand mit „Erneut anmelden“ und sicherer Rückkehr zum bisherigen Ziel. Geheime Inhalte werden dabei sofort entfernt.

## 7. Zustände und Datenwahrheit

### Gemeinsames Zustandsmodell

| Zustand | Darstellung | Aktionen / Fokus |
|---|---|---|
| Initial laden | Strukturtreue Skeletons, „Daten werden geladen“ | Keine erfundenen Werte; Bereichswechsel bleibt möglich |
| Aktualisieren | Vorherige erlaubte Daten mit Zeitstempel und kleinem Fortschritt | Kein Springen der Tabelle, keine verlorene Auswahl |
| Erstmals leer | Kurze Erklärung mit fachlicher nächster Aktion | Aktion nur mit passendem Recht |
| Filter ohne Treffer | „Keine Einsendungen für diese Filter“ | „Filter zurücksetzen“, Filter bleiben sichtbar |
| Teilfehler | Fehlermeldung direkt an betroffener Karte oder Quelle | „Erneut laden“ nur für diese Quelle |
| Vollständiger Quellenfehler | Fehlerblock, Diagnosekennung, kein irreführendes Leerbild | Wiederholen und Navigation verfügbar |
| Gesperrt | Sichtbare erlaubte Metadaten, Inhaltsbereich mit Schloss und Erklärung | Entsperren; verschlüsselter Export bei Recht möglich |
| Schlüssel fehlt | „Für diese Version fehlt Ihnen ein Schlüssel“ | Zuständige Schlüsselverwaltung / Wiederherstellungsweg |
| Nicht berechtigt | Erklärter Aktionszustand oder Zugriffsseite | Keine Entsperr-Aufforderung für ein Rechteproblem |
| Offline | Persistentes Banner, Zeitstempel vorhandener Metadaten | Keine Servermutationen; kein automatisches späteres Absenden |
| Speichern | „Wird gespeichert …“, betroffene Aktion gesperrt | Andere Bereiche nutzbar, keine doppelte Ausführung |
| Speicherfehler | „Nicht gespeichert“, Eingaben bleiben im Speicher | Wiederholen oder Kopie sichern; Navigation warnt |
| Konflikt | Versionsvergleich mit eigenen und fremden Änderungen | Bewusste Auflösung, keine stille Überschreibung |
| Erfolg | Aktualisierte Daten, kurze kontextbezogene Bestätigung | Fokus auf sinnvoller Folgeaktion |

### Besondere Zustände je Funktionsgruppe

- **Auth:** Passkey nicht verfügbar, Abbruch, ungültiger zusätzlicher Faktor, Rate-Limit, TOTP-Zeitabweichung und abgelaufene Einladung sind unterscheidbar, soweit keine Konteninformation offengelegt wird.
- **Schlüssel:** gesperrt, entsperrt, teilweise entsperrt, Ableitung nicht unterstützt, privater Schlüssel fehlt, Wiederherstellung nötig, Daten beschädigt. Die UI behauptet bei einem funktionierenden Login nicht automatisch erfolgreichen Schlüsselzugriff.
- **Formular:** neuer Entwurf, unveröffentlichter Entwurf, unveränderte aktive Version, geänderter Entwurf, Prüfung mit Blockern, Veröffentlichung läuft, veröffentlicht, Empfang pausiert. „Veröffentlicht“ und „Empfang aktiv“ sind unabhängig.
- **Mail/Webhooks:** nicht konfiguriert, Test läuft, Test fehlgeschlagen, bereit, Zustellung ausstehend, Wiederholungsversuch geplant, endgültig fehlgeschlagen. „Kein Zustellprotokoll“ wird nicht als erfolgreiche Zustellung interpretiert.
- **Migration/Export/Rotation:** bereit, Prüfung läuft, wartet auf Entsperrung, teilweise erfolgreich, abgebrochen, abgeschlossen. Fortschritt nennt Anzahl und Einheit; Restzeit nur bei belastbarer Schätzung.

### Kennzahlen, Zeiträume und Vergleiche

- Besuche, Beginne und Absendungen stammen aus definierten Messereignissen; serverseitig angenommene Absendungen und SDK-Analyseereignisse sind unterschiedliche Quellen. Ohne aktivierte Besuchsmessung sind Besuche und daraus berechnete Konversion „—“.
- Besuche: gemessene Formular-Sitzungen. Beginne: Sitzungen mit erster relevanter Interaktion. Absendungen: angenommene Einsendungen, gesondert von Übertragungsversuchen. Doppelte Ereignisse werden anhand stabiler Kennungen abgeglichen.
- Konversion: Anteil gemessener Besuche mit erfolgreicher Absendung. Nur verknüpfbare und vergleichbare Messdaten gehen in diese Quote ein. Die absolute Serverzahl angenommener Einsendungen wird nicht durch einen unvollständigen Besuchsnenner geteilt.
- Abbrüche: begonnene gemessene Sitzungen ohne erfolgreiche Absendung nach Ablauf eines definierten Inaktivitätsfensters von 30 Minuten. Noch offene Sitzungen zählen nicht als Abbruch. Das Fenster steht in der Kennzahlenhilfe.
- Standardzeitraum: letzte sieben vollständige Kalendertage in der angezeigten Zeitzone. Vergleich: dieselben Wochentage der Vorwoche. Für „Heute“ wird nur der bis zur gleichen Uhrzeit vergangene Abschnitt verglichen. Ein manuell gewählter Zeitraum vergleicht standardmäßig die gleich lange Vorperiode; die Beschriftung nennt sie ausdrücklich.
- Ein bekannter Nullwert ist „0“, ein unbekannter Wert „—“. Bei Nenner 0 steht „Nicht berechenbar“. Bei Vorperiodenwert 0 und aktuellem Wert größer 0 steht „Neu“, keine unendliche Steigerung. Prozentquoten vergleichen in Prozentpunkten, Zählwerte relativ und mit absoluter Differenz.
- Gesamtaggregate werden aus Zählern und Nennern berechnet, niemals aus dem Mittel der Formularprozente. Bei fehlenden Quellen heißt es zum Beispiel „Unvollständig · 8 von 10 Formularen“, nicht scheinbar vollständiger Gesamtwert.
- Diagramme zeigen Datenlücken als Lücken. Tooltips, Zusammenfassung und Tabelle unterscheiden fehlende Werte von Null. Quellen-/Kampagnenauswertung nennt unbekannte Herkunft und blockierte Messung statt scheinbar präziser Zurechnungen.

## 8. Kernabläufe

### 8.1 Erste nutzbare Installation

1. Installationsnachweis prüfen und Voraussetzungen zeigen.
2. Erstes Konto mit Passkey anlegen; Zugang tatsächlich testen.
3. Schlüsselbund und Wiederherstellung einrichten; Wiederherstellung lokal prüfen.
4. SMTP/Domain/Dienste optional verbinden und einzeln testen.
5. Einrichtung abschließen; ersten Kunden und erstes Formular anlegen.
6. Felder, Ablauf und Empfangsschlüssel konfigurieren; Veröffentlichung prüfen.
7. Mit Passkey bestätigen, aktive Version herunterladen/einbetten und eine ausdrücklich markierte Testeinsendung prüfen. „Einrichtung vollständig“ erst nach belegtem Empfang; Entschlüsselung und Mailtest werden als eigene Prüfpunkte geführt.

### 8.2 Einladung bis zur ersten lesbaren Einsendung

1. Berechtigte Person wählt Kunde, E-Mail und minimale Rechte.
2. Einladung wird erstellt; Versand und Annahme haben eigene Statusanzeigen.
3. Eingeladene Person nimmt mit vorhandenem Konto an oder legt einen Passkey an.
4. Kundenrechte werden aktiv; Schlüsselzugriff bleibt gegebenenfalls ausstehend.
5. Schlüsselberechtigte Person prüft den Empfänger und gibt die nötigen Schlüssel sicher frei.
6. Empfänger entsperrt lokal und prüft die Lesbarkeit. Die UI meldet erst dann „Schlüsselzugriff bereit“.

### 8.3 Entsperren, sperren und wiederherstellen

1. „Entsperren“ benennt den angeforderten Bereich und dessen benötigte Schlüsselversionen.
2. Eine Passkey-Abfrage kann Anmeldung/Bestätigung und unterstützte lokale Schlüsselableitung verbinden; die UI zeigt getrennte Ergebnisse. Ein bloßer WebAuthn-Erfolg liefert nicht automatisch einen Inhaltsschlüssel.
3. Ist Ableitung nicht verfügbar, bietet die App nur tatsächlich eingerichtete lokale Alternativen an, insbesondere Wiederherstellungsmaterial. Ohne solche Mittel bleibt sie gesperrt.
4. Entschlüsselung läuft lokal; Teilerfolge zeigen den abgedeckten Umfang. Ein erneuter Bereichswechsel lädt keine weiteren privaten Schlüssel ohne passenden Zugriff.
5. Automatische Sperre nach standardmäßig 15 Minuten Inaktivität, bei Abmeldung und bei Rechteentzug. Nach längerem Hintergrundzustand erfolgt die Inaktivitätsprüfung vor erneutem Anzeigen. „Jetzt sperren“ wirkt sofort in allen Tabs derselben App, soweit sie erreichbar sind.
6. Sperren entfernt Schlüssel, Werte, lokale Inhaltsindizes, Vorschauen und Download-Objekt-URLs aus dem Arbeitsspeicher. Bereits bewusst gespeicherte Dateien und Zwischenablageinhalte lassen sich nicht verlässlich zurückholen; Download-/Kopieraktionen benennen daher ihre Vertraulichkeit an der passenden Stelle.
7. Wiederherstellung benötigt vorher angelegtes Material; ein Kontoreset oder Systemadministrator kann verlorene private Schlüssel nicht ersetzen.

### 8.4 Formular ändern und veröffentlichen

1. Editor öffnet einen Entwurf auf Basis einer aktiven Version.
2. Kleine Änderungen speichern nach kurzer Ruhephase automatisch auf dem Server; Feldvalidierung blockiert fehlerhafte Zustände. „Gespeichert“ erst nach Serverbestätigung.
3. Änderungen an Feldern, Regeln und Einstellungen sind in der Veröffentlichungszusammenfassung sichtbar.
4. Prüfung bewertet Schema, Regeln, Empfangsschlüssel, Domain und nötige Verbindungen; Blocker verlinken zum konkreten Feld.
5. Berechtigte Person prüft die exakte Revision und bestätigt mit Passkey. Server prüft Rechte und Revision erneut.
6. Bei Erfolg zeigt die App aktive Version, Zeit und Integrationsartefakte. Konflikte oder unklare Antworten führen zur Statusprüfung, nicht zu einem zweiten unkontrollierten Schreibvorgang.

### 8.5 Einsendungen bearbeiten und exportieren

1. Bereich und Zeitraum wählen, Status filtern; Metadaten sind ohne Entsperrung nutzbar.
2. Bei Bedarf den passenden Schlüssel entsperren und eine Detailansicht öffnen.
3. Bearbeitungsstatus setzen; Ergebnis wird pro Datensatz bestätigt.
4. Auswahl starten: „25 auf dieser Seite ausgewählt“. „Alle 420 gefilterten auswählen“ ist eine eigene Aktion.
5. Bei seitenübergreifenden Aktionen wird die Menge serverseitig für die Prüfung fixiert; neu eingegangene Einsendungen werden nicht unbemerkt eingeschlossen.
6. Exportformat und Umfang prüfen. Für Klartext fehlende Schlüssel entsperren; bei Teilfehlern explizit entscheiden.
7. Lokale Datei erstellen und Download anbieten. Kein automatischer Klartext-Zwischenspeicher und keine persistente Exporthistorie mit Dateiinhalten.

### 8.6 Löschen und Aufbewahrung

1. Auswahl und Löschrecht prüfen; betroffene Datensatz-/Dateimenge anzeigen.
2. Dialog benennt Kunde/Formular, Umfang, Unwiderruflichkeit und Backupgrenzen.
3. Massenlöschung sowie jede Löschung einer Einsendung erfordern eine frische Passkey-Bestätigung. Keine wirkungslose „Rückgängig“-Aktion nach endgültiger Löschung.
4. Während Ausführung nur betroffene Aktionen sperren; Ergebnis pro Datensatz berichten. Fehlgeschlagene Elemente bleiben ausgewählt und können erneut geprüft werden.
5. Automatische Aufbewahrung zeigt zuletzt und als Nächstes geplanten Lauf. Fehlgeschlagene Löschläufe werden als Betriebsproblem sichtbar.

### 8.7 Schlüsselrotation und Entzug

1. Aktuellen Schlüsselbestand, historische Daten und Empfänger prüfen.
2. Neuen Schlüssel lokal erzeugen und ausschließlich zulässige verschlüsselte Schlüsselhüllen übertragen.
3. Neue Empfangsschlüsselkonfiguration nach Passkey-Bestätigung atomar aktivieren; Zwischenzustände bleiben sichtbar.
4. Testeinsendung mit neuer Schlüsselversion empfangen und lokal prüfen.
5. Ältere Schlüssel nicht löschen, solange sie für gespeicherte Daten benötigt werden. Ein optionales Neuverschlüsseln alter Daten wäre ein eigener, lokal arbeitender Migrationsprozess.
6. Beim Entzug einer Person: Zugriffsrechte sofort widerrufen, Schlüsselhüllen nicht mehr ausliefern und Rotation für künftige Einsendungen anbieten. Bereits besessene Schlüssel werden nicht als rückwirkend entzogen dargestellt.

### 8.8 Sensible Aktionen bestätigen

Rechteänderung, Tokenverwaltung, Schlüsselverwaltung, Veröffentlichung, Löschung, sicherheitsrelevante Systemeinstellungen und Wiederherstellung beginnen jeweils mit einer konkreten Zusammenfassung. Danach folgt eine erneute Passkey-Abfrage. Die Bestätigung ist kurzlebig und an Aktion, Ziel sowie Revision gebunden; eine Anmeldung Stunden zuvor reicht nicht. Bei abgebrochener Abfrage bleibt die Aktion unausgeführt und der Bearbeitungsstand erhalten. Ein TOTP-Login ersetzt diesen Schritt nicht. Bei verlorenem Passkey führt die App zum vorab eingerichteten Zugangswiederherstellungsprozess statt eine schwächere Bestätigung anzubieten.

## 9. Konsistenzregeln und Barrierefreiheit

### Tabellen und Listen

- Tabellen besitzen Caption, eindeutige Spaltenköpfe, angekündigte Sortierrichtung und benannte Auswahlfelder, etwa „Einsendung E-1042 auswählen“. Die Hauptkennung ist ein echter Link, nicht eine nur per Mausklick nutzbare Zeile.
- Standard: Einsendungen neueste zuerst; Kunden und Formulare alphabetisch. Sortierung, Filter und Seitengröße stehen in der URL, soweit sie keine Inhaltswerte enthalten.
- Seitenweise Navigation mit 25/50/100 Zeilen, keine endlose Scrollliste für administrative Aufgaben. Eine serverseitig unbekannte Gesamtzahl wird nicht erfunden; dann nur „Weitere laden“/Vorherige mit bisheriger Anzahl.
- Spalten verwenden eine festgelegte Reihenfolge: Identität, Zuordnung, Zeit, fachlicher Status, technische Nebenmerkmale, Aktionen. Zahlen rechts, Text links. Datumsangaben sind vollständig zugänglich, relative Angaben nur ergänzend.
- Filteränderung entfernt eine bestehende Auswahl mit vorheriger Erklärung, falls sonst der Aktionsumfang unklar würde. Keine Auswahl wandert unbemerkt zwischen Kunden.
- Tabellenfehler erscheinen innerhalb des Listenbereichs. Eine leere Seite nach Löschung führt auf die vorherige verfügbare Seite.

### Formulare und Speicherung

- Jedes Feld hat ein dauerhaft sichtbares Label. Pflichtfelder tragen „Pflichtfeld“, optionale Felder bei Bedarf „optional“. Platzhalter enthalten ausschließlich Beispiele.
- Hilfetext und Fehlermeldung sind mit der Eingabe verknüpft. Nach Absenden eines fehlerhaften Formulars fokussiert die App eine Fehlerzusammenfassung mit Links zu den betroffenen Feldern. Prüfung beim Verlassen oder Absenden, nicht bei jedem ersten Tastendruck.
- Keine unbemerkte Änderung von Rechten, Veröffentlichung oder destruktiven Werten durch Auswahl eines Dropdown-Eintrags. Diese Vorgänge verwenden immer Prüfen/Bestätigen.
- Formularentwürfe speichern automatisch; Stammdaten und Verbindungen explizit über „Speichern“. Jede Seite zeigt die passende Speicherregel nahe dem Titel.
- Bei Navigation mit ungespeicherten Änderungen: „Auf dieser Seite gibt es ungespeicherte Änderungen“ mit „Weiter bearbeiten“ und „Verwerfen“. Bei laufendem Speichern wird zunächst dessen Ergebnis abgewartet. Es gibt keine Zusage, dass ein geschlossener Browser flüchtige Eingaben erhält.
- Geheimnisfelder bieten „Anzeigen“ mit verständlichem Zustand und „Kopieren“. Automatische Maskierung ersetzt keine sichere Speicherung. Passworteinfügen und Passwortmanager werden nicht blockiert.

### Hinweise und Rückmeldungen

- Inline-Hilfe für Erklärung, `Alert` für aktuelle Blockaden und Risiken, Toast für kurze nicht blockierende Bestätigungen. Kritische Fehler verschwinden nicht automatisch.
- Erfolg: „Version 5 wurde veröffentlicht.“ Fehler: „Die Verbindung zum Mailserver konnte nicht hergestellt werden. Prüfen Sie Host und Port.“ Technische Diagnose erscheint optional darunter.
- Datenfehler nennen Quelle, Datenstand und Umfang. Ein Fehler in der Statistik verdeckt weder Einsendungen noch Schlüsselstatus.
- Live-Meldungen sind sparsam: asynchrone Erfolge höflich, akute Blockaden gezielt. Wiederholte Pollingwerte werden nicht ständig vorgelesen.

### Dialoge und Buttons

- Ein Dialog hat Titel, kurze Auswirkung, Inhalt und Abschlussaktionen. Escape und Schließen erhalten Eingaben im zugrunde liegenden Editor, soweit sie dort schon existierten. Modale Dialoge führen den Fokus hinein und nach Schließen zum Auslöser zurück.
- Bei destruktiven Bestätigungen liegt der anfängliche Fokus auf „Abbrechen“ oder der Überschrift, nie automatisch auf „Endgültig löschen“. Umfangreiche Erklärungen sind vor dem Aktionsbereich erreichbar.
- Primärbuttons benennen das Ergebnis: „Kunden anlegen“, „Version 5 veröffentlichen“, „24 Einsendungen löschen“. „OK“ und „Ja“ sind keine Aktionslabels.
- Sekundärbuttons für Vorschau, Test und Export; Ghost-Buttons für weniger wichtige Navigation. Destruktiv rot erst am tatsächlichen Bestätigungsschritt.
- Icon-Buttons besitzen sichtbare Tooltip-Erklärung und zugänglichen Namen; wesentliche Aktionen haben Text. Ladebuttons behalten ihre Breite und erhalten „Wird gespeichert …“.
- Sicherheitsprüfungen werden nicht in Toasts untergebracht. Ein Dialog öffnet nicht ungefragt einen zweiten Dialog; Passkey-Systemdialog folgt auf eine bewusste Aktion.

### Tastatur und WCAG-2.2-AA-Abnahme

- „Zum Inhalt springen“ als erster Fokuspunkt. Landmarken für Navigation, Kopfbereich und Hauptinhalt; genau ein H1 je Seite. Nach Navigation Fokus auf Seitentitel, nach Dialogschluss zurück zum Auslöser.
- Logische DOM-/Tab-Reihenfolge, kein positiver Tabindex, kein Fokusverlust bei Filterung. Reiter unterstützen die übliche Pfeiltastenbedienung; echte Navigationslinks bleiben normal aktivierbar.
- Fokus ist sichtbar und wird durch sticky Header oder Aktionsleisten nicht verdeckt. Keine Tastaturfalle außerhalb bewusst modaler Overlays.
- Alle Kernaufgaben funktionieren ohne Ziehen, Hover, Farbe oder Diagrammablesen. Auswahl- und Statusinformationen sind programmatisch ermittelbar.
- Bedienelemente erhalten mindestens 24 × 24 CSS-Pixel Zielfläche, Standardaktionen 44 × 44 px. Reflow bei 320 CSS-Pixeln, Textvergrößerung auf 200 % sowie 400-%-Zoom werden geprüft. Datentabellen dürfen einen eigenen zweidimensionalen Scrollbereich behalten.
- Diagramme besitzen Textzusammenfassung, Muster/Marker und Datentabelle. Informationen aus Tooltips sind auch per Fokus oder Tabelle erreichbar.
- Authentifizierung unterstützt Passkeys, Einfügen und Passwortmanager; kein kognitives Rätsel als Pflicht. TOTP-Codes dürfen vollständig eingefügt werden. Unnötige wiederholte Dateneingaben werden vermieden.
- Vor Sitzungsablauf wird bei aktiver Arbeit gewarnt und eine Verlängerung angeboten, soweit die Sicherheitsrichtlinie dies zulässt. Ein Schlüssel-Lock erhält nicht geheime Entwürfe, entfernt aber Klartexte.
- Abnahme mit reiner Tastatur, Screenreader auf Desktop und Mobil, Hell/Dunkel, reduzierter Bewegung und hoher Vergrößerung. Automatisierte Prüfungen ergänzen die manuelle Prüfung.

### PWA, Offline und lokale Vertraulichkeit

- Die PWA ist installierbar, benötigt die Installation aber für keine Funktion. Updatehinweise nennen den notwendigen Neustart und warten laufende Arbeit ab.
- Offline werden nur statische App-Ressourcen dauerhaft bereitgestellt. Geschützte API-Antworten, entschlüsselte Werte, Geheimnisse und Wiederherstellungsmaterial werden nicht durch den Service Worker gecacht. Persistente persönliche Präferenzen sind unkritische Ausnahmen.
- Bereits im Speicher vorhandene Metadaten bleiben offline mit Datenstand sichtbar. Die App bietet offline keine neue Anmeldung, Entsperrung, Veröffentlichung oder Servermutation an. Ein Neuladen offline zeigt die Shell mit „Für Ihre Daten benötigen Sie eine Verbindung“.
- Es gibt keine versteckte Offline-Warteschlange für Änderungen, Tokenanlagen oder Löschungen. Ein im offenen Tab vorhandener Entwurf bleibt als „Nicht gespeichert“ erhalten und wird nach Rückkehr der Verbindung erst nach Versionsprüfung gespeichert.
- Sperr-/Abmeldeereignisse werden zwischen Tabs verteilt. Abgelaufene Sitzungen und geänderte Rechte werden bei Wiederaufnahme geprüft, bevor vertrauliche Daten erneut angezeigt werden. Lokale Inhaltsindizes sind flüchtig und an Ressource, Schlüssel und Sitzung gebunden.

## 10. Prioritäten und Umsetzung

Die Prioritäten bauen aufeinander auf; keine Stufe darf fehlende Sicherheitsgrundlagen durch vorübergehende Klartextverarbeitung umgehen.

| Priorität | Umfang | Abnahmekriterium |
|---|---|---|
| P0 – Grundlagen | Rollen-/Rechtemodell, Schlüsselzustände, Metadaten-/Inhaltsgrenze, Tokenrollen, Hell/Dunkel, barrierefreie Shell, Bereichswähler | Kontext und Schlüsselstatus sind in jeder Breite eindeutig; API-Rechte und Cachegrenzen sind festgelegt |
| P1 – Zugang und erste Inbetriebnahme | Installation, Passkey-Anmeldung, Enrollment, Konto, Schlüsselbund, getestete Wiederherstellung, Kundenanlage | Eine neue Installation erreicht ohne unsichere Abkürzung ein berechtigtes und entschlüsselungsfähiges Konto |
| P2 – Erstes produktives Formular | Formularliste, Übersicht, Felder, einfacher Ablauf, Schlüsselbereitstellung, Domainverbindung, Prüfung, Veröffentlichung und Integration | Ein Entwurf wird versionsgebunden veröffentlicht und eine reale Testeinsendung lokal gelesen; Konflikte sind lösbar |
| P3 – Tägliche Bearbeitung | Einsendungslisten/-details, Filter, Bearbeitungsstatus, Spamübersicht, Export, Massenaktionen, Löschung und Aufbewahrung | Gesperrt-, Leer-, Fehler- und Teilfehlerzustände sind vollständig; gemischte Schlüsselbestände und Exporte funktionieren |
| P4 – Zusammenarbeit und Verbindungen | Mitglieder/Rechte, zusätzliche Passkeys/Faktoren, Mail, Webhooks, API-Tokens, Dienste | Rechteentzug, Signatur-/Token-Geheimnisse und Zustellfehler sind nachvollziehbar; kein Einsendungsinhalt landet auf dem Server im Klartext |
| P5 – Einblick und Kontrolle | Dashboard, vollständige Statistik, Quellenanalyse, globale Suche und Befehlspalette | Jede Kennzahl besitzt Definition, Datenquelle und Tabelle; unvollständige Daten und lokale Suchgrenzen sind sichtbar |
| P6 – Betrieb und Übernahme | Ops-Unterseiten, Backups/Restore-Plan, Versions-/PWA-Updates, Migration, komplexe Abläufe, Schlüsselrotation | Wiederaufnahme und Teilfehler erzeugen keine unbemerkten Duplikate; Wiederherstellung und Rotation sind praktisch geprüft |
| P7 – Gesamtabnahme | Responsive Feinschliffe, Tastatur/Screenreader, Kontrast, Reflow, Lastfälle, Offline-/Mehrtab-Verhalten | Alle Kernabläufe funktionieren bei begrenztem Netz, mit ca. 1.500 Formularen und ohne Maus |

Barrierefreiheit, sichere Schlüsselverwendung und Zustandsdarstellung werden in jeder Stufe umgesetzt, nicht erst in P7. Die Abschlussstufe prüft das Zusammenspiel.

### Vor Implementierungsbeginn verbindlich spezifizieren

1. **Kryptografischer Vertrag:** unterstützte Passkey-Ableitung, Schlüsselhüllen, Gerätewechsel, Empfängerfreigabe, Recoveryformat und Testvektoren. Alle UI-Versprechen zur Lesbarkeit hängen an nachgewiesenen Verfahren.
2. **Rechtevertrag:** Kundenrechte, zusätzliche Mitgliederverwaltung, Löschrecht als Teil von Bearbeiten, Systemrechte und API-Scopes; serverseitige Durchsetzung einschließlich Rechteentzug in offenen Sitzungen.
3. **Messvertrag:** Ereignisdefinitionen, Deduplizierung, Zuordnung von Konversionen, Umgang mit blockierter Messung, Zeitzone und Inaktivitätsfenster.
4. **Versionsvertrag:** Entwurfsrevision, Konfigurationsumfang, atomare Veröffentlichung, unmittelbare Betriebsaktionen und Kompatibilität von SDK, Server und Schema.
5. **Betriebsvertrag:** unterstützte Importformate, Dateigrößen, serverseitige Grenzen, Backupfristen und real ausführbarer Wiederherstellungsweg je Installation.

Diese Spezifikationen präzisieren die Umsetzung. Das UI bleibt in allen Fällen bei seinen festen Regeln: keine erfundenen Daten, keine vorgetäuschte Entschlüsselung, keine unbeabsichtigte Veröffentlichung und keine stillschweigende Ausweitung von Rechten oder Aktionsumfang.
