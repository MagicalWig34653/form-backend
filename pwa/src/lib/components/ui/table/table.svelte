<script lang="ts">
  import type { HTMLTableAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: HTMLTableAttributes = $props();
</script>

<div class="w-full overflow-x-auto">
  <table
    class={cn(
      'w-full text-left text-sm [&_th]:px-4 [&_th]:py-3 [&_th]:font-medium [&_td]:px-4 [&_td]:py-3 [&_tr]:border-b [&_tr]:border-border',
      className,
    )}
    {...rest}
  >
    {@render children?.()}
  </table>
</div>
