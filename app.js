/* Glasses Hub (phone). Pairs with Glasses Hub on a Windows PC, then receives its notes as real push
   notifications (they arrive even when this app is closed), which your glasses show.

   PC <-> phone setup messages go through a relay (ntfy.sh), encrypted with a key derived from the
   pairing code. Notes arrive by Web Push, encrypted for this phone. Must match core.py on the PC. */
'use strict';
const VERSION = '1.0.0';
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const sleep = ms => new Promise(r => setTimeout(r, ms));
const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
  del(k) { try { localStorage.removeItem(k); } catch {} },
};
const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const standalone = () => window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
const RELAY = store.get('gh.relay', 'https://ntfy.sh');   // a self-hosted ntfy server works too

const S = Object.assign({ code: '', id: '', name: isIOS ? 'iPhone' : 'Phone', tw: 70, bw: 70, vapid: '', pc: '', paired: false },
  store.get('gh.settings', {}));
if (!S.id) { S.id = Array.from(crypto.getRandomValues(new Uint8Array(9)), b => b.toString(16).padStart(2, '0')).join(''); }
const save = () => store.set('gh.settings', S);
save();

const L = { es: null, d: null, connected: false, seen: new Set(), status: null, lastStatusAt: 0, waiters: [] };

function toast(text, ms = 2600) {
  const t = $('#toast'); t.textContent = text; t.classList.add('on');
  clearTimeout(toast.h); toast.h = setTimeout(() => t.classList.remove('on'), ms);
}

// ------------------------------------------------------------------ pairing crypto (matches core.py)
const ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
const normCode = c => [...String(c || '').toUpperCase()].filter(ch => ALPHABET.includes(ch)).join('');
const prettyCode = c => (normCode(c).match(/.{1,4}/g) || []).join('-');
async function sha256Bytes(str) { return new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(str))); }
async function derive(code) {
  const c = normCode(code);
  const h = [...await sha256Bytes('glasseshub-channel:' + c)].map(b => b.toString(16).padStart(2, '0')).join('').slice(0, 24);
  const key = await crypto.subtle.importKey('raw', await sha256Bytes('glasseshub-key:' + c), 'AES-GCM', false, ['encrypt', 'decrypt']);
  return { down: `gh-${h}`, up: `gh-${h}-up`, key };
}
async function dec(key, b64) {
  const raw = Uint8Array.from(atob(b64), ch => ch.charCodeAt(0));
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: raw.slice(0, 12) }, key, raw.slice(12));
  return JSON.parse(new TextDecoder().decode(pt));
}
async function enc(key, obj) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, new TextEncoder().encode(JSON.stringify(obj))));
  const all = new Uint8Array(12 + ct.length); all.set(iv); all.set(ct, 12);
  let bin = ''; for (const b of all) bin += String.fromCharCode(b);
  return btoa(bin);
}
function b64uToBytes(s) {
  s = s.replace(/-/g, '+').replace(/_/g, '/'); s += '='.repeat((4 - s.length % 4) % 4);
  return Uint8Array.from(atob(s), c => c.charCodeAt(0));
}

