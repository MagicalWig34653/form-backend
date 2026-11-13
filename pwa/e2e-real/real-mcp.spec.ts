import { createHash, randomBytes } from 'node:crypto';
import { test, expect, type Page } from '@playwright/test';
import {
  addAuthenticator,
  configureAndPublish,
  createCustomer,
  createForm,
  env,
  loginAndSecure,
  registerPasskey,
  toOverview,
} from './helpers';

// MCP against the real binary (orchestrated by backend/e2e-mcp.sh): personal API token created in the UI and OAuth
// (dynamic registration, PKCE S256, consent on the internal listener, refresh rotation), both used on the PUBLIC listener.
const PUBLIC = () => env('E2E_PUBLIC_URL');
const MCP_HEADERS = {
  'Content-Type': 'application/json',
  Accept: 'application/json, text/event-stream',
};

interface Rpc {
  jsonrpc: string;
  id?: number;
  result?: Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
  error?: { code: number };
}
let rpcId = 0;
async function rpc(token: string | null, method: string, params?: object) {
  const res = await fetch(`${PUBLIC()}/mcp/`, {
    method: 'POST',
    headers: { ...MCP_HEADERS, ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, ...(params ? { params } : {}) }),
  });
  const text = await res.text();
  return { status: res.status, body: (text ? JSON.parse(text) : null) as Rpc | null };
}
const toolNames = (r: { body: Rpc | null }) =>
  (r.body!.result.tools as { name: string }[]).map((t) => t.name);
const call = (token: string, name: string, args: object) =>
  rpc(token, 'tools/call', { name, arguments: args });

const b64url = (b: Buffer) => b.toString('base64url');

