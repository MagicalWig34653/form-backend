/**
 * Akzentfarbe -> Tokens mit berechnetem Kontrast (nach dem thermoctl-Design):
 * `foreground` ist Schwarz oder Weiß nach Luminanz, `ink` eine Tinte mit mindestens 4,5 : 1 auf dem
 * Hintergrund (Text, Fokusring), `soft` eine zarte Fläche (9 % hell, 18 % dunkel).
 */
export function accentTokens(hex: string, dark: boolean) {
  if (!/^#[0-9a-f]{6}$/i.test(hex)) return null;
  const rgb = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  const weights = [0.2126, 0.7152, 0.0722];
  const lum = (r: number[]): number =>
    r
      .map((v) => {
        const x = v / 255;
        return x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4;
      })
      .reduce((a, v, i) => a + v * (weights[i] ?? 0), 0);
  const l = lum(rgb);
  const white = 1.05 / (l + 0.05);
  const black = (l + 0.05) / 0.05;
  let ink = [...rgb];
  // Ink is checked against the page and against the soft surface (active menu entry, avatars):
  // the soft surface is the accent mixed 9 % (light) or 18 % (dark) into the page colour.
  const page = dark ? [9, 9, 11] : [255, 255, 255];
  const mixAmount = dark ? 0.18 : 0.09;
  const soft = rgb.map((v, i) => v * mixAmount + (page[i] ?? 0) * (1 - mixAmount));
  const bgs = [lum(page), lum(soft)];
  for (let i = 0; i < 30; i++) {
    const li = lum(ink);
    if (bgs.every((bg) => (Math.max(li, bg) + 0.05) / (Math.min(li, bg) + 0.05) >= 4.5)) break;
    ink = ink.map((v) => Math.round(v * 0.9 + (dark ? 255 : 0) * 0.1));
  }
  return {
    primary: hex,
    foreground: white >= black ? '#ffffff' : '#000000',
    ink: `rgb(${ink.join(' ')})`,
    soft: `color-mix(in srgb, ${hex} ${dark ? '18' : '9'}%, var(--background))`,
  };
}
