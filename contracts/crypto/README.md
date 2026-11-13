# P2-2 – Verbindliche Kryptografieverträge

Stand: 26.10.2026 · SPDX: AGPL-3.0-only.

Dieses Paket spezifiziert die durch ADR 0001–0004 beschlossenen Verfahren und die statisch belegten Kompatibilitätsbytes. **MUSS**, **DARF NICHT** und **NUR** sind verbindlich. **OFFEN** bezeichnet eine Implementierungssperre für den betroffenen Teil, keine stillschweigende Voreinstellung. Die Verträge sind keine Implementierung oder kryptografische Abnahme.

| Vertrag | Inhalt |
| --- | --- |
| [paket-v2.md](paket-v2.md) | Paketbytes, HPKE-Suite, CEK-Wraps, `kid` |
| [schluessel.md](schluessel.md) | Kundengenerationen, Kontoschlüssel, PRF, Zugänge, Recovery, Rotation |
| [migration.md](migration.md) | Ausschließlich offline verwendbare Altleseverfahren und Cutover-Grenzen |
| [signatur.md](signatur.md) | Ed25519, PHP-Kanonisierung, Provisionierung |
| [test-vectors.md](test-vectors.md) | Synthetischer Erzeugungs- und Abnahmeplan, keine erzeugten Vektoren |
| [HANDOFF.md](HANDOFF.md) | Prüfstand, offene Prüfaufträge und Fortsetzung |

## Geltung und Quellenrang

ADR [0001](../../docs/decisions/0001-grundentscheidungen-p1.md), [0002](../../docs/decisions/0002-sicherheit-und-cutover.md), [0003](../../docs/decisions/0003-produkt-und-betrieb.md) haben Vorrang vor dem Altverhalten in [D](../../docs/paritaet/D-krypto-protokolle.md). [review-D](../../docs/paritaet/review-D.md), insbesondere F1–F4 und O1, korrigiert D. Weitere Grundlagen: [SICHERHEIT-UND-DATEN](../../docs/SICHERHEIT-UND-DATEN.md), [PARITAET](../../docs/PARITAET.md). `bvk:` bezeichnet ausschließlich lesend untersuchte Dateien in `../form-backend_bvk/`; alle Altcodebelege gelten für den am 26.10.2026 gelesenen Stand.

Neue Formulardaten werden NUR als `KUBUS-AEAD:2` gespeichert und zur Laufzeit gelesen. `:1`, CBC, `MFAKEYv1` gehören NUR ins Migrationswerkzeug; rohe v1-Header-Schlüssel sind zusätzlich ausschließlich im befristeten Docker-Adapter nach ADR 0004 zulässig; kein Laufzeitfallback, auch nicht bei fehlender Generation. MFA-Secrets sind keine Formularpakete: Ihr künftiges serverseitig entschlüsselbares Speicherformat ist OFFEN, siehe migration.md. Es darf nicht aus dem Formularpaketvertrag abgeleitet werden.

ADR 0004 H05 entscheidet K04: zusätzliche **eigene Transporthülle**, spezifiziert
als VORGESCHLAGENER technischer Wirevertrag in [transport.md](transport.md) und
Ingest-OpenAPI. `sym-v2` als auswählbares Speicherprofil bleibt gesperrt;
`wrap=sym` als bestehender CEK-Wrap/Nachschutz ist unabhängig davon.
Neue Speicherung nutzt hpke-v2. TLS und Ed25519 bleiben erforderlich.
Die begrenzte Ausnahme K12 für alte Header steht in
[legacy-adapter.md](../ingest/legacy-adapter.md); kein Altdecoder im Kern.
Originalnachweis für unveränderten Resend und Freigabe nach Warten/Crash:
[wiederanlauf.md](../flow/wiederanlauf.md). Technische Nachweise sind noch abzunehmen.

## Gemeinsames Fehlerverhalten

- Format-, Base64-, Längen-, Versions-, Schlüsselzuordnungs-, KDF- und Authentifizierungsfehler MÜSSEN den betroffenen Vorgang ohne Klartextausgabe abbrechen. Ein gültiger Parserbefund ist kein Nachweis eines gültigen Tags oder fachlicher Autorisierung.
- Unbekannte Version/Suite/Wrap-Art DARF NICHT durch Probieren älterer Verfahren akzeptiert werden. Fehlende, mehrere aktive oder inkonsistente Kundengenerationen sperren neue verschlüsselte Speicherung; kein `:1`- oder Klartextfallback (`bvk:providers/Anfrageverschluesselung.php:54–135`, verschärft durch ADR 0001).
- Nach fehlgeschlagener CEK-/Zugangs-/Recovery-Entschlüsselung DARF kein Teilergebnis persistiert werden. Nach GCM-Fehler DARF kein Klartext verwendet werden. Fehler sind keine leeren Nutzdaten: ein erfolgreich authentifizierter leerer Klartext bleibt zulässig.
- Änderungen an Generationen, Zugängen und Paketen MÜSSEN atomar sein; Konflikte nach erneutem Lesen unter Sperre prüfen. Fehler hinterlassen den vorherigen vollständigen Zustand. Keine stille Teilrotation oder Überschreibung einer inzwischen veränderten Zeile.
- Rechteprüfung und Kundenzuordnung gelten für REST, MCP und UI gemeinsam. Ein passendes `kid` oder ein entschlüsselbarer Wrap allein erteilt keine Berechtigung. Schlüsselzwecke Signatur, Transport, Daten, Konto und MFA bleiben getrennt.
- Gewöhnliche Logs/Audit enthalten Vorgang, Kunden-/Objektreferenz, `kid`, Ergebnis und sichere Fehlerklasse, niemals Schlüssel, PRF-Ausgabe, Passphrase, MFA-Secret oder Nutzdaten. Kein Klartext für automatische Retries; Resend nur bewusst durch berechtigte Benutzer, ADR 0002.
- Regulär fehlgeschlagene v2-Signaturprüfung ergibt 403 gemäß Ingest-Vertrag. Konflikte beim Umhängen sind im Altcode 409. **OFFEN K05:** konkrete neue HTTP-/MCP-Fehlercodes für Parser-, KDF-, Generations- und Persistenzfehler mit P2-1/P2-5 abstimmen; diese Dokumente erfinden keine API-Fehlercodes. Historische JSON-Exceptions dürfen nicht pauschal als nachgewiesenes HTTP 500 bezeichnet werden (review-D F3).

## Abnahme

Bytegleichheit und Fehlerverhalten sind anhand des Plans in test-vectors.md in PHP, Swift und Browser zu prüfen. Änderungen an signierten Bytes oder Kryptokonstanten benötigen einen expliziten neuen Vertrag; keine „Bereinigung“ während der Portierung. Offene Prüfaufträge und unabhängiges Review müssen vor Freigabe der jeweils betroffenen Implementierung abgeschlossen sein.
