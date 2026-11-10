<script lang="ts">
  import { onMount } from 'svelte';
  import { SvelteURLSearchParams } from 'svelte/reactivity';
  import { http } from '$lib/api';
  import { describeError } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { confirmAction } from '$lib/confirm.svelte';
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
  import DateField from '$lib/components/admin/DateField.svelte';
  import { NO_VALUE, formatDateTime } from '$lib/format';
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
  let fromInvalid = $state(false);
  let toInvalid = $state(false);
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
      access = { ...r.data, forms: r.data.forms ?? [] };
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
      if (from && !fromInvalid) query.set('from', `${from}T00:00:00Z`);
      if (to && !toInvalid) query.set('to', `${to}T23:59:59Z`);
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
    if (
      !(await confirmAction({
        title: t.ops.cleanupConfirmTitle,
        description: t.ops.cleanupConfirmBody,
        confirmLabel: t.ops.cleanupNow,
        destructive: true,
      }))
    )
      return;
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
  const hasSubmission = $derived(items.some((i) => i.submission));
  const hasTarget = $derived(items.some((i) => i.target));
  const columns = $derived([
    t.ops.time,
    t.ops.event,
    t.ops.operation,
    t.ops.priority,
    ...(hasSubmission ? [t.ops.submission] : []),
    ...(hasTarget ? [t.ops.target] : []),
  ]);
  onMount(() => void initialize());
</script>

