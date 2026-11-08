<script lang="ts">
  import { onMount } from 'svelte';
  import { http } from '$lib/api';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';

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
    if (busy || !window.confirm(text.confirmDelete.replace('{url}', hook.targetURL))) return;
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
  <p class="text-muted-foreground max-w-prose text-sm">{text.intro}</p>
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
  <form class="flex flex-wrap items-end gap-2" onsubmit={create}>
    <label class="flex min-w-0 flex-1 flex-col gap-1 text-sm">
      {text.target}
      <Input type="url" bind:value={target} placeholder="https://example.org/hook" required />
    </label>
    <Button type="submit" disabled={busy}>{text.add}</Button>
  </form>
  {#if loading}<p role="status">{t.admin.loading}</p>
  {:else if items.length === 0}<p class="text-muted-foreground text-sm">{text.empty}</p>
  {:else}
    <ul class="divide-border bg-card ring-1 ring-foreground/10 rounded-xl divide-y">
      {#each items as hook (hook.id)}
        <li class="flex flex-wrap items-center gap-3 p-3 text-sm">
          <span class="min-w-0 flex-1 break-all">{hook.targetURL}</span>
          <span class="text-muted-foreground">{hook.active ? text.active : text.inactive}</span>
          <Button variant="outline" disabled={busy} onclick={() => void toggle(hook)}>
            {hook.active ? text.disable : text.enable}
          </Button>
          <Button variant="ghost" disabled={busy} onclick={() => void remove(hook)}>
            {text.remove}
          </Button>
        </li>
      {/each}
    </ul>
  {/if}
</section>
