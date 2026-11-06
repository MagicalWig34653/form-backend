<script lang="ts">
  import type { HTMLButtonAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';

  type Variant = 'default' | 'secondary' | 'outline' | 'ghost';
  interface Props extends HTMLButtonAttributes {
    variant?: Variant;
  }
  let { variant = 'default', class: className, children, ...rest }: Props = $props();

  const variants: Record<Variant, string> = {
    default: 'bg-primary text-primary-foreground hover:opacity-90',
    secondary: 'bg-secondary text-foreground hover:opacity-80',
    outline: 'border border-border bg-transparent hover:bg-secondary',
    ghost: 'bg-transparent hover:bg-secondary',
  };
</script>

<button
  class={cn(
    'inline-flex min-h-10 items-center justify-center gap-2 rounded-md px-4 py-2 text-sm font-medium disabled:pointer-events-none disabled:opacity-50',
    variants[variant],
    className,
  )}
  {...rest}
>
  {@render children?.()}
</button>