<div class="flex w-full min-w-0 flex-col gap-6">
  <PageHeader title={t.ops.title} description={t.ops.description}></PageHeader>
  {#if error}
    <ErrorState
      title={denied ? t.states.forbiddenTitle : t.states.errorTitle}
      message={error}
      onretry={() => void initialize()}
      {busy}
    />
  {/if}
  {#if busy && !access}
    <div
      aria-busy="true"
      class="bg-card ring-1 ring-foreground/10 rounded-xl flex flex-col gap-3 p-5"
    >
      <p role="status" class="sr-only">{t.ops.loading}</p>
      <Skeleton class="h-10" /><Skeleton class="h-10" /><Skeleton class="h-32" />
    </div>
  {:else if busy}
    <p role="status" class="sr-only">{t.ops.loading}</p>
  {/if}
  {#if access}
    {#if !access.forms.length && !error}
      <Panel>
        <EmptyState title={t.ops.noForms} description={t.ops.noFormsHint} icon="ops" />
      </Panel>
    {/if}
    {#if access.alarm}
      {@const alarmTone =
        access.alarm.outcome === 'failed'
          ? 'danger'
          : access.alarm.outcome === 'accepted'
            ? 'ok'
            : access.alarm.outcome === 'claimed'
              ? 'warn'
              : 'idle'}
      <Panel title={t.ops.alarm}>
        <div class="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm">
          <StatusChip
            tone={alarmTone}
            label={t.ops.lastAlarm.replace('{outcome}', t.ops.outcomes[access.alarm.outcome])}
          />
          <span class="text-muted-foreground"
            >{t.ops.suppressed}: <span class="tabular-nums">{access.alarm.suppressed}</span></span
          >
        </div>
        {#if access.system}
          <p class="text-muted-foreground m-0 mt-3 text-sm">
            {t.ops.settingsPrefix}
            <a
              href="/settings"
              class="text-brand-ink underline underline-offset-4"
              onclick={(e) => {
                if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
                e.preventDefault();
                router.navigate('/settings');
              }}>{t.ops.settingsLink}</a
            >
            {t.ops.settingsSuffix}
          </p>
        {/if}
      </Panel>
    {/if}
    {#if access.forms.length}
      <Panel title={t.ops.filter}>
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
          <DateField
            id="ops-from"
            label={t.ops.from}
            bind:value={from}
            bind:invalid={fromInvalid}
            disabled={busy}
          />
          <DateField
            id="ops-to"
            label={t.ops.to}
            bind:value={to}
            bind:invalid={toInvalid}
            disabled={busy}
          />
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
      <Panel title={t.ops.eventsTitle.replace('{n}', String(items.length))} flush>
        {#if items.length}
          <!-- svelte-ignore a11y_no_noninteractive_tabindex (keyboard access to horizontal scrolling) -->
          <div
            class="overflow-x-auto max-sm:hidden"
            aria-busy={busy}
            role="region"
            aria-label={t.ops.title}
            tabindex="0"
          >
            <table class="w-full text-left text-sm">
              <thead class="bg-muted/60 text-muted-foreground text-xs"
                ><tr
                  >{#each columns as heading (heading)}<th scope="col" class="px-4 py-3 font-medium"
                      >{heading}</th
                    >{/each}</tr
                ></thead
              ><tbody>
                {#each items as item (item.id)}<tr class="border-border border-t"
                    ><td class="px-4 py-3 whitespace-nowrap tabular-nums"
                      >{formatDateTime(item.occurredAt, { utc: true })}</td
                    ><td class="px-4 py-3">{t.ops.events[item.event] ?? item.event}</td><td
                      class="px-4 py-3">{t.ops.operations[item.operation] ?? item.operation}</td
                    ><td class="px-4 py-3"
                      ><span
                        class="bg-muted text-muted-foreground inline-flex min-w-6 justify-center rounded-md px-1.5 text-xs leading-6 font-medium tabular-nums"
                        title={t.ops.priority}>{item.priority ?? NO_VALUE}</span
                      ></td
                    >{#if hasSubmission}<td class="px-4 py-3 break-all"
                        >{item.submission || NO_VALUE}</td
                      >{/if}{#if hasTarget}<td class="px-4 py-3 break-all"
                        >{item.target || NO_VALUE}</td
                      >{/if}</tr
                  >{/each}
              </tbody>
            </table>
          </div>
          <ul class="flex flex-col gap-2 p-3 sm:hidden" aria-label={t.ops.title}>
            {#each items as item (item.id)}
              <li class="border-border flex flex-col gap-1.5 rounded-lg border p-3 text-sm">
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <span class="font-medium tabular-nums"
                    >{formatDateTime(item.occurredAt, { utc: true })}</span
                  >
                  <span
                    class="bg-muted text-muted-foreground rounded-md px-1.5 text-xs leading-6 font-medium"
                    >{t.ops.priority} {item.priority ?? NO_VALUE}</span
                  >
                </div>
                <p class="m-0">
                  {t.ops.events[item.event] ?? item.event} · {t.ops.operations[item.operation] ??
                    item.operation}
                </p>
                {#if item.submission}<p class="text-muted-foreground m-0 break-all">
                    {t.ops.submissionShort}: {item.submission}
                  </p>{/if}
                {#if item.target}<p class="text-muted-foreground m-0 break-all">
                    {t.ops.targetShort}: {item.target}
                  </p>{/if}
              </li>
            {/each}
          </ul>
        {/if}
        {#if loaded && !items.length}<EmptyState
            title={t.ops.empty}
            description={t.ops.emptyHint}
            icon="ops"
          />{/if}
        {#if next}
          <div class="border-border border-t px-4 py-3">
            <Button variant="outline" disabled={busy} onclick={() => void load(true)}
              >{t.ops.next}</Button
            >
          </div>
        {/if}
      </Panel>
    {/if}
    {#if access.cleanup}
      <Panel title={t.ops.cleanup} description={t.ops.limit}>
        <Button variant="outline" disabled={busy} onclick={() => void cleanup()}
          >{t.ops.cleanupNow}</Button
        >
      </Panel>
    {/if}
    {#if report}
      <Banner
        tone="ok"
        title={`${t.ops.report}: ${t.ops.removed.replace('{n}', String(Object.values(report).reduce((a, b) => a + b, 0)))}`}
      >
        {#each Object.entries(report) as [key, count] (key)}<p>
            {t.ops.categories[key as keyof typeof t.ops.categories] ?? key}: {count}
          </p>{/each}
      </Banner>
    {/if}
  {/if}
</div>
