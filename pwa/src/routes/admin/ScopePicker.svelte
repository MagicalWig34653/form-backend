<script lang="ts">
  import { loadFailureText } from '$lib/admin/describe';
  import { adminApi } from '$lib/api';
  import { t } from '$lib/i18n';
  import { session } from '$lib/session.svelte';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Select from '$lib/components/admin/Select.svelte';

  let {
    idPrefix,
    tenantId = $bindable(''),
    formId = $bindable(''),
  }: { idPrefix: string; tenantId?: string; formId?: string } = $props();
  const text = t.admin.tokens;

  let forms = $state<{ id: string; name: string }[]>([]);
  let formsFailed = $state<string | undefined>();

  // Customers and forms are picked by name; the ids stay internal.
  $effect(() => {
    const tenant = tenantId;
    forms = [];
    formsFailed = undefined;
    if (!tenant || session.tenants.length === 0) return;
    let active = true;
    void adminApi.forms(tenant).then((r) => {
      if (!active) return;
      if (r.ok) forms = r.data.items.map((f) => ({ id: f.id, name: f.name }));
      else formsFailed = loadFailureText(r.error, text.formsFailed);
    });
    return () => {
      active = false;
    };
  });
</script>

{#if session.tenants.length > 0}
  <Row id={`${idPrefix}-tenant`} label={text.tenantPick} required>
    <Select id={`${idPrefix}-tenant`} bind:value={tenantId} required onchange={() => (formId = '')}>
      <option value="" disabled>{text.tenantChoose}</option>
      {#each session.tenants as c (c.id)}<option value={c.id}>{c.name}</option>{/each}
    </Select>
  </Row>
  <Row id={`${idPrefix}-form`} optional label={text.formPick} error={formsFailed}>
    <Select id={`${idPrefix}-form`} bind:value={formId} disabled={!tenantId}>
      <option value="">{text.allForms}</option>
      {#each forms as f (f.id)}<option value={f.id}>{f.name}</option>{/each}
    </Select>
  </Row>
{:else}
  <Row id={`${idPrefix}-tenant`} label={text.tenant}
    ><Input id={`${idPrefix}-tenant`} bind:value={tenantId} required /></Row
  >
  <Row id={`${idPrefix}-form`} optional label={text.form}
    ><Input id={`${idPrefix}-form`} bind:value={formId} /></Row
  >
{/if}
