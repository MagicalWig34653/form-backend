import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { test, expect } from '@playwright/test';
import { sql } from './unlock-helpers';
import { env } from './helpers';
import { setupMailForm } from './mail-form-setup';
import { exactlyOneMail, expectAttachments, expectEnvelope, totalMessages } from './mail-helpers';

// Card 85E16E07, blocker criterion: a client that gives up while its request waits in the server's body-budget queue (BodyBudget.reserveWaiting,
// FORM_BODY_BUDGET_MB=64) must NOT be served afterwards. Otherwise the retry (same idempotency key) races a request the server still
// processes. Expected: while the budget is released later, nothing for the abandoned request appears (no submission row, no mail, > 20 s
// observation); the retry then yields exactly one submission and one mail. Sizes 19 MiB (upload cannot finish while the server does not
// read), 2 / 3.5 MiB (below 4 MiB: no wait window, 503 at once) and 4 / 6 / 8 MiB (queue, may fit into socket buffers). Synthetic data only.

const MIB = 1024 * 1024;
const HOLD_SECONDS = 10; // shorter than the 20 s wait: the budget really becomes free for the abandoned request
const OBSERVE_MS = 26_000;

function driver(
  credentials: string,
  mode: string,
  marker: string,
  bytes: number,
  timeoutMs?: number,
): string {
  return execFileSync(
    'php',
    [
      '-d',
      'memory_limit=1G',
      env('E2E_SUBMIT_DRIVER'),
      credentials,
      env('E2E_PUBLIC_URL'),
      marker,
      marker,
      mode,
      String(bytes),
      ...(timeoutMs ? [String(timeoutMs)] : []),
    ],
    { maxBuffer: 1 << 20, timeout: 240_000 },
  ).toString();
}

/** SHA-256 of the file the driver builds (same generator as detPdf in e2e-mail-resilience-submit.php). */
function sha(bytes: number, marker: string): string {
  const head = Buffer.from(`%PDF-1.4\nsynthetic ${marker}\n`);
  let block: Buffer = createHash('sha256').update(marker).digest();
  const parts: Buffer[] = [head];
  let len = head.length;
  while (len < bytes) {
    block = createHash('sha512').update(block).digest();
    const chunk = block.subarray(0, Math.min(64, bytes - len));
    parts.push(chunk);
    len += chunk.length;
  }
  return createHash('sha256').update(Buffer.concat(parts)).digest('hex');
}

async function holdBudget(formId: string): Promise<{ done: Promise<void> }> {
  // ONE stalled upload declaring 20 MiB reserves 60 of the 64 MiB and leaves 4 MiB: every larger request has to wait
  const holder = spawn('python3', [
    env('E2E_HOLD_SCRIPT'),
    env('E2E_PUBLIC_URL').split(':').pop()!,
    '127.0.0.1',
    formId,
    '1',
    String(20 * MIB),
    String(HOLD_SECONDS),
  ]);
  let said = '';
  const done = new Promise<void>((r) => holder.on('close', () => r()));
  await new Promise<void>((resolve, reject) => {
    holder.stdout.on('data', (d: Buffer) => {
      said += d.toString();
      if (said.includes('held')) resolve();
    });
    holder.on('close', () => reject(new Error(`holder could not take the budget: ${said}`)));
  });
  return { done };
}

test('client aborts while queued for the body budget: server must not process it afterwards', async ({
  page,
  context,
}) => {
  test.setTimeout(900_000);
  const { credentials, formId } = await setupMailForm(page, context);
  let expectedTotal = 0;
  for (const [marker, bytes] of [
    ['BUDGET-A-19M', 19 * MIB],
    ['BUDGET-B-2M', 2 * MIB],
    ['BUDGET-C-3M5', 3 * MIB + 512 * 1024],
    ['BUDGET-D-4M', 4 * MIB],
    ['BUDGET-E-6M', 6 * MIB],
    ['BUDGET-F-8M', 8 * MIB],
  ] as const) {
    const held = await holdBudget(formId);
    const t0 = Date.now();
    const out = driver(credentials, 'abort', marker, bytes, 2000).trim().split('\n');
    console.log(`${marker}: abort driver after ${Date.now() - t0} ms -> ${out.join(' | ')}`);
    // < 4 MiB (BodyBudget.minWaitBytes) the gate answers 503 at once (no queue), >= 4 MiB the request waits and the client times out
    expect(out[0], 'the abandoned request must not have been served (503 or timeout)').toBe(
      'aborted',
    );
    await held.done; // budget is free now; the queued request would be admitted from here on
    await new Promise((r) => setTimeout(r, OBSERVE_MS)); // longer than the 20 s maximum wait
    // Strict criterion
    console.log(
      `${marker}: after the budget was free: ${sql('SELECT COUNT(*) FROM submissions')} submissions, ${await totalMessages()} mails (expected ${expectedTotal})`,
    );
    expect(
      sql(`SELECT COUNT(*) FROM submissions`),
      `${marker}: nothing may be stored for the abandoned request`,
    ).toBe(String(expectedTotal));
    expect(await totalMessages(), `${marker}: no mail for the abandoned request`).toBe(
      expectedTotal,
    );
    // retry: same key, same bytes -> exactly one submission, one mail
    const id = driver(credentials, 'retry', marker, bytes).trim().split('\n')[0]!;
    expectedTotal += 1;
    expect(
      sql(`SELECT COUNT(*) FROM submissions`),
      `${marker}: the retry must not create a duplicate`,
    ).toBe(String(expectedTotal));
    const m = await exactlyOneMail(id, { timeoutMs: 120_000 });
    expectEnvelope(m, 'Neue Einsendung: Kontakt');
    await expectAttachments(m, [
      { sha: sha(bytes, marker), name: `budget-${marker}.pdf`, size: bytes },
    ]);
    await new Promise((r) => setTimeout(r, 3000));
    expect(await totalMessages()).toBe(expectedTotal);
    expect(sql(`SELECT COUNT(*) FROM submissions`)).toBe(String(expectedTotal));
  }
});
