import { describe, expect, it } from 'vitest';
import {
  NO_VALUE,
  formatClock,
  formatDateTime,
  formatDay,
  formatDayShort,
  formatPeriod,
} from './format';

describe('format', () => {
  it('formats calendar days independent of the time zone', () => {
    expect(formatDay('2026-10-31')).toBe('31.10.2026');
    expect(formatDayShort('2026-10-31')).toBe('31.10.');
  });
  it('formats date and time in UTC on request', () => {
    expect(formatDateTime('2026-11-03T10:00:00Z', { utc: true })).toBe('03.11.2026, 10:00');
    expect(formatDay('2026-11-03T23:30:00Z', { utc: true })).toBe('03.11.2026');
  });
  it('formats periods compactly', () => {
    expect(formatPeriod('2026-10-03', '2026-11-01')).toBe('03.10.–01.11.2026');
    expect(formatPeriod('2025-12-28', '2026-01-03')).toBe('28.12.2025–03.01.2026');
  });
  it('never shows undefined or Invalid Date', () => {
    for (const bad of [undefined, null, '', 'nope', 'undefined', NaN]) {
      expect(formatDay(bad as never)).toBe(NO_VALUE);
      expect(formatDateTime(bad as never)).toBe(NO_VALUE);
      expect(formatClock(bad as never)).toBe(NO_VALUE);
      expect(formatDayShort(bad as never)).toBe(NO_VALUE);
    }
    expect(formatPeriod(undefined, '2026-01-01')).toBe(NO_VALUE);
    expect(formatClock(new Date(NaN))).toBe(NO_VALUE);
  });
});
