# ADR 0005: Entscheidungen nach Vertragsrunde 3

Stand: 29.10.2026. Vom Nutzer per Formular bestätigt (Bezug: `docs/handoffs/vertragsrunde-3-offen.md`, D1–D7).

## Beschlossen

1. **D1 Domain und Release:** Eine Domain folgt einem neuen Release nicht automatisch. Umstellung erfolgt bewusst (bestätigte Domainänderung, optional im Dialog der Veröffentlichung). Zusatzanforderung des Nutzers: Die Release-Bindung muss auch an Zugriffsserver bzw. Zugriffsadressen (API-/Ingest-Hosts) koppelbar sein, nicht nur an Ansichtsdomains. Die Verträge (`domain_bindings`, `api_hosts`, `domains-proxy.md`) sind entsprechend zu erweitern; die Form der Kopplung ist VORGESCHLAGEN zu spezifizieren.
2. **D2 Adapter:** Eigene Signieridentität (Ed25519 plus mTLS-Pin, Register `adapter_signers`). Aktivierungsrecht und Laufzeit bleiben offen (Vorschlag `system.manage` mit menschlicher Bestätigung; 90 Tage nur Vorschlag). Der Signaturtext `KUBUS-ADAPTER-SIGN-1` braucht ein Kryptoreview.
3. **D3 Transporthülle:** Pro Formular wählbar (`off` Standard, `required` echte Wahl, `offered` auf Wunsch). Schlüsselausgabe über `key.manage` im Formularscope. Provider bleibt Betriebsentscheidung (D9).
4. **D4 OAuth/MCP-Altcredentials:** Neuanmeldung. Das ersetzt ADR 0004 Nr. 8 (Token-Übernahme); die später getroffene Wahl gilt. Konsequenz: `resource_binding legacy-unbound` und Tokenübernahme in Migrationsmapping/Datenmodell sind hinfällig und aus den Verträgen zu entfernen; alle MCP-/OAuth-Clients melden sich nach dem Cutover neu an.
5. **D6 Scanner:** Altverhalten gilt weiter (Scannerfehler lässt durch, Statuscodes 418/424 des Bewerbungshandlers bleiben). Verschärfung bleibt unbeschlossen.
6. **D7 Altstatistik:** Der Altbestand wird komplett übernommen. Hinweis zur Spannung: ADR 0003 schließt IP-Speicherung für neue Statistik aus, und IP-Adressen gelten als personenbezogen. Falls der Altbestand IP-Werte enthält, gilt die Übernahme als ausdrücklich gewollt, ist aber vor dem Import am echten Dump zu prüfen und im Importbericht mit Herkunft `legacy` zu kennzeichnen (Schutz: Zugriff beschränken, keine Auswertung auf Personenebene). Die 13-Monats-Frist gilt für neu erhobene Daten.

## Weiterhin offen

- **D5 Replay nach gelöschtem Ergebnis:** Nutzer hat nachgefragt, warum es dazu käme. Erklärung: Ein Absender (z. B. Browser mit Netzwerkabbruch) wiederholt dieselbe Einsendung mit demselben Idempotenzschlüssel, nachdem das Ergebnis aus Datenschutzgründen bereits gelöscht wurde. Der Server muss dann ablehnen oder neutral antworten, ohne eine zweite Einsendung anzulegen. Entscheidung noch nicht getroffen; bis dahin Vorschlag 409.
- **D8** Rewrap-Vertrauen, **D9** Secretprovider, **D10** Sandbox (P6-S), **D11** Zahlenwerte/Altschlüsselschnitt: nicht entschieden.
