import { describe, expect, it } from 'vitest';
import { describeError, needsFreshLogin } from './describe';
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
