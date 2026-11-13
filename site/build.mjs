// SPDX-License-Identifier: AGPL-3.0-only
// Dependency-free static site build: content/*.html (fragments with a leading <!-- title: ... | description: ... --> line)
// are wrapped into template.html and written to site/dist/. Usage: node site/build.mjs [--base /form-backend/]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, 'dist');
// Pages use relative links (flat layout) so the site works from any prefix; only 404.html needs an absolute base.
const baseArg = process.argv.indexOf('--base');
const base = './';
const base404 = baseArg > 0 ? process.argv[baseArg + 1] : '/';

const nav = [
  ['index', 'Start'],
  ['einrichtung', 'Einrichtung'],
  ['benutzung', 'Benutzung'],
  ['sdk', 'PHP-SDK'],
  ['api', 'Admin-API'],
  ['sicherheit', 'Sicherheit'],
  ['architektur', 'Architektur'],
  ['status', 'Stand & Roadmap'],
  ['entwicklung', 'Entwicklung'],
];

const template = fs.readFileSync(path.join(here, 'template.html'), 'utf8');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(path.join(out, 'assets'), { recursive: true });
for (const f of fs.readdirSync(path.join(here, 'assets'))) fs.copyFileSync(path.join(here, 'assets', f), path.join(out, 'assets', f));

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
let count = 0;
for (const [slug, label] of nav) {
  const file = path.join(here, 'content', `${slug}.html`);
  let html = fs.readFileSync(file, 'utf8');
  const meta = /^<!--\s*title:\s*(.+?)\s*\|\s*description:\s*(.+?)\s*-->\s*/.exec(html);
  if (!meta) throw new Error(`${slug}.html: missing <!-- title: … | description: … --> header`);
  html = html.slice(meta[0].length);
  const links = nav.map(([s, l]) => `<a href="${s === 'index' ? base : `${base}${s}.html`}"${s === slug ? ' aria-current="page"' : ''}>${l}</a>`).join('\n');
  const page = template
    .replaceAll('{{title}}', esc(slug === 'index' ? meta[1] : `${meta[1]} – Formular-Backend`))
    .replaceAll('{{description}}', esc(meta[2]))
    .replaceAll('{{base}}', base)
    .replace('{{nav}}', links)
    .replace('{{content}}', html);
  fs.writeFileSync(path.join(out, slug === 'index' ? 'index.html' : `${slug}.html`), page);
  count++;
}
fs.writeFileSync(path.join(out, '.nojekyll'), '');
const links404 = nav.map(([s, l]) => `<a href="${s === 'index' ? base404 : `${base404}${s}.html`}">${l}</a>`).join('\n');
fs.writeFileSync(path.join(out, '404.html'), template
  .replaceAll('{{title}}', 'Seite nicht gefunden – Formular-Backend').replaceAll('{{description}}', 'Seite nicht gefunden').replaceAll('{{base}}', base404)
  .replace('{{nav}}', links404)
  .replace('{{content}}', `<h1>Seite nicht gefunden</h1><p>Diese Seite gibt es nicht. <a href="${base404}">Zur Startseite</a>.</p>`));
console.log(`built ${count} pages into ${path.relative(process.cwd(), out)} (404 base ${base404})`);
