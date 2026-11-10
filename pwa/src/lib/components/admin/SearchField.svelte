<script lang="ts">
  import { Input } from '$lib/components/ui/input';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import { cn } from '$lib/utils';

  interface Props {
    id: string;
    /** Accessible name; the field has no visible label, the placeholder says what to type. */
    label: string;
    placeholder?: string;
    value?: string;
    class?: string;
  }
  let { id, label, placeholder, value = $bindable(''), class: className }: Props = $props();
</script>

<div class={cn('relative min-w-48 flex-1', className)}>
  <span
    aria-hidden="true"
    class="text-muted-foreground pointer-events-none absolute top-1/2 left-3 -translate-y-1/2"
    ><NavIcon name="search" size={16} /></span
  >
  <Input {id} type="search" aria-label={label} {placeholder} bind:value class="pl-9" />
</div>
