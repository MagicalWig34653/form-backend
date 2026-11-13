<script lang="ts">
  import { t } from '$lib/i18n';
  import Banner from '$lib/components/admin/Banner.svelte';
</script>

<Banner tone="info" title={t.prfHint.title}>
  <span data-testid="prf-hint">{t.prfHint.reason} {t.prfHint.way}</span>
</Banner>
