# 0003 Produkt- und Betriebsentscheidungen (P1, Teil 3)

Datum: 26.10.2026. Status: **beschlossen durch den Nutzer** (Session vom 26.10.2026). Ergänzt 0001 und 0002. Schwellenwerte und Detailsemantik sind in P2 zu konkretisieren.

| Nr. | Entscheidung | Verworfene Alternativen |
| --- | --- | --- |
| 1 | Arbeitsname `form-backend`; Produktname und Remote später. Kein Remote, keine Veröffentlichung. | sofortiger Name |
| 4 (Rest) | Pro Formular wählbar: HPKE-Paketformat `:2` (Standard) oder zusätzliche symmetrische Nutzlasthülle (`sym`). Datenschlüssel pro Kunde mit Generationen und Passphrase-Recovery; Entschlüsselung/Resend durch berechtigte Benutzer. | Schlüssel pro Formular |
| 5 | **Voller Ablaufeditor**: Graphen, Schleifen, Warte-/Freigabeschritte, Skriptknoten. Nutzerentscheidung abweichend von der Empfehlung (azyklisch zuerst). | azyklisch + Teilabläufe; linear |
| 6 | PHP-SDK ab PHP 8.2, schlank (Formular laden, verschlüsseln/signieren, senden). Docker-Agent optional als Kompatibilitätsbrücke für Alt-Endpunkte v1/v2. | PHP 7.4+ |
| 7 | Feldzuordnung per Name auf Bestandsseiten; gesperrte Felder werden serverseitig fixiert, verborgene Felder nicht gerendert, aber validiert. | nur systemgerenderte Formulare |
| 8 | Domains trägt der Administrator manuell ein; kein DNS-Besitznachweis. Reverse Proxy/TLS bleibt extern, Host nur aus vertrauenswürdig konfiguriertem Proxy. Nutzerentscheidung abweichend von der Empfehlung (DNS-TXT). | DNS-TXT-Nachweis |
| 9 | Debug: sensible Felder maskiert, Aufzeichnung TTL 15 Minuten, Klartext nur für berechtigte Benutzer mit Schlüssel, Export maskiert, Testziele verwaltbar. | Klartext für Admins |
| 10 | Statistik: pseudonym, keine IP, Aufbewahrung 13 Monate, Ereignisse Besuch/Beginn/Absenden/Abbruch; Conversion = Absenden/Besuch; Löschprotokoll bleibt. Bestehende Statistiken bleiben erhalten. | Altbestand ohne neue Ereignisse |
| 11 | Speicher: DB Standard, pro Formular S3/SFTP wählbar, Größenlimit pro Formular; bei Ausfall des Ziels wird die Annahme mit Fehler abgelehnt (kein stiller Verlust). Verlagerung vorhandener Daten als eigener Vorgang. | lokaler Puffer |
| 12 | Migration: wiederholbarer Import aus Datenbankabzug, kurzes Cutover-Fenster, Admin-Domain/RP-ID unverändert (Passkeys und PRF-Kontoschlüssel bleiben gültig). | neue Admin-Domain |
| 13 | REST/MCP: Entwürfe und Tests erlaubt, Veröffentlichung nur durch Menschen mit Bestätigung; KI-Konvertierung von PHP liefert nur einen Entwurf. | Token dürfen veröffentlichen |
| 14 (Rest) | Feature-Branch/Worktree pro Paket, Conventional Commits, lokal ohne Remote. | direkt auf main |

## Risiken aus abweichenden Entscheidungen

- **Voller Editor (5):** Schleifen und Skriptknoten brauchen Laufzeitgrenzen (Schrittlimit, Timeout, Speicher), eine Sandbox für Skripte und einen versionierten Ausführungsvertrag mit Wiederanlauf. Das ist der größte Aufwand- und Sicherheitstreiber; P6 wird entsprechend zerlegt (Engine ohne Skripte zuerst, Skriptsandbox als eigenes Paket mit unabhängigem Review).
- **Manuelle Domains (8):** Kein Besitznachweis. Der Missbrauchsschutz stützt sich auf die Ed25519-Pflicht (ADR 0002) und Origin-/Host-Prüfung gegen die eingetragenen Domains. Ein späterer Nachweis bleibt nachrüstbar.

## Folgen

- P2 legt Verträge für Ablaufmodell (inkl. Schleifen/Warten), Debug-Ereignisse, Statistikereignisse, Speicheradapter und Rechte (REST/MCP) an.
- Migration (P9) darf Admin-Domain, Passkeys und Kontoschlüssel nicht verändern.
