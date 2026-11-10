<script lang="ts">
  import RecoveryStep from '$lib/crypto/RecoveryStep.svelte';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import type { PrfResult } from '$lib/api/webauthn';
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import type { AuthApi } from '$lib/api/auth';
  import { authApi } from '$lib/api';
  import { router } from '$lib/router.svelte';
  import { safeNext } from '$lib/routes';
  import { session } from '$lib/session.svelte';
  import { requestAssertion, type PasskeyOutcome } from '$lib/api/webauthn';
  import type { ApiError } from '$lib/api/client';
  import { Button } from '$lib/components/ui/button';
  import { Label } from '$lib/components/ui/label';
  import { Input } from '$lib/components/ui/input';
  import AuthShell from '$lib/components/auth/AuthShell.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import { Dialog, DialogTrigger, DialogClose, DialogContent } from '$lib/components/ui/dialog';

  interface Props {
    api?: AuthApi;
    assertion?: () => Promise<PasskeyOutcome>;
  }
  let { api = authApi, assertion }: Props = $props();

  type Step = 'loading' | 'passkey' | 'password' | 'done' | 'recovery' | 'unavailable';
  let step = $state<Step>('loading');
  let message = $state('');
  let busy = $state(false);
  const c = t.accountsPackage;
  let totpAllowed = $state(false);
  let totpUser = $state('');
  let totpPassword = $state('');
  let totpCode = $state('');
  async function submitTotp(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;
    busy = true;
    message = '';
    const r = await api.totp({ username: totpUser, password: totpPassword, code: totpCode });
    totpPassword = totpCode = '';
    busy = false;
    if (!r.ok) {
      message = describe(r.error);
      return;
    }
    apply(r.data.state);
  }
  let password = $state('');
  let loginPrf: PrfResult | undefined;
  $effect(() => () => {
    loginPrf?.output.fill(0);
    loginPrf = undefined;
  });

  function apply(state: string): void {
    step = state === 'authenticated' ? 'done' : state === 'factor_pending' ? 'password' : 'passkey';
    if (step === 'done') void enter();
  }

  /** Signed in: load the account and continue where the user wanted to go (only local app paths). */
  // Bumped by every sign-in and by logging out: a slow enter() of an earlier state must not touch the page afterwards.
  let flow = 0;
  async function enter(): Promise<void> {
    const mine = ++flow;
    await session.load();
    if (mine !== flow || session.status !== 'ready') return;
    let issue;
    try {
      issue = await keyring.afterLogin(loginPrf);
    } catch {
      /* Access remains locked; the account page offers recovery. */
    } finally {
      loginPrf?.output.fill(0);
      loginPrf = undefined;
    }
    if (mine !== flow) return;
    if (
      keyring.recoveryRequired ||
      issue === 'unsupported' ||
      issue === 'no-account-key' ||
      issue === 'mismatch'
    ) {
      step = 'recovery';
      return;
    }
    continueLogin();
  }
  function continueLogin(): void {
    const next = safeNext(new URLSearchParams(window.location.search).get('next')) ?? '/overview';
    if (next.startsWith('/oauth/authorize?')) window.location.assign(next);
    else router.navigate(next, true);
  }

  function describe(e: ApiError): string {
    if (e.kind === 'http' && e.status === 429)
      return t.login.tooManyAttempts.replace('{seconds}', String(e.retryAfter ?? 60));
    if (e.kind === 'http' && e.status === 401 && e.code === 'unauthenticated')
      return t.login.sessionExpired;
    if (e.kind === 'http' && e.status === 401) return t.login.failed;
    if (e.kind === 'http' && (e.status === 503 || e.status === 500)) return t.login.unavailable;
    return e.message;
  }

  let autoTried = false;
  async function load(): Promise<void> {
    const params = new URLSearchParams(window.location.search);
    step = 'loading';
    message = '';
    if (new URLSearchParams(window.location.search).get('fresh') === '1') {
      await session.load();
      await session.logout();
    }
    const r = await api.session();
    if (!r.ok) {
      step = 'unavailable';
      message = describe(r.error);
      return;
    }
    totpAllowed = r.data.totpAllowed ?? false;
    apply(r.data.state);
    // Confirmation for a sensitive action: ask for the passkey right away (once); on failure the button stays.
    if ((step as Step) === 'passkey' && !autoTried && params.get('reauth') === '1') {
      autoTried = true;
      void startPasskey();
    }
  }

  async function startPasskey(): Promise<void> {
    if (busy) return;
    busy = true;
    message = '';
    try {
      const opts = await api.passkeyOptions();
      if (!opts.ok) {
        message = describe(opts.error);
        if (opts.error.status === 401) await load();
        return;
      }
      const out = await (assertion ? assertion() : requestAssertion(opts.data));
      if (!out.ok) {
        message =
          out.reason === 'cancelled'
            ? t.login.cancelled
            : out.reason === 'unsupported'
              ? t.login.unsupported
              : t.login.failed;
        return;
      }
      loginPrf?.output.fill(0);
      loginPrf = out.prf;
      const v = await api.passkeyVerify(out.body);
      if (!v.ok) {
        loginPrf?.output.fill(0);
        loginPrf = undefined;
        message = describe(v.error);
        return;
      }
      apply(v.data.state);
    } finally {
      busy = false;
    }
  }

  async function submitPassword(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy || !password) return;
    busy = true;
    message = '';
    try {
      const r = await api.secondFactorPassword(password);
      password = '';
      if (!r.ok) {
        message = describe(r.error);
        if (r.error.status === 401 && r.error.code === 'unauthenticated') await load();
        return;
      }
      apply(r.data.state);
    } finally {
      busy = false;
    }
  }

  async function logout(): Promise<void> {
    flow++;
    await api.logout();
    await load();
  }

  onMount(() => void load());
