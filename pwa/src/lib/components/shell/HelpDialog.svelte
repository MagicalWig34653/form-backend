<script lang="ts">
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { Dialog, DialogTrigger, DialogClose, DialogContent } from '$lib/components/ui/dialog';
  import NavIcon from './NavIcon.svelte';
  const docsUrl =
    import.meta.env.VITE_DOCS_URL ?? 'https://magicalwig34653.github.io/form-backend/';
</script>

<Dialog>
  <DialogTrigger
    >{#snippet child({ props })}<button
        {...props}
        type="button"
        class="text-muted-foreground hover:bg-surface-sunken hover:text-foreground flex min-h-11 w-full items-center gap-3 text-left rounded-[var(--r-ctl)] px-3 text-[length:var(--fs-body)] font-medium transition-colors md:min-h-9"
        ><span aria-hidden="true" class="flex w-5 justify-center"><NavIcon name="help" /></span>{t
          .shell.help}</button
      >{/snippet}</DialogTrigger
  >
  <DialogContent title={t.shell.help} description={t.shell.helpBody}>
    <a href={docsUrl} target="_blank" rel="noopener noreferrer" class="mr-auto text-sm underline"
      >{t.app.docs}</a
    >
    <DialogClose
      >{#snippet child({ props })}<Button {...props} variant="outline">{t.shell.close}</Button
        >{/snippet}</DialogClose
    >
  </DialogContent>
</Dialog>
