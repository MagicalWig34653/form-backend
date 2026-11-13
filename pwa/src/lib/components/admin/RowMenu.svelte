<script lang="ts" module>
  export interface RowMenuItem {
    id: string;
    label: string;
    onselect: () => void;
    disabled?: boolean;
    destructive?: boolean;
  }
</script>

<script lang="ts">
  import { DropdownMenu } from 'bits-ui';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  interface Props {
    /** Accessible name of the "⋯" trigger, for example "Aktionen für Einsendung vom 03.11.2026". */
    label: string;
    items: RowMenuItem[];
    /** Id of the trigger, so callers can return focus to it. */
    id?: string;
    disabled?: boolean;
  }
  let { label, items, id, disabled = false }: Props = $props();
</script>

<DropdownMenu.Root>
  <DropdownMenu.Trigger
    {id}
    {disabled}
    aria-label={label}
    class="border-border hover:bg-secondary focus-visible:ring-ring inline-flex size-11 items-center justify-center rounded-md border focus-visible:ring-2 focus-visible:outline-none disabled:pointer-events-none disabled:opacity-50 sm:size-9"
  >
    <NavIcon name="more" size={18} />
  </DropdownMenu.Trigger>
  <DropdownMenu.Portal>
    <DropdownMenu.Content
      align="end"
      sideOffset={4}
      class="bg-popover text-popover-foreground ring-foreground/10 z-50 min-w-48 rounded-lg p-1 shadow-md ring-1"
    >
      {#each items as item (item.id)}
        <DropdownMenu.Item
          disabled={item.disabled}
          onSelect={item.onselect}
          class={`data-highlighted:bg-accent flex min-h-11 cursor-default items-center rounded-md px-3 text-sm outline-none select-none data-disabled:pointer-events-none data-disabled:opacity-50 sm:min-h-9 ${item.destructive ? 'text-red-700 dark:text-destructive' : ''}`}
        >
          {item.label}
        </DropdownMenu.Item>
      {/each}
    </DropdownMenu.Content>
  </DropdownMenu.Portal>
</DropdownMenu.Root>
