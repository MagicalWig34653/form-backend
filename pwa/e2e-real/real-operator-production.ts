import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { expect, type Locator, type Page } from '@playwright/test';
import { env } from './helpers';
import { openAdvanced, unlockWithRecoveryCode } from './unlock-helpers';
import {
  ctl,
  finding,
  note,
  resetBudget,
  stepDone,
  target,
  uuidBin,
} from './real-operator-helpers';

// The part of the operator path after the import (backend/e2e-operator.sh, real-operator.spec.ts): review, key, publishing, cutover and
// then PRODUCTION use: SDK submission -> encrypted at rest -> team mail with the full content -> readable in the backend, reload/unlock,
// container restart/kill, image update, rotation state. Synthetic dump: full chain incl. old keys; real dump: everything that does not
// need the old private key (it is not in the dump).

export const CUSTOMER = 'Kubus Altkunde GmbH';
const REAL = process.env.E2E_DUMP === 'real';
const SYNTHETIC_KEYS: Record<string, number> = { a6077815bba8b14c: 0x10, d19bf3f082782c87: 0x11 }; // RehearsalSource seeds
const seedKey = (seed: number) => Buffer.alloc(32, seed).toString('base64url');
const mailpit = (path: string) => `http://127.0.0.1:${env('E2E_MAILPIT_API')}${path}`;
const uuidOf = (hex: string) =>
  hex.toLowerCase().replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5');

async function waitFor(check: () => boolean | Promise<boolean>, what: string, ms = 60_000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await check()) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`timeout: ${what}`);
}

async function toUmstieg(page: Page) {
  resetBudget();
  await page.getByRole('link', { name: 'Umstieg', exact: true }).first().click();
  await expect(page.getByRole('heading', { name: 'Umstieg', exact: true })).toBeVisible();
}

async function openCustomer(page: Page) {
  resetBudget();
  await expect(async () => {
    await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
    await page.getByRole('link', { name: `Öffnen: ${CUSTOMER}` }).click({ timeout: 10_000 });
  }).toPass({ timeout: 90_000 });
  await expect(page).toHaveURL(/\/t\/[0-9a-f-]{36}/);
}

