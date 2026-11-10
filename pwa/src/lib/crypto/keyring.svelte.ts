// SPDX-License-Identifier: AGPL-3.0-only
// In-memory keyring of this browser tab: the unlocked account key and the customer data keys. Nothing here is persisted
// (no IndexedDB, no storage); a reload or "lock" forgets everything. The server only ever sees public keys and wrapped blobs.
import { adminApi } from '$lib/api';
import {
  fromBase64Url,
  toBase64Url,
  requestPrf,
  LOGIN_PRF_SALT,
  type PrfResult,
} from '$lib/api/webauthn';
import type { ApiResult } from '$lib/api/client';
import type { KeyCandidate } from '$lib/api/admin';
import {
  generateKeyPair,
  generateRecoveryCode,
  grantAccess,
  openAccess,
  openRecovery,
  unwrapAccountKey,
  wrapAccountKey,
  wrapRecovery,
  wrapAccountRecovery,
  openAccountRecovery,
  normalizeRecovery,
} from './keys';
import { prfWasMissing } from './prfSupport';
import { KeyOperation } from './operation';
import { identity, randomBytes, hkdf, bytes } from './packageV2';

export type KeyringIssue =
  | 'unsupported' // no PRF / cancelled
  | 'no-account-key'
  | 'locked'
  | 'no-access'
  | 'mismatch'
  | 'server';

class Keyring {
  unlocked = $state(false);
  /** This session saw a passkey ceremony without PRF output (hint only, never persisted). */
  prfMissing = $state(false);
  /** kid -> private data key (32 bytes) */
  private data = new Map<string, Uint8Array>();
  kids = $state<string[]>([]);
  /** Recovery code of a just created data key: kept until the user confirmed it (survives tab switches, never persisted). */
  pendingCode = $state('');
  private account: Uint8Array | null = null;
  recoveryRequired = $state(false);
  recoveryCode = $state('');
  private recoveryRevision: string | null = null;
  private preparedRecovery: {
    publicKey: string;
    expectedRevision: string | null;
    recovery: { salt: string; iterations: number; iv: string; wrap: string };
  } | null = null;

