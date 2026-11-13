<script lang="ts">
  import Select from '$lib/components/ui/select/select.svelte';
  import type { HTMLSelectAttributes } from 'svelte/elements';
  let { value = $bindable(''), children, ...rest }: HTMLSelectAttributes = $props();
</script>

<Select bind:value {...rest}>{@render children?.()}</Select>
