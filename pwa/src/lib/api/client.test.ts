import { describe, expect, it } from 'vitest';
import { createApiClient } from './client';

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

describe('api client health', () => {
  it('returns data on success and requests uncached', async () => {
    let seen: { url: string; init?: RequestInit } | undefined;
    const api = createApiClient({
      baseUrl: '/x',
      fetchImpl: async (url, init) => {
        seen = { url: String(url), init };
        return json({ status: 'ok' });
      },
    });
    const r = await api.health();
    expect(r).toEqual({ ok: true, data: { status: 'ok' } });
    expect(seen?.url).toBe('/x/health');
    expect(seen?.init?.cache).toBe('no-store');
  });

  it('maps HTTP errors with status', async () => {
    const api = createApiClient({ fetchImpl: async () => json({}, 503) });
    const r = await api.health();
    expect(r).toMatchObject({ ok: false, error: { kind: 'http', status: 503 } });
  });

  it('maps network failures', async () => {
    const api = createApiClient({
      fetchImpl: async () => {
        throw new TypeError('fail');
      },
    });
    expect(await api.health()).toMatchObject({ ok: false, error: { kind: 'network' } });
  });

  it('maps invalid JSON', async () => {
    const api = createApiClient({ fetchImpl: async () => new Response('nope', { status: 200 }) });
    expect(await api.health()).toMatchObject({ ok: false, error: { kind: 'parse' } });
  });

  it('maps caller abort', async () => {
    const c = new AbortController();
    c.abort();
    const api = createApiClient({
      fetchImpl: async (_u, init) => {
        init?.signal?.throwIfAborted();
        return json({});
      },
    });
    expect(await api.health(c.signal)).toMatchObject({ ok: false, error: { kind: 'aborted' } });
  });

  it('maps timeout', async () => {
    const api = createApiClient({
      timeoutMs: 5,
      fetchImpl: (_u, init) =>
        new Promise((_res, rej) =>
          init?.signal?.addEventListener('abort', () => rej(new Error('x'))),
        ),
    });
    expect(await api.health()).toMatchObject({ ok: false, error: { kind: 'timeout' } });
  });
});

describe('api client defaults', () => {
  it('uses the admin API base path', async () => {
    let url = '';
    const api = createApiClient({
      fetchImpl: async (u) => {
        url = String(u);
        return new Response('{"status":"ok"}');
      },
    });
    await api.health();
    expect(url).toBe('/admin/api/v1/health');
  });

  it('reports abort during body read as aborted, not parse', async () => {
    const c = new AbortController();
    const api = createApiClient({
      fetchImpl: async () => {
        const res = new Response('{}');
        res.json = async () => {
          c.abort();
          throw new DOMException('aborted', 'AbortError');
        };
        return res;
      },
    });
    expect(await api.health(c.signal)).toMatchObject({ ok: false, error: { kind: 'aborted' } });
  });
});
