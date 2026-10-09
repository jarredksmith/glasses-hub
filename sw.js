/* Glasses Hub service worker: shows pushed notes (even when the app is closed), keeps a short history,
   and makes the app work offline after the first load. */
const CACHE = 'glasseshub-v1';
const SHELL = ['./', 'index.html', 'app.js', 'manifest.webmanifest', 'icon-180.png', 'icon-192.png', 'icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== self.location.origin) return;
  e.respondWith(
    fetch(e.request).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
      return res;
    }).catch(() => caches.match(e.request).then(r => r || caches.match('index.html')))
  );
});

// ---- history (IndexedDB, shared with the page)
function db() {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open('glasseshub', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('notes', { keyPath: 'id', autoIncrement: true });
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}
async function saveNote(n) {
  try {
    const d = await db();
    await new Promise((resolve, reject) => {
      const tx = d.transaction('notes', 'readwrite');
      const st = tx.objectStore('notes');
      st.add(n);
      // keep the newest 100
      const keys = st.getAllKeys();
      keys.onsuccess = () => { const k = keys.result; for (let i = 0; i < k.length - 100; i++) st.delete(k[i]); };
      tx.oncomplete = resolve; tx.onerror = () => reject(tx.error);
    });
  } catch (e) { /* history is a nice-to-have */ }
}
async function tellPages(msg) {
  const list = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  for (const c of list) c.postMessage(msg);
}

// ---- pushes from the PC (standard Web Push; the payload is also valid Declarative Web Push)
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { notification: { title: 'Glasses Hub', body: e.data ? e.data.text() : '' } }; }
  const n = d.notification || d;
  const title = (n.title || '').trim() || 'Glasses Hub';
  const opts = { body: n.body || '', data: { url: n.navigate || self.registration.scope } };
  if (n.tag) opts.tag = n.tag;
  const note = { title, body: opts.body, source: (d.gh && d.gh.source) || 'hub', t: Date.now() };
  e.waitUntil(Promise.all([
    self.registration.showNotification(title, opts),
    saveNote(note).then(() => tellPages({ type: 'note', note })),
  ]));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) if ('focus' in c) return c.focus();
    return self.clients.openWindow((e.notification.data && e.notification.data.url) || './');
  }));
});

// iOS can replace a subscription; tell the page so it can send the new one to the PC next time it opens
self.addEventListener('pushsubscriptionchange', e => {
  e.waitUntil(tellPages({ type: 'subchange' }));
});
