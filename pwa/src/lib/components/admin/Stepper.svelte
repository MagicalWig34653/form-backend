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
    class?: string;
  }
  let { steps, current, label, class: className }: Props = $props();
  const percent = $derived(
    steps.length > 1 ? Math.round((Math.max(current, 0) / (steps.length - 1)) * 100) : 0,
  );
</script>

<nav aria-label={label} class={cn('min-w-0', className)}>
  <ol
    class="grid grid-cols-[repeat(var(--n),minmax(0,1fr))] gap-1 sm:gap-2"
    style:--n={steps.length}
  >
    {#each steps as step, index (step.id)}
      {@const done = index < current}
      {@const active = index === current}
      <li
        aria-current={active ? 'step' : undefined}
        class="flex min-w-0 flex-col items-center gap-1.5 text-center"
      >
        <span
          class={cn(
            'flex size-8 items-center justify-center rounded-full border text-sm font-semibold transition-colors',
            done && 'border-ok bg-ok-soft text-ok',
            active && 'border-ui-accent bg-ui-accent text-ui-accent-foreground',
            !done && !active && 'border-input bg-surface-sunken text-muted-foreground',
          )}
        >
          {#if done}<NavIcon name="check" size={16} />{:else}{index + 1}{/if}
        </span>
        <span
          class={cn(
            'w-full text-xs leading-4 [overflow-wrap:anywhere] hyphens-auto',
            active ? 'text-foreground font-semibold' : 'text-muted-foreground',
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
  <div aria-hidden="true" class="bg-surface-sunken mt-3 h-1 overflow-hidden rounded-full">
    <div
      class="bg-ui-accent h-full rounded-full transition-[width] duration-500"
      style:width="{percent}%"
    ></div>
  </div>
</nav>
