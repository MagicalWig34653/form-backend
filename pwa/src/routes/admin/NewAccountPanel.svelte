<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { authApi, adminApi } from '$lib/api';
  import { router } from '$lib/router.svelte';
  import { needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';

  let { oncreated, onclose }: { oncreated?: () => void; onclose?: () => void } = $props();
  const a = t.admin.account;
  let username = $state('');
  let password = $state('');
  let link = $state('');
  let message = $state('');
  let busy = $state(false);
  let secondFactorRequired = $state(false);

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;
    busy = true;
    message = link = '';
    const r = await adminApi.createAccount(username.trim(), password);
    busy = false;
    password = '';
    if (!r.ok) {
      if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(r.error)) message = r.error.status === 409 ? a.exists : a.failed;
      return;
    }
    username = '';
    link = r.data.setupLink;
    oncreated?.();
  }

  // The one-time link must not outlive this view.
  $effect(() => () => {
    link = '';
  });
  onMount(() => {
    void authApi.session().then((policy) => {
      if (policy.ok) secondFactorRequired = policy.data.secondFactorRequired ?? true;
    });
  });
</script>

<Panel title={a.create} description={a.createIntro}>
  <form onsubmit={(e) => void create(e)} class="flex max-w-[560px] flex-col gap-4">
    <Row id="new-username" label={a.username}>
      <Input
        id="new-username"
        bind:value={username}
        required
        autocomplete="off"
        spellcheck={false}
      />
    </Row>
    {#if secondFactorRequired}
      <Row id="new-password" label={a.password}>
        <Input
          id="new-password"
          type="password"
          bind:value={password}
          required
          minlength={12}
          autocomplete="new-password"
        />
      </Row>
    {/if}
    <div class="flex flex-wrap gap-2">
      <Button type="submit" disabled={busy}>{a.createBtn}</Button>
      {#if onclose}<Button type="button" variant="ghost" onclick={onclose}
          >{t.accountsPackage.closeCreate}</Button
        >{/if}
    </div>
  </form>
  {#if link}
    <div role="group" class="bg-muted/60 mt-4 max-w-prose rounded-md p-3">
      <p class="text-sm font-medium">{a.link}</p>
      <p class="my-2 font-mono text-sm break-all select-all" data-testid="setup-link">{link}</p>
    </div>
  {/if}
  <Notice {message} />
</Panel>
