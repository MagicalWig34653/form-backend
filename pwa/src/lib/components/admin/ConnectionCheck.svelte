<script lang="ts">
  import Check from '@lucide/svelte/icons/check';
  import LoaderCircle from '@lucide/svelte/icons/loader-circle';
  import Minus from '@lucide/svelte/icons/minus';
  import X from '@lucide/svelte/icons/x';
  import { t } from '$lib/i18n';
  import {
    formatDuration,
    PROXY_STEPS,
    SMTP_STEPS,
    type CheckKind,
    type CheckOutcome,
    type StepId,
  } from '$lib/admin/connectionCheck';
  import Banner from './Banner.svelte';
  import Panel from './Panel.svelte';

  /**
   * Prüfbereich einer Verbindung: senkrechter Schritt-Stepper (Schritte werden aus dem Fehlercode
   * abgeleitet, siehe connectionCheck.ts), Ergebnis und Rat am fehlgeschlagenen Schritt.
   * Es werden keine Dauern je Schritt gezeigt, nur die clientseitig gemessene Gesamtdauer.
   */
  interface Props {
    kind: CheckKind;
    name: string;
    running: boolean;
    outcome: CheckOutcome | null;
    /** Meldung, wenn die Prüfung selbst nicht lief (z. B. Rate-Limit). */
    error?: string;
    totalMs?: number | null;
    id: string;
  }
  let { kind, name, running, outcome, error = '', totalMs = null, id }: Props = $props();

  const c = t.admin.connections.check;
  const tone = {
    ok: 'border-emerald-500/50 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300',
    failed: 'border-destructive/50 bg-destructive/10 text-red-700 dark:text-destructive',
    skipped: 'border-border bg-muted text-muted-foreground',
  } as const;

  const waiting = $derived<StepId[]>(kind === 'mail-proxy' ? PROXY_STEPS : SMTP_STEPS);
  const stepTitle = (step: StepId): string =>
    kind === 'mail-proxy' && step === 'dns' ? c.proxySteps.dns : c.steps[step];

  function problemOf(o: CheckOutcome): { message: string; advice: string } {
    const known =
      o.known && o.code
        ? (c.codes as Record<string, { message: string; advice: string }>)[o.code]
        : null;
    if (known) return known;
    return {
      message: c.unknown.message.replace('{code}', o.code ?? '?'),
      advice: c.unknown.advice,
    };
  }
  const problem = $derived(outcome && !outcome.ok ? problemOf(outcome) : null);
  // Ohne Schritt (Konfigurationsfehler, unbekannter Code, Speicher) steht der Rat im Ergebnis selbst.
  const generalProblem = $derived(outcome && !outcome.ok && outcome.failedStep === null);
</script>

