<script lang="ts">
  import RecoveryStep from '$lib/crypto/RecoveryStep.svelte';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { onMount } from 'svelte';
  import { http } from '$lib/api';
  import { setupSteps } from '$lib/setup';
  import { router } from '$lib/router.svelte';
  let step = $state(0);
  let error = $state('');
  let required = $state(false);
  let loading = $state(true);
  let revision = $state('');
  onMount(() => {
    void load();
  });
  async function load() {
    const result = await http.request<{ required: boolean }>('GET', '/setup-state');
    if (result.ok) {
      required = result.data.required;
      if (required) {
        const settings = await http.request<{
          revision: string;
          items: { definition: { key: string }; value: string }[];
        }>('GET', '/settings');
        if (settings.ok) {
          revision = settings.data.revision;
          step = Number(
            settings.data.items.find((i) => i.definition.key === 'setup.step')?.value ?? '0',
          );
        } else error = 'Bitte erneut anmelden, um die Einrichtung fortzusetzen.';
      }
    } else
      error = 'Die Einrichtung konnte nicht geladen werden. Bitte erneut anmelden und versuchen.';
    loading = false;
  }
  async function advance(next = 1) {
    if (next === 2 && (!keyring.unlocked || keyring.recoveryRequired)) return;
    const r = await http.request<{ revision: string }>('PUT', '/settings', {
      body: { revision, values: { 'setup.step': String(next) } },
    });
    if (r.ok) {
      revision = r.data.revision;
      step = next;
    } else error = 'Der Fortschritt konnte nicht gespeichert werden. Bitte erneut laden.';
  }
</script>

<h1 id="page-title" tabindex="-1">Einrichtung</h1>
{#if loading}<p role="status">Einrichtung wird geladen …</p>
{:else if error}<p role="alert">{error}</p>
  <button onclick={load}>Erneut versuchen</button>
{:else if required}
  <p>Richten Sie Ihr Formular-Backend ein.</p>
  <p>Schritt {step + 1} von 6</p>
  <ol aria-label="Einrichtungsschritte">
    {#each setupSteps as label, index (label)}<li
        aria-current={step === index ? 'step' : undefined}
      >
        {index + 1}
        {label}
      </li>{/each}
  </ol>
  {#if step === 0}
    <h2>Ihr Administrationskonto einrichten</h2>
    <p>Ihr Konto und Passkey wurden über den installationsgebundenen Setup-Link eingerichtet.</p>
    <button onclick={() => void advance()}>Weiter</button>
  {:else if step === 1}
    <RecoveryStep oncomplete={() => void advance(2)} />
    <button onclick={() => (step = 0)}>Zurück</button>
  {:else}
    <p>Ihr Wiederherstellungscode ist gesichert. Fahren Sie mit Mail und Adressen fort.</p>
  {/if}
  <a href="/connections">Mail-Verbindung anlegen und testen</a>
  <a href="/settings">Adressen &amp; Betrieb prüfen</a>
  <a href="/migration">Daten übernehmen (optional)</a>
{:else}<p>
    Die Einrichtung ist abgeschlossen oder Sie haben kein Systemrecht für die Einrichtung.
  </p>{/if}
<button onclick={() => router.navigate('/t')}>Zum Überblick</button>
