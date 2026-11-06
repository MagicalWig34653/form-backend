<script lang="ts">
  import Suche from './Suche.svelte';
  import SealedExport from './SealedExport.svelte';
  import { Dialog, DialogTrigger, DialogClose, DialogContent } from '$lib/components/ui/dialog';
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import { leaves, safeFileName } from '$lib/entries/files';
  import type { EntryItem, MailDelivery } from '$lib/api/admin';
  import { router } from '$lib/router.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { PackageError, contentKey, openPackage, toBase64Url } from '$lib/crypto/packageV2';
  import { rewrapPackage } from '$lib/crypto/rewrap';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';

  let { tenant, form }: { tenant: string; form: string } = $props();

  let items = $state<EntryItem[]>([]);
  let next = $state<string | null>(null);
  let loaded = $state(false);
  let message = $state('');
  let busy = $state(false);

  const ui = t.admin.entriesPage;
  let loading = $state(false);
  let slow = $state(false);
  let query = $state('');
  let protection = $state('all');
  let selected = $state<string[]>([]);
  let deleteIds = $state<string[]>([]);
  let deleteOpen = $state(false);
  const visible = $derived(
    items.filter(
      (entry) =>
        (protection === 'all' || entry.held === (protection === 'held')) &&
        (!query || (entry.receivedAt ?? '').includes(query)),
    ),
  );

  let openId = $state('');
  let shown = $state<{ fields: [string, string][]; files: [string, string][] } | null>(null);
  let openMessage = $state('');
  let attachments = $state<{ name: string; size: number; sha256: string }[]>([]);
  let openWire = '';
  let openKey: Uint8Array | null = null;
  let deliveries = $state<MailDelivery[]>([]);
  let confirmed = $state<Record<string, boolean>>({});
  let resendMessage = $state('');
  let cancelHold: (() => void) | undefined;
  let epoch = 0; // bumped by lock(): a decryption that finishes afterwards is discarded

  async function load(cursor?: string): Promise<void> {
    if (loading) return;
    loading = true;
    message = '';
    const timer = setTimeout(() => (slow = true), 1500);
    const r = await adminApi.entries(tenant, form, cursor);
    if (!r.ok) {
      if (!handleSessionError(r.error)) message = describeError(r.error);
    } else {
      items = [...items, ...r.data.items];
      next = r.data.nextCursor;
    }
    clearTimeout(timer);
    slow = false;
    loading = false;
    loaded = true;
  }

  async function resend(entryId: string, d: MailDelivery): Promise<void> {
    if (busy || !openKey) return;
    busy = true;
    resendMessage = '';
    const mine = epoch;
    const cek = await contentKey(openWire, openKey).catch(() => null);
    if (!cek || mine !== epoch) {
      cek?.fill(0);
      busy = false;
      resendMessage = t.admin.entries.resendFailed;
      return;
    }
    const r = await adminApi.resend(tenant, form, entryId, {
      deliveryId: d.id,
      contentKey: toBase64Url(cek),
      confirmUncertain: d.state === 'uncertain' ? true : undefined,
      expectedFence: d.state === 'uncertain' ? d.fence : undefined,
    });
    cek.fill(0);
    busy = false;
    if (mine !== epoch) return;
    if (!r.ok) {
      if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(r.error)) resendMessage = t.admin.entries.resendFailed;
      return;
    }
    resendMessage = t.admin.entries.resent;
    const list = await adminApi.deliveries(tenant, form);
    if (list.ok) deliveries = list.data.items.filter((x) => x.submissionId === entryId);
  }

  function lock(): void {
    epoch++;
    cancelHold?.();
    openWire = '';
    attachments = [];
    openKey = null;
    deliveries = [];
    shown = null;
    openId = '';
  }

  function flatten(value: unknown, prefix = ''): [string, string][] {
    if (value === null || typeof value !== 'object') return [[prefix, String(value)]];
    return Object.entries(value as Record<string, unknown>).flatMap(([k, v]) =>
      flatten(v, prefix ? `${prefix}[${k}]` : k),
    );
  }

  async function download(entryId: string, n: number): Promise<void> {
    const key = openKey;
    const meta = attachments[n];
    if (busy || !key || !meta) return;
    busy = true;
    openMessage = '';
    const mine = epoch;
    try {
      const r = await adminApi.attachment(tenant, form, entryId, n);
      if (!r.ok) {
        if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
        if (!handleSessionError(r.error)) openMessage = describeError(r.error);
        return;
      }
      const bytes = await openPackage(r.data.package, key);
      // the signed metadata pins the content: a swapped or damaged attachment is refused
      const digest = new Uint8Array(
        await crypto.subtle.digest('SHA-256', bytes.slice().buffer as ArrayBuffer),
      );
      const hex = [...digest].map((b) => b.toString(16).padStart(2, '0')).join('');
      if (hex !== meta.sha256 || mine !== epoch) {
        openMessage = t.admin.entries.downloadFailed;
        return;
      }
      const url = URL.createObjectURL(
        new Blob([bytes.slice().buffer as ArrayBuffer], { type: 'application/octet-stream' }),
      );
      const a = document.createElement('a');
      a.href = url;
      a.download = safeFileName(meta.name);
      a.click();
      URL.revokeObjectURL(url);
    } catch {
      openMessage = t.admin.entries.downloadFailed;
    } finally {
      busy = false;
    }
  }

  async function view(entry: EntryItem): Promise<void> {
    const usable = keyring.dataKey(entry.keyId ?? '');
    if (busy || !usable) return;
    const key = usable;
    const mine = epoch;
    busy = true;
    openMessage = '';
    shown = null;
    deliveries = [];
    resendMessage = '';
    openId = entry.id;
    const r = await adminApi.ciphertext(tenant, form, entry.id);
    if (!r.ok) {
      busy = false;
      if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(r.error)) openMessage = describeError(r.error);
      return;
    }
    try {
      const plain = await openPackage(r.data.package, key);
      if (mine !== epoch) return void (busy = false);
      const doc = JSON.parse(new TextDecoder().decode(plain)) as {
        fields?: unknown;
        files?: unknown;
      };
      shown = { fields: flatten(doc.fields ?? {}), files: flatten(doc.files ?? {}) };
      attachments = leaves(doc.files ?? {});
      openWire = r.data.package;
      openKey = key;
      const d = await adminApi.deliveries(tenant, form);
      if (d.ok) deliveries = d.data.items.filter((x) => x.submissionId === entry.id);
    } catch (e) {
      openMessage =
        e instanceof PackageError && e.message === 'keyMismatch'
          ? t.admin.entries.wrongKey.replace('{kid}', r.data.keyId)
          : t.admin.entries.failed;
    }
    busy = false;
  }

  // --- deletion, hold, retention, export (ADR 0012) ---
  let actionMessage = $state('');
  let actionKind = $state<'ok' | 'error'>('error');
  let retentionInput = $state('');
  let retentionMessage = $state('');

  async function toggleHold(entry: EntryItem): Promise<void> {
    if (busy) return;
    busy = true;
    actionMessage = '';
    const mine = epoch;
    const operation = keyring.operation();
    cancelHold = () => operation.dispose();
    try {
      const list = await adminApi.holdObjects(tenant, form, entry.id);
      operation.check();
      if (mine !== epoch) throw new Error(t.rotation.noAccess);
      if (!list.ok) throw new Error(describeError(list.error));
      const objects = [];
      for (const object of list.data.items) {
        let replacementPackage: string | undefined;
        if (!entry.held && object.wrapKind === 'hpke') {
          const usable = keyring.dataKey(object.kid);
          if (!usable) throw new Error(t.rotation.noAccess);
          replacementPackage = await rewrapPackage(
            object.package,
            usable,
            {
              wrap: 'sym',
              secret: usable,
            },
            undefined,
            operation,
          );
          operation.check();
          if (mine !== epoch) throw new Error(t.rotation.noAccess);
        }
        objects.push({
          objectId: object.id,
          expectedRevision: object.revision,
          expectedSha256: object.ciphertext_sha256,
          sourceGenerationId: object.sourceGenerationId,
          ...(replacementPackage ? { replacementPackage } : {}),
        });
      }
      operation.check();
      if (mine !== epoch) throw new Error(t.rotation.noAccess);
      const r = await adminApi.setHold(tenant, form, entry.id, !entry.held, objects);
      if (!r.ok) {
        if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
        if (!handleSessionError(r.error)) actionMessage = describeError(r.error);
        return;
      }
      items = items.map((x) => (x.id === entry.id ? { ...x, held: r.data.held } : x));
    } catch (error) {
      actionMessage = error instanceof Error ? error.message : t.admin.entries.holdFailed;
    } finally {
      operation.dispose();
      cancelHold = undefined;
      busy = false;
    }
  }

  async function holdSelection(held: boolean): Promise<void> {
    if (busy) return;
    if (!held && !confirm(ui.unholdWarning)) return;
    actionKind = 'error';
    for (const entry of items.filter((item) => selected.includes(item.id) && item.held !== held)) {
      await toggleHold(entry);
      if (actionMessage) break;
    }
  }

  async function remove(): Promise<void> {
    if (busy) return;
    busy = true;
    actionMessage = '';
    actionKind = 'error';
    const ids = [...deleteIds];
    deleteOpen = false;
    const r = await adminApi.deleteEntries(tenant, form, ids);
    busy = false;
    if (!r.ok) {
      if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(r.error)) actionMessage = describeError(r.error);
      return;
    }
    // The transport's older type omits pending; only confirmed IDs count as deleted.
    const pending = (r.data as typeof r.data & { pending?: string[] }).pending ?? [];
    const failed = ids.filter(
      (id) => ![...r.data.deleted, ...r.data.held, ...r.data.missing, ...pending].includes(id),
    );
    if (r.data.deleted.includes(openId)) lock();
    items = items.filter((x) => !r.data.deleted.includes(x.id));
    selected = selected.filter((id) => !r.data.deleted.includes(id));
    actionKind = 'ok';
    actionMessage = ui.deleteResult
      .replace('{deleted}', String(r.data.deleted.length))
      .replace('{held}', String(r.data.held.length))
      .replace('{failed}', String(failed.length + r.data.missing.length))
      .replace('{pending}', String(pending.length));
    if (pending.length) actionMessage += ' ' + ui.deletePending;
  }

  async function loadRetention(): Promise<void> {
    const r = await adminApi.retention(tenant, form);
    if (r.ok) retentionInput = r.data.days === null ? '' : String(r.data.days);
    else if (!handleSessionError(r.error)) retentionMessage = describeError(r.error);
  }

  async function saveRetention(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;
    const text = String(retentionInput ?? '').trim();
    const days = text === '' ? null : Number(text);
    if (days !== null && (!Number.isInteger(days) || days < 1 || days > 3650)) {
      retentionMessage = t.admin.entries.retentionFailed;
      return;
    }
    busy = true;
    retentionMessage = '';
    const r = await adminApi.setRetention(tenant, form, days);
    busy = false;
    if (!r.ok) {
      if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(r.error)) retentionMessage = describeError(r.error);
      return;
    }
    retentionMessage = t.admin.entries.retentionSaved;
  }

  // Decrypted content and the key must not outlive the page view.
  $effect(() => () => lock());

  onMount(() => {
    void load();
    void loadRetention();
    return keyring.onLock(lock);
  });
