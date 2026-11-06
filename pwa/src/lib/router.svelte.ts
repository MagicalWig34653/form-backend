/** Minimal History-API router (2 routes; SvelteKit would be overkill, see handoff). */
const state = $state({ path: normalize(window.location.pathname) });

function normalize(path: string): string {
  return path.length > 1 ? path.replace(/\/+$/, '') : path;
}

window.addEventListener('popstate', () => {
  state.path = normalize(window.location.pathname);
});

export const router = {
  get path(): string {
    return state.path;
  },
  navigate(to: string, replace = false): void {
    // Only same-origin absolute paths; "//host" and other forms are rejected.
    if (!to.startsWith('/') || to.startsWith('//') || to.includes('\\')) return;
    if (replace) history.replaceState(null, '', to);
    else history.pushState(null, '', to);
    state.path = normalize(to.split(/[?#]/)[0] ?? to);
  },
};