  /** Prepare only in RAM. Persist after exact confirmation, keeping an old envelope usable until then. */
  async prepareRecovery(): Promise<KeyringIssue | null> {
    const operation = this.operation();
    try {
      const b = await adminApi.keyBundle();
      operation.check();
      if (!b.ok) return 'server';
      this.rpId = b.data.rpId;
      if (!this.account) {
        if (b.data.accountPublicKey) return 'locked';
        const pair = await generateKeyPair();
        operation.track(pair.secret);
        operation.check();
        this.account = pair.secret.slice();
        this.localPublicKey = toBase64Url(pair.publicKey);
      }
      const secret = operation.copy(this.account);
      const code = generateRecoveryCode();
      const r = await wrapAccountRecovery(secret, code);
      operation.check();
      this.preparedRecovery = {
        publicKey: this.localPublicKey,
        expectedRevision: b.data.recovery?.revision ?? null,
        recovery: {
          salt: toBase64Url(r.salt),
          iterations: r.iterations,
          iv: toBase64Url(r.iv),
          wrap: toBase64Url(r.wrap),
        },
      };
      this.recoveryCode = code;
      this.armIdle();
      return null;
    } catch {
      return this.account ? 'server' : 'locked';
    } finally {
      operation.dispose();
    }
  }
  async confirmRecovery(input: string): Promise<KeyringIssue | null> {
    if (
      !this.preparedRecovery ||
      !this.recoveryCode ||
      normalizeRecovery(input) !== normalizeRecovery(this.recoveryCode)
    )
      return 'mismatch';
    const operation = this.operation();
    try {
      const p = this.preparedRecovery;
      const result = await adminApi.saveAccountRecovery(
        p.publicKey,
        p.expectedRevision,
        p.recovery,
      );
      operation.check();
      if (!result.ok) return 'server';
      this.recoveryRevision = result.data.revision;
      this.recoveryRequired = false;
      this.preparedRecovery = null;
      this.recoveryCode = '';
      this.unlocked = true;
      this.prfMissing = false;
      this.armIdle();
      return null;
    } catch {
      return 'locked';
    } finally {
      operation.dispose();
    }
  }
  async recoverAccount(code: string, checkOnly = false): Promise<KeyringIssue | null> {
    const operation = this.operation();
    try {
      const b = await adminApi.keyBundle();
      operation.check();
      if (!b.ok) return 'server';
      if (!b.data.recovery || !b.data.accountPublicKey) return 'no-account-key';
      const r = b.data.recovery;
      const secret = operation.track(
        await openAccountRecovery(
          {
            salt: fromBase64Url(r.salt),
            iterations: r.iterations,
            iv: fromBase64Url(r.iv),
            wrap: fromBase64Url(r.wrap),
          },
          code,
          b.data.accountPublicKey,
        ),
      );
      operation.check();
      if (checkOnly) return null;
      const opened: [string, Uint8Array][] = [];
      for (const a of b.data.access) {
        try {
          opened.push([
            a.kid,
            operation.track(
              await openAccess(fromBase64Url(a.enc), fromBase64Url(a.sealed), secret, a.kid),
            ),
          ]);
        } catch {
          operation.check();
        }
      }
      operation.check();
      this.wipe();
      this.account = secret.slice();
      this.localPublicKey = b.data.accountPublicKey;
      this.rpId = b.data.rpId;
      this.recoveryRevision = r.revision;
      for (const [kid, data] of opened) this.remember(kid, data.slice());
      this.unlocked = true;
      this.prfMissing = false;
      this.armIdle();
      return null;
    } catch {
      return 'mismatch';
    } finally {
      operation.dispose();
    }
  }
  /** Internal recovery for newly created generations, derived from the recoverable account secret. */
  private async customerRecoveryCode(): Promise<string> {
    if (!this.account) throw new Error('locked');
    const operation = this.operation();
    try {
      const secret = operation.copy(this.account);
      const value = operation.track(
        await hkdf(secret, bytes('kubus-customer-recovery-v1'), bytes('recovery'), 32),
      );
      operation.check();
      return [...value].map((b) => b.toString(16).padStart(2, '0')).join('');
    } finally {
      operation.dispose();
    }
  }
  async refreshAccess(): Promise<void> {
    if (!this.account) return;
    const operation = this.operation();
    const account = operation.copy(this.account);
    try {
      const b = await adminApi.keyBundle();
      operation.check();
      if (!b.ok || b.data.accountPublicKey !== this.localPublicKey) throw new Error('access');
      for (const a of b.data.access) {
        if (this.data.has(a.kid)) continue;
        try {
          const data = operation.track(
            await openAccess(fromBase64Url(a.enc), fromBase64Url(a.sealed), account, a.kid),
          );
          operation.check();
          this.remember(a.kid, data.slice());
        } catch {
          operation.check();
        }
      }
    } finally {
      operation.dispose();
    }
  }
  async repairAutomatic(tenant: string, kid: string): Promise<boolean> {
    if (this.data.has(kid)) return true;
    if (!this.owner || !this.account) return false;
    const result = await this.recover(tenant, await this.customerRecoveryCode(), kid, false);
    if (result) return false;
    return (await this.repairOwnAccess(tenant, this.owner, kid, false)) === null;
  }
  async rotateAutomatic(tenant: string, kid: string): Promise<boolean> {
    if (!this.owner || !this.recoveryRevision) return false;
    const candidates = await adminApi.keyCandidates(tenant);
    if (!candidates.ok) return false;
    return (
      (await this.beginRotation(
        tenant,
        this.owner,
        kid,
        candidates.data.items.filter((c) => c.hasAccess),
        true,
      )) === null
    );
  }
  private rpId = '';
  /** Public key of the account key as derived HERE from the unlocked private key (never taken from the server). */
  localPublicKey = $state('');
  /** Bumped by every lock(): an operation that started before cannot change state or keep secrets afterwards (review H2). */
  private epoch = 0;
  private owner: string | null = null;
  private sessionToken: string | null = null;