// ------------------------------------------------------------------ relay
function relayStop() { if (L.es) { try { L.es.close(); } catch {} } L.es = null; L.connected = false; }
async function relayStart() {
  relayStop();
  if (normCode(S.code).length !== 16) return;
  L.d = await derive(S.code);
  const es = new EventSource(`${RELAY}/${L.d.down}/sse?since=${Math.floor(Date.now() / 1000)}`);   // only new messages
  L.es = es;
  await new Promise(resolve => {
    const done = setTimeout(resolve, 8000);
    es.onopen = () => { L.connected = true; clearTimeout(done); render(); resolve(); };
  });
  es.onopen = () => { L.connected = true; render(); send('hello', helloExtra(), true); };
  es.onerror = () => { L.connected = false; render(); };
  es.onmessage = async ev => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    if (m.event && m.event !== 'message') return;
    if (!m.id || L.seen.has(m.id)) return;
    L.seen.add(m.id);
    let msg; try { msg = await dec(L.d.key, m.message); } catch { return; }
    if (msg.to && msg.to !== S.id) return;               // meant for another phone
    if (Date.now() / 1000 - (msg.t || 0) > 120) return;  // stale
    onMessage(msg);
  };
}
function helloExtra() { return { name: S.name, widths: { title: +S.tw || 70, body: +S.bw || 70 }, hasPush: 'PushManager' in window }; }
async function send(cmd, extra = {}, quiet = false) {
  if (!L.d) { if (!quiet) toast('Not paired yet.'); return false; }
  const body = await enc(L.d.key, Object.assign({ cmd, id: S.id, t: Date.now() / 1000 }, extra));
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await fetch(`${RELAY}/${L.d.up}`, { method: 'POST', body });
      if (r.ok) return true;
      throw new Error(`HTTP ${r.status}`);
    } catch (e) {
      if (attempt === 2) { if (!quiet) toast(`Couldn't reach your PC: ${e.message}`); return false; }
      await sleep(String(e.message).includes('429') ? 5000 : 1200);
    }
  }
}
function waitFor(type, ms = 15000) {
  return new Promise(resolve => {
    const w = { type, resolve }; L.waiters.push(w);
    setTimeout(() => { L.waiters = L.waiters.filter(x => x !== w); resolve(null); }, ms);
  });
}
function onMessage(msg) {
  for (const w of [...L.waiters]) if (w.type === msg.type) { L.waiters = L.waiters.filter(x => x !== w); w.resolve(msg); }
  if (msg.type === 'welcome' || msg.type === 'status') {
    L.status = msg; L.lastStatusAt = Date.now();
    if (msg.vapid) { if (S.vapid && S.vapid !== msg.vapid) S.subKey = ''; S.vapid = msg.vapid; }
    if (msg.pc) S.pc = msg.pc;
    S.paired = true; save();
    if (msg.type === 'welcome' && !L.pairing) ensurePush(false);
    render();
  } else if (msg.type === 'subscribed') {
    if (L.status) L.status.push = true;
    toast('Notifications are on. A test is on its way.');
    render();
  } else if (msg.type === 'toast') {
    toast(msg.text || '');
  } else if (msg.type === 'note') {
    showRelayNote(msg);           // fallback when push isn't available: works while the app is open
  }
}

// ------------------------------------------------------------------ push
async function reg() { return navigator.serviceWorker ? navigator.serviceWorker.ready : null; }
function pushSupported() { return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window; }

// Subscribe (or re-use the subscription) and send it to the PC when it's new or the PC doesn't have it.
async function ensurePush(fromTap) {
  if (!pushSupported() || !S.vapid) return 'unsupported';
  if (Notification.permission === 'default') {
    if (!fromTap) { render(); return 'needs-tap'; }
    const p = await Notification.requestPermission();
    if (p !== 'granted') { render(); return 'denied'; }
  }
  if (Notification.permission !== 'granted') { render(); return 'denied'; }
  const r = await reg();
  let sub = await r.pushManager.getSubscription();
  const key = b64uToBytes(S.vapid);
  if (sub && S.subKey !== S.vapid) { try { await sub.unsubscribe(); } catch {} sub = null; }   // PC has a new push key
  let fresh = false;
  if (!sub) {
    try {
      sub = await r.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
      fresh = true;
    } catch (e) {
      console.warn('subscribe failed', e);
      L.subError = e.message || String(e);
      render(); return 'needs-tap';
    }
  }
  L.subError = '';
  S.subKey = S.vapid; save();
  const json = sub.toJSON();
  const pcHasIt = L.status && L.status.push;
  if (fresh || !pcHasIt || S.sentEndpoint !== json.endpoint) {
    const ok = await send('subscribe', Object.assign(helloExtra(), { sub: { endpoint: json.endpoint, keys: json.keys } }), true);
    if (ok) { S.sentEndpoint = json.endpoint; save(); }
  }
  render();
  return 'ok';
}

