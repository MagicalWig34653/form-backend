// SPDX-License-Identifier: AGPL-3.0-only
/** Pure helpers for the guided migration flow; all state is derived from real job data. */

export interface FlowJob {
  state: string;
  dryRun: boolean;
}

/** Number of steps: source, mapping, import, review, switch. */
export const MIGRATION_STEPS = 5;

/**
 * Step the data puts the user in: no job yet means source (0) or mapping (1) after a
 * successful source check; a running or dry run stays in the import step (2); a finished
 * import waiting for review lands in review (3); a closed run lands in the switch step (4).
 */
export function landingStep(jobs: FlowJob[], sourceChecked: boolean): number {
  const job = jobs[0];
  if (!job) return sourceChecked ? 1 : 0;
  if (job.state === 'closed') return 4;
  if (job.state === 'review') return job.dryRun ? 2 : 3;
  return 2;
}

/**
 * Furthest step the user may open. Like the landing step, except that a finished import in
 * review already unlocks the switch step, where the old access is removed.
 */
export function reachedStep(jobs: FlowJob[], sourceChecked: boolean): number {
  const job = jobs[0];
  return job?.state === 'review' && !job.dryRun ? 4 : landingStep(jobs, sourceChecked);
}

/** The user may only move forward as far as the data has reached. */
export function canAdvance(step: number, reached: number): boolean {
  return step < MIGRATION_STEPS - 1 && step < reached;
}

/** Source inventory of POST /migration/test (ADR 0040). Metadata only, never secrets or content. */
export interface SourceForm {
  id: string;
  name: string | null;
  connectionIds?: string[];
}
export interface SourceConnection {
  id: string;
  kind: string;
  name: string | null;
}
export interface SourceKey {
  kid: string;
  /** `aktiv`, `auslaufend` or `andere`. */
  status: string;
  /** Unix seconds. */
  createdAt: number | null;
  publicKeyValid: boolean;
}
export interface KeyUsage {
  kid: string;
  submissions: number;
  inKeyStore: boolean;
  formIds: string[];
  formIdsComplete: boolean;
}
export interface SourceInventory {
  schemaHMAC: string;
  formIds: string[];
  connectionIds?: string[];
  counts: Record<string, number>;
  forms?: SourceForm[];
  connections?: SourceConnection[];
  keys?: SourceKey[];
  keysComplete?: boolean;
  invalidKeys?: number;
  keyUsage?: { complete: boolean; scannedSubmissions: number; items: KeyUsage[] };
}
export interface PlanCustomer {
  id: string;
  name: string;
}

/** Forms of the source with names; older answers without `forms` fall back to the bare ids. */
export function sourceForms(inventory: SourceInventory | undefined): SourceForm[] {
  if (!inventory) return [];
  const named = new Map((inventory.forms ?? []).map((form) => [form.id, form]));
  return inventory.formIds.map((id) => named.get(id) ?? { id, name: null });
}
export function sourceConnections(inventory: SourceInventory | undefined): SourceConnection[] {
  if (!inventory) return [];
  const named = new Map((inventory.connections ?? []).map((c) => [c.id, c]));
  return (inventory.connectionIds ?? []).map((id) => named.get(id) ?? { id, kind: '', name: null });
}

/**
 * Stable namespace proposal from the source database name (host as fallback), so that a repeated
 * check of the same source yields the same value. Only [A-Za-z0-9._-], 1 to 64 characters.
 */
export function suggestNamespace(host: string, database: string): string {
  const clean = (value: string) =>
    value
      .trim()
      .replace(/[^A-Za-z0-9._-]+/g, '-')
      .replace(/-+/g, '-')
      .replace(/^-|-$/g, '');
  const base = clean(database) || clean(host);
  return base ? `legacy-${base}`.slice(0, 64).replace(/-$/, '') : '';
}

const known = (customers: PlanCustomer[], id: string | undefined): id is string =>
  !!id && customers.some((c) => c.id === id);

