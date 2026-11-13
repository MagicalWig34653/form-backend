<script lang="ts">
  import { cn } from '$lib/utils';
  let { class: className = '' }: { class?: string } = $props();
</script>

<!-- Marke wie im thermoctl-Design: weiße Fläche mit Rahmen, Zeichen in Vordergrundfarbe. -->
<span
  aria-hidden="true"
  class={cn(
    'bg-background text-foreground border-border inline-flex size-9 shrink-0 items-center justify-center rounded-lg border',
    className,
  )}
>
  <svg viewBox="0 0 24 24" class="size-5" fill="currentColor"
    ><path d="M5 5h14v3H5zm0 5.5h14v3H5zM5 16h9v3H5z" /></svg
  >
</span>