  /** The CSRF token identifies the cookie session locally; never persist or broadcast it. */
  bind(accountId: string | null, sessionToken: string | null): boolean {
    const changed = this.owner !== accountId || this.sessionToken !== sessionToken;
    if (changed) this.lock();
    this.owner = accountId;
    this.sessionToken = sessionToken;
    return changed;
  }
  private lastUse = Date.now();
  private idleTimer: ReturnType<typeof setInterval> | undefined;
  static readonly IDLE_MS = 600_000; // schluessel.md: lock after 10 minutes without use (review M5)

  private touch(): void {
    this.lastUse = Date.now();
  }

  private armIdle(): void {
    this.touch();
    if (this.idleTimer) clearInterval(this.idleTimer);
    this.idleTimer = setInterval(() => {
      if (Date.now() - this.lastUse >= Keyring.IDLE_MS) this.lock();
    }, 5_000);
  }

  dataKey(kid: string, activity = true): Uint8Array | undefined {
    if (activity) this.touch();
    return this.data.get(kid);
  }

  private operations = new Set<KeyOperation>();
  operation(): KeyOperation {
    const epoch = this.epoch;
    const operation = new KeyOperation(
      () => epoch === this.epoch,
      () => this.operations.delete(operation),
    );
    this.operations.add(operation);
    return operation;
  }

  private lockListeners = new Set<() => void>();
  onLock(listener: () => void): () => void {
    this.lockListeners.add(listener);
    return () => this.lockListeners.delete(listener);
  }

  lock(): void {
    this.epoch++;
    for (const listener of this.lockListeners) listener();
    for (const operation of this.operations) operation.dispose();
    if (this.idleTimer) clearInterval(this.idleTimer);
    this.idleTimer = undefined;
    this.wipe();
  }

  private wipe(): void {
    this.localPublicKey = '';
    this.account?.fill(0);
    this.account = null;
    for (const k of this.data.values()) k.fill(0);
    this.data.clear();
    this.kids = [];
    this.pendingCode = '';
    this.recoveryCode = '';
    this.preparedRecovery = null;
    this.recoveryRevision = null;
    this.recoveryRequired = false;
    this.unlocked = false;
  }

  private remember(kid: string, secret: Uint8Array): void {
    this.data.get(kid)?.fill(0); // an older buffer for the same kid is wiped, not just dropped
    this.data.set(kid, secret);
    this.kids = [...this.data.keys()];
  }

  /** Adds a data key obtained elsewhere (recovery code or pasted); verified against its kid by the caller. */
  adopt(kid: string, secret: Uint8Array): void {
    this.remember(kid, secret);
    if (!this.idleTimer) this.armIdle();
  }

  /** Login PRF material is consumed locally, only after the full server login succeeded. */
  async afterLogin(prf?: PrfResult): Promise<KeyringIssue | null> {
    const epoch = this.epoch;
    if (this.unlocked) {
      prf?.output.fill(0);
      return null;
    }
    try {
      const bundle = await adminApi.keyBundle();
      if (epoch !== this.epoch) return 'locked';
      if (!bundle.ok) return 'server';
      this.recoveryRequired = !bundle.data.recovery;
      this.recoveryRevision = bundle.data.recovery?.revision ?? null;
      return bundle.data.accountPublicKey
        ? await this.unlock(prf)
        : await this.setupAccountKey(prf);
    } finally {
      prf?.output.fill(0);
    }
  }

  forget(kid: string): void {
    this.data.get(kid)?.fill(0);
    this.data.delete(kid);
    this.kids = [...this.data.keys()];
  }

