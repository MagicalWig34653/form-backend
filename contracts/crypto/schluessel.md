# Schlüssel, Recovery und Generationen

SPDX: AGPL-3.0-only. Grundlage: ADR 0001–0003, review-D S16–S19/F4; `bvk:www/src/krypto/schluessel-modell.js:39–163`, `prf.js:33–91`, `schluessel-seite.js:66–69`, `paket-v2.js:74–215`, `providers/Schluesselverwaltung.php`, `Umhaengen.php`, `Entsperrdaten.php:26–41`.

## Zuständigkeit und Datensätze

Jeder Kunde hat eigene X25519-Datenschlüsselgenerationen `(sk_D,pk_D)`, identifiziert durch das abgeleitete `kid` aus paket-v2.md. Formulare des Kunden verwenden dessen aktive Generation; pro Formular gibt es keinen neuen Datenschlüssel. `sk_D` entsteht im berechtigten Browser und gelangt NUR als verschlüsselter Zugang/Recovery-Wrap zum Server. Der Server hält Public Key, Generation, verschlüsselte Hüllen und Audit. Je Konto existiert ein X25519-Kontopaar `(sk_K,pk_K)`; neue Rohprivatschlüssel sind 32 Zufallsbytes, öffentliche Schlüssel die daraus berechneten X25519-Rohbytes.

| Datensatz | Logisch erforderlicher Inhalt / Eindeutigkeit |
| --- | --- |
| Kontoschlüssel | Konto, `pk_K`[32]; ein Paar je Konto |
| Passkey-Wrap | Konto, Credential-ID[1..255], `prfSalt`[32], IV[12], Wrap[48]; Credential-ID eindeutig |
| Kundengeneration | Kunde, `kid`, `pk_D`[32], Status `aktiv`/`auslaufend`, Erstellzeit/-akteur |
| Datenzugang | Kunde/Generation, Konto, `enc`[32], `versiegelt`[48], Erteiler/-zeit; ein Zugang je Generation und Konto |
| Recovery | Kunde/Generation, Salt[32], Iterationen=600000, IV[12], Wrap[48]; ein Recovery-Datensatz je Generation |
| Audit | Einrichtung, Zugang/Entzug, Rotation/Abschluss, Akteur, Kunde/Generation, Zeitpunkt; keine Geheimnisse |

Dies ist ein logischer Kryptovertrag, kein SQL-Schema. Auflösung, Rechte und Änderungen MÜSSEN im selben Kundenkontext stattfinden. Die Altverwaltung hatte globale Generationen; ADR 0003 ändert dies auf Kunden. **OFFEN K07:** Zuordnung alter Generationen/Zugänge zu Kunden und konkrete Kundenberechtigungen mit P2-3/P2-5 festlegen. Insbesondere darf ein globaler alter Zugang (Altrolle Admin) nicht ungeprüft für alle neuen Kunden übernommen werden. Bestehende Kryptobytes sind bis zur bewusst autorisierten Umhüllung verlustfrei zu erhalten.

## Kontoschlüssel und Passkey-PRF

`KEK_P = HKDF-SHA256(IKM=PRF-Ausgabe[32], salt=credentialId_raw[1..255], info=ASCII("kubus-kontoschluessel v1"), L=32)`.
`sk_K` wird mit AES-256-GCM, KEK_P, frischem IV[12], AAD=`ASCII("kubus-kontoschluessel v1")` gewickelt. `wrap = ct[32]||tag[16]`. Das PRF-Eingabesalz `prfSalt`[32] ist **nicht** das HKDF-Salz; beide Rollen dürfen nicht vertauscht werden. Pro Passkey wird dasselbe Kontoprivatmaterial unter dessen eigenem KEK_P gewickelt. Passwortreset ersetzt keinen solchen Wrap und stellt keinen Datenzugang her.

Erstanlage schreibt Kontopublickey und ersten Wrap gemeinsam transaktional; Konto aktiv, noch kein Kontoschlüssel, Credential gehört diesem Konto. Weitere Wraps verlangen bereits vorhandenen Kontoschlüssel und dieselbe Credential-Zuordnung; doppelte Credential-ID ist ein Konflikt, kein Überschreiben. Passkey-Löschen entfernt dessen Wrap; wiederholtes Entfernen eines bereits fehlenden Wraps ist ohne Änderung erfolgreich. Andere Passkeys und das Kontopaar werden dadurch nicht automatisch rotiert (`Schluesselverwaltung.php:195–312`, `Passkey.php:754–818`).

