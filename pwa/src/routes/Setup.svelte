<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { createAuthApi, type AuthApi } from '$lib/api/auth';
  import { createCredential, type RegistrationOutcome } from '$lib/api/webauthn';
  import { Button } from '$lib/components/ui/button';
  import { Label } from '$lib/components/ui/label';
  import { Input } from '$lib/components/ui/input';
  import {
    Card,
    CardHeader,
    CardTitle,
    CardDescription,
    CardContent,
  } from '$lib/components/ui/card';

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

<div class="mb-6 text-center">
  <p class="text-ui-accent-ink mb-3 text-xs font-semibold tracking-widest uppercase">
    {t.shell.secure}
  </p>
  <p class="text-muted-foreground text-sm">{t.shell.setupIntro}</p>
</div>
<Card class="mx-auto w-full max-w-md p-8">
  <CardHeader>
    <CardTitle id="page-title" tabindex={-1}>{t.setup.title}</CardTitle>
    <CardDescription>{t.setup.description}</CardDescription>
  </CardHeader>
  <CardContent>
    <div aria-live="polite" class="min-h-6">
      {#if message}<p role="alert" class="text-destructive text-sm">{message}</p>{/if}
    </div>
    {#if done}
      <p>{t.setup.done}</p>
      {#if secondFactorRequired}<p>{t.setup.passwordRequired}</p>{/if}
      <Button type="button" onclick={() => router.navigate('/login')}>{t.setup.toLogin}</Button>
    {:else if !token}
      <p role="alert" class="text-destructive text-sm">{t.setup.missingToken}</p>
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
        <Button type="submit" disabled={busy}>{t.setup.start}</Button>
      </form>
    {/if}
  </CardContent>
</Card>
