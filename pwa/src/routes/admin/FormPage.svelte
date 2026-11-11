<script lang="ts">
  import { formStatus } from '$lib/admin/formStatus';
  import WebhooksPanel from './WebhooksPanel.svelte';
  import AccessStatus from './AccessStatus.svelte';
  import { onMount, tick } from 'svelte';
  import { t } from '$lib/i18n';
  import { confirmDiscard } from '$lib/confirm.svelte';
  import { adminApi } from '$lib/api';
  import type { Statistics } from '$lib/api/admin';
  import { session } from '$lib/session.svelte';
  import { createEditor } from '$lib/draft/editor.svelte';
  import { router } from '$lib/router.svelte';
  import { formPath, TABS, type Tab } from '$lib/routes';
  import { describeError } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import PageTabs, { type PageTab } from '$lib/components/admin/PageTabs.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import { formContext } from '$lib/formContext.svelte';
  import AbusePanel from './AbusePanel.svelte';
  import FieldsTab from './FieldsTab.svelte';
  import MailTab from './MailTab.svelte';
  import PublishTab from './PublishTab.svelte';
  import EntriesTab from './EntriesTab.svelte';
  import KeysTab from './KeysTab.svelte';
  import RetentionPanel from './RetentionPanel.svelte';
  import StatisticsChart from './StatisticsChart.svelte';
  import StatisticsKpis from './StatisticsKpis.svelte';
  import ActiveSwitch from './ActiveSwitch.svelte';
  import AdsStatisticsPanel from './AdsStatisticsPanel.svelte';

  let { tenant, form, tab }: { tenant: string; form: string; tab: Tab } = $props();
  // svelte-ignore state_referenced_locally
  const editor = createEditor(adminApi, tenant, form);
  const rights = $derived(session.tenants.find((x) => x.id === tenant)?.permissions ?? []);
  const canEdit = $derived(rights.includes('draft.write'));
  const canPublish = $derived(rights.includes('release.publish'));
  const canIssue = $derived(rights.includes('key.manage'));
  let fieldsDirty = $state(false);
  let abuseDirty = $state(false);
  let retentionDirty = $state(false);
  const dirty = $derived(fieldsDirty || abuseDirty || retentionDirty);
  let slow = $state(false);
  let statsSlow = $state(false);
  let activePath = router.path;
  $effect(() => {
    activePath = router.path;
  });
  let stats = $state<Statistics | null>(null);
  let statsLoading = $state(false);
  let statsError = $state('');
  let statsDays = $state(14);
  const configuration = $derived(
    tab === 'fields' || tab === 'mail' || tab === 'webhooks' || tab === 'storage',
  );
  const customer = $derived(session.tenants.find((x) => x.id === tenant)?.name ?? '');
  const published = $derived(!!editor.detail?.currentReleaseId);
  const formTabs = $derived<PageTab[]>(
    TABS.map((id) => ({
      id,
      label: t.shell.tabs[id],
      href: formPath(tenant, form, id),
      active: tab === id,
    })),
  );
  // The shell breadcrumb can show the real form name from this shared context.
  $effect(() => {
    formContext.tenant = tenant;
    formContext.form = form;
    formContext.name = editor.detail?.name ?? '';
    return () => {
      formContext.tenant = formContext.form = formContext.name = '';
    };
  });
  // Leaving with unsaved changes asks once, whichever control triggered the navigation.
  function guard(): boolean | Promise<boolean> {
    if (!dirty) return true;
    return confirmDiscard().then((ok) => {
      if (ok) fieldsDirty = abuseDirty = retentionDirty = false;
      return ok;
    });
  }
  function navigate(event: MouseEvent, target: Tab): void {
    if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    const statistics =
      event.currentTarget instanceof HTMLAnchorElement &&
      event.currentTarget.hash === '#statistics';
    router.navigate(formPath(tenant, form, target) + (statistics ? '#statistics' : ''));
    if (statistics) void tick().then(() => document.getElementById('statistics')?.scrollIntoView());
  }
  async function loadStats(): Promise<void> {
    statsLoading = true;
    statsError = '';
    const r = await adminApi.statistics(tenant, form, statsDays);
    statsLoading = false;
    if (r.ok) stats = r.data;
    else if (!handleSessionError(r.error)) statsError = describeError(r.error);
  }
  $effect(() => {
    if (editor.loading) {
      const timer = setTimeout(() => (slow = true), 5000);
      return () => clearTimeout(timer);
    }
    slow = false;
  });
  $effect(() => {
    if (statsLoading) {
      const timer = setTimeout(() => (statsSlow = true), 5000);
      return () => clearTimeout(timer);
    }
    statsSlow = false;
  });
  $effect(() => {
    if (tab === 'overview') void loadStats();
  });
  onMount(() => {
    void editor.load();
    const unload = (event: BeforeUnloadEvent) => {
      if (dirty) event.preventDefault();
    };
    const back = () => {
      if (!dirty) return;
      const target = location.pathname + location.search;
      router.navigate(activePath, true);
      void confirmDiscard().then((ok) => {
        if (!ok) return;
        fieldsDirty = abuseDirty = retentionDirty = false;
        router.navigate(target);
      });
    };
    const release = router.setGuard(guard);
    window.addEventListener('beforeunload', unload);
    window.addEventListener('popstate', back);
    return () => {
      release();
      window.removeEventListener('beforeunload', unload);
      window.removeEventListener('popstate', back);
    };
  });
