# Herkunft der Vektoren

Alle Schlüssel in diesen Fixtures sind öffentliches Testmaterial und niemals
produktiv zu verwenden. Synthetische Daten enthalten keinerlei Kundendaten.

- `rfc9180.json`: unveränderte lesende Kopie des im Vertrag bezeichneten
  `../form-backend_bvk/tests/fixtures/hpke-rfc9180-base-x25519-sha256-aes256gcm.json`.
  SHA-256 dieser lokalen gefilterten Datei:
  `46e3f79e4aa537339b138fa3cfeb074493be1cb17f24361c874443e324d2ad28`.
  Das enthaltene `_quelle` bleibt unverändert. Upstream: CFRG HPKE Testvektoren,
  Commit `5f503c564da00b0687b3de75f1dfbdfc4079ad31`, Filter mode=0,
  kem=32/kdf=1/aead=2. Der im Vertrag angegebene SHA-256 der vollständigen
  Upstreamdatei ist `61fc662f01996cd06d713dacf5e133167bd309a1f329442d53f1e21a47b3ede6`.
  Dieser Upstreamhash konnte wegen gesperrter DNS-Auflösung nicht neu geprüft
  werden. Lokaler Filterhash und Originaldateihash sind unterschiedliche Werte.
  Quelle: https://github.com/cfrg/draft-irtf-cfrg-hpke/tree/5f503c564da00b0687b3de75f1dfbdfc4079ad31
  RFC: https://www.rfc-editor.org/rfc/rfc9180.html
  Quellen-/Lizenzhinweise des RFC: Copyright (c) 2022 IETF Trust and the persons
  identified as the document authors. All rights reserved. RFC 9180 unterliegt
  BCP 78 und den IETF Trust Legal Provisions: https://trustee.ietf.org/license-info
  Es wurde kein Legacy-Implementierungscode übernommen.
- `synthetic.json`: unabhängig durch den neuen PHP-8.5/ext-sodium-Harness erzeugt.
  SHA-256: `300e216da48d19c471de643f6bcef2e132615e735916fe833154edaab7f20ead`.
  Drei hpke-Pakete (leer, UTF-8, binär), sym-Leertextpaket und sechs
  PHP-Kanonisierungs-/Ed25519-Referenzen mit festen öffentlichen Testschlüsseln.
- `ed25519-strict.json`: 15 Ed25519-Negativ-/Positivvektoren (S=L, S=L+s, S=0xff.., Public Key
  kleiner Ordnung/nichtkanonisch, R kleiner Ordnung/nichtkanonisch, 63/65-Byte-Signatur, 31/33-Byte-Key,
  Positivfall). Erzeugt mit `php sdk/php/tests/form_crypto.php --generate-ed25519`; das Skript bricht ab,
  wenn libsodium (`sodium_crypto_sign_verify_detached`) von `expected` abweicht. Swift prüft denselben
  Satz über `Ed25519Strict`.
- `alt-sdk.json`: Vektoren aus dem ALTCODE (F6). `sdk/php/tests/alt_sdk_vectors.php` liest lesend
  `form-backend_bvk/providers/Clients/BackendV2.php` (`signaturtext`, `bodyHash`) und
  `providers/AnfrageSignatur.php` (`bodyHash`, `signaturtext`, `sortiereRekursiv`, `dateien`), wertet die
  Klassen unverändert aus (nur `require_once`/`declare` entfernt, keine Konfiguration, keine Secrets, keine DB),
  prüft SDK = Backend und schreibt Eingaben/Kanonik/Texte/Signaturen. Eingaben synthetisch, Wegwerfschlüssel aus
  festem öffentlichem Seed. Enthält absichtlich Grenzfälle (Pfadformen `host:80/x`, `0`, `//host`, BOM-Schlüssel,
  Tiefe 511/512, Ganzzahlgrenzen).
- `swift-output.json` ist KEIN Fixture mehr: der Swift-Test schreibt nach `$FORM_SWIFT_EXPORT`
  (`run-tests.sh`: `backend/.build/swift-output.json`), danach prüft PHP. Der Quellbaum bleibt unverändert.

Eigene Test-/Harnessdateien: SPDX-License-Identifier: AGPL-3.0-only.