Die getrennte lokale Entsperrzeremonie ruft `navigator.credentials.get` auf: `extensions.prf.evalByCredential[base64url(credentialId_raw, ohne Padding)] = {first: prfSalt}`; `allowCredentials` enthält die betreffenden Wrap-Credentials, `userVerification="required"`, `rpId` vom Server, Timeout 60000 ms, frische lokale Challenge[32]. `results.first` MUSS 32 Byte lang sein. Fehlt PRF oder wird abgebrochen, bleibt der Bund gesperrt. Kein Nullschlüssel oder Login-Passwort als Ersatz. Die lokale PRF-Zeremonie ist kein serververifizierter Login; Login/Session-Autorisierung bleibt separat. Registrierung bzw. Anmeldung allein erzeugt/öffnet im belegten Altweg keinen Kontowrap; Freischalten ist eine eigene Zeremonie.

Entsperrdaten kompatibel: `{rpId, wraps:[{credentialId,prfSalt,iv,wrap}], zugaenge:[{kid,enc,versiegelt}]}`. `credentialId` ist Base64url ohne Padding, alle anderen Binärfelder Standard-Base64. Rohbyte-Längen bleiben oben verbindlich; öffentliches Kunden-API-Envelope und Berechtigungen sind mit P2-5 abzustimmen. Admin-Domain und RP-ID MÜSSEN bei Migration unverändert bleiben (ADR 0003), ebenso Credential-Bytes, Salze und Wraps; keine Neuregistrierung als stiller Ersatz.

## Datenzugang

`HPKE.Seal(pk_K, info=ASCII("kubus-datenzugang v1"), aad=ASCII(kid), pt=sk_D_raw[32])` mit der festen Suite aus paket-v2.md. Gespeichert werden `enc`[32] und `versiegelt=ct||tag`[48]. Nach Öffnen MUSS `kid(X25519_public(sk_D)) == erwartetes kid` geprüft werden; GCM-Erfolg allein genügt nicht. Fehlende/fremde Zugänge sind keine leeren Schlüssel. Der Server validiert Längen, Identität, Kundenbezug und Rechte; ohne Privatschlüssel kann er den Hülleninhalt nicht kryptografisch bestätigen.

Eine gesonderte Zugangserteilung (außerhalb der Rotation) verlangt die aktive Zielgeneration unter Sperre und ein aktives Zielkonto mit Kontoschlüssel. Zugang und Audit werden atomar geschrieben. Belegtes Altverhalten (dort Rolle Admin; neu: Konto mit aktuellem `key.manage` im Kundenscope): Das Konto darf zur Recovery die eigene Zugangszeile für dieses aktive `kid` atomar ersetzen; fremde bereits vorhandene Zugänge ergeben einen Konflikt. Diese Selbstreparatur ersetzt keine Rechteprüfung und erlaubt keine Erteilung auf eine auslaufende Generation (`Schluesselverwaltung.php:837–915`). Der Zugriff auf Recovery-Hüllen ist gesondert berechtigt und wird bereits beim Abruf auditiert, auch wenn die anschließende lokale Entschlüsselung scheitert (`:996–1030`); Rollen-/Kundenrechte bleiben K07.

## Recovery – Normalisierung vor dem KDF

Der vorhandene UI-Vertrag ist exakt die ECMAScript-Funktion:

```javascript
String(wert || '').toUpperCase().replace(/[-\s]/g, '')
```

Einrichtung, Bestätigung, Rotation und Öffnen MÜSSEN diese Normalisierung **vor** Vergleich und KDF ausführen. Erst Großschreibung, dann Entfernen von ASCII-Bindestrich und ECMAScript-Whitespace; keine NFC-/NFKC-Normalisierung. Der niedrigere Alt-KDF-Helfer normalisiert selbst nicht. Eine Portierung darf dort keine zweite abweichende Normalisierung einführen. Mindestlänge nach Normalisierung: 24 gemäß JavaScript-`String.length` (UTF-16-Codeeinheiten); anschließend UTF-8-Kodierung mittels TextEncoder-Semantik. Für erzeugte Recovery-Codes ist der Eingaberaum ASCII; abweichende Unicode-Portierungen sind anhand von Fixtures zu prüfen.

`KEK_R = PBKDF2-HMAC-SHA256(UTF8(normalisierte Passphrase), salt[32], iterations=600000, output=32 Byte)`.
AES-256-GCM mit KEK_R, frischem IV[12], AAD=`ASCII(kid)`, Klartext=`sk_D_raw[32]`, Wrap=`ct[32]||tag[16]`. Der Server MUSS exakt 600000 Iterationen sowie Salz-/IV-/Wrap-Längen prüfen. Kein erratener KDF-Default oder parameterloser Wiederherstellungsversuch. Nach Öffnen dieselbe Public-Key-/`kid`-Prüfung wie beim Zugang. Falsche Passphrase und beschädigter Wrap liefern keinen Schlüssel und werden nicht als Passwortreset behandelt.

