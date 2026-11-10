<script lang="ts">
  import { confirmAction } from '$lib/confirm.svelte';
  import { onMount } from 'svelte';
  import { http } from '$lib/api';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';

  interface Hook {
    id: string;
    targetURL: string;
    publicKey: string;
    createdAt: string;
    active: boolean;
    privateKey?: string | null;
  }
  let { tenant, form }: { tenant: string; form: string } = $props();
  const text = t.webhooks;
  const base = $derived(`/tenants/${tenant}/forms/${form}/webhooks`);
  let items = $state<Hook[]>([]);
  let loading = $state(true);
  let busy = $state(false);
  let error = $state('');
  let target = $state('');
  /** The private signing key is shown exactly once, directly after creation. */
  let created = $state<Hook | null>(null);

  async function failure(e: Parameters<typeof describeError>[0]) {
    if (needsFreshLogin(e)) await reauthenticate(window.location.pathname);
    else if (!handleSessionError(e)) error = describeError(e);
  }
  async function load() {
    loading = true;
    const r = await http.request<{ items: Hook[] }>('GET', base);
    loading = false;
    if (r.ok) items = r.data.items;
    else await failure(r.error);
  }
  async function create(e: SubmitEvent) {
    e.preventDefault();
    if (busy) return;
    busy = true;
    error = '';
    const r = await http.request<Hook>('POST', base, { body: { targetURL: target.trim() } });
    if (r.ok) {
      created = r.data;
      target = '';
      await load();
    } else await failure(r.error);
    busy = false;
  }
  async function toggle(hook: Hook) {
    if (busy) return;
    busy = true;
    error = '';
    const r = await http.request('PUT', `${base}/${hook.id}`, { body: { active: !hook.active } });
    if (r.ok) await load();
    else await failure(r.error);
    busy = false;
  }
  async function remove(hook: Hook) {
    if (busy) return;
    if (
      !(await confirmAction({
        title: t.confirm.deleteWebhookTitle,
        description: t.confirm.deleteWebhookBody.replace('{url}', hook.targetURL),
        confirmLabel: t.confirm.deleteWebhook,
        destructive: true,
      }))
    )
      return;
    busy = true;
    error = '';
    const r = await http.request('DELETE', `${base}/${hook.id}`);
    if (r.ok) await load();
    else await failure(r.error);
    busy = false;
  }
  onMount(() => void load());
</script>

<section class="space-y-4" aria-busy={loading || busy}>
  {#if error}<p role="alert" class="text-red-700 dark:text-destructive text-sm">{error}</p>{/if}
  {#if created?.privateKey}
    <div
      role="status"
      class="border-emerald-500/40 bg-emerald-500/10 space-y-2 rounded-md border p-4 text-sm"
    >
      <p class="font-medium">{text.keyOnce}</p>
      <code class="block break-all select-all">{created.privateKey}</code>
      <Button variant="outline" onclick={() => (created = null)}>{text.keySaved}</Button>
    </div>
  {/if}
  {#if loading}<p role="status" class="text-muted-foreground text-sm">{t.admin.loading}</p>
  {:else if items.length === 0}
    <EmptyState title={text.empty} description={text.emptyHint} icon="webhook" />
  {:else}
    <ul class="divide-border m-0 list-none divide-y p-0">
      {#each items as hook (hook.id)}
        <li class="flex flex-wrap items-center gap-3 py-3 text-sm">
          <span class="min-w-0 flex-1 break-all">{hook.targetURL}</span>
          <StatusChip
            tone={hook.active ? 'ok' : 'idle'}
            label={hook.active ? text.active : text.inactive}
          />
          <Button variant="outline" disabled={busy} onclick={() => void toggle(hook)}>
            {hook.active ? text.disable : text.enable}
          </Button>
          <Button variant="destructive" disabled={busy} onclick={() => void remove(hook)}>
            {text.remove}
          </Button>
        </li>
      {/each}
    </ul>
  {/if}
  <form class="border-border flex flex-wrap items-start gap-2 border-t pt-4" onsubmit={create}>
    <div class="flex min-w-0 flex-1 basis-64 flex-col gap-1">
      <label for="hook-target" class="text-sm font-medium">{text.target}</label>
      <Input
        id="hook-target"
        type="url"
        bind:value={target}
        required
        aria-describedby="hook-example"
      />
      <span id="hook-example" class="text-muted-foreground text-xs">{text.example}</span>
    </div>
    <Button type="submit" disabled={busy} class="max-sm:w-full sm:mt-6">{text.add}</Button>
  </form>
</section>
