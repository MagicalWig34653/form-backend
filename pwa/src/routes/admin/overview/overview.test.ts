import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import type { FormListItem, Statistics } from '$lib/api/admin';

const mocks = vi.hoisted(() => ({ navigate: vi.fn(), reduced: true }));
vi.mock('$lib/router.svelte', () => ({ router: { navigate: mocks.navigate } }));
vi.mock('$lib/motion', () => ({
  motion: {
    get reduced() {
      return mocks.reduced;
    },
  },
}));

import CountUp from './CountUp.svelte';
import Sparkline, { geometry } from './Sparkline.svelte';
import KpiTile from './KpiTile.svelte';
import AttentionList from './AttentionList.svelte';
import SetupProgress from './SetupProgress.svelte';
import RecentEntries from './RecentEntries.svelte';
import TenantOverview from './TenantOverview.svelte';
import { OverviewLoader } from '$lib/stats/loader.svelte';

beforeEach(() => {
  vi.clearAllMocks();
  mocks.reduced = true;
});

it('CountUp shows the end value directly when motion is reduced', () => {
  render(CountUp, { value: 1042 });
  expect(screen.getByTestId('countup-visual').textContent).toBe('1.042');
  expect(screen.getByTestId('countup-value').textContent).toBe('1.042');
  expect(screen.getByTestId('countup-visual').getAttribute('aria-hidden')).toBe('true');
});
it('CountUp starts at 0 and reaches the end value when animating', async () => {
  mocks.reduced = false;
  render(CountUp, { value: 50, duration: 100 });
  expect(screen.getByTestId('countup-visual').textContent).toBe('0');
  await waitFor(() => expect(screen.getByTestId('countup-visual').textContent).toBe('50'), {
    timeout: 5000,
  });
});

it('Sparkline geometry breaks lines at gaps and marks single points', () => {
  const g = geometry([1, 2, null, 3, null, 4, 5], 100, 20);
  expect(g.lines).toHaveLength(2);
  expect(g.dots).toHaveLength(1);
  expect(g.end).not.toBeNull();
  expect(geometry([null, null], 100, 20).lines).toHaveLength(0);
  expect(geometry([0, 0, 0], 100, 20).lines).toHaveLength(1);
});
it('Sparkline is an image with the full label', () => {
  render(Sparkline, { values: [1, 2, 3], label: 'Einsendungen: 1, 2, 3' });
  expect(screen.getByRole('img', { name: 'Einsendungen: 1, 2, 3' })).toBeTruthy();
});

