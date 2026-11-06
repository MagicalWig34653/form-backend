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
  import { formPath, tenantPath, type Tab } from '$lib/routes';
  import { describeError } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
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

<section class="flex min-w-0 flex-col gap-5">
  <AccessStatus />
  <a href={tenantPath(tenant)} class="text-muted-foreground w-fit text-sm underline"
    >← {t.admin.forms.title}</a
  >
  <div class="flex flex-wrap items-start justify-between gap-4">
    <div class="space-y-2">
      <h1 id="page-title" tabindex="-1" class="text-2xl font-semibold">
        {editor.detail?.name ?? t.formWork.title}
      </h1>
      {#if editor.detail}
        <p class="text-muted-foreground text-sm">
          {editor.detail.active ? t.formWork.active : t.formWork.inactive} · {t.admin.form.release}
          {editor.detail.currentReleaseVersion ?? '—'}
        </p>
        <p class="text-muted-foreground text-sm">
          {editor.draft
            ? t.formWork.saved.replace('{n}', String(editor.draft.revision))
            : t.formWork.noDraft}
        </p>
      {/if}
    </div>
    <div class="flex flex-wrap gap-2">
      {#if canEdit}<a
          class="border-border rounded-md border px-4 py-3 text-sm"
          href={formPath(tenant, form, 'fields')}
          onclick={(e) => navigate(e, 'fields')}>{t.formWork.edit}</a
        >{/if}
      {#if canPublish}<a
          class="bg-primary text-primary-foreground rounded-md px-4 py-3 text-sm font-medium"
          href={formPath(tenant, form, 'publish')}
          onclick={(e) => navigate(e, 'publish')}>{t.formWork.publish}</a
        >{/if}
    </div>
  </div>
  <nav aria-label={t.admin.form.tabsLabel} class="border-border flex flex-wrap gap-1 border-b">
    {#each navigation as item (item.target)}
      <a
        href={formPath(tenant, form, item.target)}
        aria-current={tab === item.target || (item.target === 'fields' && configuration)
          ? 'page'
          : undefined}
        onclick={(e) => navigate(e, item.target)}
        class={`border-b-2 px-3 py-3 text-sm font-medium ${tab === item.target || (item.target === 'fields' && configuration) ? 'border-primary text-foreground' : 'text-muted-foreground border-transparent'}`}
        >{item.name}</a
      >
    {/each}
    <a
      href={formPath(tenant, form) + '#statistics'}
      class="text-muted-foreground px-3 py-3 text-sm"
      onclick={(e) => navigate(e, 'overview')}>{t.formWork.statistics}</a
    >
  </nav>
  {#if editor.loading}
    <div aria-busy="true" class="border-border min-h-64 rounded-xl border p-6">
      <p role="status">{slow ? t.formWork.slow : t.admin.loading}</p>
      <div class="bg-muted mt-6 h-32 rounded-md"></div>
    </div>
  {:else if !editor.detail}
    <p role="alert">
      {editor.error?.status === 403
        ? t.formWork.denied
        : editor.error?.status === 404
          ? t.formWork.unavailable
          : t.formWork.loadError}
    </p>
    <div><Button onclick={() => void editor.load()}>{t.admin.retry}</Button></div>
  {:else}
    {#if editor.error && !editor.draft}
      <p role="alert">{describeError(editor.error)}</p>
      <div>
        <Button variant="outline" onclick={() => void editor.load()}>{t.admin.retry}</Button>
      </div>
    {:else if configuration}
      <nav aria-label={t.formWork.configuration} class="flex flex-wrap gap-2">
        {#each ['fields', 'mail'] as target (target)}
          <a
            class="border-border rounded-md border px-3 py-2 text-sm"
            aria-current={!extra && tab === target ? 'page' : undefined}
            href={formPath(tenant, form, target as Tab)}
            onclick={(e) => navigate(e, target as Tab)}
            >{target === 'fields' ? t.formWork.fields : t.formWork.mail}</a
          >
        {/each}
        {#each ['webhooks', 'storage', 'flow'] as target (target)}
          <Button
            variant={extra === target ? 'secondary' : 'ghost'}
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
    <section class="bg-card border-border flex min-w-0 flex-col gap-4 rounded-xl border p-4 sm:p-6">
      {#if extra && configuration}
        <h2 class="text-lg font-medium">{t.formWork[extra as 'webhooks' | 'storage' | 'flow']}</h2>
        {#if extra === 'webhooks'}
          <WebhooksPanel {tenant} {form} />
        {:else}
          <p class="text-muted-foreground max-w-prose text-sm">
            {t.formWork[`${extra}Pending` as 'storagePending' | 'flowPending']}
          </p>
        {/if}
      {:else if tab === 'overview'}
        <h2 class="text-lg font-medium">{t.shell.overview}</h2>
        {#if !editor.detail.currentReleaseId}<p>{t.formWork.unpublished}</p>{/if}
        {#if canPublish && editor.detail.currentReleaseId}
          <ActiveSwitch
            {tenant}
            {form}
            active={editor.detail.active}
            onchange={() => editor.load()}
          />
        {/if}
        {#if canEdit && editor.detail.currentReleaseId}
          <div>
            <Button
              variant="outline"
              disabled={editor.saving}
              onclick={async () => {
                if (await editor.createDraft()) router.navigate(formPath(tenant, form, 'fields'));
              }}>{t.admin.form.newDraft}</Button
            >
          </div>
          <p class="text-muted-foreground text-xs">{t.admin.form.newDraftHint}</p>
        {/if}
        <dl class="grid gap-4 text-sm sm:grid-cols-2">
          <div>
            <dt class="font-medium">{t.formWork.mail}</dt>
            <dd class="text-muted-foreground">
              {editor.detail.mailConnectionId ? t.admin.mail.connection : t.formWork.noRoute}
            </dd>
          </div>
          <div>
            <dt class="font-medium">{t.formWork.integration}</dt>
            <dd>
              <a
                class="underline"
                href={formPath(tenant, form, 'keys')}
                onclick={(e) => navigate(e, 'keys')}>{t.formWork.integrationCheck}</a
              >
            </dd>
          </div>
        </dl>
        <div id="statistics" class="scroll-mt-20" aria-busy={statsLoading}>
          {#if statsLoading}<p role="status" class="min-h-40">
              {statsSlow ? t.formWork.slow : t.admin.loading}
            </p>
          {:else if statsError}<p role="alert">{statsError}</p>
            <Button variant="outline" onclick={() => void loadStats()}>{t.admin.retry}</Button>
          {:else if stats}<StatisticsChart {stats} days={30} /><AdsStatisticsPanel
              {tenant}
              {form}
            />{/if}
        </div>
      {:else if tab === 'entries'}<EntriesTab {tenant} {form} />
      {:else if editor.error && !editor.draft}
        <!-- The failed draft load must never be shown as an empty draft. -->
      {:else if (configuration && !canEdit) || (tab === 'publish' && !canPublish)}
        <p role="alert">{t.formWork.denied}</p>
      {:else if tab === 'fields'}<FieldsTab
          {editor}
          ondirty={(value) => (fieldsDirty = value)}
        /><AbusePanel {editor} {tenant} {form} ondirty={(value) => (abuseDirty = value)} />
      {:else if tab === 'mail'}<MailTab
          {editor}
          {tenant}
          {form}
          canAssign={canPublish}
          ondirty={(value) => (fieldsDirty = value)}
        />
      {:else if tab === 'publish'}<PublishTab {editor} {tenant} {form} canBump={canEdit} />
      {:else}<KeysTab {editor} {tenant} {form} {canIssue} />{/if}
    </section>
  {/if}
</section>
