# ADR 0038: Übernahme des Alt-Kundenschlüssels im Browser

11.11.2026. Status: umgesetzt (Agent), Nutzerprüfung mit echtem Altschlüssel offen.
Todolino D68077D4-42CC-4D61-B973-AF88264216D8. SPDX-License-Identifier: AGPL-3.0-only.

## Kontext

Der Altimport (ADR 0014, P9) überträgt Einsendungen als `:2/hpke`-Pakete bytegleich und
die öffentlichen Altschlüsselgenerationen (`datenschluessel` → `customer_key_generations`),
aber keine Zugangshüllen: alte `datenschluesselZugang`-Zeilen sind an alte Kontoschlüssel
versiegelt, die im neuen System nicht existieren. Nach dem Import kann deshalb niemand die
importierten Pakete im Normalbetrieb öffnen; nur die lokale Probe (ADR 0033) funktioniert.
Nutzerentscheidung: Der Alt-Kundenschlüssel wird **im Browser** übernommen; vorhanden sind der
alte private X25519-Schlüssel und der alte Recovery-Code.

## Entscheidung

**A – Übernahme mit privatem Schlüssel.** Konto → Sicherheit → Erweitert, je Kunde Abschnitt
„Altschlüssel aus dem Umstieg übernehmen“ (`pwa/src/routes/admin/LegacyKeyAdoption.svelte`,
erreichbar über `/account?legacy=1`, verlinkt aus Umstieg Schritt „Prüfung“ und „Umschaltung“
sowie aus der Sperrmeldung der Einsendungsliste). Ablauf (`keyring.adoptLegacyKey`,
`lib/crypto/legacyAdoption.ts`):

1. Eingabe 32 Byte als Base64url, Standard-Base64 (kanonische Endbits) oder 64 Hex; direkt in
   ein `Uint8Array` dekodiert; Feld sofort geleert (`type=password`, `autocomplete=off`,
   `spellcheck=false`).
2. Browser leitet den öffentlichen X25519-Schlüssel und `kid` lokal ab und verlangt exakte
   Gleichheit (kid **und** 32-Byte-Public-Key) mit einer vom Server gelisteten Generation
   (`GET /tenants/{t}/key-rotation`: aktive und auslaufende Generation, Recht `key.manage`).
3. Kontoschlüssel muss lokal entsperrt sein; der Server muss denselben Kontoschlüssel nennen
   (`/me/key-bundle`), sonst Abbruch ohne Versiegeln.
4. Versiegelung mit dem normalen Zugangsformat (`keys.ts grantAccess`: HPKE, info
   `kubus-datenzugang v1`, AAD = kid) an den **eigenen**, lokal abgeleiteten Kontoschlüssel.
5. Upload nur `{kid,enc,sealed}` über den vorhandenen Selbstzugang
   `PUT /tenants/{t}/key-access/{eigeneKontoId}`.
6. Eingabepuffer in jedem Pfad mit `fill(0)` überschrieben; die Kopie im Schlüsselbund folgt
   den üblichen Sperr-/Leerlaufregeln (nur RAM).

Eine Probeentschlüsselung eines importierten Pakets ist nicht nötig: Gleichheit des abgeleiteten
öffentlichen Schlüssels beweist den passenden privaten Schlüssel (X25519-Clamping-Varianten sind
funktional identisch); die lokale Probe aus ADR 0033 bleibt zusätzlich verfügbar.

**Kein neuer Endpunkt.** Geprüft am Code (`KeyManagementRoutes.swift`, PUT `key-access`): Für
das eigene Konto verlangt der Weg **keinen** vorhandenen Zugang („Selbstreparatur“), wohl aber
Recht `key.manage` (vor und in der Transaktion), frische Anmeldung, CSRF (mutation), Generation
`active`/`retiring` des Kunden, aktives Zielkonto mit Kontoschlüssel und Recht im Kunden;
Transaktion mit Kundensperre und `FOR UPDATE`, Audit `key.access.repair`. Fremde Konten erhalten
Zugang nur von einem Konto mit eigenem Zugang; fremder Zugang wird nie ersetzt. Ein zusätzlicher
„nur ohne vorhandenen Zugang“-Endpunkt hätte keine Fläche verkleinert, weil der breitere
Selbstzugang ohnehin besteht. Eine Wiederholung derselben Anfrage ersetzt nur die eigene Zeile
(kein Vervielfachen, jede Ausführung auditiert).

**B – Alt-Recovery-Code: umgesetzt.** Formatvergleich:

