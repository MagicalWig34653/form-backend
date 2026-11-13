import { describe, expect, it } from 'vitest';
import { rightHint, rightLabel, rightsOf, rightsText } from './rights';

describe('rights', () => {
  it('übersetzt bekannte Rechte in Klartext', () => {
    expect(rightLabel('form.read')).toBe('Lesen');
    expect(rightHint('release.publish')).toContain('veröffentlichen');
  });
  it('zeigt unbekannte Schlüssel unverändert und ohne Beschreibung', () => {
    expect(rightLabel('x.unknown')).toBe('x.unknown');
    expect(rightHint('x.unknown')).toBe('');
  });
  it('fasst mehrere Rechte kommagetrennt zusammen', () => {
    expect(rightsText(['form.read', 'draft.write'])).toBe('Lesen, Bearbeiten');
    expect(rightsText([])).toBe('');
  });
  it('lists customer-wide rights in catalogue order with reading implied', () => {
    expect(rightsOf(['key.manage', 'draft.write'])).toEqual(['Lesen', 'Bearbeiten', 'Schlüssel']);
    expect(rightsOf([])).toEqual(['Lesen']);
  });
});
