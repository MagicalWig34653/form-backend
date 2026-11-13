/** Die 20 Akzentfarben der Oberfläche (Vorgabe: Türkis). Der Kontrast wird in accent.ts berechnet. */
export const ACCENTS: readonly { id: string; hex: string }[] = [
  { id: 'tuerkis', hex: '#0f766e' },
  { id: 'blau', hex: '#2563eb' },
  { id: 'violett', hex: '#7c3aed' },
  { id: 'orange', hex: '#ea580c' },
  { id: 'rot', hex: '#dc2626' },
  { id: 'gruen', hex: '#15803d' },
  { id: 'gelb', hex: '#eab308' },
  { id: 'bernstein', hex: '#f59e0b' },
  { id: 'limette', hex: '#84cc16' },
  { id: 'smaragd', hex: '#10b981' },
  { id: 'cyan', hex: '#06b6d4' },
  { id: 'himmelblau', hex: '#0ea5e9' },
  { id: 'indigo', hex: '#4f46e5' },
  { id: 'purpur', hex: '#a855f7' },
  { id: 'magenta', hex: '#d946ef' },
  { id: 'pink', hex: '#ec4899' },
  { id: 'rose', hex: '#f43f5e' },
  { id: 'koralle', hex: '#f97316' },
  { id: 'braun', hex: '#92400e' },
  { id: 'schiefer', hex: '#475569' },
];
export const DEFAULT_ACCENT = 'tuerkis';
/** Frühere Kennungen aus gespeicherten Einstellungen. */
export const LEGACY_ACCENTS: Record<string, string> = {
  blue: 'blau',
  violet: 'violett',
  green: 'gruen',
  orange: 'orange',
};
