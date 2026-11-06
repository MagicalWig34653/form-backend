<script lang="ts">
  import type { Snippet } from 'svelte';
  import { t } from '$lib/i18n';

  interface Props {
    id: string;
    label: string;
    hint?: string;
    error?: string | undefined;
    /** Force the required marker; otherwise it follows the control's `required` attribute. */
    required?: boolean;
    children: Snippet;
  }
  let { id, label, hint, error, required, children }: Props = $props();

  let box = $state<HTMLElement>();
  let controlRequired = $state(false);

  /** Links hint and error to the control and mirrors the required state (WCAG 1.3.1, 3.3.1). */
  $effect(() => {
    const control = box?.querySelector<HTMLElement>(`[id="${id}"]`);
    if (!control) return;
    controlRequired = control.hasAttribute('required');
    const own = [hint ? `${id}-hint` : '', error ? `${id}-error` : ''].filter(Boolean);
    const original = control.getAttribute('aria-describedby');
    const merged = [...(original ? original.split(/\s+/) : []), ...own].filter(
      (value, index, all) => all.indexOf(value) === index,
    );
    if (merged.length) control.setAttribute('aria-describedby', merged.join(' '));
    if (error) control.setAttribute('aria-invalid', 'true');
    return () => {
      if (original === null) control.removeAttribute('aria-describedby');
      else control.setAttribute('aria-describedby', original);
      if (error) control.removeAttribute('aria-invalid');
    };
  });
  const marked = $derived(required ?? controlRequired);
</script>

<div bind:this={box} class="flex min-w-0 flex-col gap-1.5">
  <div class="flex flex-wrap items-baseline justify-between gap-x-3">
    <label for={id} class="text-sm leading-5 font-medium">{label}</label>
    {#if marked}<span aria-hidden="true" class="text-muted-foreground text-xs"
        >{t.formKit.required}</span
      >{/if}
  </div>
  {@render children()}
  {#if hint}<p id={`${id}-hint`} class="text-muted-foreground text-xs leading-[18px]">
      {hint}
    </p>{/if}
  {#if error}<p id={`${id}-error`} role="alert" class="text-danger text-sm">{error}</p>{/if}
</div>
