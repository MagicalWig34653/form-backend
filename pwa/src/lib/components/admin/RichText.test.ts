import { render } from '@testing-library/svelte';
import { expect, it } from 'vitest';
import RichText, { segments } from './RichText.svelte';

it('trennt Text und Code an Backticks', () => {
  expect(segments('Datei `a.json` ablegen')).toEqual([
    { code: false, text: 'Datei ' },
    { code: true, text: 'a.json' },
    { code: false, text: ' ablegen' },
  ]);
  expect(segments('ohne')).toEqual([{ code: false, text: 'ohne' }]);
});
it('zeichnet Code als code-Element', () => {
  const { container } = render(RichText, { text: 'Mit `chmod 600` sichern' });
  expect(container.querySelector('code')?.textContent).toBe('chmod 600');
  expect(container.textContent).toBe('Mit chmod 600 sichern');
});
