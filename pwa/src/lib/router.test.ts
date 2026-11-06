import { describe, expect, it } from 'vitest';
import { router } from './router.svelte';

describe('router.navigate', () => {
  it('keeps query/hash out of the route path', () => {
    router.navigate('/login?next=/x#h');
    expect(router.path).toBe('/login');
  });

  it('rejects protocol-relative and backslash targets', () => {
    router.navigate('/login');
    router.navigate('//evil.example/x');
    router.navigate('/\\evil.example');
    expect(router.path).toBe('/login');
  });
});
