<script lang="ts">
  // The mail HTML is shown only inside a sandboxed frame (no scripts, no same-origin access, no forms or popups),
  // never in the admin page itself.
  import { t } from '$lib/i18n';
  import Eye from '@lucide/svelte/icons/eye';
  import { previewDocument } from './preview';

  let {
    body,
    id,
    class: className = '',
    frameClass = 'h-[480px]',
  }: { body: string; id: string; class?: string; frameClass?: string } = $props();
  const b = t.admin.mail.builder;

  // Debounced so typing does not reload the frame on every key.
  let shown = $state('');
  let first = true;
  $effect(() => {
    const next = previewDocument(body, b.example);
    if (first) {
      first = false;
      shown = next;
      return;
    }
    const timer = setTimeout(() => (shown = next), 250);
    return () => clearTimeout(timer);
  });
</script>

<figure
  class="m-0 flex min-w-0 flex-col gap-1.5 {className}"
  aria-labelledby={`${id}-preview-label`}
>
  <figcaption class="flex flex-wrap items-center gap-x-2 gap-y-1">
    <span id={`${id}-preview-label`} class="flex items-center gap-1.5 text-sm font-medium"
      ><Eye size={16} aria-hidden="true" />{b.preview}</span
    >
    <span class="text-muted-foreground text-xs">{b.previewHint}</span>
  </figcaption>
  <iframe
    sandbox=""
    referrerpolicy="no-referrer"
    title={b.previewTitle}
    srcdoc={shown}
    class="border-border w-full min-w-0 rounded-md border bg-white {frameClass}"
    data-testid={`${id}-preview`}
  ></iframe>
</figure>
