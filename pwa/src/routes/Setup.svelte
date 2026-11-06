<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { createAuthApi, type AuthApi } from '$lib/api/auth';
  import { createCredential, type RegistrationOutcome } from '$lib/api/webauthn';
  import { Button } from '$lib/components/ui/button';
  import { Label } from '$lib/components/ui/label';
  import { Input } from '$lib/components/ui/input';
  import AuthShell from '$lib/components/auth/AuthShell.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  interface Props {
    api?: AuthApi;
    /** Injected in tests; defaults to the browser's authenticator. */
    create?: (opts: Parameters<typeof createCredential>[0]) => Promise<RegistrationOutcome>;
    /** The token comes from the URL fragment (never sent to a server or written to logs). */
    fragment?: () => string;
  }
  let {
    api = createAuthApi(),
    create = createCredential,
    fragment = () => window.location.hash,
  }: Props = $props();

  let token = $state('');
  let label = $state(t.setup.labelDefault);
  let message = $state('');
  let busy = $state(false);
  let done = $state(false);
  let secondFactorRequired = $state(false);

  onMount(() => {
    token = fragment().replace(/^#/, '');
    // Remove the token from the address bar and history entry right away.
    if (token) history.replaceState(null, '', window.location.pathname);
  });

  async function start(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy || !token) return;
    busy = true;
    message = '';
    try {
      const session = await api.session();
      if (!session.ok) return void (message = t.setup.failed);
      secondFactorRequired = session.data.secondFactorRequired ?? true;
      const opts = await api.enrollmentOptions(token);
      if (!opts.ok) return void (message = t.setup.failed);
      const out = await create(opts.data);
      if (!out.ok) {
        message = t.setup[out.reason === 'failed' ? 'failed' : out.reason];
        return;
      }
      const v = await api.enrollmentVerify({
        ...out.body,
        label: label.trim() || t.setup.labelDefault,
        token,
      });
      if (!v.ok) return void (message = t.setup.failed);
      token = '';
      done = true;
    } finally {
      busy = false;
    }
  }
</script>

<AuthShell title={t.setup.title} description={t.setup.description} intro={t.shell.setupIntro}>
  <div class="min-h-6">
    {#if message}
      <p
        role="alert"
        class="bg-danger-soft border-danger/35 flex items-start gap-2 rounded-md border px-3 py-2 text-sm"
      >
        <span aria-hidden="true" class="text-danger mt-0.5 shrink-0"
          ><NavIcon name="danger" size={16} /></span
        >{message}
      </p>
    {/if}
  </div>
  {#if done}
    <p class="text-ok flex items-center gap-2 font-medium">
      <NavIcon name="check" size={18} />{t.setup.done}
    </p>
    {#if secondFactorRequired}<p class="text-sm">{t.setup.passwordRequired}</p>{/if}
    <Button type="button" class="w-full" onclick={() => router.navigate('/login')}
      >{t.setup.toLogin}</Button
    >
  {:else if !token}
    <p
      role="alert"
      class="bg-danger-soft border-danger/35 flex items-start gap-2 rounded-md border px-3 py-2 text-sm"
    >
      <span aria-hidden="true" class="text-danger mt-0.5 shrink-0"
        ><NavIcon name="danger" size={16} /></span
      >{t.setup.missingToken}
    </p>
  {:else}
    <form class="flex flex-col gap-5" onsubmit={(e) => void start(e)}>
      <div class="flex flex-col gap-1.5">
        <Label for="label">{t.setup.label}</Label>
        <Input
          id="label"
          name="label"
          maxlength={120}
          required
          bind:value={label}
          aria-describedby="label-hint"
        />
        <p id="label-hint" class="text-muted-foreground text-sm">{t.setup.labelHint}</p>
      </div>
      <Button type="submit" class="w-full" disabled={busy}>{t.setup.start}</Button>
    </form>
    <p class="text-muted-foreground text-xs leading-[18px]">{t.auth.passkeyNote}</p>
  {/if}
</AuthShell>
