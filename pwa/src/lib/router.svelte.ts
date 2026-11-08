/** Minimal History-API router (2 routes; SvelteKit would be overkill, see handoff). */
const state = $state({
  path: normalize(window.location.pathname),
  search: window.location.search,
});

function normalize(path: string): string {
  return path.length > 1 ? path.replace(/\/+$/, '') : path;
}

window.addEventListener('popstate', () => {
  state.path = normalize(window.location.pathname);
  state.search = window.location.search;
});

export const router = {
  get path(): string {
    return state.path;
  },
  /** Query string of the current location, e.g. "?need=customer". */
  get search(): string {
    return state.search;
  },
  navigate(to: string, replace = false): void {
    // Only same-origin absolute paths; "//host" and other forms are rejected.
    if (!to.startsWith('/') || to.startsWith('//') || to.includes('\\')) return;
    if (replace) history.replaceState(null, '', to);
    else history.pushState(null, '', to);
    state.path = normalize(to.split(/[?#]/)[0] ?? to);
    state.search = /^[^?#]*(\?[^#]*)?/.exec(to)?.[1] ?? '';
  },
};
