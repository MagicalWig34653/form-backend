<script lang="ts" module>
  export type Tone = 'ok' | 'warn' | 'danger' | 'info' | 'idle';
</script>

<script lang="ts">
  import { cn } from '$lib/utils';

  interface Props {
    tone?: Tone;
    label: string;
    /** Soft ring around the dot for live/waiting states; never for errors. */
    pulse?: boolean;
    class?: string;
  }
  let { tone = 'idle', label, pulse = false, class: className }: Props = $props();
  // Getönt, nie voll: Zustand steht immer als Text neben dem Punkt.
  const tones: Record<Tone, string> = {
    ok: 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-400',
    warn: 'bg-amber-500/10 text-amber-800 dark:text-amber-400',
    danger: 'bg-destructive/10 text-red-700 dark:text-destructive',
    info: 'bg-blue-500/10 text-blue-700 dark:text-blue-400',
    idle: 'bg-muted text-muted-foreground',
  };
</script>

<span
  data-tone={tone}
  class={cn(
    'inline-flex h-6 items-center gap-1.5 rounded-full px-2.5 text-xs leading-none font-medium whitespace-nowrap',
    tones[tone],
    className,
  )}
>
  <span
    aria-hidden="true"
    class={cn(
      'size-1.5 shrink-0 rounded-full bg-current',
      pulse && tone !== 'danger' && 'animate-pulse',
    )}
  ></span>{label}
</span>
