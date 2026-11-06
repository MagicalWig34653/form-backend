<script lang="ts">
  import { onMount } from 'svelte';
  import { http } from '$lib/api';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { t } from '$lib/i18n';
  interface Item {
    definition: {
      key: string;
      group: string;
      type: string;
      envName: string;
      minimum?: number;
      maximum?: number;
      restartRequired: boolean;
      sensitive: boolean;
    };
    value?: string;
    source: string;
    locked: boolean;
  }
  interface Snapshot {
    revision: string;
    items: Item[];
  }
  const text = t.admin.settings;
  const groups = [
    t.abuse.title,
    'Mail-Netze',
    'Limits',
    'Aufbewahrungsstandard',
    'Speicher',
    'Webhook-Limits',
    'MCP-Token-Ratelimit',
    'Hosts',
    'Einrichtung',
    'Umstieg',
  ];
  let snapshot = $state<Snapshot>();
  let values = $state<Record<string, string>>({});
  let busy = $state(false);
  let error = $state('');
  let notice = $state('');
  async function failure(e: Parameters<typeof describeError>[0]) {
    if (e.status === 409) error = text.conflict;
    else if (needsFreshLogin(e)) await reauthenticate('/settings');
    else if (!handleSessionError(e)) error = describeError(e);
  }
  function accept(data: Snapshot) {
    snapshot = data;
    values = Object.fromEntries(data.items.map((x) => [x.definition.key, x.value ?? '']));
  }
  async function load() {
    busy = true;
    error = '';
    notice = '';
    const r = await http.request<Snapshot>('GET', '/settings');
    if (r.ok) accept(r.data);
    else await failure(r.error);
    busy = false;
  }
  async function save(e: SubmitEvent) {
    e.preventDefault();
    if (!snapshot || busy) return;
    const changed = snapshot.items.filter(
      (x) => !x.locked && values[x.definition.key] !== (x.value ?? ''),
    );
    if (!changed.length) return;
    busy = true;
    error = '';
    notice = '';
    const r = await http.request<Snapshot>('PUT', '/settings', {
      body: {
        revision: snapshot.revision,
        values: Object.fromEntries(
          changed.map((x) => [x.definition.key, values[x.definition.key]]),
        ),
      },
    });
    if (r.ok) {
      accept(r.data);
      notice = changed.some((x) => x.definition.restartRequired) ? text.savedRestart : text.saved;
    } else await failure(r.error);
    busy = false;
  }
  onMount(() => void load());
</script>

<h1 id="page-title" tabindex="-1" class="text-2xl font-semibold">{text.title}</h1>
<p>{text.precedence}</p>
{#if error}<p role="alert">{error}</p>{/if}
{#if notice}<p role="status">{notice}</p>{/if}
<button type="button" disabled={busy} onclick={() => void load()}>{text.reload}</button>
{#if snapshot}
  <form onsubmit={save} class="flex flex-col gap-6">
    {#each groups as group (group)}
      <fieldset class="rounded border p-4">
        <legend>{group}</legend>
        {#each snapshot.items.filter((x) => x.definition.group === group) as item (item.definition.key)}
          <div class="my-3 flex flex-col gap-1">
            <label for={item.definition.key}>{item.definition.key}</label>
            <input
              id={item.definition.key}
              type={item.definition.sensitive ? 'password' : 'text'}
              bind:value={values[item.definition.key]}
              disabled={busy || item.locked}
              inputmode={item.definition.type === 'integer' ? 'numeric' : 'text'}
              class="rounded border p-2"
            />
            <small
              >{text.source}: {item.source} · {item.definition.envName}{item.locked
                ? ` · ${text.locked}`
                : ''}{item.definition.restartRequired ? ` · ${text.restart}` : ''}{item.definition
                .minimum !== undefined
                ? ` · ${item.definition.minimum}–${item.definition.maximum}`
                : ''}</small
            >
          </div>
        {:else}<p>{text.noExistingEnv}</p>{/each}
      </fieldset>
    {/each}
    <button type="submit" disabled={busy}>{text.save}</button>
  </form>
{/if}
