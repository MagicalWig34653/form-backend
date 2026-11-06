<script lang="ts">
  let { name, size = 18 }: { name: string; size?: number } = $props();
  const paths: Record<string, string> = {
    customers: 'M3 21V8l9-5l9 5v13 M9 21v-6h6v6 M3 21h18',
    forms: 'M6 3h12v18H6z M9 8h6 M9 12h6 M9 16h4',
    entries: 'M4 4h16v16H4z M8 11l4 4l4-4 M12 7v8',
    statistics: 'M4 3v17h17 M8 15v-4 M13 15V6 M18 15V9',
    tokens: 'M7 5L2 12l5 7 M17 5l5 7l-5 7 M14 3l-4 18',
    settings: 'M4 7h16 M4 17h16 M9 4v6 M15 14v6',
    account: 'M4 21v-2a8 8 0 0 1 16 0v2 M12 2a4 4 0 1 1 0 8a4 4 0 1 1 0-8',
    members:
      'M4 20v-3a4 4 0 0 1 4-4h2a4 4 0 0 1 4 4v3 M17 13a4 4 0 0 1 3 4v3 M9 3a4 4 0 1 1 0 8a4 4 0 1 1 0-8 M17 4a3 3 0 0 1 0 6',
    connections: 'M9 2v6 M15 2v6 M6 8h12v4a6 6 0 0 1-12 0z M12 18v4',
    ops: 'M3 12h4l3-8l4 16l3-8h4',
    setup: 'M14 6l4 4 M3 21l7-7 M13 3l8 8l-4 4l-8-8z',
    migration: 'M4 8h13l-3-3 M20 16H7l3 3',
    search: 'M10 3a7 7 0 1 1 0 14a7 7 0 1 1 0-14 M21 21l-5-5',
    help: 'M12 3a9 9 0 1 1 0 18a9 9 0 1 1 0-18 M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.4-1 .9-1 1.7 M12 17h.01',
    logout: 'M9 4H5v16h4 M16 8l4 4l-4 4 M20 12H9',
    menu: 'M4 6h16 M4 12h16 M4 18h16',
    chevron: 'M9 6l6 6l-6 6',
    check: 'M5 12l5 5L20 7',
    warn: 'M12 3l10 18H2z M12 10v5 M12 18h.01',
    info: 'M12 3a9 9 0 1 1 0 18a9 9 0 1 1 0-18 M12 11v5 M12 8h.01',
    danger: 'M12 3a9 9 0 1 1 0 18a9 9 0 1 1 0-18 M12 7v6 M12 16h.01',
    x: 'M6 6l12 12 M18 6L6 18',
    appearance: 'M12 3a9 9 0 1 1 0 18a9 9 0 1 1 0-18 M12 3v18 M12 3a9 9 0 0 1 0 18z',
    inbox: 'M3 13l3-8h12l3 8v6H3z M3 13h5l1 3h6l1-3h5',
  };
</script>

<svg
  width={size}
  height={size}
  viewBox="0 0 24 24"
  fill="none"
  stroke="currentColor"
  stroke-width="1.6"
  stroke-linecap="round"
  stroke-linejoin="round"
  aria-hidden="true"><path d={paths[name] ?? paths.forms} /></svg
>
