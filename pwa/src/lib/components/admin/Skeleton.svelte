<script lang="ts">
  import { cn } from '$lib/utils';
  /** Placeholder in target geometry. Give the container aria-busy="true"; this element is decorative. */
  let { class: className }: { class?: string } = $props();
</script>

<div aria-hidden="true" class={cn('skeleton h-4 w-full rounded-md', className)}></div>
