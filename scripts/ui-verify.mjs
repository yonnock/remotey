// Drives the page in headless Chromium with real multi-touch events and records what it would send to the Mac.
// No agent, no network: the page gets a fake WebSocket and a visual viewport whose size the script sets, so
// the keyboard can be "opened". Chromium is not iOS Safari: this checks the page's own logic and layout,
// not WebKit's keyboard, safe areas or gesture handling.
// Usage: node scripts/ui-verify.mjs [--web=Web] [--json=out.json] [--only=T1,T9] [--shots=DIR]
// --shots saves pictures of the page at moments T8, T10 to T14, T16 and T17 name, for looking at what they measure.
import { spawn } from 'node:child_process';
import { createHash, createPublicKey, randomBytes, verify } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { createServer } from 'node:http';
import { homedir, tmpdir } from 'node:os';
import { extname, join, resolve } from 'node:path';

// 2: a lifted finger is released with its own touchEnd (Chromium does not release a point left out of a touchMove).
// 3: also a 320 px phone (Display Zoom), and the full view key upright.
// 4: no full view key (the dock leaves the display the height it had); reports the display's share upright too.
// 5: T6 sets the pointer speed on the Regler page and checks the next move; T7 opens and closes the tray.
// 6: the side buttons (back, forward) count as main actions; T8 taps them.
// 7: T2 also zooms out, upright and sideways: by pinch, by the − key, and up to the limit a fake Mac answers with.
// 8: T2 also turns the phone and back: each way of holding it keeps its own zoom.
// 9: the Apps key counts as a main action; T9 opens the switcher, with a socket that answers `apps`.
// 10: T10 locks the fake Mac: the type key's field takes the password and sends it whole.
// 11: the zoom readout switches "Auto" (T11, with a fake Mac that answers with fitted pictures) and no longer
//     returns to 1×, which T2 now reaches with the zoom keys; T12 opens the display picker on a Mac with three
//     displays; T8 also taps the keys for an app's zoom.
// 12: T13 switches "Telefonform" on in the Apps sheet: the zoom keys and the pinch then ask the Mac for another
//     size of the window instead of ending "Auto", and a page that goes out of sight switches the view off.
// 13: T10 also measures the lock key on the tray's first page on every phone and taps it with a modifier armed.
// 14: T14 enrols the phone for Face ID and unlocks with it; Chromium's virtual authenticator is the passkey. The
//     page is loaded from `localhost`, since a passkey belongs to a host name. T10 and T14 also tap the lock key on
//     a locked Mac, which unlocks as the type key does.
// 15: updates carry the view's place and height; T15 moves the pointer and checks that the page shows the move
//     before the fake Mac answers, keeps it there with the answer, and stops it at the display's edge. T12 counts
//     the page's question for the displays when it connects apart from the one the sheet asks.
// 16: T15 draws the pointer ahead only with "Telefonform" on, and first checks that without it the pointer waits.
// 17: the words come from a table (Web/strings.js) and the page runs in German unless a task asks for English;
//     the new names (Klick, Rechtsklick, Live-Bild, Fenster einpassen, An iPhone anpassen, Steuerung,
//     Einstellungen, Zurücksetzen, Auf dem Mac schreiben, Mac entsperren, Mit Face ID entsperren) replace the old
//     ones in every check. "Auto" and "Form" are symbols over the zoom (T11, T13). T16 walks the connection's
//     states with a fake Mac that is out of reach, not running, refuses the key or lacks a permission; T17 checks
//     type sizes, capitals, the longer words at 320 px in both languages and 44 pt touch targets; T18 checks
//     the protocol fixes: heartbeat, long text in pieces, icons kept across a reconnect, the readout as a setting.
// 18: the page is "Glas über dem Mac". The picture element covers the phone and the controls float over it; the
//     page tells the Mac what they cover (`inset`), and T1 measures the share of the phone the picture shows
//     unobscured, from that inset (before: the share of the display element). The readout opens the view's menu, which
//     holds "Fenster einpassen", "An iPhone anpassen", actual size, the whole desktop and the displays (T11 to T13 reach
//     them there; T12 measures the map in the menu). The settings are a sheet of their own, reached from the Mac's
//     button (T1, T6, T18). Sheets lie over the bar, so T7 no longer counts what covers the dock. The lock key is a
//     tile beside the mute key (T10). The fake Mac pairs per device: `/pair`, `/session` and tickets (T19), and says
//     `mac` (T20). New: T19 pairing, T20 glass, insets and the Mac's state, T21 the gesture tour, T22 sideways sides.
//     --gallery=DIR saves every screen, dark and light, with a drawn Mac desktop as the picture.
// 19: the fake Mac can end a session (`__bye`: `bye`, then the socket closes); T16 checks that the page stays
//     disconnected through coming back into sight and the network's return, and connects again on the notice's button.
//     The gallery adds the screen for it (`ended-*`).
// 20: T6 also swipes the settings' list from a row, a slider's track and a switch: the list scrolls and nothing is
//     set; sideways along a row slides its value; a tap flips a switch. T19: a phone the Mac knows asks for a ticket
//     first and hands its old token over only when the Mac does not know it.
// 21: the machine's own wishes stay out (reduced transparency and motion, contrast: a CI runner has them set), the
//     fake Mac's slow answer takes 1.5 s instead of 0.4 s, and T20 counts view requests once they have come to rest.
//     --slow=N gives the page a fraction of the processor.
// 22: the page's frame clock is 60 a second on every machine: a runner that draws slower had the page measure 30 or
//     55 and ask for the view again in the middle of T8, T13 and T20.
export const VERIFIER_VERSION = 23;
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const webDir = resolve(arg('web', new URL('../Web', import.meta.url).pathname));
const only = arg('only', '')?.split(',').filter(Boolean);
const shots = arg('shots', '');
// --slow=4 gives the page a quarter of the processor, as a busy CI runner does: what only passes on a fast machine fails here too.
const slow = Number(arg('slow', '1')) || 1;
// How long the fake Mac takes where a task makes it slow to answer: longer than the measuring takes on a slow machine.
const SLOW_ANSWER = 1500;
if (shots) mkdirSync(shots, { recursive: true });
const gallery = arg('gallery', '');
if (gallery) mkdirSync(gallery, { recursive: true });
// --docs=DIR: the README's pictures (remote.png, apps.png, keys.png) at 390 × 844, twice the pixels.
const docs = arg('docs', '');
if (docs) mkdirSync(docs, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function chromePath() {
  const root = join(homedir(), 'Library/Caches/ms-playwright');
  const dir = existsSync(root) && readdirSync(root).filter((d) => d.startsWith('chromium_headless_shell')).sort().at(-1);
  if (!dir) throw new Error('no chrome-headless-shell in ~/Library/Caches/ms-playwright');
  return join(root, dir, readdirSync(join(root, dir)).find((d) => d.startsWith('chrome-headless-shell')), 'chrome-headless-shell');
}

const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' };
// The fake Mac's pairing, as the agent's contract has it: `/pair` takes a one-time code or the old token and sets a
// cookie the page cannot read; `/session` gives a ticket to a phone with that cookie. `mode: 'old'` plays an agent
// from before pairing per device, which knows neither route. Tasks set what they need and read `log`.
const fakeMac = { mode: 'devices', code: '482913', closed: false, tries: 0, most: 5, tickets: 0, log: [] };
const resetMac = () => Object.assign(fakeMac, { mode: 'devices', code: '482913', closed: false, tries: 0, log: [] });
const answer = (res, status, json, cookie) => {
  res.writeHead(status, { 'Content-Type': 'application/json', ...(cookie && { 'Set-Cookie': 'remotey-device=d1; Path=/; HttpOnly; SameSite=Strict' }) });
  res.end(json === undefined ? '' : JSON.stringify(json));
};
const server = createServer((req, res) => {
  const path = req.url.split('?')[0];
  if (req.method === 'POST') {
    let text = '';
    req.on('data', (d) => { text += d; });
    req.on('end', () => {
      let body = {};
      try { body = JSON.parse(text || '{}'); } catch {}
      const paired = /(^|;\s*)remotey-device=d1/.test(req.headers.cookie ?? '');
      fakeMac.log.push({ path, body, paired });
      if (fakeMac.mode === 'old' || !['/pair', '/session'].includes(path)) { res.writeHead(404); res.end(); return; }
      if (path === '/session') return paired ? answer(res, 200, { ticket: `t${++fakeMac.tickets}` }) : answer(res, 401, { why: 'unpaired' });
      if (body.token !== undefined) return body.token === 'test-token' ? answer(res, 200, { ok: true, device: { id: 'd1', name: 'iPhone Test' } }, true) : answer(res, 403, { ok: false, why: 'code' });
      if (fakeMac.closed) return answer(res, 403, { ok: false, why: 'closed' });
      if (fakeMac.tries >= fakeMac.most) return answer(res, 429);
      if (body.code === fakeMac.code) return answer(res, 200, { ok: true, device: { id: 'd1', name: 'iPhone Test' } }, true);
      fakeMac.tries++;
      return answer(res, 403, { ok: false, why: 'code' });
    });
    return;
  }
  const name = path === '/' ? 'index.html' : path.slice(1);
  try {
    const body = readFileSync(join(webDir, name));
    res.writeHead(200, { 'Content-Type': types[extname(name)] ?? 'application/octet-stream' });
    res.end(body);
  } catch { res.writeHead(404); res.end(); }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const origin = `http://localhost:${server.address().port}`;

const profile = mkdtempSync(join(tmpdir(), 'remotey-ui-'));
const chrome = spawn(chromePath(), ['--headless', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
  '--no-first-run', '--disable-gpu', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const wsUrl = await new Promise((r, j) => {
  let text = '';
  chrome.stderr.on('data', (d) => { text += d; const m = text.match(/ws:\/\/[^\s]+/); if (m) r(m[0]); });
  setTimeout(() => j(new Error('chrome did not start')), 10000);
});

// ---- Minimal CDP client
const socket = new WebSocket(wsUrl);
await new Promise((r) => { socket.onopen = r; });
let nextId = 0;
const waiting = new Map();
socket.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && waiting.has(m.id)) { const { r, j } = waiting.get(m.id); waiting.delete(m.id); m.error ? j(new Error(m.error.message)) : r(m.result); }
  if (m.method === 'Runtime.exceptionThrown') pageErrors.get(m.sessionId)?.push(m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text);
};
// Exceptions the page threw, by session: a task can say what broke instead of only that something did.
const pageErrors = new Map();
const cdp = (method, params = {}, sessionId) => new Promise((r, j) => {
  const id = ++nextId;
  waiting.set(id, { r, j });
  socket.send(JSON.stringify({ id, method, params, sessionId }));
});

// What the fake Mac has open: an app in front with two windows (one title is markup, as a web page may set it),
// one with a single minimized window, a hidden one without windows, and enough others to fill three rows.
const APPS = [
  { pid: 501, name: 'Safari', icon: 'safari', front: true, hidden: false, windows: [
    { id: 11, title: 'Remotey', min: false, main: true }, { id: 12, title: '<img src=x onerror="window.__xss = 1">', min: false, main: false }] },
  { pid: 502, name: 'Mail', icon: 'mail', front: false, hidden: false, windows: [{ id: 13, title: 'Eingang', min: true, main: true }] },
  { pid: 503, name: 'Musik', icon: 'music', front: false, hidden: true, windows: [] },
  ...['Kalender', 'Nachrichten', 'Systemeinstellungen', 'Terminal', 'Notizen', 'Vorschau', 'Karten', 'Fotos', 'Finder']
    .map((name, i) => ({ pid: 510 + i, name, icon: name, front: false, hidden: false, windows: [] })),
];
// The fake Mac's displays in T12: a laptop above two large displays side by side. One name is markup.
const DISPLAYS = [
  { id: 1, name: 'Built-in Retina Display', x: 0, y: 0, w: 2056, h: 1329, pointer: true },
  { id: 2, name: 'Studio Display', x: -1939, y: 1329, w: 3008, h: 1692, pointer: false },
  { id: 3, name: '<img src=y onerror="window.__xss = 1">', x: 1069, y: 1329, w: 3008, h: 1692, pointer: false },
];
// A 1x1 PNG for the one icon the fake Mac sends.
const ICON = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

// Runs in the page before its own scripts.
const harness = `(() => {
  const sent = window.__sent = [];
  // The phone's frame clock: 60 a second, whatever this machine manages. The page measures it to ask the Mac for
  // a frame rate, and asks again when it finds another: on a slow machine in the middle of a task, as one more
  // view request nobody counted on. \`__frame\` is the machine's own clock, for what a task times itself.
  const frame = window.__frame = window.requestAnimationFrame.bind(window);
  let frames = 0;
  window.requestAnimationFrame = (step) => frame(() => step(++frames * 1000 / 60));
  // The fake Mac. \`__mac\` says how it answers a new socket: 'up' (default), 'down' (the socket fails, as when
  // the Mac is out of reach or Remotey is not running), 'noax' (no Accessibility permission) or 'deny' (the key
  // is refused). \`__probe\` is what a request for the page's own origin gets: a status, or null for no answer.
  window.__sockets = [];
  window.WebSocket = class {
    constructor() {
      window.__socket = this; this.readyState = 0; window.__sockets.push(performance.now());
      if (window.__mac === 'down') { setTimeout(() => { this.readyState = 3; this.onclose?.(); }, 0); return; }
      setTimeout(() => { this.readyState = 1; this.onopen?.(); }, 0);
    }
    send(data) {
      const m = JSON.parse(data);
      sent.push({ ...m, at: performance.now() });
      if (m.t === 'view') window.__view = m; // outlives a task's clearing of the list
      // A ticket from \`/session\` or the old token; \`revoked\`: the Mac removed this phone.
      const good = (m.ticket && /^t\\d+$/.test(m.ticket)) || m.token === 'test-token';
      if (m.t === 'auth') setTimeout(() => this.onmessage?.({ data: JSON.stringify(window.__mac === 'deny' || !good ? { t: 'denied', why: m.ticket ? 'ticket' : 'token' }
        : window.__mac === 'revoked' ? { t: 'denied', why: 'revoked' }
        : { t: 'ok', ax: window.__mac !== 'noax', page: 'test', name: window.__macName ?? 'MacBook Pro', device: 'iPhone Test' }) }), 0);
      if (m.t === 'ping' && !window.__silent) setTimeout(() => this.onmessage?.({ data: JSON.stringify({ t: 'pong' }) }), 0);
      if (m.t === 'apps') setTimeout(() => {
        this.onmessage?.({ data: JSON.stringify({ t: 'apps', list: ${JSON.stringify(APPS)} }) });
        this.onmessage?.({ data: JSON.stringify({ t: 'icon', id: 'safari', png: '${ICON}' }) });
        // For pictures (--gallery, --docs): a drawn icon for every app, a coloured tile with a letter.
        if (window.__icons) ${JSON.stringify(APPS.map((a) => a.icon))}.forEach((id, i) => {
          const c = Object.assign(document.createElement('canvas'), { width: 120, height: 120 }), x = c.getContext('2d');
          const hues = [212, 200, 330, 4, 140, 220, 0, 48, 262, 24, 160, 210];
          const g = x.createLinearGradient(0, 0, 0, 120); g.addColorStop(0, 'hsl(' + hues[i] + ' 80% 62%)'); g.addColorStop(1, 'hsl(' + hues[i] + ' 75% 46%)');
          x.fillStyle = g; x.beginPath(); x.roundRect(6, 6, 108, 108, 26); x.fill();
          x.fillStyle = 'rgba(255,255,255,0.95)'; x.font = '600 56px -apple-system, system-ui, sans-serif'; x.textAlign = 'center'; x.textBaseline = 'middle';
          x.fillText(id[0].toUpperCase(), 60, 64);
          this.onmessage?.({ data: JSON.stringify({ t: 'icon', id, png: c.toDataURL('image/png').split(',')[1] }) });
        });
      }, window.__appsDelay ?? 0); // T9 makes the Mac slow to answer
      // One display unless a task plugs in more: then the picker shows.
      if (m.t === 'displays') setTimeout(() => this.onmessage?.({ data: JSON.stringify({ t: 'displays', list: window.__displays ?? [${JSON.stringify(DISPLAYS[0])}] }) }),
        window.__appsDelay ?? 0);
    }
    close() { this.readyState = 3; }
  };
  // "Trennen" in the Mac's menu: the Mac says \`bye\` and closes the connection right after.
  window.__bye = () => { const s = window.__socket; s.onmessage?.({ data: JSON.stringify({ t: 'bye' }) }); s.readyState = 3; s.onclose?.(); };
  window.__probe = 200;
  const realFetch = window.fetch.bind(window);
  window.fetch = (url, options) => (options?.method === 'HEAD'
    ? (window.__probe === null ? Promise.reject(new TypeError('Load failed')) : Promise.resolve(new Response(null, { status: window.__probe })))
    : realFetch(url, options));
  Object.defineProperty(navigator, 'onLine', { get: () => window.__online !== false, configurable: true });
  // The phone's language: German, unless a task asks for another one.
  Object.defineProperty(navigator, 'languages', { get: () => [localStorage.getItem('test-lang') ?? 'de-DE'], configurable: true });
  const vv = new EventTarget();
  Object.assign(vv, { width: innerWidth, height: innerHeight, offsetTop: 0, offsetLeft: 0, pageTop: 0, pageLeft: 0, scale: 1 });
  window.__vv = { set(next) { Object.assign(vv, next); vv.dispatchEvent(new Event('resize')); vv.dispatchEvent(new Event('scroll')); },
    reset() { this.set({ width: innerWidth, height: innerHeight, offsetTop: 0 }); } };
  Object.defineProperty(window, 'visualViewport', { value: vv, configurable: true });
  addEventListener('resize', () => { if (!window.__kb) Object.assign(vv, { width: innerWidth, height: innerHeight }); });
  // The Mac's answer to the newest view request: a JPEG picture of the display's aspect that shows \`points\` Mac
  // points across, in the format of Wire.swift. Resolves once the page had time to draw it. \`fitted\`: the Mac
  // chose the zoom itself, for the window in front, which the picture then shows as a light sheet.
  window.__picture = async (points, fitted = false) => {
    const request = window.__view, socket = window.__socket;
    // 256 pixels across: a narrower picture rounds its height so far off the display's aspect that the pointer is drawn
    // half a point beside its place (seen in version 17, with a display one pixel wider than before).
    const canvas = Object.assign(document.createElement('canvas'), { width: 256, height: Math.max(2, Math.round(256 * request.h / request.w)) });
    const context = canvas.getContext('2d');
    context.fillRect(0, 0, canvas.width, canvas.height);
    if (fitted) { context.fillStyle = '#d9dce1'; context.fillRect(0, canvas.height * 0.3, canvas.width, canvas.height * 0.4); }
    const jpeg = new Uint8Array(await (await new Promise((r) => canvas.toBlob(r, 'image/jpeg'))).arrayBuffer());
    const packet = new Uint8Array(47 + jpeg.length), head = new DataView(packet.buffer);
    packet.set([1, 30, fitted ? 2 : 0]);
    // The pointer in the middle of a view that has its left top at the Mac's origin.
    [0.5, 0.5, 0.5, 0.5, points, points * request.h / request.w, 0, 0].forEach((value, i) => head.setFloat32(3 + i * 4, value, true));
    head.setUint32(39, request.v, true);
    head.setUint32(43, window.__pictures = (window.__pictures ?? 0) + 1, true);
    packet.set(jpeg, 47);
    window.__shows = [points, points * request.h / request.w, fitted];
    socket.onmessage?.({ data: packet.buffer });
    await new Promise((r) => setTimeout(r, 150));
  };
  // The Mac's answer to pointer moves up to the one numbered \`q\`: the pointer is at \`x\`, \`y\` (Mac points) in the
  // view of the last picture, which stays as it is.
  window.__pointer = async (x, y, q) => {
    const packet = new Uint8Array(47), head = new DataView(packet.buffer), [w, h, fitted] = window.__shows;
    packet.set([0, 30, fitted ? 2 : 0]);
    [x / w, y / h, x / w, y / h, w, h, 0, 0].forEach((value, i) => head.setFloat32(3 + i * 4, value, true));
    head.setUint32(35, q, true);
    window.__socket.onmessage?.({ data: packet.buffer });
    await new Promise((r) => setTimeout(r, 50));
  };
  try { const lang = localStorage.getItem('test-lang'), tour = localStorage.getItem('test-tour'); localStorage.clear();
    if (lang) localStorage.setItem('test-lang', lang); if (tour) localStorage.setItem('test-tour', tour);
    localStorage.setItem('remotey-view', '1'); localStorage.setItem('remotey-zoom', '0.5');
    // The tour starts by itself on a phone that never saw it; tasks other than T21 are that phone's later days.
    if (!tour) localStorage.setItem('remotey-toured', 'true'); } catch {}
  // A made-up Mac desktop as the picture, for the pictures --gallery saves: what \`kind\` shows, \`points\` across.
  window.__scene = async (kind, points, flags = 2) => {
    const fitted = (flags & 2) === 2;
    const request = window.__view, socket = window.__socket, [top, right, bottom, left] = request.inset ?? [0, 0, 0, 0];
    const k = 2, W = Math.round(request.w * k), H = Math.round(request.h * k);
    const canvas = Object.assign(document.createElement('canvas'), { width: W, height: H }), c = canvas.getContext('2d');
    c.scale(k, k);
    const w = request.w, h = request.h, inner = { x: left, y: top, w: w - left - right, h: h - top - bottom };
    const round = (x, y, rw, rh, r) => { c.beginPath(); c.roundRect(x, y, rw, rh, r); };
    // The wallpaper: dusk over hills.
    const sky = c.createLinearGradient(0, 0, w * 0.4, h);
    sky.addColorStop(0, '#2b2d6e'); sky.addColorStop(0.45, '#6b3f7d'); sky.addColorStop(0.8, '#c9645a'); sky.addColorStop(1, '#e9925a');
    c.fillStyle = sky; c.fillRect(0, 0, w, h);
    c.fillStyle = 'rgba(255,255,255,0.06)'; c.beginPath(); c.ellipse(w * 0.85, h * 0.18, w * 0.5, h * 0.16, -0.3, 0, 7); c.fill();
    c.fillStyle = 'rgba(40,20,60,0.35)'; c.beginPath(); c.ellipse(w * 0.1, h * 0.95, w * 0.8, h * 0.22, 0.2, 0, 7); c.fill();
    const bar = Math.max(0, inner.y - 22);
    const text = (t, x, y, size, color, weight = 400, align = 'left') => { c.font = weight + ' ' + size + 'px -apple-system, system-ui, sans-serif'; c.fillStyle = color; c.textAlign = align; c.fillText(t, x, y); };
    if (kind === 'lock') {
      text('Donnerstag, 26. November', w / 2, inner.y + inner.h * 0.16, 14, 'rgba(255,255,255,0.8)', 500, 'center');
      text('14:42', w / 2, inner.y + inner.h * 0.16 + 62, 64, 'rgba(255,255,255,0.92)', 700, 'center');
      c.fillStyle = 'rgba(255,255,255,0.28)'; c.beginPath(); c.arc(w / 2, inner.y + inner.h * 0.58, 30, 0, 7); c.fill();
      c.fillStyle = 'rgba(255,255,255,0.85)'; c.beginPath(); c.arc(w / 2, inner.y + inner.h * 0.58 - 6, 11, 0, 7); c.fill();
      c.beginPath(); c.ellipse(w / 2, inner.y + inner.h * 0.58 + 18, 18, 11, 0, Math.PI, 0); c.fill();
      text('Erika', w / 2, inner.y + inner.h * 0.58 + 52, 13, '#fff', 600, 'center');
      round(w / 2 - 62, inner.y + inner.h * 0.58 + 64, 124, 22, 11); c.fillStyle = 'rgba(255,255,255,0.22)'; c.fill();
      text('Passwort eingeben', w / 2, inner.y + inner.h * 0.58 + 79, 10, 'rgba(255,255,255,0.75)', 400, 'center');
    } else {
      // The menu bar, at the top of what the Mac fits; under the glass above it, more wallpaper.
      c.fillStyle = 'rgba(20,14,40,0.38)'; c.fillRect(0, bar, w, 22);
      c.fillStyle = 'rgba(255,255,255,0.9)'; c.beginPath(); c.arc(14, bar + 11, 4, 0, 7); c.fill();
      text('Safari   Ablage   Bearbeiten   Darstellung', 24, bar + 15, 10.5, 'rgba(255,255,255,0.92)', 500);
      text('Do. 26. Nov.  14:42', w - 10, bar + 15, 10.5, 'rgba(255,255,255,0.92)', 500, 'right');
      // The window in front, fitted to the part the glass leaves free.
      const m = 6, x = inner.x + m, y = inner.y + m, ww = inner.w - 2 * m, wh = inner.h - 2 * m - (kind === 'desktop' ? 44 : 0);
      c.save(); c.shadowColor = 'rgba(0,0,0,0.45)'; c.shadowBlur = 24; c.shadowOffsetY = 8; round(x, y, ww, wh, 10); c.fillStyle = '#fbfbfd'; c.fill(); c.restore();
      c.save(); round(x, y, ww, wh, 10); c.clip();
      c.fillStyle = '#ececf0'; c.fillRect(x, y, ww, 30);
      [['#ff5f57', 14], ['#febc2e', 28], ['#28c840', 42]].forEach(([col, dx]) => { c.fillStyle = col; c.beginPath(); c.arc(x + dx, y + 15, 4.5, 0, 7); c.fill(); });
      round(x + ww * 0.22, y + 7, ww * 0.56, 16, 8); c.fillStyle = '#dcdce2'; c.fill();
      text('kuestenblatt.example', x + ww / 2, y + 19, 9.5, '#6e6e73', 400, 'center');
      const heroH = Math.min(wh * 0.3, ww * 0.55), hy = y + 30;
      const g = c.createLinearGradient(0, hy, 0, hy + heroH); g.addColorStop(0, '#8fb8da'); g.addColorStop(0.7, '#e9c9a7'); g.addColorStop(1, '#f2d2b0');
      c.fillStyle = g; c.fillRect(x, hy, ww, heroH);
      c.fillStyle = '#f8ecd0'; c.beginPath(); c.arc(x + ww * 0.68, hy + heroH * 0.42, heroH * 0.13, 0, 7); c.fill();
      c.fillStyle = '#7d8ea3'; c.beginPath(); c.moveTo(x, hy + heroH * 0.75); c.lineTo(x + ww * 0.22, hy + heroH * 0.4); c.lineTo(x + ww * 0.42, hy + heroH * 0.66);
      c.lineTo(x + ww * 0.6, hy + heroH * 0.48); c.lineTo(x + ww, hy + heroH * 0.72); c.lineTo(x + ww, hy + heroH); c.lineTo(x, hy + heroH); c.fill();
      c.fillStyle = '#34536d'; c.beginPath(); c.moveTo(x, hy + heroH * 0.86); c.lineTo(x + ww * 0.3, hy + heroH * 0.62); c.lineTo(x + ww * 0.55, hy + heroH * 0.8);
      c.lineTo(x + ww * 0.8, hy + heroH * 0.66); c.lineTo(x + ww, hy + heroH * 0.8); c.lineTo(x + ww, hy + heroH); c.lineTo(x, hy + heroH); c.fill();
      c.fillStyle = '#2c4c66'; c.fillRect(x, hy + heroH * 0.93, ww, heroH * 0.07);
      let ty = hy + heroH + 24;
      text('REISE · NORDSEE', x + 18, ty, 8, '#c2611f', 700); ty += 26;
      text('Die Küste im Herbst', x + 18, ty, Math.min(22, ww / 15), '#1d1d1f', 700); ty += 18;
      text('Vier Tage zwischen Deich, Watt und Leuchtturm', x + 18, ty, 9.5, '#6e6e73'); ty += 18;
      const lines = (n, from) => { for (let i = 0; i < n; i++) { c.fillStyle = '#d1d1d6'; round(x + 18, from + i * 9, (ww - 36) * [1, 0.96, 0.98, 0.7, 0.93, 0.5][i % 6], 4, 2); c.fill(); } return from + n * 9; };
      ty = lines(6, ty) + 10;
      ty = lines(4, ty) + 12;
      const cardW = (ww - 46) / 2, cardH = Math.min(70, wh - (ty - y) - 60);
      if (cardH > 30) {
        round(x + 18, ty, cardW, cardH, 6); c.fillStyle = '#d6e2ea'; c.fill();
        c.fillStyle = '#93b2c6'; c.beginPath(); c.moveTo(x + 18, ty + cardH); c.lineTo(x + 18 + cardW * 0.3, ty + cardH * 0.45); c.lineTo(x + 18 + cardW * 0.55, ty + cardH * 0.75);
        c.lineTo(x + 18 + cardW * 0.75, ty + cardH * 0.5); c.lineTo(x + 18 + cardW, ty + cardH * 0.8); c.lineTo(x + 18 + cardW, ty + cardH); c.fill();
        round(x + 28 + cardW, ty, cardW, cardH, 6); c.fillStyle = '#ebdcc9'; c.fill();
        c.fillStyle = '#d7a46f'; c.beginPath(); c.arc(x + 28 + cardW * 1.5, ty + cardH * 0.45, cardH * 0.2, 0, 7); c.fill();
        ty += cardH + 14;
      }
      if (y + wh - ty > 60) { ty = lines(3, ty) + 12; round(x + 18, ty, 70, 18, 9); c.fillStyle = '#0a7cff'; c.fill(); text('Weiterlesen', x + 53, ty + 12.5, 8.5, '#fff', 600, 'center'); }
      c.restore();
      if (kind === 'desktop') {
        round(w / 2 - 92, h - bottom + 8 > h - 40 ? inner.y + inner.h - 38 : inner.y + inner.h - 38, 184, 32, 10); c.fillStyle = 'rgba(255,255,255,0.22)'; c.fill();
        ['#2f7cf6', '#1d1d1f', '#30c25b', '#ff9f0a', '#f2f2f7', '#ff375f', '#8e8e93'].forEach((col, i) => { round(w / 2 - 86 + i * 25.5, inner.y + inner.h - 34, 22, 22, 5); c.fillStyle = col; c.fill(); });
      }
    }
    const jpeg = new Uint8Array(await (await new Promise((r) => canvas.toBlob(r, 'image/jpeg', 0.92))).arrayBuffer());
    const packet = new Uint8Array(47 + jpeg.length), head = new DataView(packet.buffer);
    packet.set([1, 30, flags]);
    const px = window.__aimAt?.[0] ?? 0.32, py = window.__aimAt?.[1] ?? 0.62;
    [px, py, px, py, points, points * request.h / request.w, 0, 0].forEach((value, i) => head.setFloat32(3 + i * 4, value, true));
    head.setUint32(39, request.v, true);
    head.setUint32(43, window.__pictures = (window.__pictures ?? 0) + 1, true);
    packet.set(jpeg, 47);
    window.__shows = [points, points * request.h / request.w, fitted];
    socket.onmessage?.({ data: packet.buffer });
    await new Promise((r) => setTimeout(r, 250));
  };
})();`;

// `lang`: the phone's language; `token`: false for a phone that was never paired.
// `scheme`: the phone's light or dark appearance; `tour`: a phone that never saw the gesture tour; `hash`: another
// fragment than the old token (a one-time code). Every page starts without the fake Mac's cookie.
async function openPage(width, height, { lang = 'de-DE', token = true, scheme = 'dark', tour = false, hash = null, contrast = null, transparency = null, dpr = 3 } = {}) {
  await cdp('Storage.clearCookies', {});
  const { targetId } = await cdp('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp('Target.attachToTarget', { targetId, flatten: true });
  const s = (method, params) => cdp(method, params, sessionId);
  await s('Page.enable');
  await s('Runtime.enable');
  const errors = [];
  pageErrors.set(sessionId, errors);
  await s('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: dpr, mobile: true });
  await s('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
  await s('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme },
    { name: 'prefers-contrast', value: contrast ?? 'no-preference' }, { name: 'prefers-reduced-transparency', value: transparency ?? 'no-preference' },
    { name: 'prefers-reduced-motion', value: 'no-preference' }] });
  if (slow > 1) await s('Emulation.setCPUThrottlingRate', { rate: slow });
  await s('Page.addScriptToEvaluateOnNewDocument', { source: `try { localStorage.setItem('test-lang', ${JSON.stringify(lang)});
    ${tour ? "localStorage.setItem('test-tour', '1');" : "localStorage.removeItem('test-tour');"} } catch {}` });
  await s('Page.addScriptToEvaluateOnNewDocument', { source: harness });
  await s('Page.navigate', { url: hash ? `${origin}/${hash}` : token ? `${origin}/#test-token` : `${origin}/` });
  await sleep(600);
  const evaluate = async (expression) => {
    const { result, exceptionDetails } = await s('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
    return result.value;
  };
  const touch = (type, points) => s('Input.dispatchTouchEvent', { type, touchPoints: points.map(([x, y], id) => ({ x, y, id })) });
  // Since version 18 a connection asks the fake Mac for a ticket (and may pair first) before its socket: wait until
  // the page has settled, connected or not, so a task never draws a picture before the first view request.
  for (let i = 0; i < 40 && await evaluate(`document.body.dataset.link === 'connecting' || (document.body.dataset.link === 'connected' && !window.__view)`); i++) await sleep(50);
  const page = {
    evaluate, touch, cdp: s, errors,
    close: () => cdp('Target.closeTarget', { targetId }),
    resize: async (w, h) => { await s('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 3, mobile: true }); await sleep(250); },
    sent: () => evaluate('window.__sent'),
    /** With --shots: a picture of the page as it is now. */
    shot: async (name) => { if (shots) writeFileSync(join(shots, `${name}.png`), Buffer.from((await s('Page.captureScreenshot', { format: 'png' })).data, 'base64')); },
    /** With --gallery: a picture of the page as it is now, under the gallery's name. */
    keep: async (name) => { if (gallery) writeFileSync(join(gallery, `${name}.png`), Buffer.from((await s('Page.captureScreenshot', { format: 'png' })).data, 'base64')); },
    clear: () => evaluate('window.__sent.length = 0'),
    rect: (selector) => evaluate(`(() => { const e = document.querySelector(${JSON.stringify(selector)}); if (!e) return null;
      const r = e.getBoundingClientRect(); const st = getComputedStyle(e);
      return { x: r.x, y: r.y, w: r.width, h: r.height, shown: r.width > 0 && r.height > 0 && st.visibility !== 'hidden' && st.opacity !== '0' }; })()`),
    // A tap at the element's centre, as a finger would do it.
    tap: async (selector) => {
      const r = await page.rect(selector);
      if (!r?.shown) return false;
      const p = [r.x + r.w / 2, r.y + r.h / 2];
      await touch('touchStart', [p]); await sleep(40); await touch('touchEnd', []); await sleep(60);
      return true;
    },
    /** Moves fingers along paths: `paths(i)` gives every finger's point at step i of n, `hz` events per second. */
    gesture: async ({ steps, hz = 60, at, end = 'touchEnd', fingers }) => {
      await touch('touchStart', at(0)); await sleep(1000 / hz);
      for (let i = 1; i <= steps; i++) { await touch('touchMove', at(i)); await sleep(1000 / hz); }
      if (fingers) {
        // The second finger lifts; the first one keeps moving.
        await s('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [{ x: at(steps)[1][0], y: at(steps)[1][1], id: 1 }] });
        await sleep(1000 / hz);
        for (const f of fingers) { await touch('touchMove', f.points); await sleep(1000 / hz); }
      }
      await touch(end, []); await sleep(80);
    },
  };
  return page;
}

const sum = (list, type, key) => list.filter((m) => m.t === type).reduce((a, m) => a + m[key], 0);
const count = (list, type) => list.filter((m) => m.t === type).length;
const round = (n) => Math.round(n * 10) / 10;
// Since version 18: sheets lie over the bar, so each is put away with its own close key; menus open from their button.
const SHEET_OF = { apps: '#switcher', deck: '#drawer', prefs: '#prefs' };
async function closeSheet(page) {
  const open = await page.evaluate(`['apps', 'drawer', 'prefs'].find((c) => document.body.classList.contains(c)) ?? ''`);
  if (open) { await page.tap(`${{ apps: '#switcher', drawer: '#drawer', prefs: '#prefs' }[open]} [data-act=close]`); await sleep(320); }
}
/** Opens the menu behind `opener` ('#macBtn' or '#readout') and taps `item` in it. */
async function fromMenu(page, opener, item) {
  const menu = opener === '#macBtn' ? '#macMenu' : '#viewMenu';
  if (await page.evaluate(`document.querySelector('${menu}').hidden`)) { await page.tap(opener); await sleep(300); }
  const ok = await page.tap(`${menu} ${item}`);
  await sleep(250);
  return ok;
}
/** Taps a row of the settings sheet, scrolled into sight first as a finger would. */
const tapSetting = async (page, act) => {
  // Only the sheet's list scrolls: scrollIntoView would scroll the page's own frame too.
  await page.evaluate(`(() => { const w = document.querySelector('#prefs .well'), r = document.querySelector('#prefs [data-act=${act}]').getBoundingClientRect();
    w.scrollTop += r.top + r.height / 2 - w.getBoundingClientRect().top - w.clientHeight / 2; })()`); await sleep(100);
  return page.tap(`#prefs [data-act=${act}]`);
};
const openSettings = async (page) => { await fromMenu(page, '#macBtn', '[data-act=settings]'); await sleep(250); };
const toggleFit = (page) => fromMenu(page, '#readout', '[data-act=fit]');
const toggleShape = (page) => fromMenu(page, '#readout', '[data-act=shape]');

// Whether a control is usable: shown, inside the visible area, large enough, and not covered by something else.
async function reachable(page, selector, visible) {
  return page.evaluate(`(() => {
    const els = [...document.querySelectorAll(${JSON.stringify(selector)})];
    const e = els.find((x) => { const r = x.getBoundingClientRect(); return r.width > 0 && r.height > 0; });
    if (!e) return { ok: false, why: 'missing or not shown' };
    const r = e.getBoundingClientRect(), st = getComputedStyle(e);
    if (st.visibility === 'hidden' || +st.opacity === 0 || e.closest('[inert]')) return { ok: false, why: 'hidden' };
    const v = ${JSON.stringify(visible)};
    if (r.left < -0.5 || r.top < v.top - 0.5 || r.right > innerWidth + 0.5 || r.bottom > v.top + v.height + 0.5) return { ok: false, why: 'outside visible area' };
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    if (!hit || !(e === hit || e.contains(hit) || hit.contains(e) && hit.matches(${JSON.stringify(selector)}))) return { ok: false, why: 'covered by ' + (hit?.id || hit?.className || hit?.tagName) };
    return { ok: true, w: Math.round(r.width), h: Math.round(r.height) };
  })()`);
}

const CONTROLS = {
  'Klick (Ziehen)': '[data-hold=left]', 'Rechtsklick': '[data-click=right]', 'Zurück': '[data-click=back]',
  'Vorwärts': '[data-click=forward]', 'Live-Bild': '[data-act=view]', 'Apps': '[data-act=apps]', 'Steuerung': '[data-act=deck]',
  'Zoom': '#zoom, [data-act=zoom-in]', 'Auf dem Mac schreiben': '#field, [data-act=type]', 'Play': '[data-media=play]',
  'Lauter': '[data-media=volup]', 'esc': '[data-key=escape]', 'Einstellungen': '[data-setting], [data-page=settings]',
};
// Some controls sit behind a page switch or drawer; this opens it the way a user would and counts the taps.
async function reach(page, name, selector, visible) {
  let direct = await reachable(page, selector, visible), taps = 1;
  if (direct.ok) return { ...direct, taps };
  // The live view's key is in the Mac's menu while it runs; the settings are a sheet from the same menu.
  const openers = name === 'Live-Bild' ? ['[data-act=mac]'] : name === 'Einstellungen' ? ['[data-act=mac]', '#macMenu [data-act=settings]']
    : ['[data-act=deck]', `[data-act=page][data-page=${['Play', 'Lauter'].includes(name) ? 'media' : 'keys'}]`];
  for (const opener of openers) {
    if (!(await page.tap(opener))) continue;
    taps++;
    await sleep(350);
    direct = await reachable(page, selector, visible);
    if (direct.ok) return { ...direct, taps };
  }
  return { ...direct, state: await page.evaluate(`document.body.className + ' page=' + document.body.dataset.page`) };
}

// Since version 18 the picture element covers the phone, and the page tells the Mac what its controls cover. The share
// is of the phone's area that the picture shows unobscured, from that inset; `height` is the same upright.
const screenArea = (page) => page.evaluate(`(() => { const r = document.querySelector('#screen').getBoundingClientRect();
  const [top, right, bottom, left] = window.__view?.inset ?? [0, 0, 0, 0], w = r.width - left - right, h = r.height - top - bottom;
  return { w: Math.round(w), h: Math.round(h), inset: [top, right, bottom, left], share: Math.round(100 * w * h / (innerWidth * innerHeight)),
    height: Math.round(1000 * h / innerHeight) / 10 }; })()`);

const results = {};
const task = async (name, fn) => {
  if (only.length && !only.includes(name)) return;
  // A task that throws fails: with an `ok` of false, so the check in CI counts it instead of skipping it.
  try { results[name] = await fn(); } catch (error) { results[name] = { error: String(error.stack || error), ok: false }; }
};

const PHONES = { narrow: [320, 568], small: [375, 667], large: [440, 956] };
const KEYBOARD = { portrait: 336, landscape: 208 };

// T1: turn the phone, use the live view, reach the main actions.
await task('T1', async () => {
  const out = {};
  for (const [phone, [w, h]] of Object.entries(PHONES)) {
    for (const orientation of ['portrait', 'landscape']) {
      const [width, height] = orientation === 'portrait' ? [w, h] : [h, w];
      const page = await openPage(width, height);
      const visible = { top: 0, height };
      const controls = {};
      const wanted = CONTROLS;
      for (const [name, selector] of Object.entries(wanted)) {
        controls[name] = await reach(page, name, selector, visible);
        for (let i = 0; i < 2; i++) await page.evaluate(`dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))`);
        await sleep(200);
      }
      out[`${phone} ${orientation}`] = { screen: await screenArea(page), reachable: Object.values(controls).filter((c) => c.ok).length,
        of: Object.keys(controls).length, missing: Object.entries(controls).filter(([, c]) => !c.ok).map(([n, c]) => `${n}: ${c.why}${c.state ? ` (${c.state})` : ""}`) };
      await page.close();
    }
  }
  return out;
});

// T2: magnify a part of the picture with two fingers, then return to 1x.
await task('T2', async () => {
  const page = await openPage(390, 844);
  const r = await page.rect('#screen');
  const cx = r.x + r.w / 2, cy = r.y + r.h / 2;
  await page.clear();
  await page.gesture({ steps: 20, at: (i) => [[cx - 30 - i * 5, cy - 30 - i * 5], [cx + 30 + i * 5, cy + 30 + i * 5]] });
  await sleep(300);
  const sent = await page.sent();
  const views = sent.filter((m) => m.t === 'view');
  const pinch = { zoomAfter: views.at(-1)?.zoom ?? 0.5, zoomed: (views.at(-1)?.zoom ?? 0.5) > 0.5,
    misactions: count(sent, 'm') + count(sent, 's') + count(sent, 'c') };
  // Back to 1x: with the − key, step by step. Before version 11 the readout went there in one tap.
  await page.clear();
  let taps = 0;
  const asked = async () => (await page.sent()).filter((m) => m.t === 'view').at(-1)?.zoom;
  if ((await page.rect('[data-act=zoom-reset]'))?.shown) { await page.tap('[data-act=zoom-reset]'); taps++; }
  else for (; taps < 6 && ((await asked()) ?? pinch.zoomAfter) > 1.001; taps++) await page.tap('[data-act=zoom][data-step="-1"]');
  await sleep(200);
  const after = await asked();
  await page.close();
  return { pinch, reset: { taps, zoom: after ?? null, ok: after === 1 }, out: await zoomOut(), turned: await zoomTurned() };
});

// T2, zooming out: two fingers moving together, then the − key, then a Mac whose desktop is 3008 points wide and
// stops the view there. Baseline: the page asks for no less than 0.25.
async function zoomOut() {
  const out = {};
  for (const [orientation, [width, height]] of Object.entries({ portrait: [390, 844], landscape: [844, 390] })) {
    const page = await openPage(width, height);
    const r = await page.rect('#screen');
    const cx = r.x + r.w / 2, cy = r.y + r.h / 2;
    const asked = async () => (await page.sent()).filter((m) => m.t === 'view').at(-1)?.zoom ?? null;
    const readout = () => page.evaluate(`(document.querySelector('#zoomValue') ?? document.querySelector('#zoom'))?.textContent.trim() ?? null`);
    const together = () => page.gesture({ steps: 20, at: (i) => [[cx - 150 + i * 6, cy], [cx + 150 - i * 6, cy]] });
    await page.clear();
    await together();
    await sleep(300);
    const sent = await page.sent();
    const pinch = { zoom: await asked(), misactions: count(sent, 'm') + count(sent, 's') + count(sent, 'c') };
    // The − key, as often as it takes to reach the end.
    let key = null;
    if ((await page.rect('[data-act=zoom][data-step="-1"]'))?.shown) {
      for (let i = 0; i < 12; i++) await page.tap('[data-act=zoom][data-step="-1"]');
      await sleep(200);
      key = await asked();
    }
    // The fake Mac shows its whole desktop at this zoom and no less. The page takes the value over, a further
    // pinch previews no smaller picture, neither while it runs nor while the Mac is asked, and what the page
    // asks for afterwards is the limit again.
    const limit = r.w / 3008;
    let mac = null;
    if (await page.evaluate(`typeof window.__picture === 'function' && window.__sent.some((m) => m.t === 'view')`)) {
      await page.evaluate(`window.__picture(3008)`); // the first JPEG only switches the page from H.264 to JPEG
      await sleep(200);
      await page.evaluate(`window.__picture(3008)`);
      const adopted = await asked();
      await page.touch('touchStart', [[cx - 150, cy], [cx + 150, cy]]); await sleep(16);
      for (let i = 1; i <= 20; i++) { await page.touch('touchMove', [[cx - 150 + i * 6, cy], [cx + 150 - i * 6, cy]]); await sleep(16); }
      const preview = await page.evaluate(`document.querySelector('#picture')?.style.transform ?? null`);
      const shown = await readout();
      await page.touch('touchEnd', []); await sleep(200);
      const released = { asked: await asked(), preview: await page.evaluate(`document.querySelector('#picture')?.style.transform ?? null`), readout: await readout() };
      await page.evaluate(`window.__picture(3008)`);
      mac = { limit: Math.round(limit * 1000) / 1000, adopted, preview, readoutWhilePinching: shown, released, readout: await readout(),
        after: await asked(), ok: Math.abs(adopted - limit) < 0.001 && preview === '' && released.preview === '' && released.asked < adopted
          && Math.abs(await asked() - limit) < 0.001 };
    }
    await page.close();
    out[orientation] = { pinch, key, mac, ok: pinch.zoom < 0.25 && pinch.misactions === 0 && key !== null && key < 0.25 && mac?.ok === true };
  }
  return out;
}

// T2, turning the phone: − upright, + sideways, then back and forth. Each way of holding it asks for its own zoom
// again, and both are stored. Baseline: one zoom for both, so the turn carries the last value along.
async function zoomTurned() {
  const page = await openPage(390, 844);
  const asked = async () => (await page.sent()).filter((m) => m.t === 'view').at(-1)?.zoom ?? null;
  const turn = async (width, height) => { await page.resize(width, height); await sleep(200); return asked(); };
  await page.tap('[data-act=zoom][data-step="-1"]');
  const upright = await asked();
  const sidewaysFirst = await turn(844, 390);
  await page.tap('[data-act=zoom][data-step="1"]');
  const sideways = await asked();
  const back = await turn(390, 844), again = await turn(844, 390);
  const stored = await page.evaluate(`[localStorage.getItem('remotey-zoom'), localStorage.getItem('remotey-zoom-wide')].map(Number)`);
  await page.close();
  return { upright, sidewaysFirst, sideways, back, again, stored,
    ok: upright === 0.35 && sidewaysFirst === 0.5 && sideways === 0.7 && back === 0.35 && again === 0.7 && stored.join() === '0.35,0.7' };
}

// T3: keyboard open, type, correct, close, in portrait and landscape.
await task('T3', async () => {
  const out = {};
  for (const [label, [width, height], keyboard, offsetTop] of [
    ['small portrait', PHONES.small, KEYBOARD.portrait, 0], ['small portrait, iOS scrolled', PHONES.small, KEYBOARD.portrait, 120],
    ['large landscape', [PHONES.large[1], PHONES.large[0]], KEYBOARD.landscape, 0],
    ['large landscape, iOS scrolled', [PHONES.large[1], PHONES.large[0]], KEYBOARD.landscape, 80],
  ]) {
    const page = await openPage(width, height);
    const opened = await page.tap('[data-act=type]') || await page.evaluate(`(document.querySelector('#field').focus(), true)`);
    await page.evaluate(`document.activeElement !== document.querySelector('#field') && document.querySelector('#field').focus()`);
    await page.evaluate(`(window.__kb = true, __vv.set({ height: ${height - keyboard - offsetTop}, offsetTop: ${offsetTop} }))`);
    await sleep(300);
    const visible = { top: offsetTop, height: height - keyboard - offsetTop };
    const geometry = await page.evaluate(`(() => {
      const v = ${JSON.stringify(visible)};
      const box = (s) => { const e = document.querySelector(s); if (!e) return null; const r = e.getBoundingClientRect();
        const st = getComputedStyle(e); if (!r.width || !r.height || st.display === 'none' || st.visibility === 'hidden') return null;
        return { top: r.top, bottom: r.bottom, left: r.left, right: r.right }; };
      const inView = (b) => b && b.top >= v.top - 0.5 && b.bottom <= v.top + v.height + 0.5;
      const field = box('#field'), done = box('[data-act=done]'), screen = box('#screen');
      // Since version 18: the picture that shows unobscured, between what the glass covers at its top and bottom.
      const [top, , bottom] = window.__view?.inset ?? [0, 0, 0, 0];
      const screenVisible = screen ? Math.max(0, Math.min(screen.bottom - bottom, v.top + v.height) - Math.max(screen.top + top, v.top)) : 0;
      const under = (b) => b && b.top >= screen.bottom - bottom - 0.5;
      return { field: inView(field), done: inView(done), screenVisible: Math.round(screenVisible),
        covered: !(under(field) && under(done)), focused: document.activeElement?.id === 'field' };
    })()`);
    await page.clear();
    await page.evaluate(`(() => { const f = document.querySelector('#field');
      const type = (text) => { f.setRangeText(text, f.selectionStart, f.selectionEnd, 'end'); f.dispatchEvent(new InputEvent('input', { inputType: 'insertText', data: text })); };
      const back = () => { const s = f.selectionStart; const before = f.value.slice(0, s); const cut = [...new Intl.Segmenter().segment(before)].at(-1)?.segment.length ?? 1;
        f.setRangeText('', s - cut, s, 'end'); f.dispatchEvent(new InputEvent('input', { inputType: 'deleteContentBackward' })); };
      type('Grüße '); type('👋🏽'); back(); type('ß'); f.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    })()`);
    await sleep(100);
    const sent = await page.sent();
    const typing = { text: sent.filter((m) => m.t === 'text').map((m) => m.s).join(''),
      backspaces: sent.filter((m) => m.t === 'key' && m.k === 'backspace').reduce((a, m) => a + m.n, 0),
      enter: sent.some((m) => m.t === 'key' && m.k === 'return') };
    typing.ok = typing.text === 'Grüße 👋🏽ß' && typing.backspaces === 1 && typing.enter;
    // Close the keyboard with "Fertig", as the page offers it.
    await page.tap('[data-act=done]');
    await page.evaluate(`(window.__kb = false, __vv.reset())`);
    await sleep(300);
    const closed = await page.evaluate(`(() => { const app = document.querySelector('#app').getBoundingClientRect();
      return { blurred: document.activeElement?.id !== 'field', top: Math.round(app.top), bottom: Math.round(app.bottom), height: innerHeight }; })()`);
    out[label] = { opened, ...geometry, typing, closed: { ...closed, full: closed.top === 0 && Math.abs(closed.bottom - closed.height) < 1 } };
    await page.close();
  }
  return out;
});

// T4: hit a small target precisely and cross a long way. Paths at 60 and 120 events per second.
await task('T4', async () => {
  const page = await openPage(390, 844);
  const r = await page.rect('#screen');
  const x0 = r.x + 60, y0 = r.y + r.h / 2;
  const run = async (distance, ms, hz, holdMs = 0) => {
    await page.clear();
    const steps = Math.max(1, Math.round(ms * hz / 1000));
    await page.touch('touchStart', [[x0, y0]]);
    if (holdMs) await sleep(holdMs);
    for (let i = 1; i <= steps; i++) { await sleep(1000 / hz); await page.touch('touchMove', [[x0 + distance * i / steps, y0]]); }
    await sleep(30); await page.touch('touchEnd', []); await sleep(80);
    const sent = await page.sent();
    return { mac: round(sum(sent, 'm', 'dx')), clicks: count(sent, 'c') };
  };
  const out = {
    'slow 30px, 60 Hz': await run(30, 1000, 60), 'slow 30px, 120 Hz': await run(30, 1000, 120),
    'nudge 5px after holding': await run(5, 200, 60, 400),
    'fast 250px, 60 Hz': await run(250, 150, 60), 'fast 250px, 120 Hz': await run(250, 150, 120),
  };
  await page.close();
  return out;
});

// T5: scroll a long view, stop, change direction; lift a finger; cancel.
await task('T5', async () => {
  const page = await openPage(390, 844);
  const r = await page.rect('#screen');
  const x = r.x + r.w / 2 - 25, y = r.y + 100;
  const scroll = async (label, options) => {
    await page.clear();
    await page.gesture(options);
    await sleep(150);
    const sent = await page.sent();
    return [label, { dx: round(sum(sent, 's', 'dx')), dy: round(sum(sent, 's', 'dy')), moves: count(sent, 'm'),
      clicks: count(sent, 'c'), views: sent.filter((m) => m.t === 'view' && m.zoom !== 0.5).length,
      signChanges: sent.filter((m) => m.t === 's' && m.dy).reduce((a, m, i, all) => a + (i && Math.sign(m.dy) !== Math.sign(all[i - 1].dy) ? 1 : 0), 0) }];
  };
  const both = (dy) => (i) => [[x, y + dy(i)], [x + 50, y + dy(i)]];
  const out = Object.fromEntries([
    await scroll('down 100px, both fingers', { steps: 25, at: both((i) => i * 4) }),
    await scroll('down 100px, one finger per event', { steps: 50, at: (i) => [[x, y + Math.ceil(i / 2) * 4], [x + 50, y + Math.floor(i / 2) * 4]] }),
    await scroll('small 4px', { steps: 4, hz: 30, at: both((i) => i) }),
    await scroll('down 60 then up 60', { steps: 30, at: both((i) => (i <= 15 ? i * 4 : 120 - i * 4)) }),
    await scroll('diagonal drift 10%', { steps: 25, at: (i) => [[x + i * 0.4, y + i * 4], [x + 50 + i * 0.4, y + i * 4]] }),
    await scroll('lift one finger, keep moving', { steps: 10, at: both((i) => i * 4),
      fingers: Array.from({ length: 10 }, (_, i) => ({ points: [[x, y + 40 + i * 5]] })) }),
    await scroll('cancelled mid-scroll', { steps: 10, at: both((i) => i * 4), end: 'touchCancel' }),
  ]);
  await page.clear();
  await sleep(500);
  out['after cancel'] = { trailing: (await page.sent()).filter((m) => m.t === 's' && (m.dx || m.dy)).length };
  await page.close();
  return out;
});

// T6: set the pointer speed to its maximum on the Regler page, then check that the next slow move is that much longer.
await task('T6', async () => {
  const page = await openPage(375, 812);
  const r = await page.rect('#screen');
  const slowMove = async () => {
    await page.clear();
    const x0 = r.x + 40, y0 = r.y + 60;
    await page.touch('touchStart', [[x0, y0]]);
    for (let i = 1; i <= 30; i++) { await sleep(1000 / 30); await page.touch('touchMove', [[x0 + i, y0]]); }
    await sleep(30); await page.touch('touchEnd', []); await sleep(80);
    return round(sum(await page.sent(), 'm', 'dx'));
  };
  const before = await slowMove();
  await openSettings(page);
  const value = () => page.evaluate(`document.querySelector('[data-setting=speed] output')?.textContent`);
  let touches = 0;
  const slider = await page.rect('[data-setting=speed] [role=slider]');
  if (slider?.shown) {
    // One finger, put down at the right end of the track.
    await page.touch('touchStart', [[slider.x + slider.w - 2, slider.y + slider.h / 2]]); await sleep(40); await page.touch('touchEnd', []);
    touches = 1;
  } else {
    // Before round 6: a + key, tapped until the value stops rising.
    for (let last = ''; touches < 12; touches++) {
      const now = await value();
      if (now === last) break;
      last = now;
      await page.tap('[data-setting=speed] [data-step="1"]');
    }
    touches--;
  }
  await sleep(100);
  const shown = await value();
  // The sheet is not modal: the next move counts with the sheet still open.
  const after = await slowMove();
  // The list scrolls under a finger that starts on a row, a slider's track or a switch, and such a swipe sets
  // nothing. A finger that goes sideways along a row slides its value.
  const state = () => page.evaluate(`(() => { const w = document.querySelector('#prefs .well'); return { top: Math.round(w.scrollTop),
    set: [...w.querySelectorAll('output')].map((o) => o.textContent).join(' ') + ' ' + [...w.querySelectorAll('[role=switch]')].map((b) => b.getAttribute('aria-checked')).join(' ') }; })()`);
  const centre = (selector) => page.evaluate(`(() => { const w = document.querySelector('#prefs .well').getBoundingClientRect();
    const e = [...document.querySelectorAll(${JSON.stringify(selector)})].map((x) => x.getBoundingClientRect()).find((r) => r.top > w.top + 8 && r.bottom < w.bottom - 8);
    return e ? { x: e.left + e.width / 2, y: e.top + e.height / 2 } : null; })()`);
  const swipe = async (selector, dx, dy) => {
    const from = await centre(selector);
    if (!from) return null;
    await page.touch('touchStart', [[from.x, from.y]]);
    for (let i = 1; i <= 8; i++) { await sleep(16); await page.touch('touchMove', [[from.x + dx * i / 8, from.y + dy * i / 8]]); }
    await sleep(30); await page.touch('touchEnd', []); await sleep(350);
    return state();
  };
  const rest = await state();
  const scrolls = {};
  for (const [name, selector] of [['row', '#prefs [data-setting=acceleration] .name'], ['track', '#prefs [data-setting=scroll] [role=slider]'], ['switch', '#prefs [role=switch]']]) {
    const top = (await state()).top;
    const then = await swipe(selector, 0, -70);
    scrolls[name] = then && { by: then.top - top, set: then.set === rest.set };
  }
  await page.evaluate(`document.querySelector('#prefs .well').scrollTop = 0`); await sleep(100);
  const slid = await swipe('#prefs [data-setting=scroll] .name', -120, 4);
  // A tap still flips a switch: the first one in sight, there and back.
  const tapped = await (async () => {
    await swipe('#prefs [data-setting=acceleration] .name', 0, -160);
    const at = await centre('#prefs [role=switch]');
    if (!at) return null;
    const read = () => page.evaluate(`document.elementFromPoint(${at.x}, ${at.y}).closest('[role=switch]')?.getAttribute('aria-checked')`);
    const flips = [await read()];
    for (let i = 0; i < 2; i++) { await page.touch('touchStart', [[at.x, at.y]]); await sleep(40); await page.touch('touchEnd', []); await sleep(200); flips.push(await read()); }
    return flips.join(' ');
  })();
  await page.close();
  const scrolled = Object.values(scrolls).every((s) => s && s.by > 20 && s.set);
  return { touches, shown, before, after, ratio: round(after / before), scrolls, slid: slid && slid.set !== rest.set, tapped,
    ok: shown === '2×' && Math.abs(after / before - 2) < 0.1 && scrolled && !!slid && slid.set !== rest.set && ['true false true', 'false true false'].includes(tapped) };
});

// T7: the tray. How long it stays in sight after the key closes it, whether it covers the dock on the way,
// and whether a tap on the display or a swipe down puts it away (without a click on the Mac).
await task('T7', async () => {
  const page = await openPage(375, 812);
  const open = async () => { if (!(await page.evaluate(`document.body.classList.contains('drawer')`))) await page.tap('[data-act=deck]'); await sleep(450); };
  const isOpen = () => page.evaluate(`document.body.classList.contains('drawer')`);
  // Every frame: the part of the tray that can be seen, after clipping by its ancestors.
  const record = () => page.evaluate(`(() => {
    const frames = window.__frames = [], tray = document.querySelector('#drawer'), dock = document.querySelector('#bar').getBoundingClientRect();
    let t0 = null;
    addEventListener('touchstart', () => { t0 ??= performance.now(); }, { capture: true, once: true });
    const seen = () => {
      if (getComputedStyle(tray).visibility === 'hidden' || getComputedStyle(tray).display === 'none') return null;
      let r = tray.getBoundingClientRect(), box = { l: r.left, t: r.top, r: r.right, b: r.bottom };
      for (let e = tray.parentElement; e; e = e.parentElement) {
        if (getComputedStyle(e).overflow === 'visible') continue;
        const c = e.getBoundingClientRect();
        box = { l: Math.max(box.l, c.left), t: Math.max(box.t, c.top), r: Math.min(box.r, c.right), b: Math.min(box.b, c.bottom) };
      }
      return box.r > box.l && box.b > box.t ? box : null;
    };
    const step = (now) => {
      const box = seen();
      frames.push({ at: t0 === null ? null : now - t0, h: box ? Math.round(box.b - box.t) : 0,
        overDock: box ? Math.max(0, Math.round(Math.min(box.b, dock.bottom) - Math.max(box.t, dock.top))) : 0 });
      if (frames.length < 60) window.__frame(step);
    };
    window.__frame(step);
  })()`);
  await open();
  await record();
  await page.tap('#drawer [data-act=close]');
  await sleep(700);
  const frames = (await page.evaluate('window.__frames')).filter((f) => f.at !== null);
  const lastSeen = frames.filter((f) => f.h > 0).at(-1);
  // Since version 18 a sheet lies over the bar by design: what covers it is no fault, only how long the sheet stays.
  // The limit is 200 ms on a display that draws 60 times a second. A machine that draws slower hands the tap
  // over a frame late and starts the way out a frame late: twice what its frame is longer counts for it.
  const gaps = frames.slice(1).map((f, i) => f.at - frames[i].at).sort((a, b) => a - b);
  const frameMs = gaps.length ? gaps[gaps.length >> 1] : 1000 / 60;
  const limitMs = Math.round(200 + 2 * Math.max(0, frameMs - 1000 / 60));
  const close = { inSightMs: lastSeen ? Math.round(lastSeen.at) : 0, frames: frames.filter((f) => f.h > 0).length,
    frameMs: Math.round(frameMs * 10) / 10, limitMs };
  // A tap on the display above the tray.
  await open();
  await page.clear();
  const s = await page.rect('#screen');
  await page.touch('touchStart', [[s.x + s.w / 2, s.y + 120]]); await sleep(40); await page.touch('touchEnd', []); await sleep(300);
  const tap = { closed: !(await isOpen()), clicks: count(await page.sent(), 'c') };
  // A swipe down from the tray's top edge.
  await open();
  const d = await page.rect('#drawer');
  const x = d.x + d.w / 2, y = d.y + 6;
  await page.touch('touchStart', [[x, y]]);
  for (let i = 1; i <= 8; i++) { await sleep(16); await page.touch('touchMove', [[x, y + i * 12]]); }
  await page.touch('touchEnd', []); await sleep(300);
  const swipe = { closed: !(await isOpen()) };
  await page.close();
  return { close, tap, swipe, ok: close.inSightMs < close.limitMs && tap.closed && tap.clicks === 0 && swipe.closed };
});

// T8: the side buttons. A tap is one click of that button; an armed modifier goes with the next click only.
await task('T8', async () => {
  const page = await openPage(375, 812);
  await page.clear();
  await page.tap('[data-click=back]');
  await page.tap('[data-click=forward]');
  await page.tap('[data-act=deck]'); await sleep(450);
  await page.tap('[data-act=page][data-page=keys]'); await sleep(250);
  await page.tap('[data-mod=cmd]');
  await closeSheet(page);
  await page.tap('[data-click=back]');
  await page.tap('[data-click=back]');
  const sent = await page.sent();
  await page.tap('[data-act=deck]'); await sleep(450);
  const clicks = sent.filter((m) => m.t === 'c').map((m) => [m.b, ...m.mods].join(' '));
  // The keys for an app's zoom bring their Command along; an armed modifier joins it, for one key.
  await page.clear();
  for (const key of ['+', '-', '0']) await page.tap(`[data-key="${key}"]`);
  await page.tap('[data-mod=alt]');
  await page.tap('[data-key="+"]');
  await page.tap('[data-key="+"]');
  const keys = (await page.sent()).map((m) => (m.t === 'key' ? [m.k, ...m.mods, m.n].join(' ') : m.t));
  await page.shot('keys');
  const sizes = await page.evaluate(`[...document.querySelectorAll('.keys .cap')].map((e) => { const r = e.getBoundingClientRect(); return Math.round(Math.min(r.width, r.height)); })`);
  await page.close();
  return { clicks, others: sent.length - clicks.length, keys, smallestKey: Math.min(...sizes),
    ok: clicks.join() === 'back,forward,back cmd,back' && sent.length === clicks.length
      && keys.join() === '+ cmd 1,- cmd 1,0 cmd 1,+ cmd alt 1,+ cmd 1' && sizes.length === 16 && Math.min(...sizes) >= 27 };
});

// T9: the switcher. On every phone, upright and sideways: the icons are large enough to tap, lie inside the
// sheet, and the sheet leaves the display's top row (state, zoom) free. Then what the taps send: an app with
// one window comes forward at once, one with several shows them first, and nothing reaches the Mac before the choice.
await task('T9', async () => {
  const out = { layout: {} };
  const isOpen = (page) => page.evaluate(`document.body.classList.contains('apps')`);
  const open = async (page) => { if (!(await isOpen(page))) await page.tap('[data-act=apps]'); await sleep(450); };
  for (const [phone, [w, h]] of Object.entries(PHONES)) {
    for (const orientation of ['portrait', 'landscape']) {
      const page = await openPage(...(orientation === 'portrait' ? [w, h] : [h, w]));
      await open(page);
      out.layout[`${phone} ${orientation}`] = await page.evaluate(`(() => {
        const box = (s) => document.querySelector(s).getBoundingClientRect();
        const sheet = box('#switcher'), well = box('.well'), zoom = box('#zoom'), tiles = [...document.querySelectorAll('.app')].map((e) => e.getBoundingClientRect());
        const perRow = tiles.filter((t) => Math.abs(t.top - tiles[0].top) < 1).length;
        return { apps: tiles.length, perRow, smallest: Math.round(Math.min(...tiles.map((t) => Math.min(t.width, t.height)))),
          inside: tiles.every((t) => t.left >= well.left - 0.5 && t.right <= well.right + 0.5),
          belowZoom: sheet.top >= zoom.bottom - 0.5 || sheet.right <= zoom.left + 0.5 || sheet.left >= zoom.right - 0.5, inSight: tiles.filter((t) => t.bottom <= well.bottom + 0.5).length,
          truncated: [...document.querySelectorAll('.app .name')].filter((n) => n.scrollWidth > n.clientWidth).map((n) => n.textContent) };
      })()`);
      await page.close();
    }
  }
  const page = await openPage(375, 812);
  const focuses = async () => (await page.sent()).filter((m) => m.t === 'focus').map(({ at, ...m }) => m);
  await open(page);
  const shown = await page.evaluate(`(() => ({ asked: window.__sent.filter((m) => m.t === 'apps').length,
    labels: [...document.querySelectorAll('.app')].slice(0, 3).map((e) => e.getAttribute('aria-label')),
    icon: !!document.querySelector('.app img[src^="data:image/png"]'), letter: getComputedStyle(document.querySelector('[data-pid="502"] .letter')).display !== 'none',
    key: document.querySelector('[data-act=apps]').getAttribute('aria-expanded') }))()`);
  // One window: that window, and the sheet goes away.
  await page.clear();
  await page.tap('[data-pid="502"]'); await sleep(300);
  const one = { sent: await focuses(), closed: !(await isOpen(page)) };
  // No window known: the app alone.
  await open(page); await page.clear();
  await page.tap('[data-pid="503"]'); await sleep(300);
  const none = { sent: await focuses(), closed: !(await isOpen(page)) };
  // Several windows: a choice, and nothing sent before it. A title that is markup stays text.
  await open(page); await page.clear();
  await page.tap('[data-pid="501"]'); await sleep(300);
  const choice = await page.evaluate(`(() => ({ open: document.body.classList.contains('apps'),
    rows: [...document.querySelectorAll('.window .title')].map((e) => e.textContent), front: document.querySelector('.window[aria-current]')?.dataset.win,
    head: document.querySelector('#appsTitle').textContent + ' / ' + document.querySelector('#appsNote').textContent,
    back: !document.querySelector('[data-act=apps-back]').hidden, markup: !!document.querySelector('#apps img[src="x"]') || !!window.__xss,
    foot: document.querySelector('#apps .foot')?.textContent ?? null }))()`);
  choice.sentBefore = (await focuses()).length;
  await page.tap('[data-act=apps-back]'); await sleep(250);
  const back = await page.evaluate(`document.querySelectorAll('.app').length`);
  await page.tap('[data-pid="501"]'); await sleep(300);
  await page.tap('[data-win="12"]'); await sleep(300);
  const window = { sent: await focuses(), closed: !(await isOpen(page)) };
  // Opened again while the Mac is slow to answer: the list of last time is not offered, since the new one may
  // come in another order under the finger. As many blank places stand in, and a tap on one does nothing.
  await page.evaluate(`window.__appsDelay = ${SLOW_ANSWER}`);
  await page.tap('[data-act=apps]'); await sleep(150);
  await page.clear();
  const first = await page.rect('.app');
  await page.touch('touchStart', [[first.x + first.w / 2, first.y + first.h / 2]]); await sleep(40); await page.touch('touchEnd', []); await sleep(60);
  const stale = await page.evaluate(`({ places: document.querySelectorAll('.app.ghost').length, tappable: document.querySelectorAll('.app[data-pid]').length,
    sent: window.__sent.filter((m) => m.t === 'focus').length, open: document.body.classList.contains('apps') })`);
  await sleep(SLOW_ANSWER + 200);
  await page.evaluate(`window.__appsDelay = 0`);
  // Then it shows all apps, and a tap on the display puts it away without a click.
  await page.clear();
  const again = await page.evaluate(`document.querySelectorAll('.app[data-pid]').length`);
  const s = await page.rect('#screen');
  await page.touch('touchStart', [[s.x + 60, s.y + 80]]); await sleep(40); await page.touch('touchEnd', []); await sleep(300);
  const tap = { closed: !(await isOpen(page)), clicks: count(await page.sent(), 'c') };
  // A swipe down from its head.
  await open(page);
  const head = await page.rect('#appsTitle');
  await page.touch('touchStart', [[head.x + head.w / 2, head.y + head.h / 2]]);
  for (let i = 1; i <= 8; i++) { await sleep(16); await page.touch('touchMove', [[head.x + head.w / 2, head.y + head.h / 2 + i * 12]]); }
  await page.touch('touchEnd', []); await sleep(300);
  const swipe = { closed: !(await isOpen(page)) };
  // Back from the background with the sheet open: the page connects anew. What was on show is from before,
  // so nothing of it takes a tap until the Mac has answered again.
  await open(page);
  await page.evaluate(`(window.__appsDelay = ${SLOW_ANSWER}, document.dispatchEvent(new Event('visibilitychange')))`);
  await sleep(150); await page.clear();
  const old = await page.rect('#apps');
  await page.touch('touchStart', [[old.x + 50, old.y + 40]]); await sleep(40); await page.touch('touchEnd', []); await sleep(60);
  const resumed = await page.evaluate(`({ tappable: document.querySelectorAll('#apps button').length,
    sent: window.__sent.filter((m) => m.t === 'focus').length, open: document.body.classList.contains('apps') })`);
  await sleep(SLOW_ANSWER + 300);
  resumed.after = await page.evaluate(`document.querySelectorAll('.app[data-pid]').length`);
  await page.evaluate(`window.__appsDelay = 0`);
  // The same swipe started on an icon, while the list does not scroll: the sheet goes, the app is not asked for.
  await open(page); await page.clear();
  const icon = await page.rect('[data-pid="502"]');
  await page.touch('touchStart', [[icon.x + icon.w / 2, icon.y + icon.h / 2]]);
  for (let i = 1; i <= 8; i++) { await sleep(16); await page.touch('touchMove', [[icon.x + icon.w / 2, icon.y + icon.h / 2 + i * 14]]); }
  await page.touch('touchEnd', []); await sleep(300);
  swipe.fromIcon = { closed: !(await isOpen(page)), sent: (await focuses()).length };
  // One sheet at a time, and typing puts the switcher away for good. The bar's keys lie under the sheet: the
  // controls' key is pressed the way a keyboard or switch control does.
  await open(page);
  await page.evaluate(`document.querySelector('[data-act=deck]').click()`); await sleep(450);
  const sheets = await page.evaluate(`document.body.className.split(' ').filter((c) => c === 'drawer' || c === 'apps').join()`);
  await open(page);
  await page.evaluate(`document.querySelector('#field').focus()`); await sleep(200);
  await page.evaluate(`document.querySelector('#field').blur()`); await sleep(300);
  const typed = { closed: !(await isOpen(page)) };
  await page.close();
  const layouts = Object.values(out.layout);
  return { ...out, shown, one, none, choice, back, window, stale, again, tap, swipe, resumed, sheets, typed,
    ok: layouts.every((l) => l.apps === 12 && l.smallest >= 44 && l.inside && l.belowZoom && l.inSight >= 6)
      && shown.asked === 1 && shown.icon && shown.letter && shown.key === 'true'
      && shown.labels.join('|') === 'Safari, 2 Fenster zur Auswahl, im Vordergrund|Mail|Musik, ausgeblendet'
      && JSON.stringify(one.sent) === '[{"t":"focus","pid":502,"win":13}]' && one.closed
      && JSON.stringify(none.sent) === '[{"t":"focus","pid":503}]' && none.closed
      && choice.open && choice.sentBefore === 0 && choice.rows.length === 2 && choice.rows[1].startsWith('<img') && !choice.markup
      && choice.front === '11' && choice.head === 'Safari / 2 Fenster' && choice.back && back === 12
      && choice.foot === 'Ein Tipp holt das Fenster nach vorn. Vorher bewegt sich am Mac nichts.'
      && JSON.stringify(window.sent) === '[{"t":"focus","pid":501,"win":12}]' && window.closed
      && stale.places === 12 && stale.tappable === 0 && stale.sent === 0 && stale.open
      && again === 12 && tap.closed && tap.clicks === 0 && swipe.closed && swipe.fromIcon.closed && swipe.fromIcon.sent === 0
      && resumed.tappable === 0 && resumed.sent === 0 && resumed.open && resumed.after === 12
      && sheets === 'drawer' && typed.closed };
});

// T10: a locked Mac. The type key opens the same field for the password: nothing of it leaves before Enter,
// then all of it in one message. A refusal shows in the field, and an open Mac gets its keyboard back.
// Before that, the key that locks it: under the mute key on the tray's first page, large enough for a finger on
// every phone, and it sends Control-Command-Q alone, whatever modifier is armed.
await task('T10', async () => {
  const lockKey = { layout: {} };
  for (const [phone, [w, h]] of Object.entries(PHONES)) {
    for (const orientation of ['portrait', 'landscape']) {
      const page = await openPage(...(orientation === 'portrait' ? [w, h] : [h, w]));
      await page.tap('[data-act=deck]'); await sleep(450);
      lockKey.layout[`${phone} ${orientation}`] = await page.evaluate(`(() => {
        const box = (s) => document.querySelector(s).getBoundingClientRect(), side = (r) => Math.round(Math.min(r.width, r.height));
        // Since version 18 the lock is a tile of its own in the row with the mute key, the volume between them.
        const page = box('.page.media'), lock = box('.tile[data-act=lock]'), mute = box('[data-media=mute]'), rocker = box('.rocker');
        return { lock: side(lock), mute: side(mute), apart: Math.round(Math.min(lock.left - rocker.right, rocker.left - mute.right)),
          inside: [lock, mute].every((k) => k.left >= page.left - 0.5 && k.right <= page.right + 0.5 && k.top >= page.top - 0.5 && k.bottom <= page.bottom + 0.5) };
      })()`);
      if (phone === 'small' && orientation === 'portrait') {
        await page.shot('lock');
        await page.tap('[data-act=page][data-page=keys]'); await sleep(250);
        await page.tap('[data-mod=shift]');
        await page.tap('[data-act=page][data-page=media]'); await sleep(250);
        await page.clear();
        await page.tap('.tile[data-act=lock]');
        lockKey.sent = (await page.sent()).map(({ at, ...m }) => m);
        lockKey.armed = await page.evaluate(`document.querySelector('[data-mod=shift]').classList.contains('on')`);
      }
      await page.close();
    }
  }
  const page = await openPage(...PHONES.small);
  const say = (m) => page.evaluate(`window.__socket.onmessage({ data: ${JSON.stringify(JSON.stringify(m))} })`);
  const state = () => page.evaluate(`(() => { const f = document.querySelector('#field'), shown = (s) => getComputedStyle(document.querySelector(s)).display !== 'none';
    return { type: f.type, autocomplete: f.autocomplete, label: document.querySelector('#typeLabel').textContent, hint: f.placeholder,
      failed: f.classList.contains('failed'), focused: document.activeElement === f, value: f.value,
      padlock: shown('.slot .shut'), keys: shown('.slot .open'), name: document.querySelector('[data-act=type]').getAttribute('aria-label') }; })()`);
  const type = (text) => page.evaluate(`(() => { const f = document.querySelector('#field'); f.focus();
    f.setRangeText(${JSON.stringify(text)}, f.value.length, f.value.length, 'end'); f.dispatchEvent(new InputEvent('input', { inputType: 'insertText' })); })()`);
  const enter = () => page.evaluate(`document.querySelector('#field').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))`);
  const input = async () => (await page.sent()).filter((m) => m.t !== 'view').map(({ at, ...m }) => m);
  const open = await state();
  // The lock key shows which way the Mac is, and on a locked Mac it opens the field as the type key does.
  const lockKeyState = () => page.evaluate(`(() => { const k = document.querySelector('.tile[data-act=lock]'), shown = (s) => getComputedStyle(k.querySelector(s)).display !== 'none';
    return { shut: shown('.shut'), open: shown('.open'), on: k.classList.contains('on'), pressed: k.getAttribute('aria-pressed'), name: k.getAttribute('aria-label') }; })()`);
  lockKey.open = await lockKeyState();
  await say({ t: 'lock', on: true });
  const locked = await state();
  lockKey.locked = await lockKeyState();
  await page.tap('[data-act=deck]'); await sleep(450);
  await page.clear();
  await page.tap('.tile[data-act=lock]'); await sleep(200);
  lockKey.unlocks = { ...(await state()), sent: (await input()).length };
  await page.evaluate(`document.querySelector('#field').blur()`); await sleep(200);
  await closeSheet(page);
  await page.clear();
  await type('ge'); await type('heim');
  const typed = { ...(await state()), sent: await input() };
  await enter();
  const sent = { ...(await state()), sent: await input() };
  // A corrected password while the Mac is still at the first: held in the field, sent once the Mac has answered.
  await type('neu'); await enter();
  const early = { ...(await state()), sent: (await input()).length };
  await say({ t: 'unlock', ok: false, why: 'password' });
  const refused = await state();
  await enter();
  const second = { ...(await state()), sent: await input() };
  await say({ t: 'unlock', ok: false, why: 'field' });
  const unready = await state();
  await type('x');
  const retry = await state();
  // The Mac opens, here while the field still holds a try.
  await say({ t: 'lock', on: false });
  await page.clear();
  const opened = await state();
  await type('hi'); await enter();
  const relayed = await input();
  await page.close();
  return { lockKey, open, locked, typed, sent, early, refused, second, unready, retry, opened, relayed,
    ok: Object.values(lockKey.layout).every((l) => l.lock >= 44 && l.mute >= 44 && l.apart >= 8 && l.inside)
      && JSON.stringify(lockKey.sent) === '[{"t":"key","k":"q","mods":["ctrl","cmd"],"n":1}]' && lockKey.armed
      && lockKey.open.open && !lockKey.open.shut && !lockKey.open.on && lockKey.open.pressed === 'false' && lockKey.open.name === 'Mac sperren'
      && lockKey.locked.shut && !lockKey.locked.open && lockKey.locked.on && lockKey.locked.pressed === 'true' && lockKey.locked.name === 'Mac entsperren'
      && lockKey.unlocks.focused && lockKey.unlocks.type === 'password' && lockKey.unlocks.sent === 0
      && open.type === 'text' && open.keys && !open.padlock && open.label === 'Auf dem Mac schreiben'
      && locked.type === 'password' && locked.autocomplete === 'current-password' && locked.padlock && !locked.keys
      && locked.label === 'Mac entsperren' && locked.name === 'Mac entsperren' && locked.value === '' && locked.hint === 'Passwort des Macs'
      && typed.value === 'geheim' && typed.sent.length === 0
      && JSON.stringify(sent.sent) === '[{"t":"unlock","s":"geheim"}]' && sent.value === '' && sent.focused && sent.hint === 'Entsperre…'
      && early.value === 'neu' && early.sent === 1 && refused.failed && refused.hint === 'Nicht entsperrt, nochmal?' && refused.value === 'neu'
      && JSON.stringify(second.sent.at(-1)) === '{"t":"unlock","s":"neu"}' && second.sent.length === 2 && second.value === ''
      && unready.failed && unready.hint === 'Mac nicht bereit, nochmal?' && !retry.failed && retry.hint === 'Passwort des Macs'
      && opened.type === 'text' && !opened.focused && !opened.failed && opened.hint === '' && opened.label === 'Auf dem Mac schreiben' && opened.keys
      && JSON.stringify(relayed) === '[{"t":"text","s":"hi"},{"t":"key","k":"return","mods":[],"n":1}]' };
});

// T11: "Auto". The readout's key asks the Mac to fit the view to the window in front. The Mac picks the zoom and
// the readout shows it, with no request in return; another window, another zoom. Turned, the phone asks again.
// A zoom key or a pinch takes the zoom back into the hand, from where the picture stands. Without a window
// in front the zoom set by hand counts, and its limit is taken over as before.
await task('T11', async () => {
  const page = await openPage(390, 844);
  const r = await page.rect('#screen');
  const cx = r.x + r.w / 2, cy = r.y + r.h / 2;
  const views = async () => (await page.sent()).filter((m) => m.t === 'view').map(({ at, v, ...m }) => m);
  // Since version 17 the lamp is a symbol over the zoom: a window while the view is fitted, none while it is not.
  // Since version 18 the readout opens the view's menu; "Fenster einpassen" is a checked item there, and the readout's
  // segment is tinted while it is on.
  const state = () => page.evaluate(`(() => { const key = document.querySelector('#readout'), lamp = document.querySelector('#fitLamp');
    return { readout: document.querySelector('#zoomValue').textContent, on: key.classList.contains('on'),
      pressed: document.querySelector('#viewMenu [data-act=fit]').getAttribute('aria-checked'),
      lamp: getComputedStyle(lamp).display === 'none' ? '' : key.dataset.lamp, label: key.getAttribute('aria-label'), preview: document.querySelector('#picture').style.transform,
      stored: localStorage.getItem('remotey-fit'), w: Math.round(key.getBoundingClientRect().width), h: Math.round(key.getBoundingClientRect().height),
      clipped: document.querySelector('#zoomValue').scrollWidth > key.clientWidth
        || (getComputedStyle(lamp).display !== 'none' && lamp.getBoundingClientRect().top < key.getBoundingClientRect().top - 0.5) }; })()`);
  const text = (z) => `${String(Math.round(z * 100) / 100).replace('.', ',')}×`;
  const off = await state();
  await page.evaluate(`window.__picture(${r.w / 0.5})`); // the first JPEG only switches the page from H.264 to JPEG
  await sleep(200);
  await page.clear();
  await toggleFit(page);
  const asked = { ...(await state()), views: await views() };
  // The window in front is 1512 points wide, then another one of 900 comes forward.
  await page.clear();
  await page.evaluate(`window.__picture(1512, true)`);
  const first = { ...(await state()), views: (await views()).length };
  await page.shot('auto-upright');
  await page.evaluate(`window.__picture(900, true)`);
  const second = { ...(await state()), views: (await views()).length };
  // Sideways the page asks again, still for the window, and takes the zoom that fits there.
  await page.resize(844, 390); await sleep(200);
  const wide = await page.rect('#screen');
  const turned = { views: await views() };
  await page.evaluate(`window.__picture(1800, true)`);
  Object.assign(turned, await state());
  await page.shot('auto-sideways');
  await page.resize(390, 844); await sleep(200);
  await page.evaluate(`window.__picture(900, true)`);
  // The + key: by hand from here on, at the next step above what the picture had.
  await page.clear();
  await page.tap('[data-act=zoom][data-step="1"]');
  const stepped = { ...(await state()), views: await views() };
  await page.evaluate(`window.__picture(${r.w / 0.5})`);
  // On again, then a pinch: the picture is scaled from the zoom it has, and the request is for that.
  await toggleFit(page);
  await page.evaluate(`window.__picture(1512, true)`);
  await page.clear();
  await page.touch('touchStart', [[cx - 40, cy], [cx + 40, cy]]); await sleep(16);
  for (let i = 1; i <= 20; i++) { await page.touch('touchMove', [[cx - 40 - i * 2, cy], [cx + 40 + i * 2, cy]]); await sleep(16); }
  const during = await state();
  await page.touch('touchEnd', []); await sleep(200);
  const sent = await page.sent();
  const pinched = { during, ...(await state()), views: await views(), misactions: count(sent, 'm') + count(sent, 's') + count(sent, 'c') };
  // "Auto" with no window in front (the Finder's desktop): the Mac answers at the zoom set by hand.
  // Down to a known step: 0.35.
  for (let i = 0; i < 4 && ((await page.sent()).filter((m) => m.t === 'view').at(-1)?.zoom ?? 1) > 0.351; i++) await page.tap('[data-act=zoom][data-step="-1"]');
  await toggleFit(page);
  await page.clear();
  await page.evaluate(`window.__picture(${r.w / 0.35})`);
  const none = { ...(await state()), views: (await views()).length };
  await page.evaluate(`window.__picture(1512, true)`);
  await page.evaluate(`window.__picture(${r.w / 0.35})`);
  const gone = { ...(await state()), views: (await views()).length };
  await page.close();
  const fits = (list) => list.map((m) => `${m.fit ?? '-'} ${m.zoom}`).join();
  return { off, asked, first, second, turned, stepped, pinched, none, gone,
    ok: !off.on && off.pressed === 'false' && off.lamp === '' && off.readout === '0,5×' && !off.clipped && off.h >= 32
      && asked.on && asked.pressed === 'true' && asked.lamp === 'window' && asked.stored === 'true' && fits(asked.views) === 'window 0.5'
      && asked.label.includes('Fenster einpassen an') && off.label.includes('Fenster einpassen aus')
      && first.readout === text(r.w / 1512) && first.views === 0 && first.preview === '' && !first.clipped
      && second.readout === text(r.w / 900) && second.views === 0 && second.preview === ''
      && turned.views.length >= 1 && turned.views.every((m) => m.fit === 'window') && turned.readout === text(wide.w / 1800) && turned.on
      && !stepped.on && stepped.stored === 'false' && fits(stepped.views) === '- 0.5'
      && pinched.during.readout === text(r.w / 1512 * 2) && Math.abs(Number(pinched.during.preview.match(/scale\(([\d.]+)\)/)?.[1]) - 2) < 0.01 && !pinched.on && pinched.misactions === 0
      && pinched.views.length === 1 && pinched.views[0].fit === undefined && Math.abs(pinched.views[0].zoom - r.w / 1512 * 2) < 0.002
      && none.on && none.readout === '0,35×' && none.views === 0 && gone.readout === '0,35×' && gone.views === 0 };
});

// T12: the display picker. With three displays the Apps sheet shows them under the apps, as they are arranged,
// the pointer's one lit. A tap asks for that display and puts the sheet away. The map follows a display that is
// unplugged, and one display shows no map at all.
await task('T12', async () => {
  const out = { layout: {} };
  // Since version 18 the displays are in the view's menu, under its items.
  const isOpen = (page) => page.evaluate(`!document.querySelector('#viewMenu').hidden`);
  const open = async (page) => { if (!(await isOpen(page))) await page.tap('#readout'); await sleep(450); };
  const tiles = (page) => page.evaluate(`(() => { const box = (e) => e.getBoundingClientRect();
    const map = document.querySelector('#displays'), sheet = box(document.querySelector('#viewMenu')), well = box(document.querySelector('#viewMenu [data-act=zoom-all]'));
    const list = [...map.querySelectorAll('.display')].map((e) => { const r = box(e); return { id: e.dataset.display, x: r.x, y: r.y, w: r.width, h: r.height,
      here: e.classList.contains('here'), name: e.textContent, label: e.getAttribute('aria-label'), off: e.disabled,
      cut: e.firstElementChild.firstElementChild.getBoundingClientRect().height > e.firstElementChild.clientHeight + 0.5 }; });
    const apps = [...document.querySelectorAll('.app')].map(box);
    return { hidden: map.hidden, list, smallest: list.length ? Math.round(Math.min(...list.map((t) => Math.min(t.w, t.h)))) : 0,
      // Under the view's items, or sideways beside them.
      inside: list.every((t) => t.x >= sheet.left - 0.5 && t.x + t.w <= sheet.right + 0.5 && (t.y >= well.bottom - 0.5 || t.x >= well.right - 0.5)
        && t.y >= sheet.top - 0.5 && t.y + t.h <= sheet.bottom + 0.5),
      belowZoom: (() => { const z = box(document.querySelector('#zoom')); return sheet.top >= z.bottom - 0.5 || sheet.right <= z.left + 0.5 || sheet.left >= z.right - 0.5; })(),
      inView: sheet.top >= -0.5 && sheet.bottom <= innerHeight + 0.5 && sheet.left >= -0.5 && sheet.right <= innerWidth + 0.5 }; })()`);
  // As arranged: the laptop above, the two large ones under it, side by side and of one size.
  const arranged = (list) => { const [laptop, left, right] = list;
    return list.length === 3 && laptop.y + laptop.h <= left.y + 0.5 && Math.abs(left.y - right.y) < 0.5 && Math.abs(left.x + left.w - right.x) < 0.5
      && Math.abs(left.w - right.w) < 0.5 && laptop.w < left.w && laptop.x > left.x && laptop.x + laptop.w < right.x + right.w; };
  for (const [phone, [w, h]] of Object.entries(PHONES)) {
    for (const orientation of ['portrait', 'landscape']) {
      const page = await openPage(...(orientation === 'portrait' ? [w, h] : [h, w]));
      await page.evaluate(`window.__displays = ${JSON.stringify(DISPLAYS)}`);
      await open(page);
      const seen = await tiles(page);
      out.layout[`${phone} ${orientation}`] = { tiles: seen.list.length, smallest: seen.smallest, inside: seen.inside, belowZoom: seen.belowZoom,
        inView: seen.inView, arranged: arranged(seen.list), cut: seen.list.filter((t) => t.cut).map((t) => t.name) };
      if (phone === 'small') await page.shot(`displays-${orientation}`);
      await page.close();
    }
  }
  const page = await openPage(375, 812);
  // One display: no map, and the sheet is as it was. The page has asked for the displays once before, when it
  // connected: the pointer it draws stops at their edges.
  const askedFor = async () => (await page.sent()).filter((m) => m.t === 'displays').length;
  const connecting = await askedFor();
  await open(page);
  const one = { ...(await tiles(page)), asked: await askedFor() - connecting, connecting };
  await page.tap('#readout'); await sleep(300);
  // Three: plugged in while the sheet was shut.
  await page.evaluate(`window.__displays = ${JSON.stringify(DISPLAYS)}`);
  await open(page);
  const three = await tiles(page);
  three.markup = await page.evaluate(`!!document.querySelector('#displays img') || !!window.__xss`);
  await page.clear();
  await page.tap('[data-display="2"]'); await sleep(300);
  const tap = { sent: (await page.sent()).filter((m) => m.t !== 'view').map(({ at, ...m }) => m), closed: !(await isOpen(page)) };
  // One is unplugged while the sheet is open: the Mac says so without being asked.
  await open(page);
  await page.evaluate(`window.__socket.onmessage({ data: ${JSON.stringify(JSON.stringify({ t: 'displays', list: [DISPLAYS[0], { ...DISPLAYS[1], pointer: true }].map((d, i) => ({ ...d, pointer: i === 1 })) }))} })`);
  const two = await tiles(page);
  // Opened again while the Mac is slow to answer: the map of last time takes no tap.
  await page.tap('#readout'); await sleep(300);
  await page.evaluate(`window.__appsDelay = ${SLOW_ANSWER}`);
  await page.tap('#readout'); await sleep(150);
  await page.clear();
  const old = (await tiles(page)).list[0];
  await page.touch('touchStart', [[old.x + old.w / 2, old.y + old.h / 2]]); await sleep(40); await page.touch('touchEnd', []); await sleep(60);
  const stale = { off: (await tiles(page)).list.every((t) => t.off), sent: (await page.sent()).filter((m) => m.t === 'display').length, open: await isOpen(page) };
  await sleep(SLOW_ANSWER + 200);
  stale.after = (await tiles(page)).list.filter((t) => !t.off).length;
  await page.close();
  return { ...out, one: { hidden: one.hidden, asked: one.asked, connecting: one.connecting }, three, tap, two: { tiles: two.list.length, here: two.list.filter((t) => t.here).map((t) => t.id) }, stale,
    // Sideways the display is short: the map is lower there, so a row of apps stays in sight on the smallest phone.
    ok: Object.entries(out.layout).every(([name, l]) => l.tiles === 3 && l.smallest >= 44 && l.inside && l.belowZoom && l.inView
        && l.arranged && l.cut.length === 0)
      && one.hidden && one.asked === 1 && one.connecting === 1 && !three.hidden && arranged(three.list) && !three.markup
      && three.list.filter((t) => t.here).map((t) => t.id).join() === '1' && three.list[0].label === 'Display Built-in Retina Display, mit dem Zeiger'
      && three.list[2].name.startsWith('<img')
      && JSON.stringify(tap.sent) === '[{"t":"display","id":2}]' && tap.closed
      && two.list.length === 2 && two.list.filter((t) => t.here).map((t) => t.id).join() === '2'
      && stale.off && stale.sent === 0 && stale.open && stale.after === 3 };
});

// T13: "Telefonform". A latch in the Apps sheet's head asks the Mac to give the window in front the phone's shape,
// which needs "Auto" and switches it on. From then on the zoom is the window's size: + and a pinch ask for
// another one and "Auto" stays on. The readout's key ends it and keeps the latch for the next time. A page that
// goes out of sight says so, so the window gets its frame back.
await task('T13', async () => {
  const out = { layout: {} };
  // Since version 18 "An iPhone anpassen" is a checked item in the view's menu, beside "Fenster einpassen".
  for (const [phone, [w, h]] of Object.entries(PHONES)) {
    for (const orientation of ['portrait', 'landscape']) {
      const page = await openPage(...(orientation === 'portrait' ? [w, h] : [h, w]));
      await page.tap('#readout'); await sleep(400);
      out.layout[`${phone} ${orientation}`] = await page.evaluate(`(() => { const key = document.querySelector('#viewMenu [data-act=shape]'), r = key.getBoundingClientRect(),
        m = document.querySelector('#viewMenu').getBoundingClientRect(), label = key.querySelector('span');
        return { w: Math.round(r.width), h: Math.round(r.height), inside: r.left >= m.left - 0.5 && r.right <= m.right + 0.5 && m.right <= innerWidth + 0.5 && m.bottom <= innerHeight + 0.5,
          whole: label.scrollWidth <= label.clientWidth + 1 }; })()`);
      await page.close();
    }
  }
  const page = await openPage(390, 844);
  const r = await page.rect('#screen');
  const cx = r.x + r.w / 2, cy = r.y + r.h / 2;
  const views = async () => (await page.sent()).filter((m) => m.t === 'view').map(({ at, v, ...m }) => m);
  const asked = (list) => list.map((m) => (m.on ? `${m.fit ?? '-'} ${m.shape ?? '-'}` : 'off')).join();
  const state = () => page.evaluate(`(() => { const key = document.querySelector('#viewMenu [data-act=shape]'), lamp = document.querySelector('#zoomValue'),
      readout = document.querySelector('#readout');
    return { readout: lamp.textContent, lamp: { phone: 'Form', window: 'Auto', '': '' }[readout.dataset.lamp], lit: readout.classList.contains('on'),
      latch: key.getAttribute('aria-checked') === 'true', pressed: key.getAttribute('aria-checked'),
      stored: [localStorage.getItem('remotey-shape'), localStorage.getItem('remotey-fit')].join(), open: !document.querySelector('#viewMenu').hidden,
      clipped: lamp.scrollWidth > readout.clientWidth }; })()`);
  const text = (z) => `${String(Math.round(z * 100) / 100).replace('.', ',')}×`;
  await page.evaluate(`window.__picture(${r.w / 0.5})`); // the first JPEG only switches the page from H.264 to JPEG
  await sleep(200);
  const before = await state();
  await page.clear();
  await toggleShape(page);
  const on = { ...(await state()), views: await views() };
  await page.tap('#readout'); await sleep(400);
  await page.shot('form-sheet');
  await page.tap('#readout'); await sleep(300);
  // The Mac gave the window the phone's shape: it shows at the zoom asked for and fills the display.
  await page.clear();
  await page.evaluate(`window.__picture(${r.w / 0.5}, true)`);
  const shaped = { ...(await state()), views: (await views()).length };
  await page.shot('form');
  // + asks for a smaller window, which shows larger. "Auto" stays on.
  await page.tap('[data-act=zoom][data-step="1"]');
  const stepped = { ...(await state()), views: await views() };
  // The app has a smallest size and stays at it: the readout says what is. + would ask for the step above that,
  // which the Mac was asked for already, so nothing is sent.
  await page.evaluate(`window.__picture(${r.w / 0.6}, true)`);
  await page.clear();
  await page.tap('[data-act=zoom][data-step="1"]');
  const held = { ...(await state()), views: await views() };
  // A pinch to twice the size: one request for that, nothing else.
  await page.clear();
  await page.touch('touchStart', [[cx - 40, cy], [cx + 40, cy]]); await sleep(16);
  for (let i = 1; i <= 20; i++) { await page.touch('touchMove', [[cx - 40 - i * 2, cy], [cx + 40 + i * 2, cy]]); await sleep(16); }
  await page.touch('touchEnd', []); await sleep(200);
  const sent = await page.sent();
  const pinched = { ...(await state()), views: await views(), misactions: count(sent, 'm') + count(sent, 's') + count(sent, 'c') };
  // Sideways the window has a size of its own.
  await page.clear();
  await page.resize(844, 390); await sleep(200);
  const turned = { views: await views() };
  await page.resize(390, 844); await sleep(200);
  // The readout's key ends "Auto" and with it the shape; the latch stays for the next time.
  await page.clear();
  await toggleFit(page);
  const off = { ...(await state()), views: await views() };
  await page.clear();
  await toggleFit(page);
  const again = { ...(await state()), views: await views() };
  // Out of sight: the page switches the view off, whatever iOS does with the socket.
  await page.clear();
  await page.evaluate(`(Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true }), document.dispatchEvent(new Event('visibilitychange')))`);
  await sleep(100);
  const hidden = await views();
  await page.evaluate(`(Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true }), document.dispatchEvent(new Event('visibilitychange')))`);
  await sleep(400);
  const back = await views();
  // The latch off: plain fitting, the windows on the Mac as they are.
  await page.clear();
  await toggleShape(page);
  const plain = { ...(await state()), views: await views() };
  await page.close();
  return { ...out, before, on, shaped, stepped, held, pinched, turned, off, again, hidden: asked(hidden), back: asked(back), plain,
    ok: Object.values(out.layout).every((l) => l.h >= 44 && l.w >= 200 && l.inside && l.whole)
      && !before.latch && before.pressed === 'false' && before.lamp === ''
      && on.latch && on.pressed === 'true' && on.stored === 'true,true' && !on.open && asked(on.views) === 'window 0.5'
      && shaped.readout === '0,5×' && shaped.lamp === 'Form' && shaped.lit && !shaped.clipped && shaped.views === 0
      && asked(stepped.views) === 'window 0.7' && stepped.lit && stepped.lamp === 'Form'
      && held.readout === '0,6×' && held.views.length === 0
      && pinched.misactions === 0 && pinched.views.length === 1 && pinched.views[0].fit === 'window' && Math.abs(pinched.views[0].shape - 1.2) < 0.01 && pinched.lit
      && turned.views.length >= 1 && turned.views.every((m) => m.fit === 'window' && m.shape === 0.5)
      && asked(off.views) === '- -' && !off.lit && off.lamp === '' && !off.latch && off.stored === 'true,false'
      && asked(again.views).startsWith('window ') && again.lit
      && asked(hidden) === 'off' && asked(back) === 'off,window 1.2'
      && !plain.latch && plain.stored === 'false,true' && asked(plain.views) === 'window -' && plain.lamp === 'Auto' && plain.lit };
});

// T14: Face ID. The Mac offers an enrolment and the page makes a passkey for it; once the Mac is locked and names
// that passkey, the type key asks the phone for it and sends its signature and secret instead of opening the
// field. A try the Mac refuses or the user declines leaves the next tap to the password field, and closing the
// field leaves it to Face ID again. Chromium's virtual authenticator is the phone's passkey here: what it signs
// is checked as the agent checks it.
await task('T14', async () => {
  const page = await openPage(...PHONES.small);
  await page.cdp('WebAuthn.enable');
  await page.cdp('WebAuthn.addVirtualAuthenticator', { options: { protocol: 'ctap2', ctap2Version: 'ctap2_1',
    transport: 'internal', hasResidentKey: true, hasUserVerification: true, hasPrf: true, isUserVerified: true, automaticPresenceSimulation: true } });
  const say = (m) => page.evaluate(`window.__socket.onmessage({ data: ${JSON.stringify(JSON.stringify(m))} })`);
  const random = () => randomBytes(32).toString('base64url'), raw = (text) => Buffer.from(text, 'base64url');
  const sent = async (t) => (await page.sent()).filter((m) => m.t === t).map(({ at, ...m }) => m);
  // The card of the offer: its state, what it says, and whether all of it lies in the display with keys a finger hits.
  const card = (p = page) => p.evaluate(`(() => { const e = document.querySelector('#enrol'), box = (s) => e.querySelector(s).getBoundingClientRect();
    const c = box('.card'), s = document.querySelector('#screen').getBoundingClientRect(), keys = [box('[data-act=enrol]'), box('[data-act=enrol-later]')];
    return { hidden: e.hidden, state: e.dataset.state, title: e.querySelector('h2').textContent, text: e.querySelector('p').textContent,
      key: e.querySelector('[data-act=enrol]').textContent, keyH: Math.round(Math.min(...keys.map((k) => k.height))),
      inside: c.left >= s.left && c.right <= s.right && c.top >= s.top && c.bottom <= s.bottom && keys.every((k) => k.bottom <= c.bottom && k.top >= c.top),
      whole: e.querySelector('.card').scrollHeight <= e.querySelector('.card').clientHeight + 1 }; })()`);
  const key = card;
  const state = () => page.evaluate(`(() => { const f = document.querySelector('#field');
    return { label: document.querySelector('#typeLabel').textContent, focused: document.activeElement === f, type: f.type, hint: f.placeholder }; })()`);
  // The user declines what iOS asks, or Face ID fails: the browser rejects the call. (The virtual authenticator
  // cannot play that: once it has failed to verify its user it refuses every later call too.)
  const decline = (call, on) => page.evaluate(on
    ? `navigator.credentials.${call} = () => Promise.reject(new DOMException('declined', 'NotAllowedError'))` : `delete navigator.credentials.${call}`);
  const tapType = async () => { await page.clear(); await page.tap('[data-act=type]'); await sleep(300); return { ...(await state()), unlocks: await sent('unlock') }; };
  // What the agent checks in Passkey.swift: made for this challenge on this page, user verified, signed by the enrolled key.
  const checked = (message, type, challenge, publicKey) => {
    const client = JSON.parse(raw(message.client)), authenticator = raw(message.auth);
    return client.type === type && client.challenge === challenge && client.origin === origin
      && authenticator.subarray(0, 32).equals(createHash('sha256').update('localhost').digest()) && (authenticator[32] & 5) === 5
      && (!publicKey || verify('sha256', Buffer.concat([authenticator, createHash('sha256').update(raw(message.client)).digest()]),
        { key: createPublicKey({ key: raw(publicKey), format: 'der', type: 'spki' }), dsaEncoding: 'der' }, raw(message.sig)));
  };

  // The offer: a card over the display; a tap on its key makes the passkey and sends what the agent keeps.
  const before = await key();
  const offer = { t: 'enrol', challenge: random(), salt: random(), name: 'Test-Mac' };
  // On every phone, upright and sideways, the card lies whole in the display.
  const layout = {};
  for (const [phone, [w, h]] of Object.entries(PHONES)) {
    for (const orientation of ['portrait', 'landscape']) {
      const other = await openPage(...(orientation === 'portrait' ? [w, h] : [h, w]));
      await other.evaluate(`window.__socket.onmessage({ data: ${JSON.stringify(JSON.stringify({ ...offer, name: 'MacBook Pro von Erika Mustermann' }))} })`);
      layout[`${phone} ${orientation}`] = await card(other);
      if (phone !== 'large') await other.shot(`enrol-${phone}-${orientation}`);
      await other.close();
    }
  }
  await say(offer);
  const offered = await key();
  await page.shot('enrol');
  // "Nicht jetzt" puts the card away; the Mac's offer stands, so a new one shows it again.
  await page.tap('[data-act=enrol-later]');
  const later = await key();
  await say(offer);
  // The passkey is not made: the card says so and offers another try.
  await decline('create', true);
  await page.clear();
  await page.tap('[data-act=enrol]'); await sleep(400);
  const failed = { ...(await key()), sent: (await sent('enrol')).length };
  await page.shot('enrol-failed');
  await decline('create', false);
  await page.tap('[data-act=enrol]'); await sleep(400);
  const [enrol] = await sent('enrol'), taking = await key();
  await say({ t: 'enrolled', ok: true });
  const done = await key();
  await page.shot('enrol-done');
  await sleep(2700);
  const gone = await key();

  // Locked, and the Mac names the passkey: the type key asks the phone for it.
  const challenges = [random(), random(), random(), random()];
  const lock = (i) => say({ t: 'lock', on: true, key: { id: enrol.cred, salt: offer.salt, challenge: challenges[i] } });
  await lock(0);
  const named = await state(); // the key names the way: Face ID
  const first = await tapType();
  // The Mac typed the sealed password and stayed locked: the next tap opens the field for the password.
  await say({ t: 'unlock', ok: false, why: 'password' }); await lock(1);
  const refused = await state();
  const field = await tapType();
  // The field put away: Face ID again, with the Mac's next challenge.
  await page.evaluate(`document.querySelector('#field').blur()`);
  const second = await tapType();
  // A Mac that was not ready is asked again with Face ID at once.
  await say({ t: 'unlock', ok: false, why: 'field' }); await lock(2);
  const unready = await state();
  const third = await tapType();
  // Face ID fails or is cancelled: nothing leaves, the next tap opens the field.
  await lock(3);
  await decline('get', true);
  const declined = await tapType();
  const after = await tapType();
  // The lock key on the tray's first page asks for Face ID too.
  await page.evaluate(`document.querySelector('#field').blur()`);
  await decline('get', false);
  await page.tap('[data-act=deck]'); await sleep(450);
  await page.clear();
  await page.tap('.tile[data-act=lock]'); await sleep(300);
  const byLockKey = { ...(await state()), unlocks: await sent('unlock') };
  await page.shot('locked');
  await say({ t: 'lock', on: false });
  const open = await state();
  await page.close();
  const answers = [first, second, third].map((t) => t.unlocks[0]);
  return { before, layout, offered, later, failed, taking, done, gone, enrol, named, first, refused, field, second, unready, third, declined, after, byLockKey, open,
    vector: { origin, offer, challenge: challenges[0] },
    ok: before.hidden && Object.values(layout).every((l) => !l.hidden && l.inside && l.whole && l.keyH >= 44)
      && !offered.hidden && offered.state === 'offer' && offered.title === 'Mit Face ID entsperren' && offered.text.includes('„Test-Mac“') && offered.key === 'Einrichten'
      && later.hidden && failed.state === 'failed' && failed.key === 'Erneut versuchen' && failed.sent === 0 && !failed.hidden
      && !!enrol && checked(enrol, 'webauthn.create', offer.challenge) && raw(enrol.prf).length === 32 && raw(enrol.key).length === 91
      && taking.state === 'busy' && taking.key === 'Richte ein…' && !done.hidden && done.state === 'done' && done.title === 'Eingerichtet' && gone.hidden
      && byLockKey.unlocks.length === 1 && checked(byLockKey.unlocks[0], 'webauthn.get', challenges[3], enrol.key) && !byLockKey.focused
      && first.unlocks.length === 1 && first.label === 'Entsperre…' && !first.focused
      && answers.every((a, i) => a && !('s' in a) && a.prf === enrol.prf && checked(a, 'webauthn.get', challenges[i], enrol.key))
      && refused.label === 'Abgelehnt' && !refused.focused
      && named.label === 'Mit Face ID entsperren'
      && field.focused && field.type === 'password' && field.label === 'Mac entsperren' && field.unlocks.length === 0
      && second.unlocks.length === 1 && !second.focused
      && unready.label === 'Nicht bereit' && third.unlocks.length === 1 && !third.focused
      && declined.unlocks.length === 0 && declined.label === 'Mac entsperren' && !declined.focused
      && after.focused && after.unlocks.length === 0
      && open.label === 'Auf dem Mac schreiben' && open.type === 'text' };
});

// T15: the pointer ahead of the Mac, while the window in front has the phone's shape. A move shows on the page at
// once, before any answer; the answer leaves the pointer where it is; and a move against the display's edge stops
// there, as the Mac holds the pointer. Without "Telefonform" the pointer waits for the Mac, as the picture does.
await task('T15', async () => {
  const page = await openPage(390, 844);
  const screen = await page.rect('#screen');
  const aim = async () => { const r = await page.rect('#aim'); return { x: round(r.x + r.w / 2 - screen.x), y: round(r.y + r.h / 2 - screen.y) }; };
  const x0 = screen.x + 200, y0 = screen.y + 300;
  const drag = async () => {
    await page.clear();
    await page.touch('touchStart', [[x0, y0]]);
    for (let i = 1; i <= 20; i++) { await sleep(16); await page.touch('touchMove', [[x0 + i * 2, y0]]); }
    await sleep(40);
    return (await page.sent()).filter((m) => m.t === 'm');
  };
  // The picture at the zoom the page asked for, 0.5, with its left top at the display's: the pointer is in the middle.
  const wide = screen.w * 2, pixelsPerPoint = 0.5;
  await page.evaluate(`window.__picture(${wide})`); // the first JPEG only switches the page from H.264 to JPEG
  await page.evaluate(`window.__picture(${wide})`);
  const [, high] = await page.evaluate('window.__shows');
  const start = await aim();
  // The picture is cut around the pointer: it waits for the Mac.
  const waited = { moves: (await drag()).length, aim: await aim() };
  await page.touch('touchEnd', []); await sleep(80);
  // "Telefonform": the Mac fits the picture to the window, and the picture stands still.
  await toggleShape(page);
  await page.evaluate(`window.__picture(${wide}, true)`);
  const moves = await drag();
  const points = Math.trunc(sum(moves, 'm', 'dx')), ahead = await aim();
  // The Mac answers with all of them made.
  await page.evaluate(`window.__pointer(${wide / 2 + points}, ${high / 2}, ${moves.at(-1).q})`);
  const answered = await aim();
  // And then says that its own mouse took the pointer elsewhere.
  await page.evaluate(`window.__pointer(100, 100, ${moves.at(-1).q})`);
  const taken = await aim();
  await page.touch('touchEnd', []); await sleep(80);
  // A fast swipe to the left, further than the display goes: the pointer waits at its edge.
  await page.touch('touchStart', [[x0 + 150, y0]]);
  for (let i = 1; i <= 10; i++) { await sleep(8); await page.touch('touchMove', [[x0 + 150 - i * 25, y0]]); }
  await sleep(40);
  const swiped = Math.trunc(sum((await page.sent()).filter((m) => m.q > moves.at(-1).q), 'm', 'dx')), edge = await aim();
  await page.touch('touchEnd', []); await sleep(80);
  const clicks = count(await page.sent(), 'c');
  await page.close();
  return { start, waited, points, ahead, answered, taken, swiped, edge, clicks,
    ok: waited.moves > 5 && waited.aim.x === start.x && waited.aim.y === start.y
      && points > 20 && Math.abs(ahead.x - start.x - points * pixelsPerPoint) < 1 && ahead.y === start.y
      && Math.abs(answered.x - ahead.x) < 0.5 && Math.abs(taken.x - 100 * pixelsPerPoint) < 0.5 && Math.abs(taken.y - 100 * pixelsPerPoint) < 0.5
      && swiped < -100 && Math.abs(edge.x) < 0.5 && edge.y === taken.y && clicks === 0 };
});

// T16: the connection's states. Each says what it is on the display in words with a symbol, and a failure shows a
// notice with its likely cause and one button. A failed try is repeated at a growing interval, at once on a tap.
// Baseline: one red dot and "Keine Verbindung zum Mac." for every failure, a try every second.
await task('T16', async () => {
  // Since version 18 the state's symbol is in the Mac's button: ok, wait, bad, shut (locked) or held (paused).
  const look = (page) => page.evaluate(`(() => { const n = document.querySelector('#notice'), s = document.querySelector('#macBtn');
    const sym = [...s.querySelectorAll('.state svg')].find((e) => getComputedStyle(e).display !== 'none');
    const nsym = [...n.querySelectorAll('.sym')].filter((e) => getComputedStyle(e).display !== 'none').map((e) => e.dataset.for);
    return { link: document.body.dataset.link, status: document.querySelector('#statusText').textContent, symbol: sym?.getAttribute('class') ?? null,
      notice: n.hidden ? null : { kind: n.dataset.kind, title: n.querySelector('h2').textContent, text: n.querySelector('p').textContent,
        button: n.querySelector('button').hidden ? null : n.querySelector('button').textContent, symbols: nsym }, mac: s.textContent.trim(),
      welcome: !document.querySelector('#welcome').hidden }; })()`);
  const sockets = (page) => page.evaluate('window.__sockets.slice()');
  const out = {};
  // Never paired: the first start's steps, and no socket.
  const fresh = {};
  for (const [label, [width, height]] of [['narrow portrait', PHONES.narrow], ['small portrait', PHONES.small], ['narrow landscape', [568, 320]]]) {
    const page = await openPage(width, height, { token: false });
    fresh[label] = await page.evaluate(`(() => { const w = document.querySelector('#welcome'), c = w.querySelector('.card').getBoundingClientRect();
      return { shown: !w.hidden, steps: [...w.querySelectorAll('li')].map((li) => li.textContent), title: w.querySelector('h1').textContent,
        back: !w.querySelector('[data-act=welcome-back]').hidden, sockets: window.__sockets.length, link: document.body.dataset.link,
        inside: c.left >= 0 && c.right <= innerWidth, scrolls: w.scrollHeight > w.clientHeight }; })()`);
    if (label === 'small portrait') await page.shot('welcome');
    await page.close();
  }
  out.unpaired = fresh;
  // Connected, with and without the Accessibility permission.
  let page = await openPage(...PHONES.small);
  out.connected = await look(page);
  await page.close();
  page = await openPage(...PHONES.small);
  await page.evaluate(`(window.__mac = 'noax', window.__socket.onclose())`); await sleep(300);
  out.noAccess = await look(page);
  await page.shot('no-access');
  await page.evaluate(`window.__mac = 'up'`); await page.clear();
  await page.tap('#noticeAct'); await sleep(300);
  out.noAccess.after = { ...(await look(page)), auth: (await page.sent()).filter((m) => m.t === 'auth').length };
  await page.close();
  // The Mac out of reach: the socket fails and nothing answers. Tries come later each time; a tap tries at once.
  page = await openPage(...PHONES.small);
  await page.evaluate(`(window.__mac = 'down', window.__probe = null, window.__sockets.length = 0, window.__socket.onclose())`);
  await sleep(300);
  out.unreachable = await look(page);
  await page.shot('unreachable');
  await sleep(3600);
  const times = await sockets(page);
  out.unreachable.intervals = times.slice(1).map((at, i) => Math.round(at - times[i]));
  out.unreachable.stillShown = (await look(page)).notice?.kind;
  const before = (await sockets(page)).length;
  await page.tap('#noticeAct'); await sleep(50);
  out.unreachable.tap = { tried: (await sockets(page)).length - before };
  // Remotey not running: the origin answers 502.
  await page.evaluate(`window.__probe = 502`); await sleep(1200);
  out.stopped = await look(page);
  await page.shot('stopped');
  // No network on the phone; then it returns and the page connects at once.
  await page.evaluate(`window.__online = false`); await sleep(2500);
  out.offline = await look(page);
  await page.evaluate(`(window.__online = true, window.__mac = 'up', window.__probe = 200, window.__sockets.length = 0, dispatchEvent(new Event('online')))`);
  await sleep(150);
  out.online = { ...(await look(page)), sockets: (await sockets(page)).length };
  await page.close();
  // A connection that worked and is lost: tried again at once, no notice in between.
  page = await openPage(...PHONES.small);
  await page.evaluate(`(window.__sockets.length = 0, window.__socket.onclose())`); await sleep(100);
  out.blip = { ...(await look(page)), sockets: (await sockets(page)).length };
  await page.close();
  // Ended at the Mac ("Trennen", v19): the Mac says `bye` and closes. No try by itself, also not when the page comes
  // back into sight or the network returns; the notice's one button connects again.
  page = await openPage(...PHONES.small);
  await page.evaluate(`(window.__sockets.length = 0, window.__bye())`); await sleep(300);
  out.ended = await look(page);
  await page.shot('ended');
  await page.evaluate(`(document.dispatchEvent(new Event('visibilitychange')), dispatchEvent(new Event('online')))`);
  await sleep(1500);
  out.ended.tries = (await sockets(page)).length;
  out.ended.still = (await look(page)).notice?.kind;
  await page.tap('#noticeAct'); await sleep(300);
  out.ended.after = { ...(await look(page)), sockets: (await sockets(page)).length };
  await page.close();
  // The key refused: no more tries; the button shows how to pair again, and back.
  page = await openPage(...PHONES.small);
  await page.evaluate(`(window.__mac = 'deny', window.__socket.onclose())`); await sleep(300);
  out.denied = await look(page);
  await page.shot('denied');
  const refused = (await sockets(page)).length;
  await page.tap('#noticeAct'); await sleep(200);
  out.denied.steps = await look(page);
  await page.tap('[data-act=welcome-back]'); await sleep(200);
  out.denied.back = await look(page);
  await sleep(1500);
  out.denied.tries = (await sockets(page)).length - refused;
  await page.close();
  // The Mac refuses the live view: Screen Recording is missing, or another device took it over.
  page = await openPage(...PHONES.small);
  const say = (m) => page.evaluate(`window.__socket.onmessage({ data: ${JSON.stringify(JSON.stringify(m))} })`);
  await say({ t: 'view', ok: false }); await sleep(100);
  out.permission = { ...(await look(page)), view: await page.evaluate(`document.querySelector('#macMenu [data-act=view]').getAttribute('aria-checked')`) };
  await say({ t: 'view', ok: false, why: 'taken' }); await sleep(100);
  out.taken = await look(page);
  await page.shot('taken');
  await page.clear();
  await page.tap('#noticeAct'); await sleep(200);
  out.taken.after = { ...(await look(page)), asked: (await page.sent()).filter((m) => m.t === 'view').map((m) => m.on) };
  await page.close();
  const n = (o) => o.notice ?? {};
  const growing = out.unreachable.intervals;
  return { ...out,
    ok: Object.values(fresh).every((f) => f.shown && f.steps.length === 3 && f.title === 'Mit dem Mac verbinden' && !f.back && f.sockets === 0 && f.link === 'unpaired' && f.inside)
      && out.connected.status === 'Verbunden' && out.connected.symbol === 'ok' && !out.connected.notice
      && out.noAccess.status === 'Kein Zugriff' && out.noAccess.symbol === 'bad' && n(out.noAccess).title === 'Steuern nicht erlaubt'
      && n(out.noAccess).button === 'Erneut prüfen' && n(out.noAccess).symbols.join() === 'noAccess' && out.noAccess.after.auth === 1 && !out.noAccess.after.notice
      && out.unreachable.status === 'Nicht verbunden' && out.unreachable.symbol === 'bad' && n(out.unreachable).title === 'Mac nicht erreichbar'
      && n(out.unreachable).button === 'Erneut versuchen' && n(out.unreachable).symbols.join() === 'unreachable'
      && growing.length >= 2 && growing.length <= 4 && growing.every((ms, i) => i === 0 || ms > growing[i - 1] * 1.5)
      && out.unreachable.stillShown === 'unreachable' && out.unreachable.tap.tried === 1
      && n(out.stopped).title === 'Remotey läuft nicht' && n(out.stopped).symbols.join() === 'stopped'
      && n(out.offline).title === 'iPhone offline' && out.offline.status === 'Offline'
      && out.online.sockets === 1 && out.online.status === 'Verbunden' && !out.online.notice
      && out.blip.sockets === 1 && !out.blip.notice && out.blip.status === 'Verbunden'
      && n(out.ended).kind === 'ended' && n(out.ended).title === 'Am Mac getrennt' && n(out.ended).button === 'Wieder verbinden'
      && n(out.ended).symbols.join() === 'ended' && out.ended.symbol === 'off' && out.ended.status === 'Getrennt'
      && out.ended.tries === 0 && out.ended.still === 'ended' && out.ended.after.sockets === 1 && out.ended.after.status === 'Verbunden' && !out.ended.after.notice
      && n(out.denied).title === 'Kopplung ungültig' && n(out.denied).button === 'So geht’s' && out.denied.status === 'Nicht gekoppelt'
      && out.denied.steps.welcome && !out.denied.back.welcome && out.denied.tries === 0
      && n(out.permission).kind === 'permission' && n(out.permission).title === 'Live-Bild nicht erlaubt' && out.permission.view === 'false' && out.permission.status === 'Verbunden'
      && n(out.taken).kind === 'taken' && n(out.taken).button === 'Hierher holen' && !out.taken.after.notice && out.taken.after.asked.at(-1) === true };
});

// T17: words and type. On every phone, upright and sideways, in German and in English, with the tray on each page
// and the switcher open: no text under 11 px, no capitals set with letter-spacing, none of the page's own words
// cut off, and the controls that stay in the coming layout (dock, zoom) take a finger of 44 pt.
// Baseline: 8 px for "Auto", 10 px in nine places, capitals with letter-spacing on every legend.
await task('T17', async () => {
  const out = {};
  const survey = (page) => page.evaluate(`(() => {
    const shown = (e) => { const r = e.getBoundingClientRect(), st = getComputedStyle(e);
      return r.width > 0 && r.height > 0 && st.visibility !== 'hidden' && !e.closest('[hidden]') && !e.closest('body:not(.typing) #typebar'); };
    const texts = [...document.querySelectorAll('body *')].filter((e) => [...e.childNodes].some((c) => c.nodeType === 3 && c.textContent.trim()) && shown(e));
    const sizes = texts.map((e) => ({ e, size: parseFloat(getComputedStyle(e).fontSize) }));
    const small = sizes.filter((x) => x.size < 11 - 0.01).map((x) => x.e.textContent.trim().slice(0, 20) + ' ' + x.size);
    const caps = texts.filter((e) => { const st = getComputedStyle(e); return st.textTransform === 'uppercase' || (parseFloat(st.letterSpacing) > 0.5 && /[A-ZÄÖÜ]{3}/.test(e.textContent)); })
      .map((e) => e.textContent.trim().slice(0, 20));
    // The page's own words: an element that names a key, the type key's words, the chip, the setting names.
    const own = [...document.querySelectorAll('[data-text], #typeLabel, #typeShort, #macName, #noticeAct')].filter(shown).filter((e) => !e.closest('.sr'));
    // Measured on the words themselves: a key's wider touch target (::after) is no overflow.
    const cut = own.filter((e) => { const range = document.createRange(); range.selectNodeContents(e); const w = range.getBoundingClientRect(), box = e.getBoundingClientRect();
      const clip = e.closest('.slot, .key, .cap, button') ?? e, c = clip.getBoundingClientRect();
      return w.width > box.width + 1 || w.left < c.left - 0.5 || w.right > c.right + 0.5 || (getComputedStyle(e).textOverflow === 'ellipsis' && e.scrollWidth > e.clientWidth + 1); })
      .map((e) => e.textContent.trim() + ' ' + Math.round(e.getBoundingClientRect().width) + (e.closest('#typebar') ? ' typebar' : '') + ' ' + innerWidth + '×' + innerHeight);
    return { smallest: Math.min(...sizes.map((x) => x.size)), small, caps, cut };
  })()`);
  // A 44 × 44 box around each control's centre: its edges and corners must reach the control.
  const targets = (page) => page.evaluate(`(() => {
    const list = ['[data-act=zoom][data-step="-1"]', '#readout', '[data-act=zoom][data-step="1"]', '[data-click=back]', '[data-click=forward]',
      '[data-hold=left]', '[data-click=right]', '[data-act=type]', '[data-act=apps]', '[data-act=deck]', '#macBtn'];
    const small = [];
    for (const sel of list) {
      const e = document.querySelector(sel), r = e.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
      if (!r.width) { small.push(sel + ' not shown'); continue; }
      // A round finger of 44 pt: the circle's edge in eight directions.
      const misses = [[-21, 0], [21, 0], [0, -21], [0, 21], [-15, -15], [15, 15], [-15, 15], [15, -15]].filter(([dx, dy]) => {
        const hit = document.elementFromPoint(x + dx, y + dy); return !hit || !(hit === e || e.contains(hit)); });
      if (misses.length) small.push(sel + ' ' + Math.round(r.width) + '×' + Math.round(r.height) + ' misses ' + misses.length);
    }
    return small;
  })()`);
  for (const lang of ['de-DE', 'en-US']) {
    for (const [phone, [w, h]] of Object.entries(PHONES)) {
      for (const orientation of ['portrait', 'landscape']) {
        const page = await openPage(...(orientation === 'portrait' ? [w, h] : [h, w]), { lang });
        await page.evaluate(`window.__picture(${w})`); await sleep(150);
        const views = { main: await survey(page), targets: await targets(page) };
        await page.tap('[data-act=deck]'); await sleep(450);
        for (const p of ['media', 'keys']) {
          await page.tap(`[data-act=page][data-page=${p}]`); await sleep(250);
          views[p] = await survey(page);
          if (phone === 'narrow' && orientation === 'portrait') await page.shot(`tray-${p}-${lang.slice(0, 2)}`);
        }
        await closeSheet(page);
        await openSettings(page);
        views.settings = await survey(page);
        await page.evaluate(`document.querySelector('#prefs .well').scrollTop = 9999`); await sleep(100);
        views.settingsEnd = await survey(page);
        if (phone === 'narrow' && orientation === 'portrait') await page.shot(`tray-settings-${lang.slice(0, 2)}`);
        await closeSheet(page);
        await page.tap('#macBtn'); await sleep(400);
        views.macMenu = await survey(page);
        await page.tap('#macBtn'); await sleep(300);
        await page.tap('#readout'); await sleep(400);
        views.viewMenu = await survey(page);
        await page.tap('#readout'); await sleep(300);
        await page.tap('[data-act=apps]'); await sleep(450);
        views.apps = await survey(page);
        if (phone === 'narrow' && orientation === 'portrait') await page.shot(`apps-${lang.slice(0, 2)}`);
        await closeSheet(page);
        await page.tap('[data-act=type]'); await sleep(300);
        views.typing = await survey(page);
        await page.evaluate(`document.querySelector('#field').blur()`); await sleep(300);
        // A locked Mac with Face ID: the longest words the type key has.
        await page.evaluate(`window.__socket.onmessage({ data: JSON.stringify({ t: 'lock', on: true, key: { id: 'AA', salt: 'AA', challenge: 'AA' } }) })`);
        await sleep(100);
        views.locked = await survey(page);
        if (orientation === 'portrait') await page.shot(`main-${phone}-${lang.slice(0, 2)}`);
        else await page.shot(`main-${phone}-landscape-${lang.slice(0, 2)}`);
        out[`${lang} ${phone} ${orientation}`] = views;
        await page.close();
      }
    }
  }
  const all = Object.values(out).flatMap((v) => Object.entries(v).filter(([k]) => k !== 'targets').map(([, s]) => s));
  return { smallest: Math.min(...all.map((s) => s.smallest)), small: [...new Set(all.flatMap((s) => s.small))],
    caps: [...new Set(all.flatMap((s) => s.caps))], cut: [...new Set(all.flatMap((s) => s.cut))],
    targets: Object.fromEntries(Object.entries(out).map(([k, v]) => [k, v.targets]).filter(([, v]) => v.length)),
    ok: all.every((s) => s.smallest >= 11 && !s.caps.length && !s.cut.length) && Object.values(out).every((v) => !v.targets.length) };
});

// T18: the page's half of the protocol fixes. In sight the page says `ping` every 5 s; long text goes in pieces the
// Mac takes; the icons stay across a reconnect and are named in the request; frame rate and delay show only when
// the setting asks for it.
await task('T18', async () => {
  const page = await openPage(...PHONES.small);
  await page.clear();
  await sleep(5600);
  const pings = (await page.sent()).filter((m) => m.t === 'ping').length;
  // A paste of 2500 characters, with accents, a flag and an emoji with skin tone among them.
  const text = 'é'.repeat(999) + '🇩🇪' + 'Grüße 👋🏽 '.repeat(150);
  await page.clear();
  await page.evaluate(`(() => { const f = document.querySelector('#field'); f.focus(); f.setRangeText(${JSON.stringify(text)}, f.value.length, f.value.length, 'end');
    f.dispatchEvent(new InputEvent('input', { inputType: 'insertFromPaste' })); })()`);
  const pieces = (await page.sent()).filter((m) => m.t === 'text').map((m) => m.s);
  const graphemes = (s) => [...new Intl.Segmenter().segment(s)].length;
  const long = { pieces: pieces.length, largest: Math.max(...pieces.map(graphemes)), whole: pieces.join('') === text, flag: pieces.some((p) => p.endsWith('🇩🇪')) };
  await page.evaluate(`document.querySelector('#field').blur()`); await sleep(200);
  // Icons: the first opening gets Safari's; after a reconnect the request names it.
  await page.tap('[data-act=apps]'); await sleep(450);
  await closeSheet(page);
  await page.evaluate(`window.__socket.onclose()`); await sleep(400);
  await page.clear();
  await page.tap('[data-act=apps]'); await sleep(450);
  const asked = (await page.sent()).filter((m) => m.t === 'apps').map(({ at, ...m }) => m);
  const icon = await page.evaluate(`!!document.querySelector('[data-pid="501"] img[src^="data:image/png"]')`);
  await closeSheet(page);
  // The readout (since version 18 in the Mac's button instead of the Mac's name): hidden at first, shown by the setting, kept.
  await page.evaluate(`window.__picture(375)`); await sleep(100);
  // A move, so there is something to measure.
  const r = await page.rect('#screen');
  await page.gesture({ steps: 10, at: (i) => [[r.x + 100 + i * 4, r.y + 300]] });
  await page.evaluate(`window.__picture(375)`); await sleep(700);
  const meter = () => page.evaluate(`document.querySelector('#macBtn').classList.contains('meter') && /fps/.test(document.querySelector('#macName').textContent)`);
  const hidden = await meter();
  await openSettings(page);
  await tapSetting(page, 'meter'); await sleep(700);
  const shown = { meter: await meter(), pressed: await page.evaluate(`document.querySelector('#prefs [data-act=meter]').getAttribute('aria-checked')`),
    stored: await page.evaluate(`localStorage.getItem('remotey-meter')`) };
  await page.close();
  return { pings, long, asked, icon, meter: { hidden, ...shown },
    ok: pings === 1 && long.pieces >= 3 && long.largest <= 1000 && long.whole && long.flag
      && JSON.stringify(asked) === '[{"t":"apps","have":["safari"]}]' && icon
      && !hidden && shown.meter && shown.pressed === 'true' && shown.stored === 'true' };
});

// T19: pairing per device. A one-time code in the link pairs and leaves the address; the old token is posted once
// to become a device; an agent without pairing gets the token as before; a phone the Mac does not know shows the
// first start, whose field takes six digits typed or pasted and says in words what went wrong.
await task('T19', async () => {
  const look = (page) => page.evaluate(`({ link: document.body.dataset.link, hash: location.hash, welcome: !document.querySelector('#welcome').hidden,
    says: document.querySelector('#pairSays').textContent, failed: document.querySelector('.code').classList.contains('failed'),
    field: document.querySelector('#code').value, token: localStorage.getItem('remotey-token'),
    auth: window.__sent.filter((m) => m.t === 'auth').map(({ at, ...m }) => m) })`);
  const paths = () => fakeMac.log.map((l) => `${l.path}${l.body.code ? ' code' : l.body.token ? ' token' : ''}`).join();
  const type = (page, text) => page.evaluate(`(() => { const f = document.querySelector('#code'); f.focus(); f.value = ${JSON.stringify(text)};
    f.dispatchEvent(new InputEvent('input', { inputType: 'insertFromPaste' })); })()`);
  const out = {};
  // The QR code's link: pairs, asks for a ticket, connects with it, and the code is out of the address.
  resetMac();
  let page = await openPage(393, 852, { hash: '#p=482913' });
  await sleep(300);
  out.link = { ...(await look(page)), paths: paths() };
  await page.close();
  // Paired the old way: the token becomes a device once, then tickets only; it leaves the address and the phone.
  resetMac();
  page = await openPage(393, 852);
  out.upgrade = { ...(await look(page)), paths: paths() };
  await page.evaluate(`window.__socket.onclose()`); await sleep(400);
  out.upgrade.again = paths();
  await page.close();
  // An agent from before pairing per device: the old token, as before, and the address keeps it.
  resetMac();
  fakeMac.mode = 'old';
  page = await openPage(393, 852);
  out.old = { ...(await look(page)), paths: paths() };
  await page.close();
  resetMac();
  // A link with a code that is no longer good: the first start says so, and the field is ready.
  page = await openPage(393, 852, { hash: '#p=000000' });
  await sleep(300);
  out.spent = await look(page);
  await page.close();
  // Never paired: the first start. Pasted with a space, the six digits pair this phone.
  resetMac();
  page = await openPage(393, 852, { token: false });
  out.fresh = await look(page);
  out.fresh.field = await page.evaluate(`(() => { const f = document.querySelector('#code'); return { mode: f.inputMode, auto: f.autocomplete,
    label: f.getAttribute('aria-label'), cells: document.querySelectorAll('.cells span').length }; })()`);
  await type(page, '111 111'); await sleep(300);
  out.wrong = await look(page);
  await page.shot('welcome-wrong');
  fakeMac.closed = true;
  await type(page, '482913'); await sleep(300);
  out.closed = await look(page);
  fakeMac.closed = false;
  fakeMac.tries = fakeMac.most;
  await type(page, '482913'); await sleep(300);
  out.tries = await look(page);
  fakeMac.tries = 0;
  await type(page, '482 913'); await sleep(500);
  out.paired = { ...(await look(page)), paths: paths() };
  await page.close();
  // The Mac removed this phone: a notice of its own, and its button leads to the field for a new code.
  resetMac();
  page = await openPage(393, 852);
  await page.evaluate(`(window.__mac = 'revoked', window.__socket.onclose())`); await sleep(500);
  out.revoked = await page.evaluate(`({ kind: document.querySelector('#notice').dataset.kind, title: document.querySelector('#noticeTitle').textContent,
    button: document.querySelector('#noticeAct').textContent, link: document.body.dataset.link })`);
  await page.shot('revoked');
  await page.tap('#noticeAct'); await sleep(200);
  out.revoked.welcome = (await look(page)).welcome;
  await page.close();
  resetMac();
  const ticket = (a) => a.length >= 1 && a.every((m) => /^t\d+$/.test(m.ticket) && m.standalone === false && !('token' in m));
  return { ...out,
    ok: out.link.link === 'connected' && out.link.hash === '' && out.link.paths === '/pair code,/session' && ticket(out.link.auth)
      && out.upgrade.link === 'connected' && out.upgrade.hash === '' && out.upgrade.token === null && out.upgrade.paths === '/session,/pair token,/session'
      && ticket(out.upgrade.auth) && out.upgrade.again === '/session,/pair token,/session,/session'
      && out.old.link === 'connected' && out.old.hash === '#test-token' && out.old.paths === '/session' && JSON.stringify(out.old.auth) === '[{"t":"auth","token":"test-token"}]'
      && out.spent.welcome && out.spent.hash === '' && out.spent.says.startsWith('Dieser Code stimmt nicht')
      && out.fresh.welcome && out.fresh.link === 'unpaired' && out.fresh.auth.length === 0
      && out.fresh.field.mode === 'numeric' && out.fresh.field.auto === 'one-time-code' && out.fresh.field.cells === 6 && !!out.fresh.field.label
      && out.wrong.says.startsWith('Dieser Code stimmt nicht') && out.wrong.failed && out.wrong.field === '' && out.wrong.welcome
      && out.closed.says.startsWith('Am Mac ist gerade keine Kopplung offen') && out.tries.says.startsWith('Zu viele Versuche')
      && out.paired.link === 'connected' && !out.paired.welcome && ticket(out.paired.auth) && out.paired.paths.endsWith('/pair code,/session')
      && out.revoked.kind === 'revoked' && out.revoked.button === 'Neu koppeln' && out.revoked.welcome };
});

// T20: glass over the picture. The page tells the Mac what its controls cover; opening a sheet or a menu changes
// neither the picture's size nor that, so the stream runs on. The blur is kept to the capsules, nothing that
// moves is blurred, and solid surfaces replace it when asked for or when the phone reduces transparency. The
// Mac's own state comes as `mac`: a permission granted there shows at once, a pause has words of its own.
await task('T20', async () => {
  const out = {};
  const glassy = (page) => page.evaluate(`(() => {
    const blurred = [...document.querySelectorAll('body *')].filter((e) => { const st = getComputedStyle(e), r = e.getBoundingClientRect();
      return r.width > 0 && st.display !== 'none' && st.visibility !== 'hidden' && (st.backdropFilter || st.webkitBackdropFilter || 'none') !== 'none'; });
    const area = blurred.reduce((a, e) => { const r = e.getBoundingClientRect(); return a + r.width * r.height; }, 0);
    const moving = blurred.filter((e) => { const st = getComputedStyle(e); return st.animationName !== 'none' || /transform|all/.test(st.transitionProperty) && parseFloat(st.transitionDuration) > 0; });
    return { count: blurred.length, share: Math.round(1000 * area / (innerWidth * innerHeight)) / 10, moving: moving.map((e) => e.id || e.className),
      ink: getComputedStyle(document.querySelector('#macBtn')).color, page: getComputedStyle(document.querySelector('#screen')).backgroundColor }; })()`);
  for (const [phone, [w, h]] of Object.entries(PHONES)) {
    for (const orientation of ['portrait', 'landscape']) {
      const page = await openPage(...(orientation === 'portrait' ? [w, h] : [h, w]));
      const views = () => page.evaluate(`window.__sent.filter((m) => m.t === 'view').length`);
      const size = () => page.evaluate(`(() => { const r = document.querySelector('#screen').getBoundingClientRect(); return [r.width, r.height].join('×'); })()`);
      // The page asks once more when it has measured its frame rate: counted from when the requests have come to rest.
      for (let last = -1, same = 0; same < 4;) { const now = await views(); same = now === last ? same + 1 : 0; last = now; await sleep(150); }
      const before = { views: await views(), size: await size(), inset: await page.evaluate('window.__view.inset') };
      for (const opener of ['[data-act=apps]', '[data-act=deck]']) { await page.tap(opener); await sleep(400); await closeSheet(page); }
      await openSettings(page); await closeSheet(page);
      for (const opener of ['#macBtn', '#readout']) { await page.tap(opener); await sleep(350); await page.tap(opener); await sleep(250); }
      out[`${phone} ${orientation}`] = { inset: before.inset, steady: (await views()) === before.views && (await size()) === before.size,
        glass: await glassy(page), whole: before.size === `${orientation === 'portrait' ? w : h}×${orientation === 'portrait' ? h : w}` };
      await page.close();
    }
  }
  // Each sheet is gone in under 200 ms after its close key.
  let page = await openPage(...PHONES.small);
  out.gone = {};
  for (const [name, opener] of [['apps', '[data-act=apps]'], ['deck', '[data-act=deck]'], ['prefs', null]]) {
    if (opener) await page.tap(opener); else await openSettings(page);
    await sleep(450);
    await page.tap(`${SHEET_OF[name]} [data-act=close]`);
    await sleep(200);
    out.gone[name] = await page.evaluate(`getComputedStyle(document.querySelector('${SHEET_OF[name]}')).visibility`);
  }
  // Solid surfaces: the setting, kept.
  await openSettings(page);
  await tapSetting(page, 'glass'); await sleep(150);
  await closeSheet(page);
  out.solid = { ...(await glassy(page)), stored: await page.evaluate(`localStorage.getItem('remotey-glass')`) };
  // What the Mac says about itself.
  const say = (m) => page.evaluate(`window.__socket.onmessage({ data: ${JSON.stringify(JSON.stringify(m))} })`);
  const state = () => page.evaluate(`({ link: document.body.dataset.link, mac: document.querySelector('#macBtn').dataset.state, words: document.querySelector('#macName').textContent,
    notice: document.querySelector('#notice').hidden ? null : document.querySelector('#notice').dataset.kind, button: !document.querySelector('#noticeAct').hidden })`);
  await say({ t: 'mac', ax: true, screen: true, paused: true }); await sleep(100);
  out.paused = await state();
  await say({ t: 'mac', ax: false, screen: true, paused: false }); await sleep(100);
  out.noAccess = await state();
  await say({ t: 'mac', ax: true, screen: false, paused: false }); await sleep(100);
  out.noScreen = await state();
  await page.clear();
  await say({ t: 'mac', ax: true, screen: true, paused: false }); await sleep(200);
  out.granted = { ...(await state()), asked: (await page.sent()).filter((m) => m.t === 'view').map((m) => m.on) };
  await page.close();
  // The phone's own wishes: reduced transparency and more contrast take the blur away; light is light.
  page = await openPage(...PHONES.small, { transparency: 'reduce' });
  out.reduced = await glassy(page);
  await page.close();
  page = await openPage(...PHONES.small, { contrast: 'more' });
  out.contrast = await glassy(page);
  await page.close();
  page = await openPage(...PHONES.small, { scheme: 'light' });
  out.light = await glassy(page);
  await page.close();
  const layouts = Object.entries(out).filter(([k]) => / (portrait|landscape)$/.test(k));
  return { ...out,
    ok: layouts.every(([k, l]) => l.steady && l.whole && l.glass.moving.length === 0 && l.glass.share < 25
        && (k.endsWith('portrait') ? l.inset[0] > 0 && l.inset[2] > 0 && !l.inset[1] && !l.inset[3] : l.inset[1] > 0 && l.inset[3] > 0 && !l.inset[0] && !l.inset[2]))
      && Object.values(out.gone).every((v) => v === 'hidden')
      && out.solid.count === 0 && out.solid.stored === 'false' && out.reduced.count === 0 && out.contrast.count === 0
      && out.light.ink !== layouts[0][1].glass.ink && out.light.page === 'rgb(0, 0, 0)'
      && out.paused.link === 'paused' && out.paused.mac === 'held' && out.paused.notice === 'paused' && !out.paused.button && out.paused.words === 'Pausiert'
      && out.noAccess.link === 'noAccess' && out.noAccess.notice === 'noAccess'
      && out.noScreen.link === 'connected' && out.noScreen.notice === 'permission'
      && out.granted.notice === null && out.granted.asked.at(-1) === true };
});

// T21: the gesture tour. On a phone that never saw it, it starts by itself; each step is done when its gesture is
// recognised on the real pad (the gestures still reach the Mac); it can be skipped, and started again from the settings.
await task('T21', async () => {
  const page = await openPage(390, 844, { tour: true });
  const r = await page.rect('#screen');
  const cx = r.x + r.w / 2, cy = r.y + r.h / 2;
  const step = () => page.evaluate(`({ shown: !document.querySelector('#tour').hidden, count: document.querySelector('#tourCount').textContent,
    title: document.querySelector('#tourTitle').textContent, done: document.querySelector('#tour').dataset.done !== undefined })`);
  const steps = [await step()];
  await page.gesture({ steps: 12, at: (i) => [[cx - 60 + i * 6, cy]] });
  steps.push(await step());
  await page.touch('touchStart', [[cx, cy]]); await sleep(40); await page.touch('touchEnd', []); await sleep(100);
  steps.push(await step());
  await page.gesture({ steps: 15, at: (i) => [[cx - 25, cy + i * 5], [cx + 25, cy + i * 5]] });
  steps.push(await step());
  await page.touch('touchStart', [[cx - 25, cy], [cx + 25, cy]]); await sleep(40); await page.touch('touchEnd', []); await sleep(100);
  steps.push(await step());
  await page.gesture({ steps: 12, at: (i) => [[cx - 40 + i * 5, cy], [cx + i * 5, cy], [cx + 40 + i * 5, cy]] });
  steps.push(await step());
  await page.shot('tour');
  await page.gesture({ steps: 20, at: (i) => [[cx - 30 - i * 4, cy], [cx + 30 + i * 4, cy]] });
  steps.push(await step());
  const sent = await page.sent();
  await sleep(2500);
  const after = { ...(await step()), stored: await page.evaluate(`localStorage.getItem('remotey-toured')`) };
  // From the settings, and skipped: it ends, and the tap on "Überspringen" clicks nothing on the Mac.
  await openSettings(page);
  await tapSetting(page, 'tour'); await sleep(200);
  const again = await step();
  await page.clear();
  await page.tap('[data-act=tour-skip]'); await sleep(200);
  const skipped = { ...(await step()), clicks: count(await page.sent(), 'c') };
  await page.close();
  // A phone that saw it once does not get it again; without the live view there is nothing to zoom: five steps.
  const later = await openPage(390, 844);
  const quiet = (await later.evaluate(`document.querySelector('#tour').hidden`));
  await later.close();
  const off = await openPage(390, 844, { tour: true });
  await off.evaluate(`document.querySelector('#macMenu [data-act=view]').click()`); await sleep(100);
  await openSettings(off);
  await tapSetting(off, 'tour'); await sleep(200);
  const five = await off.evaluate(`document.querySelector('#tourCount').textContent`);
  await off.close();
  const titles = steps.map((s) => s.title);
  return { titles, after, again, skipped, quiet, five, clicks: count(sent, 'c'), drags: sent.filter((m) => m.t === 'b').length,
    ok: steps[0].shown && steps[0].count === 'Schritt 1 von 6'
      && titles.join('|') === 'Mit einem Finger bewegen|Tippen zum Klicken|Mit zwei Fingern scrollen|Mit zwei Fingern tippen für Rechtsklick|Mit drei Fingern ziehen|Zwei Finger spreizen zum Zoomen|Geschafft'
      && steps[6].done && !after.shown && after.stored === 'true' && count(sent, 'c') === 2
      && again.shown && again.count === 'Schritt 1 von 6' && !skipped.shown && skipped.clicks === 0 && quiet && five === 'Schritt 1 von 5' };
});

// T22: sideways, the controls stand in the side margins: mouse keys on one side, tools on the other, swapped by a
// setting. The picture's free part is what lies between them, and the Mac is told so again after a swap.
await task('T22', async () => {
  const out = {};
  for (const [phone, [w, h]] of Object.entries(PHONES)) {
    const page = await openPage(h, w);
    const sides = () => page.evaluate(`(() => { const box = (s) => document.querySelector(s).getBoundingClientRect();
      const click = box('[data-hold=left]'), tools = box('[data-act=apps]'), zoom = box('#zoom');
      const outside = [...document.querySelectorAll('#zoneMouse > *, #zoneTools > *')].filter((e) => e.getBoundingClientRect().height > 0)
        .filter((e) => { const r = e.getBoundingClientRect(); return !(r.top >= -0.5 && r.bottom <= innerHeight + 0.5 && r.left >= -0.5 && r.right <= innerWidth + 0.5); })
        .map((e) => (e.id || e.className) + ' ' + Math.round(e.getBoundingClientRect().left)), inside = !outside.length;
      return { mouse: click.left < innerWidth / 2 ? 'left' : 'right', tools: tools.left < innerWidth / 2 ? 'left' : 'right', zoom: zoom.left < innerWidth / 2 ? 'left' : 'right',
        inside, outside, inset: window.__view.inset, clickH: Math.round(click.height) }; })()`);
    const before = await sides();
    await openSettings(page);
    await tapSetting(page, 'swap'); await sleep(200);
    await closeSheet(page);
    const swapped = { ...(await sides()), stored: await page.evaluate(`localStorage.getItem('remotey-swap')`) };
    await page.shot(`sideways-swapped-${phone}`);
    out[phone] = { before, swapped };
    await page.close();
  }
  return { ...out,
    ok: Object.values(out).every(({ before, swapped }) => before.mouse === 'left' && before.tools === 'right' && before.zoom === 'right' && before.inside
      && swapped.mouse === 'right' && swapped.tools === 'left' && swapped.inside && swapped.stored === 'true' && before.clickH >= 56
      && swapped.inset.join() === before.inset.join()) };
});

// The gallery (--gallery=DIR): every screen at 393 × 852, dark and light, and the main view on every phone, upright and
// sideways, in German and English. The picture is a made-up Mac desktop. Not a check: pictures to look at.
const DISPLAYS_TWO = [DISPLAYS[0], { ...DISPLAYS[1], name: 'Studio Display' }];
async function picture(page, kind = 'window', zoom = 0.5, flags = 2) {
  await page.evaluate('window.__icons = true');
  if (!(await page.evaluate(`window.__sent.some((m) => m.t === 'view' && m.codec === 'jpeg')`))) {
    await page.evaluate(`window.__picture(800)`); // the first JPEG only switches the page from H.264 to JPEG
    await sleep(250);
  }
  const w = (await page.rect('#screen')).w;
  await page.evaluate(`window.__scene(${JSON.stringify(kind)}, ${w / zoom}, ${flags})`);
}
if (gallery) await task('gallery', async () => {
  const say = (page, m) => page.evaluate(`window.__socket.onmessage({ data: ${JSON.stringify(JSON.stringify(m))} })`);
  const made = [];
  const keep = async (page, name) => { await sleep(380); await page.keep(name); made.push(name); };
  for (const scheme of ['dark', 'light']) {
    const open = async (options = {}) => openPage(393, 852, { scheme, ...options });
    // 1 · the main view, fitted to the phone, with the window in front.
    let page = await open();
    await toggleShape(page);
    await picture(page, 'desktop');
    await keep(page, `main-${scheme}`);
    // The Mac's menu and the view's menu.
    await page.tap('#macBtn'); await keep(page, `mac-menu-${scheme}`);
    await page.tap('#macBtn'); await sleep(200);
    await page.evaluate(`window.__displays = ${JSON.stringify(DISPLAYS_TWO)}`);
    await page.tap('#readout'); await keep(page, `view-menu-${scheme}`);
    await page.tap('#readout'); await sleep(200);
    // 3 · writing: the special keys above the keyboard, the view following the text.
    await page.tap('[data-act=type]');
    await page.evaluate(`(window.__kb = true, __vv.set({ height: ${852 - 336} }))`); await sleep(300);
    await page.tap('#accessory [data-mod=cmd]');
    await page.evaluate(`(() => { const f = document.querySelector('#field'); f.value = '​Angebot geht heute raus'; })()`);
    await picture(page, 'window', 0.5, 3);
    await keep(page, `typing-${scheme}`);
    await page.tap('[data-act=done]');
    await page.evaluate(`(window.__kb = false, __vv.reset())`); await sleep(300);
    await page.tap('#accessory [data-mod=cmd]');
    await picture(page, 'desktop');
    // 4 · apps, 4b · the windows of one app.
    await page.tap('[data-act=apps]'); await keep(page, `apps-${scheme}`);
    await page.tap('[data-pid="501"]'); await keep(page, `windows-${scheme}`);
    await page.tap('[data-act=apps-back]'); await sleep(200);
    await page.tap('[data-act=close]'); await sleep(300);
    // 5 and 6 · the controls: media and keys.
    await page.tap('[data-act=deck]');
    await page.tap('[data-act=page][data-page=media]'); await keep(page, `tray-media-${scheme}`);
    await page.tap('[data-act=page][data-page=keys]'); await page.tap('.keys [data-mod=cmd]'); await keep(page, `tray-keys-${scheme}`);
    await page.tap('.keys [data-mod=cmd]');
    await page.tap('[data-act=page][data-page=media]');
    await page.tap('#drawer [data-act=close]'); await sleep(300);
    // 7 · settings.
    await page.tap('#macBtn'); await page.tap('#macMenu [data-act=settings]'); await keep(page, `tray-settings-${scheme}`);
    await page.tap('#prefs [data-act=close]'); await sleep(300);
    // 8 · locked, with Face ID.
    await say(page, { t: 'lock', on: true, key: { id: 'AA', salt: 'AA', challenge: 'AA' } });
    await picture(page, 'lock');
    await keep(page, `locked-${scheme}`);
    await say(page, { t: 'lock', on: false });
    // The offer to enrol for Face ID.
    await say(page, { t: 'enrol', challenge: 'AA', salt: 'AA', name: 'MacBook Pro' });
    await keep(page, `enrol-${scheme}`);
    await page.tap('[data-act=enrol-later]');
    await page.close();
    // 2 · without the live view: the trackpad, a ring where a click landed.
    page = await open();
    await page.evaluate(`document.querySelector('#macMenu [data-act=view]').click()`);
    await keep(page, `trackpad-${scheme}`);
    await page.touch('touchStart', [[260, 300]]); await sleep(40); await page.touch('touchEnd', []); await sleep(120);
    await page.keep(`trackpad-ring-${scheme}`);
    await page.close();
    // 9 · the first start, and with a wrong code.
    page = await open({ token: false });
    await keep(page, `welcome-${scheme}`);
    await page.evaluate(`(() => { const f = document.querySelector('#code'); f.focus(); f.value = '11111'; f.dispatchEvent(new Event('input')); })()`);
    await keep(page, `welcome-typing-${scheme}`);
    await page.evaluate(`(() => { const f = document.querySelector('#code'); f.value = '111111'; f.dispatchEvent(new Event('input')); })()`);
    await keep(page, `welcome-wrong-${scheme}`);
    await page.close();
    // 9b · the gesture tour, at step 3.
    page = await open({ tour: true });
    await picture(page, 'window');
    const r = await page.rect('#screen');
    await page.gesture({ steps: 12, at: (i) => [[r.x + 120 + i * 6, r.y + 300]] });
    await page.touch('touchStart', [[r.x + 200, r.y + 300]]); await sleep(40); await page.touch('touchEnd', []); await sleep(200);
    await keep(page, `tour-${scheme}`);
    await page.close();
    // 10 · failures.
    for (const [name, script] of [['unreachable', `window.__mac = 'down', window.__probe = null`], ['stopped', `window.__mac = 'down', window.__probe = 502`],
      ['no-access', `window.__mac = 'noax'`], ['denied', `window.__mac = 'deny'`], ['revoked', `window.__mac = 'revoked'`], ['ended', `window.__bye()`]]) {
      page = await open();
      await page.evaluate(`(${script}, window.__socket.onclose?.())`); await sleep(700);
      await keep(page, `${name}-${scheme}`);
      await page.close();
    }
    page = await open();
    await picture(page, 'window');
    await say(page, { t: 'mac', ax: true, screen: true, paused: true });
    await keep(page, `paused-${scheme}`);
    await say(page, { t: 'mac', ax: true, screen: true, paused: false });
    await say(page, { t: 'view', ok: false, why: 'taken' });
    await keep(page, `taken-${scheme}`);
    await page.close();
    // 11 · sideways.
    page = await openPage(852, 393, { scheme });
    await picture(page, 'desktop');
    await keep(page, `main-landscape-${scheme}`);
    await page.tap('[data-act=apps]'); await keep(page, `apps-landscape-${scheme}`);
    await page.close();
  }
  // The main view on every phone, upright and sideways, in both languages.
  for (const lang of ['de-DE', 'en-US']) {
    for (const [phone, [w, h]] of Object.entries(PHONES)) {
      for (const orientation of ['portrait', 'landscape']) {
        const page = await openPage(...(orientation === 'portrait' ? [w, h] : [h, w]), { lang });
        await picture(page, 'desktop');
        await keep(page, `main-${phone}${orientation === 'landscape' ? '-landscape' : ''}-${lang.slice(0, 2)}`);
        await page.close();
      }
    }
  }
  return { made: made.length };
});

if (docs) await task('docs', async () => {
  const save = async (page, name) => { await sleep(400); writeFileSync(join(docs, `${name}.png`), Buffer.from((await page.cdp('Page.captureScreenshot', { format: 'png' })).data, 'base64')); };
  const page = await openPage(390, 844, { lang: 'en-US', dpr: 2 });
  await toggleShape(page);
  await picture(page, 'desktop');
  await save(page, 'remote');
  await page.tap('[data-act=apps]');
  await save(page, 'apps');
  await closeSheet(page);
  await page.tap('[data-act=deck]'); await sleep(300);
  await page.tap('[data-act=page][data-page=keys]');
  await page.tap('.keys [data-mod=cmd]');
  await save(page, 'keys');
  await page.close();
  return { saved: 3 };
});

socket.close();
const exited = new Promise((r) => chrome.once('exit', r));
chrome.kill();
await exited;
server.close();
rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
const json = JSON.stringify({ verifier: VERIFIER_VERSION, web: webDir, results }, null, 2);
if (arg('json')) writeFileSync(arg('json'), json);
console.log(json);
