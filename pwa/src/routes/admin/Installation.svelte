<script lang="ts">
  import { onMount, tick } from 'svelte';
  import RecoveryStep from '$lib/crypto/RecoveryStep.svelte';
  import { accessAutomation } from '$lib/crypto/automation.svelte';
  import { adminApi, http } from '$lib/api';
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { formPath } from '$lib/routes';
  import { session } from '$lib/session.svelte';
  import { formLists } from '$lib/formLists.svelte';
  import { onboarding } from '$lib/onboarding.svelte';
  import type { Step, StepId } from '$lib/onboarding';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';
  import Row from '$lib/components/admin/Row.svelte';
  import Select from '$lib/components/admin/Select.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import StatusChip, { type Tone } from '$lib/components/admin/StatusChip.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  const ui = t.installationPage;
  const tones: Record<Step['state'], Tone> = {
    done: 'ok',
    open: 'info',
    skipped: 'idle',
    error: 'danger',
  };
  let finished = $state(false);
  let finishing = $state(false);
  let finishMessage = $state('');
  let customerName = $state('');
  let customerBusy = $state(false);
  let customerMessage = $state('');
  let customerOk = $state('');
  let formName = $state('');
  let formTenant = $state('');
  let formBusy = $state(false);
  let formMessage = $state('');

  const steps = $derived(onboarding.steps);
  const progress = $derived(onboarding.progress);
  const skippedCount = $derived(steps.filter((s) => s.state === 'skipped').length);
  const currentId = $derived(progress.current >= 0 ? steps[progress.current]?.id : undefined);
  const tenants = $derived(session.tenants);
  const firstTenant = $derived(tenants[0]?.id ?? '');

  onMount(() => {
    // Coming back from a step page ends that step's context.
    onboarding.setContext(null);
    void onboarding.load().then(async () => {
      await tick();
      document.getElementById(`step-${currentId ?? ''}`)?.scrollIntoView?.({ block: 'nearest' });
    });
  });

  /** Opens a page for a step; the setup bar there leads back. */
  function go(id: StepId, path: string): void {
    onboarding.setContext(id);
    router.navigate(path);
  }
  function link(e: MouseEvent, id: StepId, path: string): void {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    go(id, path);
  }

  async function createCustomer(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    const name = customerName.trim();
    if (customerBusy || !name || !session.me?.systemAdministrator) return;
    customerBusy = true;
    customerMessage = customerOk = '';
    try {
      const r = await adminApi.createTenant(name);
      if (!r.ok) {
        if (needsFreshLogin(r.error)) return void (await reauthenticate('/installation'));
        if (!handleSessionError(r.error)) customerMessage = describeError(r.error);
        return;
      }
      try {
        await accessAutomation.ensureCustomer(r.data.id);
      } catch (error) {
        customerMessage = (error as Error).message;
      }
      await session.refreshTenants();
      customerName = '';
      if (!customerMessage) customerOk = ui.steps.customer.created.replace('{name}', name);
      await onboarding.refreshStep('customer');
    } finally {
      customerBusy = false;
    }
  }

  async function createForm(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    const name = formName.trim();
    const tenant = formTenant || firstTenant;
    if (formBusy || !name || !tenant) return;
    formBusy = true;
    formMessage = '';
    try {
      try {
        await accessAutomation.ensureCustomer(tenant);
      } catch (error) {
        formMessage = (error as Error).message;
        return;
      }
      const r = await adminApi.createForm(tenant, name);
      if (!r.ok) {
        if (!handleSessionError(r.error)) formMessage = describeError(r.error);
        return;
      }
      formLists.invalidate(tenant);
      formName = '';
      // Designing and publishing happen on the form page; the setup bar leads back from there.
      go('form', formPath(tenant, r.data.id, 'publish'));
    } finally {
      formBusy = false;
    }
  }

  async function finish(): Promise<void> {
    if (finishing || !progress.complete) return;
    finishing = true;
    finishMessage = '';
    const r = await http.request<{ revision: string }>('PUT', '/settings', {
      body: { revision: onboarding.revision, values: { 'setup.completed': 'true' } },
    });
    finishing = false;
    if (r.ok) {
      finished = true;
      onboarding.markFinished();
      await tick();
      document.getElementById('page-title')?.focus();
      return;
    }
    if (needsFreshLogin(r.error)) {
      finishMessage = ui.finishFresh;
      return void (await reauthenticate('/installation'));
    }
    if (r.error.kind === 'http' && r.error.status === 409) {
      finishMessage = ui.finishConflict;
      void onboarding.load();
    } else if (!handleSessionError(r.error)) finishMessage = describeError(r.error);
  }
</script>

