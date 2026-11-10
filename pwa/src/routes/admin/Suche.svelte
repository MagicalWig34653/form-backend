<script lang="ts">
  import { formatDateTime } from '$lib/format';
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import FilterBar from '$lib/components/admin/FilterBar.svelte';
  import DateField from '$lib/components/admin/DateField.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import { Dialog, DialogContent, DialogClose } from '$lib/components/ui/dialog';
  import Notice from '$lib/components/admin/Notice.svelte';
  import Export from './Export.svelte';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { adminApi } from '$lib/api';
  import { access, scan, unwrap, RequestFailure, type Access } from '$lib/export/service';
  import { matches, type LocalRow } from '$lib/export/content';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { router } from '$lib/router.svelte';

  let {
    tenant,
    form,
    onDeleted,
  }: { tenant: string; form: string; onDeleted: (ids: string[]) => void } = $props();
  const ui = t.localExport;
  let query = $state(''),
    from = $state(''),
    until = $state('');
  let fromInvalid = $state(false),
    untilInvalid = $state(false);
  let rows = $state<LocalRow[]>([]),
    selected = $state<string[]>([]);
  let rights = $state<Access | null>(null);
  let busy = $state(false),
    loaded = $state(false),
    confirmation = $state(false);
  let message = $state(''),
    progress = $state(0);
  let epoch = 0;
  const visible = $derived(rows.filter((row) => matches(row, { query, from, until })));
  const chosen = $derived(visible.filter((row) => selected.includes(row.id)));
  const deleteReason = $derived(
    busy
      ? ''
      : !rights?.canDelete
        ? t.listUi.deleteNotAllowed
        : !chosen.some((row) => !row.unreadable)
          ? t.listUi.deleteNeedsSelection
          : '',
  );
  function invalidatePeriod(): void {
    epoch++;
    rows = [];
    selected = [];
    loaded = false;
    rights = null;
  }
  function clear(): void {
    epoch++;
    rows = [];
    selected = [];
    rights = null;
    loaded = false;
    confirmation = false;
    query = '';
    from = until = '';
    message = '';
  }
  function check(run: number): void {
    if (run !== epoch) throw new Error();
  }
  async function failure(error: unknown): Promise<void> {
    rows = [];
    selected = [];
    rights = null;
    loaded = false;
    if (error instanceof RequestFailure) {
      if (needsFreshLogin(error.error)) return void (await reauthenticate(router.path));
      if (handleSessionError(error.error)) return;
      message = describeError(error.error);
    } else message = ui.failed;
  }
  async function search(): Promise<void> {
    if (busy) return;
    rows = [];
    selected = [];
    loaded = false;
    message = '';
    if (fromInvalid || untilInvalid) {
      message = t.listUi.dateInvalid;
      return;
    }
    if (from && until && from > until) {
      message = ui.invalidPeriod;
      return;
    }
    busy = true;
    progress = 0;
    const run = ++epoch;
    try {
      const live = await access(tenant, form);
      check(run);
      const result = await scan(
        tenant,
        form,
        { query, from, until },
        () => check(run),
        (n) => (progress = n),
      );
      check(run);
      rows = result;
      rights = live;
      loaded = true;
    } catch (error) {
      if (run === epoch) await failure(error);
    } finally {
      busy = false;
    }
  }
  async function remove(): Promise<void> {
    const ids = chosen.filter((row) => !row.unreadable).map((row) => row.id);
    if (busy || !ids.length) return;
    confirmation = false;
    busy = true;
    message = '';
    const run = epoch;
    try {
      const live = await access(tenant, form);
      check(run);
      if (!live.canDelete) throw new Error();
      for (let i = 0; i < ids.length; i += 100) {
        check(run);
        const result = unwrap(await adminApi.deleteEntries(tenant, form, ids.slice(i, i + 100)));
        check(run);
        rows = rows.filter((row) => !result.deleted.includes(row.id));
        selected = selected.filter((id) => !result.deleted.includes(id));
        onDeleted(result.deleted);
        // Held, missing and asynchronous deletions stay visible until a fresh scan.
        if (result.deleted.length !== ids.slice(i, i + 100).length) {
          message = ui.partial;
          break;
        }
      }
      if (!message) message = ui.deleted;
    } catch (error) {
      if (run === epoch) await failure(error);
    } finally {
      busy = false;
    }
  }
  onMount(() => {
    const off = keyring.onLock(clear);
    return () => {
      off();
      clear();
    };
  });
</script>

