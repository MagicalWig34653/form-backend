import { describe, expect, it } from 'vitest';
import { t } from '$lib/i18n';
import { formStatus } from './formStatus';

describe('formStatus', () => {
  it('nennt nie veröffentlichte Formulare Entwurf, unabhängig vom Schalter', () => {
    expect(formStatus(false, false)).toEqual({ tone: 'idle', label: t.status.draft });
    expect(formStatus(false, true)).toEqual({ tone: 'idle', label: t.status.draft });
  });
  it('unterscheidet Live und Pausiert bei veröffentlichten Formularen', () => {
    expect(formStatus(true, true)).toEqual({ tone: 'ok', label: t.status.live });
    expect(formStatus(true, false)).toEqual({ tone: 'warn', label: t.status.paused });
  });
});
