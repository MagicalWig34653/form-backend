import { createHash } from 'node:crypto';
import { expect } from '@playwright/test';
import { env } from './helpers';

// Shared hard checks of the mail end-to-end chain (Mailpit = real SMTP server): exactly one mail per submission, recipient, subject, content,
// attachments byte for byte (SHA-256 over the Mailpit part download). Synthetic data only.

export const mailpit = (path: string) => `http://127.0.0.1:${env('E2E_MAILPIT_API')}${path}`;

export type Att = { PartID: string; FileName: string; ContentType: string; Size: number };
export type Detail = {
  ID: string;
  Subject: string;
  Text: string;
  Attachments: Att[];
  To: { Address: string }[];
  From: { Address: string };
};

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Number of messages stored in Mailpit right now (all recipients). */
export async function totalMessages(): Promise<number> {
  const info = (await (await fetch(mailpit('/api/v1/messages?limit=1'))).json()) as {
    total: number;
  };
  return info.total;
}

export async function clearMailbox(): Promise<void> {
  await fetch(mailpit('/api/v1/messages'), { method: 'DELETE' });
}

async function findIds(needle: string): Promise<string[]> {
  const res = (await (
    await fetch(mailpit(`/api/v1/search?query=${encodeURIComponent(needle)}&limit=50`))
  ).json()) as { messages: { ID: string }[] };
  return res.messages.map((m) => m.ID);
}

/**
 * Waits for the mail of one submission (found by its submission id in the text), then lets the system settle and asserts that
 * there is EXACTLY ONE such mail. Returns its detail.
 */
export async function exactlyOneMail(
  id: string,
  opts: { timeoutMs?: number; settleMs?: number } = {},
): Promise<Detail> {
  const deadline = Date.now() + (opts.timeoutMs ?? 120_000);
  let ids: string[] = [];
  while (Date.now() < deadline) {
    ids = await findIds(id);
    if (ids.length > 0) break;
    await sleep(500);
  }
  expect(ids.length, `no mail for submission ${id} arrived`).toBeGreaterThan(0);
  await sleep(opts.settleMs ?? 3000);
  ids = await findIds(id);
  expect(ids, `submission ${id} must produce exactly one mail`).toHaveLength(1);
  return (await (await fetch(mailpit(`/api/v1/message/${ids[0]!}`))).json()) as Detail;
}

export function expectEnvelope(d: Detail, subject: string) {
  expect(d.Subject).toBe(subject);
  expect(d.To.map((t) => t.Address)).toEqual(['team@example.org']);
  expect(d.From.Address).toBe('formular@example.org');
}

export async function partSha256(d: Detail, a: Att): Promise<string> {
  const res = await fetch(mailpit(`/api/v1/message/${d.ID}/part/${a.PartID}`));
  return createHash('sha256')
    .update(Buffer.from(await res.arrayBuffer()))
    .digest('hex');
}

/** Attachments byte for byte: same names, same sizes, same SHA-256. */
export async function expectAttachments(
  d: Detail,
  files: { sha: string; name: string; size?: number }[],
) {
  expect(d.Attachments.map((a) => a.FileName).sort()).toEqual(files.map((f) => f.name).sort());
  for (const f of files) {
    const a = d.Attachments.find((x) => x.FileName === f.name)!;
    if (f.size !== undefined) expect(a.Size).toBe(f.size);
    expect(await partSha256(d, a)).toBe(f.sha);
  }
}
