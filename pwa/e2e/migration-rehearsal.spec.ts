import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// Whole migration path of the PWA against a stateful mock of the admin routes. The source answer is the golden
// inventory the backend test ImportRehearsalTests checks against the real legacy schema, so page and backend
// are tested against the same data. SHOTS=dir writes screenshots for review.
const golden = JSON.parse(
  readFileSync(resolve(process.cwd(), '../contracts/migration/rehearsal-golden.json'), 'utf8'),
) as { inventory: Record<string, unknown> & { schemaHMAC: string }; plan: Record<string, unknown> };
const inventory = { ...golden.inventory, schemaHMAC: 'c'.repeat(64) };
const shots = process.env.SHOTS;
const shot = async (page: Page, name: string) => {
  if (shots) await page.screenshot({ path: `${shots}/${name}.png`, fullPage: true });
};

const issues = [
  { code: 'migration-review', count: 6 },
  { code: 'unmapped-table', count: 2 },
  { code: 'unsupported-content', count: 10 },
];
const tables = {
  anfragen: { sourceCount: 30, importedCount: 30, reviewCount: 10 },
  datenschluessel: { sourceCount: 2, importedCount: 2, reviewCount: 0 },
  formulare: { sourceCount: 3, importedCount: 3, reviewCount: 0 },
  statistics: { sourceCount: 6, importedCount: 0, reviewCount: 6 },
};
const reportFor = (dryRun: boolean) => ({
  dryRun,
  schemaHMAC: 'c'.repeat(64),
  inventory: golden.inventory.counts,
  tables,
  issues,
  cutoverReady: false,
});

interface Mock {
  jobs: unknown[];
  posted: Array<{ path: string; body: unknown }>;
  frames: unknown[][];
  testReply: { status: number; body: unknown };
}

async function mock(page: Page, setup: Partial<Mock> = {}): Promise<Mock> {
  const state: Mock = {
    jobs: [],
    posted: [],
    frames: [],
    testReply: { status: 200, body: inventory },
    ...setup,
  };
  await page.route('**/admin/api/v1/**', async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    let body: unknown = {};
    let status = 200;
    if (path.endsWith('/auth/session')) body = { state: 'authenticated', csrfToken: 'csrf' };
    else if (path.endsWith('/me')) body = { id: 'a', username: 'Test', systemAdministrator: true };
    else if (path.endsWith('/setup-state'))
      body = { required: false, migrationAllowed: true, migrationEnabled: true };
    else if (path.endsWith('/me/key-bundle'))
      body = { rpId: 'localhost', accountPublicKey: null, wraps: [], access: [], recovery: null };
    else if (path.endsWith('/tenants')) body = { items: [] };
    else if (path.endsWith('/migration/test')) {
      status = state.testReply.status;
      body = state.testReply.body;
    } else if (path.endsWith('/migration/jobs') && request.method() === 'POST') {
      state.posted.push({ path, body: request.postDataJSON() });
      body = { id: '77777777-7777-4777-8777-777777777777' };
    } else if (/\/migration\/jobs\/[^/]+\/[a-z-]+$/.test(path) && request.method() === 'POST') {
      state.posted.push({ path, body: null });
      body = { status: 'accepted' };
    } else if (path.endsWith('/migration/jobs')) {
      // Each poll shows the next frame; the last one stays.
      const frame = state.frames.length > 1 ? state.frames.shift()! : (state.frames[0] ?? []);
      body = { items: frame ?? state.jobs };
    }
    await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
  });
  return state;
}

const job = (over: Record<string, unknown>) => ({
  id: '77777777-7777-4777-8777-777777777777',
  formIds: Object.keys((golden.plan.formCustomers ?? {}) as object),
  probeConfirmed: false,
  testConfirmed: false,
  error: '',
  ...over,
});

async function check(page: Page) {
  await page.goto('/migration');
  await page.getByLabel('Host').fill('db.example.test');
  await page.getByLabel('Datenbank').fill('altsystem');
  await page.getByLabel('Benutzer').fill('lesen');
  await page.getByLabel('Passwort').fill('synthetisch');
  await page.getByRole('button', { name: 'Verbindung prüfen' }).click();
}

