<script lang="ts" module>
  /** Parses TT.MM.JJJJ (or ISO JJJJ-MM-TT) into an ISO date; null when it is not a real date. */
  export function parseDate(text: string): string | null {
    const value = text.trim();
    let year: number, month: number, day: number;
    let m = value.match(/^(\d{1,2})\.(\d{1,2})\.(\d{4})$/);
    if (m)
      [day, month, year] = [Number(m[1]), Number(m[2]), Number(m[3])] as [number, number, number];
    else if ((m = value.match(/^(\d{4})-(\d{2})-(\d{2})$/)))
      [year, month, day] = [Number(m[1]), Number(m[2]), Number(m[3])] as [number, number, number];
    else return null;
    const date = new Date(Date.UTC(year, month - 1, day));
    if (
      date.getUTCFullYear() !== year ||
      date.getUTCMonth() !== month - 1 ||
      date.getUTCDate() !== day
    )
      return null;
    return `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
  }
  export function formatDate(iso: string): string {
    const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    return m ? `${m[3]}.${m[2]}.${m[1]}` : '';
  }
</script>

<script lang="ts">
  import { untrack } from 'svelte';
  import { t } from '$lib/i18n';
  import { Input } from '$lib/components/ui/input';
  import { cn } from '$lib/utils';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  interface Props {
    id: string;
    label: string;
    /** ISO date (JJJJ-MM-TT) or '' for "not set"; typed in the German format TT.MM.JJJJ. */
    value?: string;
    /** True while the text is not empty but not a real date. */
    invalid?: boolean;
    disabled?: boolean;
    /** Fires when the parsed value changes. */
    onchange?: () => void;
    class?: string;
  }
  let {
    id,
    label,
    value = $bindable(''),
    invalid = $bindable(false),
    disabled = false,
    onchange,
    class: className,
  }: Props = $props();

  let text = $state(formatDate(value));
  let touched = $state(false);
  const parsed = $derived(parseDate(text));
  const bad = $derived(text.trim() !== '' && parsed === null);
  $effect(() => {
    invalid = bad;
  });
  // External resets of the value (for example "clear") update the text.
  // Only a change of the value itself may rewrite the text; reacting to the text as well would
  // erase a freshly typed date before the input handler has committed it.
  let last = value;
  $effect(() => {
    const next = value;
    if (next === last) return;
    last = next;
    if (next !== untrack(() => parsed ?? '')) text = formatDate(next);
  });
  let native = $state<HTMLInputElement | null>(null);
  /** Inserts the dots of TT.MM.JJJJ while the user types digits. */
  function mask(event: Event): void {
    const el = event.currentTarget as HTMLInputElement;
    const typed = (event as InputEvent).inputType === 'insertText';
    const shown = typed && /^(\d{2}|\d{2}\.\d{2})$/.test(el.value) ? el.value + '.' : el.value;
    text = shown;
    // Read from the element, not from derived state: bind:value may not have run yet.
    commit(parseDate(shown) ?? '');
  }
  function pick(): void {
    try {
      native?.showPicker();
    } catch {
      native?.focus();
    }
  }
  function picked(event: Event): void {
    const next = (event.currentTarget as HTMLInputElement).value;
    if (!next) return;
    text = formatDate(next);
    touched = true;
    commit(next);
  }
  function commit(next: string): void {
    last = next;
    if (next !== value) {
      value = next;
      onchange?.();
    }
  }
</script>

<div class={cn('flex min-w-0 flex-col gap-1.5', className)}>
  <label for={id} class="text-sm font-medium">{label}</label>
  <div class="relative">
    <Input
      {id}
      class="pr-11"
      maxlength={10}
      bind:value={text}
      {disabled}
      inputmode="numeric"
      autocomplete="off"
      placeholder={t.listUi.dateFormat}
      aria-invalid={bad && touched ? true : undefined}
      aria-describedby={bad && touched ? `${id}-error` : undefined}
      oninput={mask}
      onblur={() => (touched = true)}
    />
    <button
      type="button"
      {disabled}
      aria-label={`${label}: ${t.listUi.pickDate}`}
      class="text-muted-foreground hover:text-foreground focus-visible:ring-ring absolute top-1/2 right-1 inline-flex size-9 -translate-y-1/2 items-center justify-center rounded-md focus-visible:ring-2 focus-visible:outline-none disabled:opacity-50"
      onclick={pick}><NavIcon name="calendar" size={18} /></button
    >
    <input
      bind:this={native}
      type="date"
      tabindex="-1"
      aria-hidden="true"
      class="pointer-events-none absolute right-0 bottom-0 size-0 opacity-0"
      {value}
      onchange={picked}
    />
  </div>
  {#if bad && touched}<p id={`${id}-error`} role="alert" class="text-destructive text-sm">
      {t.listUi.dateInvalid}
    </p>{/if}
</div>
