import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import AdsStatisticsTable from './AdsStatisticsTable.svelte';
import type { AdsStatistics } from '$lib/api/admin';

const stats: AdsStatistics = {
  from: '2026-11-01',
  to: '2026-11-03',
  available: true,
  campaignsAvailable: false,
  minimumGroupSize: 5,
  suppressed: true,
  groups: [
    { segment: 'ads', visits: 10, submits: 5, conversion: 0.5 },
    { segment: 'nonAds', visits: 5, submits: 0, conversion: 0 },
    { segment: 'unknown', visits: 0, submits: 5, conversion: null },
  ],
};
describe('AdsStatisticsTable', () => {
  it('renders aggregate counts, ratios, unknown history and suppression', () => {
    render(AdsStatisticsTable, { stats });
    expect(screen.getByRole('table')).toBeTruthy();
    expect(screen.getByText('50 %')).toBeTruthy();
    expect(screen.getByText('—')).toBeTruthy();
    expect(screen.getByText('Nicht erfasst')).toBeTruthy();
    expect(screen.getByText('Kleine Gruppen wurden ausgeblendet.')).toBeTruthy();
    expect(screen.getByText(/Kampagnen werden nicht erfasst/)).toBeTruthy();
  });
  it('does not invent zero counts for suppressed or empty periods', () => {
    render(AdsStatisticsTable, { stats: { ...stats, groups: [] } });
    expect(screen.queryByRole('table')).toBeNull();
    expect(screen.getByText('Keine ausreichend großen Gruppen im Zeitraum.')).toBeTruthy();
  });
});
