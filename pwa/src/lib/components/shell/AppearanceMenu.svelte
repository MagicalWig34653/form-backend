<script lang="ts">
  import { t } from '$lib/i18n';
  import {
    theme,
    accents,
    accentIds,
    glowSteps,
    type Mode,
    type GlowStep,
  } from '$lib/theme.svelte';
  import { cn } from '$lib/utils';
  import { Button } from '$lib/components/ui/button';
  import { Switch } from '$lib/components/ui/switch';
  import { Badge } from '$lib/components/ui/badge';
  import { Dialog, DialogTrigger, DialogClose, DialogContent } from '$lib/components/ui/dialog';
  import NavIcon from './NavIcon.svelte';
  const modes: Mode[] = ['light', 'dark', 'system'];
  let preview = $state(true);
</script>

<Dialog>
  <DialogTrigger
    >{#snippet child({ props })}<Button
        {...props}
        variant="ghost"
        size="icon"
        aria-label={t.shell.appearance}><NavIcon name="appearance" size={18} /></Button
      >{/snippet}</DialogTrigger
  >
  <DialogContent
    title={t.shell.appearance}
    description={t.shell.appearanceIntro}
    class="max-h-[calc(100dvh-2rem)] sm:max-w-lg"
  >
    <div class="mr-auto flex w-full flex-col gap-5 text-left">
      <fieldset class="m-0 border-0 p-0">
        <legend class="mb-2 text-sm font-medium">{t.shell.mode}</legend>
        <div class="flex flex-wrap gap-2">
          {#each modes as mode (mode)}<Button
              variant={theme.mode === mode ? 'secondary' : 'outline'}
              aria-pressed={theme.mode === mode}
              onclick={() => theme.setMode(mode)}>{t.shell[mode]}</Button
            >{/each}
        </div>
      </fieldset>
      <fieldset class="m-0 border-0 p-0">
        <legend class="mb-2 text-sm font-medium">{t.shell.accent}</legend>
        <div class="grid grid-cols-5 gap-2 sm:grid-cols-10">
          {#each accentIds as accent (accent)}<button
              type="button"
              aria-pressed={theme.accent === accent}
              aria-label={t.shell.accents[accent]}
              title={t.shell.accents[accent]}
              onclick={() => theme.setAccent(accent)}
              class={cn(
                'ring-offset-background flex size-9 items-center justify-center rounded-full border border-black/10 ring-offset-2 transition-shadow dark:border-white/20',
                theme.accent === accent && 'ring-foreground ring-2',
              )}
              style:background={accents[accent]}
            >
              {#if theme.accent === accent}<span
                  class="text-white mix-blend-difference"
                  aria-hidden="true"><NavIcon name="check" size={16} /></span
                >{/if}
            </button>{/each}
        </div>
      </fieldset>
      <div>
        <label for="glow-step" class="mb-2 flex items-center justify-between text-sm font-medium"
          ><span>{t.shell.glow}</span><span class="text-muted-foreground font-normal"
            >{t.shell.glowSteps[theme.glow]}</span
          ></label
        >
        <input
          id="glow-step"
          type="range"
          min="0"
          max={glowSteps.length - 1}
          step="1"
          value={theme.glow}
          oninput={(e) => theme.setGlow(Number(e.currentTarget.value) as GlowStep)}
          aria-valuetext={t.shell.glowSteps[theme.glow] ?? ''}
          class="accent-primary w-full"
        />
        <p class="text-muted-foreground mt-1 mb-0 text-xs">{t.shell.glowHint}</p>
      </div>
      <div
        class="bg-muted/50 flex flex-wrap items-center gap-3 rounded-lg border p-3"
        aria-hidden="true"
      >
        <Button size="sm" tabindex={-1}>{t.shell.preview}</Button>
        <Button size="sm" variant="outline" tabindex={-1}>{t.shell.preview}</Button>
        <Badge>{t.shell.preview}</Badge>
        <Switch bind:checked={preview} tabindex={-1} />
      </div>
    </div>
    <DialogClose
      >{#snippet child({ props })}<Button {...props} variant="outline">{t.shell.close}</Button
        >{/snippet}</DialogClose
    >
  </DialogContent>
</Dialog>
