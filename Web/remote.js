// The page: connection, controls, keys and settings, wired to the touchpad, the viewport, the live view, the
// switcher and the display picker.
import { Switcher, readApps } from './apps.js';
import { Picker, readDisplays } from './displays.js';
import { Cadence, LiveView, Meter } from './live-view.js';
import { SETTINGS, Touchpad, detents, settingAt, settingFraction, settingText, stepSetting } from './touchpad.js';
import { relay } from './typing.js';
import { follow } from './viewport.js';

const $ = (s) => document.querySelector(s);
const body = document.body, root = document.documentElement;
const statusEl = $('#status'), pad = $('#pad'), field = $('#field'), screenEl = $('#screen'), view = $('#view');

// ---- Stored on the phone. Every value is checked on the way in: an older page may have left another shape.
const store = {
  get(key, valid, fallback) {
    try { const value = JSON.parse(localStorage.getItem(`remotey-${key}`)); return valid(value) ? value : fallback; } catch { return fallback; }
  },
  set(key, value) { try { localStorage.setItem(`remotey-${key}`, JSON.stringify(value)); } catch {} },
};

// ---- Token: arrives in the URL fragment (never sent to the server). The fragment stays in the URL
// so "Zum Home-Bildschirm" keeps it; localStorage is the fallback for plain Safari tabs.
let token = decodeURIComponent(location.hash.slice(1));
try {
  if (token) localStorage.setItem('remotey-token', token);
  else token = localStorage.getItem('remotey-token') || '';
} catch {}

// ---- Connection
let ws = null, liveView = null, ready = false, denied = false, retryTimer = 0;
let served = null; // names the page the agent served when this one first connected
// The LED carries the state; the text is for screen readers. state: '' (connecting), 'ok' or 'bad'.
function setStatus(text, state = '') { statusEl.className = state; statusEl.firstElementChild.textContent = text; }

function connect() {
  clearTimeout(retryTimer);
  if (!token) { pad.textContent = 'Kein Zugangsschlüssel. Am Mac im Remotey-Menü „iPhone koppeln“ wählen und den QR-Code scannen.'; return setStatus('Nicht gekoppelt', 'bad'); }
  if (denied) return;
  setStatus('Verbinde…');
  liveView?.close();
  if (ws) { ws.onclose = null; ws.close(); }
  ready = false;
  if (sheet === 'apps') askApps(); // the list on show is the old Mac's until the new connection answers
  // Behind `tailscale serve` the socket has its own path; locally the agent listens on the port after the page's.
  const url = location.protocol === 'https:' ? `wss://${location.host}/ws` : `ws://${location.hostname}:${(Number(location.port) || 80) + 1}/ws`;
  const socket = ws = new WebSocket(url);
  socket.binaryType = 'arraybuffer';
  const player = liveView = new LiveView(view, { picture: $('#picture'), aim: $('#aim'), cursor: $('#cursor') }, {
    shown: (n) => { if (socket === ws && socket.readyState === 1) socket.send(JSON.stringify({ t: 'shown', n })); },
    placed: (update, picture) => placed(update, picture),
    fallback: () => { if (socket === ws) syncView(); },
  });
  socket.onopen = () => socket.send(JSON.stringify({ t: 'auth', token }));
  socket.onmessage = (e) => {
    if (socket !== ws) return;
    if (typeof e.data !== 'string') { player.receive(e.data); return; }
    const m = JSON.parse(e.data);
    if (m.t === 'ok') {
      // The agent was updated while this page stayed open: load the page it serves now.
      if (served !== null && m.page !== served) return location.reload();
      served = m.page;
      ready = true;
      pad.textContent = m.ax ? '' : 'Am Mac fehlt die Bedienungshilfen-Freigabe für Remotey (Systemeinstellungen, Datenschutz & Sicherheit).';
      setStatus(m.ax ? 'Verbunden' : 'Freigabe fehlt', m.ax ? 'ok' : 'bad');
      sentView = '';
      fitted = 0;
      syncView();
      if (viewOn) cadence.measure(); // low power mode may have changed it while the page was away
      if (sheet === 'apps') askApps(); // the Mac is back while the switcher is open
    } else if (m.t === 'lock') {
      setLocked(m.on === true);
    } else if (m.t === 'unlock' && m.ok === false) {
      unlockFailed(m.why);
    } else if (m.t === 'cursor') {
      player.setCursor(m);
    } else if (m.t === 'view' && m.ok === false) {
      setView(false);
      pad.textContent = 'Am Mac fehlt die Freigabe „Bildschirmaufnahme“ für Remotey. Dort erlauben, Remotey neu starten, dann „Bild“ erneut antippen.';
    } else if (m.t === 'apps') {
      const list = readApps(m);
      if (list) switcher.update(list);
    } else if (m.t === 'icon') {
      switcher.picture(m.id, m.png);
    } else if (m.t === 'displays') {
      const list = readDisplays(m);
      if (list) picker.update(list);
    } else if (m.t === 'denied') {
      denied = true;
      pad.textContent = 'Zugangsschlüssel ungültig. Am Mac neu koppeln und den QR-Code scannen.';
      setStatus('Abgelehnt', 'bad');
    }
  };
  socket.onclose = () => {
    if (socket !== ws) return;
    ready = false;
    unlocking = false; // the answer to a password went with the connection
    player.close();
    if (denied) return;
    setStatus('Getrennt', 'bad');
    pad.textContent = 'Keine Verbindung zum Mac.';
    if (sheet === 'apps') askApps();
    if (document.visibilityState === 'visible') retryTimer = setTimeout(connect, 1000);
  };
}
// Nothing is queued: what cannot leave now is dropped, so nothing arrives late after a reconnect.
function send(msg) { if (ready && ws.readyState === 1) ws.send(JSON.stringify(msg)); }

