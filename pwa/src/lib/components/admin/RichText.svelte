<script lang="ts" module>
  /** Splits "Datei `credentials.json` ablegen" into text and code segments (backticks mark code). */
  export function segments(text: string): { code: boolean; text: string }[] {
    return text
      .split('`')
      .map((part, index) => ({ code: index % 2 === 1, text: part }))
      .filter((part) => part.text !== '');
  }
</script>

<script lang="ts">
  let { text }: { text: string } = $props();
</script>

{#each segments(text) as part, index (index)}{#if part.code}<code
      class="bg-muted rounded px-1 py-0.5 font-mono text-[0.9em] break-words">{part.text}</code
    >{:else}{part.text}{/if}{/each}
