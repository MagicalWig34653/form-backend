<script lang="ts">
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { matchRoute } from '$lib/routes';
  import { onboarding } from '$lib/onboarding.svelte';
  import { nextOpenStep, stepScope } from '$lib/onboarding';
  import { Button } from '$lib/components/ui/button';
  import NavIcon from './NavIcon.svelte';

  const ui = t.installationPage;
  /** While a step page is open its status is re-checked in this interval (one small request per step). */
  const POLL_MS = 5000;
  const SETTLE_MS = 900;

  const route = $derived(matchRoute(router.path));
  const ctx = $derived(onboarding.activeContext);
  const inScope = $derived(ctx !== null && stepScope(ctx, route));
  const visible = $derived(onboarding.open && onboarding.ready && inScope);
  const index = $derived(ctx ? onboarding.steps.findIndex((s) => s.id === ctx) : -1);
  const step = $derived(index >= 0 ? onboarding.steps[index] : undefined);
  const finished = $derived(step?.state === 'done' || step?.state === 'skipped');
  const next = $derived(ctx ? nextOpenStep(onboarding.steps, ctx) : null);

  // Leaving the pages of a step ends its context; the bar never follows the user anywhere else.
  $effect(() => {
    if (ctx !== null && !inScope) onboarding.setContext(null);
  });

  $effect(() => {
    if (!visible || !ctx) return;
    const id = ctx;
    const check = () => {
      if (document.visibilityState === 'visible') void onboarding.refreshStep(id);
    };
    // Right after an action on the page (button, form) the result is usually in place within a moment.
    let settle: ReturnType<typeof setTimeout> | undefined;
    const afterAction = () => {
      clearTimeout(settle);
      settle = setTimeout(check, SETTLE_MS);
    };
    check();
    const timer = setInterval(check, POLL_MS);
    window.addEventListener('focus', check);
    document.addEventListener('click', afterAction);
    document.addEventListener('submit', afterAction);
    return () => {
      clearInterval(timer);
      clearTimeout(settle);
      window.removeEventListener('focus', check);
      document.removeEventListener('click', afterAction);
      document.removeEventListener('submit', afterAction);
    };
  });

  function back(): void {
    router.navigate('/installation');
  }
</script>

{#if visible && step}
  <div
    role="region"
    aria-label={ui.bar.label}
    data-testid="setup-bar"
    class="bg-brand-soft border-border sticky top-[60px] z-10 flex flex-wrap items-center justify-between gap-x-4 gap-y-2 rounded-lg border px-4 py-2 text-sm"
  >
    <p class="m-0 flex min-w-0 items-center gap-2 font-medium">
      <span aria-hidden="true" class="text-brand-ink shrink-0"
        ><NavIcon name={finished ? 'check' : 'setup'} size={16} /></span
      >
      <span class="min-w-0"
        >{ui.bar.text
          .replace('{n}', String(index + 1))
          .replace('{m}', String(onboarding.steps.length))
          .replace('{name}', ui.steps[step.id].title)}</span
      >
      <span role="status" class="text-muted-foreground font-normal"
        >{finished ? ui.bar.done : ''}</span
      >
    </p>
    <div class="flex flex-wrap items-center gap-2">
      <Button variant={finished ? 'outline' : 'default'} size="sm" onclick={back}
        >{ui.bar.back}</Button
      >
      {#if finished}
        <Button size="sm" onclick={back}>{next ? ui.bar.next : ui.bar.finish}</Button>
      {/if}
    </div>
  </div>
{/if}
