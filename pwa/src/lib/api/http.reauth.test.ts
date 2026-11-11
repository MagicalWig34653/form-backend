import { afterEach, describe, expect, it, vi } from 'vitest';
import { createHttp, setReauthHandler } from './http';

const reauth = () =>
  new Response(JSON.stringify({ code: 'reauthentication_required', message: 'x' }), {
    status: 403,
    headers: { 'Content-Type': 'application/json' },
  });
const ok = () =>
  new Response(JSON.stringify({ items: [] }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });

afterEach(() => setReauthHandler(undefined));

describe('Bestätigung nach 403 reauthentication_required', () => {
  it('wiederholt den Aufruf genau einmal, wenn der Handler bestätigt', async () => {
    const fetchImpl = vi.fn().mockResolvedValueOnce(reauth()).mockResolvedValueOnce(ok());
    setReauthHandler(async () => true);
    const r = await createHttp({ fetchImpl }).request('GET', '/x');
    expect(r.ok).toBe(true);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });
  it('liefert den Fehler, wenn nicht bestätigt wurde (z. B. Weiterleitung zur Anmeldung)', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(reauth());
    const handler = vi.fn(async () => false);
    setReauthHandler(handler);
    const r = await createHttp({ fetchImpl }).request('GET', '/x');
    expect(r.ok).toBe(false);
    expect(handler).toHaveBeenCalledTimes(1);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });
  it('wiederholt nicht endlos, wenn auch der zweite Versuch abgelehnt wird', async () => {
    const fetchImpl = vi.fn().mockImplementation(async () => reauth());
    setReauthHandler(async () => true);
    const r = await createHttp({ fetchImpl }).request('GET', '/x');
    expect(r.ok).toBe(false);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });
});