/** Every source form goes to one customer: the user's choice, otherwise the first customer. */
export function assignForms(
  formIds: string[],
  customers: PlanCustomer[],
  choice: Record<string, string>,
): Record<string, string> {
  const first = customers[0]?.id;
  if (!first) return {};
  return Object.fromEntries(
    formIds.map((id) => {
      const chosen = choice[id];
      return [id, known(customers, chosen) ? chosen : first];
    }),
  );
}

/**
 * Mail connections: the user's choice; otherwise, with a single customer, that customer; with
 * several, the customers whose forms reference the connection. Unreferenced connections stay
 * unassigned when several customers exist (no guessing).
 */
export function assignConnections(
  connections: SourceConnection[],
  forms: SourceForm[],
  formCustomers: Record<string, string>,
  customers: PlanCustomer[],
  choice: Record<string, string>,
): Record<string, string[]> {
  const result: Record<string, string[]> = {};
  for (const connection of connections) {
    const chosen = choice[connection.id];
    if (known(customers, chosen)) result[connection.id] = [chosen];
    else if (customers.length === 1) result[connection.id] = [customers[0]!.id];
    else {
      const owners = [
        ...new Set(
          forms
            .filter((form) => form.connectionIds?.includes(connection.id))
            .map((form) => formCustomers[form.id])
            .filter((id): id is string => known(customers, id)),
        ),
      ].sort();
      if (owners.length) result[connection.id] = owners;
    }
  }
  return result;
}

/** The importer takes over a key row only with status aktiv/auslaufend and keyID(publicKey) == kid. */
export const keyImportable = (key: SourceKey): boolean =>
  key.publicKeyValid && (key.status === 'aktiv' || key.status === 'auslaufend');

/**
 * Customer of each importable key: the user's choice; with a single customer always that one;
 * otherwise the single customer owning every form whose submissions use the key (only when the
 * form list is complete). Anything else stays open.
 */
export function assignKeys(
  keys: SourceKey[],
  usage: KeyUsage[],
  formCustomers: Record<string, string>,
  customers: PlanCustomer[],
  choice: Record<string, string>,
): Record<string, string> {
  const result: Record<string, string> = {};
  for (const key of keys.filter(keyImportable)) {
    const chosen = choice[key.kid];
    if (known(customers, chosen)) result[key.kid] = chosen;
    else if (customers.length === 1) result[key.kid] = customers[0]!.id;
    else {
      const use = usage.find((u) => u.kid === key.kid);
      const owners = [...new Set(use?.formIds.map((id) => formCustomers[id]))];
      const owner = owners[0];
      if (use?.formIdsComplete && owners.length === 1 && known(customers, owner))
        result[key.kid] = owner;
    }
  }
  return result;
}

/**
 * Generation numbers per customer without gaps: retiring keys first, then the active key (the
 * active generation carries the highest number; a later rotation continues with number + 1),
 * each group oldest first by erstelltAm, ties by kid.
 */
export function generationNumbers(
  keys: SourceKey[],
  keyCustomers: Record<string, string>,
): Record<string, number> {
  const byCustomer = new Map<string, SourceKey[]>();
  for (const key of keys) {
    const owner = keyCustomers[key.kid];
    if (!owner || !keyImportable(key)) continue;
    byCustomer.set(owner, [...(byCustomer.get(owner) ?? []), key]);
  }
  const result: Record<string, number> = {};
  for (const list of byCustomer.values()) {
    list
      .sort(
        (a, b) =>
          Number(a.status === 'aktiv') - Number(b.status === 'aktiv') ||
          (a.createdAt ?? 0) - (b.createdAt ?? 0) ||
          (a.kid < b.kid ? -1 : a.kid > b.kid ? 1 : 0),
      )
      .forEach((key, index) => (result[key.kid] = index + 1));
  }
  return result;
}

/** Plan objects the expert JSON extends entry by entry (its values win); other keys replace. */
type MergedKey =
  | 'customers'
  | 'formCustomers'
  | 'connectionCustomers'
  | 'keyCustomers'
  | 'keyGenerationNumbers'
  | 'statisticsPublicKeys';

