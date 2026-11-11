# UI/UX-Konzept der Formular-Backend-PWA

Stand: 03.11.2026 · Paket P12-Konzept · Zielbild für Sonnet/sol · AGPL-3.0-only.

**Auftrag:** ausschließlich dieses Dokument; kein Anwendungscode, kein Commit. Dateibesitz: ein Codex, `docs/ux/konzept.md`. Worktree `form-backend-ux`, Branch `ux-concept`. Die folgenden Oberflächen sind Umsetzungsvorgaben im Konzept, kein Nachweis bereits vorhandener Funktionen. Neue Sicherheits-/API-Verträge sind vor abhängiger Implementierung separat zu entscheiden; dieses Dokument trifft keine neue Kryptoarchitekturentscheidung.

## 1. Zielgruppen und Hauptaufgaben

| Zielgruppe      | Alltag                                                                                                                   | Standard-Einstieg                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------- |
| Betreiber/Admin | Erstinstallation, Kunden/Zugänge, Mail, Domains, Speicher, Umstieg und Betriebsfehler betreuen                           | Kundenüberblick; offene Einrichtungsschritte zuerst              |
| Betreuer        | Zugewiesene Formulare konfigurieren, testen/veröffentlichen, Einsendungen bearbeiten, Zustellungen und Conversion prüfen | Formulare des zuletzt gewählten zugänglichen Kunden              |
| Kunde           | Eigene Einsendungen lesen/exportieren, Löschschutz setzen, Statistik ansehen; Konfiguration nur mit Recht                | Eigene Formulare; bei nur einem Formular direkt dessen Überblick |

Admin, Betreuer und Kunde sind **Rechtevorlagen**, keine fest verdrahteten Rollenprüfungen. Ein Systemadministrator erhält dadurch keinen automatischen Inhaltszugriff. Die UI verwendet die effektiven Rechte aus demselben Vertrag wie REST/MCP. Fehlende Rechte blenden Navigation/Aktionen aus; vorübergehend fehlende Voraussetzungen deaktivieren Aktionen mit sichtbarer Begründung. Direktaufrufe bleiben serverseitig geschützt.

Erfolgsmaß: Passkey-Anmeldung → Kunde/Formular → Einsendung öffnen ohne Schlüsselbegriffe, Kopieren privater Werte oder zweiten manuellen Entsperrschritt im Normalfall.

## 2. Stil, Informationsarchitektur und Navigation

### Stilreferenz timetrack-pwa

Nur lesend herangezogen: `src/routes/layout.css`, `src/routes/(app)/+layout.svelte`, `src/lib/components/shell/{SidebarNav,TopBar,SettingsShell}.svelte`, `docs/handoffs/UI-FIXES.md`, `docs/handoffs/OAUTH-CONSENT.md`. Referenzwurzel: `<workspace>/timetrack-pwa`. Dessen Backend-Dokument `docs/DESIGN.md` wird im CSS erwähnt, liegt aber nicht in dieser Referenzlektüre vor.

Übernehmen: Inter, neutrale Zinc-Flächen in OKLCH, heller/dunkler/System-Modus, blauer Standardakzent mit wählbaren kontrastgeprüften Akzenten, 10-px-Basisradius, feine vollständige Rahmen, sparsame Schatten, Lucide-Symbole. Sidebar 256 px; Kopfzeile 60 px; Inhalt maximal 1240 px, Einstellungsformulare 820 px. Seiteneinzüge 16/24/40 px, Abstände 8/16/24 px. Navigation am Desktop 36 px hoch, Eingaben mindestens 40 px, Tabellenzeilen etwa 44 px. Akzent für aktive Navigation und Hauptaktion; Rot ausschließlich für Fehler/destruktive Aktionen. Optionale Glaswirkung nur mit gesichertem Kontrast; dekoratives Leuchten ist nachrangig.

Keine großen dekorativen Dashboard-Kacheln: eine Titelzeile, kurze Beschreibung, eine primäre Aktion, Filter, kompakte Datenfläche. Sidebar/TopBar bleiben beim Seitenwechsel stehen. Ladeflächen reservieren die spätere Höhe. Wie im Referenz-Fix: Einstellungsnavigation am breiten Desktop bei 96 px anheften (60 px Kopf + 36 px Seitenabstand), nicht beim Scrollreset versetzen.

### Zielnavigation

```text
Formular-Backend                       TopBar: Kunde > Formular > Seite
[Kunde wählen v]                                [Darstellung] [Konto v]
[Navigation durchsuchen]
ARBEIT
  Überblick
  Formulare
  Einsendungen
  Statistik
VERWALTUNG DES KUNDEN
  Mitglieder und Rechte
  Domains
BETRIEB                                nur passende Systemrechte
  Kunden
  Verbindungen                         Mail / Speicher
  Systemeinstellungen
  Umstieg                              nur solange aktiviert
---------------------------------
  Mein Konto                           Passkeys / MCP & API / Erweitert
  Hilfe
  Online / Offline
```

Kundenwahl als durchsuchbare Combobox, bei einem Kunden statische Beschriftung. Keine globale Auswahl „Alle Kunden“ für Inhaltsaktionen. Wechsel erhält möglichst den Seitenbereich, verwirft aber niemals ungespeicherte Änderungen ohne Nachfrage; Formularfilter, Auswahl und entschlüsselte Inhalte werden geleert. URL enthält Kunde und gegebenenfalls Formular, damit Links eindeutig sind. Globale Betriebsseiten tragen „Systemweit“ statt eines scheinbar wirksamen Kundenfilters. Suche umfasst nur sichtbare Navigationsziele, keine entschlüsselten Inhalte.

Formularkontext: **Überblick · Einsendungen · Konfiguration · Einbindung · Statistik**. Konfiguration enthält **Felder & Ansicht · Mail · Webhooks · Aufbewahrung & Speicher · Ablauf (später)**. „Prüfen & veröffentlichen“ ist eine hervorgehobene Aktion mit eigener Prüfseite. Entwurfsstand und veröffentlichte Version bleiben getrennt sichtbar. Keine Navigation „Schlüssel & SDK“ mehr; SDK gehört unter Einbindung, Recovery und technische Sicherheitsdetails unter Mein Konto > Erweitert.

Bestehende Links `/t`, `/t/:tenant`, Formular-Unterseiten, `/account`, `/api-tokens`, `/connections`, `/settings` erhalten oder auf das eindeutige neue Ziel weiterführen. Neue kundenweite Einsendungs-/Statistikansichten benötigen Aggregationsverträge; bis dahin verlangen sie die Formularwahl und verwenden vorhandene formularbezogene APIs. Keine clientseitige Vollabfrage sämtlicher Kundenformulare vortäuschen.

## 3. Seiten und ASCII-Wireframes

**Für alle Seiten:** L = Laden: Skeleton in gleicher Geometrie, `aria-busy`, vorhandene Navigation bleibt nutzbar. E = Fehler: Inline-Alert „Die Daten konnten nicht geladen werden.“ + „Erneut versuchen“; keine falsche Leeranzeige. 401 führt nach Anmeldung zum Ausgangsziel; 403 zeigt „Dafür fehlt Ihnen die Berechtigung.“; 404 „Diese Seite ist nicht verfügbar.“ ohne fremde Objektdetails. Schreibfehler erhalten Eingaben im Arbeitsspeicher; keine automatische Wiederholung destruktiver Aktionen. Die folgenden Zustände ergänzen diesen gemeinsamen Vertrag.

### 3.1 Anmeldung

```text
           Formular-Backend
           Anmelden
           [Mit Passkey anmelden]
           [Andere Anmeldemöglichkeit]
           Probleme beim Zugang? [Hilfe]
```

