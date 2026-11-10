import { describe, expect, it } from 'vitest';
import { render, screen, within } from '@testing-library/svelte';
import StatisticsChart from './StatisticsChart.svelte';
import StatisticsKpis from './StatisticsKpis.svelte';
import { fireEvent } from '@testing-library/svelte';
import { vi } from 'vitest';
import type { Statistics } from '$lib/api/admin';

const stats: Statistics = {
  from: '2026-10-01',
  to: '2026-10-30',
  total: 3,
  visits: 20,
  begins: 8,
  submits: 3,
  abandons: 4,
  conversion: 0.15,
  days: [
    {
      date: '2026-10-29',
      count: 2,
      visits: 20,
      begins: 6,
      submits: 2,
      abandons: 3,
      conversion: 0.1,
    },
    {
      date: '2026-10-30',
      count: 1,
      visits: 0,
      begins: 2,
      submits: 1,
      abandons: 1,
      conversion: null,
    },
  ],
};

describe('StatisticsChart', () => {
  it('labels all event counts and conversion in the same period', () => {
    render(StatisticsChart, { stats });
    const table = within(screen.getByRole('table'));
    for (const name of ['Besuche', 'Beginn', 'Absenden', 'Abbruch', 'Conversion']) {
      expect(table.getByRole('columnheader', { name })).toBeTruthy();
    }
    const row = within(screen.getByRole('row', { name: /29\.10\.2026/ }));
    for (const name of ['20', '6', '2', '3', '10\u00a0%']) {
      expect(row.getByRole('cell', { name })).toBeTruthy();
    }
  });
  it('shows undefined conversion without visits, including a late submit', () => {
    render(StatisticsChart, { stats });
    const row = within(screen.getByRole('row', { name: /30\.10\.2026/ }));
    expect(row.getByRole('cell', { name: '—' })).toBeTruthy();
    expect(row.getByRole('cell', { name: '0' })).toBeTruthy();
  });
  it('shows an empty period without invented conversions', () => {
    render(StatisticsChart, {
      stats: {
        ...stats,
        visits: 0,
        begins: 0,
        submits: 0,
        abandons: 0,
        total: 0,
        conversion: null,
        days: [],
      },
    });
    expect(screen.getByText('Keine erfassten Ereignisse im Zeitraum.')).toBeTruthy();
    expect(screen.queryByRole('table')).toBeNull();
  });
});

describe('StatisticsKpis', () => {
  it('shows the German period, the total conversion and the scope', () => {
    render(StatisticsKpis, { stats, days: 30 });
    expect(screen.getByText('15 %', { exact: true })).toBeTruthy();
    expect(screen.getByText('Produktion · UTC')).toBeTruthy();
    expect(screen.getByText(/01\.10\.–30\.10\.2026/)).toBeTruthy();
  });
  it('does not invent a conversion without visits', () => {
    render(StatisticsKpis, {
      stats: { ...stats, visits: 0, begins: 0, submits: 0, abandons: 0, total: 0, days: [] },
      days: 30,
    });
    expect(screen.getByText('Ohne Besuche nicht definiert')).toBeTruthy();
  });
  it('uses the ratio of totals and keeps values above 100 percent', () => {
    render(StatisticsKpis, { stats: { ...stats, visits: 2, submits: 3, conversion: 0 }, days: 30 });
    expect(screen.getByText('150 %', { exact: true })).toBeTruthy();
  });
  it('switches the period with pressed state', async () => {
    const onperiod = vi.fn();
    render(StatisticsKpis, { stats, days: 14, onperiod });
    expect(screen.getByRole('button', { name: '14 Tage' }).getAttribute('aria-pressed')).toBe(
      'true',
    );
    await fireEvent.click(screen.getByRole('button', { name: '30 Tage' }));
    expect(onperiod).toHaveBeenCalledWith(30);
  });
});

describe('StatisticsChart caption', () => {
  it('labels the chart', () => {
    render(StatisticsChart, { stats });
    expect(screen.getByText('Zeitreihe der erfassten Ereignisse')).toBeTruthy();
  });
});
