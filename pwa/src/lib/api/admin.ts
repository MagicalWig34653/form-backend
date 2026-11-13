import type { Http } from './http';

export interface Me {
  id: string;
  username: string;
  systemAdministrator: boolean;
}
/** Display preferences stored in the account (contracts/auth/p5-implementiert.openapi.yaml). */
export interface AccountPreferences {
  theme?: 'light' | 'dark' | 'system';
  accent?: string;
  glow?: number;
}
export interface Tenant {
  id: string;
  name: string;
  /** Rights that hold for the whole customer: a hint for the UI only, the server decides. */
  permissions: string[];
}
export interface FormListItem {
  id: string;
  name: string;
  active: boolean;
  currentReleaseId: string | null;
}
export interface FormDetail {
  id: string;
  name: string;
  active: boolean;
  currentReleaseId: string | null;
  currentReleaseVersion: number | null;
  draftIds: string[];
  mailConnectionId: string | null;
}
export type JsonObject = { [key: string]: unknown };
export interface Draft {
  id: string;
  revision: number;
  hash: string;
  document: JsonObject;
}
export interface Confirmation {
  confirmationId: string;
  expiresAt: string;
}
export interface Release {
  id: string;
  version: string;
  publication: { confirmedAt: string };
}
export interface CustomerKey {
  keyId: string;
  publicKey: string;
  generation: number;
}
export interface EntryItem {
  captchaStatus?: string;
  malwareStatus?: string;
  environment?: string;
  id: string;
  receivedAt: string | null;
  state: string;
  releaseId: string | null;
  keyId: string | null;
  held: boolean;
}
export interface ExportItem {
  id: string;
  receivedAt: string | null;
  keyId: string;
  generationId: string | null;
  package: string;
  attachments: number;
}
export interface CiphertextBody {
  id: string;
  keyId: string;
  generationId: string;
  format: string;
  package: string;
}
export interface StatisticsCounts {
  visits: number;
  begins: number;
  submits: number;
  abandons: number;
  conversion: number | null;
}
export interface Statistics extends StatisticsCounts {
  from: string;
  to: string;
  total: number;
  days: (StatisticsCounts & { date: string; count: number })[];
}
export interface KeyWrap {
  credentialId: string;
  prfSalt: string;
  iv: string;
  wrap: string;
}
export interface AccountRecovery {
  revision: string;
  salt: string;
  iterations: number;
  iv: string;
  wrap: string;
}
export interface KeyBundle {
  recovery?: AccountRecovery | null;
  rpId: string;
  accountPublicKey: string | null;
  wraps: KeyWrap[];
  access: { tenantId: string; kid: string; enc: string; sealed: string }[];
}
export interface KeyCandidate {
  accountId: string;
  username: string;
  publicKey: string;
  hasAccess: boolean;
}
export interface RotationState {
  requested?: boolean;
  active: { kid: string; publicKey: string } | null;
  retiring: { kid: string; publicKey: string } | null;
}
export interface RotationObject {
  id: string;
  kid: string;
  revision: number;
  ciphertext_sha256: string;
  package: string;
  formId: string;
  wrapKind: 'hpke' | 'sym';
  held: boolean;
}
export interface RecoveryRecord {
  keyId: string;
  salt: string;
  iterations: number;
  iv: string;
  wrap: string;
}
export interface Member {
  accountId: string;
  username: string;
  permissions: string[];
  inherited: string[];
}
export interface PasskeyInfo {
  credentialId: string;
  label: string;
  createdAt: string;
  lastUsedAt?: string;
  unlocksKeys: boolean;
}
export interface SdkCredentials {
  formId: string;
  tenantId: string;
  submitPath: string;
  customerKeyId: string;
  customerPublicKey: string;
  signingSeed: string;
  signingPublicKey: string;
  signingGeneration: number;
}
export interface MailConnectionInfo {
  id: string;
  kind: 'smtp' | 'mail-proxy';
  name: string;
}
export interface Connection extends MailConnectionInfo {
  enabled: boolean;
  hasCredential: boolean;
  config: JsonObject;
}
export interface MailDelivery {
  id: string;
  submissionId: string;
  kind: 'organisation' | 'confirmation';
  state: 'leased' | 'smtp-accepted' | 'waiting-manual' | 'abandoned' | 'uncertain' | 'pending';
  attempts: number;
  fence: number;
  errorCode?: string;
  transport: string;
  createdAt: string;
  updatedAt: string;
}
export interface TestResult {
  ok: boolean;
  code?: string;
  transient?: boolean;
}

