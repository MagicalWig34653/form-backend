import { describe, expect, it } from 'vitest';
import { countDelta, formatPercent, pointsDelta } from './delta';

describe('delta', () => {
  it('liefert ohne Vergleichswerte nichts', () => {
    expect(countDelta(null)).toBeNull();
    expect(pointsDelta(null)).toBeNull();
  });
  it('gibt Anzahlen mit Vorzeichen und Richtung aus', () => {
    expect(countDelta({ current: 20, previous: 6 })).toMatchObject({ direction: 'up' });
    expect(countDelta({ current: 20, previous: 6 })?.text).toMatch(/^\+14 /);
    expect(countDelta({ current: 1, previous: 4 })).toMatchObject({ direction: 'down' });
    expect(countDelta({ current: 4, previous: 4 })?.direction).toBe('flat');
  });
  it('rechnet Quoten in Prozentpunkte um und rundet auf eine Stelle', () => {
    const up = pointsDelta({ current: 0.25, previous: 0.1 });
    expect(up?.direction).toBe('up');
    expect(up?.text).toMatch(/^\+15 /);
    expect(pointsDelta({ current: 0.1234, previous: 0.1 })?.text).toMatch(/^\+2,3 /);
    expect(pointsDelta({ current: 0.5, previous: 0.5 })?.direction).toBe('flat');
  });
  it('formatiert Prozent deutsch', () => {
    expect(formatPercent(0.25).replace(/\s/g, ' ')).toBe('25 %');
  });
});