async function showRelayNote(msg) {
  addHistory({ title: msg.title, body: msg.body, source: msg.source || 'hub', t: Date.now() });
  try {
    if ('Notification' in window && Notification.permission === 'granted') {
      const r = await reg();
      if (r) await r.showNotification(msg.title || 'Glasses Hub', { body: msg.body || '', tag: msg.tag });
    }
  } catch {}
}

// ------------------------------------------------------------------ history (IndexedDB, shared with sw.js)
function db() {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open('glasseshub', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('notes', { keyPath: 'id', autoIncrement: true });
    r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error);
  });
}
async function addHistory(n) {
  try { const d = await db(); await new Promise(res => { const tx = d.transaction('notes', 'readwrite'); tx.objectStore('notes').add(n); tx.oncomplete = res; tx.onerror = res; }); } catch {}
  renderHistory();
}
async function readHistory() {
  try {
    const d = await db();
    return await new Promise(res => { const q = d.transaction('notes').objectStore('notes').getAll(); q.onsuccess = () => res(q.result || []); q.onerror = () => res([]); });
  } catch { return []; }
}
async function renderHistory() {
  const list = (await readHistory()).reverse();
  const el = $('#history');
  if (!list.length) { el.innerHTML = '<div class="empty">Notes your PC sends will be listed here.</div>'; return; }
  const name = { nfl: 'NFL', trivia: 'Trivia', facts: 'Odd fact', send: 'Sent', hub: 'Glasses Hub' };
  el.innerHTML = list.map(n => `<div class="note ${esc(n.source)}"><div class="t">${esc(n.title)}</div>${n.body ? `<div class="b">${esc(n.body)}</div>` : ''}
    <div class="m">${esc(name[n.source] || n.source)} · ${new Date(n.t).toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' })}</div></div>`).join('');
}

// ------------------------------------------------------------------ UI
function setPill(text, cls = '') { const p = $('#pill'); p.textContent = text; p.className = 'pill ' + cls; }

function render() {
  const paired = S.paired && normCode(S.code).length === 16;
  $('#installCard').hidden = !(isIOS && !standalone());
  $('#pairCard').hidden = paired;
  $('#connCard').hidden = !paired;
  $('#plugCard').hidden = !paired;
  if (!paired) { setPill(L.connected ? 'Pairing…' : 'Not paired'); }
  const perm = 'Notification' in window ? Notification.permission : 'unsupported';
  const pushOn = pushSupported() && perm === 'granted' && S.subKey && S.subKey === S.vapid;
  let state = '';
  if (paired) {
    $('#connTitle').textContent = S.pc ? `Paired with ${S.pc}` : 'Paired';
    if (!pushSupported()) state = `<span class="warn">This browser can't receive push notifications.</span> ${isIOS ? 'Open Glasses Hub from your Home Screen.' : ''} Notes still arrive while this app is open.`;
    else if (perm === 'denied') state = '<span class="err">Notifications are blocked.</span> Turn them on in iPhone Settings → Notifications → Glasses Hub.';
    else if (pushOn && L.status && L.status.push === false && L.lastStatusAt) state = '<span class="warn">Reconnecting notifications…</span>';
    else if (pushOn) state = '<span class="ok">● Notifications on.</span> Notes arrive even when this app is closed and your phone is locked.';
    else state = `<span class="warn">Notifications aren't on yet.</span> Tap <b>Turn on notifications</b>.${L.subError ? ` (${esc(L.subError)})` : ''}`;
    if (!L.connected) state += '<br><span class="warn">Can\'t reach the relay right now.</span> Controls below need it; notifications don\'t.';
    else if (!L.lastStatusAt || Date.now() - L.lastStatusAt > 60000) state += '<br>Checking that your PC is on…';
    setPill(pushOn ? (L.connected ? 'Connected' : 'Notifications on') : 'Needs setup', pushOn ? 'ok' : 'warn');
  }
  $('#connState').innerHTML = state;
  $('#fixBtn').hidden = !(paired && pushSupported() && perm !== 'denied' && !pushOn);
  $('#setState').innerHTML = paired ? `Paired with <b>${esc(S.pc || 'your PC')}</b> using code ${esc(prettyCode(S.code))}.` : 'Not paired.';
  renderPlugins();
}