L: „Anmeldung wird geprüft …“, anschließend bei Bedarf „Ihr Datenzugang wird vorbereitet …“. Leer: nicht anwendbar. E: Abbruch und nicht unterstütztes Gerät unterscheiden (Abschnitt 4). Das derzeit vorhandene Passwort als zweiten Anmeldeschritt weiter anbieten, solange der Auth-Vertrag es verlangt; der Wunsch nach automatischem Datenzugang hebt ihn nicht stillschweigend auf. Bestehende TOTP-/Passwortpfade nicht aus der Parität entfernen. Bei notwendiger erneuter Authentifizierung Kontext und Entwurf erhalten, keine Außenwirkung automatisch auslösen.

### 3.2 Kundenüberblick und Kundenverwaltung

```text
Kunden                                  [+ Kunde anlegen]
[Name suchen]                           [Alle zugänglichen v]
Name           Formulare    Einrichtung             Aktion
Beispiel       3            Bereit                   [Öffnen]
Neuer Kunde    0            Datenzugang wird eingerichtet
```

Kundenanlage: Name → automatische Vorbereitung → „Formular anlegen“. Kein separates Schlüsselpanel. Leer: „Noch keine Kunden vorhanden.“ mit Anlageaktion nur bei Recht; ohne Zugang „Für Ihr Konto ist noch kein Kunde freigegeben.“ L: Zeilen plus laufender Einrichtungsstatus. E: Kunde bleibt als „Einrichtung unvollständig“ wiederaufnehmbar, kein zweites Anlegen beim Retry.

### 3.3 Kundenüberblick / Formulare — erste Fachseite der Optik

```text
Beispiel / Formulare                     [+ Formular anlegen]
[Suche] [Status v]                        [Einrichtung fortsetzen]
Name          Veröffentlichung   Entwurf       Handlungsbedarf
Kontakt       Version 3          Änderungen    2 offene Zustellungen
Anfrage       Keine              In Arbeit     Test fehlt
[Überblick öffnen]                       [Weitere laden]
```

Überblick zeigt nur verfügbare Summen und Aufgaben mit Deep Links; keine erfundenen Live-Kennzahlen. Leer: „Dieser Kunde hat noch kein Formular.“ / „Formular anlegen“. Filterleer: „Keine passenden Formulare.“ / „Filter zurücksetzen“. L: Tabelle. E: Liste fehlgeschlagen getrennt von Anlagefehler. Neues Formular als kompakter Guide: Name/Vorlage → Felder/Ansicht → Verarbeitung/Mail → Speicherprofil → Einbindung → Test → Veröffentlichung. Noch fehlende Funktionen als Abhängigkeit anzeigen, nicht als funktionierende Auswahl.

### 3.4 Formularüberblick

```text
Kontakt                       [Entwurf bearbeiten] [Prüfen & veröffentlichen]
Aktiv · Version 3              Entwurf: Stand 8, gespeichert
[Überblick] [Einsendungen] [Konfiguration] [Einbindung] [Statistik]
Einrichtung: Datenzugang OK | Mail OK | Einbindung prüfen
Letzte Aktivität               Offene Aufgaben
3 angenommene Einsendungen     [2 Zustellungen prüfen]
```

Leer: „Noch nicht veröffentlicht. Dieses Formular nimmt noch keine Einsendungen an.“ L: Statistik und Formularstatus unabhängig laden. E: Statistikfehler lässt Konfiguration erreichbar. „Inaktiv“ und „Noch nicht veröffentlicht“ unterscheiden; fehlende Statistik nicht als null verkaufen. Kunden mit Leserecht sehen Version und Status, keine Bearbeitungsaktionen.

### 3.5 Felder & Ansicht

```text
Konfiguration / Felder & Ansicht       Entwurf · Stand 8
Felder                          Eigenschaften              [Vorschau]
Name          Text              Beschriftung [Name       ]
E-Mail        E-Mail-Adresse    [x] Pflichtfeld
[+ Feld] [Nach oben/unten]       Sichtbarkeit [Sichtbar v]
                                [Speichern]
```

Leer: „Fügen Sie das erste Feld hinzu.“ L: Feldliste und Editorgerüst. E: Feldfehler direkt am Feld; Versionskonflikt „Der Entwurf wurde geändert. Laden Sie den aktuellen Stand und prüfen Sie Ihre Änderungen.“ Keine stille Überschreibung. Ausgeblendet, schreibgeschützt, deaktiviert und serverseitig festgelegt getrennt erklären. Feldkennung unter „Erweitert“ zugänglich, stabile Kennungen nicht beim Umbenennen ändern. Vorschau nur als solche kennzeichnen; Ansichts-/Regelbearbeitung und Sortierung sind Erweiterungen gegenüber `FieldsTab.svelte`, keine bereits vorhandenen Zusagen.

### 3.6 Mail

```text
Konfiguration / Mail                           [Speichern]
Versandweg [Zugewiesene Verbindung v]
[Mail an Team] [Bestätigung]
Absender [...]  Empfänger [...]  Betreff [...]
Inhalt   [Vorlage mit Feld-Einfügehilfe               ]
Zustellungen: Ausstehend | Angenommen | Aktion erforderlich
```

Leer: „Noch kein Versandweg zugewiesen.“ mit Verweis an berechtigte Administration. L: Konfiguration und Zustellliste separat. E: Verbindungsfehler mit „Verbindung prüfen“, Vorlagenfehler am Feld. „Vom Mailserver angenommen“ bedeutet nicht „zugestellt“. Wiederholung aus Einsendungsdetail; ungewisser Versand fordert explizite Bestätigung, weil eine doppelte Mail möglich ist. Vorlagenänderungen gelten erst nach Veröffentlichung; Betriebszuordnung des Versandwegs gesondert kennzeichnen.

### 3.7 Prüfen & veröffentlichen

```text
Kontakt / Veröffentlichung
Version 3 -> neue Version     Entwurf: Stand 8
[OK] Felder   [OK] Mail   [!] Einbindung prüfen
Änderungen: 1 Pflichtfeld hinzugefügt
[ ] Ich habe die Änderungen geprüft.
[Zurück zum Entwurf]                      [Jetzt veröffentlichen]
```

Leer: „Es gibt noch keinen Entwurf.“ / „Entwurf anlegen“. L: „Entwurf wird geprüft …“. E: konkrete Blockaden verlinken; Konflikt verlangt neue Prüfung. Vorhandene Revisions-/Bestätigungs-/Idempotenzbindung beibehalten. Wiederholter Klick nach Antwortverlust darf keine doppelte Veröffentlichung erzeugen. Hinweis: „Bestehende Domainzuordnungen bleiben bei ihrer gewählten Version.“ Versionsvergleich/-vorschlag erst nach passendem Vertrag, keine bloß kosmetische Ersetzung der bisherigen Versionslogik.

### 3.8 Einsendungen, Detail und Export

```text
Einsendungen / Kontakt                    [Exportieren]
[Zeitraum] [Status v] [Löschschutz v]       3 ausgewählt
[ ] Eingang          Versand             Schutz       [...]
[x] 03.11. 10:24      Angenommen           Geschützt    [Öffnen]
[Auswahl: Löschschutz setzen | aufheben | löschen]
--------------------------------------- Detail / rechts
Felder | Anhänge | Versand
Name: ...                  [Datei herunterladen]
[Löschschutz setzen] [Erneut senden] [...] [Schließen]
```

