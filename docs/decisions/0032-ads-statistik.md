# ADR 0032 – Datensparsame Ads-Statistik

Datum: 03.11.2026. Paket P13-Ads, Todolino A4AE1142-DEF0-4811-93BA-A5F453AAF1EE.
Nutzerauftrag ist Grundlage; DB-/Browserabnahme und unabhängiger Review stehen aus.

## Altcodebefund und Abgrenzung

Nur Quellcode gelesen, keine Kundendaten: `../form-backend_bvk/providers/Statistics.php`
Zeilen 107–127 (getrimmter Header ClientGclid, leer/`0` kein Ads-Treffer),
610–636 (Verteilung), 736–773 (Gruppierung nach GCLID für eindeutige Klicks und
konvertierte Klicks). Keine Auswertung von `utm_campaign`, Kampagnen- oder
Anzeigengruppenkennungen in diesen Funktionen. GCLID ist eine Klickkennung,
keine auslesbare Kampagnenkennung. Aus ihr werden keine Kampagnen erfunden.
FA-080 (Fehlerstatusverteilung) bleibt außerhalb dieses Ads-Pakets.

## Entscheidung

Ein optionales Objekt `ads: {gclidPresent: boolean}` ergänzt Besuchsereignis und
signierten `_statistics`-JSON-String. Die Ansicht bestimmt den Wahrheitswert lokal
(vergleichbar Altcode: getrimmte GCLID weder leer noch `0`), überträgt niemals den
Rohwert an die Statistik. Nur echte JSON-Booleans, keine numerischen Ersatzwerte;
unbekannte Eigenschaften und Rohwerte werden abgewiesen. Beim Collector nur
für `visit`, bei Ingest ausschließlich im signierten Kontext. Ohne Messung bleibt
`ads_present` NULL; false bezeichnet ausdrücklich gemessenes Nicht-Ads.
Ein vorhandener Besuch bestimmt beim Submit die Klassifikation, andernfalls gilt
der signierte Indikator. Wiederholungen überschreiben keine Klassifikation.
Bestehende Ereignisdeduplizierung und Domain-/Releasebindung bleiben maßgeblich.

Es wird kein Kampagnenpseudonym gespeichert, weil die geprüften Altfunktionen
keine Kampagnen auswerten. Deshalb ist kein neuer geheimer Tagesschlüssel nötig.
Abweichend von der Annahme im Auftrag verwendet ADR 0015 tatsächlich zufällige
16–32-Byte-Besuchspseudonyme und keine serverseitige Tages-HMAC-Ableitung.
IP, User-Agent, GCLID, URLs und Kampagnenrohwerte gelangen über diesen Vertrag
nicht in die Statistik-DB. Der Indikator ist kein kryptographischer Ads-Nachweis.

`GET /admin/api/v1/tenants/{tenantId}/forms/{formId}/statistics/ads?days=30`
verlangt Cookie-Anmeldung, bestehendes Budget und live `statistics.read` am
Formular. days ganzzahlig 1–366, UTC einschließlich heute, nur Produktion und
nicht abgelaufene Ereignisse. Keine Rückrechnung aus Einsendungsinhalten oder
importierter Legacy-Statistik. Ausgabe: `from,to,available:true,
campaignsAvailable:false,minimumGroupSize:5,groups,suppressed`.
Gruppen `ads|nonAds|unknown` enthalten `visits,submits,conversion`; Conversion
ist Einsendungen/Besuche, bei null Besuchen null, über 100 % zulässig.
Keine Einzelereignisse oder Identifikatoren und keine ungeschützten Gesamtsummen.
Sobald eine von null verschiedene Zelle unter fünf liegt, wird die ganze Gruppe
unterdrückt. Null ist sichtbar; auch die Kennzeichnung `unknown` wird geschützt.
Das ist Segment-Conversion gemäß Auftrag; die frühere GCLID-basierte
Unique-Click-Conversion wird bewusst nicht durch neue Klickverknüpfungen nachgebaut.
Kampagnen-Conversion ist mangels ausgewerteter Kampagnen nicht verfügbar.

REST und MCP verwenden denselben Reader und dieselbe Unterdrückung. Das Werkzeug
heißt gemäß Nutzerauftrag `ads_statistics`, Scope `statistik.lesen`. Der alte Name
`statistik_ads` bleibt als aufrufbarer Kompatibilitätsalias mit identischen Prüfungen;
`tools/list` enthält weiterhin sechs Werkzeuge, jetzt mit neuem Ads-Namen.
Tokenbindung, live Rechteprüfung und wertfreier Audit aus ADR 0031 bleiben erhalten.
Die PWA zeigt die Gruppen im Statistikabschnitt für die letzten 30 Tage mit
Datenschutz- und Kampagnenhinweis, Lade-/Fehler-/Leerzustand.

## Schema und Löschung

Upgrade-Kandidat `backend/db/upgrades/0031-ads-statistics.sql` (nächste freie
Upgrade-Nummer), identische ALTER-Anweisung in schema-p3.sql. Keine neue Tabelle:
Tabellenzahl im Splitter bleibt 82; ALTER-Zahl wird mit 12 geprüft.
Kein automatischer Bestandsupgrade, keine Änderung gespeicherter Checksummen.
13 Kalendermonate unverändert. `StatisticsEraser` löscht die vollständige Zeile
samt Indikator bei manueller Löschung und Retention; keine separate Ableitung,
Schlüsseltabelle oder persistente Aggregation kann die Löschung überleben.
