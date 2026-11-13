import { describe, expect, it } from 'vitest';
import { describeError, loadFailureText, needsFreshLogin } from './describe';
import type { ApiError } from '../api/client';

const err = (status: number, code?: string): ApiError => ({
  kind: 'http',
  status,
  ...(code ? { code } : {}),
  message: 'x',
});

describe('needsFreshLogin', () => {
  it('erkennt die abgelaufene Bestätigung (Server: 403, ältere Entwürfe: 401)', () => {
    expect(needsFreshLogin(err(403, 'reauthentication_required'))).toBe(true);
    expect(needsFreshLogin(err(401, 'reauthentication_required'))).toBe(true);
  });
  it('verwechselt andere Ablehnungen nicht damit', () => {
    expect(needsFreshLogin(err(403))).toBe(false);
    expect(needsFreshLogin(err(403, 'forbidden'))).toBe(false);
    expect(needsFreshLogin(err(401, 'unauthenticated'))).toBe(false);
    expect(needsFreshLogin({ kind: 'network', message: 'x' })).toBe(false);
  });
  it('nennt bei fehlender Bestätigung den Passkey statt „keine Berechtigung“', () => {
    expect(describeError(err(403, 'reauthentication_required'))).toMatch(/Passkey/);
    expect(describeError(err(403))).toMatch(/Berechtigung/);
  });
});

describe('429', () => {
  it('nennt die Wartezeit aus Retry-After', () => {
    expect(describeError({ ...err(429, 'rate_limited'), retryAfter: 42 })).toBe(
      'Zu viele Anfragen. Bitte in 42 Sekunden erneut versuchen.',
    );
    expect(describeError(err(429, 'rate_limited'))).toBe('Zu viele Anfragen. Bitte kurz warten.');
  });
  it('ersetzt bei Ladefehlern nur 429 durch die Wartemeldung', () => {
    expect(loadFailureText({ ...err(429), retryAfter: 7 }, 'Daten fehlen.')).toBe(
      'Zu viele Anfragen. Bitte in 7 Sekunden erneut versuchen.',
    );
    expect(loadFailureText(err(500), 'Daten fehlen.')).toBe('Daten fehlen.');
    expect(loadFailureText({ kind: 'network', message: 'x' }, 'Daten fehlen.')).toBe(
      'Daten fehlen.',
    );
  });
});