it('KpiTile shows skeleton without a number while loading', () => {
  const { container } = render(KpiTile, { label: 'Einsendungen', status: 'loading' });
  expect(container.querySelector('[aria-busy="true"]')).toBeTruthy();
  expect(screen.queryByTestId('countup-value')).toBeNull();
});
it('KpiTile shows a dash and a reason instead of a zero', () => {
  const view = render(KpiTile, { label: 'Besuche', status: 'unavailable' });
  expect(screen.getByText('Die Statistik konnte nicht geladen werden.')).toBeTruthy();
  expect(screen.queryByTestId('countup-value')).toBeNull();
  view.unmount();
  render(KpiTile, { label: 'Conversion', value: null, reason: 'Ohne Besuche nicht definiert' });
  expect(screen.getByText('Ohne Besuche nicht definiert')).toBeTruthy();
});
it('KpiTile shows value, sparkline and delta text', () => {
  render(KpiTile, {
    label: 'Einsendungen',
    hint: 'Hilfe',
    value: 128,
    series: [1, 2, 3],
    seriesLabel: 'Verlauf',
    delta: { direction: 'up', text: '+14 ggü. Vorwoche' },
  });
  expect(screen.getByTestId('countup-value').textContent).toBe('128');
  expect(screen.getByRole('img', { name: 'Verlauf' })).toBeTruthy();
  expect(screen.getByText('+14 ggü. Vorwoche')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Hilfe' })).toBeTruthy();
});

it('AttentionList names the form and opens the right tab', async () => {
  render(AttentionList, {
    tenant: 't',
    items: [{ id: 'n', tone: 'warn', kind: 'noMail', formId: 'f', formName: 'Kontakt' }],
  });
  expect(screen.getByText('Kontakt: Kein Versandweg für Mails gewählt.')).toBeTruthy();
  await fireEvent.click(screen.getByRole('button', { name: /Versandweg wählen/ }));
  expect(mocks.navigate).toHaveBeenCalledWith('/t/t/f/f/mail');
});
it('AttentionList says so when there is nothing to report', () => {
  render(AttentionList, { tenant: 't', items: [] });
  expect(screen.getByText('Keine weiteren Hinweise.')).toBeTruthy();
});

it('SetupProgress reports progress and opens the next step', async () => {
  render(SetupProgress, {
    tenant: 't',
    steps: [
      { id: 'form', done: true, formId: 'f' },
      { id: 'mail', done: false, formId: 'f' },
      { id: 'published', done: null },
    ],
  });
  expect(screen.getByRole('progressbar').getAttribute('aria-valuenow')).toBe('33');
  await fireEvent.click(screen.getByRole('button', { name: /Versandweg wählen/ }));
  expect(mocks.navigate).toHaveBeenCalledWith('/t/t/f/f/mail');
});

it('RecentEntries lists metadata and distinguishes empty from unavailable', async () => {
  const now = Date.parse('2026-11-06T12:00:00Z');
  const { unmount } = render(RecentEntries, {
    tenant: 't',
    status: 'ready',
    now,
    rows: [
      {
        id: 'e',
        formId: 'f',
        formName: 'Kontakt',
        receivedAt: '2026-11-06T11:48:00Z',
        state: 'accepted',
        held: true,
      },
    ],
  });
  expect(screen.getByText('vor 12 Minuten')).toBeTruthy();
  expect(screen.getByText('Angenommen')).toBeTruthy();
  expect(screen.getByText('Geschützt')).toBeTruthy();
  await fireEvent.click(screen.getByRole('link', { name: /Einsendung öffnen: Kontakt/ }));
  expect(mocks.navigate).toHaveBeenCalledWith('/t/t/f/f/entries');
  unmount();
  render(RecentEntries, { tenant: 't', status: 'unavailable', rows: [] });
  expect(screen.getByText('Die letzten Einsendungen konnten nicht geladen werden.')).toBeTruthy();
  expect(screen.queryByText('Noch keine Einsendungen.')).toBeNull();
});

const forms: FormListItem[] = [
  { id: 'a', name: 'Kontakt', active: true, currentReleaseId: 'r' },
  { id: 'b', name: 'Anfrage', active: false, currentReleaseId: null },
];
const stat = (visits: number, submits: number): Statistics => ({
  from: '2026-10-19',
  to: '2026-11-01',
  total: submits,
  visits,
  begins: 0,
  submits,
  abandons: 0,
  conversion: null,
  days: [
    {
      date: '2026-11-01',
      count: submits,
      visits,
      begins: 0,
      submits,
      abandons: 0,
      conversion: null,
    },
  ],
});
const fail = async () => ({ ok: false as const, error: { status: 500 } });

it('TenantOverview aggregates the loaded forms and keeps failures local', async () => {
  const api = {
    statistics: vi.fn(async (_t: string, id: string) =>
      id === 'a' ? { ok: true as const, data: stat(20, 5) } : await fail(),
    ),
    form: vi.fn(async (_t: string, id: string) => ({
      ok: true as const,
      data: {
        id,
        name: id,
        active: true,
        currentReleaseId: null,
        currentReleaseVersion: null,
        draftIds: [],
        mailConnectionId: null,
      },
    })),
    entries: vi.fn(async () => ({
      ok: true as const,
      data: {
        items: [
          {
            id: 'e1',
            receivedAt: '2026-11-01T10:00:00Z',
            state: 'accepted',
            releaseId: null,
            keyId: null,
            held: false,
          },
        ],
        nextCursor: null,
      },
    })),
  };
  const loader = new OverviewLoader(api as never);
  const view = render(TenantOverview, { tenant: 't', forms, loader, locked: true });
  await loader.load('t', forms);
  await waitFor(() => expect(screen.getAllByTestId('countup-value')[0]?.textContent).toBe('5'));
  const values = screen.getAllByTestId('countup-value').map((n) => n.textContent);
  expect(values).toContain('20');
  expect(values.some((v) => /^25\s%$/.test(v ?? ''))).toBe(true);
  expect(screen.getByText(/Summe von 1 von 2 Formularen/)).toBeTruthy();
  expect(
    screen.getByText('Der Zugriff auf Einsendungen ist in diesem Browser gesperrt.'),
  ).toBeTruthy();
  expect(
    screen.getByText('Anfrage: Noch nicht veröffentlicht, nimmt keine Einsendungen an.'),
  ).toBeTruthy();
  expect(view.container.querySelectorAll('[data-testid="sparkline"]').length).toBeGreaterThan(0);
});
it('TenantOverview shows unavailable tiles and never a zero when all statistics fail', async () => {
  const api = { statistics: vi.fn(fail), form: vi.fn(fail), entries: vi.fn(fail) };
  const loader = new OverviewLoader(api as never);
  render(TenantOverview, { tenant: 't', forms, loader, onreload: () => {} });
  await loader.load('t', forms);
  await screen.findAllByText('Die Statistik konnte nicht geladen werden.');
  expect(screen.getByText('Die letzten Einsendungen konnten nicht geladen werden.')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Daten neu laden' })).toBeTruthy();
});
