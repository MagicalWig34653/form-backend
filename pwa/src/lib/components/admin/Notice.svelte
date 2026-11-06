<script lang="ts">
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  interface Props {
    message: string;
    kind?: 'error' | 'ok';
  }
  let { message, kind = 'error' }: Props = $props();
</script>

<!-- The message carries its own live role; a wrapper with aria-live would announce twice. -->
<div class="min-h-6">
  {#if message}
    <p
      role={kind === 'error' ? 'alert' : 'status'}
      class="flex items-start gap-2 text-sm leading-5 {kind === 'error'
        ? 'text-danger'
        : 'text-ok'}"
    >
      <span aria-hidden="true" class="mt-0.5 shrink-0 [&>svg]:size-4"
        ><NavIcon name={kind === 'error' ? 'danger' : 'check'} /></span
      >
      <span class="min-w-0">{message}</span>
    </p>
  {/if}
</div>