</script>

<Dialog bind:open={deleteOpen}>
  <header class="flex flex-wrap items-center justify-between gap-4">
    <div>
      <h2 class="text-xl font-semibold">{t.admin.entries.title}</h2>
      <p class="text-muted-foreground max-w-prose text-sm">{t.admin.entries.intro}</p>
    </div>
    {#key tenant + form}<SealedExport {tenant} {form} />{/key}
  </header>
  {#key tenant + form}<Suche
      {tenant}
      {form}
      onDeleted={(ids) => {
        items = items.filter((item) => !ids.includes(item.id));
        lock();
      }}
    />{/key}
  <section
    class="bg-card min-w-0 space-y-4 rounded-xl border p-4 sm:p-6"
    aria-label={ui.list}
    aria-busy={loading}
  >
    <details>
      <summary class="min-h-11 cursor-pointer py-3 font-medium">{ui.filters}</summary>
      <div class="grid gap-3 sm:grid-cols-2">
        <Row id="entry-search" label={ui.search}
          ><Input id="entry-search" type="search" bind:value={query} /></Row
        >
        <Row id="entry-protection" label={ui.protection}
          ><select
            id="entry-protection"
            class="bg-background min-h-11 w-full rounded-md border px-3"
            bind:value={protection}
          >
            <option value="all">{ui.all}</option><option value="held">{ui.held}</option><option
              value="free">{ui.free}</option
            >
          </select></Row
        >
      </div>
      <p class="text-muted-foreground text-sm">{ui.filterHint}</p>
    </details>
    <Notice {message} />
    {#if message}<Button
        disabled={loading}
        variant="outline"
        onclick={() => void load(next ?? undefined)}>{t.admin.retry}</Button
      >{/if}
    {#if loading}<p role="status">{slow ? ui.slow : t.admin.loading}</p>
      <div class="bg-muted h-20 rounded-md" aria-hidden="true"></div>{/if}
    {#if loaded && !message && items.length === 0}<p>{t.admin.entries.none}</p>
    {:else if loaded && visible.length === 0 && items.length > 0}<p>{ui.filteredEmpty}</p>{/if}
    {#if selected.length}<div class="flex flex-wrap items-center gap-3">
        <p role="status">{ui.selected.replace('{n}', String(selected.length))}</p>
        <Button
          class="min-h-11"
          variant="outline"
          disabled={busy}
          onclick={() => void holdSelection(true)}>{t.admin.entries.hold}</Button
        >
        <Button
          class="min-h-11"
          variant="outline"
          disabled={busy}
          onclick={() => void holdSelection(false)}>{t.admin.entries.unhold}</Button
        >
        <DialogTrigger
          class="min-h-11 rounded-md border px-4 text-sm font-medium disabled:opacity-50"
          disabled={busy}
          onclick={() => {
            deleteIds = [...selected];
            deleteOpen = true;
          }}>{t.admin.entries.remove}</DialogTrigger
        >
      </div>{/if}
    <ul class="space-y-3">
      {#each visible as entry (entry.id)}
        <li class="space-y-3 rounded-lg border p-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <label class="flex min-h-11 min-w-0 items-center gap-3 text-sm">
              <input
                type="checkbox"
                class="size-5"
                bind:group={selected}
                value={entry.id}
                aria-label={ui.selectEntry.replace('{date}', entry.receivedAt ?? ui.unknownDate)}
              />
              <span
                >{t.admin.entries.received}: {entry.receivedAt
                  ? new Date(entry.receivedAt).toLocaleString('de-DE')
                  : ui.unknownDate}</span
              >
            </label>
            <span class="text-muted-foreground text-sm">{ui.accepted}</span>
            {#if entry.environment === 'test'}<span>{t.abuse.testEntry}</span>{/if}
            {#if entry.captchaStatus === 'unavailable'}<span>{t.abuse.unavailable}</span>{/if}
            {#if entry.captchaStatus === 'rejected'}<span>{t.abuse.rejected}</span>{/if}
            {#if entry.malwareStatus === 'nicht_geprueft'}<span>{t.abuse.unchecked}</span>{/if}
            {#if entry.malwareStatus === 'hash_clear'}<span>{t.abuse.hashClear}</span>{/if}
            <span class="rounded-md border px-2 py-1 text-sm">{entry.held ? ui.held : ui.free}</span
            >
          </div>
          <div class="flex flex-wrap gap-2">
            <Dialog
              open={openId === entry.id}
              onOpenChange={(value) => {
                if (!value) lock();
              }}
            >
              <DialogTrigger
                class="min-h-11 rounded-md border px-4 text-sm font-medium disabled:opacity-50"
                disabled={busy || !keyring.dataKey(entry.keyId ?? '')}
                onclick={() => void view(entry)}>{t.admin.entries.open}</DialogTrigger
              >
              <DialogContent
                title={ui.detail}
                description={entry.receivedAt ?? ui.unknownDate}
                class="max-h-[90dvh] max-w-2xl overflow-y-auto max-sm:inset-0 max-sm:h-dvh max-sm:max-h-dvh max-sm:w-full max-sm:translate-x-0 max-sm:translate-y-0 max-sm:rounded-none"
              >
                <div class="w-full min-w-0">
                  {#if busy && !shown}<p role="status">{ui.opening}</p>{/if}
                  {#if shown}
                    <div class="mb-4">
                      <Button
                        class="min-h-11"
                        variant="outline"
                        disabled={busy}
                        onclick={() => {
                          actionKind = 'error';
                          if (!entry.held || confirm(ui.unholdWarning)) void toggleHold(entry);
                        }}>{entry.held ? t.admin.entries.unhold : t.admin.entries.hold}</Button
                      >
                    </div>
                    <h3 class="text-base font-medium">{t.admin.entries.fields}</h3>
                    <dl
                      class="mt-3 grid grid-cols-[minmax(0,1fr)_minmax(0,2fr)] gap-x-4 gap-y-1 text-sm"
                    >
                      {#each shown.fields as [k, v], i (i)}
                        <dt class="text-muted-foreground break-all">{k}</dt>
                        <dd class="break-words whitespace-pre-wrap">{v}</dd>
                      {/each}
                      {#each attachments as a, n (n)}
                        <dt class="text-muted-foreground break-all">{t.admin.entries.files}</dt>
                        <dd class="break-words">
                          {a.name} ({ui.bytes.replace('{n}', String(a.size))})
                          <Button
                            type="button"
                            variant="outline"
                            disabled={busy}
                            onclick={() => void download(entry.id, n)}
                            >{t.admin.entries.download}</Button
                          >
                        </dd>
                      {/each}
                    </dl>
                    {#if deliveries.length > 0}
                      <h3 class="mt-3 text-sm font-medium">{t.admin.entries.mails}</h3>
                      <ul class="flex flex-col gap-2 text-sm">
                        {#each deliveries as d (d.id)}
                          <li class="flex flex-col gap-1">
                            <span
                              >{t.admin.entries.mailKind[d.kind]}: {t.admin.entries.mailState[
                                d.state
                              ]}</span
                            >
                            {#if d.state === 'waiting-manual' || d.state === 'uncertain'}
                              {#if d.state === 'uncertain'}
                                <label class="flex items-start gap-2">
                                  <input type="checkbox" bind:checked={confirmed[d.id]} />
                                  <span>{t.admin.entries.resendUncertain}</span>
                                </label>
                              {/if}
                              <div>
                                <Button
                                  type="button"
                                  variant="outline"
                                  disabled={busy || (d.state === 'uncertain' && !confirmed[d.id])}
                                  onclick={() => void resend(entry.id, d)}
                                  >{t.admin.entries.resend}</Button
                                >
                              </div>
                            {/if}
                          </li>
                        {/each}
                      </ul>
                      <Notice
                        message={resendMessage}
                        kind={resendMessage === t.admin.entries.resent ? 'ok' : 'error'}
                      />
                    {/if}
                    <div class="mt-2">
                      <Button type="button" variant="outline" onclick={lock}
                        >{t.admin.entries.close}</Button
                      >
                    </div>
                  {/if}
                  <Notice message={openMessage} />
                  {#if openMessage && !shown}<Button
                      class="min-h-11"
                      variant="outline"
                      disabled={busy}
                      onclick={() => void view(entry)}>{t.admin.retry}</Button
                    >{/if}
                  {#if !shown}<Button variant="outline" onclick={lock}
                      >{t.admin.entries.close}</Button
                    >{/if}
                </div></DialogContent
              ></Dialog
            >
            <Button
              class="min-h-11"
              variant="outline"
              disabled={busy}
              onclick={() => {
                actionKind = 'error';
                if (!entry.held || confirm(ui.unholdWarning)) void toggleHold(entry);
              }}>{entry.held ? t.admin.entries.unhold : t.admin.entries.hold}</Button
            >
            <DialogTrigger
              class="min-h-11 rounded-md border px-4 text-sm font-medium disabled:opacity-50"
              disabled={busy || entry.held}
              onclick={() => {
                deleteIds = [entry.id];
                deleteOpen = true;
              }}>{t.admin.entries.remove}</DialogTrigger
            >
          </div>
          {#if !keyring.dataKey(entry.keyId ?? '')}<p class="text-muted-foreground text-sm">
              {ui.noAccess}
            </p>{/if}
        </li>
      {/each}
    </ul>
    {#if next}<Button
        class="min-h-11"
        variant="outline"
        disabled={loading}
        onclick={() => void load(next ?? undefined)}>{t.admin.entries.more}</Button
      >{/if}
    <Notice message={actionMessage} kind={actionKind} />
  </section>
  <DialogContent
    title={ui.deleteTitle}
    description={ui.deleteConfirm.replace('{n}', String(deleteIds.length))}
  >
    <DialogClose class="min-h-11 rounded-md border px-4">{ui.cancel}</DialogClose>
    <Button class="min-h-11" disabled={busy} onclick={() => void remove()}>{ui.deleteFinal}</Button>
  </DialogContent>
  <details class="bg-card rounded-xl border p-4 sm:p-6">
    <summary class="min-h-11 cursor-pointer py-3 font-medium"
      >{t.admin.entries.retentionTitle}</summary
    >
    <p class="text-muted-foreground max-w-prose text-sm">{ui.retentionHint}</p>
    <form onsubmit={(e) => void saveRetention(e)} class="mt-4 flex max-w-xl flex-col gap-3">
      <Row id="retention-days" label={t.admin.entries.retentionDays}
        ><Input
          id="retention-days"
          type="number"
          min="1"
          max="3650"
          bind:value={retentionInput}
        /></Row
      >
      <div>
        <Button class="min-h-11" type="submit" disabled={busy}
          >{t.admin.entries.retentionSave}</Button
        >
      </div>
    </form>
    <Notice
      message={retentionMessage}
      kind={retentionMessage === t.admin.entries.retentionSaved ? 'ok' : 'error'}
    />
  </details>
</Dialog>
