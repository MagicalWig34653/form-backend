<script lang="ts">
  import type { Snippet } from 'svelte';
  import { t } from '$lib/i18n';
  import type { Editor } from '$lib/draft/editor.svelte';
  import { Button } from '$lib/components/ui/button';
  import Notice from '$lib/components/admin/Notice.svelte';
  import { describeError } from '$lib/admin/describe';

  /** `hint` false where the page has its own save pattern (a save bar) and "saved immediately" would be wrong. */
  let {
    editor,
    children,
    hint = true,
  }: { editor: Editor; children: Snippet; hint?: boolean } = $props();
</script>

{#if editor.draft}
  {#if hint}<p class="text-muted-foreground text-sm">{t.admin.form.draftHint}</p>{/if}
  {@render children()}
{:else}
  <p>{t.admin.form.noDraft}</p>
  <Notice message={editor.error ? describeError(editor.error) : ''} />
  <div>
    <Button type="button" disabled={editor.saving} onclick={() => void editor.createDraft()}
      >{t.admin.form.createDraft}</Button
    >
  </div>
{/if}
