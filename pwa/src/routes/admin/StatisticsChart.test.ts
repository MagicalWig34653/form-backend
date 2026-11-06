import { describe, expect, it } from 'vitest';
import { render, screen, within } from '@testing-library/svelte';
import StatisticsChart from './StatisticsChart.svelte';
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
    render(StatisticsChart, { stats, days: 30 });
    const table = within(screen.getByRole('table'));
    for (const name of ['Besuche', 'Beginn', 'Absenden', 'Abbruch', 'Conversion']) {
      expect(table.getByRole('columnheader', { name })).toBeTruthy();
    }
    expect(screen.getByText('15 %', { exact: true })).toBeTruthy();
    const row = within(screen.getByRole('row', { name: /2026-10-29/ }));
    for (const name of ['20', '6', '2', '3', '10\u00a0%']) {
      expect(row.getByRole('cell', { name })).toBeTruthy();
    }
  });
  it('shows undefined conversion without visits, including a late submit', () => {
    render(StatisticsChart, { stats, days: 30 });
    const row = within(screen.getByRole('row', { name: /2026-10-30/ }));
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
      days: 30,
    });
    expect(screen.getByText('Keine erfassten Ereignisse im Zeitraum.')).toBeTruthy();
    expect(screen.getByText('—', { exact: true })).toBeTruthy();
    expect(screen.queryByRole('table')).toBeNull();
  });
});

describe('StatisticsChart total conversion', () => {
  it('uses the ratio of totals, keeps values above 100 percent and labels scope', () => {
    render(StatisticsChart, {
      stats: { ...stats, visits: 2, submits: 3, conversion: 0 },
      days: 30,
    });
    expect(screen.getByText('150 %', { exact: true })).toBeTruthy();
    expect(screen.getByText('Produktion · UTC')).toBeTruthy();
    expect(screen.getByText('Zeitreihe der erfassten Ereignisse')).toBeTruthy();
  });
});
