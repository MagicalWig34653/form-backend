import { t } from '$lib/i18n';

/** Quotes a field name for a single-quoted PHP string. */
const quote = (name: string): string => `'${name.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;

/**
 * PHP example for the integration page. The array keys are the real field names of the form;
 * without any field a neutral placeholder is shown (as a comment, so that it never submits a
 * field the form does not have).
 */
export function phpExample(fieldNames: readonly string[]): string {
  const c = t.phpSdk;
  const names = fieldNames.filter((n) => n !== '');
  const width = Math.max(0, ...names.map((n) => quote(n).length));
  const lines =
    names.length === 0
      ? [
          c.codePlaceholder,
          `        // ${quote(c.codePlaceholderField)} => $_POST[${quote(c.codePlaceholderField)}] ?? '',`,
        ]
      : names.map((n) => `        ${quote(n).padEnd(width)} => $_POST[${quote(n)}] ?? '',`);
  return [c.codeHead, ...lines, c.codeFoot].join('\n');
}
