<script lang="ts">
  import { t } from '$lib/i18n';
  import { theme, accents, type Mode, type Accent } from '$lib/theme.svelte';
  import { effects, effectLevels } from '$lib/effects.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Dialog, DialogTrigger, DialogClose, DialogContent } from '$lib/components/ui/dialog';
</script>

<Button
  variant="ghost"
  onclick={() => theme.toggle()}
  aria-label={theme.dark ? t.theme.toLight : t.theme.toDark}
  ><span aria-hidden="true">{theme.dark ? '☀' : '☾'}</span></Button
>
<Dialog>
  <DialogTrigger
    >{#snippet child({ props })}<Button {...props} variant="ghost" aria-label={t.shell.appearance}
        ><span aria-hidden="true">◐</span></Button
      >{/snippet}</DialogTrigger
  >
  <DialogContent title={t.shell.appearance} description={t.shell.mode}>
    <div class="mr-auto flex flex-col gap-5">
      <fieldset>
        <legend class="mb-2 text-sm font-medium">{t.shell.mode}</legend>
        <div class="flex flex-wrap gap-2">
          {#each ['light', 'dark', 'system'] as mode (mode)}<Button
              variant={theme.mode === mode ? 'secondary' : 'outline'}
              aria-pressed={theme.mode === mode}
              onclick={() => theme.setMode(mode as Mode)}>{t.shell[mode as Mode]}</Button
            >{/each}
        </div>
      </fieldset>
      <fieldset>
        <legend class="mb-2 text-sm font-medium">{t.shell.accent}</legend>
        <div class="flex flex-wrap gap-2">
          {#each Object.keys(accents) as accent (accent)}<Button
              variant="outline"
              aria-pressed={theme.accent === accent}
              onclick={() => theme.setAccent(accent as Accent)}
              ><span class="size-3 rounded-full" style:background={accents[accent as Accent]}
              ></span>{t.shell.accents[accent as Accent]}</Button
            >{/each}
        </div>
      </fieldset>
      <fieldset>
        <legend class="mb-2 text-sm font-medium">{t.shell.effects}</legend>
        <div class="flex flex-wrap gap-2">
          {#each effectLevels as level (level)}<Button
              variant={effects.level === level ? 'secondary' : 'outline'}
              aria-pressed={effects.level === level}
              onclick={() => effects.setLevel(level)}>{t.shell.effectLevels[level]}</Button
            >{/each}
        </div>
        <p class="text-muted-foreground mt-2 text-xs">
          {effects.forcedOff ? t.shell.effectsForcedOff : t.shell.effectsHint}
        </p>
      </fieldset>
      <DialogClose
        >{#snippet child({ props })}<Button {...props} variant="outline">{t.shell.close}</Button
          >{/snippet}</DialogClose
      >
    </div>
  </DialogContent>
</Dialog>
