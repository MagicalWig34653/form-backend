<script lang="ts">
  import { confirmAction } from '$lib/confirm.svelte';
  import { adminApi } from '$lib/api';
  import { t } from '$lib/i18n';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import Notice from '$lib/components/admin/Notice.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';

  let {
    tenant,
    form,
    active,
    onchange,
  }: { tenant: string; form: string; active: boolean; onchange: () => void | Promise<void> } =
    $props();
  let busy = $state(false);
  let error = $state('');

  async function toggle(): Promise<void> {
    if (busy) return;
    if (
      active &&
      !(await confirmAction({
        title: t.confirm.pauseFormTitle,
        description: t.confirm.pauseFormBody,
        confirmLabel: t.confirm.pauseForm,
        destructive: true,
      }))
    )
      return;
    busy = true;
    error = '';
    const r = await adminApi.setFormActive(tenant, form, !active);
    busy = false;
    if (r.ok) await onchange();
    else if (!handleSessionError(r.error)) error = t.admin.form.activeFailed;
  }
</script>

<div class="flex flex-wrap items-center gap-3">
  <p class="text-sm" role="status">
    <StatusChip
      tone={active ? 'ok' : 'warn'}
      label={active ? t.admin.form.activeOn : t.admin.form.activeOff}
      pulse={active}
    />
  </p>
  <Button type="button" variant="outline" disabled={busy} onclick={() => void toggle()}
    >{active ? t.admin.form.deactivate : t.admin.form.activate}</Button
  >
</div>
<Notice message={error} kind="error" />
