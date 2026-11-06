<script lang="ts">
  import { onMount } from 'svelte';
  import { SvelteURLSearchParams } from 'svelte/reactivity';
  import { http } from '$lib/api';
  import { describeError } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { t } from '$lib/i18n';
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
  let report = $state<Record<string, number>>();
  let applied = '';
  function failure(e: Parameters<typeof describeError>[0]) {
    if (!handleSessionError(e)) error = e.status === 403 ? t.ops.denied : describeError(e);
  }
  async function initialize() {
    busy = true;
    error = '';
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

<h1 id="page-title" tabindex="-1" class="text-2xl font-semibold">{t.ops.title}</h1>
<p>{t.ops.description}</p>
{#if error}<p role="alert">{error}</p>
  <button onclick={() => void initialize()} disabled={busy}>{t.ops.retry}</button>{/if}
{#if busy}<p role="status">{t.ops.loading}</p>{/if}
{#if access}
  {#if !access.system && !access.forms.length}<p>{t.ops.denied}</p>{/if}
  <form
    onsubmit={(e) => {
      e.preventDefault();
      void load();
    }}
    class="flex flex-wrap gap-4"
    aria-busy={busy}
  >
    <label
      >{t.ops.form}<select bind:value={form} disabled={busy}
        ><option value="">{t.ops.choose}</option>{#each access.forms as f (f.id)}<option
            value={f.id}>{f.name}</option
          >{/each}</select
      ></label
    >
    <label
      >{t.ops.event}<select bind:value={event} disabled={busy}
        ><option value="">{t.ops.all}</option
        >{#each Object.entries(t.ops.events) as [key, label] (key)}<option value={key}
            >{label}</option
          >{/each}</select
      ></label
    >
    <label
      >{t.ops.operation}<select bind:value={operation} disabled={busy}
        ><option value="">{t.ops.all}</option
        >{#each Object.entries(t.ops.operations) as [key, label] (key)}<option value={key}
            >{label}</option
          >{/each}</select
      ></label
    >
    <label>{t.ops.from}<input type="datetime-local" bind:value={from} disabled={busy} /></label>
    <label>{t.ops.to}<input type="datetime-local" bind:value={to} disabled={busy} /></label>
    <label>{t.ops.submission}<input bind:value={submission} disabled={busy} /></label>
    <label><input type="checkbox" bind:checked={alarms} disabled={busy} />{t.ops.alarms}</label>
    <button disabled={busy || !form}>{t.ops.apply}</button>
  </form>
  <div class="overflow-x-auto" aria-busy={busy}>
    <table class="w-full text-left">
      <thead
        ><tr
          >{#each [t.ops.time, t.ops.event, t.ops.operation, t.ops.priority, t.ops.submission, t.ops.target] as heading (heading)}<th
              class="p-3">{heading}</th
            >{/each}</tr
        ></thead
      ><tbody>
        {#each items as item (item.id)}<tr class="border-b"
            ><td class="p-3">{item.occurredAt}</td><td>{t.ops.events[item.event]}</td><td
              >{t.ops.operations[item.operation]}</td
            ><td>{item.priority}</td><td>{item.submission ?? ''}</td><td>{item.target ?? ''}</td
            ></tr
          >{/each}
      </tbody>
    </table>
    {#if loaded && !items.length}<p>{t.ops.empty}</p>{/if}
  </div>
  {#if next}<button disabled={busy} onclick={() => void load(true)}>{t.ops.next}</button>{/if}
  {#if access.cleanup}<p>{t.ops.limit}</p>
    <button disabled={busy} onclick={() => void cleanup()}>{t.ops.cleanup}</button>{/if}
  {#if report}<div role="status">
      <h2>{t.ops.report}</h2>
      {#each Object.entries(report) as [key, count] (key)}<p>
          {t.ops.categories[key as keyof typeof t.ops.categories] ?? key}: {count}
        </p>{/each}
    </div>{/if}
  {#if access.system}<p>{t.ops.settings}</p>{/if}
  {#if access.alarm}<p>
      {t.ops.alarm}: {t.ops.outcomes[access.alarm.outcome]} · {t.ops.suppressed}: {access.alarm
        .suppressed}
    </p>{/if}
{/if}
