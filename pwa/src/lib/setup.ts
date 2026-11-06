// SPDX-License-Identifier: AGPL-3.0-only
export const setupSteps = ['Konto', 'Wiederherstellung', 'Mail', 'Adressen', 'Umstieg', 'Prüfen'];
export const migrationStates: Record<string, string> = {
  queued: 'Wartet auf Freigabe des Workers',
  running: 'Läuft',
  paused: 'Pausiert',
  failed: 'Fehlgeschlagen',
  review: 'Wartet auf Prüfung',
  closed: 'Altzugriff entfernt',
};
export function createImportPlan(
  customer: string,
  name: string,
  forms: string,
  namespace: string,
  dumpSHA256: string,
) {
  const ids = forms.split(/[\s,]+/).filter(Boolean);
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  if (
    !uuid.test(customer) ||
    !name.trim() ||
    !ids.length ||
    ids.some((id) => !uuid.test(id)) ||
    !/^[0-9a-f]{64}$/.test(dumpSHA256) ||
    !namespace.trim()
  )
    throw new Error('Bitte Kunde, Formular-UUIDs und Snapshot-SHA256 vollständig angeben.');
  return {
    namespace,
    dumpSHA256,
    customers: { [customer]: name },
    formCustomers: Object.fromEntries(ids.map((id) => [id, customer])),
    connectionCustomers: {},
    keyCustomers: {},
    keyGenerationNumbers: {},
    statisticsPublicKeys: {},
  };
}
