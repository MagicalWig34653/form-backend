import { t } from '$lib/i18n';

/** Plain-language name of a permission key (form.read -> "Lesen"); unknown keys are shown as they are. */
export function rightLabel(key: string): string {
  const labels = t.rights.labels as Record<string, string>;
  return labels[key] ?? key;
}

/** One-sentence description of what a permission allows; empty for unknown keys. */
export function rightHint(key: string): string {
  const hints = t.rights.hints as Record<string, string>;
  return hints[key] ?? '';
}

/** Comma-separated labels, e.g. for a compact table cell. */
export function rightsText(keys: readonly string[]): string {
  return keys.map(rightLabel).join(', ');
}

/**
 * Labels of the rights a customer-wide permission list grants, in the catalogue's order. Reading is
 * implied by every membership. The customer list and the members page use this one description.
 */
export function rightsOf(permissions: readonly string[]): string[] {
  const order = Object.keys(t.rights.labels);
  const known = new Set(['form.read', ...permissions]);
  return order.filter((key) => known.has(key)).map(rightLabel);
}
