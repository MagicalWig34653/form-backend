<script lang="ts">
  import AccessStatus from './AccessStatus.svelte';
  import { accessAutomation } from '$lib/crypto/automation.svelte';
  import { onMount, onDestroy } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi, http } from '$lib/api';
  import { session } from '$lib/session.svelte';
  import { Table } from '$lib/components/ui/table';
  import { Select } from '$lib/components/ui/select';
  import { Badge } from '$lib/components/ui/badge';
  import type { FormListItem } from '$lib/api/admin';
  import { router } from '$lib/router.svelte';
  import { formPath } from '$lib/routes';
  import { describeError } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';

  let { tenant }: { tenant: string } = $props();

  let items = $state<FormListItem[] | null>(null);
  let query = $state('');
  let status = $state('');
  let loading = $state(true);
  let slow = $state(false);
  let loadError = $state('');
  let nextCursor = $state<string | null>(null);
  let showCreate = $state(false);
  let controller: AbortController | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const canCreate = $derived(
    session.tenants.find((t) => t.id === tenant)?.permissions.includes('form.create') ?? false,
  );
  const visible = $derived(
    (items ?? []).filter(
      (f) =>
        f.name.toLocaleLowerCase('de').includes(query.trim().toLocaleLowerCase('de')) &&
        (!status ||
          (status === 'unpublished'
            ? !f.currentReleaseId
            : status === 'active'
              ? f.active
              : !f.active)),
    ),
  );
  let name = $state('');
  let busy = $state(false);
  let message = $state('');

  async function load(): Promise<void> {
    controller?.abort();
    clearTimeout(timer);
    const request = new AbortController();
    controller = request;
    loading = true;
    slow = false;
    loadError = '';
    timer = setTimeout(() => {
      slow = true;
    }, 3000);
    const r = nextCursor
      ? await http.request<{ items: FormListItem[]; nextCursor: string | null }>(
          'GET',
          `/tenants/${encodeURIComponent(tenant)}/forms?limit=100&cursor=${encodeURIComponent(nextCursor)}`,
          { signal: request.signal },
        )
      : await adminApi.forms(tenant, request.signal);
    if (request.signal.aborted) return;
    clearTimeout(timer);
    loading = false;
    if (r.ok) {
      items = nextCursor
        ? [...(items ?? []), ...r.data.items.filter((f) => !items?.some((old) => old.id === f.id))]
        : r.data.items;
      nextCursor = r.data.nextCursor;
    } else if (!handleSessionError(r.error)) {
      loadError =
        r.error.status === 403
          ? t.lists.forbidden
          : r.error.status === 404
            ? t.lists.notFound
            : t.lists.failed;
    }
  }

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy || !canCreate || !name.trim()) return;
    busy = true;
    message = '';
    try {
      await accessAutomation.ensureCustomer(tenant);
    } catch (error) {
      message = (error as Error).message;
      busy = false;
      return;
    }
    const r = await adminApi.createForm(tenant, name.trim());
    busy = false;
    if (!r.ok) {
      if (!handleSessionError(r.error)) message = describeError(r.error);
      return;
    }
    router.navigate(formPath(tenant, r.data.id));
  }

  onMount(() => void load());
  onDestroy(() => {
    controller?.abort();
    clearTimeout(timer);
  });
</script>

