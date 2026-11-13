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
  import ErrorState from '$lib/components/admin/ErrorState.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import DateField from '$lib/components/admin/DateField.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { NO_VALUE, formatDateTime } from '$lib/format';

  type ActorKind = keyof typeof t.audit.actors;
  interface Item {
    id: string;
    occurredAt: string;
    category: string;
    action: string;
    actorId: string | null;
    actorKind: ActorKind;
    customerId: string | null;
    formId: string | null;
    subjectId: string | null;
  }
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const CODE = /^[A-Za-z0-9._:-]{1,100}$/;

  let action = $state('');
  let actor = $state('');
  let from = $state('');
  let to = $state('');
  let fromInvalid = $state(false);
  let toInvalid = $state(false);
  let items = $state<Item[]>([]);
  let next = $state<string>();
  let busy = $state(false);
  let loaded = $state(false);
  let error = $state('');
  let denied = $state(false);
  let applied = '';

  const actionInvalid = $derived(action.trim() !== '' && !CODE.test(action.trim()));
  const actorInvalid = $derived(actor.trim() !== '' && !UUID.test(actor.trim()));
  const blocked = $derived(actionInvalid || actorInvalid || fromInvalid || toInvalid);

  function failure(e: Parameters<typeof describeError>[0]) {
    if (handleSessionError(e)) return;
    denied = e.status === 403;
    error = denied ? t.audit.denied : describeError(e);
  }
  async function load(more = false) {
    if (busy || (!more && blocked)) return;
    busy = true;
    error = '';
    denied = false;
    if (!more) {
      items = [];
      loaded = false;
      next = undefined;
      const query = new SvelteURLSearchParams({ limit: '50' });
      if (action.trim()) query.set('action', action.trim());
      if (actor.trim()) query.set('actor', actor.trim().toLowerCase());
      if (from) query.set('from', `${from}T00:00:00Z`);
      if (to) query.set('to', `${to}T23:59:59Z`);
      applied = query.toString();
    }
    const r = await http.request<{ items: Item[]; nextCursor: string | null }>(
      'GET',
      `/audit?${applied}${more && next ? `&cursor=${encodeURIComponent(next)}` : ''}`,
    );
    if (r.ok) {
      items = more ? [...items, ...r.data.items] : r.data.items;
      next = r.data.nextCursor ?? undefined;
      loaded = true;
    } else failure(r.error);
    busy = false;
  }
  function reset() {
    action = '';
    actor = '';
    from = '';
    to = '';
    void load();
  }
  const short = (id: string | null) => (id ? id.slice(0, 8) : NO_VALUE);
  const scope = (i: Item) =>
    i.customerId
      ? [short(i.customerId), ...(i.formId ? [short(i.formId)] : [])].join(' / ')
      : t.audit.system;
  const actorText = (i: Item) =>
    `${t.audit.actors[i.actorKind] ?? i.actorKind}${i.actorId ? ` ${short(i.actorId)}` : ''}`;
  onMount(() => void load());
</script>

