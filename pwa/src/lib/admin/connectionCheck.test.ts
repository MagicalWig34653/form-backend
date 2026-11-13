import { describe, expect, it } from 'vitest';
import { deriveCheck, formatDuration, KNOWN_CODES } from './connectionCheck';
import { t } from '../i18n';

const status = (o: ReturnType<typeof deriveCheck>) => o.steps.map((s) => `${s.id}:${s.status}`);

describe('deriveCheck SMTP', () => {
  it('ok: alle vier Schritte in Ordnung', () => {
    const o = deriveCheck('smtp', { ok: true });
    expect(o.ok).toBe(true);
    expect(status(o)).toEqual(['dns:ok', 'tcp:ok', 'tls:ok', 'auth:ok']);
  });
  it.each([
    ['unresolvable', 'dns', ['dns:failed', 'tcp:skipped', 'tls:skipped', 'auth:skipped']],
    ['target_blocked', 'dns', ['dns:failed', 'tcp:skipped', 'tls:skipped', 'auth:skipped']],
    ['connect_failed', 'tcp', ['dns:ok', 'tcp:failed', 'tls:skipped', 'auth:skipped']],
    ['timeout', 'tcp', ['dns:ok', 'tcp:failed', 'tls:skipped', 'auth:skipped']],
    ['connection_closed', 'tcp', ['dns:ok', 'tcp:failed', 'tls:skipped', 'auth:skipped']],
    ['tls_failed', 'tls', ['dns:ok', 'tcp:ok', 'tls:failed', 'auth:skipped']],
    ['starttls_unsupported', 'tls', ['dns:ok', 'tcp:ok', 'tls:failed', 'auth:skipped']],
    ['insecure_not_allowed', 'tls', ['dns:ok', 'tcp:ok', 'tls:failed', 'auth:skipped']],
    ['auth_failed', 'auth', ['dns:ok', 'tcp:ok', 'tls:ok', 'auth:failed']],
    ['auth_unsupported', 'auth', ['dns:ok', 'tcp:ok', 'tls:ok', 'auth:failed']],
    ['auth_over_plain', 'auth', ['dns:ok', 'tcp:ok', 'tls:ok', 'auth:failed']],
    ['credential_missing', 'auth', ['dns:ok', 'tcp:ok', 'tls:ok', 'auth:failed']],
  ])('%s -> Schritt %s', (code, failed, expected) => {
    const o = deriveCheck('smtp', { ok: false, code });
    expect(o.failedStep).toBe(failed);
    expect(status(o)).toEqual(expected);
    expect(o.known).toBe(true);
  });
  it('connection_invalid ist ein Konfigurationsfehler ohne fehlgeschlagenen Schritt', () => {
    const o = deriveCheck('smtp', { ok: false, code: 'connection_invalid' });
    expect(o.failedStep).toBeNull();
    expect(o.known).toBe(true);
    expect(o.steps.every((s) => s.status === 'skipped')).toBe(true);
  });
  it('unbekannter Code erfindet keine Schritte', () => {
    const o = deriveCheck('smtp', { ok: false, code: 'weird_thing' });
    expect(o).toMatchObject({ ok: false, steps: [], code: 'weird_thing', known: false });
    expect(deriveCheck('smtp', { ok: false, code: 'constructor' }).known).toBe(false);
    expect(deriveCheck('smtp', { ok: false }).code).toBe('?');
  });
  it('übernimmt das Merkmal vorübergehend', () => {
    expect(deriveCheck('smtp', { ok: false, code: 'timeout', transient: true }).transient).toBe(
      true,
    );
  });
});

describe('deriveCheck Mail-Proxy', () => {
  it('ok: drei Schritte', () => {
    expect(status(deriveCheck('mail-proxy', { ok: true }))).toEqual([
      'dns:ok',
      'reach:ok',
      'auth:ok',
    ]);
  });
  it.each([
    ['proxy_url_invalid', null],
    ['proxy_missing_parameters', null],
    ['connection_invalid', null],
    ['target_blocked', 'dns'],
    ['unresolvable', 'dns'],
    ['proxy_unreachable', 'reach'],
    ['proxy_auth_failed', 'auth'],
    ['credential_missing', 'auth'],
  ])('%s -> %s', (code, failed) => {
    const o = deriveCheck('mail-proxy', { ok: false, code });
    expect(o.failedStep).toBe(failed);
    expect(o.known).toBe(true);
    expect(o.steps).toHaveLength(3);
  });
  it('SMTP-Codes sind für den Proxy unbekannt', () => {
    expect(deriveCheck('mail-proxy', { ok: false, code: 'tls_failed' }).known).toBe(false);
  });
});

describe('deriveCheck Speicher', () => {
  it('liefert keine Schrittliste', () => {
    expect(deriveCheck('s3', { ok: true }).steps).toEqual([]);
    const o = deriveCheck('sftp', { ok: false, code: 'credential_missing' });
    expect(o).toMatchObject({ ok: false, steps: [], known: true });
    expect(deriveCheck('s3', { ok: false, code: 'x' }).known).toBe(false);
  });
});

describe('Texte und Format', () => {
  it('jeder bekannte Code hat Meldung und Rat', () => {
    for (const code of KNOWN_CODES) {
      const c =
        t.admin.connections.check.codes[code as keyof typeof t.admin.connections.check.codes];
      expect(c?.message, code).toBeTruthy();
      expect(c?.advice, code).toBeTruthy();
    }
  });
  it('formatiert Dauern', () => {
    expect(formatDuration(412.4)).toBe('412 ms');
    expect(formatDuration(1234)).toBe('1,2 s');
  });
});