// iOS suspends sockets in the background without closing them, so reconnect on every return.
let wakeLock = null;
async function keepAwake() {
  try { if (!wakeLock || wakeLock.released) wakeLock = await navigator.wakeLock.request('screen'); } catch {}
}
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') { connect(); keepAwake(); }
});

// ---- Sticky modifiers (apply to the next key or click, then release)
const mods = new Set();
function takeMods() {
  const list = [...mods];
  mods.clear();
  showMods();
  return list;
}
// A modifier has a key on the deck and one above the keyboard; both show whether it is armed.
function showMods() { document.querySelectorAll('[data-mod]').forEach((b) => b.classList.toggle('on', mods.has(b.dataset.mod))); }
// `held` is a modifier the key itself brings along, as the keys for an app's zoom do.
function sendKey(k, held) { send({ t: 'key', k, mods: [...new Set([...(held ? [held] : []), ...takeMods()])], n: 1 }); }
function sendClick(b) { send({ t: 'c', b, mods: takeMods() }); }

// ---- Settings: pointer speed, acceleration and scroll speed, independent of each other. Each is a slider
// that takes the finger anywhere along its track and snaps to the detents; the touchpad reads the values
// at every move, so a change counts from the next one.
const settings = Object.fromEntries(Object.entries(SETTINGS).map(([name, { initial }]) =>
  [name, store.get(`setting-${name}`, (v) => detents(name).includes(v), initial)]));
const decimal = (n) => String(n).replace('.', ',');
function showSettings() {
  for (const el of document.querySelectorAll('[data-setting]')) {
    const name = el.dataset.setting, value = settings[name], text = settingText(name, value);
    el.querySelector('output').textContent = text;
    el.style.setProperty('--at', settingFraction(name, value));
    const slider = el.querySelector('[role=slider]');
    slider.setAttribute('aria-valuenow', value);
    slider.setAttribute('aria-valuetext', text);
  }
}
function setSetting(name, value) {
  if (settings[name] === value) return;
  settings[name] = value;
  store.set(`setting-${name}`, value);
  showSettings();
}
function resetSettings() {
  for (const [name, { initial }] of Object.entries(SETTINGS)) setSetting(name, initial);
}
for (const el of document.querySelectorAll('[data-setting]')) {
  const name = el.dataset.setting, slider = el.querySelector('[role=slider]'), all = detents(name);
  slider.setAttribute('aria-valuemin', all[0]);
  slider.setAttribute('aria-valuemax', all.at(-1));
  // A tick for every detent; the longer one marks the default that "Std." returns to.
  for (const v of all) {
    const tick = document.createElement('i');
    tick.style.setProperty('--at', settingFraction(name, v));
    tick.classList.toggle('std', v === SETTINGS[name].initial);
    slider.prepend(tick);
  }
  // The finger sets the value where it is, on the first touch and while it slides. The track's ends sit
  // half a thumb inside the element, so both ends are reachable with the thumb under the finger.
  const at = (x) => {
    const r = slider.getBoundingClientRect(), inset = slider.lastElementChild.offsetWidth / 2;
    setSetting(name, settingAt(name, (x - r.left - inset) / Math.max(1, r.width - 2 * inset)));
  };
  slider.addEventListener('touchstart', (e) => { e.preventDefault(); keepAwake(); slider.classList.add('pressed'); at(e.targetTouches[0].clientX); }, { passive: false });
  slider.addEventListener('touchmove', (e) => { e.preventDefault(); at(e.targetTouches[0].clientX); }, { passive: false });
  for (const type of ['touchend', 'touchcancel']) slider.addEventListener(type, () => slider.classList.remove('pressed'));
  // Mouse and keyboard, for desktop browsers and assistive tech.
  slider.addEventListener('mousedown', (e) => {
    at(e.clientX);
    const move = (m) => at(m.clientX), up = () => { removeEventListener('mousemove', move); removeEventListener('mouseup', up); };
    addEventListener('mousemove', move);
    addEventListener('mouseup', up);
  });
  slider.addEventListener('keydown', (e) => {
    const direction = { ArrowRight: 1, ArrowUp: 1, ArrowLeft: -1, ArrowDown: -1 }[e.key];
    if (direction) { e.preventDefault(); setSetting(name, stepSetting(name, settings[name], direction)); }
    else if (e.key === 'Home' || e.key === 'End') { e.preventDefault(); setSetting(name, e.key === 'Home' ? all[0] : all.at(-1)); }
  });
}
showSettings();

