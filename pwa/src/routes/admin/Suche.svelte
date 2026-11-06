<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
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

<section class="bg-card my-4 min-w-0 space-y-4 rounded-xl border p-4 sm:p-6" aria-label={ui.title}>
  <h3 class="text-lg font-semibold">{ui.title}</h3>
  <p class="text-muted-foreground text-sm">{ui.intro}</p>
  <form
    class="grid gap-3 sm:grid-cols-3"
    onsubmit={(event) => {
      event.preventDefault();
      void search();
    }}
  >
    <label class="space-y-2 text-sm"
      >{ui.query}<Input type="search" bind:value={query} disabled={busy} /></label
    >
    <label class="space-y-2 text-sm"
      >{ui.from}<Input
        type="date"
        onchange={invalidatePeriod}
        bind:value={from}
        disabled={busy}
      /></label
    >
    <label class="space-y-2 text-sm"
      >{ui.until}<Input
        type="date"
        onchange={invalidatePeriod}
        bind:value={until}
        disabled={busy}
      /></label
    >
    <Button type="submit" disabled={busy}>{ui.search}</Button>
    <Button type="button" variant="outline" onclick={clear}>{ui.clear}</Button>
  </form>
  {#if busy}<p role="status">{ui.progress.replace('{n}', String(progress))}</p>{/if}
  <Notice {message} />
  {#if loaded}
    <p role="status">{ui.count.replace('{n}', String(visible.length))}</p>
    <p class="text-sm">{ui.unknownHint}</p>
    <Button
      variant="outline"
      disabled={busy}
      onclick={() => (selected = visible.map((row) => row.id))}>{ui.selectAll}</Button
    >
    <ul class="space-y-2">
      {#each visible as row (row.id)}
        <li class="min-w-0 rounded-lg border p-3">
          <label class="flex min-h-11 items-center gap-3 break-all"
            ><input
              type="checkbox"
              bind:group={selected}
              value={row.id}
              disabled={busy}
            />{row.receivedAt ?? ui.noDate} · {row.id}</label
          >
          {#if row.unreadable}<p class="text-sm">{ui.unknown}</p>{:else}<pre
              class="max-h-48 overflow-auto whitespace-pre-wrap break-all text-sm">{JSON.stringify(
                row.fields,
                null,
                2,
              )}</pre>{/if}
        </li>
      {/each}
    </ul>
    <Export
      {tenant}
      {form}
      rows={chosen}
      allowed={rights?.canExport ?? false}
      disabled={busy}
      onFailure={failure}
    />
    <Button
      variant="outline"
      class="text-destructive"
      disabled={busy || !rights?.canDelete || !chosen.some((row) => !row.unreadable)}
      onclick={() => (confirmation = true)}>{ui.delete}</Button
    >
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
