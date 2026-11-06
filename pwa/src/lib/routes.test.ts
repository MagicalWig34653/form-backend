import { describe, expect, it } from 'vitest';
import { formPath, matchRoute, safeNext } from './routes';

const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
const F = '22222222-2222-4222-8222-222222222222';

describe('matchRoute', () => {
  it('matches the known paths', () => {
    expect(matchRoute('/login')).toEqual({ name: 'login' });
    expect(matchRoute('/t')).toEqual({ name: 'tenants' });
    expect(matchRoute(`/t/${T}`)).toEqual({ name: 'forms', tenant: T });
    expect(matchRoute(`/t/${T}/f/${F}`)).toEqual({
      name: 'form',
      tenant: T,
      form: F,
      tab: 'overview',
    });
    expect(matchRoute(`/t/${T}/f/${F}/mail`)).toEqual({
      name: 'form',
      tenant: T,
      form: F,
      tab: 'mail',
    });
    expect(matchRoute('/connections')).toEqual({ name: 'connections' });
    expect(matchRoute('/account')).toEqual({ name: 'account' });
    expect(matchRoute('/t/aaaaaaaa-1111-4111-8111-11111111111a/members')).toEqual({
      name: 'members',
      tenant: 'aaaaaaaa-1111-4111-8111-11111111111a',
    });
    expect(matchRoute('/t/aaaaaaaa-1111-4111-8111-11111111111a/members/x')).toEqual({
      name: 'notFound',
    });
  });
  it('rejects anything that is not a lower-case UUID or a known tab', () => {
    for (const p of [
      '/t/abc',
      `/t/${T.toUpperCase()}`,
      `/t/${T}/f/x`,
      `/t/${T}/f/${F}/nope`,
      `/t/${T}/f/${F}/mail/x`,
      `/t/${T}/x`,
      '/x',
      `/t/${T}%2f..`,
    ])
      expect(matchRoute(p).name, p).toBe('notFound');
  });
  it('builds the paths it matches', () => {
    expect(matchRoute(formPath(T, F, 'keys'))).toMatchObject({ tab: 'keys' });
    expect(formPath(T, F)).toBe(`/t/${T}/f/${F}`);
  });
  it('safeNext only accepts local app paths', () => {
    expect(safeNext(`/t/${T}`)).toBe(`/t/${T}`);
    for (const x of [null, '', '//evil.example', 'https://evil.example', '/\\evil', '/nothing'])
      expect(safeNext(x), String(x)).toBeNull();
  });
});