// ---- Trackpad: the live view is the pad. See touchpad.js for the gestures.
const meter = new Meter();
let moveNumber = 0, pinchFrom = 1, pinching = 0;
const touchpad = new Touchpad({
  move(dx, dy) {
    // The Mac returns the number with the first picture that shows the move, which times the round trip.
    moveNumber = (moveNumber + 1) >>> 0;
    send({ t: 'm', dx, dy, q: moveNumber });
    if (viewOn && ready) meter.moved(moveNumber, performance.now());
  },
  scroll: (dx, dy) => send({ t: 's', dx, dy }),
  scrollEnd: () => send({ t: 'se' }),
  // With a sheet open, a tap on the display puts it away instead of clicking; moves and scrolls still steer.
  click: (button) => { if (sheet && !typing && button === 'left') setSheet(''); else sendClick(button); },
  // Three fingers drag, as the Links key held with a second finger does; armed modifiers stay for the drag.
  dragStart: () => send({ t: 'b', b: 'left', d: true, mods: takeMods() }),
  dragEnd: () => send({ t: 'b', b: 'left', d: false }),
  pinchStart() {
    if (!viewOn) return false;
    pinchFrom = pinching = fitted || zoom(); // a fitted picture is pinched from the zoom it has
  },
  pinch(scale) {
    // Readout and preview stop where the Mac did (see `syncView`); the request at the end still asks for all of it.
    pinching = Math.max(clampZoom(pinchFrom * scale), floor);
    liveView?.zoomTo(pinching);
    showZoom(pinching);
  },
  pinchEnd(scale) {
    pinching = 0;
    leaveFit();
    setZoom(pinchFrom * scale);
  },
}, () => settings);
const touches = (e) => [...e.targetTouches].map((t) => ({ id: t.identifier, x: t.clientX, y: t.clientY }));
for (const [event, type] of [['touchstart', 'start'], ['touchmove', 'move'], ['touchend', 'end'], ['touchcancel', 'cancel']]) {
  pad.addEventListener(event, (e) => {
    e.preventDefault(); // the pad's touches are the Mac's, not the browser's: no scrolling, no page zoom
    if (type === 'start') keepAwake();
    touchpad.update(type, touches(e), e.timeStamp);
  }, { passive: false });
}

