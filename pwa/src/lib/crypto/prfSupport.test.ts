import { describe, expect, it } from 'vitest';
import { detectPrfCapability, hasPrfOutput, notePrfOutcome, prfWasMissing } from './prfSupport';

const caps = (c: Record<string, boolean>) => ({ getClientCapabilities: async () => c });

describe('hasPrfOutput', () => {
  it('needs a 32 byte result', () => {
    expect(hasPrfOutput({ prf: { results: { first: new ArrayBuffer(32) } } })).toBe(true);
    expect(hasPrfOutput({ prf: { results: { first: new ArrayBuffer(16) } } })).toBe(false);
    expect(hasPrfOutput({ prf: { enabled: true } })).toBe(false);
    expect(hasPrfOutput({})).toBe(false);
    expect(hasPrfOutput(undefined)).toBe(false);
  });
});

describe('prf outcome flag', () => {
  it('remembers whether the last ceremony lacked PRF', () => {
    notePrfOutcome(false);
    expect(prfWasMissing()).toBe(true);
    notePrfOutcome(true);
    expect(prfWasMissing()).toBe(false);
  });
});

describe('detectPrfCapability', () => {
  it('reads extension:prf', async () => {
    expect(await detectPrfCapability(caps({ 'extension:prf': true }))).toBe('yes');
    expect(await detectPrfCapability(caps({ 'extension:prf': false }))).toBe('no');
    expect(await detectPrfCapability(caps({}))).toBe('unknown');
  });
  it('never throws when the API is missing or fails', async () => {
    expect(await detectPrfCapability(undefined)).toBe('unknown');
    expect(await detectPrfCapability({})).toBe('unknown');
    expect(
      await detectPrfCapability({
        getClientCapabilities: async () => {
          throw new Error('x');
        },
      }),
    ).toBe('unknown');
  });
});
