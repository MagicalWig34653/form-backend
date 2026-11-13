import { createRawSnippet } from 'svelte';
import { render, screen, fireEvent } from '@testing-library/svelte';
import { expect, it, vi } from 'vitest';
import PageHeader from './PageHeader.svelte';
import Panel from './Panel.svelte';
import StatusChip from './StatusChip.svelte';
import Banner from './Banner.svelte';
import EmptyState from './EmptyState.svelte';
import Skeleton from './Skeleton.svelte';
import Breadcrumb from './Breadcrumb.svelte';
import { router } from '$lib/router.svelte';

const text = (value: string) => createRawSnippet(() => ({ render: () => `<span>${value}</span>` }));
const button = (label: string) =>
  createRawSnippet(() => ({ render: () => `<button type="button">${label}</button>` }));

it('PageHeader: h1 with focus target id, description and actions', () => {
  render(PageHeader, {
    title: 'Kontakt',
    description: 'Ein Satz.',
    actions: button('Anlegen'),
    badges: text('Aktiv'),
  });
  const h1 = screen.getByRole('heading', { level: 1, name: 'Kontakt' });
  expect(h1.id).toBe('page-title');
  expect(h1.getAttribute('tabindex')).toBe('-1');
  expect(screen.getByText('Ein Satz.')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Anlegen' })).toBeTruthy();
  expect(screen.getByText('Aktiv')).toBeTruthy();
});

it('Panel: title as heading of the requested level, body and actions', () => {
  render(Panel, {
    title: 'Verlauf',
    level: 3,
    description: 'Letzte 14 Tage',
    children: text('Inhalt'),
    actions: button('Mehr'),
  });
  expect(screen.getByRole('heading', { level: 3, name: 'Verlauf' })).toBeTruthy();
  expect(screen.getByText('Letzte 14 Tage')).toBeTruthy();
  expect(screen.getByText('Inhalt')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Mehr' })).toBeTruthy();
});

it('Panel without title renders no heading', () => {
  render(Panel, { children: text('Nur Inhalt') });
  expect(screen.queryByRole('heading')).toBeNull();
});

it('StatusChip: always carries the text, pulse only for non-error tones', () => {
  const { container, rerender } = render(StatusChip, { tone: 'ok', label: 'Aktiv', pulse: true });
  expect(screen.getByText('Aktiv')).toBeTruthy();
  expect(container.querySelector('.animate-pulse')).not.toBeNull();
  void rerender({ tone: 'danger', label: 'Fehler', pulse: true });
  expect(container.querySelector('.animate-pulse')).toBeNull();
  expect(container.querySelector('[data-tone="danger"]')).not.toBeNull();
});

it('Banner: danger is an alert, others are status; dismiss and action work', async () => {
  const dismiss = vi.fn();
  const { rerender } = render(Banner, {
    tone: 'danger',
    title: 'Fehler',
    children: text('Details'),
    ondismiss: dismiss,
    action: button('Erneut'),
  });
  expect(screen.getByRole('alert')).toBeTruthy();
  expect(screen.getByText('Details')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Erneut' })).toBeTruthy();
  await fireEvent.click(screen.getByRole('button', { name: 'Hinweis schließen' }));
  expect(dismiss).toHaveBeenCalledOnce();
  void rerender({ tone: 'warn' });
  expect(screen.getByRole('status')).toBeTruthy();
  expect(screen.queryByRole('alert')).toBeNull();
});

it('Banner without ondismiss has no close button', () => {
  render(Banner, { tone: 'info', children: text('Hinweis') });
  expect(screen.queryByRole('button')).toBeNull();
});

it('EmptyState: title, description and primary action', () => {
  render(EmptyState, {
    title: 'Noch nichts da',
    description: 'Legen Sie etwas an.',
    action: button('Anlegen'),
  });
  expect(screen.getByText('Noch nichts da')).toBeTruthy();
  expect(screen.getByText('Legen Sie etwas an.')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Anlegen' })).toBeTruthy();
});

it('Skeleton is hidden from assistive technology', () => {
  const { container } = render(Skeleton, { class: 'h-10' });
  const el = container.querySelector('.skeleton');
  expect(el?.getAttribute('aria-hidden')).toBe('true');
  expect(el?.className).toContain('h-10');
});

it('Breadcrumb: last item is the current page, links navigate client-side', async () => {
  const navigate = vi.spyOn(router, 'navigate').mockImplementation(() => {});
  render(Breadcrumb, { items: [{ label: 'Kunde A', href: '/t/abc' }, { label: 'Formulare' }] });
  const link = screen.getByRole('link', { name: 'Kunde A' });
  await fireEvent.click(link);
  expect(navigate).toHaveBeenCalledWith('/t/abc');
  expect(screen.getByText('Formulare').getAttribute('aria-current')).toBe('page');
  navigate.mockRestore();
});

it('Breadcrumb renders nothing without items', () => {
  render(Breadcrumb, { items: [] });
  expect(screen.queryByRole('navigation')).toBeNull();
});