</script>

<AuthShell title={t.login.title} description={t.login.description} intro={t.shell.loginIntro}>
  {#if message}
    <p
      role="alert"
      class="bg-destructive/10 border-destructive/40 flex items-start gap-2 rounded-md border px-3 py-2 text-sm"
    >
      <span aria-hidden="true" class="text-red-700 dark:text-destructive mt-0.5 shrink-0"
        ><NavIcon name="danger" size={16} /></span
      >{message}
    </p>
  {/if}

  {#if step === 'recovery'}
    {#if !keyring.unlocked}<p>{t.recovery.fallback}</p>{/if}
    <RecoveryStep oncomplete={continueLogin} />
    <Button
      variant="outline"
      class="w-full"
      onclick={() => {
        keyring.lock();
        step = 'passkey';
      }}>{t.recovery.other}</Button
    >
    <Button variant="outline" class="w-full" onclick={continueLogin}>{t.recovery.skip}</Button>
  {:else if step === 'loading'}
    <div aria-busy="true" class="flex flex-col gap-3">
      <p role="status" class="text-muted-foreground text-sm">{t.login.loading}</p>
      <Skeleton class="h-10" />
    </div>
  {:else if step === 'unavailable'}
    <Button type="button" onclick={() => void load()}>{t.login.retry}</Button>
  {:else if step === 'passkey'}
    <Button type="button" class="w-full" disabled={busy} onclick={() => void startPasskey()}
      >{t.login.passkeyButton}</Button
    >
    <p class="text-muted-foreground m-0 text-center text-sm">{t.auth.passkeyHint}</p>
  {:else if step === 'password'}
    <form class="flex flex-col gap-5" onsubmit={(e) => void submitPassword(e)}>
      <p class="text-sm font-medium">{t.login.passwordStep}</p>
      <div class="flex flex-col gap-1.5">
        <Label for="password">{t.login.password}</Label>
        <Input
          id="password"
          name="password"
          type="password"
          autocomplete="current-password"
          required
          bind:value={password}
        />
      </div>
      <Button type="submit" class="w-full" disabled={busy}>{t.login.submit}</Button>
    </form>
  {:else}
    <p class="text-emerald-700 dark:text-emerald-400 flex items-center gap-2 font-medium">
      <NavIcon name="check" size={18} />{t.login.done}
    </p>
    <Button type="button" variant="outline" onclick={() => void logout()}>{t.login.logout}</Button>
  {/if}

  {#if totpAllowed && (step === 'passkey' || step === 'password')}
    <details class="rounded-lg border px-4 py-3">
      <summary class="min-h-6 cursor-pointer text-sm font-medium">{c.login}</summary>
      <form onsubmit={(e) => void submitTotp(e)} class="mt-3 flex flex-col gap-3">
        {#if step === 'passkey'}
          <Label for="totp-user">{c.username}</Label><Input
            id="totp-user"
            bind:value={totpUser}
            autocomplete="username"
            required
          />
          <Label for="totp-login-password">{c.password}</Label><Input
            id="totp-login-password"
            type="password"
            bind:value={totpPassword}
            autocomplete="current-password"
            required
          />
        {/if}
        <Label for="totp-login-code">{c.code}</Label><Input
          id="totp-login-code"
          bind:value={totpCode}
          inputmode="numeric"
          pattern={'[0-9]{6}'}
          maxlength={6}
          autocomplete="one-time-code"
          required
        />
        <Button type="submit" disabled={busy}>{c.login}</Button>
      </form>
    </details>
  {/if}

  <Dialog>
    <DialogTrigger>
      {#snippet child({ props })}
        <Button
          {...props}
          type="button"
          variant="ghost"
          class="text-muted-foreground -mb-2 self-center">{t.login.help}</Button
        >
      {/snippet}
    </DialogTrigger>
    <DialogContent title={t.login.helpTitle} description={t.login.helpBody}>
      <DialogClose>
        {#snippet child({ props })}
          <Button {...props} variant="outline">{t.login.close}</Button>
        {/snippet}
      </DialogClose>
    </DialogContent>
  </Dialog>
</AuthShell>
