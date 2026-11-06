// Service worker: caches ONLY static build assets (same origin, GET, hashed
// /assets/*, icons, manifest) plus the app shell. Never caches API responses
// or any other data: everything outside the allowlist goes straight to the network.
// The build placeholder below is replaced by vite.config.ts with a per-build hash, so every release
// gets its own cache and the old one is dropped on activate.
const BUILD = '__BUILD__';
const CACHE = `static-${BUILD}`;
const SHELL = ['/', '/manifest.webmanifest', '/icon.svg', '/theme-init.js'];
const HASHED_PATH = /^\/assets\/.+/;
const UNHASHED_PATH = /^\/(icon\.svg|manifest\.webmanifest|theme-init\.js)$/;
const DENY_PREFIXES = ['/api', '/admin', '/oauth', '/mcp', '/health', '/ready'];

function denied(pathname) {
  return DENY_PREFIXES.some((p) => pathname === p || pathname.startsWith(p + '/'));
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((c) => c.addAll(SHELL))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

function cacheable(res, hashed) {
  if (!res.ok || res.type !== 'basic') return false;
  // An SPA fallback can answer a missing hashed file with index.html (200).
  const type = res.headers.get('Content-Type') || '';
  return !(hashed && /text\/html/i.test(type));
}

function store(event, req, res) {
  const copy = res.clone();
  event.waitUntil(caches.open(CACHE).then((c) => c.put(req, copy)));
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (denied(url.pathname)) return;

  if (req.mode === 'navigate') {
    // Network first; offline fallback is the static shell only.
    event.respondWith(fetch(req).catch(() => caches.match('/').then((r) => r || Response.error())));
    return;
  }

  if (HASHED_PATH.test(url.pathname)) {
    // Content-hashed: immutable, cache first.
    event.respondWith(
      caches.match(req).then(
        (hit) =>
          hit ||
          fetch(req).then((res) => {
            if (cacheable(res, true)) store(event, req, res);
            return res;
          }),
      ),
    );
    return;
  }

  if (UNHASHED_PATH.test(url.pathname)) {
    // Not content-hashed: network first so releases reach clients, cache as offline fallback.
    event.respondWith(
      fetch(req)
        .then((res) => {
          if (cacheable(res, false)) store(event, req, res);
          return res;
        })
        .catch(() => caches.match(req).then((r) => r || Response.error())),
    );
  }
});
