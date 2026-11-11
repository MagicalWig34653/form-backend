import AxeBuilder from '@axe-core/playwright';
import { test, expect, type Page } from '@playwright/test';

// HTML mail builder in the form's mail tab (Design / Einfach / Quelltext). Mocks follow the real API shapes:
// GET/PATCH draft with If-Match revision, form detail, connections and deliveries.
const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
const F = '22222222-2222-4222-8222-222222222222';
const D = '33333333-3333-4333-8333-333333333333';
const MARKER = '<!--kubus-mail-quelle:';

// The app shell policy from backend/Sources/FormHTTP/StaticSite.swift (kept in sync by hand).
const CSP =
  "default-src 'self'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; img-src 'self' data:; " +
  "connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";

const marker = (json: object): string =>
  MARKER + Buffer.from(JSON.stringify(json), 'utf8').toString('base64') + '-->';
function readMarker(body: string): { m: string; s: string; q: boolean } | null {
  const hit = /<!--\s*kubus-mail-quelle:([A-Za-z0-9+/=]+)\s*-->/.exec(body);
  return hit ? JSON.parse(Buffer.from(hit[1]!, 'base64').toString('utf8')) : null;
}

function documentWith(body: string, format: 'html' | 'text' = 'html') {
  return {
    form: {
      id: F,
      version: '1.0.0',
      title: { de: 'Kontakt' },
      fields: {
        message: {
          name: 'nachricht',
          kind: 'text',
          label: { de: 'Nachricht' },
          required: true,
          validation: { type: 'string' },
        },
        mail: {
          name: 'email',
          kind: 'email',
          label: { de: 'E-Mail' },
          required: true,
          validation: { type: 'string' },
        },
      },
      mail: {
        from: { address: 'formular@example.org' },
        organisation: { to: ['team@example.org'], subject: 'Neue Anfrage', body, format },
      },
    },
    views: [
      {
        id: 'v',
        version: '1.0.0',
        form: { id: F, version: '1.0.0', sha256: 'x' },
        steps: [
          {
            id: 'm',
            sections: [{ id: 's', fields: [{ fieldId: 'message' }, { fieldId: 'mail' }] }],
          },
        ],
      },
    ],
  };
}

interface World {
  revision: number;
  document: ReturnType<typeof documentWith>;
  patches: { ifMatch: string | undefined; document: ReturnType<typeof documentWith> }[];
}

async function mock(page: Page, body: string, format: 'html' | 'text' = 'html'): Promise<World> {
  const w: World = { revision: 1, document: documentWith(body, format), patches: [] };
  const j = (b: unknown, status = 200) => ({
    status,
    contentType: 'application/json',
    body: JSON.stringify(b),
  });
  await page.route('**/admin/api/v1/**', async (r) => {
    const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
    const f = `/tenants/${T}/forms/${F}`;
    if (p === '/auth/session')
      return r.fulfill(
        j({ state: 'authenticated', csrfToken: 'c', subjectId: 'a', expiresAt: 'x' }),
      );
    if (p === '/me') return r.fulfill(j({ id: 'a', username: 'u', systemAdministrator: true }));
    if (p === '/tenants')
      return r.fulfill(
        j({
          items: [
            {
              id: T,
              name: 'Kunde A',
              permissions: ['form.read', 'draft.write', 'release.publish'],
            },
          ],
        }),
      );
    if (p === `/tenants/${T}/forms`)
      return r.fulfill(
        j({
          items: [{ id: F, name: 'Kontakt', active: true, currentReleaseId: D }],
          nextCursor: null,
        }),
      );
    if (p === f)
      return r.fulfill(
        j({
          id: F,
          name: 'Kontakt',
          active: true,
          currentReleaseId: D,
          currentReleaseVersion: 1,
          draftIds: [D],
          mailConnectionId: 'c1',
        }),
      );
    if (p === `${f}/drafts/${D}`) {
      if (r.request().method() === 'PATCH') {
        const ifMatch = r.request().headers()['if-match'];
        if (ifMatch !== `"${w.revision}"`) return r.fulfill(j({ error: 'conflict' }, 409));
        w.document = JSON.parse(r.request().postData() ?? '{}');
        w.patches.push({ ifMatch, document: w.document });
        w.revision += 1;
      }
      return r.fulfill(
        j({ id: D, revision: w.revision, hash: `h${w.revision}`, document: w.document }),
      );
    }
    if (p === `/tenants/${T}/connections`)
      return r.fulfill(j({ items: [{ id: 'c1', kind: 'smtp', name: 'Mailserver' }] }));
    if (p === `${f}/mail-deliveries`) return r.fulfill(j({ items: [] }));
    return r.fulfill(j({ error: 'not_found' }, 404));
  });
  return w;
}

