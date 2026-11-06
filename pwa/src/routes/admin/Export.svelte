<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { audit } from '$lib/export/service';
  import { serialize, type LocalRow } from '$lib/export/content';
  let {
    tenant,
    form,
    rows,
    allowed,
    disabled,
    onFailure,
  }: {
    tenant: string;
    form: string;
    rows: LocalRow[];
    allowed: boolean;
    disabled: boolean;
    onFailure: (error: unknown) => Promise<void>;
  } = $props();
  const ui = t.localExport;
  let busy = $state(false);
  let epoch = 0;
  onMount(() => {
    const off = keyring.onLock(() => epoch++);
    return () => {
      epoch++;
      off();
    };
  });
  async function download(format: 'csv' | 'json'): Promise<void> {
    if (busy || disabled || !allowed || !rows.length) return;
    busy = true;
    const run = epoch;
    const snapshot = rows.slice();
    const off = keyring.onLock(() => {
      epoch++;
      snapshot.length = 0;
    });
    try {
      // Serialize only after the live rights and audit call succeeds.
      await audit(tenant, form);
      if (run !== epoch) return;
      const url = URL.createObjectURL(
        new Blob([serialize(snapshot, format)], {
          type: format === 'csv' ? 'text/csv;charset=utf-8' : 'application/json',
        }),
      );
      try {
        const link = document.createElement('a');
        link.href = url;
        link.download = `einsendungen.${format}`;
        link.click();
      } finally {
        URL.revokeObjectURL(url);
      }
    } catch (error) {
      if (run === epoch) await onFailure(error);
    } finally {
      off();
      snapshot.length = 0;
      busy = false;
    }
  }
</script>

<div class="flex flex-wrap gap-3">
  <p class="w-full text-sm">{ui.downloadHint}</p>
  <Button
    variant="outline"
    disabled={disabled || busy || !allowed || !rows.length}
    onclick={() => void download('csv')}>{ui.csv}</Button
  >
  <Button
    variant="outline"
    disabled={disabled || busy || !allowed || !rows.length}
    onclick={() => void download('json')}>{ui.json}</Button
  >
</div>
