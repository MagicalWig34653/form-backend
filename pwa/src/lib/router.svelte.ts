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

/** Asked before a normal navigation; `true` goes on, a promise settles later (e.g. unsaved-changes dialog). */
type Guard = (to: string) => boolean | Promise<boolean>;
let guard: Guard | null = null;

function go(to: string, replace: boolean): void {
  if (replace) history.replaceState(null, '', to);
  else history.pushState(null, '', to);
  state.path = normalize(to.split(/[?#]/)[0] ?? to);
  state.search = /^[^?#]*(\?[^#]*)?/.exec(to)?.[1] ?? '';
}

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
    const verdict = guard && !replace ? guard(to) : true;
    if (verdict === true) go(to, replace);
    else if (verdict !== false) void verdict.then((ok) => ok && go(to, replace));
  },
  /** One guard at a time (the page with unsaved changes); returns the function that removes it. */
  setGuard(next: Guard | null): () => void {
    guard = next;
    return () => {
      if (guard === next) guard = null;
    };
  },
};
