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

export interface MappingInput {
  customer: string;
  name: string;
  forms: string;
  namespace: string;
  snapshot: string;
  expectedSchema: string;
}
export type MappingIssue = 'customer' | 'name' | 'forms' | 'namespace' | 'snapshot' | 'schema';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA256 = /^[0-9a-f]{64}$/;
export const isSha256 = (value: string): boolean => SHA256.test(value);

/** Lists which required mapping values are still missing or malformed (empty means ready). */
export function mappingIssues(input: MappingInput): MappingIssue[] {
  const ids = input.forms.split(/[\s,]+/).filter(Boolean);
  const issues: MappingIssue[] = [];
  if (!UUID.test(input.customer.trim())) issues.push('customer');
  if (!input.name.trim()) issues.push('name');
  if (!ids.length || ids.some((id) => !UUID.test(id))) issues.push('forms');
  if (!input.namespace.trim()) issues.push('namespace');
  if (!SHA256.test(input.snapshot)) issues.push('snapshot');
  if (!SHA256.test(input.expectedSchema)) issues.push('schema');
  return issues;
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