Leer: „Noch keine Einsendungen.“; Filterleer gesondert. L: Metadaten zuerst, „Einsendung wird geöffnet …“ nur im Detail. E: Datei-/Inhaltsfehler lokal; Liste bleibt verfügbar. Suche zunächst nach verfügbaren Metadaten, keine serverseitige Klartextsuche versprechen. Listenstandard enthält keine entschlüsselten Inhaltsvorschauen.

„Löschschutz“ ersetzt „Hold“ in Nutzertexten. Setzen umfasst Inhalte, Anhänge und Mailobjekte atomar; Status erst nach Bestätigung wechseln. Aufheben erklärt: „Die Aufbewahrungsfrist ist bereits abgelaufen. Nach dem Aufheben kann diese Einsendung automatisch gelöscht werden.“ Löschen: „{n} Einsendungen einschließlich Anhängen und Mail-Aufträgen endgültig löschen?“ / „Abbrechen“ / „Endgültig löschen“. Geschützte Einträge nicht automatisch entsperren; Ergebnis trennt gelöscht, geschützt, fehlgeschlagen, noch in Löschung. Bei externem Speicher: „Löschung läuft. Die Bestätigung steht noch aus.“ statt Erfolg bei HTTP 202.

Exportdialog: Bereich ausdrücklich „Alle Einsendungen dieses Formulars“ (Bestands-API), später Auswahl/Filter erst mit Vertrag; Format „Verschlüsselte Daten“ oder „Lesbare Daten“. Lesbar verlangt Datenzugang und Hinweis „Diese Datei enthält lesbare personenbezogene Daten.“ Fortschritt/Abbrechen, keine Teildatei als vollständig ausgeben. Der aktuelle Export enthält Datenpakete und Anhanganzahl; Anhänge separat herunterladen. Kein vollständiges ZIP versprechen. Aufbewahrung steht in Konfiguration: 1–3650 Tage oder „Automatische Löschung aus“; Änderung betrifft auch den Bestand.

### 3.9 Statistik

```text
Statistik / Kontakt           [Letzte 30 Tage v]  Produktion · UTC
Besuche 100 | Beginn 60 | Absenden 25 | Abbruch 20 | Conversion 25 %
[Zeitreihe: Besuche / Beginn / Absenden / Abbruch]
[Datentabelle anzeigen]                 Stand: ...
Conversion = Absenden / Besuche
```

Leer: „Keine erfassten Ereignisse im Zeitraum.“; ohne Besuche Conversion „—“. L: Kennzahl-Skeletons, niemals vorab 0 %. E: Chartfehler mit Tabelle/Retry, soweit Daten vorhanden. Berechnung aus Gesamtsummen, nicht Mittelwert der Tagesquoten. UTC und Produktionsumfang immer sichtbar; Werte über 100 % nicht abschneiden. Besuche/Ereignisse sind keine Personenzählung, Abbrüche nicht einfach Besuche minus Absenden.

ADR 0015 ist maßgeblich: ab 03.11.2026 nur instrumentierte Ereignisse; angenommene Einsendungen ohne Statistik-Kontext werden nicht ersatzweise gezählt. Vorheriger Einsendungszählpfad hat keine vollständigen Besuche. Importierte Altstatistik einschließlich Google-Ads/GCLID-Kontext getrennt halten; keine gemischte Conversion. Hinweis bei fehlender Instrumentierung: „Für dieses Formular werden noch keine Besuchsereignisse erfasst.“ Erweiterte Altstatistik-/Ads-Ansicht benötigt eigenen Vertrag. Statistiklöschung separat von Inhaltslöschung, mit Recht und Bestätigung.

### 3.10 Einbindung und Domains

```text
Einbindung / Kontakt
[PHP-SDK] [Domainzuordnung]
Anbindung: Bereit       [Einrichtungsdatei herunterladen]
API: Hauptadresse ...  Backup ...      [Testeinsendung prüfen]
Domains                                  [+ Domain zuordnen]
Host              Ansicht    Version   Modus     Aktiv
formular.example  Standard   3         Test      Nein  [Bearbeiten]
```

Leer: „Noch keine Einbindung eingerichtet.“ L: Status, keine vorzeitige Bereitanzeige. E: fehlende Veröffentlichung/Datenvorbereitung als konkrete Aufgabe. SDK-Datei nur einmal nach bewusster Ausstellung anzeigen/herunterladen; keine automatischen Downloads. Bestehender Pairing-/Deploypfad bleibt erhalten, falls verfügbar; Zugangsdaten nicht als normale Schlüsselverwaltung präsentieren.

Domainseite der Sidebar verwendet dieselbe Tabelle kundenweit; Ansichtshost und API-/Backuphost klar trennen. Neue Bindungen immer inaktiv im Testmodus. Aktivierungsdialog nennt Host, Kunde, Formular, Ansicht, feste Version und Modus vollständig. Veröffentlichung verändert Bindungen nicht automatisch. Vor Entfernen deaktivieren. Konflikt lädt aktuellen Stand zur erneuten Bestätigung. DNS/Proxy/TLS werden extern eingerichtet: Anleitung und Prüfstatus, kein „Zertifikat automatisch eingerichtet“. Hostprüfung ersetzt keinen Besitznachweis. API-/Backuphosts müssen zur freigegebenen Formularversion passen.

### 3.11 Webhooks

```text
Konfiguration / Webhooks                       [+ Ziel hinzufügen]
Ziel                      Aktiv     Status
https://.../eingang        Nein      Noch keine Zustellung [Details]
Details: Signaturprüfung [Öffentliche Prüfinformation kopieren]
[Aktivieren/Deaktivieren]                         [Entfernen]
```

Leer: „Noch keine Webhooks eingerichtet.“ L: Liste. E: „Das Ziel konnte nicht gespeichert werden.“ mit erlaubter konkreter Feldursache. Anlage zunächst inaktiv anbieten (API unterstützt explizites `active=false`), Aktivierung bewusst. Empfänger braucht die öffentliche Prüfinformation, keinen privaten Signierschlüssel. Die einmalige private API-Antwort nicht im Standardfluss darstellen. URL-Wechsel als neues Ziel; Entfernung benennt auch ausstehende Zustellungen. Rechte derzeit `key.manage` am Kunden, nicht aus der UI-Bezeichnung ableiten. Zustellhistorie nur mit verfügbarer Lese-API; Test-/Retry-Buttons erst mit eigenem Vertrag, keine erfundenen Außenwirkungen.

### 3.12 Mitglieder und Rechte

```text
Mitglieder und Rechte                     [+ Person hinzufügen]
Name       Rechtevorlage    Datenzugang          [Bearbeiten]
Person A   Betreuer         Bereit
Person B   Kunde            Einrichtung ausstehend
Details: [Lesen] [Bearbeiten] [Veröffentlichen] [Datenschutz ...]
Geerbt: ...                               [Rechte speichern]
```

Leer: „Noch keine weiteren Personen zugeordnet.“ L: Rechte und Zugangsstatus getrennt. E: „Die Rechte wurden nicht geändert.“; bei erfolgreicher Rechtevergabe und ausstehendem Datenzugang genau das anzeigen. Effektive, direkte und geerbte Rechte unterscheidbar. Nur selbst vergebbare Rechte auswählbar; bestehender Schutz eigener Rechte/letzter handlungsfähiger Identität bleibt. Kontenanlage aus `Account.svelte` hier bzw. in berechtigte Kontenverwaltung verschieben. Einladung/Einrichtungslink einmalig, sicher weiterzugeben. Automatische Zugangsvergabe siehe Abschnitt 4.

### 3.13 Verbindungen und Speicher