<div class="flex w-full min-w-0 flex-col gap-6">
  <PageHeader title={t.audit.title} description={t.audit.description}></PageHeader>
  {#if error}
    <ErrorState
      title={denied ? t.states.forbiddenTitle : t.states.errorTitle}
      message={error}
      onretry={() => void load()}
      {busy}
    />
  {/if}
  {#if !denied}
    <Panel title={t.audit.filter}>
      <form
        onsubmit={(e) => {
          e.preventDefault();
          void load();
        }}
        class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4"
        aria-busy={busy}
      >
        <Row
          id="audit-action"
          label={t.audit.action}
          hint={t.audit.actionHint}
          error={actionInvalid ? t.audit.invalidAction : undefined}
        >
          <Input id="audit-action" bind:value={action} disabled={busy} autocomplete="off" />
        </Row>
        <Row
          id="audit-actor"
          label={t.audit.actor}
          error={actorInvalid ? t.audit.invalidActor : undefined}
        >
          <Input
            id="audit-actor"
            bind:value={actor}
            disabled={busy}
            autocomplete="off"
            spellcheck={false}
          />
        </Row>
        <DateField
          id="audit-from"
          label={t.audit.from}
          bind:value={from}
          bind:invalid={fromInvalid}
          disabled={busy}
        />
        <DateField
          id="audit-to"
          label={t.audit.to}
          bind:value={to}
          bind:invalid={toInvalid}
          disabled={busy}
        />
        <div class="flex flex-wrap items-end gap-2 sm:col-span-2 lg:col-span-4 lg:justify-end">
          <Button type="button" variant="outline" disabled={busy} onclick={reset}
            >{t.audit.reset}</Button
          >
          <Button type="submit" disabled={busy || blocked}>{t.audit.apply}</Button>
        </div>
      </form>
    </Panel>
    <Panel title={t.audit.entriesTitle.replace('{n}', String(items.length))} flush>
      {#if busy && !loaded}
        <div aria-busy="true" class="flex flex-col gap-3 p-5">
          <p role="status" class="sr-only">{t.audit.loading}</p>
          <Skeleton class="h-10" /><Skeleton class="h-10" /><Skeleton class="h-10" />
        </div>
      {/if}
      {#if items.length}
        <!-- svelte-ignore a11y_no_noninteractive_tabindex (keyboard access to horizontal scrolling) -->
        <div
          class="overflow-x-auto max-sm:hidden"
          aria-busy={busy}
          role="region"
          aria-label={t.audit.title}
          tabindex="0"
        >
          <table class="w-full text-left text-sm">
            <thead class="bg-muted/60 text-muted-foreground text-xs"
              ><tr
                >{#each [t.audit.time, t.audit.actionColumn, t.audit.actorColumn, t.audit.scope, t.audit.subject] as heading (heading)}<th
                    scope="col"
                    class="px-4 py-3 font-medium">{heading}</th
                  >{/each}</tr
              ></thead
            >
            <tbody>
              {#each items as item (item.id)}
                <tr class="border-border border-t">
                  <td class="px-4 py-3 whitespace-nowrap tabular-nums"
                    >{formatDateTime(item.occurredAt, { utc: true })}</td
                  >
                  <td class="px-4 py-3 font-mono text-xs break-all">{item.action}</td>
                  <td class="px-4 py-3" title={item.actorId ?? undefined}>{actorText(item)}</td>
                  <td class="px-4 py-3 font-mono text-xs" title={item.customerId ?? undefined}
                    >{scope(item)}</td
                  >
                  <td class="px-4 py-3 font-mono text-xs" title={item.subjectId ?? undefined}
                    >{short(item.subjectId)}</td
                  >
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
        <ul class="flex flex-col gap-2 p-3 sm:hidden" aria-label={t.audit.title}>
          {#each items as item (item.id)}
            <li class="border-border flex flex-col gap-1.5 rounded-lg border p-3 text-sm">
              <span class="font-medium tabular-nums"
                >{formatDateTime(item.occurredAt, { utc: true })}</span
              >
              <p class="m-0 font-mono text-xs break-all">{item.action}</p>
              <p class="text-muted-foreground m-0 break-all">
                {t.audit.actorColumn}: {actorText(item)}
              </p>
              <p class="text-muted-foreground m-0 break-all">{t.audit.scope}: {scope(item)}</p>
              {#if item.subjectId}<p class="text-muted-foreground m-0 break-all">
                  {t.audit.subject}: {short(item.subjectId)}
                </p>{/if}
            </li>
          {/each}
        </ul>
      {/if}
      {#if loaded && !items.length && !error}
        <EmptyState title={t.audit.empty} description={t.audit.emptyHint} icon="audit" />
      {/if}
      {#if next}
        <div class="border-border border-t px-4 py-3">
          <Button variant="outline" disabled={busy} onclick={() => void load(true)}
            >{t.audit.next}</Button
          >
        </div>
      {/if}
    </Panel>
  {/if}
</div>
