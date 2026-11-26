// The page: connection, controls, keys and settings, wired to the touchpad, the viewport, the live view, the
// switcher, the display picker, the pairing and the gesture tour.
import { Switcher, readApps } from './apps.js';
import { Awake } from './awake.js';
import { Heartbeat, Link, probe } from './connection.js';
import { Picker, readDisplays } from './displays.js';
import { Cadence, LiveView, Meter } from './live-view.js';
import { CODE_LENGTH, Pairing, auth, digits, fragment } from './pairing.js';
import * as passkey from './passkey.js';
import { localize, number, t } from './strings.js';
import { Tour } from './tour.js';
import { SETTINGS, Touchpad, detents, settingAt, settingFraction, settingText, stepSetting } from './touchpad.js';
import { pieces, relay } from './typing.js';
import { follow } from './viewport.js';

const $ = (s) => document.querySelector(s);
const $$ = (s) => document.querySelectorAll(s);
const body = document.body, root = document.documentElement;
const pad = $('#pad'), field = $('#field'), screenEl = $('#screen'), view = $('#view');

// ---- Words: in the phone's language, from strings.js. The steps of the first start are a list there.
localize();
$('#steps').replaceChildren(...t('welcome.steps').map((step) => Object.assign(document.createElement('li'), { textContent: step })));

// ---- Stored on the phone. Every value is checked on the way in: an older page may have left another shape.
const store = {
  get(key, valid, fallback) {
    try { const value = JSON.parse(localStorage.getItem(`remotey-${key}`)); return valid(value) ? value : fallback; } catch { return fallback; }
  },
  set(key, value) { try { localStorage.setItem(`remotey-${key}`, JSON.stringify(value)); } catch {} },
};
const isBool = (v) => typeof v === 'boolean';

// ---- Pairing: each phone is a device of the Mac's, with a key in a cookie the page cannot read (see pairing.js).
// The QR code's link names a one-time code in its fragment; a phone paired the old way has the old token there or
// stored. Either way the fragment leaves the address once it did its work, so what "Zum Home-Bildschirm" keeps
// holds no secret. Only an agent from before pairing per device still needs the token in the address.
const pairing = new Pairing();
const fromLink = fragment(location.hash);
if (fromLink?.token) pairing.keepToken(fromLink.token);
const standalone = navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;
const clearFragment = () => { if (location.hash) history.replaceState(null, '', location.pathname + location.search); };

// ---- Connection. connection.js decides the state and when to try again; this part owns the socket and shows
// the state: in the Mac's button, and for a failure a notice with its likely cause and one thing to do.
let ws = null, liveView = null, ready = false, opening = 0;
let served = null; // names the page the agent served when this one first connected
let macName = '', refusal = ''; // the Mac's name from `ok`; why it refused this phone
const heartbeat = new Heartbeat();
let beat = 0;
const link = new Link({
  open: () => { openSocket(); },
  drop: dropSocket,
  probe: () => probe(),
  online: () => navigator.onLine !== false,
  changed: () => showLink(),
  schedule: (fn, ms) => setTimeout(fn, ms),
  cancel: (id) => clearTimeout(id),
});
/** Tries now. `ask`: the user asked for it, so a refused or unknown phone is tried again and the state says "connecting". */
const connect = (ask = false) => link.begin({ ask });

// A connection needs a ticket first (or, from an older agent, the token). Without either the phone is not
// paired, and the first start shows.
async function openSocket() {
  dropSocket();
  const attempt = ++opening;
  let credentials;
  try { credentials = await pairing.credentials(); } catch { if (attempt === opening) link.lost(); return; }
  if (attempt !== opening) return;
  if (!credentials) { link.unpaired(); return; }
  if (credentials.ticket) clearFragment(); // a device now: the address holds nothing it needs
  if (sheet === 'apps') askApps(); // the list on show is the old Mac's until the new connection answers
  // Behind `tailscale serve` the socket has its own path; locally the agent listens on the port after the page's.
  const url = location.protocol === 'https:' ? `wss://${location.host}/ws` : `ws://${location.hostname}:${(Number(location.port) || 80) + 1}/ws`;
  const socket = ws = new WebSocket(url);
  socket.binaryType = 'arraybuffer';
  const player = liveView = new LiveView(view, { picture: $('#picture'), aim: $('#aim'), cursor: $('#cursor') }, {
    shown: (n) => { if (socket === ws && socket.readyState === 1) socket.send(JSON.stringify({ t: 'shown', n })); },
    placed: (update, picture) => placed(update, picture),
    keyframe: () => { if (socket === ws && ready) socket.send(JSON.stringify({ t: 'idr' })); },
    fallback: () => { if (socket === ws) syncView(); },
  });
  socket.onopen = () => socket.send(JSON.stringify(auth(credentials, standalone)));
  socket.onmessage = (e) => {
    if (socket !== ws) return;
    heartbeat.heard(performance.now()); // whatever arrives says the connection lives
    if (typeof e.data !== 'string') { player.receive(e.data); return; }
    const m = JSON.parse(e.data);
    if (m.t === 'ok') {
      // The agent was updated while this page stayed open: load the page it serves now.
      if (served !== null && m.page !== served) return location.reload();
      served = m.page;
      ready = true;
      refusal = '';
      // The Mac's name is text from the Mac: set as text where it shows, never as markup.
      macName = typeof m.name === 'string' ? m.name : '';
      showDevice(typeof m.device === 'string' ? m.device : pairing.device?.name);
      link.accepted(m.ax === true);
      listen();
      sentView = '';
      fitted = 0;
      syncView();
      send({ t: 'displays' }); // the pointer on the page stops at their edges as it does on the Mac
      if (viewOn) cadence.measure(); // low power mode may have changed it while the page was away
      if (sheet === 'apps') askApps(); // the Mac is back while the switcher is open
      showLink();
      offerTour();
    } else if (m.t === 'mac') {
      macSays(m);
    } else if (m.t === 'bye') {
      // Someone at the Mac ended this phone's session ("Trennen"); the socket closes right after. Not tried again
      // until the user asks, or the page is opened anew.
      dropSocket();
      link.ended();
    } else if (m.t === 'lock') {
      setLocked(m.on === true, m.key);
    } else if (m.t === 'unlock' && m.ok === false) {
      unlockFailed(m.why);
    } else if (m.t === 'enrol') {
      setOffer(m.off ? null : m);
    } else if (m.t === 'enrolled') {
      enrolled(m.ok === true);
    } else if (m.t === 'cursor') {
      player.setCursor(m);
    } else if (m.t === 'view' && m.ok === false) {
      // Screen Recording is missing (no `why` means the same), or another device took the live view over.
      setView(false);
      viewNotice = m.why === 'taken' ? 'taken' : 'permission';
      showNotice();
    } else if (m.t === 'apps') {
      const list = readApps(m);
      if (list) switcher.update(list);
    } else if (m.t === 'icon') {
      switcher.picture(m.id, m.png);
    } else if (m.t === 'displays') {
      const list = readDisplays(m);
      if (list) { picker.update(list); player.setDisplays(list); showDisplays(); }
    } else if (m.t === 'denied') {
      dropSocket();
      // A ticket that ran out on the way is no refusal: one more try with a fresh one.
      if (m.why === 'ticket' && !retried) { retried = true; connect(); return; }
      refusal = m.why === 'revoked' ? 'revoked' : '';
      if (refusal) pairing.forget();
      link.refused();
    }
  };
  socket.onclose = () => {
    if (socket !== ws) return;
    forget();
    link.lost();
  };
}
let retried = false;
// What the Mac says about itself, after `ok` and on every change: a permission granted at the Mac shows at once,
// and a pause at the Mac is a state of its own.
function macSays({ ax, screen, paused }) {
  link.mac({ ax: ax === true, paused: paused === true });
  if (screen === false && viewOn) { viewNotice = 'permission'; showNotice(); }
  else if (screen === true && viewNotice === 'permission') { viewNotice = null; showNotice(); if (!viewOn) setView(true); else { sentView = ''; syncView(); } }
}
// What goes with a connection: the socket, the answers it was waiting for, the challenge of the passkey.
function forget() {
  ready = false;
  clearInterval(beat);
  unlocking = byFace = false; // the answer to a password went with the connection
  phoneKey = null; // and so did the challenge
  setOffer(null);
  if (locked) restLabel();
  liveView?.close();
  if (sheet === 'apps') askApps();
}
// Closes the socket without a word: the state machine has already decided what comes next.
function dropSocket() {
  opening++;
  if (!ws) return;
  ws.onclose = null;
  ws.close();
  ws = null;
  forget();
}
// While the page is in sight, a connection that falls silent is dead: see Heartbeat.
function listen() {
  clearInterval(beat);
  retried = false;
  heartbeat.heard(performance.now());
  heartbeat.pingedAt = performance.now();
  beat = setInterval(() => {
    const now = performance.now(), due = heartbeat.check(now);
    if (due === 'ping') send({ t: 'ping' });
    else if (due === 'dead') { dropSocket(); link.lost(); }
  }, 1000);
}
// Nothing is queued: what cannot leave now is dropped, so nothing arrives late after a reconnect.
// True if the message left.
function send(msg) {
  if (!ready || ws?.readyState !== 1) return false;
  ws.send(JSON.stringify(msg));
  return true;
}

