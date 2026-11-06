<script lang="ts">
  import { onMount } from 'svelte';
  import { SvelteURLSearchParams } from 'svelte/reactivity';
  import { http } from '$lib/api';
  import { describeError } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { t } from '$lib/i18n';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Row from '$lib/components/admin/Row.svelte';
  import Select from '$lib/components/admin/Select.svelte';
  import ErrorState from '$lib/components/admin/ErrorState.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Checkbox } from '$lib/components/ui/checkbox';
  type Event = keyof typeof t.ops.events;
  type Operation = keyof typeof t.ops.operations;
  interface Item {
    id: number;
    event: Event;
    operation: Operation;
    priority: number;
    occurredAt: string;
    submission?: string;
    target?: string;
  }
  interface Access {
    alarm?: { outcome: keyof typeof t.ops.outcomes; suppressed: number };
    system: boolean;
    cleanup: boolean;
    forms: { customer: string; id: string; name: string }[];
  }
  let access = $state<Access>();
  let form = $state('');
  let event = $state('');
  let operation = $state('');
  let from = $state('');
  let to = $state('');
  let submission = $state('');
  let alarms = $state(true);
  let items = $state<Item[]>([]);
  let next = $state<number>();
  let busy = $state(false);
  let loaded = $state(false);
  let error = $state('');
  let denied = $state(false);
  let report = $state<Record<string, number>>();
  let applied = '';
  function failure(e: Parameters<typeof describeError>[0]) {
    if (handleSessionError(e)) return;
    denied = e.status === 403;
    error = denied ? t.ops.denied : describeError(e);
  }
  async function initialize() {
    busy = true;
    error = '';
    denied = false;
    const r = await http.request<Access>('GET', '/ops/access');
    if (r.ok) {
      access = r.data;
      form = access.forms[0]?.id ?? '';
    } else failure(r.error);
    busy = false;
    if (form) await load();
  }
  async function load(more = false) {
    if (busy || !form) return;
    busy = true;
    error = '';
    if (!more) {
      items = [];
      loaded = false;
      next = undefined;
      const query = new SvelteURLSearchParams({ form, limit: '50' });
      if (event) query.set('event', event);
      if (operation) query.set('operation', operation);
      if (from) query.set('from', new Date(from + 'Z').toISOString());
      if (to) query.set('to', new Date(to + 'Z').toISOString());
      if (submission) query.set('submission', submission);
      if (alarms) query.set('alarms', '1');
      applied = query.toString();
    }
    const r = await http.request<{ items: Item[]; next?: number }>(
      'GET',
      `/ops?${applied}${more && next ? `&before=${next}` : ''}`,
    );
    if (r.ok) {
      items = more ? [...items, ...r.data.items] : r.data.items;
      next = r.data.next;
      loaded = true;
    } else failure(r.error);
    busy = false;
  }
  async function cleanup() {
    busy = true;
    error = '';
    report = undefined;
    const r = await http.request<{ deleted: Record<string, number> }>('POST', '/ops/cleanup', {
      body: {},
    });
    if (r.ok) report = r.data.deleted;
    else failure(r.error);
    busy = false;
  }
  onMount(() => void initialize());
</script>

