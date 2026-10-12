const CACHE_VERSION = 'couloak-v2';

const APP_SHELL = [
  './',
  './index.html',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => cache.addAll(APP_SHELL))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((key) => key !== CACHE_VERSION).map((key) => caches.delete(key)))
    )
  );
  self.clients.claim();
});

// Network-first for the page itself (index.html / navigations), falling
// back to the cache only when offline. The app shell used to be
// cache-first with a manually-bumped CACHE_VERSION as the only way to
// invalidate it - that's exactly the kind of step that's easy to forget
// (it was, for every release since this file was written), leaving
// installed PWAs stuck on old code indefinitely even after real fixes
// ship. Network-first means a deployed fix is just there on next load,
// no version bump required - offline support still works via the cache
// fallback, it just isn't the first thing tried.
//
// Icons/manifest rarely change and benefit more from cache-first (faster,
// and they're not where bugs get fixed), so those keep the old strategy.
self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;

  const isPage = event.request.mode === 'navigate' || event.request.url.endsWith('/index.html');

  if (isPage) {
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(CACHE_VERSION).then((cache) => cache.put(event.request, clone));
          }
          return response;
        })
        .catch(() => caches.match(event.request))
    );
    return;
  }

  event.respondWith(
    caches.match(event.request).then((cached) => {
      if (cached) return cached;

      return fetch(event.request)
        .then((response) => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(CACHE_VERSION).then((cache) => cache.put(event.request, clone));
          }
          return response;
        })
        .catch(() => cached);
    })
  );
});