// The state, in the Mac's button: a symbol and words. Connected, the button names the Mac; a locked or paused Mac
// says so beside its name; out of reach, the words say what is wrong. Without a pairing, the first start instead.
let welcome = false; // the first start is open from the notice of a refused phone
function showLink() {
  const state = link.state, up = link.up;
  body.dataset.link = state;
  body.classList.toggle('up', up);
  const words = state === 'connected' && locked ? t('mac.locked') : t(`status.${state}`);
  $('#statusText').textContent = words;
  const button = $('#macBtn'), name = macName || t('mac.fallback');
  button.dataset.state = state === 'connecting' ? 'wait' : state === 'ended' ? 'off' : !up ? 'bad' : state === 'paused' ? 'held' : locked ? 'shut'
    : state === 'noAccess' ? 'bad' : 'ok';
  const meterText = meterOn && viewOn && up && meterLine;
  button.classList.toggle('meter', !!meterText);
  // A locked or paused Mac says that, not its name: the state is what matters then, and the name is in the menu.
  const held = up && (state === 'paused' || locked);
  $('#macName').textContent = meterText || (held ? t(state === 'paused' ? 'mac.paused' : 'mac.locked') : up ? name : words);
  $('#macState').textContent = !up || meterText || held ? '' : state === 'noAccess' ? words : '';
  button.setAttribute('aria-label', t('mac.label', name, words));
  $('#menuName').textContent = name;
  const tone = $('#menuState');
  tone.textContent = words;
  tone.dataset.tone = state === 'connected' ? 'ok' : state === 'connecting' || state === 'ended' ? '' : 'bad';
  const steps = $('#welcome');
  steps.hidden = state !== 'unpaired' && !welcome;
  steps.querySelector('[data-act=welcome-back]').hidden = state === 'unpaired';
  if (!steps.hidden && !welcomeShown) { welcomeShown = true; drawCode(); }
  if (steps.hidden) welcomeShown = false;
  showNotice();
}
let welcomeShown = false;
// One notice at a time: what keeps the Mac out of reach comes before what keeps the live view off. A paused Mac
// has nothing to do here: it goes on when it goes on at the Mac.
const NOTICES = { ended: 'reconnect', unreachable: 'retry', stopped: 'retry', offline: 'retry', noAccess: 'recheck', denied: 'howto', revoked: 'pair',
  paused: null, permission: 'retry', taken: 'takeBack' };
let viewNotice = null; // 'permission' or 'taken': the Mac refused the live view
function showNotice() {
  const state = link.state === 'denied' && refusal === 'revoked' ? 'revoked' : link.state;
  const kind = state in NOTICES ? state : viewNotice;
  const el = $('#notice');
  el.hidden = !kind;
  if (!kind) return;
  el.dataset.kind = kind;
  $('#noticeTitle').textContent = t(`notice.${kind}.title`);
  $('#noticeText').textContent = t(`notice.${kind}.text`);
  const act = $('#noticeAct');
  act.hidden = !NOTICES[kind];
  if (NOTICES[kind]) act.textContent = t(`notice.${NOTICES[kind]}`);
}
function noticeAct() {
  const kind = $('#notice').dataset.kind;
  if (kind === 'denied' || kind === 'revoked') { welcome = true; showLink(); }
  else if (kind === 'permission' || kind === 'taken') setView(true);
  else connect(true);
}
// The name the Mac gave this phone when it paired, at the foot of the settings.
function showDevice(name) {
  $('#deviceNote').textContent = name ? t('mac.device', name) : '';
}

// iOS suspends sockets in the background without closing them, so reconnect on every return. The screen
// stays on while the phone is used, and goes dark as usual once it lies untouched (see awake.js).
const awake = new Awake();
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') { connect(); awake.touched(); return; }
  // Out of sight the page shows no picture. Said now, the Mac stops the stream at once, and a window that took
  // the phone's shape gets its frame back before someone sits down at the Mac, not when the socket times out.
  send({ t: 'view', on: false });
  sentView = '';
  clearInterval(beat);
  link.stop();
  awake.release();
});
// The network is back: no need to wait for the next try.
addEventListener('online', () => { if (!link.up) connect(); });

