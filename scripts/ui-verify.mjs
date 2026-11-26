// Drives the page in headless Chromium with real multi-touch events and records what it would send to the Mac.
// No agent, no network: the page gets a fake WebSocket and a visual viewport whose size the script sets, so
// the keyboard can be "opened". Chromium is not iOS Safari: this checks the page's own logic and layout,
// not WebKit's keyboard, safe areas or gesture handling.
// Usage: node scripts/ui-verify.mjs [--web=Web] [--json=out.json] [--only=T1,T9] [--shots=DIR]
// --shots saves pictures of the page at moments T8, T10, T11, T12, T13 and T14 name, for looking at what they measure.
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
export const VERIFIER_VERSION = 16;
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const webDir = resolve(arg('web', new URL('../Web', import.meta.url).pathname));
const only = arg('only', '')?.split(',').filter(Boolean);
const shots = arg('shots', '');
if (shots) mkdirSync(shots, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function chromePath() {
  const root = join(homedir(), 'Library/Caches/ms-playwright');
  const dir = existsSync(root) && readdirSync(root).filter((d) => d.startsWith('chromium_headless_shell')).sort().at(-1);
  if (!dir) throw new Error('no chrome-headless-shell in ~/Library/Caches/ms-playwright');
  return join(root, dir, readdirSync(join(root, dir)).find((d) => d.startsWith('chrome-headless-shell')), 'chrome-headless-shell');
}

const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' };
const server = createServer((req, res) => {
  const name = req.url.split('?')[0] === '/' ? 'index.html' : req.url.split('?')[0].slice(1);
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
};
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
  window.WebSocket = class {
    constructor() { window.__socket = this; this.readyState = 0; setTimeout(() => { this.readyState = 1; this.onopen?.(); }, 0); }
    send(data) {
      const m = JSON.parse(data);
      sent.push({ ...m, at: performance.now() });
      if (m.t === 'view') window.__view = m; // outlives a task's clearing of the list
      if (m.t === 'auth') setTimeout(() => this.onmessage?.({ data: JSON.stringify({ t: 'ok', ax: true, page: 'test' }) }), 0);
      if (m.t === 'apps') setTimeout(() => {
        this.onmessage?.({ data: JSON.stringify({ t: 'apps', list: ${JSON.stringify(APPS)} }) });
        this.onmessage?.({ data: JSON.stringify({ t: 'icon', id: 'safari', png: '${ICON}' }) });
      }, window.__appsDelay ?? 0); // T9 makes the Mac slow to answer
      // One display unless a task plugs in more: then the picker shows.
      if (m.t === 'displays') setTimeout(() => this.onmessage?.({ data: JSON.stringify({ t: 'displays', list: window.__displays ?? [${JSON.stringify(DISPLAYS[0])}] }) }),
        window.__appsDelay ?? 0);
    }
    close() { this.readyState = 3; }
  };
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
    const canvas = Object.assign(document.createElement('canvas'), { width: 64, height: Math.max(2, Math.round(64 * request.h / request.w)) });
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
  try { localStorage.clear(); localStorage.setItem('remotey-view', '1'); localStorage.setItem('remotey-zoom', '0.5'); } catch {}
})();`;

async function openPage(width, height) {
  const { targetId } = await cdp('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp('Target.attachToTarget', { targetId, flatten: true });
  const s = (method, params) => cdp(method, params, sessionId);
  await s('Page.enable');
  await s('Runtime.enable');
  await s('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 3, mobile: true });
  await s('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
  await s('Page.addScriptToEvaluateOnNewDocument', { source: harness });
  await s('Page.navigate', { url: `${origin}/#test-token` });
  await sleep(600);
  const evaluate = async (expression) => {
    const { result, exceptionDetails } = await s('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
    return result.value;
  };
  const touch = (type, points) => s('Input.dispatchTouchEvent', { type, touchPoints: points.map(([x, y], id) => ({ x, y, id })) });
  const page = {
    evaluate, touch, cdp: s,
    close: () => cdp('Target.closeTarget', { targetId }),
    resize: async (w, h) => { await s('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 3, mobile: true }); await sleep(250); },
    sent: () => evaluate('window.__sent'),
    /** With --shots: a picture of the page as it is now. */
    shot: async (name) => { if (shots) writeFileSync(join(shots, `${name}.png`), Buffer.from((await s('Page.captureScreenshot', { format: 'png' })).data, 'base64')); },
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
  'Links (Drag)': '[data-hold=left]', 'Rechts': '[data-click=right]', 'Zurück': '[data-click=back]',
  'Vorwärts': '[data-click=forward]', 'Bild': '[data-act=view]', 'Apps': '[data-act=apps]',
  'Zoom': '#zoom, [data-act=zoom-in]', 'Tastatur': '#field, [data-act=type]', 'Play': '[data-media=play]',
  'Lauter': '[data-media=volup]', 'Esc': '[data-key=escape]', 'Einstellungen': '[data-setting], [data-page=settings]',
};
// Some controls sit behind a page switch or drawer; this opens it the way a user would and counts the taps.
async function reach(page, name, selector, visible) {
  let direct = await reachable(page, selector, visible), taps = 1;
  if (direct.ok) return { ...direct, taps };
  for (const opener of ['[data-act=deck]', `[data-act=page][data-page=${['Play', 'Lauter'].includes(name) ? 'media' : name === 'Esc' ? 'keys' : 'settings'}]`]) {
    if (!(await page.tap(opener))) continue;
    taps++;
    await sleep(350);
    direct = await reachable(page, selector, visible);
    if (direct.ok) return { ...direct, taps };
  }
  return { ...direct, state: await page.evaluate(`document.body.className + ' page=' + document.body.dataset.page`) };
}

const screenArea = (page) => page.evaluate(`(() => { const r = document.querySelector('#screen').getBoundingClientRect();
  return { w: Math.round(r.width), h: Math.round(r.height), share: Math.round(100 * r.width * r.height / (innerWidth * innerHeight)) }; })()`);

const results = {};
const task = async (name, fn) => {
  if (only.length && !only.includes(name)) return;
  try { results[name] = await fn(); } catch (error) { results[name] = { error: String(error.stack || error) }; }
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
        await page.evaluate(`document.querySelector('[data-act=deck].on, body.drawer [data-act=deck]')?.dispatchEvent(new MouseEvent('click'))`);
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
      const screenVisible = screen ? Math.max(0, Math.min(screen.bottom, v.top + v.height) - Math.max(screen.top, v.top)) : 0;
      const overlap = (a, b) => a && b && a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
      return { field: inView(field), done: inView(done), screenVisible: Math.round(screenVisible),
        overlap: overlap(field, screen) || overlap(done, screen), focused: document.activeElement?.id === 'field' };
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
  await page.tap('[data-act=deck]'); await sleep(350);
  await page.tap('[data-act=page][data-page=settings]'); await sleep(250);
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
  await page.evaluate(`document.querySelector('[data-act=deck]').dispatchEvent(new MouseEvent('click'))`);
  await sleep(350);
  const after = await slowMove();
  await page.close();
  return { touches, shown, before, after, ratio: round(after / before), ok: shown === '2×' && Math.abs(after / before - 2) < 0.1 };
});

// T7: the tray. How long it stays in sight after the key closes it, whether it covers the dock on the way,
// and whether a tap on the display or a swipe down puts it away (without a click on the Mac).
await task('T7', async () => {
  const page = await openPage(375, 812);
  const open = async () => { if (!(await page.evaluate(`document.body.classList.contains('drawer')`))) await page.tap('[data-act=deck]'); await sleep(450); };
  const isOpen = () => page.evaluate(`document.body.classList.contains('drawer')`);
  // Every frame: the part of the tray that can be seen, after clipping by its ancestors.
  const record = () => page.evaluate(`(() => {
    const frames = window.__frames = [], tray = document.querySelector('#drawer'), dock = document.querySelector('#dock').getBoundingClientRect();
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
      if (frames.length < 60) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  })()`);
  await open();
  await record();
  await page.tap('[data-act=deck]');
  await sleep(700);
  const frames = (await page.evaluate('window.__frames')).filter((f) => f.at !== null);
  const lastSeen = frames.filter((f) => f.h > 0).at(-1);
  const close = { inSightMs: lastSeen ? Math.round(lastSeen.at) : 0, overDockPx: Math.max(0, ...frames.map((f) => f.overDock)),
    frames: frames.filter((f) => f.h > 0).length };
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
  return { close, tap, swipe };
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
  await page.tap('[data-click=back]');
  await page.tap('[data-click=back]');
  const sent = await page.sent();
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
          belowZoom: sheet.top >= zoom.bottom - 0.5, inSight: tiles.filter((t) => t.bottom <= well.bottom + 0.5).length,
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
    back: !document.querySelector('[data-act=apps-back]').hidden, markup: !!document.querySelector('#apps img[src="x"]') || !!window.__xss }))()`);
  choice.sentBefore = (await focuses()).length;
  await page.tap('[data-act=apps-back]'); await sleep(250);
  const back = await page.evaluate(`document.querySelectorAll('.app').length`);
  await page.tap('[data-pid="501"]'); await sleep(300);
  await page.tap('[data-win="12"]'); await sleep(300);
  const window = { sent: await focuses(), closed: !(await isOpen(page)) };
  // Opened again while the Mac is slow to answer: the list of last time is not offered, since the new one may
  // come in another order under the finger. As many blank places stand in, and a tap on one does nothing.
  await page.evaluate(`window.__appsDelay = 400`);
  await page.tap('[data-act=apps]'); await sleep(150);
  await page.clear();
  const first = await page.rect('.app');
  await page.touch('touchStart', [[first.x + first.w / 2, first.y + first.h / 2]]); await sleep(40); await page.touch('touchEnd', []); await sleep(60);
  const stale = await page.evaluate(`({ places: document.querySelectorAll('.app.ghost').length, tappable: document.querySelectorAll('.app[data-pid]').length,
    sent: window.__sent.filter((m) => m.t === 'focus').length, open: document.body.classList.contains('apps') })`);
  await sleep(500);
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
  await page.evaluate(`(window.__appsDelay = 400, document.dispatchEvent(new Event('visibilitychange')))`);
  await sleep(150); await page.clear();
  const old = await page.rect('#apps');
  await page.touch('touchStart', [[old.x + 50, old.y + 40]]); await sleep(40); await page.touch('touchEnd', []); await sleep(60);
  const resumed = await page.evaluate(`({ tappable: document.querySelectorAll('#apps button').length,
    sent: window.__sent.filter((m) => m.t === 'focus').length, open: document.body.classList.contains('apps') })`);
  await sleep(600);
  resumed.after = await page.evaluate(`document.querySelectorAll('.app[data-pid]').length`);
  await page.evaluate(`window.__appsDelay = 0`);
  // The same swipe started on an icon, while the list does not scroll: the sheet goes, the app is not asked for.
  await open(page); await page.clear();
  const icon = await page.rect('[data-pid="502"]');
  await page.touch('touchStart', [[icon.x + icon.w / 2, icon.y + icon.h / 2]]);
  for (let i = 1; i <= 8; i++) { await sleep(16); await page.touch('touchMove', [[icon.x + icon.w / 2, icon.y + icon.h / 2 + i * 14]]); }
  await page.touch('touchEnd', []); await sleep(300);
  swipe.fromIcon = { closed: !(await isOpen(page)), sent: (await focuses()).length };
  // One sheet at a time, and typing puts the switcher away for good.
  await open(page);
  await page.tap('[data-act=deck]'); await sleep(450);
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
        const page = box('.page.media'), lock = box('[data-act=lock]'), mute = box('[data-media=mute]');
        return { lock: side(lock), mute: side(mute), apart: Math.round(lock.top - mute.bottom),
          inside: [lock, mute].every((k) => k.left >= page.left - 0.5 && k.right <= page.right + 0.5 && k.top >= page.top - 0.5 && k.bottom <= page.bottom + 0.5) };
      })()`);
      if (phone === 'small' && orientation === 'portrait') {
        await page.shot('lock');
        await page.tap('[data-act=page][data-page=keys]'); await sleep(250);
        await page.tap('[data-mod=shift]');
        await page.tap('[data-act=page][data-page=media]'); await sleep(250);
        await page.clear();
        await page.tap('[data-act=lock]');
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
  const lockKeyState = () => page.evaluate(`(() => { const k = document.querySelector('[data-act=lock]'), shown = (s) => getComputedStyle(k.querySelector(s)).display !== 'none';
    return { shut: shown('.shut'), open: shown('.open'), on: k.classList.contains('on'), pressed: k.getAttribute('aria-pressed'), name: k.getAttribute('aria-label') }; })()`);
  lockKey.open = await lockKeyState();
  await say({ t: 'lock', on: true });
  const locked = await state();
  lockKey.locked = await lockKeyState();
  await page.tap('[data-act=deck]'); await sleep(450);
  await page.clear();
  await page.tap('[data-act=lock]'); await sleep(200);
  lockKey.unlocks = { ...(await state()), sent: (await input()).length };
  await page.evaluate(`document.querySelector('#field').blur()`);
  await page.tap('[data-act=deck]'); await sleep(450);
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
      && open.type === 'text' && open.keys && !open.padlock && open.label === 'Tippen…'
      && locked.type === 'password' && locked.autocomplete === 'current-password' && locked.padlock && !locked.keys
      && locked.label === 'Entsperren…' && locked.name === 'Mac entsperren' && locked.value === '' && locked.hint === 'Passwort des Macs'
      && typed.value === 'geheim' && typed.sent.length === 0
      && JSON.stringify(sent.sent) === '[{"t":"unlock","s":"geheim"}]' && sent.value === '' && sent.focused && sent.hint === 'Entsperre…'
      && early.value === 'neu' && early.sent === 1 && refused.failed && refused.hint === 'Nicht entsperrt, nochmal?' && refused.value === 'neu'
      && JSON.stringify(second.sent.at(-1)) === '{"t":"unlock","s":"neu"}' && second.sent.length === 2 && second.value === ''
      && unready.failed && unready.hint === 'Mac nicht bereit, nochmal?' && !retry.failed && retry.hint === 'Passwort des Macs'
      && opened.type === 'text' && !opened.focused && !opened.failed && opened.hint === '' && opened.label === 'Tippen…' && opened.keys
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
  const state = () => page.evaluate(`(() => { const key = document.querySelector('[data-act=fit]'), lamp = key.querySelector('.legend');
    return { readout: document.querySelector('#zoomValue').textContent, on: key.classList.contains('on'), pressed: key.getAttribute('aria-pressed'),
      lamp: getComputedStyle(lamp).color, label: key.getAttribute('aria-label'), preview: document.querySelector('#picture').style.transform,
      stored: localStorage.getItem('remotey-fit'), w: Math.round(key.getBoundingClientRect().width), h: Math.round(key.getBoundingClientRect().height),
      clipped: lamp.scrollWidth > key.clientWidth || document.querySelector('#zoomValue').scrollWidth > key.clientWidth }; })()`);
  const text = (z) => `${String(Math.round(z * 100) / 100).replace('.', ',')}×`;
  const off = await state();
  await page.evaluate(`window.__picture(${r.w / 0.5})`); // the first JPEG only switches the page from H.264 to JPEG
  await sleep(200);
  await page.clear();
  await page.tap('[data-act=fit]');
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
  await page.tap('[data-act=fit]');
  await page.evaluate(`window.__picture(1512, true)`);
  await page.clear();
  await page.touch('touchStart', [[cx - 40, cy], [cx + 40, cy]]); await sleep(16);
  for (let i = 1; i <= 20; i++) { await page.touch('touchMove', [[cx - 40 - i * 2, cy], [cx + 40 + i * 2, cy]]); await sleep(16); }
  const during = await state();
  await page.touch('touchEnd', []); await sleep(200);
  const sent = await page.sent();
  const pinched = { during, ...(await state()), views: await views(), misactions: count(sent, 'm') + count(sent, 's') + count(sent, 'c') };
  // "Auto" with no window in front (the Finder's desktop): the Mac answers at the zoom set by hand.
  await page.tap('[data-act=zoom][data-step="-1"]'); // a known step: 0.35
  await page.tap('[data-act=fit]');
  await page.clear();
  await page.evaluate(`window.__picture(${r.w / 0.35})`);
  const none = { ...(await state()), views: (await views()).length };
  await page.evaluate(`window.__picture(1512, true)`);
  await page.evaluate(`window.__picture(${r.w / 0.35})`);
  const gone = { ...(await state()), views: (await views()).length };
  await page.close();
  const fits = (list) => list.map((m) => `${m.fit ?? '-'} ${m.zoom}`).join();
  const amber = 'rgb(242, 184, 75)';
  return { off, asked, first, second, turned, stepped, pinched, none, gone,
    ok: !off.on && off.pressed === 'false' && off.lamp !== amber && off.readout === '0,5×' && !off.clipped && off.h >= 32
      && asked.on && asked.pressed === 'true' && asked.lamp === amber && asked.stored === 'true' && fits(asked.views) === 'window 0.5'
      && asked.label.includes('Auto an')
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
  const isOpen = (page) => page.evaluate(`document.body.classList.contains('apps')`);
  const open = async (page) => { if (!(await isOpen(page))) await page.tap('[data-act=apps]'); await sleep(450); };
  const tiles = (page) => page.evaluate(`(() => { const box = (e) => e.getBoundingClientRect();
    const map = document.querySelector('#displays'), sheet = box(document.querySelector('#switcher')), well = box(document.querySelector('.well'));
    const list = [...map.querySelectorAll('.display')].map((e) => { const r = box(e); return { id: e.dataset.display, x: r.x, y: r.y, w: r.width, h: r.height,
      here: e.classList.contains('here'), name: e.textContent, label: e.getAttribute('aria-label'), off: e.disabled,
      cut: e.firstElementChild.firstElementChild.getBoundingClientRect().height > e.firstElementChild.clientHeight + 0.5 }; });
    const apps = [...document.querySelectorAll('.app')].map(box);
    return { hidden: map.hidden, list, smallest: list.length ? Math.round(Math.min(...list.map((t) => Math.min(t.w, t.h)))) : 0,
      inside: list.every((t) => t.x >= sheet.left - 0.5 && t.x + t.w <= sheet.right + 0.5 && t.y >= well.bottom - 0.5 && t.y + t.h <= sheet.bottom + 0.5),
      belowZoom: sheet.top >= box(document.querySelector('#zoom')).bottom - 0.5, appsInSight: apps.filter((t) => t.bottom <= well.bottom + 0.5).length }; })()`);
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
        appsInSight: seen.appsInSight, arranged: arranged(seen.list), cut: seen.list.filter((t) => t.cut).map((t) => t.name) };
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
  await page.tap('[data-act=apps]'); await sleep(300);
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
  await page.tap('[data-act=apps]'); await sleep(300);
  await page.evaluate(`window.__appsDelay = 400`);
  await page.tap('[data-act=apps]'); await sleep(150);
  await page.clear();
  const old = (await tiles(page)).list[0];
  await page.touch('touchStart', [[old.x + old.w / 2, old.y + old.h / 2]]); await sleep(40); await page.touch('touchEnd', []); await sleep(60);
  const stale = { off: (await tiles(page)).list.every((t) => t.off), sent: (await page.sent()).filter((m) => m.t === 'display').length, open: await isOpen(page) };
  await sleep(500);
  stale.after = (await tiles(page)).list.filter((t) => !t.off).length;
  await page.close();
  return { ...out, one: { hidden: one.hidden, asked: one.asked, connecting: one.connecting, appsInSight: one.appsInSight }, three, tap, two: { tiles: two.list.length, here: two.list.filter((t) => t.here).map((t) => t.id) }, stale,
    // Sideways the display is short: the map is lower there, so a row of apps stays in sight on the smallest phone.
    ok: Object.entries(out.layout).every(([name, l]) => l.tiles === 3 && l.smallest >= (name.endsWith('portrait') ? 44 : 30) && l.inside && l.belowZoom
        && l.arranged && l.appsInSight >= 5 && l.cut.length === 0)
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
  const isOpen = (page) => page.evaluate(`document.body.classList.contains('apps')`);
  const open = async (page) => { if (!(await isOpen(page))) await page.tap('[data-act=apps]'); await sleep(450); };
  const shut = async (page) => { if (await isOpen(page)) await page.tap('[data-act=apps]'); await sleep(300); };
  for (const [phone, [w, h]] of Object.entries(PHONES)) {
    for (const orientation of ['portrait', 'landscape']) {
      const page = await openPage(...(orientation === 'portrait' ? [w, h] : [h, w]));
      await open(page);
      out.layout[`${phone} ${orientation}`] = await page.evaluate(`(() => { const box = (s) => document.querySelector(s).getBoundingClientRect();
        const key = box('[data-act=shape]'), title = box('#appsTitle'), head = box('.head'), label = document.querySelector('[data-act=shape]');
        return { w: Math.round(key.width), h: Math.round(key.height), inside: key.left >= head.left - 0.5 && key.right <= head.right + 0.5,
          clear: title.right <= key.left + 0.5, whole: (() => { const range = document.createRange(); range.selectNodeContents(label); return range.getBoundingClientRect().width <= key.width - 8; })(), title: document.querySelector('#appsTitle').scrollWidth <= document.querySelector('#appsTitle').clientWidth }; })()`);
      await page.close();
    }
  }
  const page = await openPage(390, 844);
  const r = await page.rect('#screen');
  const cx = r.x + r.w / 2, cy = r.y + r.h / 2;
  const views = async () => (await page.sent()).filter((m) => m.t === 'view').map(({ at, v, ...m }) => m);
  const asked = (list) => list.map((m) => (m.on ? `${m.fit ?? '-'} ${m.shape ?? '-'}` : 'off')).join();
  const state = () => page.evaluate(`(() => { const key = document.querySelector('[data-act=shape]'), lamp = document.querySelector('#fitLamp');
    return { readout: document.querySelector('#zoomValue').textContent, lamp: lamp.textContent, lit: document.querySelector('[data-act=fit]').classList.contains('on'),
      latch: key.classList.contains('on'), pressed: key.getAttribute('aria-pressed'), shown: getComputedStyle(key).display !== 'none',
      stored: [localStorage.getItem('remotey-shape'), localStorage.getItem('remotey-fit')].join(), open: document.body.classList.contains('apps'),
      clipped: lamp.scrollWidth > lamp.parentElement.clientWidth }; })()`);
  const text = (z) => `${String(Math.round(z * 100) / 100).replace('.', ',')}×`;
  await page.evaluate(`window.__picture(${r.w / 0.5})`); // the first JPEG only switches the page from H.264 to JPEG
  await sleep(200);
  await open(page);
  const before = await state();
  await page.clear();
  await page.tap('[data-act=shape]');
  const on = { ...(await state()), views: await views() };
  await page.shot('form-sheet');
  // The windows of one app: the latch makes way for their number.
  await page.tap('[data-pid="501"]'); await sleep(300);
  const listed = await state();
  await shut(page);
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
  await page.tap('[data-act=fit]');
  const off = { ...(await state()), views: await views() };
  await page.clear();
  await page.tap('[data-act=fit]');
  const again = { ...(await state()), views: await views() };
  // Out of sight: the page switches the view off, whatever iOS does with the socket.
  await page.clear();
  await page.evaluate(`(Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true }), document.dispatchEvent(new Event('visibilitychange')))`);
  await sleep(100);
  const hidden = await views();
  await page.evaluate(`(Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true }), document.dispatchEvent(new Event('visibilitychange')))`);
  await sleep(400);
  const back = await views();
  // The latch off: plain "Auto", the windows on the Mac as they are.
  await open(page);
  await page.clear();
  await page.tap('[data-act=shape]');
  const plain = { ...(await state()), views: await views() };
  await page.close();
  return { ...out, before, on, listed, shaped, stepped, held, pinched, turned, off, again, hidden: asked(hidden), back: asked(back), plain,
    ok: Object.values(out.layout).every((l) => l.h >= 36 && l.w >= 44 && l.inside && l.clear && l.whole && l.title)
      && !before.latch && before.pressed === 'false' && before.shown && before.lamp === 'Auto'
      && on.latch && on.pressed === 'true' && on.stored === 'true,true' && on.open && asked(on.views) === 'window 0.5'
      && !listed.shown
      && shaped.readout === '0,5×' && shaped.lamp === 'Form' && shaped.lit && !shaped.clipped && shaped.views === 0
      && asked(stepped.views) === 'window 0.7' && stepped.lit && stepped.lamp === 'Form'
      && held.readout === '0,6×' && held.views.length === 0
      && pinched.misactions === 0 && pinched.views.length === 1 && pinched.views[0].fit === 'window' && Math.abs(pinched.views[0].shape - 1.2) < 0.01 && pinched.lit
      && turned.views.length >= 1 && turned.views.every((m) => m.fit === 'window' && m.shape === 0.5)
      && asked(off.views) === '- -' && !off.lit && off.lamp === 'Auto' && off.latch && off.stored === 'true,false'
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
  await page.tap('[data-act=lock]'); await sleep(300);
  const byLockKey = { ...(await state()), unlocks: await sent('unlock') };
  await page.shot('locked');
  await say({ t: 'lock', on: false });
  const open = await state();
  await page.close();
  const answers = [first, second, third].map((t) => t.unlocks[0]);
  return { before, layout, offered, later, failed, taking, done, gone, enrol, first, refused, field, second, unready, third, declined, after, byLockKey, open,
    vector: { origin, offer, challenge: challenges[0] },
    ok: before.hidden && Object.values(layout).every((l) => !l.hidden && l.inside && l.whole && l.keyH >= 44)
      && !offered.hidden && offered.state === 'offer' && offered.title === 'Entsperren mit Face ID' && offered.text.includes('„Test-Mac“') && offered.key === 'Einrichten'
      && later.hidden && failed.state === 'failed' && failed.key === 'Nochmal' && failed.sent === 0 && !failed.hidden
      && !!enrol && checked(enrol, 'webauthn.create', offer.challenge) && raw(enrol.prf).length === 32 && raw(enrol.key).length === 91
      && taking.state === 'busy' && taking.key === 'Richte ein…' && !done.hidden && done.state === 'done' && done.title === 'Eingerichtet' && gone.hidden
      && byLockKey.unlocks.length === 1 && checked(byLockKey.unlocks[0], 'webauthn.get', challenges[3], enrol.key) && !byLockKey.focused
      && first.unlocks.length === 1 && first.label === 'Entsperre…' && !first.focused
      && answers.every((a, i) => a && !('s' in a) && a.prf === enrol.prf && checked(a, 'webauthn.get', challenges[i], enrol.key))
      && refused.label === 'Abgelehnt' && !refused.focused
      && field.focused && field.type === 'password' && field.label === 'Entsperren…' && field.unlocks.length === 0
      && second.unlocks.length === 1 && !second.focused
      && unready.label === 'Nicht bereit' && third.unlocks.length === 1 && !third.focused
      && declined.unlocks.length === 0 && declined.label === 'Entsperren…' && !declined.focused
      && after.focused && after.unlocks.length === 0
      && open.label === 'Tippen…' && open.type === 'text' };
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
  await page.tap('[data-act=apps]'); await sleep(450);
  await page.tap('[data-act=shape]'); await sleep(150);
  await page.tap('[data-act=apps]'); await sleep(300);
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

socket.close();
const exited = new Promise((r) => chrome.once('exit', r));
chrome.kill();
await exited;
server.close();
rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
const json = JSON.stringify({ verifier: VERIFIER_VERSION, web: webDir, results }, null, 2);
if (arg('json')) writeFileSync(arg('json'), json);
console.log(json);
