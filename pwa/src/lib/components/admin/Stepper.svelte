<script lang="ts">
  import { cn } from '$lib/utils';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import { t } from '$lib/i18n';

  interface Step {
    id: string;
    label: string;
  }
  interface Props {
    steps: Step[];
    /** Zero-based index of the current step; -1 when none has started. */
    current: number;
    label: string;
    /** Furthest step reached so far; earlier steps count as done even while an older one is shown. */
    reached?: number;
    class?: string;
  }
  let { steps, current, label, reached, class: className }: Props = $props();
  const furthest = $derived(Math.max(reached ?? current, current));
</script>

<nav aria-label={label} class={cn('min-w-0', className)}>
  <ol
    class="grid grid-cols-[repeat(var(--n),minmax(0,1fr))] gap-1 sm:gap-2"
    style:--n={steps.length}
  >
    {#each steps as step, index (step.id)}
      {@const done = index < furthest && index !== current}
      {@const active = index === current}
      <li
        aria-current={active ? 'step' : undefined}
        class="relative flex min-w-0 flex-col items-center gap-1.5 text-center"
      >
        {#if index > 0}<span
            aria-hidden="true"
            data-connector
            class={cn(
              'absolute top-4 right-1/2 h-0.5 w-full -translate-y-1/2',
              index <= furthest ? 'bg-emerald-600' : 'bg-border',
            )}
          ></span>{/if}
        <span
          class={cn(
            'relative z-10 flex size-8 items-center justify-center rounded-full border text-sm font-semibold transition-colors',
            done && 'border-emerald-600 bg-emerald-500/10 text-emerald-700 dark:text-emerald-400',
            active && 'border-brand bg-brand text-primary-foreground',
            !done && !active && 'border-input bg-muted/60 text-muted-foreground',
          )}
        >
          {#if done}<NavIcon name="check" size={16} />{:else}{index + 1}{/if}
        </span>
        <span
          class={cn(
            'w-full text-xs leading-4 break-words',
            active ? 'text-foreground font-semibold' : 'text-muted-foreground max-sm:sr-only',
          )}
        >
          {step.label}<span class="sr-only">
            ({done
              ? t.formKit.stepDone
              : active
                ? t.formKit.stepCurrent
                : t.formKit.stepOpen})</span
          >
        </span>
      </li>
    {/each}
  </ol>
</nav>
