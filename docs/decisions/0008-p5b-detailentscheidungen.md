# ADR 0008: P5-B Detailentscheidungen (30.10.2026)

Nutzerentscheidungen zu `docs/handoffs/P5-B-vertrag-offen.md`:

- **F4** Argon2id-Abhängigkeit ist erlaubt (Lizenz vor Aufnahme prüfen und in der Übergabe vermerken; Format der Altdaten-Hashes weiter per Dumpprüfung klären).
- **F5** Serverschlüssel: 32 Byte aus Betriebsgeheimnis (Datei/Umgebung außerhalb DB und Repo), AEAD via swift-crypto, hinter einem Protokoll gekapselt (D9 damit für P5-B beantwortet).
- **F9** Passkey-Code als Kopie nach `FormAuth` mit Herkunftsvermerk, PoC unverändert, Vektoren mitkopiert, Paritätstest.
- **F1** Kanonisierung/Hash: RFC 8785 (JCS) + SHA-256, nur ganze Zahlen, ein Verfahren für alle Hashes.

Weiter offen (nicht B1-blockierend): F2, F3, F8 (B2), F6 (B1 verlangt den zweiten Faktor immer), F7 (B1 folgt dem Vorschlag 404 ohne Grant / 403 bei fehlendem Aktionsrecht, bis entschieden).
