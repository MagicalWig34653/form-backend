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
  const tones: Record<Tone, string> = {
    ok: 'bg-ok-soft text-ok',
    warn: 'bg-warn-soft text-warn',
    danger: 'bg-danger-soft text-danger',
    info: 'bg-info-soft text-info',
    idle: 'bg-idle-soft text-idle',
  };
</script>

<span
  data-tone={tone}
  class={cn(
    'inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-[length:var(--fs-small)] leading-[18px] font-medium whitespace-nowrap',
    tones[tone],
    className,
  )}
>
  <span
    aria-hidden="true"
    class={cn(
      'relative size-2 shrink-0 rounded-full bg-current',
      pulse && tone !== 'danger' && 'pulse-ring',
    )}
  ></span>{label}
</span>