function watchErrors(page: Page): string[] {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(e.message));
  return errors;
}

// The preview frame shows the mail itself (sandboxed, no scripts, so axe cannot run inside it); the app is checked.
const axe = (page: Page) => new AxeBuilder({ page }).exclude('iframe[sandbox]');
const tab = (page: Page, name: string) => page.getByRole('tab', { name });
const orgBody = (w: World) => w.document.form.mail.organisation.body;

test('Design: Vorlage, Platzhalter, Schaltfläche, Speichern mit Marker, erneutes Laden im Design', async ({
  page,
}) => {
  const errors = watchErrors(page);
  const w = await mock(page, '<p>Altes HTML #=[nachricht]=#</p>');
  await page.goto(`/t/${T}/f/${F}/mail`);

  // Foreign HTML without marker opens in the source view, preview is a sandboxed frame without scripts.
  await expect(tab(page, 'Quelltext')).toHaveAttribute('aria-selected', 'true');
  const frame = page.getByTestId('org-body-preview');
  await expect(frame).toHaveAttribute('sandbox', '');
  await expect(frame).toHaveAttribute('srcdoc', /Beispiel nachricht/);
  await expect(frame).not.toHaveAttribute('srcdoc', /#=\[nachricht\]=#/);

  // Switching to design asks first (foreign HTML cannot become MJML) – cancelling keeps everything.
  await tab(page, 'Design').click();
  await expect(page.getByRole('alertdialog')).toContainText('Mit Design-Vorlage beginnen?');
  await page.getByRole('button', { name: 'Abbrechen' }).click();
  await expect(tab(page, 'Quelltext')).toHaveAttribute('aria-selected', 'true');
  await tab(page, 'Design').click();
  await page.getByRole('button', { name: 'Mit Vorlage beginnen' }).click();
  await expect(tab(page, 'Design')).toHaveAttribute('aria-selected', 'true');
  const list = page.getByRole('region', { name: 'Design' });
  const items = list.locator('[data-select]');
  await expect(items).toHaveCount(1);
  await expect(items.first()).toContainText('Text');

  // Placeholder chip inserts at the caret of the text block.
  const text = page.getByRole('textbox', { name: 'Text', exact: true });
  await text.click();
  await page.keyboard.press('ControlOrMeta+a');
  await page.keyboard.type('Hallo ');
  await page.getByRole('button', { name: 'nachricht', exact: true }).click();
  await expect(text).toContainText('Hallo #=[nachricht]=#');

  // Add a button block, set label and link.
  await list.getByRole('button', { name: 'Schaltfläche', exact: true }).click();
  await page.getByLabel('Beschriftung').fill('Antwort ansehen');
  await page.getByLabel('Linkadresse (https:// oder mailto:)').fill('javascript:alert(1)');
  await expect(page.getByText('Nur Adressen mit https://')).toBeVisible();
  await page.getByLabel('Linkadresse (https:// oder mailto:)').fill('https://example.org/a');
  await expect(page.getByText('Nur Adressen mit https://')).toHaveCount(0);
  await expect(page.getByLabel('Linkadresse (https:// oder mailto:)')).not.toHaveAttribute(
    'aria-invalid',
    'true',
  );
  // The canvas is the compiled mail in the sandboxed frame, with example values.
  await expect(page.getByTestId('org-body-preview')).toHaveAttribute('srcdoc', /Antwort ansehen/);
  await expect(page.getByTestId('org-body-preview')).toHaveAttribute(
    'srcdoc',
    /Hallo Beispiel nachricht/,
  );

  // Reorder with Alt+Arrow and move it back.
  await items.filter({ hasText: 'Schaltfläche' }).focus();
  await page.keyboard.press('Alt+ArrowUp');
  await expect(list.locator('ol > li').first()).toContainText('Schaltfläche');
  await page.keyboard.press('Alt+ArrowDown');
  await expect(list.locator('ol > li').first()).toContainText('Text');

  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect.poll(() => w.patches.length).toBe(1);
  const saved = orgBody(w);
  expect(saved.startsWith(MARKER)).toBe(true);
  expect(saved).toContain('#=[nachricht]=#');
  expect(saved).toContain('<table');
  expect(saved).toContain('https://example.org/a');
  expect(saved).not.toContain('javascript:');
  const m = readMarker(saved)!;
  expect(m.m).toBe('design');
  expect(m.q).toBe(false);
  expect(m.s).toContain('<mj-button');
  expect(m.s).toContain('#=[nachricht]=#');
  expect(w.document.form.mail.organisation.format).toBe('html');

  await page.reload();
  await expect(tab(page, 'Design')).toHaveAttribute('aria-selected', 'true');
  await expect(items.filter({ hasText: 'Schaltfläche' })).toBeVisible();
  expect(errors).toEqual([]);
});

test('Einfach und Quelltext: Platzhalter an der Cursorposition, Warnung vor Verlust der Design-Quelle', async ({
  page,
}) => {
  const errors = watchErrors(page);
  const mjml =
    '<mjml><mj-body background-color="#f4f4f4"><mj-section background-color="#ffffff" padding="24px"><mj-column>' +
    '<mj-text>Guten Tag,<br /><br />Ihr Text.</mj-text></mj-column></mj-section></mj-body></mjml>';
  // A design mail written by the legacy editor (GrapesJS) stays editable.
  const w = await mock(
    page,
    marker({ m: 'design', s: mjml, q: false }) + '\n<table><tr><td>Alt</td></tr></table>',
  );
  await page.goto(`/t/${T}/f/${F}/mail`);
  await expect(tab(page, 'Design')).toHaveAttribute('aria-selected', 'true');

  // Source view: placeholder lands at the caret, the source stays in the marker (flagged as hand-edited).
  await tab(page, 'Quelltext').click();
  await expect(tab(page, 'Quelltext')).toHaveAttribute('aria-selected', 'true');
  const source = page.locator('#org-body');
  await expect(source).toHaveValue('<table><tr><td>Alt</td></tr></table>');
  await source.click();
  await source.evaluate((el: HTMLTextAreaElement) => el.setSelectionRange(15, 15));
  await page.getByRole('button', { name: 'email', exact: true }).click();
  await expect(source).toHaveValue('<table><tr><td>#=[email]=#Alt</td></tr></table>');

  // Back to design asks before the hand edit is replaced.
  await tab(page, 'Design').click();
  await expect(page.getByRole('alertdialog')).toContainText('Handänderungen ersetzen?');
  await page.getByRole('button', { name: 'Abbrechen' }).click();

  // To "Einfach": warning about losing the design source.
  await tab(page, 'Einfach').click();
  await expect(page.getByRole('alertdialog')).toContainText('Design-Quelle verwerfen?');
  await page.getByRole('button', { name: 'Design verwerfen' }).click();
  await expect(tab(page, 'Einfach')).toHaveAttribute('aria-selected', 'true');
  const rich = page.getByRole('textbox', { name: 'Inhalt (Einfach)' });
  await expect(rich).toContainText('Ihr Text.');
  await rich.click();
  await page.keyboard.press('End');
  await page.getByRole('button', { name: 'nachricht', exact: true }).click();
  await expect(rich).toContainText('#=[nachricht]=#');
  await page.getByRole('button', { name: 'Fett' }).click();
  await page.keyboard.type('fett');

  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect.poll(() => w.patches.length).toBe(1);
  const m = readMarker(orgBody(w))!;
  expect(m.m).toBe('einfach');
  expect(m.s).toContain('#=[nachricht]=#');
  expect(m.s).toContain('<strong>fett</strong>');
  expect(orgBody(w)).toContain('role="presentation"');
  await page.reload();
  await expect(tab(page, 'Einfach')).toHaveAttribute('aria-selected', 'true');
  expect(errors).toEqual([]);
});

test('Text-Mails bleiben ein einfaches Feld; Platzhalter an der Cursorposition', async ({
  page,
}) => {
  const w = await mock(page, 'Hallo , danke.', 'text');
  await page.goto(`/t/${T}/f/${F}/mail`);
  await expect(page.getByRole('tab', { name: 'Design' })).toHaveCount(0);
  const body = page.locator('#org-body');
  await body.click();
  await body.evaluate((el: HTMLTextAreaElement) => el.setSelectionRange(6, 6));
  await page.getByRole('button', { name: 'nachricht', exact: true }).click();
  await expect(body).toHaveValue('Hallo #=[nachricht]=#, danke.');
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect.poll(() => w.patches.length).toBe(1);
  expect(orgBody(w)).toBe('Hallo #=[nachricht]=#, danke.');
});

test('Builder funktioniert unter der echten Content-Security-Policy (kein eval, keine Inline-Skripte)', async ({
  page,
}) => {
  const errors = watchErrors(page);
  const refused: string[] = [];
  page.on('console', (msg) => {
    if (msg.type() === 'error' && /Content Security Policy|unsafe-eval/i.test(msg.text()))
      refused.push(`${msg.location().url} ${msg.text()}`);
  });
  await page.route(
    (url) => url.origin === 'http://localhost:4173' && !url.pathname.startsWith('/admin/api/'),
    async (route) => {
      if (route.request().resourceType() !== 'document') return route.fallback();
      const response = await route.fetch();
      return route.fulfill({
        response,
        headers: { ...response.headers(), 'content-security-policy': CSP },
      });
    },
  );
  const w = await mock(page, '');
  await page.goto(`/t/${T}/f/${F}/mail`);
  await tab(page, 'Design').click();
  await expect(tab(page, 'Design')).toHaveAttribute('aria-selected', 'true');
  const list = page.getByRole('region', { name: 'Design' });
  await list.getByRole('button', { name: 'Trennlinie', exact: true }).click();
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect.poll(() => w.patches.length).toBe(1);
  expect(orgBody(w)).toContain('<table');
  expect(readMarker(orgBody(w))!.s).toContain('<mj-divider');
  expect(errors).toEqual([]);
  // The app itself needs no exception and nothing needs eval. The only refusals come from the preview frame
  // (about:srcdoc inherits the app policy, so the mail's own <style> blocks are not applied there; inline style
  // attributes, which MJML uses for the layout, are).
  expect(refused.filter((t) => /eval|script-src/i.test(t))).toEqual([]);
  expect(refused.filter((t) => !t.startsWith('about:srcdoc '))).toEqual([]);
});

for (const scheme of ['light', 'dark'] as const) {
  test(`Design-Modus bei 320 px (${scheme}): keine Querverschiebung, axe ohne Befund`, async ({
    page,
  }) => {
    const errors = watchErrors(page);
    await page.setViewportSize({ width: 320, height: 800 });
    await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
    await mock(
      page,
      marker({
        m: 'design',
        s: '<mjml><mj-body><mj-section><mj-column><mj-text>Hallo</mj-text><mj-button href="https://example.org">Los</mj-button></mj-column></mj-section></mj-body></mjml>',
        q: false,
      }) + '\n<p>Hallo</p>',
    );
    await page.goto(`/t/${T}/f/${F}/mail`);
    await expect(tab(page, 'Design')).toHaveAttribute('aria-selected', 'true');
    await expect(page.getByTestId('org-body-mobile-hint')).toBeVisible();
    await expect(page.getByRole('textbox', { name: 'Text', exact: true })).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
    expect((await axe(page).analyze()).violations).toEqual([]);
    await tab(page, 'Quelltext').click();
    await expect(page.locator('#org-body')).toBeVisible();
    expect((await axe(page).analyze()).violations).toEqual([]);
    expect(errors).toEqual([]);
  });
}

test('Vollbild für den Design-Modus und zurück', async ({ page }) => {
  await mock(page, '');
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto(`/t/${T}/f/${F}/mail`);
  await tab(page, 'Design').click();
  await page.getByRole('button', { name: 'Vollbild', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Vollbild beenden' })).toBeVisible();
  const box = await page.getByRole('region', { name: 'Design' }).boundingBox();
  expect(box!.width).toBeGreaterThan(1200);
  expect((await axe(page).analyze()).violations).toEqual([]);
  await page.getByRole('button', { name: 'Vollbild beenden' }).click();
  await expect(page.getByRole('button', { name: 'Vollbild', exact: true })).toBeVisible();
});