```text
Verbindungen                           [+ Verbindung anlegen]
[Mail] [Speicher]
Name        Typ      Kunden      Prüfung       [Prüfen] [Zuweisen]
Archiv      S3       Beispiel    Erfolgreich
-------------------------------------- Kunden-/Formularrichtlinie
Speicher [Vom Kunden übernehmen v]     Effektiv: Datenbank
[ ] Formulardaten extern   Anhänge größer als [ ... MiB ]
[Speichern]
```

Leer: „Es sind noch keine externen Verbindungen eingerichtet. Daten werden in der Datenbank gespeichert.“ L: Liste/Richtlinie unabhängig. E: Verbindungsfehler, ausstehender Upload und ausstehende Löschung getrennt. Probe: „Verbindung geprüft. Testdaten entfernt.“ oder „Verbindung geprüft. Testdaten konnten noch nicht entfernt werden.“ Bei Speicherfehler kein automatischer DB-Fallback behaupten.

MariaDB Standard, S3/SFTP optional; Geheimnisse als „Hinterlegt“ mit Ersetzen, nie zurückanzeigen. SFTP-Serverprüfung mit ausdrücklich bestätigter Vertrauensprüfung; S3 verlangt unversionierten Bucket. Formular kann Kundenrichtlinie vollständig ersetzen, explizite DB-Auswahl beendet Vererbung. „Diese Einstellung gilt für neue Einsendungen. Bestehende Daten bleiben an ihrem Speicherort.“ Verwaltung gemäß Systemrechten; lesbare Zusammenfassung für Betreuer nur soweit autorisiert. Gesamtbelegung/Quoten nur anzeigen, wenn Inventar/API sie liefern.

### 3.14 Systemeinstellungen und Listener

```text
Systemeinstellungen                         [Änderungen speichern]
[Suche]              Kategorie: Mail | Limits | Hosts | Betrieb
Einstellung          Effektiver Wert     Quelle          Wirkung
MCP-Anfragen/Minute  [60        ]         Datenbank       Sofort
Mail-Netzfreigabe    [gesperrt  ]         Umgebung (ENV)  Neustart
Dashboard intern    Port 8081            Umgebung (ENV)  Neustart
Öffentlicher Eingang Port 8080           Umgebung (ENV)  Neustart
Dashboard öffentlich: Aus                Umgebung (ENV)
```

Vorrang **Umgebung (ENV) > Datenbank > Standard**. Auch leere gesetzte ENV sperrt. Feldhilfe: „Vom Server vorgegeben: {envName}. Diese Einstellung kann hier nicht geändert werden.“ Bootstrapwerte schreibgeschützt; fehlende Registrygruppen nicht mit fiktiven Feldern füllen. Quelle direkt am Feld, nicht nur Tooltip. Geheimnisse nie als effektiven Wert ausgeben.

Leer: „Keine Einstellungen in dieser Kategorie.“ L: Formular-Skeleton; E: Revisionskonflikt erhält lokale Eingaben zur Prüfung, kein stilles Überschreiben. Neustartpflicht: „Gespeichert. Die Änderung wird nach einem Serverneustart wirksam.“ Kein Neustartbutton ohne Betriebsvertrag.

Zwei Listener: intern PWA/Admin-API; öffentlich SDK-Eingang, Statistik und MCP/OAuth-Protokollendpunkte. Öffentliches Dashboard standardmäßig aus; Aktivierung nur über Betriebsumgebung samt erlaubten Hosts. Ports, DB-Zugang, Serverschlüssel und vertrauenswürdige Proxys sind Bootstrap, kein editierbarer Assistententrick. Öffentliches Dashboard erweitert nicht automatisch die Passkey-Origin/RP-ID. Erreichbarkeit der internen Autorisierungsseite bei MCP erklären, keine Empfehlung zum pauschalen Öffnen.

### 3.15 Mein Konto, MCP-Tokens und Erweitert

```text
Mein Konto
[Passkeys] [MCP & API] [Erweitert]
Passkeys: Laptop · Datenzugang bereit       [Weiteren Passkey hinzufügen]
MCP & API: [Tokens] [Verbundene Anwendungen]
Name       Kunde / Formular      Rechte     Ablauf     [Widerrufen]
[Token erstellen]
Erweitert > Wiederherstellung / Gerätezugang / Sicherheitsaktualisierung
```

Leer: Tokens „Noch keine Tokens erstellt.“; letzter Passkey ist kein normaler löschbarer Leerzustand. L: Metadaten. E: API-Fehler inline; Eigenwiderruf auch nach Rechteentzug erreichbar lassen. Tokenanlage: Bezeichnung, Kunden-/Formularauswahl nach Namen statt UUID-Freitext, bewusst gewählte Rechte, Ablauf 1–90 Tage, maximal fünf aktive Tokens. „Dieses Token wird nur jetzt angezeigt. Speichern Sie es sicher.“ / „Kopieren“ / „Ausblenden“. Keine automatische Zwischenablage.

Aktuelle Scopes nur Konfiguration lesen und Entwürfe schreiben; keine Einsendungen entschlüsseln oder veröffentlichen. Anfragelimit als effektiven Systemwert erklären; ein individueller Token-Limitregler ist erst nach erweitertem Vertrag möglich (aktuelles P11-B-Limit gilt je Token, ist aber systemweit konfiguriert). OAuth-Anwendungen mit Widerruf sind P11-E-Ziel, keine aus Tokenmetadaten erfundene Liste. Erweitert enthält Wiederherstellung, Sicherheitsstatus und gezielte Reparatur; keine täglichen Recovery-Prompts.

### 3.16 OAuth-Zustimmung

```text
Anwendung verbinden
Anwendung: ...              Registrierung: nicht verifiziert
Angemeldet als: ...         Kunde / Formular: ...
Angefragter Zugriff:
[ ] Konfiguration lesen
[ ] Entwürfe schreiben      Kann gespeicherte Entwürfe ändern
Weiterleitung: https://.../callback
[Ablehnen]                                  [Zugriff erlauben]
```

Eigenständige ruhige Seite mit Konto/Kontext, keine ablenkende Sidebar. Nur serverseitig validierte Anfrage anzeigen. Rechte nie still erweitern; Schreiben nicht vorauswählen. Reduzierbare Auswahl nur, wenn P11-E sie vertraglich unterstützt, sonst vollständiges angefragtes Bündel erlauben/ablehnen. Ohne Scopes keine Rechte erfinden. Clientname/Logo sind keine Vertrauensbestätigung; Zieladresse sichtbar, kein Geheimnis/Token in der Seite.

Leer/E: „Diese Anfrage ist abgelaufen oder ungültig. Starten Sie die Verbindung in der Anwendung erneut.“ L: „Zugriffsanfrage wird geprüft …“. Nach Ablehnen keine Freigabe, nach Allow nur bestätigten Antrag abschließen. OAuth-Metadaten, Registrierung und Token-Endpunkt öffentlich; Login/Consent intern, sofern Dashboard nicht bewusst öffentlich betrieben wird. Hilfe: „Öffnen Sie die interne Verwaltungsadresse über Ihr freigegebenes Netz oder VPN.“ Ein unerreichbarer interner Host lässt sich nicht durch eine dort gerenderte Fehlerseite lösen; Erklärung auch in der MCP-Einrichtung bereitstellen.

### 3.17 Setup und Umstiegsfortschritt

```text
Einrichtung                    Schritt 2 von 6
1 Konto  >  2 Wiederherstellung  >  3 Mail  >  4 Adressen  >  5 Umstieg  >  6 Prüfen
[Schrittinhalt / Feldfehler / Hilfe]
[Zurück]                                         [Weiter]

Umstieg / Lauf ...                        Letzte Aktualisierung ...
Quelle geprüft -> Zuordnung -> Import -> Prüfung -> Umschaltung
Formulare 8/8 | Einsendungen 640/800 | Prüffälle 3
[Probleme ansehen] [Bericht herunterladen] [Sicher pausieren]
```