</script>

{#snippet checkItem(done: boolean | null, label: string, target?: Tab)}
  <li class="flex min-h-11 items-center gap-3">
    <span
      aria-hidden="true"
      class={`flex size-6 shrink-0 items-center justify-center rounded-full ${done ? 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-400' : done === false ? 'bg-muted text-muted-foreground' : 'bg-blue-500/10 text-blue-700 dark:text-blue-400'}`}
      ><NavIcon name={done ? 'check' : done === false ? 'x' : 'info'} size={13} /></span
    >
    {#if target && !done}
      <a
        class="min-w-0 flex-1 underline-offset-4 hover:underline"
        href={formPath(tenant, form, target)}
        onclick={(e) => navigate(e, target)}>{label}</a
      >
    {:else}
      <span class="min-w-0 flex-1">{label}</span>
    {/if}
    <span class="text-muted-foreground shrink-0 text-sm"
      >{done ? t.formUi.stateDone : done === false ? t.formUi.stateOpen : t.formUi.stateCheck}</span
    >
  </li>
{/snippet}

<section class="flex min-w-0 flex-col gap-5">
  <PageHeader title={editor.detail?.name ?? t.formWork.title} description={customer}>
    {#snippet badges()}
      {#if editor.detail}
        {@const st = formStatus(published, editor.detail.active)}
        <StatusChip tone={st.tone} label={st.label} />
        {#if published}
          <StatusChip
            tone="idle"
            label={t.lists.version.replace(
              '{n}',
              String(editor.detail.currentReleaseVersion ?? '—'),
            )}
          />
        {/if}
        <StatusChip
          class="max-sm:hidden"
          tone="idle"
          label={editor.draft
            ? t.formWork.saved.replace('{n}', String(editor.draft.revision))
            : t.formUi.noDraftChip}
        />
      {/if}
    {/snippet}
    {#snippet actions()}
      {#if canEdit}<Button
          variant="outline"
          class="max-sm:h-9 max-sm:flex-1 max-sm:px-2"
          aria-label={t.formWork.edit}
          href={formPath(tenant, form, 'fields')}
          onclick={(e) => navigate(e, 'fields')}
          ><span class="sm:hidden" aria-hidden="true">{t.formWork.editShort}</span><span
            class="max-sm:hidden">{t.formWork.edit}</span
          ></Button
        >{/if}
      {#if canPublish && tab !== 'publish'}<Button
          class="max-sm:h-9 max-sm:flex-1 max-sm:px-2"
          aria-label={t.formWork.publish}
          href={formPath(tenant, form, 'publish')}
          onclick={(e) => navigate(e, 'publish')}
          ><span class="sm:hidden" aria-hidden="true">{t.formWork.publishShort}</span><span
            class="max-sm:hidden">{t.formWork.publish}</span
          ></Button
        >{/if}
    {/snippet}
    {#snippet tabs()}
      <PageTabs label={t.admin.form.tabsLabel} tabs={formTabs} />
    {/snippet}
  </PageHeader>
  <AccessStatus showLocked={tab === 'entries'} />
  {#if editor.loading}
    <div aria-busy="true" class="flex min-h-64 flex-col gap-4">
      <p role="status" class="text-muted-foreground text-sm">
        {slow ? t.formWork.slow : t.admin.loading}
      </p>
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        {#each [0, 1, 2, 3] as n (n)}<Skeleton class="h-24 rounded-xl" />{/each}
      </div>
      <Skeleton class="h-48 rounded-xl" />
    </div>
  {:else if !editor.detail}
    <Banner tone="danger">
      {editor.error?.status === 403
        ? t.formWork.denied
        : editor.error?.status === 404
          ? t.formWork.unavailable
          : t.formWork.loadError}
      {#snippet action()}
        <Button variant="outline" onclick={() => void editor.load()}>{t.admin.retry}</Button>
      {/snippet}
    </Banner>
  {:else}
    {#if editor.error && !editor.draft}
      <Banner tone="danger">
        {describeError(editor.error)}
        {#snippet action()}
          <Button variant="outline" onclick={() => void editor.load()}>{t.admin.retry}</Button>
        {/snippet}
      </Banner>
    {/if}
    {#if tab === 'overview'}
      {#if !published}
        <Banner tone="info">{t.formWork.unpublished}</Banner>
      {/if}
      {#if stats && !statsError}
        <StatisticsKpis
          {stats}
          days={statsDays}
          onperiod={(n) => {
            statsDays = n;
            void loadStats();
          }}
        />
      {/if}
      <div class="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-5 lg:grid-cols-[minmax(0,1fr)_21rem]">
        <div
          id="statistics"
          class="flex min-w-0 scroll-mt-20 flex-col gap-5 max-lg:order-2"
          aria-busy={statsLoading}
        >
          {#if statsLoading && !stats}
            <p role="status" class="text-muted-foreground text-sm">
              {statsSlow ? t.formWork.slow : t.admin.loading}
            </p>
            <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
              {#each [0, 1, 2] as n (n)}<Skeleton class="h-24 rounded-xl" />{/each}
            </div>
            <Skeleton class="h-48 rounded-xl" />
          {:else if statsError}
            <Banner tone="danger">
              {statsError}
              {#snippet action()}
                <Button variant="outline" onclick={() => void loadStats()}>{t.admin.retry}</Button>
              {/snippet}
            </Banner>
          {:else if stats}
            <StatisticsChart {stats} />
            <AdsStatisticsPanel {tenant} {form} />
          {/if}
        </div>
        <div class="flex min-w-0 flex-col gap-5 max-lg:contents" data-testid="form-side">
          <div class="min-w-0 max-lg:order-1">
            <Panel title={t.formUi.setupTitle} description={t.formUi.setupHint}>
              <ul class="divide-border -my-1 divide-y">
                {@render checkItem(
                  published,
                  t.formUi.setupPublished,
                  canPublish ? 'publish' : undefined,
                )}
                {@render checkItem(published && editor.detail.active, t.formUi.setupAccepting)}
                {@render checkItem(
                  !!editor.detail.mailConnectionId,
                  t.formUi.setupMail,
                  canEdit ? 'mail' : undefined,
                )}
                {@render checkItem(null, t.formUi.setupIntegration, 'keys')}
              </ul>
            </Panel>
          </div>
          {#if published && (canPublish || canEdit)}
            <div class="min-w-0 max-lg:order-3">
              <Panel title={t.formUi.actionsTitle} description={t.formUi.actionsHint}>
                <div class="flex flex-col gap-4">
                  {#if canPublish}
                    <ActiveSwitch
                      {tenant}
                      {form}
                      active={editor.detail.active}
                      onchange={() => editor.load()}
                    />
                  {/if}
                  {#if canEdit}
                    <div class="flex flex-col gap-1.5">
                      <div>
                        <Button
                          variant="outline"
                          class="h-auto min-h-10 py-2 text-left whitespace-normal"
                          disabled={editor.saving}
                          onclick={async () => {
                            if (await editor.createDraft())
                              router.navigate(formPath(tenant, form, 'fields'));
                          }}>{t.admin.form.newDraft}</Button
                        >
                      </div>
                      <p class="text-muted-foreground text-sm">
                        {t.admin.form.newDraftHint}
                      </p>
                    </div>
                  {/if}
                </div>
              </Panel>
            </div>
          {/if}
        </div>
      </div>
    {:else if tab === 'entries'}<EntriesTab {tenant} {form} />
    {:else if editor.error && !editor.draft}
      <!-- The failed draft load must never be shown as an empty draft. -->
    {:else if (configuration && !canEdit) || (tab === 'publish' && !canPublish)}
      <Banner tone="danger">{t.formWork.denied}</Banner>
    {:else if tab === 'fields'}
      <FieldsTab {editor} ondirty={(value) => (fieldsDirty = value)} />
      <AbusePanel {editor} {tenant} {form} ondirty={(value) => (abuseDirty = value)} />
    {:else if tab === 'webhooks'}
      <Panel title={t.formWork.webhooks} description={t.webhooks.intro}
        ><WebhooksPanel {tenant} {form} /></Panel
      >
    {:else if tab === 'storage'}
      <RetentionPanel {tenant} {form} ondirty={(value) => (retentionDirty = value)} />
    {:else if tab === 'mail'}
      <MailTab
        {editor}
        {tenant}
        {form}
        canAssign={canPublish}
        ondirty={(value) => (fieldsDirty = value)}
      />
    {:else if tab === 'publish'}<PublishTab {editor} {tenant} {form} canBump={canEdit} />
    {:else}<KeysTab {editor} {tenant} {form} {canIssue} />{/if}
  {/if}
</section>