test('Gesamtablauf: Quelle prüfen, automatische Zuordnung, Prüflauf, Fortschritt, Import, Ergebnis', async ({
  page,
}) => {
  test.setTimeout(90_000);
  const state = await mock(page, {
    frames: [
      [],
      [
        job({
          state: 'running',
          phase: 'formulare',
          dryRun: true,
          report: { processed: 12 },
        }),
      ],
      [
        job({
          state: 'running',
          phase: 'anfragen',
          dryRun: true,
          report: { processed: 24 },
        }),
      ],
      [job({ state: 'review', phase: 'verification', dryRun: true, report: reportFor(true) })],
    ],
  });
  await check(page);
  await expect(page.getByText('Prüfbericht der Quelle')).toBeVisible();
  await shot(page, '01-quelle');
  await page.getByRole('button', { name: 'Weiter' }).click();

  // Automatic assignment from the source check; only the customer name is typed.
  await expect(page.getByRole('heading', { name: 'Zuordnung', exact: true })).toBeVisible();
  await expect(page.getByTestId('migration-forms')).toContainText('Kontaktformular Müller');
  await expect(page.getByTestId('migration-forms')).toContainText('Ohne Namen');
  const keys = page.getByTestId('migration-keys');
  await expect(keys).toContainText('Generation 1');
  await expect(keys).toContainText('Generation 2');
  await expect(page.getByTestId('migration-key-warning')).toHaveCount(0);
  await expect(page.getByTestId('migration-stats-notice')).toContainText('6 Statistikzeilen');
  const start = page.getByRole('button', { name: 'Prüflauf starten' });
  await expect(start).toBeDisabled();
  await page.getByLabel('Kundenname', { exact: false }).fill('Müller & Söhne GmbH');
  await expect(page.getByTestId('migration-summary')).toContainText('Der Plan ist vollständig.');
  await shot(page, '02-zuordnung');
  await start.click();
  await expect.poll(() => state.posted.length).toBe(1);
  const sent = state.posted[0]!.body as {
    plan: Record<string, Record<string, unknown>>;
    dryRun: boolean;
  };
  expect(sent.dryRun).toBe(true);
  expect(Object.keys(sent.plan.keyCustomers!)).toHaveLength(2);
  expect(Object.values(sent.plan.keyGenerationNumbers!).sort()).toEqual([1, 2]);

  // Progress: phase and counter follow the job frames, then the review of the dry run.
  await expect(page.getByRole('status').filter({ hasText: 'Phase: formulare' })).toBeVisible({
    timeout: 15_000,
  });
  await shot(page, '03-fortschritt');
  await expect(page.getByRole('status').filter({ hasText: 'Phase: anfragen' })).toBeVisible({
    timeout: 15_000,
  });
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 15_000 });
  await shot(page, '04-pruefung-abgeschlossen');

  // Real import, then the result.
  state.frames = [
    [job({ state: 'running', phase: 'anfragen', dryRun: false, report: { processed: 9 } })],
    [job({ state: 'review', phase: 'verification', dryRun: false, report: reportFor(false) })],
  ];
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect.poll(() => state.posted.some((p) => p.path.endsWith('/import'))).toBe(true);
  await expect(page.getByRole('heading', { name: 'Prüfbericht', exact: true })).toBeVisible({
    timeout: 20_000,
  });
  await expect(page.getByTestId('migration-report')).toContainText('Einsendungen');
  await expect(page.getByTestId('migration-report')).toContainText('nicht übernehmbarem Inhalt');
  await shot(page, '05-ergebnis');
});

const failures: Array<[string, number, { code: string; message: string }, string]> = [
  [
    'falsche Zugangsdaten',
    422,
    {
      code: 'source_failure',
      message: 'Anmeldung an der Quelle abgelehnt: Benutzer oder Passwort prüfen.',
    },
    'Anmeldung an der Quelle abgelehnt',
  ],
  [
    'Quelle nicht erreichbar',
    422,
    {
      code: 'source_failure',
      message: 'Die Quelle ist nicht erreichbar: Adresse, Port und Netzwerkfreigabe prüfen.',
    },
    'nicht erreichbar',
  ],
  [
    'ohne TLS',
    422,
    {
      code: 'source_failure',
      message:
        'Die Quelle bietet kein TLS an. Die Verbindung wurde abgebrochen, bevor Zugangsdaten gesendet wurden. TLS an der Quelle aktivieren.',
    },
    'bevor Zugangsdaten gesendet wurden',
  ],
  [
    'Netz nicht freigegeben',
    422,
    {
      code: 'source_failure',
      message:
        'Quelladresse nicht freigegeben oder nicht auflösbar: migration.allowedNets (FORM_MIGRATION_ALLOWED_NETS) muss das Netz der Quelle enthalten.',
    },
    'migration.allowedNets',
  ],
  [
    'zu viele gleichzeitige Prüfungen',
    429,
    { code: 'source_check_busy', message: 'Es läuft bereits eine Quellprüfung.' },
    'Es läuft bereits eine Quellprüfung',
  ],
];

