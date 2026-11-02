// Cache the single page so the home-screen app works offline.
const C = 'symbol-odds-v3';
self.addEventListener('install', e => e.waitUntil(caches.open(C).then(c => c.addAll(['./', 'index.html', 'manifest.webmanifest']))));
self.addEventListener('fetch', e => e.respondWith(
  fetch(e.request).then(r => { const k = r.clone(); caches.open(C).then(c => c.put(e.request, k)); return r; })
    .catch(() => caches.match(e.request, {ignoreSearch: true}))));