Leer: Erststart „Richten Sie Ihr Formular-Backend ein.“; später „Kein Umstieg gestartet.“ L: benannte Phase, bei unbekanntem Umfang unbestimmter Fortschritt statt erfundener Prozentzahl. E: Phase und nächster Schritt, keine SQL-/Klartextlogs. „Fortsetzen“ verwendet denselben Lauf; kein impliziter Neuimport. Pause nur an bestätigten sicheren Grenzen, kein behauptetes Rollback fertiger Importobjekte. Details in Abschnitt 5.

### 3.18 Ablauf, Hilfe und Betriebsereignisse

```text
Konfiguration / Ablauf
Aktuelle Verarbeitung: [Beschreibung der vorhandenen Zuordnung]
Der visuelle Ablauf-Editor folgt später.
[Dokumentation öffnen]

Hilfe                         [Thema suchen]
Anmeldung | Formulare | Einbindung | Datenschutz | Betrieb
Betriebsereignisse: Zeit | Bereich | Ergebnis | [Details]
```

Ablauf ist ausschließlich lesbarer Platzhalter; kein Canvas, Drag-and-drop oder funktionsloser Speichernbutton. Vorhandene Ablaufzuordnung darf dadurch nicht überschrieben werden. Leer: „Kein eigener Ablauf zugeordnet.“ nur nach Datenprüfung. L/E für Zuordnung lokal. Hilfe als Dialog/Seite mit kontextbezogenem Einstieg; bei leerer Suche „Kein passendes Hilfethema“. Audit-/Fehlerereignisse später als rechtegeschützte Ansicht ohne Nutzdaten/Secrets; L: Zeilen, leer: „Keine Ereignisse im Zeitraum“, E: Retry. Bestehende Debug-/Benachrichtigungsfunktionen bleiben Paritätsaufgaben, kein ungeprüftes Klartext-Debugpanel im Optikpaket.

## 4. Unsichtbare Schlüsselverwaltung: Flows und verbindliche Nutzertexte

**Normalfall:** Anmeldung und Datenentsperrung bilden einen Ablauf. Schlüssel entstehen/arbeiten im entsperrten Browser; der Server erhält keine privaten Datenschlüssel. UI-Zustände sind Anmeldung, Datenzugang und Berechtigung getrennt. Kein grünes „Bereit“, solange nur der Login erfolgreich ist. PRF ist eine technische Abhängigkeit und kein Nutzerwort.

| Situation                                 | Ablauf und exakte Nutzertexte                                                                                                                                                                                                                                                                                                                                                                                                         |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Passkey-Login mit vorbereitetem Gerät     | Passkey → bestehende Auth-Schritte → automatisches Öffnen des Keyrings → berechtigte Zugänge laden → Zielseite. Kurz „Ihr Datenzugang wird vorbereitet …“. Im Erfolg kein zusätzlicher Dialog.                                                                                                                                                                                                                                        |
| Erstes Konto                              | Passkey registrieren, lokale Schutzdaten vorbereiten, einmalige Recovery-Sicherung. „Sichern Sie Ihren Wiederherstellungscode.“ / „Er wird nur jetzt angezeigt. Bewahren Sie ihn getrennt von diesem Gerät auf. Ohne einen nutzbaren Datenzugang und ohne diesen Code können geschützte Daten verloren sein.“ Aktionen „Als Datei speichern“, „Kopieren“; Kontrollfeld „Code zur Bestätigung erneut eingeben“, dann „Code gesichert“. |
| Neuer Kunde                               | Nach „Kunde anlegen“ automatische lokale Erzeugung und eigene Zugangszuordnung. „Der Kunde wird eingerichtet …“ → „Der Kunde ist bereit.“ Bei Teilfehler „Der Kunde wurde angelegt. Der Datenzugang ist noch nicht bereit.“ / „Einrichtung fortsetzen“. Keine zweite Kundenanlage.                                                                                                                                                    |
| Weitere Person                            | Rechte zuweisen und automatisch für verifizierte, vorbereitete Empfänger Zugang erzeugen. Solange Vorbereitung fehlt: „Der Datenzugang wird verfügbar, sobald die Einrichtung abgeschlossen ist.“ Bei nötiger Vertrauensprüfung: „Die Identität dieser Person muss vor der Freigabe bestätigt werden.“ / „Person prüfen“. Keine automatische Freigabe eines bloß vom Server gelieferten fremden Schlüssels.                           |
| Neues Gerät ohne automatische Entsperrung | Login kann erfolgreich sein; Metadaten bleiben nutzbar. „Sie sind angemeldet. Dieses Gerät kann Ihren Datenzugang nicht automatisch öffnen.“ / „Anderen Passkey verwenden“ / „Wiederherstellung öffnen“ / „Ohne Datenzugang fortfahren“. Recovery öffnet Konto > Erweitert, Code nur im RAM. Auf diesem Gerät keine dauerhafte automatische Entsperrung versprechen.                                                                  |
| Passkey-Abfrage abgebrochen               | „Die Passkey-Abfrage wurde abgebrochen. Versuchen Sie es erneut.“ / „Erneut versuchen“. Nicht als Geräteinkompatibilität behandeln.                                                                                                                                                                                                                                                                                                   |
| Geräteverlust, weiterer Zugang vorhanden  | Mit anderem Passkey anmelden, verlorenen Passkey/Sitzung widerrufen, neues Gerät einrichten. „Entfernen Sie den Zugang des verlorenen Geräts.“ Nach Prüfung ggf. Hintergrundrotation; letzte handlungsfähige Identität schützen.                                                                                                                                                                                                      |
| Kein nutzbarer Gerätezugang               | Wiederherstellung nach separat bestätigter Kontoauthentifizierung, soweit Vertrag nur Daten-Recovery unterstützt. „Geben Sie Ihren Wiederherstellungscode ein, um Ihren Datenzugang zu öffnen.“ / „Datenzugang öffnen“. Ein Daten-Recovery-Code ersetzt nicht automatisch den Login. Fehler: „Der Code konnte nicht verwendet werden. Prüfen Sie die Eingabe und das gewählte Konto.“                                                 |
| Alles verloren                            | „Auf diesem Gerät ist kein Datenzugang verfügbar. Verwenden Sie einen weiteren eingerichteten Passkey oder Ihren Wiederherstellungscode. Falls eine andere berechtigte Person Zugang hat, kann sie Ihnen erneut Zugang geben.“ Kein pauschales Passwortreset zur Datenrettung versprechen. Ohne weitere Quelle: „Ohne einen vorhandenen Datenzugang ist eine Wiederherstellung nicht möglich.“                                        |
| Hintergrundrotation                       | Nach autorisiertem Start alle weiterhin berechtigten, verifizierten Zugänge berücksichtigen, neue Eingänge neue Generation; Bestand/Holds/Anhänge seitenweise umhängen. Unaufdringlich unter Erweitert: „Der Datenschutz wird im Hintergrund aktualisiert.“ Fortschritt nur aus bestätigten Ergebnissen; Abschluss erst nach serverseitig null alten Referenzen.                                                                      |
| Browser geschlossen/gesperrt              | „Die Sicherheitsaktualisierung ist pausiert. Sie wird fortgesetzt, sobald ein berechtigter Datenzugang geöffnet ist.“ Keine Ausführung durch Service Worker oder geschlossene PWA versprechen. Nach Entsperrung aus geprüftem Inventar fortsetzen.                                                                                                                                                                                    |
| Rotation blockiert                        | „Die Sicherheitsaktualisierung konnte noch nicht abgeschlossen werden. Der bisherige Fortschritt bleibt erhalten.“ / „Details prüfen“. Sicherer Grund: „Ein Speicher ist nicht erreichbar.“ oder „Für einzelne Daten fehlt der Zugang.“ Alte Generation nicht löschen.                                                                                                                                                                |
| Zugang fehlt / Daten beschädigt           | „Für diese Einsendung ist Ihr Datenzugang noch nicht eingerichtet.“ / „Zugang prüfen“. Davon trennen: „Diese Einsendung konnte nicht sicher geöffnet werden.“ / „Erneut versuchen“. Bei Vertrauenskonflikt „Die Identität konnte nicht bestätigt werden. Es wurden keine neuen Datenzugänge freigegeben.“                                                                                                                             |
| Sitzung endet                             | Inhalte schließen, laufende lokale Arbeit stoppen, sensible Puffer freigeben. „Ihre Sitzung ist abgelaufen. Melden Sie sich erneut an.“ Bereits gesendete Requests können noch abschließen; anschließend Status nachladen.                                                                                                                                                                                                            |

