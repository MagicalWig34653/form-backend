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
  import { t } from '$lib/i18n';
  import { Input } from '$lib/components/ui/input';
  import { cn } from '$lib/utils';

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
  $effect(() => {
    if (value !== (parsed ?? '')) text = formatDate(value);
  });
  function input(): void {
    const next = parsed ?? '';
    if (next !== value) {
      value = next;
      onchange?.();
    }
  }
</script>

<div class={cn('flex min-w-0 flex-col gap-1.5', className)}>
  <label for={id} class="text-sm font-medium">{label}</label>
  <Input
    {id}
    bind:value={text}
    {disabled}
    inputmode="numeric"
    autocomplete="off"
    placeholder={t.listUi.dateFormat}
    aria-invalid={bad && touched ? true : undefined}
    aria-describedby={bad && touched ? `${id}-error` : undefined}
    oninput={input}
    onblur={() => (touched = true)}
  />
  {#if bad && touched}<p id={`${id}-error`} role="alert" class="text-destructive text-sm">
      {t.listUi.dateInvalid}
    </p>{/if}
</div>