export interface PlanInput {
  namespace: string;
  snapshot: string;
  customers: PlanCustomer[];
  formCustomers: Record<string, string>;
  connectionCustomers: Record<string, string[]>;
  keys: SourceKey[];
  keyCustomers: Record<string, string>;
  /** Raw text of the expert field; `{}` or empty means none. */
  extra: string;
}
export interface ImportPlan {
  namespace: string;
  dumpSHA256: string;
  customers: Record<string, string>;
  formCustomers: Record<string, string>;
  connectionCustomers: Record<string, string[]>;
  keyCustomers: Record<string, string>;
  keyGenerationNumbers: Record<string, number>;
  statisticsPublicKeys: Record<string, string>;
  [key: string]: unknown;
}

/**
 * Builds the plan from the automatic assignment and merges the expert JSON over it. Generation
 * numbers follow the merged key assignment; explicit numbers from the JSON win.
 */
export function buildPlan(input: PlanInput): { plan: ImportPlan; extraValid: boolean } {
  let extra: Record<string, unknown> = {};
  let extraValid = true;
  try {
    const parsed: unknown = input.extra.trim() ? JSON.parse(input.extra) : {};
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed))
      extra = parsed as Record<string, unknown>;
    else extraValid = false;
  } catch {
    extraValid = false;
  }
  const part = <T>(key: MergedKey): Record<string, T> => {
    const value = extra[key];
    return value && typeof value === 'object' && !Array.isArray(value)
      ? (value as Record<string, T>)
      : {};
  };
  const keyCustomers = { ...input.keyCustomers, ...part<string>('keyCustomers') };
  const plan: ImportPlan = {
    ...extra,
    namespace: typeof extra.namespace === 'string' ? extra.namespace : input.namespace.trim(),
    dumpSHA256: typeof extra.dumpSHA256 === 'string' ? extra.dumpSHA256 : input.snapshot,
    customers: {
      ...Object.fromEntries(input.customers.map((c) => [c.id, c.name.trim()])),
      ...part<string>('customers'),
    },
    formCustomers: { ...input.formCustomers, ...part<string>('formCustomers') },
    connectionCustomers: {
      ...input.connectionCustomers,
      ...part<string[]>('connectionCustomers'),
    },
    keyCustomers,
    keyGenerationNumbers: {
      ...generationNumbers(input.keys, keyCustomers),
      ...part<number>('keyGenerationNumbers'),
    },
    statisticsPublicKeys: part<string>('statisticsPublicKeys'),
  };
  return { plan, extraValid };
}

export type MappingIssue =
  | 'source'
  | 'customer'
  | 'name'
  | 'forms'
  | 'namespace'
  | 'snapshot'
  | 'schema'
  | 'connections'
  | 'keys'
  | 'activeKeys'
  | 'extra';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA256 = /^[0-9a-f]{64}$/;
/** Server rule: printable ASCII without spaces, 1 to 64 bytes. */
const NAMESPACE = /^[!-~]{1,64}$/;
export const isSha256 = (value: string): boolean => SHA256.test(value);

export interface IssueInput {
  plan: ImportPlan;
  extraValid: boolean;
  /** Form ids of the source; every one must be assigned (the server compares the full set). */
  formIds: string[];
  connectionIds: string[];
  keys: SourceKey[];
  expectedSchema: string;
  sourceChanged: boolean;
}
/** Lists what is still missing or malformed in the merged plan (empty means ready to start). */
export function mappingIssues(input: IssueInput): MappingIssue[] {
  const { plan } = input;
  const owner = (id: string | undefined) => !!id && Object.hasOwn(plan.customers, id);
  const customers = Object.entries(plan.customers);
  const issues: MappingIssue[] = [];
  if (input.sourceChanged) issues.push('source');
  if (!customers.length || customers.some(([id]) => !UUID.test(id))) issues.push('customer');
  if (customers.some(([, name]) => typeof name !== 'string' || !name.trim())) issues.push('name');
  const forms = Object.entries(plan.formCustomers);
  if (
    !forms.length ||
    forms.some(([id, customer]) => !UUID.test(id) || !owner(customer)) ||
    input.formIds.some((id) => !Object.hasOwn(plan.formCustomers, id))
  )
    issues.push('forms');
  if (!NAMESPACE.test(plan.namespace)) issues.push('namespace');
  if (!SHA256.test(plan.dumpSHA256)) issues.push('snapshot');
  if (!SHA256.test(input.expectedSchema)) issues.push('schema');
  if (
    input.connectionIds.some((id) => {
      const owners = plan.connectionCustomers[id];
      return !Array.isArray(owners) || !owners.length || !owners.every(owner);
    })
  )
    issues.push('connections');
  const importable = input.keys.filter(keyImportable);
  if (
    importable.some(
      (key) =>
        !owner(plan.keyCustomers[key.kid]) || !((plan.keyGenerationNumbers[key.kid] ?? 0) > 0),
    )
  )
    issues.push('keys');
  const active = importable
    .filter((key) => key.status === 'aktiv' && owner(plan.keyCustomers[key.kid]))
    .map((key) => plan.keyCustomers[key.kid]);
  if (new Set(active).size !== active.length) issues.push('activeKeys');
  if (!input.extraValid) issues.push('extra');
  return issues;
}

