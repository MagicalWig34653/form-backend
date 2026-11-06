<script lang="ts">
  interface Props {
    message: string;
    kind?: 'error' | 'ok';
  }
  let { message, kind = 'error' }: Props = $props();
</script>

<div aria-live="polite" class="min-h-6">
  {#if message}
    <p
      role={kind === 'error' ? 'alert' : 'status'}
      class={kind === 'error' ? 'text-destructive text-sm' : 'text-sm'}
    >
      {message}
    </p>
  {/if}
</div>
