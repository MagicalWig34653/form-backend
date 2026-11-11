import type { Page } from '@playwright/test';

// Shared API mock for the screenshot spec and the UI polish specs.
export const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
export const F = '22222222-2222-4222-8222-222222222222';
export const D = '33333333-3333-4333-8333-333333333333';
export const E = '44444444-4444-4444-8444-444444444444';
const doc = {
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
    },
  },
  views: [
    {
      id: 'v',
      version: '1.0.0',
      form: { id: F, version: '1.0.0', sha256: 'x' },
      steps: [{ id: 'm', sections: [{ id: 's', fields: [{ fieldId: 'message' }] }] }],
    },
  ],
};
const j = (b: unknown, s = 200) => ({
  status: s,
  contentType: 'application/json',
  body: JSON.stringify(b),
});
export async function mock(page: Page) {
  await page.route('**/admin/api/v1/**', (r) => {
    const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
    const f = `/tenants/${T}/forms/${F}`;
    if (p === '/auth/session')
      return r.fulfill(
        j({ state: 'authenticated', csrfToken: 'c', subjectId: 'a', expiresAt: 'x' }),
      );
    if (p === '/me') return r.fulfill(j({ id: 'a', username: 'admin', systemAdministrator: true }));
    if (p === '/setup-state') return r.fulfill(j({ required: false }));
    if (p === '/tenants')
      return r.fulfill(
        j({
          items: [
            {
              id: T,
              name: 'Kunde A',
              permissions: [
                'form.read',
                'draft.write',
                'release.publish',
                'key.manage',
                'identity.manage',
              ],
            },
            { id: 'bbbbbbbb-1111-4111-8111-11111111111b', name: 'Kunde B', permissions: [] },
          ],
        }),
      );
    if (p === `/tenants/${T}/forms`)
      return r.fulfill(
        j({
          items: [
            { id: F, name: 'Kontakt', active: true, currentReleaseId: D },
            { id: 'cc', name: 'Newsletter', active: false, currentReleaseId: null },
          ],
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
          mailConnectionId: null,
        }),
      );
    if (p === `${f}/drafts/${D}`)
      return r.fulfill(j({ id: D, revision: 1, hash: 'h', document: doc }));
    if (p === `${f}/entries`)
      return r.fulfill(
        j({
          items: [
            {
              id: E,
              receivedAt: '2026-10-31T10:00:00Z',
              state: 'accepted',
              releaseId: D,
              keyId: 'k',
              held: false,
            },
          ],
          nextCursor: null,
        }),
      );
    if (p === `${f}/statistics`) {
      // Like the server: the period is days long and only days with events are listed.
      const days = Number(new URL(r.request().url()).searchParams.get('days') ?? '30');
      const end = Date.parse('2026-11-01T00:00:00Z');
      const iso = (ms: number) => new Date(ms).toISOString().slice(0, 10);
      return r.fulfill(
        j({
          from: iso(end - (days - 1) * 86_400_000),
          to: iso(end),
          total: 5,
          visits: 20,
          begins: 12,
          submits: 5,
          abandons: 3,
          conversion: 0.25,
          days: [
            {
              date: '2026-10-31',
              count: 3,
              visits: 20,
              begins: 10,
              submits: 3,
              abandons: 2,
              conversion: 0.15,
            },
            {
              date: '2026-11-01',
              count: 2,
              visits: 0,
              begins: 2,
              submits: 2,
              abandons: 1,
              conversion: null,
            },
          ],
        }),
      );
    }
    if (p === `/tenants/${T}/members`)
      return r.fulfill(
        j({
          items: [
            {
              accountId: 'a',
              username: 'admin',
              permissions: [
                'form.read',
                'draft.write',
                'release.publish',
                'key.manage',
                'identity.manage',
              ],
              inherited: [],
            },
          ],
          assignable: [
            'form.read',
            'form.create',
            'draft.write',
            'release.publish',
            'key.manage',
            'identity.manage',
          ],
        }),
      );
    if (p === '/me/passkeys')
      return r.fulfill(
        j({
          items: [
            {
              credentialId: 'AQE',
              label: 'Laptop',
              createdAt: '2026-10-01T10:00:00Z',
              unlocksKeys: true,
            },
          ],
        }),
      );
    if (p === `${f}/retention`) return r.fulfill(j({ days: 90 }));
    if (p === `${f}/statistics/ads`)
      return r.fulfill(
        j({
          from: '2026-10-03',
          to: '2026-11-01',
          available: false,
          campaignsAvailable: false,
          minimumGroupSize: 10,
          suppressed: false,
          groups: [],
        }),
      );
    if (p === '/settings')
      return r.fulfill(
        j({
          revision: 'r',
          items: [
            {
              definition: {
                key: 'mcp.requestsPerMinute',
                group: 'MCP-Token-Ratelimit',
                envName: 'FORM_MCP_TOKEN_RATE_LIMIT',
                type: 'integer',
                defaultValue: '60',
                minimum: 1,
                maximum: 100000,
                restartRequired: false,
              },
              value: '60',
              source: 'default',
              locked: false,
            },
            {
              definition: {
                key: 'admin.origin',
                group: 'Hosts',
                envName: 'FORM_ADMIN_ORIGIN',
                type: 'origin',
                defaultValue: '',
                restartRequired: false,
              },
              value: 'https://forms.example.org',
              source: 'env',
              locked: true,
            },
            {
              definition: {
                key: 'admin.rpID',
                group: 'Hosts',
                envName: 'FORM_RP_ID',
                type: 'host',
                defaultValue: '',
                restartRequired: false,
              },
              value: 'forms.example.org',
              source: 'env',
              locked: true,
            },
            {
              definition: {
                key: 'ops.intervalSeconds',
                group: 'Limits',
                envName: 'FORM_OPS_INTERVAL_SECONDS',
                type: 'integer',
                defaultValue: '900',
                minimum: 60,
                maximum: 86400,
                restartRequired: false,
              },
              value: '1800',
              source: 'db',
              locked: false,
            },
            {
              definition: {
                key: 'ops.threshold',
                group: 'Limits',
                envName: 'FORM_OPS_THRESHOLD',
                type: 'integer',
                defaultValue: '1',
                minimum: 1,
                maximum: 2,
                restartRequired: false,
              },
              value: '1',
              source: 'default',
              locked: false,
            },
            {
              definition: {
                key: 'ops.retentionDays',
                group: 'Limits',
                envName: 'FORM_OPS_RETENTION_DAYS',
                type: 'integer',
                defaultValue: '30',
                minimum: 1,
                maximum: 365,
                restartRequired: false,
              },
              value: '30',
              source: 'default',
              locked: false,
            },
            {
              definition: {
                key: 'ops.recipient',
                group: 'Limits',
                envName: 'FORM_OPS_RECIPIENT',
                type: 'mailbox',
                defaultValue: '',
                restartRequired: false,
              },
              value: '',
              source: 'default',
              locked: false,
            },
            {
              definition: {
                key: 'ops.sender',
                group: 'Limits',
                envName: 'FORM_OPS_SENDER',
                type: 'mailbox',
                defaultValue: '',
                restartRequired: false,
              },
              value: '',
              source: 'default',
              locked: false,
            },
            {
              definition: {
                key: 'ops.connection',
                group: 'Limits',
                envName: 'FORM_OPS_CONNECTION',
                type: 'uuid',
                defaultValue: '',
                restartRequired: false,
              },
              value: '',
              source: 'default',
              locked: false,
            },
            {
              definition: {
                key: 'log.level',
                group: 'Limits',
                envName: 'FORM_LOG_LEVEL',
                type: 'level',
                defaultValue: 'info',
                restartRequired: false,
              },
              value: 'info',
              source: 'default',
              locked: false,
            },
            {
              definition: {
                key: 'mail.restricted',
                group: 'Missbrauchsschutz',
                envName: 'FORM_MAIL_RESTRICTED',
                type: 'boolean',
                defaultValue: 'false',
                restartRequired: false,
              },
              value: 'false',
              source: 'default',
              locked: false,
            },
            {
              definition: {
                key: 'webhook.perForm',
                group: 'Webhook-Limits',
                envName: 'FORM_WEBHOOK_MAX_PER_FORM',
                type: 'integer',
                defaultValue: '5',
                minimum: 0,
                maximum: 10000,
                restartRequired: false,
              },
              value: '5',
              source: 'default',
              locked: false,
            },
          ],
        }),
      );
    if (p === '/ops/access')
      return r.fulfill(
        j({
          system: true,
          cleanup: true,
          alarm: { outcome: 'accepted', suppressed: 2 },
          forms: [{ customer: T, id: F, name: 'Kontakt' }],
        }),
      );
    if (p === '/ops')
      return r.fulfill(
        j({
          items: [
            {
              id: 1,
              event: 'accepted',
              operation: 'mail',
              priority: 1,
              occurredAt: '2026-11-03T10:00:00Z',
            },
          ],
        }),
      );
    if (p === '/accounts')
      return r.fulfill(
        j({
          items: [
            { id: 'a', username: 'admin', active: true, mcpAllowed: true },
            { id: 'u2', username: 'erika', active: true, mcpAllowed: false },
          ],
        }),
      );
    if (p === `/tenants/${T}/connections`)
      return r.fulfill(j({ items: [{ id: 'c1', kind: 'smtp', name: 'Mailserver' }] }));
    if (p === '/connections')
      return r.fulfill(
        j({
          items: [
            {
              id: 'c1',
              kind: 'smtp',
              name: 'Mailserver',
              enabled: true,
              hasCredential: false,
              config: { host: 'smtp.example.org' },
            },
          ],
        }),
      );
    return r.fulfill(j({ items: [] }));
  });
}
