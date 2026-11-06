<script lang="ts">
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { router } from '$lib/router.svelte';
</script>

<div class="mx-auto flex max-w-sm flex-col items-start gap-4">
  <h1 id="page-title" tabindex="-1" class="text-2xl font-semibold">{t.notFound.title}</h1>
  <Button onclick={() => router.navigate('/login')}>{t.notFound.back}</Button>
</div>