Generator: 32 Zufallsbytes; jedes Byte modulo 32 indiziert `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`. Die 32 Zeichen werden als acht Vierergruppen mit sieben `-` angezeigt. In den KDF gelangen nach Normalisierung die 32 Zeichen ohne Trenner. Nur Salt/IV/Wrap/Iterationenzahl, niemals die Passphrase, werden serverseitig abgelegt.

## Browserablage

Kompatibler Altbund: IndexedDB `kubus-krypto`, Version 2, Stores `buende`/`meta`, Leerlauf 600000 ms. `skDVerpackt` enthält AES-256-GCM unter KEK_L aus paket-v2.md, IV[12], AAD=`ASCII("kubus-ablage v1|" + kid)`, Klartext=`sk_D_raw`, Chiffrat inklusive Tag[48]. KEK_L und nicht exportierbare CryptoKeys sind kein Schutz gegen bereits kompromittierten Browsercode. Rohbytes nach Import/Verpacken soweit möglich überschreiben; nach Ablauf sperren. **OFFEN K08:** Kunden-/Kontonamensraum und Behandlung vorhandener lokaler Altbünde bei Cutover festlegen; niemals nur anhand eines globalen `kid` einem anderen Kunden zuordnen. Der Safari-Kommentar im Altcode ist keine hier ausgeführte Browserprüfung.

## Einrichtung, Entzug und Rotation

Einrichtung legt unter gemeinsamer Transaktion genau eine aktive Kundengeneration mit berechnetem `kid`, Zugang des ausführenden berechtigten Kontos (aktuelles `key.manage` im Kundenscope plus menschliche Sitzung; dessen Kontoschlüssel muss entsperrt sein, der Zugang wird mit diesem Kontoschlüssel gewickelt), Recovery und Audit an. Der Kunde darf ohne aktive konsistente Generation keine neuen Daten speichern. Das letzte aktive Konto, das für **jede aktive und auslaufende Generation** einen Datenzugang besitzt UND aktuell `key.manage` im Kundenscope hat (die „letzte handlungsfähige Identität“; es wird nie ein Vorlagenname geprüft), bleibt gegen Entzug/Sperrung/Löschung und gegen Entzug seines `key.manage` geschützt; nur die aktive Generation zu prüfen könnte eine laufende Rotation unabschließbar machen (`Schluesselverwaltung.php:1033–1145`). Zugangsentzug entfernt im Altcode alle Generationenzugänge des Kontos atomar; im neuen Modell ist der Kundenumfang explizit zu prüfen. Konto sperren/löschen entfernt dessen Kontoschlüssel, Passkey-Wraps und Zugänge atomar; kundenübergreifende Folgen sind bei globalem Konto durch P2-5 zu klären. Bereits herausgegebene Schlüssel können durch Löschen eines Zugangs nicht zurückgerufen werden.

Rotationsbeginn pro Kunde:

1. Keine offenen Altformatzeilen; keine parallele Migration, keine bestehende auslaufende Generation, genau eine aktive Generation. Ungeklärte Migrationsausnahmen erlauben keinen Laufzeitzugriff auf Altchiffrate.
2. Neue Generation samt neuem Recovery und neuen Datenzugängen vorbereiten. Zugangsliste nichtleer und ohne doppelte Konten; das ausführende Konto (mit `key.manage`) enthalten. Alle Zielkonten aktiv und mit Kontoschlüssel. Außer dem ausführenden Konto dürfen NUR Konten mit Zugang zur alten Generation aufgenommen werden (review-D S18); kein stilles Wiederherstellen entzogener Zugänge. Mindestens ein aktives Konto mit `key.manage` im Kundenscope behält Zugang.
3. Unter Sperren und Transaktion Vorbedingungen erneut prüfen; alte Generation `aktiv→auslaufend`, neue `aktiv`, Zugänge/Recovery/Audit atomar schreiben. Eingang verwendet danach nur die neue aktive Generation. Rechte-/Generationssperren konsistent mit Entzug koordinieren.
4. Berechtigte Clients öffnen alte CEKs und wickeln sie auf die neue Generation. Abbruch ist fortsetzbar: bereits umgehängte Pakete bleiben gültig; alte Generation bleibt verfügbar, bis kein Verweis mehr besteht.
5. Abschluss NUR bei null verbliebenen alten Referenzen. Altcode zählt `data`, `file1Enc`, `mailBody`, `mailBodyFiller`; im neuen System müssen alle tatsächlich eingeführten verschlüsselten Gegenstände einschließlich externer Inhalte/Anhänge erfasst sein. **VORGESCHLAGEN K09:** vollständiges Referenzinventar und Lebenszyklus in `../data/objektinventar.md`; Implementierungs-/Rotationsnachweis weiterhin OFFEN. Erst dann alte Zugänge, Recovery und Generation atomar entfernen und Abschluss auditieren. Keine Schlüsselvernichtung während ein CEK noch darauf verweist.

