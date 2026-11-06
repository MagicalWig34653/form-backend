# P3-A FormCrypto

SPDX-License-Identifier: AGPL-3.0-only.

Eigenständiges Swift-Paket mit CryptoKit; keine externen Abhängigkeiten, kein
Server, keine Persistenz. Der aktuelle Build ist für macOS ab 13 konfiguriert;
Linux/swift-crypto und die endgültige Backend-Targetstruktur sind nicht abgenommen.

Aus dem Repositorywurzelverzeichnis:

```sh
sh backend/run-tests.sh
```

Der Runner führt `swift test` und anschließend den PHP-Interoptest aus. Er legt
Compiler-Caches unter `.build/` ab. Die Option `--build-system native` umgeht im
aktuellen File-Provider-Arbeitsverzeichnis einen FinderInfo-/Codesignfehler des
Swift-6.4-Standardbuilders; native ist als deprecated markiert.

Exakte stdout/stderr-Ausgaben: `swift-test.log`, `../sdk/php/tests/php-test.log`;
Exitcodes: `test-exit-codes.txt`. Swift schreibt frische zufällige Pakete und
Signaturen nach `Tests/FormCryptoTests/Fixtures/swift-output.json`, PHP öffnet
und prüft sie anschließend. PHP ist deshalb nach Swift auszuführen.

Öffentliche synthetische Referenzbytes lassen sich ausdrücklich mit
`php sdk/php/tests/form_crypto.php --generate` neu erzeugen (aus Repo-Wurzel).
Das ist keine normale Testausführung: Es überschreibt `synthetic.json`.
Referenzwerte stammen aus PHP/ext-sodium, nicht aus der Swift-Implementierung.
Fixtureänderungen müssen geprüft werden. Alle privaten Fixturewerte sind
öffentliches Testmaterial. Deterministische CEKs/Nonces werden ausschließlich
im Test wiederverwendet und dürfen niemals produktiv eingesetzt werden.
Produktions-Writer akzeptieren keine deterministischen Testparameter.

`PackageV2.seal` erzeugt ausschließlich hpke-Wraps. `PackageV2.open` ist eine
Client-/Testprimitive, keine serverseitige Datenzugriffsberechtigung. Bestehende
sym-Wraps können gelesen werden; neue sym-Speicherprofile, Transporthülle,
Umhängen, Recovery, Provisionierungs-/Rotationszustand und Autorisierung sind
kein Teil dieser Bibliothek.

`PHPValue` bildet die bereits vom PHP-Parser aufgelöste Arraystruktur ab.
Arraykeys sind ihre PHP-Stringdarstellung; Reihenfolge und lückenhafte Indizes
bleiben explizit. Doppelte Schlüssel, ungültiges UTF-8 und Float-Eingaben werden
abgelehnt. Insbesondere gibt es keinen generischen JSON→PHP-Parser und keine
stillschweigende Typkonvertierung. `SignedFile`/`FileField` erhalten typisierte
Metadaten und optionale Rohbytes; HTTP-Uploadparser, PHP-Casts beliebiger Werte
und Dateizugriffsrechte gehören in einen gesondert geprüften Adapter. `nil`
entspricht dem vertraglichen `sha256=null`; das validiert keinen Upload.

Ed25519 unterstützt 32-Byte-Seed und geprüftes libsodium-Secret-Key-Layout
`seed[32] || publicKey[32]`. CryptoKit randomisiert Signaturen; PHP-Festsignaturen
werden in Swift verifiziert, Swift-Signaturen in PHP. Kanonische JSON-Bytes,
Signaturtext und HPKE-Paketbytes müssen bytegleich sein, Signaturbytes nicht.
Siehe [Apple-Dokumentation](https://developer.apple.com/documentation/cryptokit/curve25519/signing/privatekey/signature(for:)).

Schlüsselmaterial bleibt im RAM. Swift/CryptoKit garantiert hier keine sichere
Löschung sämtlicher Data-/Runtimekopien. Keine Ausgabe von produktivem
Schlüsselmaterial oder Klartext; Fixtures enthalten ausschließlich öffentliche
synthetische Werte. Weitere Grenzen und vollständiger Prüfstand stehen in
`../docs/handoffs/P3-A.md`.

### Systemeinstellungen (P11-B)

`/settings` in der PWA verwaltet registrierte Systemeinstellungen mit dem neuen
Systemrecht `system.settings` und frischer Anmeldung. Explizite ENV-Werte sperren
den jeweiligen Eintrag; sonst gilt DB vor Standard. Quellen und Neustartpflicht
stehen an jedem Feld. MCP nutzt `FORM_MCP_TOKEN_RATE_LIMIT` (Standard 60/min je
Token); Webhookquoten und MCP-Limit wirken live. Bootstrap bleibt ausschließlich
ENV. API-/Revisionsvertrag und registrierter Umfang: ADR 0021
(`docs/decisions/0021-systemeinstellungen.md`). Bestehende Installationen benötigen
einen geprüften Katalogupgrade und explizite Rechtezuweisung; Baselinechecksummen
nicht überschreiben. Siehe `db/upgrades/0021-system-settings.sql` und Handoff P11-B.