const id = (s: string) => encodeURIComponent(s);

/** Typed calls of the admin API (contracts/auth/admin-api.openapi.yaml plus the VORGESCHLAGEN operations of docs/handoffs). */
export interface RetentionInfo {
  days: number;
  importedCount?: number;
  importedWithoutDeadline?: number;
  dueNowImported?: number;
  appliedToImported?: boolean;
}

export function createAdminApi(http: Http) {
  const t = (tenant: string) => `/tenants/${id(tenant)}`;
  const f = (tenant: string, form: string) => `${t(tenant)}/forms/${id(form)}`;
  return {
    me: (signal?: AbortSignal) => http.request<Me>('GET', '/me', { ...(signal ? { signal } : {}) }),
    /** Display preferences of the own account; keys that were never set are missing. */
    preferences: () => http.request<AccountPreferences>('GET', '/me/preferences'),
    /** Sets a subset; the answer is the complete stored state. */
    savePreferences: (values: AccountPreferences) =>
      http.request<AccountPreferences>('PUT', '/me/preferences', { body: values }),
    tenants: (signal?: AbortSignal) =>
      http.request<{ items: Tenant[] }>('GET', '/tenants', { ...(signal ? { signal } : {}) }),
    createTenant: (name: string) =>
      http.request<{ id: string }>('POST', '/tenants', { body: { name } }),

    forms: (tenant: string, signal?: AbortSignal) =>
      http.request<{ items: FormListItem[]; nextCursor: string | null }>(
        'GET',
        `${t(tenant)}/forms?limit=100`,
        { ...(signal ? { signal } : {}) },
      ),
    createForm: (tenant: string, name: string) =>
      http.request<{ id: string }>('POST', `${t(tenant)}/forms`, { body: { name } }),
    form: (tenant: string, form: string, signal?: AbortSignal) =>
      http.request<FormDetail>('GET', f(tenant, form), { ...(signal ? { signal } : {}) }),

    setFormActive: (tenant: string, form: string, active: boolean) =>
      http.request<void>('PUT', `${f(tenant, form)}/active`, { body: { active } }),

    draft: (tenant: string, form: string, draft: string, signal?: AbortSignal) =>
      http.request<Draft>('GET', `${f(tenant, form)}/drafts/${id(draft)}`, {
        ...(signal ? { signal } : {}),
      }),
    createDraft: (tenant: string, form: string) =>
      http.request<Draft>('POST', `${f(tenant, form)}/drafts`),
    updateDraft: (
      tenant: string,
      form: string,
      draft: string,
      document: JsonObject,
      revision: number,
    ) =>
      http.request<Draft>('PATCH', `${f(tenant, form)}/drafts/${id(draft)}`, {
        body: document,
        headers: { 'If-Match': `"${revision}"` },
      }),
    confirmPublication: (
      tenant: string,
      form: string,
      draft: string,
      revision: number,
      hash: string,
    ) =>
      http.request<Confirmation>('POST', `${f(tenant, form)}/publication-confirmations`, {
        body: { draftId: draft, revision, hash, confirm: true },
      }),
    publishRelease: (
      tenant: string,
      form: string,
      draft: string,
      revision: number,
      hash: string,
      confirmationId: string,
      key: string,
    ) =>
      http.request<Release>('POST', `${f(tenant, form)}/releases`, {
        body: { draftId: draft, revision, hash, confirmationId },
        headers: { 'Idempotency-Key': key },
      }),

    customerKey: (tenant: string) => http.request<CustomerKey>('GET', `${t(tenant)}/customer-key`),
    setCustomerKey: (tenant: string, publicKey: string) =>
      http.request<CustomerKey>('PUT', `${t(tenant)}/customer-key`, { body: { publicKey } }),
    entries: (tenant: string, form: string, cursor?: string) =>
      http.request<{ items: EntryItem[]; nextCursor: string | null }>(
        'GET',
        `${f(tenant, form)}/entries?limit=25${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`,
      ),
    attachment: (tenant: string, form: string, entry: string, ordinal: number) =>
      http.request<CiphertextBody>(
        'GET',
        `${f(tenant, form)}/entries/${encodeURIComponent(entry)}/attachments/${ordinal}`,
      ),
    ciphertext: (tenant: string, form: string, entry: string) =>
      http.request<CiphertextBody>(
        'GET',
        `${f(tenant, form)}/entries/${encodeURIComponent(entry)}/ciphertext`,
      ),
    holdObjects: (tenant: string, form: string, entry: string) =>
      http.request<{ items: (RotationObject & { sourceGenerationId: string })[] }>(
        'GET',
        `${f(tenant, form)}/entries/${id(entry)}/hold-objects`,
      ),
    setHold: (
      tenant: string,
      form: string,
      entry: string,
      held: boolean,
      objects: {
        objectId: string;
        expectedRevision: number;
        expectedSha256: string;
        sourceGenerationId: string;
        replacementPackage?: string;
      }[],
    ) =>
      http.request<{ id: string; held: boolean }>(
        'PUT',
        `${f(tenant, form)}/entries/${encodeURIComponent(entry)}/hold`,
        { body: { held, objects } },
      ),
    deleteEntries: (tenant: string, form: string, ids: string[]) =>
      http.request<{ deleted: string[]; held: string[]; missing: string[] }>(
        'POST',
        `${f(tenant, form)}/entries/delete`,
        { body: { ids } },
      ),
    retention: (tenant: string, form: string) =>
      http.request<RetentionInfo>('GET', `${f(tenant, form)}/retention`),
    /** Imported (legacy) submissions are only touched with `applyToImported`; `dryRun` writes nothing and names `dueNowImported`. */
    setRetention: (
      tenant: string,
      form: string,
      days: number,
      options?: { applyToImported?: boolean; dryRun?: boolean },
    ) =>
      http.request<RetentionInfo>('PUT', `${f(tenant, form)}/retention`, {
        body: {
          days,
          ...(options?.applyToImported ? { applyToImported: true } : {}),
          ...(options?.dryRun ? { dryRun: true } : {}),
        },
      }),
    exportPage: (tenant: string, form: string, cursor?: string) =>
      http.request<{ items: ExportItem[]; nextCursor: string | null }>(
        'GET',
        `${f(tenant, form)}/export?limit=100${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`,
      ),
    members: (tenant: string) =>
      http.request<{ items: Member[]; assignable: string[] }>('GET', `${t(tenant)}/members`),
    setMemberPermissions: (tenant: string, account: string, permissions: string[]) =>
      http.request<void>('PUT', `${t(tenant)}/members/${encodeURIComponent(account)}/permissions`, {
        body: { permissions },
      }),
    createAccount: (username: string, password: string) =>
      http.request<{ id: string; username: string; setupLink: string }>('POST', '/accounts', {
        body: { username, password },
      }),
    setPassword: (password: string) =>
      http.request<void>('PUT', '/me/password', { body: { password } }),
    passkeys: () => http.request<{ items: PasskeyInfo[] }>('GET', '/me/passkeys'),
    removePasskey: (credentialId: string) =>
      http.request<void>('DELETE', `/me/passkeys/${encodeURIComponent(credentialId)}`),
    keyBundle: () => http.request<KeyBundle>('GET', '/me/key-bundle'),
    saveAccountRecovery: (
      publicKey: string,
      expectedRevision: string | null,
      recovery: Omit<AccountRecovery, 'revision'>,
    ) =>
      http.request<{ revision: string }>('PUT', '/me/account-recovery', {
        body: { publicKey, expectedRevision, recovery },
      }),
    putAccountKey: (publicKey: string, wrap: KeyWrap) =>
      http.request<void>('PUT', '/me/account-key', { body: { publicKey, wrap } }),
    addAccountWrap: (wrap: KeyWrap) =>
      http.request<void>('POST', '/me/account-key/wraps', { body: wrap }),
    setCustomerKeyWithAccess: (
      tenant: string,
      body: {
        publicKey: string;
        access: { enc: string; sealed: string };
        recovery: { salt: string; iterations: number; iv: string; wrap: string };
      },
    ) => http.request<CustomerKey>('PUT', `${t(tenant)}/customer-key`, { body }),
    grantKeyAccess: (
      tenant: string,
      account: string,
      body: { kid: string; enc: string; sealed: string },
      quiet = false,
    ) =>
      http.request<void>('PUT', `${t(tenant)}/key-access/${encodeURIComponent(account)}`, {
        body,
        ...(quiet ? { quiet } : {}),
      }),
    revokeKeyAccess: (tenant: string, account: string) =>
      http.request<void>('DELETE', `${t(tenant)}/key-access/${id(account)}`),
    keyCandidates: (tenant: string) =>
      http.request<{ items: KeyCandidate[] }>('GET', `${t(tenant)}/key-candidates`),
    rotation: (tenant: string) => http.request<RotationState>('GET', `${t(tenant)}/key-rotation`),
    beginRotation: (
      tenant: string,
      body: {
        publicKey: string;
        access: { accountId: string; enc: string; sealed: string; expectedPublicKey?: string }[];
        automatic?: boolean;
        recovery: { salt: string; iterations: number; iv: string; wrap: string };
      },
    ) => http.request<void>('POST', `${t(tenant)}/key-rotation`, { body }),
    rotationObjects: (tenant: string, kid: string, after = '') =>
      http.request<{ items: RotationObject[]; next: string | null }>(
        'GET',
        `${t(tenant)}/key-rotation/objects?kid=${id(kid)}&limit=50${after ? `&after=${id(after)}` : ''}`,
      ),
    rewrapObject: (
      tenant: string,
      objectId: string,
      body: {
        expectedRevision: number;
        expectedSha256: string;
        package: string;
      },
    ) => http.request<void>('PUT', `${t(tenant)}/key-rotation/objects/${id(objectId)}`, { body }),
    finishRotation: (tenant: string, kid: string) =>
      http.request<void>('POST', `${t(tenant)}/key-rotation/finish`, { body: { kid } }),
    keyRecovery: (tenant: string, kid?: string, quiet = false) =>
      http.request<RecoveryRecord>(
        'GET',
        `${t(tenant)}/key-recovery${kid ? `?kid=${encodeURIComponent(kid)}` : ''}`,
        quiet ? { quiet } : {},
      ),
    adsStatistics: (tenant: string, form: string, days = 30) =>
      http.request<AdsStatistics>('GET', `${f(tenant, form)}/statistics/ads?days=${days}`),
    statistics: (tenant: string, form: string, days = 30) =>
      http.request<Statistics>('GET', `${f(tenant, form)}/statistics?days=${days}`),
    resend: (
      tenant: string,
      form: string,
      entry: string,
      body: {
        deliveryId: string;
        contentKey: string;
        confirmUncertain?: boolean;
        expectedFence?: number;
      },
    ) =>
      http.request<{ deliveryId: string; state: string }>(
        'POST',
        `${f(tenant, form)}/entries/${encodeURIComponent(entry)}/resends`,
        { body },
      ),
    sdkCredentials: (tenant: string, form: string) =>
      http.request<SdkCredentials>('POST', `${f(tenant, form)}/sdk-credentials`),

    tenantConnections: (tenant: string) =>
      http.request<{ items: MailConnectionInfo[] }>('GET', `${t(tenant)}/connections`),
    setMailConnection: (tenant: string, form: string, connectionId: string) =>
      http.request<void>('PUT', `${f(tenant, form)}/mail-connection`, { body: { connectionId } }),
    deliveries: (tenant: string, form: string) =>
      http.request<{ items: MailDelivery[] }>('GET', `${f(tenant, form)}/mail-deliveries?limit=50`),

    connections: () => http.request<{ items: Connection[] }>('GET', '/connections'),
    createConnection: (body: {
      kind: 'smtp' | 'mail-proxy';
      name: string;
      config: JsonObject;
      credential?: string;
    }) => http.request<{ id: string }>('POST', '/connections', { body }),
    setTlsVerification: (connectionId: string, verifyCertificate: boolean) =>
      http.request<void>('PUT', `/connections/${id(connectionId)}/tls-verification`, {
        body: { verifyCertificate },
      }),
    /** Finding C: connections taken over by the Umstieg arrive disabled; activation checks and converts them on the server. */
    setConnectionEnabled: (connectionId: string, enabled: boolean) =>
      http.request<void>('PUT', `/connections/${id(connectionId)}/enabled`, { body: { enabled } }),
    testConnection: (connectionId: string) =>
      http.request<TestResult>('POST', `/connections/${id(connectionId)}/test`),
    assignConnection: (tenant: string, connectionId: string) =>
      http.request<void>('PUT', `${t(tenant)}/connections/${id(connectionId)}`),
  };
}

export type AdminApi = ReturnType<typeof createAdminApi>;

export interface AdsStatistics {
  from: string;
  to: string;
  available: boolean;
  campaignsAvailable: boolean;
  minimumGroupSize: number;
  suppressed: boolean;
  groups: {
    segment: 'ads' | 'nonAds' | 'unknown';
    visits: number;
    submits: number;
    conversion: number | null;
  }[];
}
