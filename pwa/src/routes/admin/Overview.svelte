<script lang="ts">
  import { onDestroy, onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { session } from '$lib/session.svelte';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { formLists } from '$lib/formLists.svelte';
  import { OverviewLoader } from '$lib/stats/loader.svelte';
  import { failedForms, scopeForms } from '$lib/stats/scope';
  import { router } from '$lib/router.svelte';
  import { Button } from '$lib/components/ui/button';
  import Banner from '$lib/components/admin/Banner.svelte';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import AccessStatus from './AccessStatus.svelte';
  import KpiTile from './overview/KpiTile.svelte';
  import TenantOverview from './overview/TenantOverview.svelte';

  const loader = new OverviewLoader(adminApi, handleSessionError);
  let ready = $state(false);
  const scope = $derived(scopeForms(session.tenants, formLists.states));
  const broken = $derived(failedForms(scope.forms, loader.snapshots));
  const lead = $derived(
    ready
      ? t.area.scopeCustomers
          .replace('{customers}', String(session.tenants.length))
          .replace('{forms}', String(scope.forms.length))
      : '',
  );
  let run = 0;

  async function reload(force: boolean): Promise<void> {
    const current = ++run;
    ready = false;
    await formLists.ensure(
      session.tenants.map((c) => c.id),
      force,
    );
    if (current !== run) return;
    ready = true;
    const forms = scopeForms(session.tenants, formLists.states).forms;
    void loader.loadMany(
      session.tenants.map((c) => ({ tenant: c.id, forms: forms.filter((f) => f.tenant === c.id) })),
    );
  }

  onMount(() => void reload(false));
  onDestroy(() => {
    run++;
    loader.cancel();
  });
</script>

<section class="flex min-w-0 flex-col gap-4" data-testid="overall-overview">
  <PageHeader title={t.area.pageTitle} description={t.area.pageIntro} />
  <AccessStatus />
  {#if !ready}
    <div class="tile-grid" aria-busy="true">
      {#each [0, 1, 2, 3] as n (n)}<div data-w="3">
          <KpiTile label={t.overview.kpiSubmits} status="loading" index={n} />
        </div>{/each}
    </div>
  {:else}
    {#if scope.failed.length > 0 || broken.length > 0}
      <Banner tone="warn" title={t.area.problems}>
        <ul class="m-0 flex list-none flex-col gap-1 p-0" data-testid="overview-problems">
          {#each scope.failed as c (c.id)}
            <li>{t.area.problemList.replace('{customer}', c.name)}</li>
          {/each}
          {#each broken as f (f.id)}
            <li>{t.area.problemForm.replace('{form}', f.name)}</li>
          {/each}
        </ul>
        {#snippet action()}
          <Button variant="outline" onclick={() => void reload(true)}>{t.area.retry}</Button>
        {/snippet}
      </Banner>
    {/if}
    {#if session.tenants.length === 0}
      <Banner tone="info">
        {t.area.noCustomers}
        {#snippet action()}
          <Button variant="outline" onclick={() => router.navigate('/t')}
            >{t.shell.customers}</Button
          >
        {/snippet}
      </Banner>
    {:else if scope.forms.length === 0}
      {#if scope.failed.length === 0}<p class="text-muted-foreground">{t.area.noForms}</p>{/if}
    {:else}
      <TenantOverview
        forms={scope.forms}
        {loader}
        locked={!keyring.unlocked}
        moreForms={scope.more}
        showSetup={false}
        {lead}
        recentLimit={10}
        onreload={() => void reload(true)}
      />
    {/if}
  {/if}
</section>
