// SPDX-License-Identifier: AGPL-3.0-only
import { t } from '$lib/i18n';
import { adminApi } from '$lib/api';
import { keyring } from './keyring.svelte';
import { fromBase64Url } from './packageV2';
import { rewrapPackage } from './rewrap';

/** The server inventory is the durable queue. CAS makes retries and competing tabs safe. */
class AccessAutomation {
  busy = $state(false);
  message = $state('');
  completed = $state(0);
  private tenants: string[] = [];
  private timer: ReturnType<typeof setInterval> | undefined;
  private generation = 0;

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
    if (!keyring.unlocked || keyring.pendingCode || keyring.recoveryRequired)
      throw new Error(t.access.setupNeeded);
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
            if (
              !(await keyring.repairAutomatic(tenant, active.kid)) ||
              !(await keyring.rotateAutomatic(tenant, active.kid))
            )
              throw new Error();
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
            if (!keyring.dataKey(g.kid, false) && !(await keyring.repairAutomatic(tenant, g.kid)))
              throw new Error();
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
        } catch {
          operation.check();
          if (generation !== this.generation) return;
          this.message = t.access.retry;
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