// ---- Live view: the Mac streams the screen region around the pointer (or the text being typed) into the
// display, and the trackpad lies on top of it. Without the live view the same surface is a plain trackpad.
// The steps of the keys, and with their ends the range of the pinch. How far out a view really goes is up to
// the Mac: it stops where every display is in the picture, and the value follows (see `placed`).
// With "Auto" the Mac picks the region itself: the window in front, whole. The readout shows the zoom that
// took, and its lamp is lit. A pinch or a zoom key takes the zoom back into the hand, from where it stands.
const ZOOM_STEPS = [0.02, 0.03, 0.04, 0.06, 0.09, 0.12, 0.18, 0.25, 0.35, 0.5, 0.7, 1, 1.4, 2, 2.8, 4];
const clampZoom = (z) => Math.min(ZOOM_STEPS.at(-1), Math.max(ZOOM_STEPS[0], z));
const wide = matchMedia('(orientation: landscape) and (max-height: 540px)'); // a phone on its side
const cadence = new Cadence(() => syncView());
let viewOn = store.get('view', (v) => typeof v === 'boolean' || v === 1 || v === 0, false) == true;
// A zoom for each way the phone is held: what shows a whole display upright is a narrow strip of it sideways.
// Sideways starts from the upright value, which is also what an older page stored.
const validZoom = (z) => typeof z === 'number' && z === clampZoom(z);
const zooms = { zoom: store.get('zoom', validZoom, 0.5) };
zooms['zoom-wide'] = store.get('zoom-wide', validZoom, zooms.zoom);
const zoomKey = () => (wide.matches ? 'zoom-wide' : 'zoom');
const zoom = () => zooms[zoomKey()];
let sentView = '', sentSize = null, requestNumber = 0;
let floor = 0; // the zoom at which the Mac had every display in the picture, for a display of the current size
let fit = store.get('fit', (v) => typeof v === 'boolean', false); // "Auto" is on
let fitted = 0; // the zoom of the picture on the display while it is fitted to a window, else 0
function syncView() {
  layout();
  body.classList.toggle('view', viewOn);
  view.hidden = !viewOn;
  $('#viewBtn').classList.toggle('on', viewOn);
  // Readout and preview stop where the Mac did, also while it is asked for more. A fitted picture has the
  // zoom the Mac chose for it, and is shown as it comes.
  const showing = pinching ? Math.max(pinching, floor) : fitted || Math.max(zoom(), floor);
  showZoom(showing);
  if (!viewOn) $('#follow').hidden = true;
  store.set('view', viewOn);
  if (!liveView) return; // not paired
  liveView.show(viewOn);
  liveView.zoomTo(fitted && !pinching ? 0 : showing);
  if (!ready || ws.readyState !== 1) return;
  const r = screenEl.getBoundingClientRect(); // measured after the layout change above
  // `zoom` goes along with "Auto" too: it counts while the Mac has no window in front to fit.
  const request = { t: 'view', on: viewOn, w: r.width, h: r.height, zoom: zoom(), ...(fit && { fit: 'window' }),
    dpr: window.devicePixelRatio || 2, codec: liveView.codec, fps: cadence.framesPerSecond };
  // Layout observers call this freely; an unchanged request must not restart the stream.
  const text = JSON.stringify(request);
  if (text === sentView) return;
  sentView = text;
  sentSize = { w: r.width, h: r.height };
  requestNumber = (requestNumber + 1) >>> 0;
  ws.send(JSON.stringify({ ...request, v: requestNumber }));
}
// Every update that reached the display: the meter times it; a picture tells which zoom is on screen.
function placed(update, picture) {
  meter.placed(update, performance.now());
  showMeter();
  $('#follow').hidden = !update.followsText;
  // Zoomed out further than it takes to show every display of the Mac: the view stops there, and so does the value.
  // Only for a request of the display's current size: one sent mid-rotation is cut for a size that is gone.
  const shown = screenEl.clientWidth / update.width;
  const current = sentSize && Math.abs(screenEl.clientWidth - sentSize.w) < 1 && Math.abs(screenEl.clientHeight - sentSize.h) < 1;
  if (!picture || pinching || !current || update.v !== requestNumber) return;
  // Fitted to a window: the zoom is the Mac's, and says nothing about how far out the hand may go.
  if (fit && update.fitted) {
    if (Math.abs(shown - fitted) > fitted * 0.001) { fitted = shown; syncView(); }
    return;
  }
  if (fitted) { fitted = 0; syncView(); } // "Auto" without a window in front: the zoom set by hand
  if (shown > zoom() * 1.02) { floor = shown; setZoom(shown); }
  else if (zoom() < floor / 1.02) { floor = 0; syncView(); } // the Mac shows more than it could: a display was added
}
function showZoom(z) {
  const text = `${decimal(z >= 1 ? Math.round(z * 10) / 10 : Math.round(z * 100) / 100)}×`;
  const readout = $('[data-act=fit]');
  $('#zoomValue').textContent = text;
  readout.classList.toggle('on', fit);
  readout.setAttribute('aria-pressed', fit);
  readout.setAttribute('aria-label', `Zoom ${text}. Auto ${fit ? 'an: das Bild zeigt das vordere Fenster ganz' : 'aus'}`);
}
// "Auto" on or off. Off, the view is cut around the pointer again, at the zoom last set by hand.
function setFit(on) {
  fit = on;
  fitted = 0;
  store.set('fit', fit);
  syncView();
}
// The hand takes the zoom: "Auto" ends, as moving the pointer ends "Folgt Text". The request follows with the new zoom.
function leaveFit() {
  if (!fit) return;
  fit = false;
  fitted = 0;
  store.set('fit', fit);
}
function setZoom(z) {
  const key = zoomKey();
  zooms[key] = Math.round(clampZoom(z) * 1000) / 1000; // fine enough for the overview: 0,045 is not 0,05
  store.set(key, zooms[key]);
  syncView();
}
function stepZoom(direction) {
  const from = fitted || zoom(); // a fitted picture steps from the zoom it has
  const next = direction > 0 ? ZOOM_STEPS.find((z) => z > from * 1.001) : ZOOM_STEPS.findLast((z) => z < from / 1.001);
  leaveFit();
  if (next) setZoom(next); else syncView();
}
// The readout follows the stream: written twice a second while messages arrive, and once more when they stop.
const meterEl = $('#meter');
let meterTimer = 0, meterText = '';
function showMeter() {
  if (meterTimer) return;
  meterTimer = setTimeout(() => {
    meterTimer = 0;
    const { fps, ms, level } = meter.read(performance.now());
    const text = `${fps}|${ms ?? '–'}|${level}`;
    if (text !== meterText) {
      meterText = text;
      meterEl.className = level === 'ok' ? '' : level;
      meterEl.firstElementChild.firstElementChild.textContent = fps;
      meterEl.lastElementChild.textContent = `${ms ?? '–'} ms`;
      meterEl.setAttribute('aria-label', `Live-Bild: ${fps} Bilder pro Sekunde`
        + (ms === null ? '' : `, ${ms} Millisekunden Verzögerung`));
    }
    if (fps && viewOn) showMeter();
  }, 500);
}
function setView(on) {
  viewOn = on;
  syncView();
  if (on) cadence.measure(); else cadence.stop();
}

