/** Form tabs in working order: build, receive, keep, go live. */
export const TABS = [
  'overview',
  'fields',
  'entries',
  'mail',
  'webhooks',
  'storage',
  'keys',
  'publish',
] as const;
export type Tab = (typeof TABS)[number];

export type Route =
  | { name: 'login' }
  | { name: 'setup' }
  | { name: 'overview' }
  | { name: 'tenants' }
  | { name: 'formDirectory' }
  | { name: 'forms'; tenant: string }
  | { name: 'form'; tenant: string; form: string; tab: Tab }
  | { name: 'connections' }
  | { name: 'accounts' }
  | { name: 'settings' }
  | { name: 'ops' }
  | { name: 'audit' }
  | { name: 'installation' }
  | { name: 'migration' }
  | { name: 'account' }
  | { name: 'apiTokens' }
  | { name: 'members'; tenant: string }
  | { name: 'notFound' };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Pure path → route. Ids must be lower-case UUIDs, so a path can never smuggle anything into an API URL. */
export function matchRoute(path: string): Route {
  const p = path.split('/').filter((s, i) => s !== '' || i === 0);
  const seg = p.slice(1);
  if (seg.length === 1 && seg[0] === 'overview') return { name: 'overview' };
  if (seg.length === 1 && seg[0] === 'login') return { name: 'login' };
  if (seg.length === 1 && seg[0] === 'setup') return { name: 'setup' };
  if (seg.length === 1 && seg[0] === 'forms') return { name: 'formDirectory' };
  if (seg.length === 1 && seg[0] === 'connections') return { name: 'connections' };
  if (seg.length === 1 && seg[0] === 'accounts') return { name: 'accounts' };
  if (seg.length === 1 && seg[0] === 'api-tokens') return { name: 'apiTokens' };
  if (seg.length === 1 && seg[0] === 'ops') return { name: 'ops' };
  if (seg.length === 1 && seg[0] === 'audit') return { name: 'audit' };
  if (seg.length === 1 && seg[0] === 'installation') return { name: 'installation' };
  if (seg.length === 1 && seg[0] === 'migration') return { name: 'migration' };
  if (seg.length === 1 && seg[0] === 'settings') return { name: 'settings' };
  if (seg.length === 1 && seg[0] === 'account') return { name: 'account' };
  if (seg[0] === 't') {
    const tenant = seg[1];
    if (seg.length === 1) return { name: 'tenants' };
    if (tenant === undefined || !UUID.test(tenant)) return { name: 'notFound' };
    if (seg.length === 2) return { name: 'forms', tenant };
    if (seg.length === 3 && seg[2] === 'members') return { name: 'members', tenant };
    const form = seg[3];
    if (seg[2] === 'f' && form !== undefined && UUID.test(form) && seg.length <= 5) {
      // The flow editor does not exist yet; its former address opens the overview.
      const raw = seg[4] ?? 'overview';
      const tab = raw === 'flow' ? 'overview' : raw;
      if ((TABS as readonly string[]).includes(tab))
        return { name: 'form', tenant, form, tab: tab as Tab };
    }
  }
  return { name: 'notFound' };
}

export const OVERVIEW_PATH = '/overview';
export const FORM_DIRECTORY_PATH = '/forms';
/** The form directory, pre-filtered to one customer. */
export const formDirectoryPath = (tenant: string) => `/forms?kunde=${tenant}`;
export const tenantPath = (tenant: string) => `/t/${tenant}`;
export const formPath = (tenant: string, form: string, tab: Tab = 'overview') =>
  `/t/${tenant}/f/${form}${tab === 'overview' ? '' : `/${tab}`}`;

/** `next` after a re-login: only same-origin paths of this app. */
export function safeNext(raw: string | null): string | null {
  if (!raw || !raw.startsWith('/') || raw.startsWith('//') || raw.includes('\\')) return null;
  if (raw.startsWith('/oauth/authorize?')) return raw;
  return matchRoute(raw.split(/[?#]/)[0] ?? raw).name === 'notFound' ? null : raw;
}
