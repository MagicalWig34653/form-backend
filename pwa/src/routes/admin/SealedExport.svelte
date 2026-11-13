<script lang="ts">
  import { onMount } from 'svelte';
  import { adminApi } from '$lib/api';
  import type { ExportItem } from '$lib/api/admin';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { t } from '$lib/i18n';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { router } from '$lib/router.svelte';
  import { Dialog, DialogTrigger, DialogContent, DialogClose } from '$lib/components/ui/dialog';
  import { Button } from '$lib/components/ui/button';
  import Notice from '$lib/components/admin/Notice.svelte';

  let { tenant, form }: { tenant: string; form: string } = $props();
  const ui = t.admin.entriesPage;
  let open = $state(false),
    busy = $state(false),
    count = $state(0),
    message = $state('');
  let epoch = 0;
  function cancel(): void {
    epoch++;
    busy = false;
  }
  onMount(() => {
    const off = keyring.onLock(() => {
      cancel();
      open = false;
    });
    return () => {
      cancel();
      off();
    };
  });
  async function download(): Promise<void> {
    if (busy) return;
    busy = true;
    count = 0;
    message = '';
    const run = ++epoch;
    const rows: ExportItem[] = [];
    const cursors: string[] = [];
    let cursor: string | undefined;
    try {
      do {
        const result = await adminApi.exportPage(tenant, form, cursor);
        if (run !== epoch) return;
        if (!result.ok) {
          if (needsFreshLogin(result.error)) return void (await reauthenticate(router.path));
          if (!handleSessionError(result.error)) message = describeError(result.error);
          return;
        }
        rows.push(...result.data.items);
        count = rows.length;
        cursor = result.data.nextCursor ?? undefined;
        if (cursor && cursors.includes(cursor)) throw new Error();
        if (cursor) cursors.push(cursor);
      } while (cursor);
      const url = URL.createObjectURL(
        new Blob([JSON.stringify(rows, null, 2)], { type: 'application/json' }),
      );
      try {
        const link = document.createElement('a');
        link.href = url;
        link.download = 'einsendungen-verschluesselt.json';
        link.click();
        open = false;
      } finally {
        URL.revokeObjectURL(url);
      }
    } catch {
      if (run === epoch) message = t.admin.entries.exportFailed;
    } finally {
      rows.length = 0;
      if (run === epoch) busy = false;
    }
  }
</script>

<Dialog
  bind:open
  onOpenChange={(value) => {
    if (!value) cancel();
  }}
>
  <DialogTrigger
    class="border-border hover:bg-secondary inline-flex min-h-10 items-center justify-center rounded-md border px-4 text-sm font-medium"
    >{t.admin.entries.exportSealed}</DialogTrigger
  >
  <DialogContent title={t.admin.entries.exportSealed} description={ui.exportScope}>
    <div class="w-full min-w-0 space-y-3">
      <p class="text-muted-foreground text-sm leading-6">{ui.exportContents}</p>
      {#if busy}<p role="status">{ui.exportProgress.replace('{n}', String(count))}</p>{/if}
      <Notice {message} />
    </div>
    <DialogClose
      class="border-border hover:bg-secondary min-h-10 rounded-md border px-4 text-sm font-medium"
      onclick={cancel}>{ui.cancel}</DialogClose
    >
    <Button disabled={busy} onclick={() => void download()}>{ui.export}</Button>
  </DialogContent>
</Dialog>
