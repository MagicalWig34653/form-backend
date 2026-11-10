import { expect, it } from 'vitest';
import { scrollHint } from './scrollHint';

function region(scrollWidth: number, clientWidth: number, scrollLeft = 0): HTMLElement {
  const node = document.createElement('div');
  Object.defineProperty(node, 'scrollWidth', { value: scrollWidth, configurable: true });
  Object.defineProperty(node, 'clientWidth', { value: clientWidth, configurable: true });
  node.scrollLeft = scrollLeft;
  return node;
}

it('markiert Bereiche mit verborgenem Inhalt und blendet den Hinweis am Ende aus', () => {
  const wide = region(500, 200);
  const action = scrollHint(wide);
  expect(wide.classList.contains('scroll-hint')).toBe(true);
  expect(wide.dataset.more).toBe('true');
  Object.defineProperty(wide, 'scrollLeft', { value: 300, configurable: true });
  wide.dispatchEvent(new Event('scroll'));
  expect(wide.dataset.more).toBe('false');
  action.destroy();
});
it('markiert nichts, wenn alles sichtbar ist', () => {
  const fits = region(200, 200);
  const action = scrollHint(fits);
  expect(fits.dataset.more).toBe('false');
  action.destroy();
});
