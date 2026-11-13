# Sicherheit, Daten, Debug und Statistik

## Verschlüsselungsprofile pro Formular

Bestätigt: Entscheidung je Formular über Art, Zeitpunkt und Reichweite der Verschlüsselung. Das Backend darf für initialen Mailversand Klartext erhalten. Transport über HTTPS genügt; zusätzlich symmetrische Nutzlastverschlüsselung möglich. Frühere Überlegungen einer pauschalen Pflicht zur Verschlüsselung vor dem Backend sind dadurch ersetzt.

Getrennt konfigurieren: (1) Transport/Nutzlast zum Backend, (2) erlaubter Klartextbedarf je Verarbeitungsschritt, (3) dauerhafte Speicherung und berechtigte Entschlüssler, (4) Zustellungswarteschlange und Aufbewahrung. Keine Klartexte in gewöhnlichen Logs; Speicherzustände und Fehler dürfen niemals still auf unverschlüsselte Persistenz ausweichen.

Mögliche Profile als Vorschlag: Backend verarbeitet im Speicher und speichert nur verschlüsselt; zusätzlich symmetrischer Transport; optional Verschlüsselung vor dem Backend mit entsprechend eingeschränkten zentralen Schritten. Letzteres ist nicht Standardpflicht. Kein Profil vor der konkreten Schlüssel-/Retry-Entscheidung implementieren.

Initialer Mailversand und späterer erneuter Versand unterscheiden sich. Für Resend kann der berechtigte Browser entschlüsseln und Daten bewusst erneut übertragen. Für automatische Zustellungs-Retries braucht es entweder eine gesondert verschlüsselte, zeitlich begrenzte zustellbare Nutzlast oder einen anderen expliziten Mechanismus. Das ist noch offen und darf nicht mit pauschalen E2EE-Aussagen verdeckt werden.

Bei direkter Browseranbindung ist ein dauerhaftes gemeinsames Geheimnis in JS nicht geheim. Beim PHP-SDK/Kundenagenten können Geheimnisse auf dem Kundenserver bleiben. Zusätzliche symmetrische Verschlüsselung ersetzt TLS nicht. Schlüsselzwecke für Signatur, Transport und dauerhafte Daten trennen.

Vorhandener neuer Datenpfad: HPKE/X25519 und AES-GCM mit Browserentschlüsselung, Passkey-gebundenen Schlüsselhüllen und Recovery. Altpakete und Produktionsmigrationsstand gesondert behandeln. Bewährte Bibliotheken und PHP/Swift/Browser-Kreuztests statt eigener Kryptoprimitiven. Schlüsselgranularität pro Kunde/Formular noch zu entscheiden. Passwort-/Kontowiederherstellung bedeutet nicht automatisch Wiederherstellung des Datenzugangs.

## Pairing — Vorschlag

WebUI erzeugt einen kurzlebigen, einmaligen, formulargebundenen Einrichtungscode. PHP-SDK/Agent erzeugt sein Schlüsselpaar lokal, registriert den öffentlichen Teil und erhält erforderliche Konfiguration über TLS. Code atomar verbrauchen, begrenzte Versuche, Ablauf und Widerruf. Private Client-Schlüssel verlassen den Kundenserver nicht. Rotation mit kontrollierter Überlappung und Notfallwiderruf; Status im Guide anzeigen.

## Speicherung

MariaDB ist Standard für sämtliche Formularinhalte und Anhänge. Optionale Adapter S3 und SFTP. Metadaten, Rechte, Status und Speicherreferenz bleiben zentral. Jeder gespeicherte Gegenstand benennt Backend, Objektkennung und Verschlüsselungsformat. Geänderte Voreinstellungen verschieben Altbestände nicht automatisch.

DB-Inhalt und Metadaten können gemeinsam transaktional geschrieben werden. Externe Speicher brauchen vorbereitete/fertige Zustände, Aufräumen verwaister Objekte und Wiederholbarkeit. Aufbewahrung/Löschschutz und Löschvorgänge gelten auch für S3/SFTP. Speicherverlagerung, Sicherung und Export sind unterschiedliche Operationen. Große Uploads erfordern Größenlimits, Streaming oder begrenzte Puffer; keine unbeschränkte RAM-Belegung pro Replika.

## Debugmodus