function renderPlugins() {
  const el = $('#plugins');
  const st = L.status;
  if (!st || !st.plugins) {
    el.innerHTML = `<div class="empty">${L.connected ? 'Waiting for your PC… Is Glasses Hub running?' : 'Connecting…'}</div>`;
    return;
  }
  el.innerHTML = st.plugins.map(p => `<div class="plug">
      <div class="head"><b>${esc(p.name)}</b>
        <label class="switch"><input type="checkbox" data-toggle="${esc(p.id)}" ${p.on ? 'checked' : ''}><span></span></label></div>
      <div class="sub">${esc(p.on ? (p.state || 'On') : 'Off')}</div>
      <div class="acts">${p.actions.map(a => `<button class="btn" data-plugin="${esc(p.id)}" data-action="${esc(a.id)}" ${p.on ? '' : 'disabled'}>${esc(a.label)}</button>`).join('')}</div>
    </div>`).join('') + (st.quiet ? '<div class="hint">Quiet hours are on at your PC: only things you ask for come through.</div>' : '');
  el.querySelectorAll('[data-toggle]').forEach(cb => cb.onchange = async () => {
    await send('toggle', { plugin: cb.dataset.toggle, on: cb.checked });
  });
  el.querySelectorAll('[data-action]').forEach(b => b.onclick = async () => {
    b.disabled = true;
    const ok = await send('action', { plugin: b.dataset.plugin, action: b.dataset.action });
    if (ok) toast(`${b.textContent}: sent to your PC`, 1600);
    setTimeout(() => { b.disabled = false; }, 1500);
  });
}

async function pair() {
  const code = normCode($('#code').value);
  if (code.length !== 16) { $('#pairMsg').textContent = 'The code has 16 letters and numbers, like ABCD-EFGH-JKLM-NPQR.'; return; }
  const btn = $('#pairBtn'); btn.disabled = true; L.pairing = true;
  $('#pairMsg').textContent = 'Connecting to your PC…';
  try {
    // ask for notification permission right away, while we still have the tap (iPhone requires it)
    if (pushSupported() && Notification.permission === 'default') { try { await Notification.requestPermission(); } catch {} }
    if (S.code !== code) { S.vapid = ''; S.subKey = ''; S.sentEndpoint = ''; }
    S.code = code; S.paired = false; save();
    await relayStart();
    const welcome = waitFor('welcome', 20000);
    await send('hello', helloExtra());
    const w = await welcome;
    if (!w) { $('#pairMsg').textContent = "Your PC didn't answer. Check that Glasses Hub is running and the code matches, then try again."; return; }
    $('#pairMsg').textContent = '';
    const r = await ensurePush(true);
    if (r === 'needs-tap') toast('Almost done: tap "Turn on notifications".', 4000);
    else if (r === 'denied') toast('Notifications are blocked for this app.', 4000);
  } catch (e) {
    $('#pairMsg').textContent = `Something went wrong: ${e.message}`;
  } finally { btn.disabled = false; L.pairing = false; render(); }
}

// Size the app to the area iOS lets a web app draw in (iOS 26 leaves a band at the bottom).
function fitScreen() {
  const h = window.innerHeight;
  document.documentElement.style.setProperty('--app-h', h + 'px');
  const tall = Math.max(screen.height, screen.width), short = Math.min(screen.height, screen.width);
  const full = window.matchMedia('(orientation: portrait)').matches ? tall : short;
  document.documentElement.classList.toggle('ios-band', isIOS && standalone() && full - h > 20);
}

