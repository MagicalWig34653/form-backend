<script lang="ts">
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { router } from '$lib/router.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
</script>

<div class="mx-auto flex max-w-md flex-col items-center gap-4 px-4 py-20 text-center">
  <span
    aria-hidden="true"
    class="bg-muted/60 text-muted-foreground ring-border flex size-14 items-center justify-center rounded-full ring-1"
    ><NavIcon name="search" size={26} /></span
  >
  <h1 id="page-title" tabindex="-1" class="text-2xl font-semibold outline-none">
    {t.notFound.title}
  </h1>
  <p class="text-muted-foreground text-sm">{t.states.notFoundBody}</p>
  <Button onclick={() => router.navigate('/login')}>{t.notFound.back}</Button>
</div>