Bestätigt: Auf Anfrage warten und genauen Ablauf/Datenfluss zeigen. Vorgeschlagener Auftrag fixiert Formular, erwartete Veröffentlichung, Umgebung, Berechtigten und Ablaufzeit. Optionales Korrelationsmerkmal ermöglicht, genau die eigene Testeinsendung zu erfassen. Auftrag und atomare Zuordnung liegen in MariaDB, damit jede Replika ihn erfüllen kann.

Je Schritt zeigen: tatsächlicher Pfad, Zeitpunkt/Dauer, Status, Eingabe, Ausgabe, Feldänderungen, Validierungen/Bedingungen, Datenempfänger, Verschlüsselungszustand und nachvollziehbare Fehler. Kennung eingesetzter Schlüssel statt Schlüsselwerten. Eingehende Header nur über Allowlist/Maskierung; niemals Cookies, Bearer-Tokens oder Secrets mitschneiden.

Testlauf und Beobachtung realer Verarbeitung trennen. Testlauf simuliert Außenwirkungen oder nutzt Testziele. Echte Beobachtung verändert den laufenden Prozess nicht. Schrittwiederholung mit Außenwirkung ist eine ausdrückliche neue Aktion mit Dublettenbehandlung.

Detaillierte Werte nur autorisierten Personen anzeigen; Maskierung, kurze TTL, Zugriffsaudit und explizite Exportregeln. Debug darf die Profilgrenzen nicht umgehen: Was dem Backend nur als Chiffrat vorliegt, wird dort auch im Debug nicht sichtbar. Bei Bedarf lokale Tracebeiträge vom SDK/Agenten, aber nur bewusst freigegeben. Geschützte Debugdaten selbst verschlüsselt speichern oder nur kurzzeitig berechtigt bereitstellen; konkrete Aufbewahrung offen.

## Statistik und Audit

Alle bestehenden Kennzahlen erhalten, insbesondere Anfrage-/Besuchsstatistik, Erfolgs-/Fehlerzustände, Zeiträume, Formular-/Domainfilter und Google Ads/GCLID/Conversions. Künftige Ereignisse klar zwischen Formularaufruf, Beginn, Einsendung, Ablaufdurchlauf und Zustellversuch unterscheiden. Ein Retry erzeugt keine neue Einsendung.

Vorschläge: Abbruch je Schritt (nur soweit Clientinstrumentierung vorhanden), Feldvalidierungsfehler ohne Werte, Laufzeit und Fehlerrate je Baustein, Zustellversuche und Rückmeldungen, Vergleiche nach Kunde/Formular/Ansicht/Domain/Version, Kapazität und Jobwartezeiten. Test/Debug gesondert kennzeichnen und standardmäßig aus Produktionskennzahlen ausschließen.

SMTP-Annahme nicht als belegte Zustellung oder Lesen bezeichnen. Besuche/Beginn/Abbruch benötigen klar definierte Ereignisse und können durch Blocker fehlen. Aufbewahrung, Zugriffsbereich, Aggregation und Trackingzwecke pro Ereignisklasse festlegen; Debugdaten sind keine Statistikdaten. Nachträgliche Metadaten/Aggregate dürfen sensible Formularwerte nicht unbemerkt rekonstruieren.

Audit erfasst Änderungen, Veröffentlichung, Schlüsselzugang, Import/Export, Debugzugriff und privilegierte Aktionen, ohne Secrets oder Formularklartext aufzunehmen. Ein gewöhnliches DB-Protokoll nicht pauschal manipulationssicher nennen.

## Browser-Zugriffsautomatik (P12-B-Teilstand, ADR 0024)

Die Login-Assertion kann lokal eine PRF-Ausgabe liefern, die nach Abschluss beider Loginfaktoren den Kontowrap öffnet. Die PRF-Ausgabe wird nicht Teil des Verify-Requests. Neues öffentliches Eingabesalz und Altwrap-Kompatibilität sind in ADR 0024 festgelegt. Eine entsperrte Sitzung kann auslaufende Generationen anhand des Serverinventars mit CAS und unveränderten Nutzbytes umwickeln; Hintergrundprüfungen verlängern die Inaktivitätsfrist nicht. Rohprivateingabe entfällt in Einsendungen. Kontoweite Recovery/PRF-Fallback und vollständig autonome Rotation sind noch offen; Details und tatsächliche Prüfungen in `handoffs/P12-B.md`. Der bestehende Kundengenerationscode darf nicht als Kontorecovery dargestellt werden.
