import { describe, expect, it, vi } from 'vitest';
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

  it('asks the guard first: false stays, a promise settles later, replace bypasses it', async () => {
    router.navigate('/login');
    const answers: (boolean | Promise<boolean>)[] = [false, Promise.resolve(true)];
    const guard = vi.fn(() => answers.shift() ?? true);
    const release = router.setGuard(guard);
    router.navigate('/setup');
    expect(router.path).toBe('/login');
    router.navigate('/setup');
    expect(router.path).toBe('/login');
    await Promise.resolve();
    await Promise.resolve();
    expect(router.path).toBe('/setup');
    router.navigate('/login', true);
    expect(router.path).toBe('/login');
    expect(guard).toHaveBeenCalledTimes(2);
    release();
    router.navigate('/setup');
    expect(router.path).toBe('/setup');
    expect(guard).toHaveBeenCalledTimes(2);
  });
});