<section class="flex min-w-0 flex-col gap-5">
  <PageHeader
    title={ui.title}
    description={onboarding.open
      ? ui.intro
      : onboarding.required === null
        ? undefined
        : ui.completeLead}
  />
  {#if !onboarding.failed && (onboarding.required === null || (onboarding.open && !onboarding.ready))}
    <div aria-busy="true" class="flex flex-col gap-3">
      <p role="status" class="text-muted-foreground text-sm">{ui.loading}</p>
      <Skeleton class="h-16 rounded-xl" />
      <Skeleton class="h-40 rounded-xl" />
    </div>
  {:else if onboarding.failed}
    <Banner tone="danger">
      {ui.errLoad}
      {#snippet action()}
        <Button variant="outline" onclick={() => void onboarding.load()}>{ui.retry}</Button>
      {/snippet}
    </Banner>
  {:else if onboarding.open}
    <div
      class="bg-card ring-1 ring-foreground/10 rounded-xl px-5 py-4"
      data-testid="setup-progress"
    >
      <p class="mb-2 text-sm font-medium" aria-live="polite">
        {ui.progress
          .replace('{done}', String(progress.done))
          .replace('{total}', String(progress.total))}{skippedCount > 0
          ? ui.progressSkipped.replace('{n}', String(skippedCount))
          : ''}
      </p>
      <div aria-hidden="true" class="bg-muted h-2 overflow-hidden rounded-full">
        <div
          class="bg-brand h-full rounded-full transition-[width]"
          style:width={`${progress.total ? Math.round((progress.handled / progress.total) * 100) : 0}%`}
        ></div>
      </div>
    </div>
    <ol aria-label={ui.stepsLabel} class="m-0 flex list-none flex-col gap-3 p-0">
      {#each steps as step, index (step.id)}
        {@const text = ui.steps[step.id]}
        {@const current = step.id === currentId}
        <li
          id={`step-${step.id}`}
          data-testid={`step-${step.id}`}
          data-state={step.state}
          aria-current={current ? 'step' : undefined}
          class={`bg-card rounded-xl px-5 py-4 ring-1 ${current ? 'ring-brand ring-2' : 'ring-foreground/10'}`}
        >
          <div class="flex flex-wrap items-start justify-between gap-x-3 gap-y-2">
            <div class="flex min-w-0 items-start gap-3">
              <span
                aria-hidden="true"
                class={`mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full text-sm font-semibold ${step.state === 'done' ? 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-400' : current ? 'bg-primary text-primary-foreground' : 'bg-muted text-muted-foreground'}`}
                >{#if step.state === 'done'}<NavIcon name="check" size={14} />{:else}{index +
                    1}{/if}</span
              >
              <div class="min-w-0">
                <h2 class="mb-0 text-base font-semibold">
                  <span class="sr-only"
                    >{ui.stepOf
                      .replace('{n}', String(index + 1))
                      .replace('{m}', String(steps.length))}:
                  </span>{text.title}
                </h2>
                {#if step.skippable && step.id === 'migration'}
                  <span class="text-muted-foreground text-xs">{ui.optional}</span>
                {/if}
              </div>
            </div>
            <StatusChip tone={tones[step.state]} label={ui.states[step.state]} />
          </div>
          <div class="mt-2 flex flex-col gap-3 pl-10 max-sm:pl-0">
            {#if step.state === 'done'}
              <p class="text-muted-foreground m-0 text-sm">{text.doneNote}</p>
              {#if step.id === 'account'}
                <div>
                  <a
                    class="text-brand-ink text-sm underline underline-offset-4"
                    href="/account"
                    onclick={(e) => link(e, 'account', '/account')}>{ui.steps.account.action}</a
                  >
                </div>
              {:else if step.id === 'mail'}
                <div>
                  <a
                    class="text-brand-ink text-sm underline underline-offset-4"
                    href="/connections"
                    onclick={(e) => link(e, 'mail', '/connections')}>{ui.steps.mail.actionDone}</a
                  >
                </div>
              {:else if step.id === 'addresses'}
                <div>
                  <a
                    class="text-brand-ink text-sm underline underline-offset-4"
                    href="/settings"
                    onclick={(e) => link(e, 'addresses', '/settings')}
                    >{ui.steps.addresses.actionDone}</a
                  >
                </div>
              {:else if step.id === 'migration'}
                <div>
                  <a
                    class="text-brand-ink text-sm underline underline-offset-4"
                    href="/migration"
                    onclick={(e) => link(e, 'migration', '/migration')}
                    >{ui.steps.migration.actionDone}</a
                  >
                </div>
              {/if}
            {:else}
              <p class="m-0 text-sm">{text.purpose}</p>
              {#if step.state === 'error'}
                <Notice message={ui.stepError} />
                <div>
                  <Button variant="outline" onclick={() => void onboarding.refreshStep(step.id)}
                    >{ui.recheck}</Button
                  >
                </div>
              {:else if step.state === 'skipped'}
                <div>
                  <Button variant="outline" onclick={() => onboarding.resume(step.id)}
                    >{ui.resume}</Button
                  >
                </div>
              {:else if step.id === 'recovery'}
                <RecoveryStep oncomplete={() => void onboarding.refreshStep('recovery')} />
              {:else if step.id === 'account'}
                <div>
                  <Button onclick={() => go('account', '/account')}
                    >{ui.steps.account.action}</Button
                  >
                </div>
              {:else if step.id === 'mail'}
                <div>
                  <Button onclick={() => go('mail', '/connections')}>{ui.steps.mail.action}</Button>
                </div>
              {:else if step.id === 'addresses'}
                <div>
                  <Button onclick={() => go('addresses', '/settings')}
                    >{ui.steps.addresses.action}</Button
                  >
                </div>
              {:else if step.id === 'migration'}
                <div>
                  <Button onclick={() => go('migration', '/migration')}
                    >{ui.steps.migration.action}</Button
                  >
                </div>
              {:else if step.id === 'customer'}
                <form class="flex max-w-md flex-col gap-3" onsubmit={(e) => void createCustomer(e)}>
                  <Row id="setup-customer-name" label={ui.steps.customer.nameLabel}
                    ><Input
                      id="setup-customer-name"
                      bind:value={customerName}
                      required
                      maxlength={190}
                      autocomplete="off"
                    /></Row
                  >
                  <Notice message={customerMessage} />
                  <div>
                    <Button
                      type="submit"
                      disabled={customerBusy || !session.me?.systemAdministrator}
                      >{customerBusy
                        ? ui.steps.customer.creating
                        : ui.steps.customer.create}</Button
                    >
                  </div>
                </form>
              {:else if step.id === 'form'}
                {#if step.detail === 'needsCustomer'}
                  <p class="text-muted-foreground m-0 text-sm">{ui.steps.form.needsCustomer}</p>
                {:else}
                  {#if step.detail === 'draftOnly'}
                    <p class="m-0 text-sm font-medium">{ui.steps.form.draftOnly}</p>
                  {/if}
                  {@const target = onboarding.facts.forms?.unpublished}
                  {#if target}
                    <div>
                      <Button
                        onclick={() => go('form', formPath(target.tenant, target.form, 'publish'))}
                        >{ui.steps.form.publish}</Button
                      >
                    </div>
                  {/if}
                  <form class="flex max-w-md flex-col gap-3" onsubmit={(e) => void createForm(e)}>
                    {#if tenants.length > 1}
                      <Row id="setup-form-tenant" label={ui.steps.form.customerLabel}
                        ><Select id="setup-form-tenant" bind:value={formTenant}>
                          {#each tenants as tenant (tenant.id)}
                            <option value={tenant.id}>{tenant.name}</option>
                          {/each}
                        </Select></Row
                      >
                    {/if}
                    <Row id="setup-form-name" label={ui.steps.form.nameLabel}
                      ><Input
                        id="setup-form-name"
                        bind:value={formName}
                        required
                        maxlength={190}
                        autocomplete="off"
                      /></Row
                    >
                    <Notice message={formMessage} />
                    <div>
                      <Button
                        type="submit"
                        variant={target ? 'outline' : 'default'}
                        disabled={formBusy}
                        >{formBusy ? ui.steps.form.creating : ui.steps.form.create}</Button
                      >
                    </div>
                  </form>
                {/if}
              {/if}
              {#if step.skippable && step.state === 'open'}
                <div>
                  <Button variant="ghost" onclick={() => onboarding.skip(step.id)}
                    >{ui.later}</Button
                  >
                </div>
              {/if}
            {/if}
            {#if step.id === 'customer' && customerOk}<Notice message={customerOk} kind="ok" />{/if}
          </div>
        </li>
      {/each}
    </ol>
    <Panel
      title={ui.finishTitle}
      description={progress.complete ? ui.finishBody : ui.finishBlocked}
    >
      <Notice message={finishMessage} />
      <div class="mt-2">
        <Button onclick={() => void finish()} disabled={!progress.complete || finishing}
          >{finishing ? ui.finishing : ui.finish}</Button
        >
      </div>
    </Panel>
  {:else}
    <Panel>
      {#if session.me?.systemAdministrator || finished}
        <div class="flex items-start gap-4">
          <span
            aria-hidden="true"
            class="flex size-12 shrink-0 items-center justify-center rounded-full bg-emerald-500/10 text-emerald-700 dark:text-emerald-400"
            ><NavIcon name="check" size={26} /></span
          >
          <div class="min-w-0">
            <h2 class="m-0 text-xl leading-snug font-semibold tracking-tight">
              {ui.complete.title}
            </h2>
            <p class="text-muted-foreground m-0 mt-0.5 text-sm">{ui.complete.body}</p>
            <p class="m-0 mt-3 text-sm">{ui.complete.openHint}</p>
          </div>
        </div>
      {:else}
        <p class="text-muted-foreground m-0 text-sm">{ui.complete.noRight}</p>
      {/if}
      <div class="mt-4 flex flex-wrap gap-2">
        <Button onclick={() => router.navigate('/overview')}>{ui.complete.overview}</Button>
      </div>
    </Panel>
  {/if}
</section>
