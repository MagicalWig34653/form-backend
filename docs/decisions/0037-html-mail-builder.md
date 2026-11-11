# 0037 HTML-E-Mail-Builder in der PWA

Status: umgesetzt (11.11.2026), Nutzerwunsch „Der HTML E-Mail Builder muss mit rein.“

## Entscheidung

- Der Mail-Reiter bietet für HTML-Vorlagen drei Betriebsarten auf demselben Feld `form.mail.<art>.body` (Format `html`): **Design** (MJML-Bausteine → tabellenbasiertes, Outlook-taugliches HTML), **Einfach** (Rich-Text in einem mailfesten Tabellenrahmen), **Quelltext** (rohes HTML). Text-Vorlagen bleiben ein einfaches Feld.
- **Speicherformat wie im Altsystem** (`www/src/mail-editor.js`): `<!--kubus-mail-quelle:BASE64(JSON {m, s, q})-->` + Zeilenumbruch + versendetes HTML. `m` = `design` | `einfach`, `s` = bearbeitbare Quelle (MJML bzw. Rich-Text-HTML), `q` = HTML danach von Hand geändert. Base64 über UTF-8-Bytes, identisch zu `btoa(unescape(encodeURIComponent(…)))`. Fehlt oder bricht der Marker, startet der Editor im Quelltext. Damit sind aus dem Altsystem importierte Mails (der Importer übernimmt `mailBody` unverändert, `LegacyFormConverter.swift`) weiter bearbeitbar.
- **Keine Backend- oder Vertragsänderung.** Der Server sieht normales HTML; der Kommentar wird mitversendet (harmlos, Platzhalter im Base64-Text matchen `#=[name]=#` nie). Grenze 100 000 Byte gilt inklusive Marker; der Editor zeigt die Größe an.
- **MJML-Compiler: `mjml-browser` 4.18.0** (MIT, eigenständiges Bündel ohne Abhängigkeiten), per `import()` in einem eigenen Chunk. 5.x nicht, weil es `cheerio` zur Laufzeit extern verlangt. Option `fonts: {}` verhindert Google-Fonts-Links in Mails.
- **Kein GrapesJS/grapesjs-mjml, kein Quill.** GrapesJS schreibt `<style>`-Elemente (von der App-CSP `style-src 'self'` blockiert) und ist per Tastatur kaum bedienbar; Quill 2.0.3 hat eine offene Advisory ohne Fix und keine Pflege seit 01/2025. Stattdessen eigener Blockeditor (Svelte) und eigener Rich-Text-Editor (contenteditable) mit Whitelist-Sanitizer.

## Sicherheit

- Nutzer-HTML erscheint nie im Admin-DOM per `{@html}`. Vorschau nur im `iframe sandbox=""` (keine Skripte, kein Same-Origin, keine Formulare/Popups) per `srcdoc`, Platzhalter als escapte Beispielwerte, zusätzliche Meta-CSP im Vorschaudokument.
- Rich-Text rein und raus nur über den Sanitizer (p, br, strong, em, u, h2, h3, ul, ol, li, a[href]); Links nur `http(s):`/`mailto:` wörtlich am Anfang (ein Platzhalter darf nicht am Anfang stehen, sonst könnte ein Feldwert `javascript:` einsetzen). Bilder nur `https:` oder `data:image/(png|jpeg|gif|webp)`. Unsichere URL-Attribute werden beim Erzeugen weggelassen. Keine Uploads.
- CSP: Der Builder läuft unter der echten App-CSP ohne Lockerung (e2e `mail-builder.spec.ts` setzt den Header aus `StaticSite.swift`). Einzige Folge: Das `srcdoc`-Vorschaudokument erbt die App-CSP, daher wirken dort `<style>`-Blöcke der Mail und externe Bilder nicht (Inline-Styles, die MJML für das Layout nutzt, schon). Bewusst keine Lockerung; wird eine originalgetreue Vorschau externer Bilder gewünscht, wäre `img-src 'self' data: https:` die minimale Lockerung (nicht umgesetzt).

## Bewusste Abweichungen vom Altsystem

- Bausteinliste statt freier GrapesJS-Leinwand; unbekanntes MJML (mehrspaltige Sektionen, mj-social, mj-head …) bleibt als „MJML“-Baustein unverändert erhalten.
- Moduswechsel fragen über den gemeinsamen Bestätigungsdialog statt `window.confirm`; zusätzlich Warnung vor Verlust der Design-Quelle (Design → Einfach) und vor dem Ersetzen von Handänderungen (Quelltext mit `q=true` → Design/Einfach).
- Quelltext zeigt das HTML ohne Marker; die Quelle bleibt im Marker erhalten und wird bei Handänderung mit `q=true` markiert.
- Vollbild per Fullscreen-API mit CSS-Rückfall; der Design-Modus zeigt unter 768 px einen Hinweis, bleibt aber nutzbar.
