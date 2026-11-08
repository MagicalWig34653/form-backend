<script lang="ts">
  import RecoveryStep from '$lib/crypto/RecoveryStep.svelte';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { onMount } from 'svelte';
  import { http } from '$lib/api';
  import { t } from '$lib/i18n';
  import { setupSteps } from '$lib/setup';
  import { router } from '$lib/router.svelte';
  import { Button } from '$lib/components/ui/button';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  const ui = t.installationPage;
  let step = $state(0);
  let error = $state('');
  let required = $state(false);
  let loading = $state(true);
  let revision = $state('');
  onMount(() => {
    void load();
  });
  async function load() {
    const result = await http.request<{ required: boolean }>('GET', '/setup-state');
    if (result.ok) {
      required = result.data.required;
      if (required) {
        const settings = await http.request<{
          revision: string;
          items: { definition: { key: string }; value: string }[];
        }>('GET', '/settings');
        if (settings.ok) {
          revision = settings.data.revision;
          step = Number(
            settings.data.items.find((i) => i.definition.key === 'setup.step')?.value ?? '0',
          );
        } else error = ui.errSettings;
      }
    } else error = ui.errLoad;
    loading = false;
  }
  async function advance(next = 1) {
    if (next === 2 && (!keyring.unlocked || keyring.recoveryRequired)) return;
    const r = await http.request<{ revision: string }>('PUT', '/settings', {
      body: { revision, values: { 'setup.step': String(next) } },
    });
    if (r.ok) {
      revision = r.data.revision;
      step = next;
    } else error = ui.errSave;
  }
  const link =
    'border-border hover:bg-muted flex min-h-11 items-center justify-between gap-3 border-b px-2 -mx-2 text-sm font-medium last:border-b-0 rounded-md';
</script>

<section class="flex min-w-0 max-w-3xl flex-col gap-5">
  <PageHeader title={ui.title} description={required ? ui.intro : undefined} />
  {#if loading}
    <div aria-busy="true" class="flex flex-col gap-3">
      <p role="status" class="text-muted-foreground text-sm">
        {ui.loading}
      </p>
      <Skeleton class="h-16 rounded-xl" />
      <Skeleton class="h-40 rounded-xl" />
    </div>
  {:else if error}
    <Banner tone="danger">
      {error}
      {#snippet action()}
        <Button variant="outline" onclick={load}>{ui.retry}</Button>
      {/snippet}
    </Banner>
  {:else if required}
    <div class="bg-card ring-1 ring-foreground/10 rounded-xl px-5 py-4">
      <p class="text-muted-foreground mb-3 text-sm">
        {ui.progress.replace('{n}', String(step + 1))}
      </p>
      <ol aria-label={ui.stepsLabel} class="grid gap-2 sm:grid-cols-6 sm:gap-1">
        {#each setupSteps as label, index (label)}
          {@const state = index < step ? 'done' : index === step ? 'current' : 'todo'}
          <li
            aria-current={state === 'current' ? 'step' : undefined}
            class="flex items-center gap-2 sm:flex-col sm:items-start sm:gap-1.5"
          >
            <span
              aria-hidden="true"
              class={`flex size-7 shrink-0 items-center justify-center rounded-full text-sm font-semibold ${state === 'done' ? 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-400' : state === 'current' ? 'bg-primary text-primary-foreground' : 'bg-muted text-muted-foreground'}`}
              >{#if state === 'done'}<NavIcon name="check" size={14} />{:else}{index + 1}{/if}</span
            >
            <span
              class={`text-sm leading-4 ${state === 'current' ? 'font-semibold' : 'text-muted-foreground'}`}
              ><span class="sr-only">{index + 1} </span>{label}</span
            >
          </li>
        {/each}
      </ol>
    </div>
    {#if step === 0}
      <Panel title={ui.accountTitle} description={ui.accountBody}>
        <div class="mt-2"><Button onclick={() => void advance()}>{ui.next}</Button></div>
      </Panel>
    {:else if step === 1}
      <Panel>
        <RecoveryStep oncomplete={() => void advance(2)} />
        <div class="mt-4">
          <Button variant="outline" onclick={() => (step = 0)}>{ui.back}</Button>
        </div>
      </Panel>
    {:else}
      <Banner tone="ok">{ui.recoverySaved}</Banner>
    {/if}
    <Panel title={ui.nextTitle}>
      <nav aria-label={ui.nextTitle} class="flex flex-col">
        <a class={link} href="/connections"
          >{ui.mail}<span aria-hidden="true" class="text-muted-foreground"
            ><NavIcon name="chevron" size={16} /></span
          ></a
        >
        <a class={link} href="/settings"
          >{ui.addresses}<span aria-hidden="true" class="text-muted-foreground"
            ><NavIcon name="chevron" size={16} /></span
          ></a
        >
        <a class={link} href="/migration"
          >{ui.migration}<span aria-hidden="true" class="text-muted-foreground"
            ><NavIcon name="chevron" size={16} /></span
          ></a
        >
      </nav>
    </Panel>
  {:else}
    <Banner tone="info">{ui.done}</Banner>
  {/if}
  <div><Button variant="outline" onclick={() => router.navigate('/t')}>{ui.overview}</Button></div>
</section>