<section class="flex min-w-0 flex-col gap-4">
  <AccessStatus />
  <div class="flex flex-wrap items-center justify-between gap-3">
    <div>
      <h1 id="page-title" tabindex="-1" class="text-2xl font-semibold">{t.admin.forms.title}</h1>
      <p class="text-muted-foreground text-sm">
        {session.tenants.find((c) => c.id === tenant)?.name} · {t.lists.formsIntro}
      </p>
    </div>
    {#if canCreate}<Button
        onclick={() => {
          showCreate = true;
        }}>{t.lists.createForm}</Button
      >{/if}
  </div>
  <div class="grid gap-3 sm:grid-cols-2">
    <Row id="forms-search" label={t.lists.searchForms}
      ><Input id="forms-search" type="search" bind:value={query} /></Row
    >
    <Row id="forms-status" label={t.lists.status}
      ><Select id="forms-status" bind:value={status}>
        <option value="">{t.lists.all}</option><option value="active">{t.lists.active}</option
        ><option value="inactive">{t.lists.inactive}</option><option value="unpublished"
          >{t.lists.unpublished}</option
        >
      </Select></Row
    >
  </div>
  <div role="status" class="text-muted-foreground text-sm">
    {loading ? (slow ? t.lists.slow : t.admin.loading) : ''}
  </div>
  {#if loadError}<p role="alert">{loadError}</p>
    <div><Button variant="outline" onclick={() => void load()}>{t.lists.retry}</Button></div>{/if}
  <div aria-busy={loading} class="bg-card border-border min-h-48 rounded-xl border">
    {#if items === null && loading}
      <div class="flex flex-col gap-4 p-4" aria-hidden="true">
        {#each [1, 2, 3] as n (n)}<div class="bg-muted h-10 rounded"></div>{/each}
      </div>
    {:else if items !== null && items.length === 0}
      <p class="p-6">{t.admin.forms.none}</p>
    {:else if items !== null && visible.length === 0}
      <div class="p-6">
        <p>{t.lists.noMatches}</p>
        <Button
          variant="outline"
          onclick={() => {
            query = '';
            status = '';
          }}>{t.lists.reset}</Button
        >
      </div>
    {:else if items !== null}
      <Table
        ><caption class="sr-only">{t.admin.forms.title}</caption>
        <thead
          ><tr
            >{#each [t.lists.name, t.lists.publication, t.lists.draft, t.lists.tasks] as heading (heading)}<th
                scope="col">{heading}</th
              >{/each}</tr
          ></thead
        >
        <tbody
          >{#each visible as f (f.id)}<tr>
              <th scope="row"
                ><a
                  class="font-medium underline underline-offset-4"
                  href={formPath(tenant, f.id)}
                  onclick={(e) => {
                    e.preventDefault();
                    router.navigate(formPath(tenant, f.id));
                  }}>{f.name}</a
                >
                <div class="mt-1">
                  <Badge>{f.active ? t.lists.active : t.lists.inactive}</Badge>
                </div></th
              >
              <td>{f.currentReleaseId ? t.lists.published : t.lists.unpublished}</td><td
                >{t.lists.unknown}</td
              >
              <td
                ><a
                  class="underline underline-offset-4"
                  aria-label={`${t.lists.openOverview}: ${f.name}`}
                  href={formPath(tenant, f.id)}
                  onclick={(e) => {
                    e.preventDefault();
                    router.navigate(formPath(tenant, f.id));
                  }}>{t.lists.openOverview}</a
                ></td
              >
            </tr>{/each}</tbody
        >
      </Table>
    {/if}
  </div>
  <p class="text-muted-foreground text-sm">{t.lists.metadataHint}</p>
  {#if nextCursor}<p class="text-muted-foreground text-sm">{t.lists.partial}</p>
    <div>
      <Button variant="outline" disabled={loading} onclick={() => void load()}
        >{t.lists.more}</Button
      >
    </div>{/if}
  {#if canCreate && showCreate}
    <form
      onsubmit={(e) => void create(e)}
      class="bg-card border-border flex max-w-xl flex-col gap-3 rounded-xl border p-5"
      aria-busy={busy}
    >
      <h2 class="text-lg font-medium">{t.lists.createForm}</h2>
      <p class="text-muted-foreground text-sm">{t.lists.guide}</p>
      <Row id="form-name" label={t.admin.forms.name}
        ><Input id="form-name" bind:value={name} required maxlength={190} autocomplete="off" /></Row
      >
      <Notice {message} />
      <div><Button type="submit" disabled={busy}>{t.lists.createForm}</Button></div>
    </form>
  {/if}
</section>