|                | Alt (bvk)                                                                                                                                                         | Neu                                                                                                                                          |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Tabelle        | `datenschluesselRecovery(kid char16 PK, salt vb32, iterationen int, iv vb12, wrap vb48, erstelltAm int)` – `db/migrations/034-schluessel-infrastruktur.sql:50–58` | `data_key_recovery(customer_id, kid, kdf_name, salt 32, iterations, iv 12, wrapped_key 48, created_at)` – `backend/db/schema-p3.sql:371–383` |
| Normalisierung | `toUpperCase().replace(/[-\s]/g,'')` – `www/src/krypto/schluessel-seite.js:66–70`, angewandt beim Wickeln (`:372`, `:721`) und Öffnen (`:1003`)                   | `normalizeRecovery`, identisch – `pwa/src/lib/crypto/keys.ts:112–116`                                                                        |
| KDF            | PBKDF2-HMAC-SHA256, UTF-8 der Passphrase, Salt 32, 600000, 256 Bit, Mindestlänge 24 – `schluessel-modell.js:121–134`                                              | identisch – `keys.ts kekRecovery`                                                                                                            |
| Hülle          | AES-256-GCM, IV 12, Tag 128, AAD = UTF-8(kid), Klartext sk_D 32 → 48 Byte – `schluessel-modell.js:136–147`                                                        | identisch – `keys.ts wrapRecovery/openRecovery` (prüft zusätzlich kid des Ergebnisses)                                                       |
| kid            | `SHA-256(pk)[0..8]` hex – `www/src/krypto/paket-v2.js:25–28`                                                                                                      | `packageV2.ts keyId`, identisch                                                                                                              |

Der Importer (`FormMigration/Transform.swift` Fall `datenschluesselRecovery`, Tabelle nach
`datenschluessel`, Cursor `kid`) kopiert Salt/IV/Wrap bytegleich, `kdf_name`
`pbkdf2-hmac-sha256`, nur bei `iterationen = 600000`, nur wenn der kid im Plan genau einem
Kunden zugeordnet ist und dessen Generation im selben Lauf importiert wurde; eine bereits im
neuen System geschriebene Recovery wird nie ersetzt. Ledger/HMAC wie bei allen Tabellen,
Wiederholung idempotent, Manipulation des Ziels → Konflikt. Fehlt die Quelltabelle, wird sie
übersprungen. Nicht passende Zeilen werden Prüffälle, nie geraten. Danach öffnet der Nutzer den
Schlüssel mit dem **alten** Code über das vorhandene „Mit Recovery-Code öffnen“ (Audit
`key.recovery.read`) und legt mit „Meinen Zugang aus dem Recovery-Code erneuern“ den eigenen
Zugang an (gleicher Selbstzugang wie A).

**Neuer Wiederherstellungsweg.** Für eine bestehende Generation gibt es keinen Endpunkt zum
Ersetzen der Recovery-Hülle; ein solcher wird bewusst nicht ergänzt. Empfohlen und in der
Oberfläche genannt wird die Rotation (vorhandene Funktion): neue Generation, neue Recovery
(bzw. automatische Recovery aus dem Konto-Recovery), Umhängen aller Objekte, danach Entfernen der
alten Generation samt alter Recovery. Bis dahin bleibt ein importierter alter Code gültig.

## Sicherheit

- Zero-Knowledge bleibt: privater Schlüssel nur im Browser-RAM, kein Logging, keine URL, kein
  Storage, keine Fehlermeldung mit Eingabe; Server erhält nur HPKE-Hülle.
- Der Server kann den Besitz des privaten Schlüssels nicht prüfen. Sicherheit beruht auf Recht
  `key.manage`, frischer Anmeldung, CSRF, nur eigenem Zugang, Audit und der Browserprüfung gegen
  die öffentliche Identität. Eine unbrauchbare eigene Hülle schadet nur dem eigenen Zugang.
- Fehlermeldung „passt zu keiner importierten Generation“ unterscheidet nicht zwischen falschem
  Schlüssel und abweichendem öffentlichen Schlüssel.
- JavaScript-Strings des Eingabefelds sind nicht garantiert physisch löschbar (wie ADR 0033).

## Restrisiken und offene Grenzen

- Vorbestehend: Selbstzugang akzeptiert eine beliebige eigene Hülle. Dadurch kann ein Konto mit
  `key.manage` ohne echten Schlüssel als „handlungsfähige Identität“ zählen
  (`capableIdentities` prüft nur Zeilen) und z. B. Entzüge auslösen. Härtung (z. B. getrennter
  Erstzugang nur ohne vorhandenen Zugang, Konfliktsperre) ist eine eigene Vertragsentscheidung.
- `GET key-rotation` liefert höchstens eine auslaufende Generation; mehrere importierte
  auslaufende Generationen eines Kunden sind über die Oberfläche nur teilweise übernehmbar.
- „Mit Recovery-Code öffnen“ nutzt die aktive Generation; Recovery einer importierten
  auslaufenden Generation bräuchte eine kid-Auswahl in der Oberfläche.
- Nicht mit echtem Altschlüssel geprüft (nur synthetische Testvektoren).
- Review B3: Importierte Alt-Recovery-Hüllen sind für jedes Konto mit `key.manage` abrufbar (`GET key-recovery`, nur der Abruf wird auditiert). Ein Offline-Ratean­griff ist möglich; seine Stärke hängt am Alt-Code. Empfehlung: Schlüssel nach der Übernahme rotieren.
