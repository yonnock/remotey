// Drives the page in headless Chromium with real multi-touch events and records what it would send to the Mac.
// No agent, no network: the page gets a fake WebSocket and a visual viewport whose size the script sets, so
// the keyboard can be "opened". Chromium is not iOS Safari: this checks the page's own logic and layout,
// not WebKit's keyboard, safe areas or gesture handling.
// Usage: node scripts/ui-verify.mjs [--web=Web] [--json=out.json] [--only=T1,T4]
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { createServer } from 'node:http';
import { homedir, tmpdir } from 'node:os';
import { extname, join, resolve } from 'node:path';

// 2: a lifted finger is released with its own touchEnd (Chromium does not release a point left out of a touchMove).
// 3: also a 320 px phone (Display Zoom), and the full view key upright.
// 4: no full view key (the dock leaves the display the height it had); reports the display's share upright too.
// 5: T6 sets the pointer speed on the Regler page and checks the next move; T7 opens and closes the tray.
export const VERIFIER_VERSION = 5;
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const webDir = resolve(arg('web', new URL('../Web', import.meta.url).pathname));
const only = arg('only', '')?.split(',').filter(Boolean);
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
const origin = `http://127.0.0.1:${server.address().port}`;

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

// Runs in the page before its own scripts.
const harness = `(() => {
  const sent = window.__sent = [];
  window.WebSocket = class {
    constructor() { this.readyState = 0; setTimeout(() => { this.readyState = 1; this.onopen?.(); }, 0); }
    send(data) {
      const m = JSON.parse(data);
      sent.push({ ...m, at: performance.now() });
      if (m.t === 'auth') setTimeout(() => this.onmessage?.({ data: JSON.stringify({ t: 'ok', ax: true, page: 'test' }) }), 0);
    }
    close() { this.readyState = 3; }
  };
  const vv = new EventTarget();
  Object.assign(vv, { width: innerWidth, height: innerHeight, offsetTop: 0, offsetLeft: 0, pageTop: 0, pageLeft: 0, scale: 1 });
  window.__vv = { set(next) { Object.assign(vv, next); vv.dispatchEvent(new Event('resize')); vv.dispatchEvent(new Event('scroll')); },
    reset() { this.set({ width: innerWidth, height: innerHeight, offsetTop: 0 }); } };
  Object.defineProperty(window, 'visualViewport', { value: vv, configurable: true });
  addEventListener('resize', () => { if (!window.__kb) Object.assign(vv, { width: innerWidth, height: innerHeight }); });
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
    evaluate, touch,
    close: () => cdp('Target.closeTarget', { targetId }),
    resize: async (w, h) => { await s('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 3, mobile: true }); await sleep(250); },
    sent: () => evaluate('window.__sent'),
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
  'Links (Drag)': '[data-hold=left]', 'Rechts': '[data-click=right]', 'Bild': '[data-act=view]',
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
  // Back to 1x with the manual control.
  await page.clear();
  let taps = 0;
  for (const selector of ['[data-act=zoom-reset]', '#zoom']) {
    const target = await page.rect(selector);
    if (!target?.shown) continue;
    if (selector === '#zoom') { // baseline: the "1" detent is the middle of five
      const p = target.w > target.h ? [target.x + target.w / 2, target.y + target.h / 2] : [target.x + target.w / 2, target.y + target.h / 2];
      await page.touch('touchStart', [p]); await sleep(40); await page.touch('touchEnd', []);
    } else await page.tap(selector);
    taps++;
    await sleep(200);
    break;
  }
  const after = (await page.sent()).filter((m) => m.t === 'view').at(-1)?.zoom;
  await page.close();
  return { pinch, reset: { taps, zoom: after ?? null, ok: after === 1 } };
});

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

socket.close();
const exited = new Promise((r) => chrome.once('exit', r));
chrome.kill();
await exited;
server.close();
rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
const json = JSON.stringify({ verifier: VERIFIER_VERSION, web: webDir, results }, null, 2);
if (arg('json')) writeFileSync(arg('json'), json);
console.log(json);
