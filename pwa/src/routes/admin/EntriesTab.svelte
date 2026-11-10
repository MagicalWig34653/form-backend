<script lang="ts">
  import { formatDateTime } from '$lib/format';
  import { confirmAction } from '$lib/confirm.svelte';
  import Suche from './Suche.svelte';
  import SealedExport from './SealedExport.svelte';
  import { Dialog, DialogContent } from '$lib/components/ui/dialog';
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
  import Row from '$lib/components/admin/Row.svelte';
  import DateField from '$lib/components/admin/DateField.svelte';
  import RowMenu from '$lib/components/admin/RowMenu.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import FilterBar from '$lib/components/admin/FilterBar.svelte';
  import Select from '$lib/components/admin/Select.svelte';

  let { tenant, form }: { tenant: string; form: string } = $props();

  let items = $state<EntryItem[]>([]);
  let next = $state<string | null>(null);
  let loaded = $state(false);
  let message = $state('');
  let busy = $state(false);

  const ui = t.admin.entriesPage;
  let loading = $state(false);
  let slow = $state(false);
  let from = $state(''),
    until = $state('');
  let fromInvalid = $state(false),
    untilInvalid = $state(false);
  let protection = $state('all');
  let selected = $state<string[]>([]);
  const visible = $derived(
    items.filter(
      (entry) =>
        (protection === 'all' || entry.held === (protection === 'held')) &&
        (!from || (entry.receivedAt ?? '').slice(0, 10) >= from) &&
        (!until || (entry.receivedAt ?? '').slice(0, 10) <= until),
    ),
  );

  const rowButton =
    'border-border hover:bg-secondary inline-flex min-h-9 items-center justify-center rounded-md border px-3 text-sm font-medium disabled:pointer-events-none disabled:opacity-50';
  const activeFilters = $derived((from ? 1 : 0) + (until ? 1 : 0) + (protection !== 'all' ? 1 : 0));
  const missingCount = $derived(
    visible.filter((entry) => !keyring.dataKey(entry.keyId ?? '')).length,
  );
  function resetFilters(): void {
    from = '';
    until = '';
    protection = 'all';
  }
  /** Gives focus back to the row's menu button once the detail dialog is closed. */
  function focusMenu(id: string): void {
    setTimeout(() => document.getElementById(`row-menu-${id}`)?.focus(), 0);
  }
  const allSelected = $derived(visible.length > 0 && visible.every((e) => selected.includes(e.id)));
  const someSelected = $derived(visible.some((e) => selected.includes(e.id)));
  let selectAllBox = $state<HTMLInputElement | null>(null);
  $effect(() => {
    if (selectAllBox) selectAllBox.indeterminate = someSelected && !allSelected;
  });
  const when = (iso: string | null): string => (iso ? formatDateTime(iso) : ui.unknownDate);

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

  const confirmUnhold = (): Promise<boolean> =>
    confirmAction({
      title: t.confirm.releaseHoldTitle,
      description: ui.unholdWarning,
      confirmLabel: t.confirm.releaseHold,
      destructive: true,
    });
  async function toggleHoldChecked(entry: (typeof items)[number]): Promise<void> {
    if (entry.held && !(await confirmUnhold())) return;
    await toggleHold(entry);
  }

  async function holdSelection(held: boolean): Promise<void> {
    if (busy) return;
    if (!held && !(await confirmUnhold())) return;
    actionKind = 'error';
    for (const entry of items.filter((item) => selected.includes(item.id) && item.held !== held)) {
      await toggleHold(entry);
      if (actionMessage) break;
    }
  }

  async function requestRemove(ids: string[]): Promise<void> {
    if (busy) return;
    const confirmed = await confirmAction({
      title: ui.deleteTitle,
      description: ui.deleteConfirm.replace('{n}', String(ids.length)),
      confirmLabel: ui.deleteFinal,
      destructive: true,
    });
    if (confirmed) await remove(ids);
  }

  async function remove(ids: string[]): Promise<void> {
    if (busy) return;
    busy = true;
    actionMessage = '';
    actionKind = 'error';
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

  // Decrypted content and the key must not outlive the page view.
  $effect(() => () => lock());

  onMount(() => {
    void load();
    return keyring.onLock(lock);
  });
</script>

<div class="flex min-w-0 flex-col gap-5">
  <Panel
    flush
    class="overflow-hidden"
    title={t.admin.entries.title}
    description={t.admin.entries.intro}
  >
    {#snippet actions()}{#key tenant + form}<SealedExport {tenant} {form} />{/key}{/snippet}
    <section aria-label={ui.list} aria-busy={loading}>
      <div class="border-border border-b px-(--card-spacing) py-3">
        <FilterBar activeCount={activeFilters} hint={ui.filterHint} onreset={resetFilters}>
          <DateField
            id="entry-from"
            label={ui.from}
            bind:value={from}
            bind:invalid={fromInvalid}
            class="min-w-40 flex-1"
          />
          <DateField
            id="entry-until"
            label={ui.until}
            bind:value={until}
            bind:invalid={untilInvalid}
            class="min-w-40 flex-1"
          />
          <div class="min-w-40 flex-1">
            <Row id="entry-protection" label={ui.protection}
              ><Select id="entry-protection" bind:value={protection}>
                <option value="all">{ui.all}</option><option value="held">{ui.held}</option><option
                  value="free">{ui.free}</option
                >
              </Select></Row
            >
          </div>
        </FilterBar>
      </div>
      {#if message}
        <div class="p-3">
          <Banner tone="danger">
            {message}
            {#snippet action()}
              <Button
                disabled={loading}
                variant="outline"
                onclick={() => void load(next ?? undefined)}>{t.admin.retry}</Button
              >
            {/snippet}
          </Banner>
        </div>
      {/if}
      {#if loading}
        <div class="flex flex-col gap-2 p-4" aria-busy="true">
          <p role="status" class="text-muted-foreground text-sm">
            {slow ? ui.slow : t.admin.loading}
          </p>
          {#if items.length === 0}
            {#each [0, 1, 2] as n (n)}<Skeleton class="h-11 rounded-md" />{/each}
          {/if}
        </div>
      {/if}
      {#if loaded && !message && items.length === 0}
        <EmptyState icon="inbox" title={t.admin.entries.none} />
      {:else if loaded && visible.length === 0 && items.length > 0}
        <EmptyState icon="search" title={ui.filteredEmpty}>
          {#snippet action()}
            <Button variant="outline" onclick={resetFilters}>{t.lists.reset}</Button>
          {/snippet}
        </EmptyState>
      {/if}
      {#if missingCount > 0 && keyring.unlocked}
        <div class="p-3 pb-0">
          <Banner tone="warn">{ui.noAccess.replace('{n}', String(missingCount))}</Banner>
        </div>
      {/if}
      {#if visible.length > 0}
        <div
          class="border-border bg-muted/50 text-muted-foreground mt-3 flex min-h-11 flex-wrap items-center gap-x-3 gap-y-1 border-y px-4 text-sm"
        >
          <label class="flex min-h-9 items-center gap-3">
            <input
              type="checkbox"
              class="size-6 shrink-0 accent-[var(--ui-accent)]"
              bind:this={selectAllBox}
              checked={allSelected}
              aria-label={t.listUi.selectAll}
              onchange={(event) => {
                selected = event.currentTarget.checked
                  ? [...new Set([...selected, ...visible.map((e) => e.id)])]
                  : selected.filter((id) => !visible.some((e) => e.id === id));
              }}
            />
            <span aria-hidden="true">{t.admin.entries.received}</span>
          </label>
          <span class="ml-auto tabular-nums"
            >{(next ? t.listUi.loadedMore : t.listUi.loaded).replace(
              '{n}',
              String(visible.length),
            )}</span
          >
        </div>
      {/if}
      {#if selected.length}
        <div
          class="bg-brand-soft border-brand/40 sticky top-16 z-10 flex flex-wrap items-center gap-2 border-b px-4 py-2"
          role="group"
          aria-label={t.listUi.selectionBar}
        >
          <p role="status" class="mr-auto font-medium">
            {ui.selected.replace('{n}', String(selected.length))}
          </p>
          <Button
            class="min-h-9"
            variant="outline"
            disabled={busy}
            onclick={() => void holdSelection(true)}>{t.admin.entries.hold}</Button
          >
          <Button
            class="min-h-9"
            variant="outline"
            disabled={busy}
            onclick={() => void holdSelection(false)}>{t.admin.entries.unhold}</Button
          >
          <Button
            class={`${rowButton} text-red-700 dark:text-destructive`}
            variant="outline"
            disabled={busy}
            onclick={() => void requestRemove([...selected])}>{t.admin.entries.remove}</Button
          >
          <Button class="min-h-9" variant="ghost" onclick={() => (selected = [])}
            >{t.listUi.selectNone}</Button
          >
        </div>
      {/if}
      <ul
        class="divide-border divide-y max-sm:flex max-sm:flex-col max-sm:gap-2 max-sm:divide-y-0 max-sm:p-3"
      >
        {#each visible as entry (entry.id)}
          {@const access = !!keyring.dataKey(entry.keyId ?? '')}
          <li
            class={`flex min-h-14 flex-wrap items-center gap-x-3 gap-y-1.5 px-4 py-2 transition-colors max-sm:border-border max-sm:rounded-lg max-sm:border max-sm:py-3 ${selected.includes(entry.id) ? 'bg-brand-soft' : 'hover:bg-muted/50'}`}
          >
            <label class="flex min-h-9 min-w-0 flex-1 basis-56 items-center gap-3 text-sm">
              <input
                type="checkbox"
                class="size-6 shrink-0 accent-[var(--ui-accent)]"
                bind:group={selected}
                value={entry.id}
                aria-label={ui.selectEntry.replace('{date}', when(entry.receivedAt))}
              />
              <span class="font-medium tabular-nums">{when(entry.receivedAt)}</span>
            </label>
            <div class="flex flex-wrap items-center gap-1.5">
              <StatusChip tone="ok" label={ui.accepted} />
              {#if entry.held}<StatusChip tone="info" label={ui.held} />{/if}
              {#if entry.environment === 'test'}<StatusChip
                  tone="idle"
                  label={t.abuse.testEntry}
                />{/if}
              {#if entry.captchaStatus === 'unavailable'}<StatusChip
                  tone="warn"
                  label={t.abuse.unavailable}
                />{/if}
              {#if entry.captchaStatus === 'rejected'}<StatusChip
                  tone="warn"
                  label={t.abuse.rejected}
                />{/if}
              {#if entry.malwareStatus === 'nicht_geprueft'}<StatusChip
                  tone="idle"
                  label={t.abuse.unchecked}
                />{/if}
              {#if entry.malwareStatus === 'hash_clear'}<StatusChip
                  tone="idle"
                  label={t.abuse.hashClear}
                />{/if}
            </div>
            <div class="ml-auto">
              <RowMenu
                id={`row-menu-${entry.id}`}
                label={ui.rowActions.replace('{date}', when(entry.receivedAt))}
                disabled={busy}
                items={[
                  {
                    id: 'open',
                    label: t.admin.entries.open,
                    disabled: !access,
                    onselect: () => void view(entry),
                  },
                  {
                    id: 'hold',
                    label: entry.held ? t.admin.entries.unhold : t.admin.entries.hold,
                    onselect: () => {
                      actionKind = 'error';
                      void toggleHoldChecked(entry);
                    },
                  },
                  {
                    id: 'remove',
                    label: t.admin.entries.remove,
                    disabled: entry.held,
                    destructive: true,
                    onselect: () => void requestRemove([entry.id]),
                  },
                ]}
              />
              <Dialog
                open={openId === entry.id}
                onOpenChange={(value) => {
                  if (!value) {
                    lock();
                    focusMenu(entry.id);
                  }
                }}
              >
                <DialogContent
                  title={ui.detail}
                  description={when(entry.receivedAt)}
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
                            void toggleHoldChecked(entry);
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
                                    <input
                                      type="checkbox"
                                      class="mt-0.5 size-5 shrink-0 accent-[var(--ui-accent)]"
                                      bind:checked={confirmed[d.id]}
                                    />
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
            </div>
          </li>
        {/each}
      </ul>
      {#if next}
        <div class="border-border border-t p-3">
          <Button variant="outline" disabled={loading} onclick={() => void load(next ?? undefined)}
            >{t.admin.entries.more}</Button
          >
        </div>
      {/if}
      {#if actionMessage}
        <div class="p-3"><Notice message={actionMessage} kind={actionKind} /></div>
      {/if}
    </section>
  </Panel>
  {#key tenant + form}<Suche
      {tenant}
      {form}
      onDeleted={(ids) => {
        items = items.filter((item) => !ids.includes(item.id));
        lock();
      }}
    />{/key}
</div>
