<script lang="ts">
  import WebhooksPanel from './WebhooksPanel.svelte';
  import AccessStatus from './AccessStatus.svelte';
  import { onMount, tick } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import type { Statistics } from '$lib/api/admin';
  import { session } from '$lib/session.svelte';
  import { createEditor } from '$lib/draft/editor.svelte';
  import { router } from '$lib/router.svelte';
  import { formPath, type Tab } from '$lib/routes';
  import { describeError } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
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
  import StatisticsChart from './StatisticsChart.svelte';
  import ActiveSwitch from './ActiveSwitch.svelte';
  import AdsStatisticsPanel from './AdsStatisticsPanel.svelte';

  let { tenant, form, tab }: { tenant: string; form: string; tab: Tab } = $props();
  // svelte-ignore state_referenced_locally
  const editor = createEditor(adminApi, tenant, form);
  const rights = $derived(session.tenants.find((x) => x.id === tenant)?.permissions ?? []);
  const canEdit = $derived(rights.includes('draft.write'));
  const canPublish = $derived(rights.includes('release.publish'));
  const canIssue = $derived(rights.includes('key.manage'));
  let extra = $state('');
  let fieldsDirty = $state(false);
  let abuseDirty = $state(false);
  const dirty = $derived(fieldsDirty || abuseDirty);
  let slow = $state(false);
  let statsSlow = $state(false);
  let activePath = router.path;
  $effect(() => {
    activePath = router.path;
  });
  let stats = $state<Statistics | null>(null);
  let statsLoading = $state(false);
  let statsError = $state('');
  const navigation = $derived([
    { name: t.shell.overview, target: 'overview' as Tab },
    { name: t.shell.entries, target: 'entries' as Tab },
    { name: t.formWork.configuration, target: 'fields' as Tab },
    { name: t.formWork.integration, target: 'keys' as Tab },
  ]);
  const configuration = $derived(tab === 'fields' || tab === 'mail');
  const customer = $derived(session.tenants.find((x) => x.id === tenant)?.name ?? '');
  const published = $derived(!!editor.detail?.currentReleaseId);
  const tabActive = (target: Tab): boolean =>
    tab === target || (target === 'fields' && configuration);
  const tabClass = (current: boolean): string =>
    `relative inline-flex min-h-11 items-center px-3.5 font-medium whitespace-nowrap transition-colors after:absolute after:inset-x-2.5 after:bottom-0 after:h-0.5 after:rounded-full ${current ? 'text-foreground after:bg-brand' : 'text-muted-foreground hover:text-foreground after:bg-transparent'}`;
  const linkButton =
    'inline-flex min-h-10 items-center justify-center rounded-md px-4 text-sm font-medium';
  // The shell breadcrumb can show the real form name from this shared context.
  $effect(() => {
    formContext.tenant = tenant;
    formContext.form = form;
    formContext.name = editor.detail?.name ?? '';
    formContext.last = { tenant, form };
    return () => {
      formContext.tenant = formContext.form = formContext.name = '';
    };
  });
  function leave(): boolean {
    return !dirty || confirm(t.formWork.unsaved);
  }
  function navigate(event: MouseEvent, target: Tab): void {
    if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    const statistics =
      event.currentTarget instanceof HTMLAnchorElement &&
      event.currentTarget.hash === '#statistics';
    // The document capture listener has already confirmed navigation.
    fieldsDirty = abuseDirty = false;
    extra = '';
    router.navigate(formPath(tenant, form, target) + (statistics ? '#statistics' : ''));
    if (statistics) void tick().then(() => document.getElementById('statistics')?.scrollIntoView());
  }
  async function loadStats(): Promise<void> {
    statsLoading = true;
    statsError = '';
    const r = await adminApi.statistics(tenant, form, 30);
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
    const click = (event: MouseEvent) => {
      if (
        !(event.target instanceof Element) ||
        !event.target.closest('a[href]') ||
        event.ctrlKey ||
        event.metaKey ||
        event.shiftKey ||
        event.altKey
      )
        return;
      if (!leave()) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    };
    const change = (event: Event) => {
      const select = event.target;
      if (
        !(select instanceof HTMLSelectElement) ||
        select.getAttribute('aria-label') !== t.admin.customer
      )
        return;
      if (!leave()) {
        select.value = tenant;
        event.stopImmediatePropagation();
      }
    };
    const back = () => {
      if (dirty && !leave()) router.navigate(activePath);
      else fieldsDirty = abuseDirty = false;
    };
    window.addEventListener('beforeunload', unload);
    window.addEventListener('popstate', back);
    document.addEventListener('change', change, true);
    document.addEventListener('click', click, true);
    return () => {
      window.removeEventListener('beforeunload', unload);
      window.removeEventListener('popstate', back);
      document.removeEventListener('change', change, true);
      document.removeEventListener('click', click, true);
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
  <AccessStatus />
  <PageHeader title={editor.detail?.name ?? t.formWork.title} description={customer}>
    {#snippet badges()}
      {#if editor.detail}
        {#if !published}
          <StatusChip tone="idle" label={t.formUi.notPublishedChip} />
        {:else}
          <StatusChip
            tone={editor.detail.active ? 'ok' : 'idle'}
            label={editor.detail.active ? t.formWork.active : t.formWork.inactive}
          />
          <StatusChip
            tone="idle"
            label={t.lists.version.replace(
              '{n}',
              String(editor.detail.currentReleaseVersion ?? '—'),
            )}
          />
        {/if}
        <StatusChip
          tone={editor.draft ? 'info' : 'idle'}
          label={editor.draft
            ? t.formWork.saved.replace('{n}', String(editor.draft.revision))
            : t.formUi.noDraftChip}
        />
      {/if}
    {/snippet}
    {#snippet actions()}
      {#if canEdit}<a
          class={`${linkButton} border-border hover:bg-secondary border`}
          href={formPath(tenant, form, 'fields')}
          onclick={(e) => navigate(e, 'fields')}>{t.formWork.edit}</a
        >{/if}
      {#if canPublish}<a
          class={`${linkButton} bg-primary text-primary-foreground hover:opacity-90`}
          href={formPath(tenant, form, 'publish')}
          onclick={(e) => navigate(e, 'publish')}>{t.formWork.publish}</a
        >{/if}
    {/snippet}
  </PageHeader>
  <nav
    aria-label={t.admin.form.tabsLabel}
    class="border-border -mx-4 overflow-x-auto border-b px-4 [scrollbar-width:none] md:mx-0 md:px-0 [&::-webkit-scrollbar]:hidden"
  >
    <div class="flex w-max min-w-full gap-0.5">
      {#each navigation as item (item.target)}
        <a
          href={formPath(tenant, form, item.target)}
          aria-current={tabActive(item.target) ? 'page' : undefined}
          onclick={(e) => navigate(e, item.target)}
          class={tabClass(tabActive(item.target))}>{item.name}</a
        >
      {/each}
      <a
        href={formPath(tenant, form) + '#statistics'}
        class={tabClass(false)}
        onclick={(e) => navigate(e, 'overview')}>{t.formWork.statistics}</a
      >
    </div>
  </nav>
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
    {:else if configuration}
      <nav aria-label={t.formWork.configuration} class="flex flex-wrap items-center gap-2">
        <div class="bg-muted/60 flex gap-1 rounded-lg p-1">
          {#each ['fields', 'mail'] as target (target)}
            <a
              class={`inline-flex min-h-9 items-center px-3 text-sm font-medium ${!extra && tab === target ? 'bg-card ring-1 ring-foreground/10 rounded-xl text-foreground' : 'text-muted-foreground hover:text-foreground'}`}
              aria-current={!extra && tab === target ? 'page' : undefined}
              href={formPath(tenant, form, target as Tab)}
              onclick={(e) => navigate(e, target as Tab)}
              >{target === 'fields' ? t.formWork.fields : t.formWork.mail}</a
            >
          {/each}
        </div>
        {#each ['webhooks', 'storage', 'flow'] as target (target)}
          <Button
            variant={extra === target ? 'secondary' : 'ghost'}
            class="min-h-9"
            onclick={() => {
              if (leave()) {
                fieldsDirty = abuseDirty = false;
                extra = target;
              }
            }}>{t.formWork[target as 'webhooks' | 'storage' | 'flow']}</Button
          >
        {/each}
      </nav>
    {/if}
    {#if extra && configuration}
      <Panel title={t.formWork[extra as 'webhooks' | 'storage' | 'flow']}>
        {#if extra === 'webhooks'}
          <WebhooksPanel {tenant} {form} />
        {:else}
          <p class="text-muted-foreground max-w-prose text-sm">
            {t.formWork[`${extra}Pending` as 'storagePending' | 'flowPending']}
          </p>
        {/if}
      </Panel>
    {:else if tab === 'overview'}
      {#if !published}
        <Banner tone="info">{t.formWork.unpublished}</Banner>
      {/if}
      <div class="grid min-w-0 gap-5 lg:grid-cols-[minmax(0,1fr)_21rem]">
        <div
          id="statistics"
          class="flex min-w-0 scroll-mt-20 flex-col gap-5"
          aria-busy={statsLoading}
        >
          {#if statsLoading}
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
            <StatisticsChart {stats} days={30} />
            <AdsStatisticsPanel {tenant} {form} />
          {/if}
        </div>
        <div class="flex min-w-0 flex-col gap-5">
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
          {#if published && (canPublish || canEdit)}
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
    {:else if tab === 'mail'}
      <Panel>
        <MailTab
          {editor}
          {tenant}
          {form}
          canAssign={canPublish}
          ondirty={(value) => (fieldsDirty = value)}
        />
      </Panel>
    {:else if tab === 'publish'}<PublishTab {editor} {tenant} {form} canBump={canEdit} />
    {:else}<KeysTab {editor} {tenant} {form} {canIssue} />{/if}
  {/if}
</section>
