<script lang="ts">
  import type { Snippet } from 'svelte';
  import { Button } from '$lib/components/ui/button';
  import { t } from '$lib/i18n';

  interface Props {
    /** Zero-based index of the shown step. */
    step: number;
    total: number;
    /** False while the next step is not yet justified by the data. */
    canNext: boolean;
    onback: () => void;
    onnext: () => void;
    /** Why "Weiter" is disabled, shown as text instead of leaving the user guessing. */
    hint?: string;
    /** Step-specific primary actions, shown before "Weiter". */
    children?: Snippet;
  }
  let { step, total, canNext, onback, onnext, hint, children }: Props = $props();
  const f = t.formKit.migration.flow;
</script>

<div class="border-border mt-5 flex flex-col gap-3 border-t pt-4">
  {#if hint && !canNext && step < total - 1}
    <p class="text-muted-foreground m-0 text-sm" id="step-hint">{hint}</p>
  {/if}
  <div class="flex flex-wrap items-center gap-2">
    {#if step > 0}<Button type="button" variant="outline" onclick={onback}>{f.back}</Button>{/if}
    <span class="text-muted-foreground text-sm tabular-nums"
      >{f.stepOf.replace('{n}', String(step + 1)).replace('{m}', String(total))}</span
    >
    <div class="ml-auto flex flex-wrap items-center justify-end gap-2">
      {@render children?.()}
      {#if step < total - 1}
        <Button
          type="button"
          disabled={!canNext}
          aria-describedby={hint && !canNext ? 'step-hint' : undefined}
          onclick={onnext}>{f.next}</Button
        >
      {/if}
    </div>
  </div>
</div>