  /** First setup: new account key wrapped under the passkey the user picks now. */
  async setupAccountKey(loginPrf?: PrfResult): Promise<KeyringIssue | null> {
    const e = this.epoch;
    const b = await adminApi.keyBundle();
    if (!b.ok) return 'server';
    if (b.data.accountPublicKey) return 'mismatch';
    const salt = loginPrf ? LOGIN_PRF_SALT : randomBytes(32);
    const prf = loginPrf ?? (await requestPrf(b.data.rpId, { salt }));
    if (!prf) {
      if (prfWasMissing()) this.prfMissing = true;
      return 'unsupported';
    }
    const pair = await generateKeyPair();
    const w = await wrapAccountKey(pair.secret, prf.output, prf.credentialId);
    prf.output.fill(0);
    if (e !== this.epoch) {
      pair.secret.fill(0);
      return 'locked';
    }
    const r = await adminApi.putAccountKey(toBase64Url(pair.publicKey), {
      credentialId: toBase64Url(prf.credentialId),
      prfSalt: toBase64Url(salt),
      iv: toBase64Url(w.iv),
      wrap: toBase64Url(w.wrap),
    });
    if (!r.ok || e !== this.epoch) {
      pair.secret.fill(0);
      return r.ok ? 'locked' : 'server';
    }
    this.account = pair.secret;
    this.localPublicKey = toBase64Url(pair.publicKey);
    this.rpId = b.data.rpId;
    this.unlocked = true;
    this.prfMissing = false;
    this.armIdle();
    return null;
  }

  /** Adds the passkey the user picks now as another way to unlock the (already unlocked) account key. */
  async addPasskey(): Promise<KeyringIssue | null> {
    const account = this.account;
    if (!account) return 'locked';
    const e = this.epoch;
    this.touch();
    const salt = randomBytes(32);
    const prf = await requestPrf(this.rpId, { salt });
    if (!prf) {
      if (prfWasMissing()) this.prfMissing = true;
      return 'unsupported';
    }
    if (e !== this.epoch) {
      prf.output.fill(0);
      return 'locked';
    }
    const w = await wrapAccountKey(account, prf.output, prf.credentialId);
    prf.output.fill(0);
    if (e !== this.epoch) return 'locked';
    const r = await adminApi.addAccountWrap({
      credentialId: toBase64Url(prf.credentialId),
      prfSalt: toBase64Url(salt),
      iv: toBase64Url(w.iv),
      wrap: toBase64Url(w.wrap),
    });
    return r.ok ? null : 'server';
  }

  /** Unlocks the account key with a passkey (PRF) and opens every data access the server lists. */
  async unlock(loginPrf?: PrfResult): Promise<KeyringIssue | null> {
    const e = this.epoch;
    const b = await adminApi.keyBundle();
    if (!b.ok) return 'server';
    if (!b.data.accountPublicKey || b.data.wraps.length === 0) return 'no-account-key';
    this.rpId = b.data.rpId;
    const wraps = b.data.wraps.map((w) => ({
      raw: w,
      credentialId: fromBase64Url(w.credentialId),
      salt: fromBase64Url(w.prfSalt),
    }));
    const compatible =
      loginPrf &&
      wraps.some(
        (w) =>
          toBase64Url(w.credentialId) === toBase64Url(loginPrf.credentialId) &&
          toBase64Url(w.salt) === toBase64Url(LOGIN_PRF_SALT),
      );
    if (loginPrf && !compatible) loginPrf.output.fill(0);
    const prf = compatible
      ? loginPrf!
      : await requestPrf(b.data.rpId, {
          byCredential: wraps.map((w) => ({ credentialId: w.credentialId, salt: w.salt })),
        });
    if (!prf) {
      if (prfWasMissing()) this.prfMissing = true;
      return 'unsupported';
    }
    const used = wraps.find((w) => toBase64Url(w.credentialId) === toBase64Url(prf.credentialId));
    if (!used) return 'mismatch';
    let account: Uint8Array;
    try {
      account = await unwrapAccountKey(
        { iv: fromBase64Url(used.raw.iv), wrap: fromBase64Url(used.raw.wrap) },
        prf.output,
        prf.credentialId,
      );
    } catch {
      return 'mismatch';
    } finally {
      prf.output.fill(0);
    }
    // the unwrapped key must match the public key the server holds
    const pub = (await identity(account)).publicKey;
    if (toBase64Url(pub) !== b.data.accountPublicKey || e !== this.epoch) {
      account.fill(0);
      return e !== this.epoch ? 'locked' : 'mismatch';
    }
    this.wipe();
    this.recoveryRequired = !b.data.recovery;
    this.recoveryRevision = b.data.recovery?.revision ?? null;
    this.account = account;
    this.localPublicKey = toBase64Url(pub);
    const opened: [string, Uint8Array][] = [];
    for (const a of b.data.access) {
      try {
        opened.push([
          a.kid,
          await openAccess(fromBase64Url(a.enc), fromBase64Url(a.sealed), account, a.kid),
        ]);
      } catch {
        /* an access that does not open is skipped, never trusted */
      }
    }
    if (e !== this.epoch) {
      for (const [, k] of opened) k.fill(0);
      account.fill(0);
      this.account = null;
      this.localPublicKey = '';
      return 'locked';
    }
    for (const [kid, k] of opened) this.remember(kid, k);
    this.unlocked = true;
    this.prfMissing = false;
    this.armIdle();
    return null;
  }