**Vor P12-B zu schließende Vertragslücken:** Der heutige `KeyringPanel` erzeugt Recovery je Kunde; `RotationPanel` verlangt erneut einen Code und manuelle Empfängerwahl. Ein einziger Setup-Code, der zukünftige Kunden/Generationen wiederherstellen kann, braucht einen geprüften Konto-Recovery-Vertrag samt Bestandsüberführung. Fingerabdruckprüfung darf erst durch einen gleichwertig bestätigten Vertrauens-/Einladungsmechanismus ersetzt werden. Ein Recovery-Code für Daten ist derzeit kein belegter Konto-Login-Recoveryweg. Auch der Schutz zwischen Login und PRF-Unlock muss gemeinsam integriert werden. Diese Grenzen blockieren den jeweiligen Automatikfluss, nicht die rein optische Shell. Bis zur Lösung die bestehende Recovery-Funktion erhalten und als Übergang in Erweitert benennen; niemals nur Warnungen entfernen.

## 5. Erststart-Assistent und Umstieg

Sechs Hauptschritte; optionaler Umstieg hat eigene Unterphasen. Fortschritt und abgeschlossene Prüfungen serverseitig speichern, Geheimnisse/entschlüsselte Inhalte ausschließlich gemäß Sicherheitsvertrag. Wiederaufnahme nach Anmeldung, kein erneutes Ausgeben eines bereits bestätigten Codes. Initialer Zugang muss installationsgebunden autorisiert sein; kein öffentliches „Erster Besucher wird Admin“. Bootstrap-/Setup-Sperre und konkurrierende Erststarts sind P11-C-Vertragsarbeit.

1. **Konto & Passkey.** Betreibername/Kontoname, Passkey-Gerätename, notwendige Auth-Faktoren gemäß Vertrag. Bootstrapvoraussetzungen prüfen. „Ihr Administrationskonto einrichten“ / „Passkey erstellen“. Bei Abbruch hier fortsetzen; ohne nutzbare Datenentsperrung auf kompatiblen Passkey verweisen, keine unsichere Ersatzspeicherung.
2. **Wiederherstellung.** Einmaliger Code wie Abschnitt 4, manuell kopieren/herunterladen und durch erneute Eingabe bestätigen. Weiter erst nach korrekter Bestätigung. Kein Code in Telemetrie, URL oder Browserpersistenz. Bei verlorenem unbestätigtem Setup-Zustand nur durch definierten Recovery-Neustart fortfahren; nicht heimlich neuen Schutz über bereits gespeicherte Daten legen.
3. **Mail.** SMTP oder Mail-Proxy anlegen/zuweisen, Verbindung testen. Probeversand nur separat mit sichtbarer Testempfängeradresse und bestätigter Außenwirkung, sofern API verfügbar. „Später einrichten“ zulässig; Abschluss markiert Mail dann ausstehend, Veröffentlichung mailabhängiger Formulare bleibt gesperrt.
4. **Adressen & Betrieb.** Interne Verwaltungsadresse, öffentliche Haupt-/temporäre API-Adresse und optionale Backupadresse unterscheiden. Effektive Ports 8081 intern/8080 öffentlich samt ENV-Quelle zeigen; Änderungen daran extern. Dashboard öffentlich standardmäßig aus. DNS-/Proxy-/TLS-Anleitung und Prüfstatus; Admin-Origin/RP-ID vor endgültiger Passkeybindung prüfen, spätere Änderungen nicht als einfache kosmetische URL behandeln. Temporäre externe Domain nicht als spätere Passkey-Identität verwenden. Notwendige Bootstrapkorrekturen dürfen bereits vor Schritt 1 blockieren.
5. **Daten übernehmen (optional).** Auswahl „Neu beginnen“ / „Vom bisherigen Backend umsteigen“. Neuinstallation überspringt Import, nicht die Abschlussprüfung. Umstieg öffnet die folgenden Phasen, jederzeit über Betrieb > Umstieg wieder erreichbar.
6. **Prüfen & abschließen.** Synthetische Probe verschlüsseln, speichern, wieder laden und im Browser entschlüsseln; erwarteten Inhalt vergleichen, Bereinigung bestätigen. Bei Migration zusätzlich Altbestand-Stichproben je unterstütztem Format/Anhang und Berechtigungsprüfung. „Prüfung erfolgreich“ nur für tatsächlich geprüfte Teile. Abschlussübersicht trennt Installation bereit, Import geprüft, Umschaltung offen. Primäraktion „Zum Überblick“, bei Umstieg „Umschaltung vorbereiten“.

### Umstiegsphasen (P11-D/F; Zielablauf, noch nicht vollständig unterstützt)

