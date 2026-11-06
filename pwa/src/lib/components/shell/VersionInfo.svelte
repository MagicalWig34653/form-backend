<script lang="ts">
  import { t } from '$lib/i18n';
  import { Badge } from '$lib/components/ui/badge';
  import pkg from '../../../../package.json';
</script>

<span title={t.shell.versionBody} aria-label={`${t.shell.version} ${pkg.version}`}
  ><Badge>v{pkg.version}</Badge></span
>