async function tokenRequest(params: Record<string, string>) {
  const res = await fetch(`${PUBLIC()}/oauth/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params).toString(),
  });
  return { status: res.status, body: (await res.json()) as Record<string, string> };
}

/**
 * The admin API budgets 120 requests per minute and IP in fixed one-minute windows (FormAuth AuthGuard.requestBudget), and every
 * full page load of the SPA costs about a dozen of them. After the UI steps so far the window is nearly used up, so wait for the
 * next window before a page load whose follow-up requests (customer/form pickers) must not run into 429.
 */
async function freshRequestWindow(page: Page) {
  await page.waitForTimeout(60_000 - (Date.now() % 60_000) + 1_000);
}

async function authorize(
  page: Page,
  query: Record<string, string>,
  tenantId: string,
  formId: string,
): Promise<URL> {
  await freshRequestWindow(page);
  await page.route('http://127.0.0.1:9/**', (r) => r.fulfill({ status: 200, body: 'callback' }));
  await page.goto('/oauth/authorize?' + new URLSearchParams(query).toString());
  await expect(page.getByRole('heading', { name: 'Zugriff erlauben?' })).toBeVisible();
  // The consent panel is part of the API & MCP page (/api-tokens?oauth_request=...); the page has no other consent UI.
  const box = page.getByRole('main');
  await expect(box).toContainText('E2E MCP-Client');
  await expect(box).toContainText('127.0.0.1');
  await box.locator('#consent-tenant').selectOption(tenantId);
  await expect(box.locator('#consent-form')).toBeEnabled();
  await box.locator('#consent-form').selectOption(formId);
  await box.getByRole('button', { name: 'Zugriff erlauben' }).click();
  await page.waitForURL(/127\.0\.0\.1:9\/cb/);
  return new URL(page.url());
}

test('MCP: personal token and OAuth against the public listener', async ({ page, context }) => {
  test.setTimeout(420_000);
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);
  const tenantA = await createCustomer(page, 'MCP Kunde');
  const formA = await createForm(page, 'MCP Kontakt');
  await configureAndPublish(page, [['email', 'E-Mail', 'email']]);
  await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
  const tenantB = await createCustomer(page, 'MCP Fremdkunde');
  expect(tenantB).not.toBe(tenantA);

  // MCP is off by default for every account (bootstrap admin included); allow it in the member administration.
  await page.goto('/accounts');
  await page
    .getByRole('button', { name: /^Aktionen für / })
    .first()
    .click();
  await page.getByRole('menuitem', { name: 'MCP erlauben' }).click();
  await page
    .getByRole('button', { name: /^Aktionen für / })
    .first()
    .click();
  await expect(page.getByRole('menuitem', { name: 'MCP sperren' })).toBeVisible();
  await page.keyboard.press('Escape');

  // (1) Personal API token created in the UI.
  await page.goto('/api-tokens');
  await page.getByRole('button', { name: 'Token anlegen', exact: true }).click();
  const dialog = page.getByRole('dialog');
  await dialog.getByLabel('Bezeichnung').fill('E2E-Token');
  await dialog.locator('#token-tenant').selectOption(tenantA);
  await dialog.getByRole('button', { name: 'Token anlegen', exact: true }).click();
  const shown = page.getByText(/^kfm_[0-9a-f]{64}$/);
  await expect(shown).toBeVisible();
  const kfm = (await shown.innerText()).trim();

  // (2) MCP with the personal token on the public listener.
  const anon = await rpc(null, 'tools/list');
  expect(anon.status).toBe(401);
  expect((await rpc('kfm_' + '0'.repeat(64), 'tools/list')).status).toBe(401);

  const init = await rpc(kfm, 'initialize', {
    protocolVersion: '2025-06-18',
    capabilities: {},
    clientInfo: { name: 'e2e', version: '1' },
  });
  expect(init.status).toBe(200);
  expect(init.body!.result.protocolVersion).toBe('2025-06-18');
  const list = await rpc(kfm, 'tools/list');
  expect(list.status).toBe(200);
  const names = toolNames(list);
  expect(names).toEqual(
    expect.arrayContaining([
      'formulare_auflisten',
      'konfiguration_lesen',
      'entwurf_lesen',
      'entwurf_validieren',
    ]),
  );
  // Only the selected scope: no write tool, no statistics tool.
  expect(names).not.toContain('entwurf_aendern');
  expect(names.some((n) => n.startsWith('statistik_'))).toBe(false);

  const own = await call(kfm, 'formulare_auflisten', { tenantId: tenantA });
  expect(own.body!.result.isError).toBe(false);
  expect(JSON.stringify(own.body!.result.structuredContent)).toContain(formA);
  const cfg = await call(kfm, 'konfiguration_lesen', { tenantId: tenantA, formId: formA });
  expect(cfg.body!.result.isError).toBe(false);
  // Foreign customer, and a foreign customer addressed with the own form id: no access.
  const foreign = await call(kfm, 'formulare_auflisten', { tenantId: tenantB });
  expect(foreign.body!.result.isError).toBe(true);
  expect(JSON.stringify(foreign.body)).not.toContain(tenantB);
  const mixed = await call(kfm, 'konfiguration_lesen', { tenantId: tenantB, formId: formA });
  expect(mixed.body!.result.isError).toBe(true);
  // A tool outside the token's scope is not callable either.
  const stat = await call(kfm, 'statistik_kpis', { tenantId: tenantA, formId: formA });
  expect(stat.body!.result?.isError ?? true).toBe(true);
  // Origin other than the admin origin is refused; GET is not allowed.
  const badOrigin = await fetch(`${PUBLIC()}/mcp/`, {
    method: 'POST',
    headers: { ...MCP_HEADERS, Authorization: `Bearer ${kfm}`, Origin: 'https://evil.example' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }),
  });
  expect(badOrigin.status).toBe(403);
  // Admin API and the consent endpoint are not reachable on the public listener.
  expect(
    (await fetch(`${PUBLIC()}/admin/api/v1/me`, { headers: { Authorization: `Bearer ${kfm}` } }))
      .status,
  ).toBe(404);
  expect((await fetch(`${PUBLIC()}/oauth/authorize`)).status).toBe(404);

  // (3) OAuth: dynamic registration on the public listener, PKCE S256, consent on the internal listener.
  const meta = (await (await fetch(`${PUBLIC()}/.well-known/oauth-protected-resource`)).json()) as {
    resource: string;
    scopes_supported: string[];
  };
  expect(meta.resource).toMatch(/\/mcp\/$/);
  expect(meta.scopes_supported).toContain('statistik.lesen');
  const reg = await fetch(`${PUBLIC()}/oauth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      client_name: 'E2E MCP-Client',
      redirect_uris: ['http://127.0.0.1:9/cb'],
    }),
  });
  expect(reg.status).toBe(201);
  const clientId = ((await reg.json()) as { client_id: string }).client_id;

  const verifier = b64url(randomBytes(32));
  const challenge = b64url(createHash('sha256').update(verifier).digest());
  const state = b64url(randomBytes(8));
  const back = await authorize(
    page,
    {
      response_type: 'code',
      client_id: clientId,
      redirect_uri: 'http://127.0.0.1:9/cb',
      code_challenge: challenge,
      code_challenge_method: 'S256',
      resource: meta.resource,
      scope: 'konfiguration.lesen statistik.lesen',
      state,
    },
    tenantA,
    formA,
  );
  expect(back.searchParams.get('state')).toBe(state);
  expect(back.searchParams.get('iss')).toBe(meta.resource.replace(/\/mcp\/$/, ''));
  const code = back.searchParams.get('code')!;
  expect(code).toMatch(/^ofc_/);

  const exchange = {
    client_id: clientId,
    redirect_uri: 'http://127.0.0.1:9/cb',
    resource: meta.resource,
  };
  // Wrong verifier is refused (and does not burn the code); the right one works exactly once.
  const wrong = await tokenRequest({
    ...exchange,
    grant_type: 'authorization_code',
    code,
    code_verifier: b64url(randomBytes(32)),
  });
  expect(wrong.status).toBe(400);
  const first = await tokenRequest({
    ...exchange,
    grant_type: 'authorization_code',
    code,
    code_verifier: verifier,
  });
  expect(first.status).toBe(200);
  expect(first.body.token_type).toBe('Bearer');
  const again = await tokenRequest({
    ...exchange,
    grant_type: 'authorization_code',
    code,
    code_verifier: verifier,
  });
  expect(again.status).toBe(400);

  const access1 = first.body.access_token;
  const oauthList = await rpc(access1, 'tools/list');
  expect(oauthList.status).toBe(200);
  const oauthNames = toolNames(oauthList);
  expect(oauthNames).toContain('statistik_kpis');
  expect(oauthNames).toContain('formulare_auflisten');
  const kpis = await call(access1, 'statistik_kpis', { tenantId: tenantA, formId: formA });
  expect(kpis.body!.result.isError).toBe(false);
  const kpisForeign = await call(access1, 'statistik_kpis', { tenantId: tenantB, formId: formA });
  expect(kpisForeign.body!.result.isError).toBe(true);

  // Refresh rotation: a new pair, the old refresh token is rejected, and its reuse revokes the whole family.
  const refresh1 = first.body.refresh_token;
  const second = await tokenRequest({
    ...exchange,
    grant_type: 'refresh_token',
    refresh_token: refresh1,
  });
  expect(second.status).toBe(200);
  expect(second.body.refresh_token).not.toBe(refresh1);
  expect((await rpc(second.body.access_token, 'tools/list')).status).toBe(200);
  const replay = await tokenRequest({
    ...exchange,
    grant_type: 'refresh_token',
    refresh_token: refresh1,
  });
  expect(replay.status).toBe(400);
  expect(replay.body.error).toBe('invalid_grant');
  const afterReplay = await tokenRequest({
    ...exchange,
    grant_type: 'refresh_token',
    refresh_token: second.body.refresh_token,
  });
  expect(afterReplay.status).toBe(400);
  expect((await rpc(second.body.access_token, 'tools/list')).status).toBe(401);
  expect((await rpc(access1, 'tools/list')).status).toBe(401);

  // The personal token is unaffected by the OAuth revocation.
  expect((await rpc(kfm, 'tools/list')).status).toBe(200);

  // Revoking the personal token in the UI takes effect immediately.
  await freshRequestWindow(page);
  await page.goto('/api-tokens');
  await page.getByRole('button', { name: 'Widerrufen' }).first().click();
  await expect(page.getByText('Widerrufen', { exact: true }).first()).toBeVisible();
  await expect.poll(async () => (await rpc(kfm, 'tools/list')).status).toBe(401);
});