export interface KeyWarnings {
  /** kids used by submissions but absent from datenschluessel. */
  missing: KeyUsage[];
  /** kids used by submissions whose key row the importer does not take over (status, public key). */
  unusable: KeyUsage[];
  /** kids used by forms of another customer than the key's customer. */
  foreign: KeyUsage[];
  /** Key rows that are not taken over. */
  skipped: SourceKey[];
  /** Submissions with a key problem; the first one stops the run (unknownKeyGeneration). */
  affectedSubmissions: number;
}
/** What the importer will do with the keys of the source, derived from the plan before the start. */
export function keyWarnings(
  keys: SourceKey[],
  usage: KeyUsage[],
  plan: Pick<ImportPlan, 'keyCustomers' | 'formCustomers'>,
): KeyWarnings {
  const byKid = new Map(keys.map((key) => [key.kid, key]));
  const importable = (kid: string) => {
    const key = byKid.get(kid);
    return !!key && keyImportable(key);
  };
  const missing = usage.filter((u) => !u.inKeyStore);
  const unusable = usage.filter((u) => u.inKeyStore && !importable(u.kid));
  const foreign = usage.filter((u) => {
    const owner = plan.keyCustomers[u.kid];
    return (
      u.inKeyStore &&
      importable(u.kid) &&
      !!owner &&
      u.formIds.some(
        (id) => plan.formCustomers[id] !== undefined && plan.formCustomers[id] !== owner,
      )
    );
  });
  const skipped = keys.filter((key) => !keyImportable(key));
  const affectedSubmissions = [...missing, ...unusable, ...foreign].reduce(
    (sum, u) => sum + u.submissions,
    0,
  );
  return { missing, unusable, foreign, skipped, affectedSubmissions };
}

export interface ReportRow {
  key: string;
  value: string;
}
/** Flattens a job report into readable key/value rows (depth-limited). */
export function reportRows(report: unknown, prefix = '', depth = 0): ReportRow[] {
  if (report === null || report === undefined) return [];
  if (typeof report !== 'object') return [{ key: prefix, value: String(report) }];
  if (depth >= 3) return [{ key: prefix, value: JSON.stringify(report) }];
  return Object.entries(report as Record<string, unknown>).flatMap(([k, v]) =>
    reportRows(v, prefix ? `${prefix}.${k}` : k, depth + 1),
  );
}

/** Sorted inventory counters for display. */
export function countRows(counts: Record<string, number>): ReportRow[] {
  return Object.entries(counts)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => ({ key, value: String(value) }));
}

/**
 * Plain-language cause for the error code of a failed run. The server stores either a fixed code
 * (e.g. conflict) or `<reason>@<column>` for a value in the source that could not be taken over
 * (never the value itself). Unknown codes are shown as they are.
 */
export function describeJobError(
  code: string,
  texts: { reasons: Record<string, string>; codes: Record<string, string>; column: string },
): string {
  const known = texts.codes[code];
  if (known) return known;
  const at = code.indexOf('@');
  if (at > 0) {
    const reason = code.slice(0, at);
    const column = code.slice(at + 1);
    const text = texts.reasons[reason];
    if (text) return `${text} (${texts.column} ${column})`;
  }
  return code;
}