| Phase                    | Oberfläche / Freigabe                                                                                                                 | Grenze und Wiederaufnahme                                                                                                                                                 |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A Koexistenz             | Neue interne + temporäre externe Domain prüfen; Altbetrieb bleibt führend; Backup-/Rückkehrplan anzeigen                              | Noch keine Domainumschaltung, keine Alt-Schreibzugriffe                                                                                                                   |
| B Quelle                 | Host/Port/DB/Benutzer/Passwort; „Nur lesender Zugriff“; explizite betriebliche Netzfreigabe, „Verbindung prüfen“                      | Credentials im SecretStore, nie im Bericht; readonly tatsächlich prüfen. P9 liest derzeit isolierten eingefrorenen Snapshot, Live-Alt-DB-Anbindung ist P11-D-Erweiterung  |
| C Inventar & Zuordnung   | Kunde/Formular/Verbindung bewusst zuordnen, Bestands-/Statistikbericht und nicht abgebildete Tabellen zeigen                          | Namen/Domains nicht als automatische Kundenzuordnung verwenden; fehlende Zuordnung blockiert                                                                              |
| D Schutz & Konvertierung | Altzugang nur im berechtigten Browser öffnen; unterstützte Daten/Anhänge prüfen, Formulare in aktuelle inaktive Entwürfe konvertieren | P9 nimmt keine privaten Altschlüssel an. Browser-Keyimport und Konverter sind P11-F. Unbekannte PHP-Logik/Altformate als Prüffall, keine verlustfreie Automatik behaupten |
| E Prüflauf & Import      | Mengen, bestätigte Objekte, Konflikte, Prüffälle; „Prüflauf starten“, danach „Import starten“                                         | Inaktive Ziele; keine Mail/Webhook-Auslösung. Gleicher Lauf/Plan wiederaufnehmbar; geänderte Quelle ist Konflikt, kein stiller Überschreib-Retry                          |
| F Prüfung                | Probe-Ent-/Verschlüsselung, Feld-/Mail-/Anhangparität, Rechte, Zählberichte, synthetische Testeinsendung                              | „Import geprüft“ ist keine Cutoverfreigabe. Offene Prüffälle einzeln lösen, keine pauschale Bestätigung                                                                   |
| G SDK vor DNS            | Neue SDK-Version/Zugang und Haupt-/Backupadresse pro Kundenintegration installieren und testen; Übersicht „ausstehend/geprüft“        | Altsystem bleibt bis koordiniertem Wechsel maßgeblich; jeder Adapter-/Versionspfad muss geprüft sein, kein impliziter Parallelversand                                     |
| H Finaler Abgleich       | Schreibruhe am alten Eingang organisatorisch herstellen, finalen Delta-/Löschabgleich prüfen; „Umschaltung freigeben“                 | Delta-/Rollback-Vertrag ist offen; P9 allein kann diese Freigabe nicht liefern. Aktive Zielreleases sind mit dessen Importvoraussetzungen zu koordinieren                 |
| I Umschalten             | Domain extern umlegen, neue Testeinsendung durch Eingang, Speicherung, Lesen und Mail prüfen                                          | DNS-Änderung wird nicht vom Assistenten vorgetäuscht. Rückkehr nur mit geprüftem Umgang mit inzwischen neu angenommenen Daten, kein Ein-Klick-Datenrollback               |
| J Abschluss              | Bericht sichern; „Altzugriff entfernen und Umstieg deaktivieren“ nach bestätigtem Erfolg                                              | Credentials entfernen, Prüfbericht ohne Secrets behalten; Quelle/Backups gemäß vereinbartem Rückkehrfenster erhalten                                                      |

Der Fortschrittsbildschirm unterscheidet **läuft / pausiert / wartet auf Freigabe / fehlgeschlagen / geprüft / umgeschaltet**. Bei Verbindungsabbruch: „Die Verbindung wurde unterbrochen. Der bestätigte Fortschritt bleibt erhalten.“ Serverimport kann weiterlaufen; Browserentschlüsselung pausiert. Nach Rückkehr zuerst Laufstatus lesen. Keine geschätzte Restzeit ohne belastbare Messung.

## 6. Sprache, Barrierefreiheit und Mobil/PWA

**Sie** beibehalten: bestehende `de.ts`-Texte sprechen so, Betreiber/Agenturen und Kunden teilen eine professionelle Verwaltungsoberfläche. Timetrack liefert die visuelle Sprache, nicht dessen persönliche Du-Ansprache. Texte kurz, tätigkeitsbezogen, ohne Schuldzuweisung: „Einsendung öffnen“, „Datenzugang“, „Wiederherstellungscode“, „Löschschutz“, „Sicherheitsaktualisierung“. Begriffe wie `kid`, HPKE, PRF, UUID und rohe Scope-JSONs nicht im normalen Nutzerfluss. Technische Host-/ENV-Bezeichner nur bei tatsächlich administrativen Aufgaben. Alle Texte einschließlich Einheiten, Pluralen und Fehlermeldungen über i18n.

WCAG-2.2-AA-Ziel: Kontrast mindestens 4,5:1 für normalen Text und 3:1 für Bedienelemente; Farbe immer mit Text/Symbol ergänzen. Sichtbarer Fokus, Skip-Link, Landmarken, echte Überschriften/Labels, Feldfehler mit Eingabe verknüpft. Dialogfokus einschließen und nach Schließen zurückgeben; destructive Dialogs nicht mit Löschaktion vorfokussieren. Fortschritt höflich ansagen, Fehler gezielt als Alert; kein Vorlesen von Codes/Token über Live-Regionen. Tabs entweder vollständig mit Tastaturmuster oder als normale Seitennavigation implementieren. Diagramme immer mit Tabelle. Sortieren von Feldern auch per „Nach oben/unten“, nicht nur Ziehen. Reduzierte Bewegung respektieren.

Unter 760 px Sidebar als Sheet, TopBar bleibt 60 px; letzte Breadcrumbstufe plus Zurücklink. Touchziele mindestens 44 × 44 px. Filter einklappbar, Einsendungsdetail vollflächig statt schmaler Seitenleiste, Hauptaktion unten nur ohne Überdeckung von Inhalt/Fokus. Tabellen als beschriftete Zeilenkarten oder gezielt horizontal scrollbar; niemals horizontales Scrollen der ganzen Seite. Setup mobil ein Schritt mit „2 von 6“, Code umbrechbar/kopierbar; Safe Areas berücksichtigen. Bei 200 % Zoom und 320 px Breite weiterhin bedienbar.

Offline zeigt Shell/Hilfe, aber keinen gespeicherten Klartext, keine Tokens und keine schreibende Warteschlange. „Sie sind offline. Änderungen sind erst wieder mit Verbindung möglich.“ Kein Offline-Versprechen für Rotation/Importentschlüsselung. PWA-Update: „Eine neue Version ist verfügbar.“ / „Jetzt neu laden“; vorher ungespeicherte Arbeit und laufende Browserarbeit berücksichtigen. Logout/Sperre entfernt entschlüsselte Ansichten und sensible Browserpuffer.

## 7. Komponenten für shadcn-svelte

Komponenten gegen die im Projekt installierte Version prüfen; keine Paketinstallation Teil dieses Konzepts. Vorhandene `Button`, `Input`, `Textarea`, `Row`, `Notice`, `Select`, `DraftGate` funktional übernehmen bzw. vereinheitlichen.

| Grundlage                                                | Zusammengesetzte Produktkomponente                    | Verwendung                                                   |
| -------------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------ |
| Sidebar, Sheet, Breadcrumb, Separator                    | AppShell, TopBar, CustomerSwitcher                    | Persistente Navigation; mobil Sheet                          |
| Popover, Command/Combobox, DropdownMenu                  | NavigationSearch, Customer/FormPicker, AppearanceMenu | Rechtegefilterte Ziele, Auswahl per Name                     |
| Button, Input, Label, Textarea, Select, Checkbox, Switch | FormField, SettingsField, PermissionPicker            | Hilfe/Fehler/Quelle/Neustartpflicht, echte Labels            |
| Table, Badge, Pagination bzw. Mehr-laden                 | FormList, EntryList, ConnectionList, StatusBadge      | Ein konsistentes Dichtemuster, begrenzte Abfragen            |
| Card, Skeleton, Alert                                    | PageHeader, EmptyState, LoadingState, ErrorState      | Stabile Geometrie; keine ganze Seite als Spinner             |
| Dialog, AlertDialog, Sheet                               | ConfirmAction, EntryDetail, ExportDialog              | Auswirkungen, Fokusführung, selektive Aktionen               |
| Tabs, Accordion/Collapsible                              | FormSections, AccountSections, AdvancedSection        | Progressive Offenlegung, stabile URLs                        |
| Progress, Alert, Button                                  | SetupStepper, MigrationProgress, BackgroundJobStatus  | Wiederaufnahme und echte bestätigte Fortschritte             |
| Input, Button, Alert                                     | OneTimeSecret, RecoveryConfirmation                   | Einmalanzeige, kontrolliertes Kopieren, keine Persistenz     |
| Tooltip plus sichtbare Hilfe, Dialog                     | HelpDialog, DisabledReason                            | Erklärung auch per Tastatur/Touch erreichbar                 |
| Chart-Darstellung plus Table                             | StatisticsPanel                                       | Beschriftete Reihen, UTC, Conversion und Tabellenalternative |

