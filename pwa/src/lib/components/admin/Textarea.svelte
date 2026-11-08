<script lang="ts">
  import Textarea from '$lib/components/ui/textarea/textarea.svelte';
  import type { HTMLTextareaAttributes } from 'svelte/elements';
  let { value = $bindable(), ...rest }: HTMLTextareaAttributes = $props();
</script>

<Textarea bind:value {...rest} />
