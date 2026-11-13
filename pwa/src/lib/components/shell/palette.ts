export type PaletteGroupId = 'pages' | 'forms' | 'customers' | 'actions';

export interface PaletteItem {
  id: string;
  group: PaletteGroupId;
  label: string;
  /** Secondary text, e.g. the kind of target. */
  hint?: string;
  /** Glyph name for NavIcon. */
  icon: string;
  /** Extra search terms that are not shown. */
  keywords?: string;
  /** Navigation targets let the app move focus to the new page heading. */
  href?: string;
  run?: () => void;
}

const fold = (text: string): string =>
  text.toLocaleLowerCase('de').normalize('NFD').replace(/\p{M}/gu, '').replace(/ß/g, 'ss');

/** All words of the query must occur (accent-insensitive) in label, hint or keywords. */
export function filterItems(items: readonly PaletteItem[], query: string): PaletteItem[] {
  const words = fold(query).split(/\s+/).filter(Boolean);
  if (words.length === 0) return [...items];
  return items.filter((item) => {
    const haystack = fold(`${item.label} ${item.hint ?? ''} ${item.keywords ?? ''}`);
    return words.every((w) => haystack.includes(w));
  });
}

/** Keeps the order of `groups`, drops empty groups; indices run over the visible result in that order. */
export function groupItems(
  items: readonly PaletteItem[],
  groups: readonly PaletteGroupId[],
): { id: PaletteGroupId; items: PaletteItem[] }[] {
  return groups
    .map((id) => ({ id, items: items.filter((i) => i.group === id) }))
    .filter((g) => g.items.length > 0);
}

/** Next index for arrow keys, wrapping around; -1 when there is nothing to select. */
export function step(current: number, delta: number, count: number): number {
  if (count === 0) return -1;
  return (((current + delta) % count) + count) % count;
}