// ---- Sticky modifiers (apply to the next key or click, then release)
const mods = new Set();
function takeMods() {
  const list = [...mods];
  mods.clear();
  showMods();
  return list;
}
// A modifier has a key on the controls' key page and one above the keyboard; both show whether it is armed.
function showMods() {
  $$('[data-mod]').forEach((b) => { b.classList.toggle('on', mods.has(b.dataset.mod)); b.setAttribute('aria-pressed', mods.has(b.dataset.mod)); });
}
// `held` is a modifier the key itself brings along, as the keys for an app's zoom do.
function sendKey(k, held) { send({ t: 'key', k, mods: [...new Set([...(held ? [held] : []), ...takeMods()])], n: 1 }); }
function sendClick(b) { send({ t: 'c', b, mods: takeMods() }); }

// ---- Settings: pointer speed, acceleration and scroll speed, independent of each other. Each is a slider
// that takes the finger anywhere along its row and snaps to the detents; the touchpad reads the values
// at every move, so a change counts from the next one.
const settings = Object.fromEntries(Object.entries(SETTINGS).map(([name, { initial }]) =>
  [name, store.get(`setting-${name}`, (v) => detents(name).includes(v), initial)]));
function showSettings() {
  for (const el of $$('[data-setting]')) {
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
// A switch in the settings or a menu: every key for the same thing shows the same state.
function check(act, on) {
  $$(`[data-act=${act}]`).forEach((b) => {
    b.setAttribute('aria-checked', on);
    if (!b.hasAttribute('role')) b.setAttribute('aria-pressed', on);
    b.classList.toggle('on', on);
  });
}
// The frame rate and delay of the live view, in the Mac's button: off unless asked for. The Mac's menu shows them always.
let meterOn = store.get('meter', isBool, false), meterLine = '';
function setMeter(on) {
  meterOn = on;
  store.set('meter', on);
  body.classList.toggle('meter', on);
  check('meter', on);
  showLink();
}
// Sideways, the mouse keys stand on the left unless asked for on the right; the tools take the other side.
let swap = store.get('swap', isBool, false);
function setSwap(on) {
  swap = on;
  store.set('swap', on);
  body.classList.toggle('swap', on);
  check('swap', on);
  syncView();
}
// See-through surfaces, or solid ones (no blur over the picture). The phone's "Reduce Transparency" does the same.
let glass = store.get('glass', isBool, true);
function setGlass(on) {
  glass = on;
  store.set('glass', on);
  body.classList.toggle('solid', !on);
  check('glass', on);
}
for (const el of $$('[data-setting]')) {
  const name = el.dataset.setting, slider = el.querySelector('[role=slider]'), all = detents(name);
  slider.setAttribute('aria-valuemin', all[0]);
  slider.setAttribute('aria-valuemax', all.at(-1));
  // A tick for every detent; the longer one marks the default that "Zurücksetzen" returns to.
  for (const v of all) {
    const tick = document.createElement('i');
    tick.style.setProperty('--at', settingFraction(name, v));
    tick.classList.toggle('std', v === SETTINGS[name].initial);
    slider.prepend(tick);
  }
  // The finger sets the value where it is, on the first touch and while it slides. The track's ends sit
  // half a thumb inside the element, so both ends are reachable with the thumb under the finger. The whole
  // row takes the finger, its name and value too, so the touch target is the row's height.
  const at = (x) => {
    const r = slider.getBoundingClientRect(), inset = slider.lastElementChild.offsetWidth / 2;
    setSetting(name, settingAt(name, (x - r.left - inset) / Math.max(1, r.width - 2 * inset)));
  };
  el.addEventListener('touchstart', (e) => { e.preventDefault(); awake.touched(); slider.classList.add('pressed'); at(e.targetTouches[0].clientX); }, { passive: false });
  el.addEventListener('touchmove', (e) => { e.preventDefault(); at(e.targetTouches[0].clientX); }, { passive: false });
  for (const type of ['touchend', 'touchcancel']) el.addEventListener(type, () => slider.classList.remove('pressed'));
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

// ---- The gesture tour: six steps on the real pad, each done when the touchpad recognises its gesture. It starts
// by itself once, the first time this phone is connected, and again from the Mac's menu or the settings.
const tourEl = $('#tour');
let tourDone = 0; // the moment the last step was done, while "Geschafft" shows
const tour = new Tour(showTour);
function showTour() {
  clearTimeout(tourDone);
  delete tourEl.dataset.done;
  if (tour.total && tour.index >= tour.total) {
    // The last gesture: a moment of praise, then the card goes.
    tourEl.dataset.done = '';
    tourEl.hidden = false;
    $('#tourCount').textContent = t('tour.count', tour.total, tour.total);
    $('#tourTitle').textContent = t('tour.done');
    $('#tourText').textContent = t('tour.doneText');
    drawDots(tour.total);
    tourDone = setTimeout(() => { tour.stop(); }, 2200);
    return;
  }
  tourEl.hidden = !tour.on;
  if (!tour.on) return;
  const step = tour.step;
  $('#tourCount').textContent = t('tour.count', tour.index + 1, tour.total);
  $('#tourTitle').textContent = t(`tour.${step.key}`);
  $('#tourText').textContent = t(`tour.${step.key}.text`);
  drawDots(tour.index);
}
function drawDots(done) {
  $('#tourDots').replaceChildren(...Array.from({ length: tour.total }, (_, i) =>
    Object.assign(document.createElement('i'), { className: i < done ? 'done' : i === done ? 'now' : '' })));
}
const saw = (gesture, distance) => tour.saw(gesture, distance);
function startTour() {
  store.set('toured', true);
  setMenu('');
  setSheet('');
  tour.start(viewOn);
}
function offerTour() {
  if (!store.get('toured', isBool, false) && link.state === 'connected' && !locked) startTour();
}

// ---- Trackpad: the live view is the pad. See touchpad.js for the gestures.
const meter = new Meter();
let moveNumber = 0, pinchFrom = 1, pinching = 0;
let fingers = { x: 0, y: 0 }; // where the last touch landed, for the ring a click leaves without the live view
let moved = store.get('moved', isBool, false);
body.classList.toggle('moved', moved);
const touchpad = new Touchpad({
  move(dx, dy) {
    if (!moved) { moved = true; store.set('moved', true); body.classList.add('moved'); }
    saw('move', Math.hypot(dx, dy));
    // The Mac returns the number with the first update that includes the move, which times the round trip.
    // Until then the page shows the pointer where the move takes it.
    moveNumber = (moveNumber + 1) >>> 0;
    if (!send({ t: 'm', dx, dy, q: moveNumber }) || !viewOn) return;
    meter.moved(moveNumber, performance.now());
    liveView.moved(moveNumber, dx, dy);
  },
  scroll: (dx, dy) => { saw('scroll'); send({ t: 's', dx, dy }); },
  scrollEnd: () => send({ t: 'se' }),
  // With a sheet or menu open, a tap on the picture puts it away instead of clicking; moves and scrolls still steer.
  click(button) {
    if (menu && !typing) return setMenu('');
    if (sheet && !typing && button === 'left') return setSheet('');
    saw(button);
    sendClick(button);
    ring();
  },
  // Three fingers drag, as the Klick key held with a second finger does; armed modifiers stay for the drag.
  dragStart: () => { saw('drag'); send({ t: 'b', b: 'left', d: true, mods: takeMods() }); },
  dragEnd: () => send({ t: 'b', b: 'left', d: false }),
  pinchStart() {
    if (!viewOn) return false;
    pinchFrom = pinching = fitted || handZoom(); // a fitted picture is pinched from the zoom it has
  },
  pinch(scale) {
    // Readout and preview stop where the Mac did (see `syncView`); the request at the end still asks for all of it.
    pinching = shaping() ? clampForm(pinchFrom * scale) : Math.max(clampZoom(pinchFrom * scale), floor);
    liveView?.zoomTo(pinching);
    showZoom(pinching);
  },
  pinchEnd(scale) {
    pinching = 0;
    saw('pinch');
    if (shaping()) return setForm(pinchFrom * scale);
    leaveFit();
    setZoom(pinchFrom * scale);
  },
}, () => settings);
const touches = (e) => [...e.targetTouches].map((t) => ({ id: t.identifier, x: t.clientX, y: t.clientY }));
for (const [event, type] of [['touchstart', 'start'], ['touchmove', 'move'], ['touchend', 'end'], ['touchcancel', 'cancel']]) {
  pad.addEventListener(event, (e) => {
    e.preventDefault(); // the pad's touches are the Mac's, not the browser's: no scrolling, no page zoom
    const now = touches(e);
    if (type === 'start') {
      awake.touched();
      const r = screenEl.getBoundingClientRect();
      fingers = { x: now.reduce((a, p) => a + p.x, 0) / now.length - r.left, y: now.reduce((a, p) => a + p.y, 0) / now.length - r.top };
    }
    touchpad.update(type, now, e.timeStamp);
  }, { passive: false });
}
// Without the live view nothing else shows that a click landed: a ring where the finger tapped.
function ring() {
  if (viewOn) return;
  const el = $('#ring');
  // Placed by its corner, not by a transform: the ring's animation is a transform of its own.
  Object.assign(el.style, { left: `${fingers.x}px`, top: `${fingers.y}px` });
  el.classList.remove('on');
  void el.offsetWidth;
  el.classList.add('on');
}

// ---- Live view: the Mac streams the screen region around the pointer (or the text being typed) into the
// picture element, and the trackpad lies on top of it. Without the live view the same element is a plain trackpad.
// The steps of the keys, and with their ends the range of the pinch. How far out a view really goes is up to
// the Mac: it stops where every display is in the picture, and the value follows (see `placed`).
// With "Fenster einpassen" the Mac picks the region itself: the window in front, whole. The readout shows the zoom
// that took, its segment tinted. A pinch or a zoom key takes the zoom back into the hand, from where it stands.
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
let floor = 0; // the zoom at which the Mac had every display in the picture, for a picture of the current size
let followsText = false; // the view follows the text being typed, not the pointer
// With "An iPhone anpassen" on top of "Fenster einpassen", the window in front also takes the phone's shape on the
// Mac, so it fills the picture instead of a band of it. Then the zoom is the window's size: − / + and a pinch ask
// the Mac for a larger or smaller window, which stays whole in the picture, and fitting stays on. The Mac gives
// the window its old frame back when another one comes forward and when this ends.
let fit = store.get('fit', isBool, false); // "Fenster einpassen" is on
let fitted = 0; // the zoom of the picture while it is fitted to a window, else 0
let shape = store.get('shape', isBool, false); // "An iPhone anpassen" is on; it counts with fitting
const shaping = () => fit && shape;
// The zoom a shaped window is asked to show at, for each way the phone is held. The Mac bounds it: a window is no
// larger than its display has room for, no smaller than its app allows, and shown at twice its size at most.
const FORM = [0.1, 2];
const clampForm = (z) => Math.min(FORM[1], Math.max(FORM[0], z));
const validForm = (z) => typeof z === 'number' && z === clampForm(z);
const forms = { form: store.get('form', validForm, 0.5), 'form-wide': store.get('form-wide', validForm, 0.5) };
const formKey = () => (wide.matches ? 'form-wide' : 'form');
const form = () => forms[formKey()];
// The zoom the hand set last, for what the zoom means right now: the size of the shaped window, or the cut.
const handZoom = () => (shaping() ? form() : zoom());
let inset = [0, 0, 0, 0]; // what the controls cover of the picture element: top, right, bottom, left
function syncView() {
  layout();
  body.classList.toggle('view', viewOn);
  view.hidden = !viewOn;
  check('view', viewOn);
  // Readout and preview stop where the Mac did, also while it is asked for more. A fitted picture has the
  // zoom the Mac chose for it, and is shown as it comes.
  const showing = pinching ? Math.max(pinching, floor) : fitted || (shaping() ? form() : Math.max(zoom(), floor));
  showZoom(showing);
  if (!viewOn) followsText = false;
  store.set('view', viewOn);
  if (!liveView) return; // not connected yet
  liveView.show(viewOn);
  liveView.zoomTo((fitted || shaping()) && !pinching ? 0 : showing);
  liveView.lead(shaping()); // the pointer ahead of the Mac's answer: only where the picture stands still
  if (!ready || ws?.readyState !== 1) return;
  const r = screenEl.getBoundingClientRect(); // measured after the layout change above
  // `zoom` goes along with fitting too: it counts while the Mac has no window in front to fit. `inset` is what the
  // glass covers: the Mac works the view out for the rest and grows it to fill the whole element.
  const request = { t: 'view', on: viewOn, w: r.width, h: r.height, zoom: zoom(), ...(fit && { fit: 'window' }), ...(shaping() && { shape: form() }),
    ...(inset.some(Boolean) && { inset }), dpr: window.devicePixelRatio || 2, codec: liveView.codec, fps: cadence.framesPerSecond };
  // Layout observers call this freely; an unchanged request must not restart the stream.
  const text = JSON.stringify(request);
  if (text === sentView) return;
  sentView = text;
  sentSize = { w: r.width, h: r.height };
  requestNumber = (requestNumber + 1) >>> 0;
  ws.send(JSON.stringify({ ...request, v: requestNumber }));
}
// Every update that reached the picture: the meter times it; a picture tells which zoom is on screen. The picture
// is the whole element's, insets included, so its width in Mac points over the element's width is its zoom.
function placed(update, picture) {
  meter.placed(update, performance.now());
  showMeter();
  if (update.followsText !== followsText) { followsText = update.followsText; showZoom(pinching || fitted || (shaping() ? form() : Math.max(zoom(), floor))); }
  // Zoomed out further than it takes to show every display of the Mac: the view stops there, and so does the value.
  // Only for a request of the element's current size: one sent mid-rotation is cut for a size that is gone.
  const shown = screenEl.clientWidth / update.width;
  const current = sentSize && Math.abs(screenEl.clientWidth - sentSize.w) < 1 && Math.abs(screenEl.clientHeight - sentSize.h) < 1;
  if (!picture || pinching || !current || update.v !== requestNumber) return;
  // Fitted to a window: the zoom is the Mac's, and says nothing about how far out the hand may go.
  if (fit && update.fitted) {
    if (Math.abs(shown - fitted) > fitted * 0.001) { fitted = shown; syncView(); }
    return;
  }
  if (fitted) { fitted = 0; syncView(); } // fitting without a window in front: the zoom set by hand
  if (shown > zoom() * 1.02) { floor = shown; setZoom(shown); }
  else if (zoom() < floor / 1.02) { floor = 0; syncView(); } // the Mac shows more than it could: a display was added
}
function showZoom(z) {
  const text = `${number(z >= 1 ? Math.round(z * 10) / 10 : Math.round(z * 100) / 100)}×`;
  const readout = $('#readout');
  $('#zoomValue').textContent = text;
  // The tinted segment: the view is fitted to the window in front. The symbol says how: a window, a phone (the
  // window has the phone's shape), or the text cursor while the view follows what is typed.
  readout.classList.toggle('on', fit);
  readout.setAttribute('aria-label', t('zoom.label', text, fit, shape, followsText));
  readout.dataset.lamp = followsText ? 'text' : shaping() ? 'phone' : fit ? 'window' : '';
  check('fit', fit);
  check('shape', shaping());
}
// "An iPhone anpassen" on or off. It needs fitting, so switching it on switches that on too. Switching fitting off
// keeps it for the next time.
function setShape(on) {
  shape = on;
  store.set('shape', shape);
  if (on && !fit) { fit = true; store.set('fit', fit); }
  fitted = 0;
  syncView();
}
// The size of the shaped window, as the zoom it shows at.
function setForm(z) {
  const key = formKey();
  forms[key] = Math.round(clampForm(z) * 1000) / 1000;
  store.set(key, forms[key]);
  syncView();
}
// "Fenster einpassen" on or off. Off, the view is cut around the pointer again, at the zoom last set by hand.
function setFit(on) {
  fit = on;
  fitted = 0;
  store.set('fit', fit);
  syncView();
}
// The hand takes the zoom: fitting ends, as moving the pointer ends following the text. The request follows with the new zoom.
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
  const from = fitted || handZoom(); // a fitted picture steps from the zoom it has
  const next = direction > 0 ? ZOOM_STEPS.find((z) => z > from * 1.001) : ZOOM_STEPS.findLast((z) => z < from / 1.001);
  if (shaping()) { if (next) setForm(next); return; }
  leaveFit();
  if (next) setZoom(next); else syncView();
}
// From the view's menu: one Mac point to one point of the phone, or as far out as the Mac goes (it stops where every
// display is in the picture, and the readout follows). With the phone's shape, actual size is the window's.
function zoomActual() {
  if (shaping()) return setForm(1);
  leaveFit();
  setZoom(1);
}
function zoomAll() {
  leaveFit();
  setZoom(ZOOM_STEPS[0]);
}
// The readout follows the stream: written twice a second while messages arrive, and once more when they stop.
let meterTimer = 0;
function showMeter() {
  if (meterTimer) return;
  meterTimer = setTimeout(() => {
    meterTimer = 0;
    const { fps, ms } = meter.read(performance.now());
    // Nothing measured yet: no numbers that look like a failure. Once measured, a still screen reads 0 fps.
    const text = fps || ms !== null || meterLine ? t('meter.short', fps, ms) : '';
    if (text !== meterLine) {
      meterLine = text;
      $('#menuMeter').textContent = viewOn ? text : '';
      $('#menuMeter').setAttribute('aria-label', t('meter.label', fps, ms));
      if (meterOn) showLink();
    }
    if (fps && viewOn) showMeter();
  }, 500);
}
function setView(on) {
  viewOn = on;
  if (on && viewNotice) { viewNotice = null; showNotice(); }
  if (!on) { meterLine = ''; $('#menuMeter').textContent = ''; }
  syncView();
  showLink();
  if (on) cadence.measure(); else cadence.stop();
}

// ---- Controls' pages: media keys and keys.
const PAGES = ['media', 'keys'];
let page = store.get('page', (p) => PAGES.includes(p), 'media');
function showPage() {
  body.dataset.page = page;
  $('#pages').style.setProperty('--page', PAGES.indexOf(page));
  // Only the chosen page is laid out: nothing of the other can take a touch or a focus.
  $$('.page').forEach((el) => { el.hidden = el.dataset.page !== page; });
  $$('[data-act=page]').forEach((b) => {
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
// sheet away, so the picture shows what came forward. See apps.js.
const switcher = new Switcher({ list: $('#apps'), title: $('#appsTitle'), note: $('#appsNote'),
  back: $('[data-act=apps-back]'), icon: $('#appsIcon') }, (message) => { send(message); setSheet(''); });
// The close key gives way to the back key while the windows of one app are listed.
new MutationObserver(() => { $('#switcher [data-act=close]').hidden = !$('[data-act=apps-back]').hidden; })
  .observe($('[data-act=apps-back]'), { attributes: true, attributeFilter: ['hidden'] });
// In the view's menu, on a Mac with more than one display: the displays as they are arranged. A tap puts the
// pointer on one and the menu away, so the picture shows where the pointer went. See displays.js.
const picker = new Picker($('#displays'), (message) => { send(message); setMenu(''); });
// The map changes the menu's height: placed again, so it stays inside the phone.
function showDisplays() { $('#viewMenu .displays').hidden = $('#displays').hidden; if (menu === 'view') place(...MENUS.view); }
// Asked whenever the sheet opens, and when the connection goes or comes back while it is open. Whatever list
// is on show stops counting at once: nothing of it can be tapped until the Mac has answered.
function askApps() {
  switcher.reset();
  if (!ready) return switcher.say(t('apps.waiting'));
  // The icons the page has from before are named, so the Mac sends only the others.
  const have = switcher.known();
  send({ t: 'apps', ...(have.length && { have }) });
}
// The displays, asked whenever the view's menu opens: the map on show takes no tap until the Mac has answered.
function askDisplays() {
  picker.reset();
  showDisplays();
  send({ t: 'displays' });
}

// ---- Layout: orientation, typing, keyboard, sheets and menus. A sheet or a menu lies over the picture, so opening
// one changes neither the picture's size nor what the glass covers: the stream runs on.
const SHEETS = { apps: $('#switcher'), deck: $('#drawer'), prefs: $('#prefs') }; // by the key that opens each
const SHEET_CLASS = { apps: 'apps', deck: 'drawer', prefs: 'prefs' };
const MENUS = { mac: [$('#macMenu'), $('#macBtn')], view: [$('#viewMenu'), $('#readout')] };
const zones = { top: $('#zoneTop'), bottom: $('#zoneBottom'), mouse: $('#zoneMouse'), tools: $('#zoneTools') };
const part = { mac: $('#macBtn'), zoom: $('#zoom'), live: $('#liveBtn'), side: $('#side'), left: $('#leftBtn'), right: $('#rightBtn'),
  type: $('[data-act=type]'), apps: $('[data-act=apps]'), deck: $('[data-act=deck]'), mouse: $('#mouse'), bar: $('#bar') };
const spacer = () => Object.assign(document.createElement('div'), { className: 'spacer' });
let typing = false, sheet = '', menu = '', visible = { height: innerHeight, keyboard: false }, arranged = '';
// Upright the controls float at the top and under the thumb; sideways they stand in the two side margins, the mouse
// keys under one thumb and the tools under the other. The same buttons move, so focus order follows what is seen.
function arrange() {
  const shape = wide.matches ? 'wide' : 'tall';
  if (shape === arranged) return;
  arranged = shape;
  if (shape === 'wide') {
    zones.mouse.replaceChildren(part.mac, part.side, part.right, part.left);
    zones.tools.replaceChildren(part.zoom, part.live, spacer(), part.type, part.apps, part.deck);
  } else {
    part.mouse.replaceChildren(part.side, part.left, part.right);
    part.bar.replaceChildren(part.type, part.apps, part.deck);
    zones.top.replaceChildren(part.mac, part.zoom, part.live);
  }
}
// What the glass covers of the picture element, in CSS pixels: the band under the top controls and the one over the
// thumb's, upright; the two side margins sideways. Sheets, menus and the tour are left out: they come and go.
function measureInsets() {
  const s = screenEl.getBoundingClientRect();
  if (!s.width || !s.height) return [0, 0, 0, 0];
  const box = (el) => el.getBoundingClientRect(), shown = (el) => getComputedStyle(el).display !== 'none';
  let top = 0, right = 0, bottom = 0, left = 0;
  if (typing) {
    if (shown(zones.top)) top = box(zones.top).bottom - s.top;
    bottom = s.bottom - box($('#typebar')).top;
  } else if (wide.matches) {
    const [a, b] = swap ? [zones.tools, zones.mouse] : [zones.mouse, zones.tools];
    left = box(a).right - s.left;
    right = s.right - box(b).left;
  } else {
    top = box(zones.top).bottom - s.top;
    bottom = s.bottom - box(zones.bottom).top;
  }
  return [top, right, bottom, left].map((v) => Math.max(0, Math.round(v)));
}
function layout() {
  arrange();
  body.classList.toggle('wide', wide.matches);
  body.classList.toggle('swap', swap);
  body.classList.toggle('typing', typing);
  body.classList.toggle('keyboard', visible.keyboard);
  // Typing on a short screen: the top controls give the picture their band, so the text stays in sight.
  body.classList.toggle('cramped', typing && visible.height < 420);
  const open = typing ? '' : sheet;
  for (const [name, el] of Object.entries(SHEETS)) {
    body.classList.toggle(SHEET_CLASS[name], open === name);
    part[name]?.classList.toggle('on', sheet === name);
    part[name]?.setAttribute('aria-expanded', sheet === name);
    el.inert = open !== name;
  }
  inset = measureInsets();
  ['top', 'right', 'bottom', 'left'].forEach((side, i) => root.style.setProperty(`--in-${side}`, `${inset[i]}px`));
  if (menu) place(...MENUS[menu]);
}
// One sheet at a time: opening one puts the other and any menu away.
function setSheet(next) {
  sheet = next;
  if (next) setMenu('');
  if (next === 'apps') askApps();
  layout();
}
// One menu at a time, next to its button: below it upright, beside it in a side margin. It leaves quickly.
function setMenu(next) {
  if (next === menu) return;
  menu = next;
  if (next && sheet) setSheet('');
  for (const [name, [el, opener]] of Object.entries(MENUS)) {
    opener.setAttribute('aria-expanded', name === next);
    if (name === next) {
      clearTimeout(el.leaving);
      el.classList.remove('leaving');
      el.hidden = false;
      place(el, opener);
      if (name === 'view') askDisplays();
    } else if (!el.hidden && !el.classList.contains('leaving')) {
      el.classList.add('leaving');
      el.leaving = setTimeout(() => { el.hidden = true; el.classList.remove('leaving'); }, 140);
    }
  }
}
function place(el, opener) {
  const a = $('#app').getBoundingClientRect(), o = opener.getBoundingClientRect();
  const leftSide = o.left + o.width / 2 < a.left + a.width / 2;
  Object.assign(el.style, { left: '', right: '', top: '' });
  if (wide.matches) {
    el.style[leftSide ? 'left' : 'right'] = `${leftSide ? o.right - a.left + 8 : a.right - o.left + 8}px`;
    el.style.top = `${Math.max(8, Math.min(o.top - a.top, a.height - el.offsetHeight - 8))}px`;
  } else {
    el.style.top = `${o.bottom - a.top + 8}px`;
    el.style[leftSide ? 'left' : 'right'] = `${leftSide ? o.left - a.left : a.right - o.right}px`;
  }
  el.style.setProperty('--from', `top ${leftSide ? 'left' : 'right'}`);
}
addEventListener('keydown', (e) => {
  if (e.key !== 'Escape' || typing) return;
  if (menu) { const opener = MENUS[menu][1]; setMenu(''); opener.focus(); } else if (sheet) setSheet('');
});
// A sheet also goes away with a swipe down. It follows the finger and either drops (far or fast enough) or
// springs back. The swipe starts anywhere on the sheet but on a control. A list is the exception both ways: its
// items act on a tap, not on a touch, so a swipe may start on them, but only while the list does not scroll,
// where the same swipe would have to scroll it.
const PULL_SLOP = 10; // a finger on a list has to travel this far down before the sheet follows it
for (const tray of Object.values(SHEETS)) {
  let from = null;
  tray.addEventListener('touchstart', (e) => {
    const well = e.target.closest('.well');
    from = null;
    if (e.touches.length > 1 || (well ? well.scrollHeight > well.clientHeight + 1 : e.target.closest('button, .setting, .segments'))) return;
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
// Keyboard and rotation resize the picture element; the captured region must follow.
new ResizeObserver(() => { floor = 0; fitted = 0; liveView?.layout(); syncView(); }).observe(screenEl);

// ---- Buttons. preventDefault on touchstart keeps the iOS keyboard open.
function fire(b) {
  const d = b.dataset;
  // A tap anywhere but on a menu's own button puts the menu away; its items act and put it away too.
  if (menu && d.act !== 'mac' && d.act !== 'viewmenu') setMenu('');
  if (d.act === 'view') setView(!viewOn);
  else if (d.act === 'mac') setMenu(menu === 'mac' ? '' : 'mac');
  else if (d.act === 'viewmenu') setMenu(menu === 'view' ? '' : 'view');
  else if (d.act === 'page') setPage(d.page);
  else if (d.act in SHEETS) setSheet(sheet === d.act ? '' : d.act);
  else if (d.act === 'close') setSheet('');
  else if (d.act === 'settings') setSheet('prefs');
  else if (d.act === 'apps-back') switcher.back();
  else if (d.act === 'zoom') stepZoom(Number(d.step));
  else if (d.act === 'fit') setFit(!fit);
  else if (d.act === 'shape') setShape(!shaping());
  else if (d.act === 'zoom-actual') zoomActual();
  else if (d.act === 'zoom-all') zoomAll();
  else if (d.act === 'settings-reset') resetSettings();
  else if (d.act === 'meter') setMeter(!meterOn);
  else if (d.act === 'swap') setSwap(!swap);
  else if (d.act === 'glass') setGlass(!glass);
  else if (d.act === 'tour') startTour();
  else if (d.act === 'tour-skip') tour.stop();
  else if (d.act === 'notice') noticeAct();
  else if (d.act === 'welcome-back') { welcome = false; showLink(); }
  else if (d.act === 'done') field.blur();
  else if (d.act === 'type') openField();
  else if (d.act === 'enrol') enrol();
  else if (d.act === 'enrol-later') enrolSheet.hidden = true; // the offer stands at the Mac until its time is up
  // A locked Mac is unlocked by its lock, as by the bar's key. To lock it: exactly these two modifiers,
  // whatever is armed, since Shift-Command-Q logs the user out.
  else if (d.act === 'lock') { if (locked) openField(); else send({ t: 'key', k: 'q', mods: ['ctrl', 'cmd'], n: 1 }); }
  else if (d.key) sendKey(d.key, d.with);
  else if (d.media) send({ t: 'media', k: d.media });
  else if (d.click) sendClick(d.click);
  else if (d.mod) { mods.has(d.mod) ? mods.delete(d.mod) : mods.add(d.mod); showMods(); }
}
// Keys that act when the finger lifts: iOS opens the keyboard only for a focus made on touchend, and asks for
// Face ID only then.
const ON_LIFT = new Set(['type', 'lock', 'enrol']);
$$('button').forEach((b) => {
  let delay = 0, repeat = 0;
  const stop = () => { clearTimeout(delay); clearInterval(repeat); };
  b.addEventListener('touchstart', (e) => {
    e.preventDefault();
    awake.touched();
    b.classList.add('pressed');
    // The Mac keeps the modifiers of the press until the release, so a drag carries them.
    if (b.dataset.hold) { if (menu) setMenu(''); return send({ t: 'b', b: b.dataset.hold, d: true, mods: takeMods() }); }
    if (ON_LIFT.has(b.dataset.act)) return;
    fire(b);
    if ('repeat' in b.dataset) delay = setTimeout(() => { repeat = setInterval(() => fire(b), 70); }, 400);
  }, { passive: false });
  const end = (e) => {
    e.preventDefault();
    stop();
    b.classList.remove('pressed');
    if (b.dataset.hold) send({ t: 'b', b: b.dataset.hold, d: false });
    if (ON_LIFT.has(b.dataset.act) && e.type === 'touchend') fire(b);
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
// With this phone enrolled for Face ID the Mac's `lock` names a passkey: the bar's key then asks the phone
// for it instead of opening the field, and the Mac types the password it kept sealed. A try that is
// declined or refused leaves the next tap to the field, and closing the field leaves it to Face ID again.
// The lock in the Mac's menu and on the controls' media page does the same on a locked Mac. One way to unlock.
let locked = false, unlocking = false; // unlocking: the Mac has a password and has not answered yet
let phoneKey = null; // the passkey to ask for and its challenge, good for one try
let asking = false, byFace = false, declined = false; // asking: iOS has a question on show; byFace: the try in flight
// The bar key's words, long and short (the short ones stand where the long ones do not fit).
function typeLabel(long, short = long) {
  $('#typeLabel').textContent = long;
  $('#typeShort').textContent = short;
  $('[data-act=type]').setAttribute('aria-label', locked ? long : t('type.label'));
}
// What the key says while nothing is under way: what a tap does. On a locked Mac it names the way, Face ID
// or the password, and shows its sign.
function showFace() { body.classList.toggle('face', locked && !!phoneKey && !declined); }
function restLabel() {
  showFace();
  if (!locked) typeLabel(t('type'), t('type.short'));
  else if (phoneKey && !declined) typeLabel(t('unlock.face'), t('unlock.faceShort'));
  else typeLabel(t('unlock.plain'), t('unlock.plainShort'));
}
const emptyField = relay(field, {
  // The Mac drops a long text: it goes in pieces (see typing.js).
  text: (s) => { for (const piece of pieces(s)) send({ t: 'text', s: piece }); },
  backspace: (n) => send({ t: 'key', k: 'backspace', mods: [], n }),
  key: (k) => sendKey(k),
  armed: () => mods.size > 0,
  secret: () => locked,
  submit(s) {
    // The Mac takes one password at a time. A corrected one stays in the field until it has answered.
    if (unlocking) return false;
    unlocking = ready;
    send({ t: 'unlock', s });
    hint(ready ? t('unlock.busy') : t('unlock.offline'));
  },
});
/** What the empty field says while the Mac is locked. `failed`: the last try did not open it. */
function hint(text, failed = false) {
  field.placeholder = text;
  field.classList.toggle('failed', failed);
}
field.addEventListener('input', () => { if (locked) hint(t('unlock.hint')); });
function openField() {
  if (locked && phoneKey && !declined) return void unlockWithFace();
  if (locked) restLabel();
  field.focus();
}
async function unlockWithFace() {
  if (asking || unlocking) return;
  const key = phoneKey;
  asking = true;
  typeLabel(t('unlock.asking'));
  const message = await passkey.get(key).catch(() => null);
  asking = false;
  if (!locked) return;
  if (!message) { declined = true; restLabel(); return; }
  if (phoneKey === key) phoneKey = null; // its challenge is spent; the Mac sends the next one
  if (!ready) return restLabel();
  unlocking = byFace = true;
  send(message);
  typeLabel(t('unlock.busy'));
}
function setLocked(on, key = null) {
  unlocking = false;
  phoneKey = on && key && passkey.available() ? key : null;
  if (on === locked) { showFace(); return; } // a new challenge, which comes after every try: the key still says how that went
  byFace = declined = false;
  // A field that changes its kind while it has the keyboard keeps the old keyboard: it is put away first.
  field.blur();
  locked = on;
  body.classList.toggle('locked', on);
  field.type = on ? 'password' : 'text';
  field.autocomplete = on ? 'current-password' : 'off';
  field.enterKeyHint = on ? 'go' : 'send';
  field.setAttribute('aria-label', on ? t('unlock.field') : t('field'));
  hint(on ? t('unlock.hint') : '');
  restLabel();
  $$('[data-act=lock]').forEach((k) => {
    k.classList.toggle('on', on);
    k.setAttribute('aria-pressed', on);
    k.setAttribute('aria-label', on ? t('lock.unlock') : t('lock.lock'));
    const word = k.querySelector('.lockword');
    if (word) word.textContent = k.classList.contains('tile') ? t(on ? 'tile.unlock' : 'tile.lock') : t(on ? 'lock.unlock' : 'lock.lock');
  });
  emptyField();
  showLink();
}
function unlockFailed(why) {
  unlocking = false;
  if (!locked) return;
  hint(why === 'field' ? t('unlock.notReady') : t('unlock.again'), true);
  if (!byFace) return;
  // The field is not open: the key says it. A Mac that was not ready is asked again with Face ID.
  byFace = false;
  declined = why !== 'field';
  typeLabel(why === 'field' ? t('unlock.unready') : t('unlock.refused'));
}

// ---- Enrolling for Face ID: started from the agent's menu at the Mac, which then offers it to the phone.
// A card over the picture says what it is for and takes the tap; its states: offer, busy (iOS asks, or the
// Mac has the passkey and has not answered), failed, done.
const enrolSheet = $('#enrol'), enrolKey = $('[data-act=enrol]');
let offer = null, taken = false, confirmed = 0; // taken: this phone has answered the offer with its passkey
function showEnrol(state, title, text, key = t('enrol.go')) {
  enrolSheet.dataset.state = state;
  $('#enrolTitle').textContent = title;
  $('#enrolText').textContent = text;
  enrolKey.textContent = key;
}
function setOffer(next) {
  offer = next;
  taken = false;
  clearTimeout(confirmed);
  if (next) showEnrol('offer', t('enrol.title'), t('enrol.offer', next.name));
  enrolSheet.hidden = !next;
}
async function enrol() {
  if (asking || !offer) return;
  const mine = offer;
  asking = true;
  enrolSheet.dataset.state = 'busy';
  const message = await passkey.create(mine).catch(() => null);
  asking = false;
  if (offer !== mine) return;
  taken = !!message && ready;
  if (taken) { send(message); enrolKey.textContent = t('enrol.busy'); } else enrolFailed();
}
function enrolFailed() {
  taken = false;
  showEnrol('failed', t('enrol.title'), t('enrol.failed'), t('enrol.again'));
}
function enrolled(ok) {
  if (!ok) { if (offer) enrolFailed(); return; }
  // The offer is over for every phone; the one that took it reads so for a moment.
  const mine = taken;
  setOffer(null);
  if (!mine) return;
  showEnrol('done', t('enrol.done'), t('enrol.doneText'));
  enrolSheet.hidden = false;
  confirmed = setTimeout(() => { enrolSheet.hidden = true; }, 2500);
}
// Sheets come back after typing, all but the switcher: its list would be old by then.
field.addEventListener('focus', () => { awake.touched(); typing = true; setMenu(''); if (sheet === 'apps') sheet = ''; syncView(); });
field.addEventListener('blur', () => { typing = false; declined = false; if (locked) restLabel(); syncView(); });

// ---- The first start: the six digits the Mac shows beside its QR code, typed, pasted or offered by iOS. They
// are posted as soon as there are six; what went wrong is said in words, and the field is ready for the next try.
const codeEl = $('#code'), cells = [...$$('.cells span')], says = $('#pairSays');
let pairingNow = false;
function drawCode() {
  const value = digits(codeEl.value);
  cells.forEach((cell, i) => { cell.textContent = value[i] ?? ''; cell.classList.toggle('now', i === Math.min(value.length, CODE_LENGTH - 1)); });
}
function say(text, tone = '') {
  says.textContent = text;
  says.className = tone;
  codeEl.parentElement.classList.toggle('failed', tone === 'bad');
}
async function pairWith(request) {
  if (pairingNow) return null;
  pairingNow = true;
  say(t('pair.busy'));
  const result = await pairing.pair(request);
  pairingNow = false;
  clearFragment(); // a one-time code is spent either way
  if (result.ok) {
    say(t('pair.done'), 'ok');
    codeEl.blur();
    welcome = false;
    refusal = '';
    connect(true);
    return result;
  }
  say(t(`pair.${result.why === 'token' ? 'code' : result.why}`), 'bad');
  codeEl.value = '';
  drawCode();
  return result;
}
codeEl.addEventListener('input', () => {
  const value = digits(codeEl.value);
  if (codeEl.value !== value) codeEl.value = value;
  if (value && says.className === 'bad') say('');
  drawCode();
  if (value.length === CODE_LENGTH) pairWith({ code: value });
});
codeEl.addEventListener('keydown', (e) => { if (e.key === 'Enter' && digits(codeEl.value).length === CODE_LENGTH) pairWith({ code: digits(codeEl.value) }); });
codeEl.addEventListener('focus', drawCode);
codeEl.addEventListener('blur', drawCode);
// From the Home Screen the app has its own storage: it needs the code once, and says so.
if (standalone) $('#welcome .card > p').textContent = t('pair.home');

setGlass(glass);
setMeter(meterOn);
setSwap(swap);
restLabel();
showLink();
drawCode();
// A link with a one-time code pairs first; every other start asks for a ticket straight away.
if (fromLink?.code) pairWith({ code: fromLink.code }).then((result) => { if (!result?.ok) connect(); });
else connect();
awake.touched();
