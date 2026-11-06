<script lang="ts">
  import type { HTMLTableAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';

  interface Props extends HTMLTableAttributes {
    /**
     * Accessible name of the scroll region. When given, the wide-table container is a labelled,
     * keyboard-focusable region so that horizontal scrolling works without a mouse (WCAG 2.1.1).
     */
    label?: string;
    /** Classes for the scroll container. */
    containerClass?: string;
  }
  let { class: className, containerClass, label, children, ...rest }: Props = $props();
</script>

<!-- svelte-ignore a11y_no_noninteractive_tabindex (keyboard access to horizontal scrolling) -->
<div
  class={cn('w-full overflow-x-auto', containerClass)}
  role={label ? 'region' : undefined}
  aria-label={label}
  tabindex={label ? 0 : undefined}
>
  <table
    class={cn(
      'w-full text-left text-[length:var(--fs-body)] [&_td]:px-4 [&_td]:py-2.5 [&_th]:px-4 [&_th]:py-2.5 [&_th]:font-medium [&_tr]:border-b [&_tr]:border-[var(--border-subtle)] [&_tbody_tr:last-child]:border-b-0',
      className,
    )}
    {...rest}
  >
    {@render children?.()}
  </table>
</div>
