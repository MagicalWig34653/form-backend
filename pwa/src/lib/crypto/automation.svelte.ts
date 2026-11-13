// SPDX-License-Identifier: AGPL-3.0-only
import { t } from '$lib/i18n';
import { adminApi } from '$lib/api';
import { keyring } from './keyring.svelte';
import { fromBase64Url } from './packageV2';
import { rewrapPackage } from './rewrap';

/** A generation we cannot open and cannot repair on our own (needs the recovery code or the legacy key, i.e. the user). */
class AccessMissing extends Error {
  constructor(readonly confirmation: boolean) {
    super('access');
  }
}

/** The server inventory is the durable queue. CAS makes retries and competing tabs safe. */
class AccessAutomation {
  busy = $state(false);
  message = $state('');
  completed = $state(0);
  private tenants: string[] = [];
  private timer: ReturnType<typeof setInterval> | undefined;
  private generation = 0;
  /** `tenant/kid` of generations whose automatic repair failed for good: not retried (no spam, no dialog) until the next lock. */
  private missing = new Set<string>();

  constructor() {
    keyring.onLock(() => this.missing.clear());
  }

  /** Opens `kid` from the own access if needed; throws AccessMissing when only the user can (recovery code, legacy key). */
  private async ensureGeneration(tenant: string, kid: string): Promise<void> {
    if (keyring.dataKey(kid, false)) return;
    const name = `${tenant}/${kid}`;
    if (this.missing.has(name)) throw new AccessMissing(false);
    const result = await keyring.repairAutomatic(tenant, kid);
    if (result === 'ok') return;
    if (result === 'missing') this.missing.add(name);
    throw new AccessMissing(result === 'reauth');
  }

  start(tenants: string[]): void {
    this.tenants = tenants;
    if (!this.timer) this.timer = setInterval(() => void this.run(), 30_000);
    void this.run();
  }
  stop(): void {
    this.generation++;
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    this.tenants = [];
    this.message = '';
  }
  async ensureCustomer(tenant: string): Promise<void> {
    const response = await adminApi.customerKey(tenant);
    if (response.ok) return;
    if (response.error.status !== 404) throw new Error(t.access.checkFailed);
    if (!keyring.unlocked) {
      // A reload locks the keyring: an account key that exists on the server needs unlocking, not "setup".
      const bundle = await adminApi.keyBundle();
      if (bundle.ok && bundle.data.accountPublicKey && bundle.data.recovery)
        throw new Error(t.access.lockedNeeded);
      throw new Error(t.access.setupNeeded);
    }
    if (keyring.pendingCode || keyring.recoveryRequired) throw new Error(t.access.setupNeeded);
    const created = await keyring.createCustomerKey(tenant);
    if (typeof created === 'string') throw new Error(t.access.setupFailed);
  }
  async run(): Promise<void> {
    if (this.busy || !keyring.unlocked || keyring.pendingCode || keyring.recoveryRequired) return;
    const generation = this.generation;
    this.busy = true;
    this.message = '';
    const operation = keyring.operation();
    try {
      for (const tenant of this.tenants) {
        try {
          operation.check();
          if (generation !== this.generation) return;
          const response = await adminApi.rotation(tenant);
          operation.check();
          if (!response.ok) {
            if ([403, 404].includes(response.error.status ?? 0)) continue;
            throw new Error();
          }
          let { active, retiring } = response.data;
          if (active && !retiring && response.data.requested) {
            await keyring.refreshAccess();
            operation.check();
            await this.ensureGeneration(tenant, active.kid);
            if (!(await keyring.rotateAutomatic(tenant, active.kid))) throw new Error();
            operation.check();
            const refreshed = await adminApi.rotation(tenant);
            operation.check();
            if (!refreshed.ok) throw new Error();
            ({ active, retiring } = refreshed.data);
          }
          if (!active || !retiring) continue;
          if (!keyring.dataKey(active.kid, false) || !keyring.dataKey(retiring.kid, false)) {
            await keyring.refreshAccess();
            operation.check();
          }
          for (const g of [active, retiring]) {
            await this.ensureGeneration(tenant, g.kid);
            operation.check();
          }
          const old = keyring.dataKey(retiring.kid, false);
          const next = keyring.dataKey(active.kid, false);
          if (!old || !next) throw new Error();
          const source = operation.copy(old),
            target = operation.copy(next);
          let after = '';
          do {
            const page = await adminApi.rotationObjects(tenant, retiring.kid, after);
            operation.check();
            if (!page.ok) throw new Error();
            for (const object of page.data.items) {
              const wire = await rewrapPackage(
                object.package,
                source,
                object.held || object.wrapKind === 'sym'
                  ? { wrap: 'sym', secret: target }
                  : { wrap: 'hpke', publicKey: fromBase64Url(active.publicKey), secret: target },
                undefined,
                operation,
              );
              operation.check();
              if (generation !== this.generation) return;
              const saved = await adminApi.rewrapObject(tenant, object.id, {
                expectedRevision: object.revision,
                expectedSha256: object.ciphertext_sha256,
                package: wire,
              });
              operation.check();
              if (!saved.ok) throw new Error();
              this.completed++;
            }
            after = page.data.next ?? '';
          } while (after);
          operation.check();
          if (generation !== this.generation) return;
          const finish = await adminApi.finishRotation(tenant, retiring.kid);
          operation.check();
          if (!finish.ok) throw new Error();
          keyring.forget(retiring.kid);
        } catch (error) {
          operation.check();
          if (generation !== this.generation) return;
          this.message =
            error instanceof AccessMissing
              ? error.confirmation
                ? t.access.needsConfirmation
                : t.access.missingGeneration
              : t.access.retry;
        }
      }
    } catch {
      if (keyring.unlocked && generation === this.generation) this.message = t.access.retry;
    } finally {
      operation.dispose();
      this.busy = false;
    }
  }
}
export const accessAutomation = new AccessAutomation();