for (const [label, status, body, text] of failures) {
  test(`Quellprüfung fehlgeschlagen (${label}) nennt die Ursache`, async ({ page }) => {
    await mock(page, { testReply: { status, body }, frames: [[]] });
    await check(page);
    await expect(page.getByRole('alert').first()).toContainText(text);
    await expect(page.getByText('Prüfbericht der Quelle')).toHaveCount(0);
    if (label === 'ohne TLS') await shot(page, '06-fehler-tls');
  });
}

for (const [code, text] of [
  ['unknownKeyGeneration@kid', 'Der Schlüssel (kid) ist im Ziel nicht vorhanden'],
  ['source_no_tls', 'Die Quelle bietet kein TLS an'],
  ['source_cert_hostname', 'passt nicht zum Hostnamen'],
  ['source_cert_untrusted', 'unbekannten Stelle'],
  ['source_cert_expired', 'ist abgelaufen'],
  ['database', 'Datenbankfehler beim Schreiben ins Ziel'],
  ['database@1062:uq_customer_active_key', 'Fehlernummer 1062, Name uq_customer_active_key'],
  ['key_conflict_active', 'schon einen aktiven Schlüssel'],
  ['key_conflict_number', 'derselben Nummer'],
] as const) {
  test(`Fehlgeschlagener Lauf (${code}) erklärt sich und lässt sich fortsetzen`, async ({
    page,
  }) => {
    const state = await mock(page, {
      frames: [
        [job({ state: 'failed', phase: 'anfragen', dryRun: true, error: code, report: {} })],
      ],
    });
    await page.goto('/migration');
    await expect(page.getByRole('alert').first()).toContainText(text);
    await shot(page, `07-fehlerlauf-${code.replace(/\W/g, '-')}`);
    await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
    await expect.poll(() => state.posted.some((p) => p.path.endsWith('/resume'))).toBe(true);
  });
}

test('320 px: Zuordnung und Ergebnis ohne horizontales Scrollen und ohne axe-Verstöße', async ({
  page,
}) => {
  await page.setViewportSize({ width: 320, height: 900 });
  await mock(page, {
    frames: [[]],
  });
  await check(page);
  await page.getByRole('button', { name: 'Weiter' }).click();
  await page.getByLabel('Kundenname', { exact: false }).fill('Müller & Söhne GmbH');
  await expect(page.getByTestId('migration-summary')).toContainText('Der Plan ist vollständig.');
  for (const name of ['320-zuordnung']) await shot(page, name);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(320);
  // Buttons fade from the disabled to the enabled colours; axe must not sample in the middle of that transition.
  await page.waitForFunction(() =>
    document.getAnimations().every((a) => !a.pending && a.playState !== 'running'),
  );
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
});

test('320 px: Fortschritt, Fehler und Prüfbericht ohne Überlauf und axe-Verstöße', async ({
  page,
}) => {
  await page.setViewportSize({ width: 320, height: 900 });
  const state = await mock(page, {
    frames: [
      [job({ state: 'failed', phase: 'anfragen', dryRun: true, error: 'source_unreachable' })],
    ],
  });
  await page.goto('/migration');
  await expect(page.getByRole('alert').first()).toContainText('nicht erreichbar');
  await shot(page, '320-fehlerlauf');
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(320);
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  state.frames = [
    [job({ state: 'review', phase: 'verification', dryRun: true, report: reportFor(true) })],
  ];
  await page.reload();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible();
  await shot(page, '320-pruefbericht');
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(320);
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
});