// ---- Tray pages: media keys, keys, Regler.
const PAGES = ['media', 'keys', 'settings'];
let page = store.get('page', (p) => PAGES.includes(p), 'media');
function showPage() {
  body.dataset.page = page;
  body.style.setProperty('--page', PAGES.indexOf(page));
  // Only the chosen page is laid out: nothing of the others can take a touch or a focus.
  document.querySelectorAll('.page').forEach((el) => { el.hidden = el.dataset.page !== page; });
  document.querySelectorAll('[data-act=page]').forEach((b) => {
    b.classList.toggle('on', b.dataset.page === page);
    b.setAttribute('aria-pressed', b.dataset.page === page);
  });
}
function setPage(next) {
  page = next;
  store.set('page', page);
  showPage();
}
showPage();
// The page switch also follows a finger sliding across it, like a real slide switch.
$('#pages').addEventListener('touchmove', (e) => {
  const r = e.currentTarget.getBoundingClientRect();
  const next = PAGES[Math.min(PAGES.length - 1, Math.max(0, Math.floor((e.touches[0].clientX - r.left) / r.width * PAGES.length)))];
  if (next !== page) setPage(next);
}, { passive: true });

// ---- The switcher: the Mac's open apps. A tap brings an app or one of its windows to the front and puts the
// sheet away, so the display shows what came forward. See apps.js.
const switcher = new Switcher({ list: $('#apps'), title: $('#appsTitle'), note: $('#appsNote'),
  back: $('[data-act=apps-back]'), icon: $('#appsIcon') }, (message) => { send(message); setSheet(''); });
// Under the apps, on a Mac with more than one display: the displays as they are arranged. A tap puts the
// pointer on one and the sheet away, so the display shows where the pointer went. See displays.js.
const picker = new Picker($('#displays'), (message) => { send(message); setSheet(''); });
// Asked whenever the sheet opens, and when the connection goes or comes back while it is open. Whatever list
// is on show stops counting at once: nothing of it can be tapped until the Mac has answered.
function askApps() {
  switcher.reset();
  picker.reset();
  if (!ready) return switcher.say('Die Apps erscheinen, sobald der Mac verbunden ist.');
  send({ t: 'apps' });
  send({ t: 'displays' });
}