Keine Fachrechte oder Schlüsseloperationen in rein visuellen Komponenten verstecken. Gemeinsame Dienste liefern zulässige Aktionen, Konflikte und Status; Shell hält nur Navigation/Darstellung und bindet den separat geprüften Sitzungs-/Datenzugangslebenszyklus ein.

## 8. Umsetzungsschritte, Abhängigkeiten und Abnahme

| Schritt                                            | Abgegrenztes Ergebnis / voraussichtlicher Dateibesitz                                                                                             | Abhängigkeit und Abnahme                                                                                                                                                                                                                 |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 Optisches Fundament                              | P12-A: Tokens, Theme, Shell/TopBar, Basiszustände, Login-/Setup-Rahmen; `pwa/src/routes/admin/Shell.svelte`, globale Styles, UI-Komponenten, i18n | Bestehende Auth/Rechte unverändert. Desktop/mobil, Dark/Light, Fokus, langsame API und Seitensprung prüfen; Setup nur Rahmen, bis P11-C verfügbar                                                                                        |
| **2 Erste Fachseite: Formulare + Kundenüberblick** | `Forms.svelte`, `Tenants.svelte`, lesender Teil `OverviewTab.svelte`, gemeinsame Listen                                                           | Baut auf 1; vorhandene APIs nutzbar. Alle Zustände, 0/1/viele Kunden, Rechte, Suche/Filter im verfügbaren Umfang, keine wechselnde Shell. Diese Seite zuerst, weil sie den täglichen Einstieg und das Muster für weitere Seiten festlegt |
| 3 Datenzugang integrieren                          | P12-B: Login/Keyring/Kundenanlage/Mitglieder/Erweitert, ausschließlich nach beschlossenem Vertrag                                                 | Gemeinsamer PRF-/Recovery-/Vertrauensvertrag vor Änderung. Echte Authenticator-Prüfungen, kein-PRF/Abbruch, Verlust, Login ohne Datenzugang, automatische Freigabe nur an bestätigte Empfänger                                           |
| 4 Einsendungen + Statistik                         | `EntriesTab.svelte`, `StatisticsChart.svelte`, Export-/Bestätigungsdialoge                                                                        | 1–3, ADR 0012/0015/0016/0019. Hold aller Objekte, gemischte Löschresultate/202, Exportgrenzen, Sessionende während Entschlüsselung, Conversion bei 0 Besuchen; neue Aggregate separat                                                    |
| 5 Formulararbeit                                   | `FormPage.svelte`, `FieldsTab.svelte`, `MailTab.svelte`, `PublishTab.svelte`, `KeysTab.svelte` als Einbindung; Domains/Webhooks                   | 1–3 und verfügbare Backendverträge. Entwurfskonflikt, Veröffentlichung/Bestätigung, feste Domainversion, SDK-Test und unveränderter Resend; Ablauf nur Platzhalter                                                                       |
| 6 Betrieb + Erststart                              | `Settings.svelte`, `Connections.svelte`, Setup-/Umstiegsseiten                                                                                    | P11-A → B; C auf Bootstrap/Recovery, D/F auf P9 plus fehlende Keyimport-/Konverter-/Delta-/Rollback-Verträge. ENV-Sperren, Quellen, getrennte Listener, readonly Quelle, Wiederaufnahme und synthetischer Rundlauf abnehmen              |
| 7 MCP/OAuth und Hintergrundkomfort                 | `ApiTokens.svelte`, Konto-Unterseiten, Consent; Rotationsstatus statt manuellem Panel                                                             | Persönliche Tokens schon vorher optisch angleichbar; OAuth erst P11-E (nach A/B, unabhängig von D). Hintergrundrotation nach 3 + ADR 0016; Rechteentzug, offene Holds, Speicherausfall, Browser schließen/erneut öffnen prüfen           |
| 8 Paritäts- und Nutzungsabnahme                    | Keine neue Editorfunktion; Seitenabgleich mit PARITAET/ANFORDERUNGEN                                                                              | Tastatur/Screenreader, 320/760/1440 px, Zoom, reale Passkeys, zwei Listener und echter Importprobelauf. Offene Bestandsthemen gezielt paketieren; Ablauf-Editor später eigener Auftrag                                                   |

Schritte 3 und 6 enthalten Sicherheitsarbeit und sind keine bloßen Stylingtickets. Reihenfolge von P11 bleibt A/B/E/C/D gemäß Arbeitsplan; die UI-Schritte dürfen verfügbare Teilfunktionen früher angleichen, ohne fehlende Backendfunktionen als fertig zu markieren. Pro Paket ein schreibender Agent je Datei, gemeinsame Verträge zuerst; keine automatische Delegation Bestandteil dieses Dokuments.

**Abnahme des Zielbilds:** Betreuer erreicht Einsendungsdetail ohne Schlüsselbedienung; Kundenwechsel zeigt keine alten Inhalte; fehlendes Recht erzeugt keine scheinbar bedienbare Aktion; Umstieg zeigt Prüffälle statt Erfolg; ENV-Feld bleibt gesperrt; Token wird nur einmal angezeigt; Rotation pausiert ehrlich beim Browserende. Hold, Rechte, Migration und Wiederholung brauchen echte Verhaltens-/Integrationstests, nicht nur Screenshots.

## 9. Quellen, Bestandsgrenzen und Übergabe

Projektgrundlage: `AGENTS.md`, `docs/STATUS.md`, `docs/ARBEITSPLAN.md` (P11/P12), `docs/ENTWICKLUNG.md`, `docs/ANFORDERUNGEN.md`, `docs/FORMULARE-UND-ABLAEUFE.md`, `docs/PARITAET.md`; ergänzend ADR 0012–0016, 0018–0021. Bestandsoberfläche: alle `pwa/src/routes/admin/*.svelte` und `pwa/src/lib/i18n/de.ts`. Die jüngeren ADRs gehen historischen Zwischenständen in STATUS/FORTSETZUNG vor; Berichte anderer Branches sind kein Nachweis integrierter Laufzeitfunktion in diesem Worktree.

Wesentliche Differenzen: heutige Shell horizontale Links; Konto enthält Kontenanlage; Tokens verlangen UUID-Eingaben; Schlüssel-/Recovery-/Rotationsarbeit steht offen im Formular; Einsendungen bieten manuelle private Eingabe; Einstellungen zeigen technische Schlüssel. Das Konzept löst diese Darstellungsprobleme, bewahrt aber ihre Sicherheitsbedingungen. Domains/Webhooks/Speicher, Setup/Umstieg und OAuth benötigen teils neue Seiten bzw. noch offene Verträge. Einmaliger kontoweiter Recovery-Code und sichere automatische Fremdzugänge sind explizite Freigabegrenzen für P12-B.

Übergabe: nur diese Datei erstellt, keine Code-/Referenzänderung, keine Commits, keine gestarteten Dienste oder laufenden Jobs. Dateibesitz nach Abschluss frei. Prüfung: statischer Quellen-/Anforderungsabgleich und Markdown-/Whitespaceprüfung; keine Anwendungstests oder visuelle Browserabnahme, keine Produktionsreife behauptet. STATUS/ARBEITSPLAN bleiben wegen der ausdrücklichen Beschränkung auf diese eine Datei unverändert; Fortsetzungswissen steht hier. Nächster konkreter Schritt: Schritt 1 als abgegrenztes Optikpaket vergeben, danach Schritt 2 „Formulare“; parallel zur Planung die drei P12-B-Vertragslücken klären, bevor Automatik implementiert wird.