  private creatingCustomer = false;

  /** Generates the customer's data key in this browser, grants it to the own account, stores a recovery wrap. Returns the one-time recovery code. */
  async createCustomerKey(tenant: string): Promise<{ code: string; kid: string } | KeyringIssue> {
    const account = this.account;
    if (!account) return 'locked';
    if (this.pendingCode || this.creatingCustomer) return 'locked';
    this.creatingCustomer = true;
    const operation = this.operation();
    const stableAccount = operation.copy(account);
    this.touch();
    let data: Awaited<ReturnType<typeof generateKeyPair>> | undefined;
    let retained = false;
    try {
      data = await generateKeyPair();
      operation.track(data.secret);
      const accountPub = (await identity(stableAccount)).publicKey;
      const access = await grantAccess(data.secret, accountPub, data.kid);
      const code = this.recoveryRevision
        ? await this.customerRecoveryCode()
        : generateRecoveryCode();
      const rec = await wrapRecovery(data.secret, code, data.kid);
      operation.check();
      const r: ApiResult<unknown> = await adminApi.setCustomerKeyWithAccess(tenant, {
        publicKey: toBase64Url(data.publicKey),
        access: { enc: toBase64Url(access.enc), sealed: toBase64Url(access.sealed) },
        recovery: {
          salt: toBase64Url(rec.salt),
          iterations: rec.iterations,
          iv: toBase64Url(rec.iv),
          wrap: toBase64Url(rec.wrap),
        },
      });
      operation.check();
      if (!r.ok) return 'server';
      this.remember(data.kid, data.secret.slice());
      retained = true;
      if (!this.recoveryRevision) this.pendingCode = code;
      return { code: this.recoveryRevision ? '' : code, kid: data.kid };
    } catch {
      return this.unlocked ? 'server' : 'locked';
    } finally {
      operation.dispose();
      if (!retained) data?.secret.fill(0);
      this.creatingCustomer = false;
    }
  }