// ---- Layout: orientation, typing, keyboard and the sheets. A sheet lies over the display, so opening one
// does not change the display's size; typing does, and the view follows.
const SHEETS = { deck: $('#drawer'), apps: $('#switcher') }; // the tray and the switcher, by the key that opens each
let typing = false, sheet = '', visible = { height: innerHeight, keyboard: false };
function layout() {
  body.classList.toggle('wide', wide.matches);
  body.classList.toggle('typing', typing);
  body.classList.toggle('keyboard', visible.keyboard);
  const open = typing ? '' : sheet;
  body.classList.toggle('drawer', open === 'deck');
  body.classList.toggle('apps', open === 'apps');
  for (const [name, el] of Object.entries(SHEETS)) {
    const key = $(`[data-act=${name}]`);
    key.classList.toggle('on', sheet === name);
    key.setAttribute('aria-expanded', sheet === name);
    el.inert = open !== name;
  }
}
// One sheet at a time: opening one puts the other away.
function setSheet(next) {
  sheet = next;
  if (next === 'apps') askApps();
  layout();
}
addEventListener('keydown', (e) => { if (e.key === 'Escape' && sheet && !typing) setSheet(''); });
// A sheet also goes away with a swipe down. It follows the finger and either drops (far or fast enough) or
// springs back. The swipe starts anywhere on the sheet but on a control. The switcher's list is the exception
// both ways: its icons act on a tap, not on a touch, so a swipe may start on them, but only while the list
// does not scroll, where the same swipe would have to scroll it.
const PULL_SLOP = 10; // a finger on the list has to travel this far down before the sheet follows it
for (const tray of Object.values(SHEETS)) {
  let from = null;
  tray.addEventListener('touchstart', (e) => {
    const well = e.target.closest('.well');
    from = null;
    if (e.touches.length > 1 || (well ? well.scrollHeight > well.clientHeight : e.target.closest('button, [role=slider], .switch'))) return;
    from = { y: e.touches[0].clientY, time: e.timeStamp, dy: 0, speed: 0, held: !well };
    if (well) return; // a tap on an icon stays a tap
    e.preventDefault();
    tray.classList.add('held');
  }, { passive: false });
  tray.addEventListener('touchmove', (e) => {
    if (!from) return;
    const travel = e.touches[0].clientY - from.y;
    if (!from.held) {
      if (travel < PULL_SLOP) return;
      Object.assign(from, { y: from.y + PULL_SLOP, held: true });
      tray.classList.add('held');
    }
    e.preventDefault();
    const dy = Math.max(0, e.touches[0].clientY - from.y), dt = Math.max(1, e.timeStamp - from.time);
    from.speed = (dy - from.dy) / dt;
    Object.assign(from, { dy, time: e.timeStamp });
    tray.style.setProperty('--pull', `${dy}px`);
  }, { passive: false });
  const release = (e) => {
    if (!from) return;
    tray.classList.remove('held');
    tray.style.removeProperty('--pull');
    // Let go over an icon after pulling: the finger did not tap it.
    if (from.held && e.cancelable) e.preventDefault();
    if (e.type === 'touchend' && (from.dy > 56 || (from.dy > 12 && from.speed > 0.4))) setSheet('');
    from = null;
  };
  tray.addEventListener('touchend', release, { passive: false });
  tray.addEventListener('touchcancel', release);
}
follow((frame) => {
  visible = frame;
  root.style.setProperty('--vh', `${frame.height}px`);
  root.style.setProperty('--top', `${frame.top}px`);
  syncView();
});
wide.addEventListener('change', syncView);
// Keyboard and rotation resize the display; the captured region must follow.
new ResizeObserver(() => { floor = 0; fitted = 0; liveView?.layout(); syncView(); }).observe(screenEl);

