// @vitest-environment node
import { expect, it, vi } from 'vitest';
import fixture from './synthetic.fixture.json';
import { ciphertextHash, verifyMigrationProbe } from './migrationProbe';
const key = () => Uint8Array.from(fixture.sk.match(/../g)!.map((h) => parseInt(h, 16)));
it('authentifiziert die Altprobe, bestätigt zuerst und prüft eine frische Testverschlüsselung', async () => {
  const secret = key(),
    wire = fixture.packets[0]!.packet;
  const confirm = vi.fn(async () => {});
  const result = await verifyMigrationProbe(wire, await ciphertextHash(wire), secret, confirm);
  expect(confirm).toHaveBeenCalledWith(await ciphertextHash(wire));
  expect(result).toMatch(/^[a-f0-9]{64}$/);
  expect(secret.every((b) => b === 0)).toBe(true);
});
it('lehnt falschen Schlüssel und manipulierten Hash ohne Serverbestätigung ab', async () => {
  const wire = fixture.packets[0]!.packet,
    confirm = vi.fn(async () => {});
  for (const [secret, hash] of [
    [new Uint8Array(32), await ciphertextHash(wire)],
    [key(), '0'.repeat(64)],
  ] as const) {
    await expect(verifyMigrationProbe(wire, hash, secret, confirm)).rejects.toThrow();
    expect(secret.every((b) => b === 0)).toBe(true);
  }
  expect(confirm).not.toHaveBeenCalled();
});
it('beendet bei abgebrochener Bestätigung und nullt den Schlüssel', async () => {
  const secret = key(),
    wire = fixture.packets[0]!.packet;
  await expect(
    verifyMigrationProbe(wire, await ciphertextHash(wire), secret, async () => {
      throw new Error('cancelled');
    }),
  ).rejects.toThrow('cancelled');
  expect(secret.every((b) => b === 0)).toBe(true);
});