  /** Begins rotation with only explicit access recipients; private keys never leave this tab. */
  async beginRotation(
    tenant: string,
    accountId: string,
    oldKid: string,
    recipients: KeyCandidate[],
    automatic = false,
  ): Promise<KeyringIssue | null> {
    const account = this.account;
    if (!account || !this.data.has(oldKid)) return 'no-access';
    const operation = this.operation();
    const stableAccount = operation.copy(account);
    if (!automatic) this.touch();
    const data = await generateKeyPair();
    let retained = false;
    try {
      operation.track(data.secret);
      operation.check();
      const ownPublic = (await identity(stableAccount)).publicKey;
      const targets = [
        { accountId, publicKey: toBase64Url(ownPublic) },
        ...recipients.filter((c) => c.accountId !== accountId && c.hasAccess),
      ];
      const access = [];
      for (const target of targets) {
        const a = await grantAccess(data.secret, fromBase64Url(target.publicKey), data.kid);
        access.push({
          accountId: target.accountId,
          expectedPublicKey: target.publicKey,
          enc: toBase64Url(a.enc),
          sealed: toBase64Url(a.sealed),
        });
      }
      const code = automatic ? await this.customerRecoveryCode() : generateRecoveryCode();
      const r = await wrapRecovery(data.secret, code, data.kid);
      operation.check();
      const result = await adminApi.beginRotation(tenant, {
        automatic,
        publicKey: toBase64Url(data.publicKey),
        access,
        recovery: {
          salt: toBase64Url(r.salt),
          iterations: r.iterations,
          iv: toBase64Url(r.iv),
          wrap: toBase64Url(r.wrap),
        },
      });
      if (!result.ok) return 'server';
      operation.check();
      this.remember(data.kid, data.secret.slice());
      retained = true;
      if (!automatic) this.pendingCode = code;
      return null;
    } catch {
      return this.unlocked ? 'server' : 'locked';
    } finally {
      operation.dispose();
      if (!retained) data.secret.fill(0);
    }
  }

  /** Grants an account of the same customer access to the active data key (needs this account's own access). */
  async grant(tenant: string, target: KeyCandidate, kid: string): Promise<KeyringIssue | null> {
    const secret = this.data.get(kid);
    if (!this.account || !secret) return 'no-access';
    const e = this.epoch;
    this.touch();
    const g = await grantAccess(secret, fromBase64Url(target.publicKey), kid);
    if (e !== this.epoch) return 'locked';
    const targetAccount = target.accountId;
    const r = await adminApi.grantKeyAccess(tenant, targetAccount, {
      kid,
      enc: toBase64Url(g.enc),
      sealed: toBase64Url(g.sealed),
    });
    return r.ok ? null : 'server';
  }

  /** After a recovery (own account key lost/replaced): seal the opened data key to the own account key again. */
  async repairOwnAccess(
    tenant: string,
    accountId: string,
    kid: string,
    activity = true,
  ): Promise<KeyringIssue | null> {
    const secret = this.data.get(kid);
    const account = this.account;
    if (!account || !secret) return 'no-access';
    const e = this.epoch;
    if (activity) this.touch();
    const g = await grantAccess(secret, (await identity(account)).publicKey, kid);
    if (e !== this.epoch) return 'locked';
    const r = await adminApi.grantKeyAccess(tenant, accountId, {
      kid,
      enc: toBase64Url(g.enc),
      sealed: toBase64Url(g.sealed),
    });
    return r.ok ? null : 'server';
  }

  /** Opens the data key with the recovery code (fetching the wrap is audited server-side). */
  async recover(
    tenant: string,
    code: string,
    expectedKid: string,
    activity = true,
  ): Promise<KeyringIssue | null> {
    const e = this.epoch;
    if (activity) this.touch();
    const rec = await adminApi.keyRecovery(tenant, expectedKid);
    if (!rec.ok) return 'server';
    if (rec.data.keyId !== expectedKid) return 'mismatch'; // the server must hand out the wrap of the key we expect
    try {
      const secret = await openRecovery(
        {
          salt: fromBase64Url(rec.data.salt),
          iterations: rec.data.iterations,
          iv: fromBase64Url(rec.data.iv),
          wrap: fromBase64Url(rec.data.wrap),
        },
        code,
        rec.data.keyId,
      );
      if (e !== this.epoch) {
        secret.fill(0);
        return 'locked';
      }
      this.remember(rec.data.keyId, secret);
      return null;
    } catch {
      return 'mismatch';
    }
  }
}

export const keyring = new Keyring();