<section
  class="bg-card ring-1 ring-foreground/10 rounded-xl min-w-0 space-y-4 px-5 py-4"
  aria-labelledby="local-search-title"
>
  <div>
    <h2 id="local-search-title" class="text-xl leading-snug font-semibold tracking-tight">
      {ui.title}
    </h2>
    <p class="text-muted-foreground max-w-prose text-sm leading-[18px]">
      {ui.intro}
    </p>
  </div>
  <form
    onsubmit={(event) => {
      event.preventDefault();
      void search();
    }}
  >
    <FilterBar collapsible={false}>
      <label class="flex min-w-52 flex-[2] flex-col gap-1.5 text-sm font-medium"
        >{ui.query}<Input type="search" bind:value={query} disabled={busy} /></label
      >
      <DateField
        id="local-from"
        label={ui.from}
        bind:value={from}
        bind:invalid={fromInvalid}
        onchange={invalidatePeriod}
        disabled={busy}
        class="min-w-36 flex-1"
      />
      <DateField
        id="local-until"
        label={ui.until}
        bind:value={until}
        bind:invalid={untilInvalid}
        onchange={invalidatePeriod}
        disabled={busy}
        class="min-w-36 flex-1"
      />
      {#snippet trailing()}
        <Button type="submit" disabled={busy}>{ui.search}</Button>
        <Button type="button" variant="outline" onclick={clear}>{ui.clear}</Button>
      {/snippet}
    </FilterBar>
  </form>
  {#if busy}<p role="status" class="text-muted-foreground text-sm">
      {ui.progress.replace('{n}', String(progress))}
    </p>{/if}
  <Notice {message} />
  {#if loaded}
    <div class="flex flex-wrap items-center justify-between gap-2">
      <p role="status" class="font-medium">{ui.count.replace('{n}', String(visible.length))}</p>
      <Button
        variant="outline"
        disabled={busy}
        onclick={() => (selected = visible.map((row) => row.id))}>{ui.selectAll}</Button
      >
    </div>
    <p class="text-muted-foreground text-sm leading-5">{ui.unknownHint}</p>
    {#if visible.length === 0}
      <EmptyState icon="search" title={t.admin.entriesPage.filteredEmpty} />
    {:else}
      <ul class="divide-border border-border divide-y border-y">
        {#each visible as row (row.id)}
          <li class="min-w-0 py-1.5">
            <label class="flex min-h-11 items-center gap-3 break-all"
              ><input
                type="checkbox"
                class="size-6 shrink-0 accent-[var(--ui-accent)]"
                bind:group={selected}
                value={row.id}
                disabled={busy}
              /><span class="tabular-nums"
                >{row.receivedAt ? formatDateTime(row.receivedAt) : ui.noDate}</span
              >
              <span class="text-muted-foreground text-sm">· {row.id}</span></label
            >
            {#if row.unreadable}<p class="text-muted-foreground pl-9 text-sm">
                {ui.unknown}
              </p>{:else}<pre
                class="bg-muted/60 ml-9 max-h-48 overflow-auto rounded-md p-3 text-sm break-all whitespace-pre-wrap">{JSON.stringify(
                  row.fields,
                  null,
                  2,
                )}</pre>{/if}
          </li>
        {/each}
      </ul>
    {/if}
    <div class="border-border flex flex-col gap-4 rounded-xl border p-4">
      <Export
        {tenant}
        {form}
        rows={chosen}
        allowed={rights?.canExport ?? false}
        disabled={busy}
        onFailure={failure}
      />
      <div class="border-border flex flex-col gap-2 border-t pt-4">
        <div>
          <Button
            variant="outline"
            class="text-destructive"
            disabled={busy || !rights?.canDelete || !chosen.some((row) => !row.unreadable)}
            aria-describedby={deleteReason ? 'delete-reason' : undefined}
            onclick={() => (confirmation = true)}>{ui.delete}</Button
          >
        </div>
        {#if deleteReason}<p id="delete-reason" class="text-muted-foreground text-sm">
            {deleteReason}
          </p>{/if}
      </div>
    </div>
  {/if}
</section>
<Dialog bind:open={confirmation}>
  <DialogContent title={ui.deleteTitle} description={ui.deleteHint}>
    <DialogClose class="min-h-11 rounded-md border px-4">{ui.cancel}</DialogClose>
    <Button variant="outline" class="text-destructive" onclick={() => void remove()}
      >{ui.confirmDelete}</Button
    >
  </DialogContent>
</Dialog>
