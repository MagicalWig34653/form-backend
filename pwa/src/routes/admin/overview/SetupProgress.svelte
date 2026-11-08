<script lang="ts">
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { formPath, type Tab } from '$lib/routes';
  import type { SetupStep, SetupStepId } from '$lib/stats/overview';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import { Button } from '$lib/components/ui/button';

  interface Props {
    tenant: string;
    steps: SetupStep[];
    loading?: boolean;
  }
  let { tenant, steps, loading = false }: Props = $props();

  const ui = t.overview;
  const tabs: Record<SetupStepId, Tab> = {
    form: 'overview',
    mail: 'mail',
    published: 'publish',
    active: 'overview',
    traffic: 'publish',
  };
  const doneCount = $derived(steps.filter((s) => s.done === true).length);
  const percent = $derived(steps.length === 0 ? 0 : Math.round((doneCount / steps.length) * 100));
  const next = $derived(steps.find((s) => s.done === false && s.formId));
  const unknown = $derived(steps.some((s) => s.done === null));
</script>

<Panel
  title={`${ui.setup} ${doneCount}/${steps.length}`}
  description={ui.setupCount
    .replace('{done}', String(doneCount))
    .replace('{total}', String(steps.length))}
  id="setup"
>
  <div aria-busy={loading}>
    {#if loading && steps.length === 0}
      <div class="flex flex-col gap-3" aria-hidden="true">
        <Skeleton class="h-2.5 w-full" /><Skeleton class="h-5 w-2/3" /><Skeleton
          class="h-5 w-1/2"
        />
      </div>
    {:else}
      <div
        role="progressbar"
        aria-label={ui.setupProgress}
        aria-valuemin="0"
        aria-valuemax="100"
        aria-valuenow={percent}
        aria-valuetext={`${percent} %`}
        class="bg-muted/60 mb-4 h-2.5 overflow-hidden rounded-full"
      >
        <div
          class="bg-primary h-full rounded-full transition-[width] duration-[var(--dur-slow)] ease-[var(--ease-out)]"
          style={`width:${percent}%`}
        ></div>
      </div>
      <ul class="grid gap-x-4 gap-y-2 sm:grid-cols-2">
        {#each steps as step (step.id)}
          <li class="flex items-center gap-2">
            <span
              aria-hidden="true"
              class={step.done
                ? 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-400 flex size-5 shrink-0 items-center justify-center rounded-full [&>svg]:size-3'
                : 'border-border text-muted-foreground flex size-5 shrink-0 items-center justify-center rounded-full border'}
              >{#if step.done}<NavIcon name="check" size={12} />{/if}</span
            >
            <span>{ui.setupSteps[step.id]}</span>
            <span class="sr-only"
              >({step.done === true
                ? ui.stepDone
                : step.done === false
                  ? ui.stepOpen
                  : ui.stepUnknown})</span
            >
          </li>
        {/each}
      </ul>
      {#if next}
        <div class="mt-4">
          <Button
            variant="outline"
            onclick={() => router.navigate(formPath(tenant, next.formId ?? '', tabs[next.id]))}
            >{ui.setupNext}<span class="sr-only">: {ui.setupSteps[next.id]}</span></Button
          >
        </div>
      {:else if !unknown && steps.length > 0}
        <p class="text-muted-foreground mt-3 text-sm">{ui.setupComplete}</p>
      {/if}
    {/if}
  </div>
</Panel>
