<script lang="ts">
  import type { HTMLAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';

  type Variant = 'default' | 'secondary' | 'destructive' | 'outline';
  interface Props extends HTMLAttributes<HTMLSpanElement> {
    variant?: Variant;
  }
  let { variant = 'secondary', class: className, children, ...rest }: Props = $props();
  const variants: Record<Variant, string> = {
    default: 'bg-primary text-primary-foreground',
    secondary: 'bg-secondary text-secondary-foreground',
    destructive: 'bg-destructive/10 text-destructive dark:bg-destructive/20',
    outline: 'border-border text-foreground',
  };
</script>

<span
  data-slot="badge"
  class={cn(
    'inline-flex h-5 w-fit shrink-0 items-center justify-center gap-1 overflow-hidden rounded-full border border-transparent px-2 py-0.5 text-xs font-medium whitespace-nowrap [&>svg]:size-3',
    variants[variant],
    className,
  )}
  {...rest}>{@render children?.()}</span
>
