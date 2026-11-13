import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { expect, type Page } from '@playwright/test';
import { env } from './helpers';
import { target, uuidBin } from './migration-helpers';

// Helpers of backend/e2e-migration-existing.sh: row fingerprint of a customer's own data and the SDK submission.

/** Row hashes per table. Every row is hashed over all of its columns (hex), so any changed byte changes the hash. */
export type Snapshot = Map<string, string[]>;

/**
 * Fingerprint of everything that belongs to one customer: every table with a `customer_id` column (found in the
 * information schema, so a new table is covered without a code change) plus the customer row, its connections and
 * their secrets (these have no `customer_id`).
 */
export function snapshot(tenant: string, opts: { ignoreAudit?: string[] } = {}): Snapshot {
  const c = uuidBin(tenant);
  const colsOf = (tables: string): string =>
    `SELECT table_name, GROUP_CONCAT(CONCAT('IFNULL(HEX(\`',column_name,'\`),''~'')') ORDER BY ordinal_position SEPARATOR ',')
       FROM information_schema.columns WHERE table_schema='e2e' AND table_name IN (${tables}) GROUP BY table_name`;
  const scoped = target(
    `SELECT DISTINCT table_name FROM information_schema.columns c WHERE table_schema='e2e' AND column_name='customer_id'
       AND table_name NOT IN (SELECT table_name FROM information_schema.views WHERE table_schema='e2e') ORDER BY 1`,
  ).split('\n');
  const where = new Map<string, string>(scoped.map((t) => [t, `customer_id=${c}`]));
  where.set('customers', `id=${c}`);
  where.set(
    'connections',
    `id IN (SELECT connection_id FROM customer_connections WHERE customer_id=${c})`,
  );
  where.set(
    'managed_secrets',
    `ref IN (SELECT credential_ref FROM connections WHERE id IN (SELECT connection_id FROM customer_connections WHERE customer_id=${c}))`,
  );
  // Background reads that the browser's key automation audits on its own 30-s timer (not caused by the step under test).
  if (opts.ignoreAudit?.length)
    where.set(
      'audit_events',
      `customer_id=${c} AND action_code NOT IN (${opts.ignoreAudit.map((a) => `'${a.replace(/[^a-z.]/g, '')}'`).join(',')})`,
    );
  const names = [...where.keys()].map((t) => `'${t}'`).join(',');
  const columns = new Map(
    target(colsOf(names))
      .split('\n')
      .map((line) => {
        const [table, cols] = line.split('\t');
        return [table, cols] as [string, string];
      }),
  );
  const statement = [...where]
    .filter(([t]) => columns.has(t))
    .map(
      ([t, w]) => `SELECT '${t}', MD5(CONCAT_WS('|', ${columns.get(t)})) FROM \`${t}\` WHERE ${w}`,
    )
    .join('\nUNION ALL\n');
  const result: Snapshot = new Map();
  for (const line of target(`SET SESSION group_concat_max_len=1000000;\n${statement}`).split(
    '\n',
  )) {
    if (!line) continue;
    const [table, hash] = line.split('\t');
    result.set(table, [...(result.get(table) ?? []), hash].sort());
  }
  return result;
}

/** Number of rows per table of a snapshot as one comparable line. */
export const sizes = (s: Snapshot): string =>
  [...s]
    .map(([t, rows]) => `${t}=${rows.length}`)
    .sort()
    .join(' ');

/** All rows of `before` exist byte-identical in `after`; returns the tables where one is missing or changed. */
export function lost(before: Snapshot, after: Snapshot): string[] {
  return [...before]
    .filter(([t, rows]) => {
      const now = after.get(t) ?? [];
      return rows.some((h) => !now.includes(h));
    })
    .map(([t]) => t);
}

/** Issues the SDK credentials of the open form (Einbindung tab) and returns the file path. */
export async function issueCredentials(page: Page): Promise<string> {
  await page.getByRole('link', { name: 'Einbindung', exact: true }).first().click();
  await page.getByRole('button', { name: 'Zugangsdatei ausstellen' }).click();
  const file = await page.getByLabel('Zugangsdatei', { exact: true }).inputValue();
  const path = join(mkdtempSync(join(tmpdir(), 'e2e-existing-')), 'credentials.json');
  writeFileSync(path, file, { mode: 0o600 });
  return path;
}

/** A submission through the public ingest route with the PHP SDK. */
export function submit(credFile: string, key: string, marker: string): void {
  execFileSync(
    'php',
    [
      resolve(process.cwd(), '..', 'sdk', 'php', 'bin', 'submit.php'),
      '--credentials',
      credFile,
      '--url',
      env('E2E_PUBLIC_URL'),
      '--key',
      key,
      `nachricht=${marker}`,
    ],
    { encoding: 'utf8' },
  );
}

export async function expectError(page: Page, text: string | RegExp): Promise<void> {
  await expect(page.getByRole('alert').filter({ hasText: text })).toBeVisible({ timeout: 120_000 });
}
