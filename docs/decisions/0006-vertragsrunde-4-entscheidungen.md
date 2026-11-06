# ADR 0006: Entscheidungen nach Vertragsrunde 4

Stand: 30.10.2026. Vom Nutzer per Formular bestätigt (Bezug: `docs/handoffs/vertragsrunde-4-offen.md`, `docs/handoffs/vertragsrunde-3-offen.md`).

## Beschlossen

1. **A2 Alt-Adapter:** Der Adapter wird nicht aktiviert; Kunden stellen vor dem Cutover auf das v2-SDK um. Das ist faktisch SDK-Rollout (Alternative B aus ADR 0004 Nr. 1) statt befristetem Adapter. Folge: ADR 0004 Nr. 1 (befristeter Adapter) und ADR 0005 Nr. 2 (Adapter-Signieridentität) sind bis auf Weiteres nicht wirksam. `contracts/ingest/legacy-adapter.md`, `adapter_signers`, `adapter_replays`, `legacy_adapter_bindings` bleiben als deaktivierter, nicht aktivierbarer Entwurf bestehen und werden nicht implementiert, bis der Nutzer anders entscheidet. Der Cutover setzt voraus, dass alle produktiven Kundenanbindungen auf v2 laufen (Cutover-Voraussetzung, in P9 zu prüfen).
2. **T3 Transporthülle:** Schutzziel nur Anfragen. Antworten werden nicht authentisiert oder verschlüsselt; `offered` bietet keinen Downgradeschutz, `required` erzwingt die Hülle für Anfragen.
3. **D4-Rückfrage:** Auch von Hand erzeugte Alt-MCP-Tokens (`mcp_tokens`) werden nicht übernommen; alle MCP-/OAuth-Zugänge werden neu eingerichtet.
4. **D5 Replay nach Löschung:** Antwort 409 (`idempotency-result-deleted`), keine zweite Einsendung. Fristen bleiben VORGESCHLAGEN und werden mit den Zahlenwerten (Nr. 21) bestätigt.

## Hinweis

Punkt 1 widerspricht dem früheren Beschluss ADR 0004 Nr. 1 und ADR 0005 Nr. 2. Die spätere Wahl gilt; bei Bedarf wieder aufmachen.

## Weiterhin offen

D8 (Rewrap-Vertrauen), D9 (Secretprovider), D10 (Sandbox, P6-S), D11 (Zahlenwerte Nr. 21, Altschlüsselschnitt Nr. 28), D2-Rest hinfällig solange Adapter inaktiv.

## Nachtrag (30.10.2026, zweites Formular)

5. **D8 Rewrap/Hold:** Vor dem Ersetzen wird eine wiederherstellbare Quelle erhalten (Konsistenz-/Recovery-Vertrag); kein reines Clientvertrauen.
6. **D9 Secrets:** MFA- und Integrationssecrets liegen verschlüsselt in der Datenbank, Hauptschlüssel aus der Betriebsumgebung (nie im Repository). Der `digest-hmac`-Schlüssel folgt demselben Provider. Ein externer Secret-Store bleibt als spätere Option hinter einer Schnittstelle.
7. **D11 Zahlenwerte:** Alle als VORGESCHLAGEN markierten Werte (Lockout, Backoff, Rate-Limits, Sitzungs-/Tokenlaufzeiten, Signaturausnahme, Replay-Fristen) gelten als bestätigt und sind konfigurierbar. Offen bleibt der Kunden-/Altschlüsselschnitt (Nr. 28).
8. **Vorgehen:** P4 wird gestartet (Backend/PWA-Grundaufbau), P3-C Passkey parallel.

Weiterhin offen: D10 (Sandbox, P6-S), Nr. 28.

## Nachtrag (30.10.2026, drittes Formular)

9. **Nr. 28 Altschlüssel:** Altdaten werden dem Kunden ihres Formulars zugeordnet; der alte Schlüssel bleibt zunächst nutzbar, berechtigte Nutzer wickeln im Browser auf den Kundenschlüssel um (Rewrap, mit Sicherung der Quelle gemäß D8). Details des Importkundenschnitts weiter im Migrationsmapping zu spezifizieren.
10. **D10 Sandbox:** Skriptsprache für Skriptknoten ist JavaScript in Isolation (kein Netz-/Dateizugriff, Quoten, eigenes Review in P6-S). Engine ohne Skripte bleibt zuerst.
11. **Berechtigung:** In `~/.claude/settings.json` (`autoMode.allow`) wurde eine Regel für SwiftPM-/npm-Downloads durch Subagenten im Projekt ergänzt (nicht im Repo; bei neuer Maschine erneut setzen).

## Nachtrag (30.10.2026, Passkeys)

12. **Passkey-Verifikation (P3-C):** Eigene Verifikation mit swift-crypto (ES256, RS256, EdDSA; PEM/SPKI unverändert lesen; Origin strikt; Challenge einmalig, sessiongebunden, 120 s; Zählerregel `(alt==0 && neu==0) || neu>alt`). `webauthn-swift` wird nicht verwendet. Registrierung neuer Passkeys: eigener minimaler CBOR-Parser, in einem späteren Paket zu spezifizieren und unabhängig zu reviewen. Vertragslücken zu schließen: `passkeys.user_handle` (UTF-8-Bytes des UUID-Textes), fester Wert `public_key_encoding = pem-spki`, RSA-Mindestlänge prüfen. Echte-Authenticator- und PRF-Browsertests bleiben Abnahmepflicht.
