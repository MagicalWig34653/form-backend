import { render, screen, fireEvent } from '@testing-library/svelte';
import { expect, it } from 'vitest';
import PageTabs from './PageTabs.svelte';
import { router } from '$lib/router.svelte';

const tabs = [
  { id: 'a', label: 'Übersicht', href: '/x', active: true },
  { id: 'b', label: 'Felder', href: '/x/fields', active: false },
  {
    id: 'c',
    label: 'Veröffentlichen',
    href: '/x/publish',
    active: false,
    dot: 'Entwurf weicht ab',
  },
];

it('is a link navigation with one current page, not an ARIA tab widget', async () => {
  render(PageTabs, { label: 'Reiter', tabs });
  expect(screen.queryByRole('tab')).toBeNull();
  const nav = screen.getByRole('navigation', { name: 'Reiter' });
  expect(nav.querySelectorAll('[aria-current="page"]')).toHaveLength(1);
  expect(screen.getByRole('link', { name: 'Übersicht' }).getAttribute('aria-current')).toBe('page');
  // The dot is explained for assistive technology, not by colour alone.
  expect(screen.getByRole('link', { name: /Veröffentlichen/ }).textContent).toContain(
    'Entwurf weicht ab',
  );
  await fireEvent.click(screen.getByRole('link', { name: 'Felder' }));
  expect(router.path).toBe('/x/fields');
});

it('scrolls with snap points so that a tab is never cut in the middle', () => {
  const { container } = render(PageTabs, { label: 'Reiter', tabs });
  expect(container.querySelector('ul')!.className).toContain('snap-x');
  expect(container.querySelector('li')!.className).toContain('snap-start');
});
