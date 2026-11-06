# ADR 0004: Entscheidungen nach dem P2-Vertragsreview

Stand: 27.10.2026. Vom Nutzer per Formular bestätigt (Bezug: `docs/paritaet/review-P2-vertraege.md`, OFFENE-ENTSCHEIDUNGEN Nr. 20, 22, 24–30).

## Beschlossen

1. **Alt-SDK-Header (Nr. 20, H11):** Befristeter Docker-Kompatibilitätsadapter übersetzt v1 auf den neuen Vertrag. Ausdrückliche, begrenzte Ausnahme zu ADR 0001. Der Kern bekommt keinen Altdecoder. Laufzeit, Vertrauensgrenze, formularbezogene Schlüssel und Abschaltung sind in den Verträgen festzulegen.
2. **Symmetrische Zusatzhülle (Nr. 22, H05):** Eigener Transportvertrag (zusätzliche symmetrische Hülle auf dem Übertragungsweg). Muss in `contracts/crypto/` und `contracts/ingest/` neu spezifiziert werden; `sym-v2` als Speicherprofil bleibt bis dahin gesperrt.
3. **Rechte (Nr. 24, H02):** Jede Funktion ist einzeln berechtigbar. Gruppen (Rechtegruppen) können vom Nutzer selbst angelegt und geändert werden. Keine feste Rollenmatrix; Admin/Betreuer/Kunde aus ADR 0001 sind Voreinstellungen/Vorlagen. Der Vertrag muss Kunden-/Formularscope, Widerruf und Gruppenänderung regeln.
4. **Wiederanlauf/Resend (Nr. 25, H07/H09):** Klartext und Schlüssel nie dauerhaft auf dem Server. Fortsetzung nach Warten/Crash nur durch bewusste menschliche Freigabe. Resend nur unverändert und an das Original gebunden; Bearbeiten ist ein separater Neuversand.
5. **Gemeinsame Alt-Hosts (Nr. 26, H04):** Ansichtsdomain pro Formular eindeutig; gemeinsame API-Hosts über das signierte Formular auflösen.
6. **Altstatistik (Nr. 27, M04):** Gesamter Altbestand wird übernommen; die 13-Monats-Frist gilt für neu erhobene Daten. Siehe Hinweis unten.
7. **Validierung (Nr. 29, M02):** Typisierte Validierung für neue Formulare; Altformulare laufen über einen Adapter mit altem Verhalten.
8. **OAuth/MCP (Nr. 30, M05):** Bestehende Credentials werden bei der Migration übernommen (kein Neufreigabe-Zwang).

## Weiterhin offen

- Nr. 21: Zahlenwerte (Lockout, Rate-Limits, Laufzeiten, Dauer der Signaturausnahme) wurden nicht bestätigt, nur die Übernahme der Tokens.
- Nr. 29 Rest: Scannerausfall (503 oder wie bisher durchlassen) und Statuscodes 418/424 wurden nicht gewählt; bis zur Klärung gilt Altverhalten, Verträge als OFFEN markieren.
- Nr. 28: Kunden-/Schlüsselschnitt der Altgenerationen, nicht migrierbare Zeilen.

## Hinweise zur Umsetzung

- Zu 6: Der Altbestand enthält laut Review Pseudonyme/Metadaten; ADR 0003 verlangt 13 Monate pseudonym und kein IP-Speichern. Beim Import ist zu prüfen, ob Altdaten IP-Bezug enthalten; in dem Fall nicht übernehmen, bis der Nutzer entscheidet. Das Mapping muss die Herkunft „legacy“ ausweisen.
- Zu 8: Übernahme setzt eine Migration der Token-/Grant-/Refreshdaten (`contracts/data/migration-mapping.md`) voraus; Hash-/Geheimnisformat der Altdaten ist zu prüfen, Secrets werden nie ins Repository kopiert.