<div role="group" aria-label="{c.title}: {name}" class="w-full min-w-0" data-testid="check-{id}">
  <Panel title={c.title} description={c.text} level={3} class="bg-muted/30">
    <div aria-live="polite" aria-busy={running} class="flex flex-col gap-4">
      {#if running}
        <span class="sr-only" role="status">{c.running}</span>
        {#if kind === 'smtp' || kind === 'mail-proxy'}
          <ol class="m-0 flex list-none flex-col p-0" data-testid="check-steps-{id}">
            {#each waiting as step, index (step)}
              <li class="relative flex gap-3 pb-4 last:pb-0" data-status="pending">
                <span
                  class="border-border bg-muted text-muted-foreground relative z-10 flex size-7 shrink-0 items-center justify-center rounded-full border"
                >
                  {#if index === 0}<LoaderCircle
                      class="size-4 animate-spin motion-reduce:animate-none"
                      aria-hidden="true"
                    />{:else}<span
                      class="bg-muted-foreground/60 size-1.5 rounded-full"
                      aria-hidden="true"
                    ></span>{/if}
                </span>
                <p class="text-muted-foreground m-0 pt-0.5 text-sm font-medium">
                  {stepTitle(step)}<span class="sr-only"> – {c.wait}</span>
                </p>
              </li>
            {/each}
          </ol>
        {:else}
          <p class="text-muted-foreground m-0 flex items-center gap-2 text-sm">
            <LoaderCircle
              class="size-4 animate-spin motion-reduce:animate-none"
              aria-hidden="true"
            />{c.running}
          </p>
        {/if}
      {:else if error}
        <Banner tone="danger"><span data-testid="check-error-{id}">{error}</span></Banner>
      {:else if outcome}
        {#if outcome.steps.length > 0}
          <ol class="m-0 flex list-none flex-col p-0" data-testid="check-steps-{id}">
            {#each outcome.steps as step, index (step.id)}
              <li
                class="check-step relative flex gap-3 pb-4 last:pb-0"
                style="animation-delay: {index * 90}ms"
                data-testid="check-step-{id}-{step.id}"
                data-status={step.status}
              >
                {#if index < outcome.steps.length - 1}<span
                    class="bg-border absolute top-7 bottom-0 left-3.5 w-px -translate-x-1/2"
                    aria-hidden="true"
                  ></span>{/if}
                <span
                  class="relative z-10 flex size-7 shrink-0 items-center justify-center rounded-full border {tone[
                    step.status
                  ]}"
                >
                  {#if step.status === 'ok'}<Check
                      class="size-4"
                      aria-hidden="true"
                    />{:else if step.status === 'failed'}<X
                      class="size-4"
                      aria-hidden="true"
                    />{:else}<Minus class="size-4" aria-hidden="true" />{/if}
                </span>
                <div class="min-w-0 flex-1 pt-0.5">
                  <p
                    class="m-0 text-sm font-medium {step.status === 'skipped'
                      ? 'text-muted-foreground'
                      : ''}"
                  >
                    {stepTitle(step.id)}<span class="sr-only"> – {c.status[step.status]}</span>
                    {#if step.status === 'skipped'}<span
                        class="text-muted-foreground text-xs font-normal"
                        aria-hidden="true"
                      >
                        · {c.status.skipped}</span
                      >{/if}
                  </p>
                  {#if step.status === 'failed' && problem}
                    <div
                      class="border-destructive/40 bg-destructive/10 mt-2 rounded-lg border px-3 py-2.5 text-sm"
                      data-testid="check-problem-{id}"
                    >
                      <p class="m-0 font-medium text-red-700 dark:text-destructive">
                        {problem.message}
                      </p>
                      <p class="m-0 mt-2 text-[13px] font-medium">{c.help}</p>
                      <p class="m-0 text-[13px]">{problem.advice}</p>
                      {#if outcome.transient}<p class="text-muted-foreground m-0 mt-2 text-[13px]">
                          {c.transient}
                        </p>{/if}
                    </div>
                  {/if}
                </div>
              </li>
            {/each}
          </ol>
        {/if}

        {#if outcome.ok}
          <Banner tone="ok" title={c.ok}>
            <span data-testid="check-result-{id}" data-ok="true"
              >{outcome.steps.length > 0 ? c.okText : c.okStorage}{#if totalMs !== null}<span
                  class="text-muted-foreground mt-1 block text-xs"
                  >{c.total.replace('{ms}', formatDuration(totalMs))}</span
                >{/if}</span
            >
          </Banner>
        {:else}
          <Banner tone="danger" title={c.failed}>
            <span data-testid="check-result-{id}" data-ok="false"
              >{generalProblem ? c.failedNoStep : c.failedHint}{#if totalMs !== null}<span
                  class="text-muted-foreground mt-1 block text-xs"
                  >{c.total.replace('{ms}', formatDuration(totalMs))}</span
                >{/if}</span
            >
          </Banner>
          {#if generalProblem && problem}
            <div
              class="border-destructive/40 bg-destructive/10 rounded-lg border px-3 py-2.5 text-sm"
              data-testid="check-problem-{id}"
            >
              <p class="m-0 font-medium text-red-700 dark:text-destructive">{problem.message}</p>
              <p class="m-0 mt-2 text-[13px] font-medium">{c.help}</p>
              <p class="m-0 text-[13px]">{problem.advice}</p>
              {#if outcome.transient}<p class="text-muted-foreground m-0 mt-2 text-[13px]">
                  {c.transient}
                </p>{/if}
            </div>
          {/if}
        {/if}
      {/if}
    </div>
  </Panel>
</div>

<style>
  .check-step {
    animation: check-step-in 260ms ease-out both;
  }
  @keyframes check-step-in {
    from {
      opacity: 0;
      transform: translateY(6px);
    }
    to {
      opacity: 1;
      transform: none;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .check-step {
      animation: none;
    }
  }
</style>
