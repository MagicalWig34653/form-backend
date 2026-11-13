// Checks WCAG contrast of the design tokens in src/app.css (text >= 4.5:1, UI >= 3:1) and of the
// computed accent tokens for all 20 accent colours in both schemes (src/lib/accent.ts).
// Run: node scripts/contrast.mjs   (exit code 1 on failure)
import { readFileSync } from 'node:fs';
import { accentTokens } from '../src/lib/accent.ts';
import { ACCENTS } from '../src/lib/accents.ts';

const css = readFileSync(new URL('../src/app.css', import.meta.url), 'utf8');
const block = (selector) => {
  const start = css.indexOf(`\n${selector} {`);
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
  m = v.match(/^rgb\((\d+) (\d+) (\d+)\)$/);
  if (m) return [m[1], m[2], m[3]].map((x) => +x / 255);
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
const mix = (fg, bg, a) => fg.map((v, i) => v * a + bg[i] * (1 - a));

let failed = 0;
function report(ok, mode, label, value, min) {
  if (!ok) failed++;
  console.log(
    `${ok ? 'ok  ' : 'FAIL'} ${mode.padEnd(5)} ${label.padEnd(44)} ${value.toFixed(2)} (>= ${min})`,
  );
}
function check(mode, tokens, fg, bg, min, label) {
  const surface = color(tokens[bg], tokens);
  const fgRgb = fg.startsWith('#') ? color(fg, tokens) : color(tokens[fg], tokens, surface);
  report(ratio(fgRgb, surface) >= min, mode, label, ratio(fgRgb, surface), min);
}

// Tailwind palette values used for status text on a 10 % tint of the same hue (see Banner, StatusChip).
const status = {
  light: { ok: '#047857', warn: '#92400e', danger: '#b91c1c', info: '#1d4ed8' },
  dark: { ok: '#34d399', warn: '#fbbf24', danger: null, info: '#60a5fa' },
};
const tint = { ok: '#10b981', warn: '#f59e0b', danger: '#ef4444', info: '#3b82f6' };

for (const [mode, tokens] of [
  ['light', light],
  ['dark', dark],
]) {
  const bgRgb = color(tokens.background, tokens);
  for (const surface of ['background', 'sidebar', 'muted', 'secondary']) {
    check(mode, tokens, 'foreground', surface, 4.5, `foreground on ${surface}`);
    check(mode, tokens, 'muted-foreground', surface, 4.5, `muted-foreground on ${surface}`);
  }
  check(mode, tokens, 'muted-foreground', 'background', 4.5, 'muted-foreground on background');
  check(mode, tokens, 'destructive', 'background', 4.5, 'destructive on background');
  for (const [tone, hex] of Object.entries(status[mode])) {
    const fg = hex ? color(hex, tokens) : color(tokens.destructive, tokens);
    for (const alpha of [0.1, 0.18]) {
      const bg = mix(color(tint[tone], tokens), bgRgb, alpha);
      report(
        ratio(fg, bg) >= 4.5,
        mode,
        `${tone} text on ${alpha * 100}% tint`,
        ratio(fg, bg),
        4.5,
      );
    }
  }
  // Accents: button text on the accent, ink (text, focus ring) on page and soft surface.
  for (const accent of ACCENTS) {
    const t = accentTokens(accent.hex, mode === 'dark');
    const primary = color(t.primary, tokens);
    const fg = color(t.foreground, tokens);
    const ink = color(t.ink, tokens);
    const soft = mix(primary, bgRgb, mode === 'dark' ? 0.18 : 0.09);
    report(
      ratio(fg, primary) >= 4.5,
      mode,
      `${accent.id}: button text on accent`,
      ratio(fg, primary),
      4.5,
    );
    report(
      ratio(ink, bgRgb) >= 4.5,
      mode,
      `${accent.id}: ink on background`,
      ratio(ink, bgRgb),
      4.5,
    );
    report(
      ratio(ink, soft) >= 4.5,
      mode,
      `${accent.id}: ink on soft surface`,
      ratio(ink, soft),
      4.5,
    );
  }
}
if (failed) {
  console.error(`${failed} contrast check(s) failed`);
  process.exit(1);
}
console.log('all contrast checks passed');