function show(v) {
  document.querySelectorAll('.view').forEach(x => x.classList.toggle('on', x.id === 'v-' + v));
  document.querySelectorAll('#tabs button').forEach(b => b.classList.toggle('on', b.dataset.v === v));
  if (v === 'history') renderHistory();
}

async function init() {
  fitScreen();
  window.addEventListener('resize', fitScreen);
  window.addEventListener('orientationchange', () => setTimeout(fitScreen, 300));
  $('#ver').textContent = VERSION;
  document.querySelectorAll('#tabs button').forEach(b => b.onclick = () => show(b.dataset.v));
  $('#code').value = prettyCode(S.code);
  $('#code').addEventListener('input', e => {
    const c = normCode(e.target.value).slice(0, 16); const p = prettyCode(c);
    if (e.target.value !== p) e.target.value = p;
  });
  $('#pairBtn').onclick = pair;
  $('#fixBtn').onclick = async () => { const r = await ensurePush(true); if (r === 'denied') toast('Notifications are blocked. Turn them on in iPhone Settings → Notifications.', 4500); };
  $('#testBtn').onclick = async () => { if (await send('test')) toast('Test requested. It should arrive in a few seconds.'); };
  $('#clearBtn').onclick = async () => { try { const d = await db(); d.transaction('notes', 'readwrite').objectStore('notes').clear(); } catch {} setTimeout(renderHistory, 200); };
  $('#s-name').value = S.name; $('#s-tw').value = S.tw; $('#s-bw').value = S.bw;
  $('#saveBtn').onclick = async () => {
    S.name = $('#s-name').value.trim() || S.name;
    S.tw = Math.max(20, Math.min(200, parseInt($('#s-tw').value, 10) || 70));
    S.bw = Math.max(20, Math.min(200, parseInt($('#s-bw').value, 10) || 70));
    save(); $('#s-tw').value = S.tw; $('#s-bw').value = S.bw;
    if (L.d) await send('hello', helloExtra(), true);
    toast('Saved.');
  };
  $('#repairBtn').onclick = () => { S.paired = false; save(); show('home'); render(); $('#code').focus(); };
  $('#forgetBtn').onclick = async () => {
    if (!confirm('Disconnect this phone from your PC?')) return;
    await send('forget', {}, true);
    try { const r = await reg(); const s = r && await r.pushManager.getSubscription(); if (s) await s.unsubscribe(); } catch {}
    relayStop();
    Object.assign(S, { code: '', vapid: '', subKey: '', sentEndpoint: '', pc: '', paired: false }); save();
    L.status = null; $('#code').value = ''; show('home'); render();
  };

  if ('serviceWorker' in navigator) {
    try { await navigator.serviceWorker.register('sw.js'); } catch (e) { console.warn('service worker', e); }
    navigator.serviceWorker.addEventListener('message', ev => {
      if (ev.data && ev.data.type === 'note') renderHistory();
      if (ev.data && ev.data.type === 'subchange') ensurePush(false);
    });
  }
  render();
  renderHistory();
  if (normCode(S.code).length === 16) {
    await relayStart();
    await send('hello', helloExtra(), true);
  }
  // check in with the PC when the app comes back to the front
  document.addEventListener('visibilitychange', async () => {
    if (document.visibilityState !== 'visible' || normCode(S.code).length !== 16) return;
    if (!L.es || L.es.readyState === 2) await relayStart();
    send('status', {}, true);
    renderHistory();
  });
  setInterval(() => { if (document.visibilityState === 'visible') render(); }, 15000);
}

window.__gh = { S, L, derive, enc, dec, ensurePush, onMessage, render, readHistory };
init();