// ---- Buttons. preventDefault on touchstart keeps the iOS keyboard open.
function fire(b) {
  const d = b.dataset;
  if (d.act === 'view') setView(!viewOn);
  else if (d.act === 'page') setPage(d.page);
  else if (d.act in SHEETS) setSheet(sheet === d.act ? '' : d.act);
  else if (d.act === 'apps-back') switcher.back();
  else if (d.act === 'zoom') stepZoom(Number(d.step));
  else if (d.act === 'fit') setFit(!fit);
  else if (d.act === 'settings-reset') resetSettings();
  else if (d.act === 'done') field.blur();
  else if (d.act === 'type') field.focus();
  else if (d.key) sendKey(d.key, d.with);
  else if (d.media) send({ t: 'media', k: d.media });
  else if (d.click) sendClick(d.click);
  else if (d.mod) { mods.has(d.mod) ? mods.delete(d.mod) : mods.add(d.mod); showMods(); }
}
document.querySelectorAll('button').forEach((b) => {
  let delay = 0, repeat = 0;
  const stop = () => { clearTimeout(delay); clearInterval(repeat); };
  b.addEventListener('touchstart', (e) => {
    e.preventDefault();
    keepAwake();
    b.classList.add('pressed');
    // The Mac keeps the modifiers of the press until the release, so a drag carries them.
    if (b.dataset.hold) return send({ t: 'b', b: b.dataset.hold, d: true, mods: takeMods() });
    if (b.dataset.act === 'type') return; // iOS opens the keyboard only for a focus made on touchend
    fire(b);
    if ('repeat' in b.dataset) delay = setTimeout(() => { repeat = setInterval(() => fire(b), 70); }, 400);
  }, { passive: false });
  const end = (e) => {
    e.preventDefault();
    stop();
    b.classList.remove('pressed');
    if (b.dataset.hold) send({ t: 'b', b: b.dataset.hold, d: false });
    if (b.dataset.act === 'type' && e.type === 'touchend') field.focus();
  };
  b.addEventListener('touchend', end, { passive: false });
  b.addEventListener('touchcancel', end, { passive: false });
  // Mouse/keyboard fallback for desktop browsers and assistive tech.
  b.addEventListener('click', () => { if (b.dataset.hold) sendClick(b.dataset.hold); else fire(b); });
});

// ---- Keyboard: what the iOS keyboard types goes to the Mac, see typing.js. While the Mac is locked the
// field takes its password instead: as a password field, so iOS masks it, keeps it out of what the keyboard
// learns and offers the one saved for this page. The Mac types it into its lock screen and says `lock` once
// it is open, or `unlock` with the reason why it is not.
let locked = false, unlocking = false; // unlocking: the Mac has a password and has not answered yet
const emptyField = relay(field, {
  text: (s) => send({ t: 'text', s }),
  backspace: (n) => send({ t: 'key', k: 'backspace', mods: [], n }),
  key: (k) => sendKey(k),
  armed: () => mods.size > 0,
  secret: () => locked,
  submit(s) {
    // The Mac takes one password at a time. A corrected one stays in the field until it has answered.
    if (unlocking) return false;
    unlocking = ready;
    send({ t: 'unlock', s });
    hint(ready ? 'Entsperre…' : 'Keine Verbindung zum Mac');
  },
});
/** What the empty field says while the Mac is locked. `failed`: the last try did not open it. */
function hint(text, failed = false) {
  field.placeholder = text;
  field.classList.toggle('failed', failed);
}
field.addEventListener('input', () => { if (locked) hint('Passwort des Macs'); });
function setLocked(on) {
  unlocking = false;
  if (on === locked) return;
  // A field that changes its kind while it has the keyboard keeps the old keyboard: it is put away first.
  field.blur();
  locked = on;
  body.classList.toggle('locked', on);
  field.type = on ? 'password' : 'text';
  field.autocomplete = on ? 'current-password' : 'off';
  field.enterKeyHint = on ? 'go' : 'send';
  field.setAttribute('aria-label', on ? 'Passwort zum Entsperren des Macs' : 'Text an den Mac senden');
  hint(on ? 'Passwort des Macs' : '');
  $('#typeLabel').textContent = on ? 'Entsperren…' : 'Tippen…';
  $('[data-act=type]').setAttribute('aria-label', on ? 'Mac entsperren' : 'Tastatur öffnen');
  emptyField();
}
function unlockFailed(why) {
  unlocking = false;
  if (locked) hint(why === 'field' ? 'Mac nicht bereit, nochmal?' : 'Nicht entsperrt, nochmal?', true);
}
// The tray comes back after typing; the switcher does not, its list would be old by then.
field.addEventListener('focus', () => { keepAwake(); typing = true; if (sheet === 'apps') sheet = ''; syncView(); });
field.addEventListener('blur', () => { typing = false; syncView(); });

connect();
keepAwake();
