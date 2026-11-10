<script lang="ts">
  import type { Snippet } from 'svelte';
  import { t } from '$lib/i18n';
  import { session } from '$lib/session.svelte';
  import { tenantPath } from '$lib/routes';
  import PageHeader from './PageHeader.svelte';
  import PageTabs, { type PageTab } from './PageTabs.svelte';

  interface Props {
    tenant: string;
    /** Which customer tab is shown. */
    current: 'forms' | 'members';
    description?: string;
    actions?: Snippet;
  }
  let { tenant, current, description, actions }: Props = $props();

  const customer = $derived(session.tenants.find((x) => x.id === tenant));
  // Members are managed with the customer-wide right; without it the tab stays out of the way.
  const canManage = $derived(customer?.permissions.includes('identity.manage') === true);
  const items = $derived<PageTab[]>([
    {
      id: 'forms',
      label: t.shell.forms,
      href: tenantPath(tenant),
      active: current === 'forms',
    },
    ...(canManage || current === 'members'
      ? [
          {
            id: 'members',
            label: t.admin.nav.members,
            href: `${tenantPath(tenant)}/members`,
            active: current === 'members',
          },
        ]
      : []),
  ]);
</script>

<PageHeader
  title={customer?.name ?? t.shell.customer}
  description={description ?? t.lists.customerIntro}
  {actions}
>
  {#snippet tabs()}
    <PageTabs label={t.shell.customerTabs} tabs={items} />
  {/snippet}
</PageHeader>
