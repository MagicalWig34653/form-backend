// Checks WCAG contrast of the design tokens in src/app.css (text >= 4.5:1, UI >= 3:1).
// Run: node scripts/contrast.mjs   (exit code 1 on failure)
import { readFileSync } from 'node:fs';

const css = readFileSync(new URL('../src/app.css', import.meta.url), 'utf8');
const block = (selector) => {
  const start = css.indexOf(`${selector} {`);
  return css.slice(start, css.indexOf('\n}', start));
};
const parse = (body) => {
  const tokens = {};
  for (const m of body.matchAll(/--([\w-]+):\s*([^;]+);/g)) tokens[m[1]] = m[2].trim();
  return tokens;
};
const light = parse(block(':root'));
const dark = { ...light, ...parse(block('.dark')) };

function oklchToRgb(l, c, h, alpha = 1, over = [1, 1, 1]) {
  const a = c * Math.cos((h * Math.PI) / 180);
  const b = c * Math.sin((h * Math.PI) / 180);
  const l_ = (l + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m_ = (l - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s_ = (l - 0.0894841775 * a - 1.291485548 * b) ** 3;
  const lin = [
    4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
    -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
    -0.0041960863 * l_ - 0.7034186147 * m_ + 1.707614701 * s_,
  ].map((v) => Math.min(1, Math.max(0, v)));
  const enc = (v) => (v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055);
  return lin.map((v, i) => enc(v) * alpha + over[i] * (1 - alpha));
}
function color(value, tokens, over) {
  const v = value.trim();
  let m = v.match(/^oklch\(([\d.]+) ([\d.]+) ([\d.]+)(?: \/ ([\d.]+)%)?\)$/);
  if (m) return oklchToRgb(+m[1], +m[2], +m[3], m[4] ? +m[4] / 100 : 1, over);
  m = v.match(/^#([0-9a-f]{6})$/i);
  if (m) return [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16) / 255);
  m = v.match(/^var\(--([\w-]+)\)$/);
  if (m) return color(tokens[m[1]], tokens, over);
  throw new Error(`unsupported colour: ${value}`);
}
const luminance = ([r, g, b]) => {
  const f = (v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
};
const ratio = (x, y) => {
  const [hi, lo] = [luminance(x), luminance(y)].sort((p, q) => q - p);
  return (hi + 0.05) / (lo + 0.05);
};

const accentInk = { light: '#1d4ed8', dark: '#93c5fd' };
// Active navigation: ink of every accent on its 10 % tint over the page surface (see theme.svelte.ts).
const accents = {
  light: {
    blue: ['#2563eb', '#1d4ed8'],
    violet: ['#7c3aed', '#7c3aed'],
    green: ['#047857', '#047857'],
    orange: ['#c2410c', '#9a3412'],
  },
  dark: {
    blue: ['#2563eb', '#93c5fd'],
    violet: ['#7c3aed', '#c4b5fd'],
    green: ['#047857', '#6ee7b7'],
    orange: ['#c2410c', '#fdba74'],
  },
};
let failed = 0;
function check(mode, tokens, fg, bg, min, label) {
  const surface = color(tokens[bg], tokens);
  const fgRgb = fg.startsWith('#') ? color(fg, tokens) : color(tokens[fg], tokens, surface);
  const value = ratio(fgRgb, surface);
  const ok = value >= min;
  if (!ok) failed++;
  console.log(
    `${ok ? 'ok  ' : 'FAIL'} ${mode.padEnd(5)} ${label.padEnd(34)} ${value.toFixed(2)} (>= ${min})`,
  );
}
for (const [mode, tokens] of [
  ['light', light],
  ['dark', dark],
]) {
  for (const surface of ['surface-page', 'surface-card', 'surface-raised', 'surface-sunken']) {
    check(mode, tokens, 'foreground', surface, 4.5, `foreground on ${surface}`);
    check(mode, tokens, 'muted-foreground', surface, 4.5, `muted-foreground on ${surface}`);
    check(mode, tokens, accentInk[mode], surface, 4.5, `accent-ink on ${surface}`);
  }
  for (const tone of ['ok', 'warn', 'danger', 'info', 'idle']) {
    check(mode, tokens, tone, `${tone}-soft`, 4.5, `${tone} on ${tone}-soft`);
    check(mode, tokens, 'foreground', `${tone}-soft`, 4.5, `foreground on ${tone}-soft`);
    check(mode, tokens, tone, 'surface-card', 3, `${tone} (dot/icon) on surface-card`);
  }
  for (const surface of ['background', 'surface-card', 'surface-page', 'surface-raised']) {
    check(mode, tokens, 'input', surface, 3, `input border on ${surface}`);
    check(mode, tokens, 'ring', surface, 3, `focus ring on ${surface}`);
  }
  check(mode, tokens, 'sidebar-ring', 'sidebar', 3, 'sidebar ring on sidebar');
  check(mode, tokens, 'sidebar-foreground', 'sidebar', 4.5, 'sidebar text on sidebar');
  check(mode, tokens, 'muted-foreground', 'sidebar', 4.5, 'muted text on sidebar');
}
for (const mode of ['light', 'dark']) {
  const tokens = mode === 'light' ? light : dark;
  for (const surfaceName of ['surface-page', 'surface-card', 'sidebar'])
    for (const [name, [base, ink]] of Object.entries(accents[mode])) {
      const surface = color(tokens[surfaceName], tokens);
      const tint = color(base, tokens).map((v, i) => v * 0.1 + surface[i] * 0.9);
      const value = ratio(color(ink, tokens), tint);
      const ok = value >= 4.5;
      if (!ok) failed++;
      console.log(
        `${ok ? 'ok  ' : 'FAIL'} ${mode.padEnd(5)} ${`accent-ink ${name} on tint/${surfaceName}`.padEnd(34)} ${value.toFixed(2)} (>= 4.5)`,
      );
    }
}
if (failed) {
  console.error(`${failed} contrast check(s) failed`);
  process.exit(1);
}
console.log('all contrast checks passed');