<div class="mx-auto flex w-full max-w-[1100px] flex-col gap-6">
  <PageHeader title={t.ops.title} description={t.ops.description}>
    {#snippet badges()}
      {#if access?.alarm}
        <StatusChip
          tone={access.alarm.outcome === 'failed'
            ? 'danger'
            : access.alarm.outcome === 'accepted'
              ? 'ok'
              : access.alarm.outcome === 'claimed'
                ? 'warn'
                : 'idle'}
          label={`${t.ops.alarm}: ${t.ops.outcomes[access.alarm.outcome]}`}
        />
      {/if}
    {/snippet}
  </PageHeader>
  {#if error}
    <ErrorState
      title={denied ? t.states.forbiddenTitle : t.states.errorTitle}
      message={error}
      onretry={() => void initialize()}
      {busy}
    />
  {/if}
  {#if busy && !access}
    <div aria-busy="true" class="surface-card flex flex-col gap-3 p-5">
      <p role="status" class="sr-only">{t.ops.loading}</p>
      <Skeleton class="h-10" /><Skeleton class="h-10" /><Skeleton class="h-32" />
    </div>
  {:else if busy}
    <p role="status" class="sr-only">{t.ops.loading}</p>
  {/if}
  {#if access}
    {#if !access.system && !access.forms.length && !error}
      <EmptyState title={t.ops.denied} icon="ops" />
    {/if}
    <Panel>
      <form
        onsubmit={(e) => {
          e.preventDefault();
          void load();
        }}
        class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3"
        aria-busy={busy}
      >
        <Row id="ops-form" label={t.ops.form}>
          <Select id="ops-form" bind:value={form} disabled={busy}>
            <option value="">{t.ops.choose}</option>
            {#each access.forms as f (f.id)}<option value={f.id}>{f.name}</option>{/each}
          </Select>
        </Row>
        <Row id="ops-event" label={t.ops.event}>
          <Select id="ops-event" bind:value={event} disabled={busy}>
            <option value="">{t.ops.all}</option>
            {#each Object.entries(t.ops.events) as [key, label] (key)}<option value={key}
                >{label}</option
              >{/each}
          </Select>
        </Row>
        <Row id="ops-operation" label={t.ops.operation}>
          <Select id="ops-operation" bind:value={operation} disabled={busy}>
            <option value="">{t.ops.all}</option>
            {#each Object.entries(t.ops.operations) as [key, label] (key)}<option value={key}
                >{label}</option
              >{/each}
          </Select>
        </Row>
        <Row id="ops-from" label={t.ops.from}>
          <Input id="ops-from" type="datetime-local" bind:value={from} disabled={busy} />
        </Row>
        <Row id="ops-to" label={t.ops.to}>
          <Input id="ops-to" type="datetime-local" bind:value={to} disabled={busy} />
        </Row>
        <Row id="ops-submission" label={t.ops.submission}>
          <Input id="ops-submission" bind:value={submission} disabled={busy} />
        </Row>
        <label class="flex min-h-10 items-center gap-2 text-sm">
          <Checkbox bind:checked={alarms} disabled={busy} />{t.ops.alarms}
        </label>
        <div class="flex items-end sm:col-span-1 lg:col-start-3 lg:justify-end">
          <Button type="submit" disabled={busy || !form}>{t.ops.apply}</Button>
        </div>
      </form>
    </Panel>
    <Panel flush>
      <!-- svelte-ignore a11y_no_noninteractive_tabindex (keyboard access to horizontal scrolling) -->
      <div
        class="overflow-x-auto"
        aria-busy={busy}
        role="region"
        aria-label={t.ops.title}
        tabindex="0"
      >
        <table class="w-full min-w-[40rem] text-left text-sm">
          <thead class="bg-surface-sunken text-muted-foreground text-xs"
            ><tr
              >{#each [t.ops.time, t.ops.event, t.ops.operation, t.ops.priority, t.ops.submission, t.ops.target] as heading (heading)}<th
                  scope="col"
                  class="px-4 py-3 font-medium">{heading}</th
                >{/each}</tr
            ></thead
          ><tbody>
            {#each items as item (item.id)}<tr class="border-border-subtle border-t"
                ><td class="px-4 py-3 whitespace-nowrap">{item.occurredAt}</td><td class="px-4 py-3"
                  >{t.ops.events[item.event]}</td
                ><td class="px-4 py-3">{t.ops.operations[item.operation]}</td><td class="px-4 py-3"
                  >{item.priority}</td
                ><td class="px-4 py-3 break-all">{item.submission ?? ''}</td><td
                  class="px-4 py-3 break-all">{item.target ?? ''}</td
                ></tr
              >{/each}
          </tbody>
        </table>
      </div>
      {#if loaded && !items.length}<EmptyState title={t.ops.empty} icon="ops" />{/if}
      {#if next}
        <div class="border-border-subtle border-t px-4 py-3">
          <Button variant="outline" disabled={busy} onclick={() => void load(true)}
            >{t.ops.next}</Button
          >
        </div>
      {/if}
    </Panel>
    {#if access.cleanup}
      <Panel title={t.ops.cleanup} description={t.ops.limit}>
        <Button variant="outline" disabled={busy} onclick={() => void cleanup()}
          >{t.ops.cleanup}</Button
        >
      </Panel>
    {/if}
    {#if report}
      <Banner tone="ok" title={t.ops.report}>
        {#each Object.entries(report) as [key, count] (key)}<p>
            {t.ops.categories[key as keyof typeof t.ops.categories] ?? key}: {count}
          </p>{/each}
      </Banner>
    {/if}
    {#if access.system}<p class="text-muted-foreground text-sm">{t.ops.settings}</p>{/if}
    {#if access.alarm}<p class="text-muted-foreground text-sm">
        {t.ops.alarm}: {t.ops.outcomes[access.alarm.outcome]} · {t.ops.suppressed}: {access.alarm
          .suppressed}
      </p>{/if}
  {/if}
</div>