async function openForm(page: Page, name: string) {
  await openCustomer(page);
  await page
    .getByRole('link', { name: new RegExp(name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')) })
    .first()
    .click();
  await expect(page).toHaveURL(/\/f\/[0-9a-f-]{36}/);
}

/** Opens the newest entry of the form and returns the detail dialog. */
async function openNewestEntry(page: Page, formName: string, retry = true): Promise<Locator> {
  await openForm(page, formName);
  await page.getByRole('link', { name: 'Einsendungen', exact: true }).last().click();
  await expect(page.getByText('Noch keine Einsendungen')).toHaveCount(0);
  await page
    .getByRole('button', { name: /^Aktionen für Einsendung/ })
    .first()
    .click();
  const open = page.getByRole('menuitem', { name: 'Öffnen' });
  // after an unlock the keyring loads the accesses in the background: give it a moment before calling the entry unopenable
  await expect(open)
    .toBeEnabled({ timeout: 10_000 })
    .catch(() => {});
  if (retry && (await open.isDisabled())) {
    // the browser holds no data key for this entry: reload + passkey unlock loads every access of the account again
    finding(
      `entry not openable in the running session (no data key in the keyring); retried after reload + unlock`,
    );
    resetBudget();
    await page.keyboard.press('Escape');
    await page.goto('/account');
    await expect(page.getByText('Schlüssel gesperrt').first()).toBeVisible();
    await unlockIfLocked(page);
    note(
      `keyring after unlock: ${(
        await page
          .getByTestId('access-status')
          .innerText()
          .catch(() => '?')
      )
        .replace(/\s+/g, ' ')
        .slice(0, 200)}`,
    );
    return openNewestEntry(page, formName, false);
  }
  await open.click();
  return page.getByRole('dialog', { name: 'Einsendungsdetail' });
}

/** Opens the entries of the form one by one until a detail dialog shows text matching `re` (the imported entries are older than production ones). */
async function openEntryContaining(page: Page, formName: string, re: RegExp): Promise<Locator> {
  await openForm(page, formName);
  await page.getByRole('link', { name: 'Einsendungen', exact: true }).last().click();
  const rows = page.getByRole('button', { name: /^Aktionen für Einsendung/ });
  await expect(rows.first()).toBeVisible();
  const n = await rows.count();
  let locked = 0;
  for (let i = 0; i < n; i++) {
    await rows.nth(i).click();
    const open = page.getByRole('menuitem', { name: 'Öffnen' });
    await expect(open)
      .toBeEnabled({ timeout: 5_000 })
      .catch(() => {});
    if (await open.isDisabled()) {
      locked++;
      await page.keyboard.press('Escape');
      continue;
    }
    await open.click();
    const dialog = page.getByRole('dialog', { name: 'Einsendungsdetail' });
    await expect(dialog).toBeVisible();
    await dialog
      .getByRole('heading', { name: 'Felder' })
      .waitFor({ timeout: 5_000 })
      .catch(() => {});
    if (await dialog.getByText(re).count()) return dialog;
    note(`entry ${i}: ${(await dialog.innerText()).replace(/\s+/g, ' ').slice(0, 120)}`);
    await dialog.getByRole('button', { name: 'Schließen' }).click();
  }
  throw new Error(`no readable entry matches ${re} among ${n} (${locked} without data key)`);
}

async function unlockIfLocked(page: Page) {
  // the lock state is shown once the session has loaded: do not judge before
  await page
    .getByText(/Schlüssel (gesperrt|entsperrt)/)
    .first()
    .waitFor({ timeout: 15_000 })
    .catch(() => {});
  if (await page.getByText('Schlüssel gesperrt').first().isVisible()) {
    // the account page re-renders while it loads and may fold the section again: open it again until the button is there
    await expect(async () => {
      const primary = page.getByRole('button', { name: 'Zugriff freigeben', exact: true }).first();
      if (await primary.isVisible()) await primary.click({ timeout: 4_000 }); // opens the advanced section
      await openAdvanced(page);
      await page
        .getByRole('button', { name: 'Mit Passkey entsperren' })
        .first()
        .click({ timeout: 4_000 });
    })
      .toPass({ timeout: 25_000 })
      .catch(async (e) => {
        note(
          `advanced: ${(await page.locator('details').filter({ hasText: 'Erweitert: Zugriff auf Einsendungen' }).innerText()).replace(/\s+/g, ' ').slice(0, 600)}; url ${page.url()}`,
        );
        note(
          `tenants api: ${await page
            .evaluate(async () => {
              const r = await fetch('/admin/api/v1/tenants', { credentials: 'include' }).catch(
                (x) => x,
              );
              return r.status + ' ' + (await r.text()).slice(0, 200);
            })
            .catch((x) =>
              String(x),
            )}; customers=${target('SELECT COUNT(*) FROM customers')}; members=${target('SELECT COUNT(*) FROM customer_memberships')}`,
        );
        throw e;
      });
    await page
      .getByText('Schlüssel entsperrt')
      .waitFor({ timeout: 30_000 })
      .catch(async () => {
        await openAdvanced(page);
        note(
          `advanced: ${(await page.locator('details').filter({ hasText: 'Erweitert: Zugriff auf Einsendungen' }).innerText()).replace(/\s+/g, ' ').slice(0, 500)}`,
        );
        note(
          `unlock failed; alerts: ${(await page.getByRole('alert').allInnerTexts()).join(' | ').slice(0, 300)}; status: ${(await page.getByRole('status').allInnerTexts()).join(' | ').slice(0, 300)}`,
        );
        throw new Error('unlock failed');
      });
  }
}

/** One signed submission through the PHP SDK (sdk/php/bin/submit.php) against the public listener behind the TLS proxy. */
function sdkSubmit(
  credentials: string,
  fields: Record<string, string>,
  key: string,
  file?: string,
): string {
  const args = [
    '-d',
    // the website trusts the proxy's throw-away CA (Homebrew PHP's cURL ignores curl.cainfo, openssl.cafile works on macOS and Linux)
    `openssl.cafile=${env('E2E_CA')}`,
    '-d',
    `curl.cainfo=${env('E2E_CA')}`,
    resolve(process.cwd(), '..', 'sdk', 'php', 'bin', 'submit.php'),
    '--credentials',
    credentials,
    '--url',
    env('E2E_PUBLIC_URL'),
    '--key',
    key,
  ];
  if (file) args.push('--file', file);
  for (const [k, v] of Object.entries(fields)) args.push(`${k}=${v}`);
  return execFileSync('php', args, { encoding: 'utf8', timeout: 60_000 }).trim();
}

async function mailWith(marker: string): Promise<string> {
  let text = '';
  await waitFor(
    async () => {
      const list = (await (
        await fetch(mailpit('/api/v1/search?query=' + encodeURIComponent(marker)))
      ).json()) as {
        messages: { ID: string }[];
      };
      if (!list.messages?.length) return false;
      const m = (await (
        await fetch(mailpit(`/api/v1/message/${list.messages[0]!.ID}`))
      ).json()) as { Text: string };
      text = m.Text;
      return true;
    },
    `team mail with ${marker}`,
    90_000,
  );
  return text;
}

/** Nothing of the clear text in the database: a full dump of the target must not contain the marker. */
function plaintextHits(marker: string): number {
  const dump = execFileSync(
    'docker',
    [
      'exec',
      '-e',
      `MYSQL_PWD=${env('E2E_DB_PASSWORD')}`,
      env('E2E_DB_CONTAINER'),
      'mariadb-dump',
      '-uroot',
      '--skip-extended-insert',
      '--hex-blob',
      env('E2E_DB_NAME'),
    ],
    { encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 },
  );
  return dump.split('\n').filter((l) => l.includes(marker)).length;
}

export async function postImport(page: Page, recovery: string) {
  const tenant = uuidOf(target(`SELECT HEX(id) FROM customers WHERE name='${CUSTOMER}'`));
  expect(tenant).toMatch(/^[0-9a-f-]{36}$/);

  // R1. review: synthetic = decryption probe + test message, release; real = no :2 package, the probe is not required (finding B)
  await toUmstieg(page);
  await expect(page.getByRole('heading', { name: 'Prüfung', exact: true }).first()).toBeVisible();
  if (REAL) {
    await expect(page.getByTestId('migration-probe-none')).toContainText(
      'Keine :2-Einsendungen importiert',
    );
    note(
      `review: ${(await page.getByTestId('migration-probe-none').innerText()).replace(/\s+/g, ' ')}`,
    );
  } else {
    const probeResponse = page.waitForResponse((r) =>
      /\/migration\/jobs\/[^/]+\/probe$/.test(r.url()),
    );
    await page.getByRole('button', { name: 'Entschlüsselungsprobe laden' }).click();
    const kid = ((await (await probeResponse).json()) as { wire: string }).wire.split('|')[1]!;
    expect(SYNTHETIC_KEYS[kid], `probe kid ${kid}`).toBeTruthy();
    await page.getByLabel('Privater Altschlüssel').fill(seedKey(SYNTHETIC_KEYS[kid]!));
    await page.getByRole('button', { name: 'Probe lokal entschlüsseln' }).click();
    await page.getByRole('alertdialog').getByRole('button', { name: 'Bestätigen' }).click();
    await expect(page.getByText(/Lokale Entschlüsselung bestätigt/)).toBeVisible();
    expect(
      target(
        'SELECT probe_hash IS NOT NULL AND test_hash IS NOT NULL FROM migration_jobs WHERE dry_run=0',
      ),
    ).toBe('1');
    await page.getByRole('button', { name: 'Importierte Einsendungen freigeben' }).click();
    await expect(page.getByTestId('migration-released')).toBeVisible();
    note(`release: ${await page.getByTestId('migration-released').innerText()}`);
  }
  stepDone('review');

  // R2. optional image update with the import in review (OLD_IMAGE -> IMAGE): migrate + new app, nothing lost
  if (process.env.E2E_UPDATE === '1') {
    const before = target(
      'SELECT (SELECT COUNT(*) FROM submissions),(SELECT COUNT(*) FROM forms),(SELECT state FROM migration_jobs WHERE dry_run=0)',
    );
    note(ctl('update'));
    expect(
      target(
        'SELECT (SELECT COUNT(*) FROM submissions),(SELECT COUNT(*) FROM forms),(SELECT state FROM migration_jobs WHERE dry_run=0)',
      ),
    ).toBe(before);
    await page.reload();
    stepDone('image-update', ctl('image'));
  }

  // R3. key: synthetic = adopt the old keys in the account; real = the old key is not in the dump, the customer gets its own key
  if (!REAL) {
    resetBudget();
    // the way the review step offers (SPA navigation keeps the unlocked keyring; a reload would lock it)
    if (process.env.E2E_UPDATE === '1') {
      await page.goto('/account'); // the reload after the update locked the keyring
      await unlockIfLocked(page);
    }
    await toUmstieg(page);
    await page.getByRole('button', { name: 'Zur Übernahme im Konto' }).first().click();
    await expect(page).toHaveURL(/\/account\?legacy=1/);
    const field = page.locator(`#legacy-key-${tenant}`);
    if (!(await field.isVisible({ timeout: 15_000 }).catch(() => false))) {
      // the session's customer list is loaded at login: a customer the import just created appears after a reload (keyring locked again)
      finding(
        'adoption: the imported customer appears in Konto/Erweitert only after a reload (session customer list from the login)',
      );
      resetBudget();
      await page.goto('/account?legacy=1');
      await expect(page.getByText('Schlüssel gesperrt').first()).toBeVisible();
      await unlockIfLocked(page);
      await expect(field).toBeVisible({ timeout: 30_000 });
    }
    for (const seed of [0x11, 0x10]) {
      if (!(await field.isVisible())) {
        note(`adoption field gone after the first key (seed ${seed} not entered)`);
        break;
      }
      await field.fill(seedKey(seed));
      await page
        .getByRole('button', { name: 'Schlüssel prüfen und Zugang anlegen' })
        .first()
        .click();
      await expect(
        page.getByText(/Zugang für die importierte Generation .* angelegt|bereits/).first(),
      ).toBeVisible();
    }
    note(
      `key generations: ${target(`SELECT GROUP_CONCAT(CONCAT(generation_no,state) ORDER BY generation_no) FROM customer_key_generations WHERE customer_id=${uuidBin(tenant)}`)}`,
    );
    stepDone('legacy-key-adopted');
    // imported submissions are listed and readable (fields, umlauts, emoji)
    const detail = await openNewestEntry(page, 'Kontaktformular Müller');
    await expect(detail.getByRole('heading', { name: 'Felder' })).toBeVisible();
    await expect(detail.getByText(/KLARTEXT-MARKER-\d+/)).toBeVisible();
    await expect(detail.getByText(/Grüße 👋🏽/)).toBeVisible();
    await detail.getByRole('button', { name: 'Schließen' }).click();
    stepDone('imported-entry-readable');
  } else {
    // 0 old keys: the customer has no data key yet. The operator creates it in Konto > Erweitert (needs the reloaded session: the customer list
    // is loaded at login); an unlocked keyring is required
    finding(
      'real dump (0 old keys): the new data key is created by hand in Konto > Erweitert after a reload + unlock',
    );
    resetBudget();
    await page.goto('/account');
    await expect(page.getByText('Schlüssel gesperrt').first()).toBeVisible();
    await unlockIfLocked(page);
    await openAdvanced(page);
    await page.getByRole('button', { name: 'Datenschlüssel im Browser erzeugen' }).first().click();
    await expect(page.getByText(/Datenschlüssel erzeugt/)).toBeVisible();
    const keys = () =>
      target(
        `SELECT COUNT(*) FROM customer_key_generations WHERE customer_id=${uuidBin(tenant)} AND state='active'`,
      );
    await waitFor(() => keys() === '1', 'own key of the imported customer', 90_000);
    stepDone('customer-key');
  }

  // R4. publishing an imported form: activate the imported mail connection, mail settings, publish
  const formName = REAL
    ? target(`SELECT name FROM forms WHERE customer_id=${uuidBin(tenant)} ORDER BY name LIMIT 1`)
    : 'Kontaktformular Müller';
  // the imported legacy SMTP server (the harness pointed its host at Mailpit; STARTTLS, SMTPallowSelfSigned=1) is tested, activated and
  // used as it is (finding C): its password comes from the dump, nothing is entered again
  const mailHost = env('E2E_MAILPIT_HOST');
  const connName = target(
    `SELECT name FROM connections WHERE JSON_VALUE(safe_config_json,'$.host')='${mailHost}' LIMIT 1`,
  );
  expect(connName, 'imported connection in the native schema').not.toBe('');
  note(
    `imported connections (kind:enabled:native:verify): ${target("SELECT GROUP_CONCAT(CONCAT(kind,':',enabled,':',JSON_EXISTS(safe_config_json,'$.host') OR JSON_EXISTS(safe_config_json,'$.url'),':',COALESCE(JSON_VALUE(safe_config_json,'$.verifyCertificate'),'-')) ORDER BY name) FROM connections")}`,
  );
  resetBudget();
  await page.getByRole('link', { name: 'Verbindungen', exact: true }).first().click();
  const row = page.locator('li').filter({ has: page.getByText(connName, { exact: true }) });
  await row.getByRole('button', { name: /^(Testen|Erneut prüfen)/ }).click();
  await expect(row.getByText('Verbindung in Ordnung')).toBeVisible({ timeout: 90_000 });
  await page.getByRole('button', { name: `Aktionen für ${connName}` }).click();
  await page.getByRole('menuitem', { name: 'Verbindung aktivieren' }).click();
  await expect(page.getByText(/Die Verbindung ist aktiv/)).toBeVisible();
  expect(
    target(`SELECT enabled FROM connections WHERE name='${connName.replace(/'/g, "''")}'`),
  ).toBe('1');
  stepDone('mail-connection');

  await openForm(page, formName);
  const formId = /\/f\/([0-9a-f-]{36})/.exec(page.url())![1]!;
  // SPA navigation like an operator (a page.goto would reload the tab and lock the keyring)
  await page.getByRole('link', { name: 'Mail', exact: true }).first().click();
  await expect(page).toHaveURL(/\/mail$/);
  await page.getByLabel('Versandverbindung').selectOption({ label: `${connName} (SMTP-Server)` });
  await page.getByRole('button', { name: 'Versandweg zuweisen' }).click();
  await expect(page.getByText('Die Verbindung wurde gespeichert.')).toBeVisible();
  await page.getByLabel('Absenderadresse').fill('formular@example.org');
  await page.getByLabel('Empfänger (eine Adresse pro Zeile)').fill('team@example.org');
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect(page.getByRole('status').filter({ hasText: /Gespeichert/ })).toBeVisible();
  const fields = target(
    `SELECT GROUP_CONCAT(CONCAT(j.name,':',j.kind) SEPARATOR ',') FROM form_drafts d, JSON_TABLE(JSON_EXTRACT(d.document_json,'$.form.fields.*'),'$[*]' COLUMNS (name VARCHAR(64) PATH '$.name', kind VARCHAR(32) PATH '$.kind')) j WHERE d.form_id=${uuidBin(formId)}`,
  )
    .split(',')
    .filter(Boolean)
    .map((p) => p.split(':') as [string, string]);
  note(
    `draft fields of the imported form: ${fields.length} (${[...new Set(fields.map((f) => f[1]))].join('/')})`,
  );
  expect(fields.length).toBeGreaterThan(0);
  await page.getByRole('link', { name: 'Veröffentlichen', exact: true }).click();
  await page.getByLabel(/Ich habe (den Entwurf|die Änderungen) geprüft/).check();
  const published = page.waitForResponse(
    (r) => r.url().endsWith('/releases') && r.request().method() === 'POST',
  );
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  const pub = await published;
  expect(pub.status(), await pub.text()).toBe(201);
  await expect(page.getByText(/Veröffentlicht/).first()).toBeVisible();
  await page.getByRole('link', { name: 'Einbindung', exact: true }).first().click();
  await page.getByRole('button', { name: 'Zugangsdatei ausstellen' }).click();
  const credentials = `${env('E2E_TMP')}/credentials.json`;
  writeFileSync(credentials, await page.getByLabel('Zugangsdatei', { exact: true }).inputValue(), {
    mode: 0o600,
  });
  stepDone('form-published');

  // R5. cutover: "Altzugriff entfernen" (synthetic: probe + test confirmed; real: no :2 package, explicit confirmation)
  await toUmstieg(page);
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(
    page.getByRole('heading', { name: 'Umschaltung', exact: true }).first(),
  ).toBeVisible();
  if (REAL)
    await page.getByRole('checkbox', { name: /Ohne Probe wird der Altzugriff entfernt/ }).check();
  await page.getByRole('button', { name: 'Altzugriff entfernen' }).click();
  await expect(page.getByTestId('migration-closed')).toBeVisible();
  expect(
    target('SELECT state, CAST(source_json AS CHAR) FROM migration_jobs WHERE dry_run=0'),
  ).toBe('closed\t{}');
  stepDone('cutover-source-removed');

  // R6. PRODUCTION: a new submission through the PHP SDK, encrypted at rest, full team mail, readable in the backend
  const values = (marker: string): Record<string, string> => {
    const out: Record<string, string> = {};
    for (const [name, kind] of fields) {
      if (kind === 'email') out[name] = 'erika.muster@example.org';
      else if (kind === 'number') out[name] = '42';
      else if (kind === 'date') out[name] = '2026-11-13';
      else if (kind === 'boolean') out[name] = '1';
      else if (kind === 'text') out[name] = `${marker} Grüße 👋🏽 Ärger & "zitiert" <b>fett</b> ß`;
    }
    return out;
  };
  const submitAndCheck = async (marker: string, label: string) => {
    const id = sdkSubmit(credentials, values(marker), `${marker}-key`);
    expect(id).toMatch(/^[0-9a-f-]{36}$/);
    expect(plaintextHits(marker), 'clear text in the target database').toBe(0);
    const text = await mailWith(marker);
    expect(text).toContain(marker);
    expect(text).toContain('Grüße 👋🏽');
    note(
      `${label}: package kid=${target(`SELECT kid FROM stored_objects WHERE submission_id=${uuidBin(id)} AND object_role='data'`)} state=${target(`SELECT state FROM submissions WHERE id=${uuidBin(id)}`)}; generations=${target(`SELECT GROUP_CONCAT(CONCAT(generation_no,state,':',kid) ORDER BY generation_no) FROM customer_key_generations WHERE customer_id=${uuidBin(tenant)}`)}; access=${target(`SELECT GROUP_CONCAT(DISTINCT kid) FROM data_key_access WHERE customer_id=${uuidBin(tenant)}`)}`,
    );
    const detail = await openNewestEntry(page, formName);
    await expect(detail.getByText(new RegExp(marker)).first()).toBeVisible();
    await detail.getByRole('button', { name: 'Schließen' }).click();
    stepDone(label, `submission ${id.slice(0, 8)}`);
  };
  await submitAndCheck('BETRIEB-1', 'production-submission');

  // R7. reload: the keyring is locked (RAM only), unlock with the passkey, still readable
  resetBudget();
  await page.reload();
  await expect(page.getByText('Schlüssel gesperrt').first()).toBeVisible();
  await unlockIfLocked(page);
  const again = await openNewestEntry(page, formName);
  await expect(again.getByText(/BETRIEB-1/).first()).toBeVisible();
  await again.getByRole('button', { name: 'Schließen' }).click();
  stepDone('reload-unlock-passkey');
  // Card 7B5E1E8A: the operator reads IMPORTED submissions through the recovery-code way (shown once at setup): reload, no passkey unlock
  resetBudget();
  await page.goto('/account');
  await expect(page.getByText('Schlüssel gesperrt').first()).toBeVisible();
  await unlockWithRecoveryCode(page, recovery);
  if (!REAL) {
    const imported = await openEntryContaining(page, formName, /KLARTEXT-MARKER-\d+/);
    await expect(imported.getByText(/Grüße 👋🏽/)).toBeVisible();
    await imported.getByRole('button', { name: 'Schließen' }).click();
    stepDone('imported-entry-readable-by-recovery-code');
  } else {
    const entry = await openNewestEntry(page, formName);
    await expect(entry.getByText(/BETRIEB-1/).first()).toBeVisible();
    await entry.getByRole('button', { name: 'Schließen' }).click();
    stepDone('production-entry-readable-by-recovery-code');
  }

  // R8. container restart and kill -9: the session and all data survive, new submissions keep working
  note(ctl('restart'));
  resetBudget();
  await page.goto('/account'); // the reload locks the keyring; the lock hint and unlock are on the account page
  await unlockIfLocked(page);
  await submitAndCheck('BETRIEB-2', 'after-restart');
  note(ctl('kill'));
  resetBudget();
  await page.goto('/account'); // the reload locks the keyring; the lock hint and unlock are on the account page
  await unlockIfLocked(page);
  await submitAndCheck('BETRIEB-3', 'after-kill');

  // R8b. retention: the sweep (env knob FORM_RETENTION_INTERVAL_SECONDS=2 in the run's override) deletes a submission that is due and keeps the others
  const due = target(
    `SELECT HEX(id) FROM submissions WHERE received_at IS NOT NULL ORDER BY received_at DESC LIMIT 1`,
  );
  const before = Number(target('SELECT COUNT(*) FROM submissions'));
  target(
    `UPDATE submissions SET retention_due_at = NOW() - INTERVAL 1 HOUR WHERE id=UNHEX('${due}')`,
  );
  await waitFor(
    () => target(`SELECT COUNT(*) FROM submissions WHERE id=UNHEX('${due}')`) === '0',
    'retention sweep deletes the due submission',
    60_000,
  );
  expect(Number(target('SELECT COUNT(*) FROM submissions'))).toBe(before - 1);
  stepDone('retention-sweep', `${before} -> ${before - 1} submissions`);

  // R9. key rotation after the cutover (FF958178: "Umschaltung abschließen" is not built): document the actual state
  resetBudget();
  await openAdvanced(page);
  const begin = page.getByRole('button', { name: 'Rotation beginnen' });
  const n = await begin.count();
  if (n === 0)
    finding(
      `rotation after cutover: no "Rotation beginnen" button (generations ${target(`SELECT GROUP_CONCAT(CONCAT(generation_no,state)) FROM customer_key_generations WHERE customer_id=${uuidBin(tenant)}`)})`,
    );
  else {
    const response = page.waitForResponse(
      (r) => /\/key-rotation$/.test(r.url()) && r.request().method() === 'POST',
    );
    await begin.first().click();
    const r = await response;
    const body = await r.text();
    if (r.status() === 201) note('rotation after cutover: begin accepted (201)');
    else
      finding(
        `rotation after cutover refused: HTTP ${r.status()} ${body.slice(0, 120)}; runs=${target('SELECT GROUP_CONCAT(state) FROM migration_runs')} open issues=${target("SELECT COUNT(*) FROM migration_issues WHERE state='open'")}`,
      );
  }
  stepDone('rotation-state');
}
