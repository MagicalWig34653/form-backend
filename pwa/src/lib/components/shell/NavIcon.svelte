<script lang="ts">
  // Symbole aus Lucide (ISC, siehe LICENSES/ISC-lucide.txt), einzeln importiert, damit nur die
  // benutzten Symbole im Bündel landen. Gleiche Bibliothek und Strichstärke wie im thermoctl-Design.
  import type { Component } from 'svelte';
  import Activity from '@lucide/svelte/icons/activity';
  import ArrowLeftRight from '@lucide/svelte/icons/arrow-left-right';
  import Building from '@lucide/svelte/icons/building';
  import ChartColumn from '@lucide/svelte/icons/chart-column';
  import ChevronsUpDown from '@lucide/svelte/icons/chevrons-up-down';
  import Calendar from '@lucide/svelte/icons/calendar';
  import Copy from '@lucide/svelte/icons/copy';
  import Ellipsis from '@lucide/svelte/icons/ellipsis';
  import Check from '@lucide/svelte/icons/check';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import CircleAlert from '@lucide/svelte/icons/circle-alert';
  import CircleQuestionMark from '@lucide/svelte/icons/circle-question-mark';
  import CodeXml from '@lucide/svelte/icons/code-xml';
  import CircleX from '@lucide/svelte/icons/circle-x';
  import Eye from '@lucide/svelte/icons/eye';
  import FileText from '@lucide/svelte/icons/file-text';
  import Hammer from '@lucide/svelte/icons/hammer';
  import Inbox from '@lucide/svelte/icons/inbox';
  import Info from '@lucide/svelte/icons/info';
  import LayoutDashboard from '@lucide/svelte/icons/layout-dashboard';
  import LogOut from '@lucide/svelte/icons/log-out';
  import KeyRound from '@lucide/svelte/icons/key-round';
  import Lock from '@lucide/svelte/icons/lock';
  import LockOpen from '@lucide/svelte/icons/lock-open';
  import Menu from '@lucide/svelte/icons/menu';
  import Palette from '@lucide/svelte/icons/palette';
  import PanelLeft from '@lucide/svelte/icons/panel-left';
  import ArrowUp from '@lucide/svelte/icons/arrow-up';
  import ArrowDown from '@lucide/svelte/icons/arrow-down';
  import Trash from '@lucide/svelte/icons/trash-2';
  import Percent from '@lucide/svelte/icons/percent';
  import Play from '@lucide/svelte/icons/play';
  import RefreshCw from '@lucide/svelte/icons/refresh-cw';
  import Plug from '@lucide/svelte/icons/plug';
  import Search from '@lucide/svelte/icons/search';
  import Send from '@lucide/svelte/icons/send';
  import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
  import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
  import UserRound from '@lucide/svelte/icons/user-round';
  import Users from '@lucide/svelte/icons/users';
  import X from '@lucide/svelte/icons/x';

  let { name, size = 18 }: { name: string; size?: number } = $props();
  const icons: Record<string, Component<{ size?: number; 'aria-hidden'?: 'true' }>> = {
    dashboard: LayoutDashboard,
    up: ArrowUp,
    down: ArrowDown,
    trash: Trash,
    updown: ChevronsUpDown,
    customers: Building,
    forms: FileText,
    entries: Inbox,
    statistics: ChartColumn,
    tokens: CodeXml,
    settings: SlidersHorizontal,
    account: UserRound,
    members: Users,
    connections: Plug,
    ops: Activity,
    setup: Hammer,
    migration: ArrowLeftRight,
    search: Search,
    help: CircleQuestionMark,
    logout: LogOut,
    menu: Menu,
    chevron: ChevronRight,
    check: Check,
    warn: TriangleAlert,
    info: Info,
    danger: CircleAlert,
    x: X,
    appearance: Palette,
    panel: PanelLeft,
    inbox: Inbox,
    visits: Eye,
    begins: Play,
    submits: Send,
    abandons: CircleX,
    conversion: Percent,
    key: KeyRound,
    locked: Lock,
    unlocked: LockOpen,
    calendar: Calendar,
    copy: Copy,
    more: Ellipsis,
    refresh: RefreshCw,
  };
  const Icon = $derived(icons[name] ?? FileText);
</script>

<Icon {size} aria-hidden="true" />
