// @vitest-environment node
// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, it } from 'vitest';
import fixture from './fixtures/rotation.json';
import { rewrapPackage } from './rewrap';
import { identity, openPackage, parsePackage } from './packageV2';
const hex = (s: string): Uint8Array =>
  Uint8Array.from(s.match(/../g)?.map((h) => parseInt(h, 16)) ?? []);
const oldSecret = hex(fixture.oldSecret);
const nextSecret = hex(fixture.newSecret);

describe('CEK-Rewrap ohne Nutzdatenänderung', () => {
  for (const vector of fixture.cases) {
    it(`erzeugt und öffnet festen Swift-Kreuzvektor ${vector.name}`, async () => {
      const target = vector.name.endsWith('hpke')
        ? { wrap: 'hpke' as const, publicKey: hex(fixture.newPublicKey), secret: nextSecret }
        : { wrap: 'sym' as const, secret: nextSecret };
      const result = await rewrapPackage(vector.source, oldSecret, target, {
        ephemeral: new Uint8Array(32).fill(0x77),
        iv: new Uint8Array(12).fill(0x88),
      });
      expect(result).toBe(vector.package);
      expect(result.split('|').slice(4)).toEqual(vector.source.split('|').slice(4));
      expect(await openPackage(result, nextSecret)).toEqual(hex(vector.plaintext));
      await expect(openPackage(result, oldSecret)).rejects.toThrow();
      expect(parsePackage(result).kid).toBe((await identity(nextSecret)).kid);
    });
  }
  it('verbietet sym→hpke und falsche Quellschlüssel', async () => {
    const target = {
      wrap: 'hpke' as const,
      publicKey: hex(fixture.newPublicKey),
      secret: nextSecret,
    };
    await expect(rewrapPackage(fixture.cases[2]!.source, oldSecret, target)).rejects.toThrow(
      'wrapDowngrade',
    );
    await expect(rewrapPackage(fixture.cases[0]!.source, nextSecret, target)).rejects.toThrow(
      'keyMismatch',
    );
  });
  it('hängt Hold auf derselben Generation um und erhält die Nutzbytes', async () => {
    const source = fixture.cases[0]!.source;
    const held = await rewrapPackage(source, oldSecret, { wrap: 'sym', secret: oldSecret });
    expect(parsePackage(held).kid).toBe(parsePackage(source).kid);
    expect(parsePackage(held).wrap).toBe('sym');
    expect(held.split('|').slice(4)).toEqual(source.split('|').slice(4));
    expect(await openPackage(held, oldSecret)).toEqual(await openPackage(source, oldSecret));
  });
  it('verwendet frische Wrap-Zufallswerte', async () => {
    const target = { wrap: 'sym' as const, secret: nextSecret };
    const a = await rewrapPackage(fixture.cases[0]!.source, oldSecret, target);
    const b = await rewrapPackage(fixture.cases[0]!.source, oldSecret, target);
    expect(a).not.toBe(b);
    expect(await openPackage(a, nextSecret)).toEqual(await openPackage(b, nextSecret));
  });
});

it('Hold benutzt stabile Kopien auch wenn der ursprüngliche Buffer zwischen awaits genullt wird', async () => {
  const source = oldSecret.slice();
  const run = rewrapPackage(fixture.cases[0]!.source, source, { wrap: 'sym', secret: source });
  source.fill(0);
  const result = await run;
  expect(await openPackage(result, oldSecret)).toEqual(
    await openPackage(fixture.cases[0]!.source, oldSecret),
  );
});

it('verweigert HPKE-Ausgabe wenn der neue Wrap nicht mit dem Zielschlüssel öffnet', async () => {
  await expect(
    rewrapPackage(fixture.cases[0]!.source, oldSecret, {
      wrap: 'hpke',
      publicKey: hex(fixture.newPublicKey),
      secret: oldSecret,
    }),
  ).rejects.toThrow('keyMismatch');
});
