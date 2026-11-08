import { http } from '$lib/api';

const state = $state<{ opsVisible: boolean; paletteOpen: boolean; drawerOpen: boolean }>({
  opsVisible: false,
  paletteOpen: false,
  drawerOpen: false,
});
let requestedFor: string | null = null;

/** State shared by the sidebar, the top bar and the command palette. */
export const shellState = {
  get opsVisible() {
    return state.opsVisible;
  },
  get paletteOpen() {
    return state.paletteOpen;
  },
  set paletteOpen(open: boolean) {
    state.paletteOpen = open;
  },
  /** Mobile navigation drawer. */
  get drawerOpen() {
    return state.drawerOpen;
  },
  set drawerOpen(open: boolean) {
    state.drawerOpen = open;
  },
  togglePalette(): void {
    state.paletteOpen = !state.paletteOpen;
  },
  /** Asks once per account whether the operations page is available. */
  async loadOpsAccess(account: string): Promise<void> {
    if (requestedFor === account) return;
    requestedFor = account;
    state.opsVisible = false;
    const result = await http.request<{ system: boolean; forms: unknown[] }>('GET', '/ops/access');
    if (requestedFor !== account) return;
    if (result.ok) state.opsVisible = result.data.system || result.data.forms.length > 0;
    else requestedFor = null;
  },
};