## Umhängen und Anhalten

Es ändert sich ausschließlich die CEK-Hülle. Nutzdaten-`iv`, `ct`, `tag` MÜSSEN nach Dekodierung byte-identisch bleiben; beide Pakete müssen den strengen Parser bestehen. Erlaubt: `hpke→hpke`, `hpke→sym`, `sym→sym`; verboten: `sym→hpke`. Ein bekanntes Ziel-`kid` allein genügt nicht:

| Vorgang | Zusätzlich notwendiges Ziel |
| --- | --- |
| Anhalten/Löschschutz | gleiches `kid`, Zielwrap `sym`; `removable=0` und alle betroffenen Pakete atomar |
| Generationsrotation | Quelle ist auslaufende Generation dieses Kunden, Ziel die aktuell aktive Generation desselben Kunden |

Altbelege: `PaketV2::umhaengenErlaubt`, `Umhaengen::speichere`/`speichereFuerRotation`. Bei Anhalten darf ein vorhandener `hpke`-Wrap ohne mitgeliefertes `sym`-Ersatzpaket nicht still bestehen bleiben (Altfehler 409). Bereits passende `sym`-Pakete sind ohne unnötiges Neuwickeln verwendbar. Der Server prüft aktuellen gesperrten Datensatz, Rechte, Zielgeneration und Invarianten vor Schreiben. Er kann ohne Schlüssel nicht beweisen, dass der neue Wrap denselben CEK enthält; diese Grenze muss durch Browser-Kreuztests und autorisierte Clients berücksichtigt werden. `:1`-Löschschutzpfade des Altprojekts werden nicht in die neue Laufzeit übernommen.


Technischer Nachtrag (VORGESCHLAGEN): UUID-`generationId`, Kunden-`kid` und
`generation_no` werden ausschließlich über denselben Datensatz in
`customer_key_generations` aufgelöst (`../data/abbildung.md`). Neue Annahmen
binden die aktive Generation am Objekt, keine Generation in der unveränderlichen
Formulardefinition. Holdliste und atomare Prüfung aller Pakete richten sich nach
`../data/objektinventar.md` und Auth `HoldInput`; Kryptoinvarianten oben bleiben
maßgeblich. Schlüsselbesitz-/CEK-Beweis wird dadurch nicht behauptet. H05 ist durch ADR 0004 als eigener Transportvertrag in transport.md geklärt;
sym-v2-Speicherprofil bleibt gesperrt. Kunden-/Altschlüsselschnitt bleibt OFFEN.


## Vertragsrunde 3 — R04: Rechteübersetzung (VORGESCHLAGEN)

Im Kryptotext bedeutet „Admin“ nie eine Rolle oder ein Vorlagenwort. Verbindlich
gilt (`../auth/rechte.md`, Katalog `Permission`):

| Aktion | Mindestbedingungen |
| --- | --- |
| Generation einrichten, Rotation beginnen/abschließen, Zugang erteilen/entziehen, Recovery erneuern | aktuelles `key.manage` im Kundenscope (Gruppen-/Einzelgrant), menschliche Sitzung mit frischer Bestätigung und CSRF, ausführendes Konto mit entsperrtem Kontoschlüssel und Datenzugang zur betroffenen Generation |
| CEK umhängen (Rewrap beim Hold/Rotation) | zusätzlich `content.decrypt` bzw. `content.hold` je Aktion, lokal entsperrter Datenschlüssel (K) |
| Zugang für ein anderes Konto erteilen | Ziel ist ein aktives Konto im selben Kunden mit Kontoschlüssel; der Erteilende braucht Zugang zur selben Generation, `key.manage` verleiht ihn nicht |
| Schutz der letzten handlungsfähigen Identität | siehe Einrichtung/Rotation oben: je Generation mindestens ein aktives Konto mit Zugang UND `key.manage`; auch das Entziehen des Rechts (`permission_assignments`, Gruppenänderung) wird gegen diese Bedingung geprüft |

Ein Kunde mit ausdrücklich delegiertem `key.manage` ist damit zulässig; ein
Konto mit Vorlage „Admin“ ohne dieses Recht nicht. `system.manage` ersetzt es
nicht. Abnahme (nicht ausgeführt): Konto nur mit `key.manage` (Vorlage Kunde) führt
Rotation aus; Vorlage Admin ohne Recht scheitert; Entzug des letzten `key.manage`
mit Datenzugang scheitert; Gruppenänderung, die das letzte Recht entfernt, scheitert.
