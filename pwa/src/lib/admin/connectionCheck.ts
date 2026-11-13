/**
 * Leitet aus dem Ergebnis von POST /connections/:id/test eine Schrittliste ab.
 * Das Backend liefert nur {ok, code?, transient?}; die Schritte sind eine Ableitung aus dem Fehlercode:
 * Schritte vor dem fehlgeschlagenen gelten als in Ordnung (der Ablauf ist sequentiell), danach als übersprungen.
 * Gemessene Dauern oder Zertifikatsdaten gibt es nicht und werden nicht erfunden.
 */
export type CheckKind = 'smtp' | 'mail-proxy' | (string & {});
export type StepStatus = 'ok' | 'failed' | 'skipped';
export type StepId = 'dns' | 'tcp' | 'tls' | 'auth' | 'reach';

export const SMTP_STEPS: StepId[] = ['dns', 'tcp', 'tls', 'auth'];
export const PROXY_STEPS: StepId[] = ['dns', 'reach', 'auth'];

/** Fehlercode -> fehlgeschlagener Schritt; 'config' = Einstellungen ungültig (kein Schritt). */
const SMTP_CODES: Record<string, StepId | 'config'> = {
  unresolvable: 'dns',
  target_blocked: 'dns',
  connect_failed: 'tcp',
  timeout: 'tcp',
  connection_closed: 'tcp',
  tls_failed: 'tls',
  starttls_unsupported: 'tls',
  insecure_not_allowed: 'tls',
  auth_failed: 'auth',
  auth_unsupported: 'auth',
  auth_over_plain: 'auth',
  credential_missing: 'auth',
  connection_invalid: 'config',
};
const PROXY_CODES: Record<string, StepId | 'config'> = {
  proxy_url_invalid: 'config',
  proxy_missing_parameters: 'config',
  connection_invalid: 'config',
  credential_missing: 'auth',
  target_blocked: 'dns',
  unresolvable: 'dns',
  proxy_unreachable: 'reach',
  proxy_auth_failed: 'auth',
};

/** Codes mit eigenem Text in de.ts (admin.connections.check.codes). */
export const KNOWN_CODES: string[] = [
  ...new Set([...Object.keys(SMTP_CODES), ...Object.keys(PROXY_CODES)]),
];

export interface CheckStep {
  id: StepId;
  status: StepStatus;
}

export interface CheckOutcome {
  ok: boolean;
  /** Leer, wenn keine Schrittliste ableitbar ist (Speicher-Verbindungen, unbekannter Code). */
  steps: CheckStep[];
  /** Fehlercode des Backends, falls fehlgeschlagen. */
  code?: string;
  /** Schritt, der den Fehler trägt; null bei Konfigurationsfehler oder unbekanntem Code. */
  failedStep: StepId | null;
  /** Code ist bekannt und hat einen eigenen Text. */
  known: boolean;
  transient: boolean;
}

export function deriveCheck(
  kind: CheckKind,
  result: { ok: boolean; code?: string; transient?: boolean },
): CheckOutcome {
  const ids = kind === 'smtp' ? SMTP_STEPS : kind === 'mail-proxy' ? PROXY_STEPS : null;
  const transient = result.transient === true;
  if (!ids) {
    // Speicher-/Übertragungsverbindungen: keine Schrittliste, nur Ergebnis.
    return {
      ok: result.ok,
      steps: [],
      code: result.ok ? undefined : (result.code ?? '?'),
      failedStep: null,
      known: result.code === 'credential_missing' || result.code === 'connection_invalid',
      transient,
    };
  }
  if (result.ok) {
    return {
      ok: true,
      steps: ids.map((id) => ({ id, status: 'ok' as const })),
      failedStep: null,
      known: true,
      transient: false,
    };
  }
  const code = result.code ?? '?';
  const map = kind === 'smtp' ? SMTP_CODES : PROXY_CODES;
  const target = Object.hasOwn(map, code) ? map[code] : undefined;
  if (target === undefined) {
    // Unbekannter Code: keine Schrittliste, nichts erfinden.
    return { ok: false, steps: [], code, failedStep: null, known: false, transient };
  }
  if (target === 'config') {
    return {
      ok: false,
      steps: ids.map((id) => ({ id, status: 'skipped' as const })),
      code,
      failedStep: null,
      known: true,
      transient,
    };
  }
  const at = ids.indexOf(target);
  return {
    ok: false,
    steps: ids.map((id, i) => ({
      id,
      status: i < at ? ('ok' as const) : i === at ? ('failed' as const) : ('skipped' as const),
    })),
    code,
    failedStep: target,
    known: true,
    transient,
  };
}

/** "412 ms" unter einer Sekunde, sonst "1,2 s". */
export function formatDuration(ms: number): string {
  if (ms < 1000) return `${Math.max(0, Math.round(ms))} ms`;
  return `${(ms / 1000).toFixed(1).replace('.', ',')} s`;
}
