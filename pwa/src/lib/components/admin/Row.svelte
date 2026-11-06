<script lang="ts">
  import type { Snippet } from 'svelte';

  interface Props {
    id: string;
    label: string;
    hint?: string;
    error?: string | undefined;
    children: Snippet;
  }
  let { id, label, hint, error, children }: Props = $props();
</script>

<div class="flex flex-col gap-1.5">
  <label for={id} class="text-sm font-medium">{label}</label>
  {@render children()}
  {#if hint}<p id={`${id}-hint`} class="text-muted-foreground text-xs">{hint}</p>{/if}
  {#if error}<p id={`${id}-error`} role="alert" class="text-destructive text-sm">{error}</p>{/if}
</div>
