import assert from 'node:assert/strict';
import { test } from 'node:test';
import { SETTINGS, TAP_MS, Touchpad, detents, gain, settingAt, settingFraction, settingText, stepSetting } from '../Web/touchpad.js';
import { appLabel, readApps, tapApp, tapWindow, windowTitle } from '../Web/apps.js';
import { SENTINEL, diff } from '../Web/typing.js';
import { KEYBOARD_MIN, frame } from '../Web/viewport.js';

const defaults = Object.fromEntries(Object.entries(SETTINGS).map(([k, { initial }]) => [k, initial]));

/** A touchpad that writes what it would send into `log`. */
function pad(settings = defaults) {
  const log = [];
  const out = { move: (dx, dy) => log.push(['m', dx, dy]), scroll: (dx, dy) => log.push(['s', dx, dy]),
    scrollEnd: () => log.push(['se']), click: (b) => log.push(['c', b]), pinchStart: () => log.push(['ps']),
    pinch: (scale) => log.push(['p', scale]), pinchEnd: (scale) => log.push(['pe', scale]),
    dragStart: () => log.push(['ds']), dragEnd: () => log.push(['de']) };
  const touchpad = new Touchpad(out, () => settings);
  // Drives fingers: `at(i)` gives every finger's [x, y] at step i; events every `ms` milliseconds.
  const drive = ({ steps, ms = 16, at, start = 0, end = 'end' }) => {
    let time = start;
    const fingers = (i) => at(i).map(([x, y], id) => ({ id, x, y }));
    for (let n = 1; n <= at(0).length; n++) touchpad.update('start', fingers(0).slice(0, n), time);
    for (let i = 1; i <= steps; i++) { time += ms; touchpad.update('move', fingers(i), time); }
    time += ms;
    if (end) touchpad.update(end, [], time);
    return time;
  };
  return { touchpad, log, drive };
}
const total = (log, kind, i = 1) => Math.round(log.filter((e) => e[0] === kind).reduce((a, e) => a + e[i], 0) * 1e6) / 1e6;

test('a tap clicks and a two-finger tap right-clicks, without moving anything', () => {
  const one = pad();
  one.drive({ steps: 3, ms: 30, at: (i) => [[100 + i, 100]] });
  assert.deepEqual(one.log, [['c', 'left']]);
  const two = pad();
  two.drive({ steps: 3, ms: 30, at: (i) => [[100, 100 + i], [160, 100 + i]] });
  assert.deepEqual(two.log, [['c', 'right']]);
});

test('two fingers that land in one event are two fingers', () => {
  for (const together of [true, false]) {
    const { log, touchpad } = pad();
    touchpad.update('start', [{ id: 0, x: 0, y: 0 }, { id: 1, x: 50, y: 0 }], 0);
    if (together) touchpad.update('end', [], 60);
    else { touchpad.update('end', [{ id: 1, x: 50, y: 0 }], 60); touchpad.update('end', [], 70); }
    assert.deepEqual(log, [['c', 'right']], together ? 'lifted together' : 'lifted one after the other');
  }
  const { log, touchpad } = pad();
  touchpad.update('start', [{ id: 0, x: 0, y: 0 }, { id: 1, x: 50, y: 0 }], 0);
  for (let i = 1; i <= 10; i++) touchpad.update('move', [{ id: 0, x: 0, y: i * 4 }, { id: 1, x: 50, y: i * 4 }], i * 16);
  touchpad.update('end', [], 200);
  assert.ok(log.every((e) => e[0] === 's' || e[0] === 'se'), 'a scroll, no pointer move');
});

test('without a live view to zoom, fingers moving apart scroll', () => {
  const log = [];
  const touchpad = new Touchpad({ move: () => log.push('m'), scroll: () => log.push('s'), scrollEnd: () => log.push('se'),
    click: () => log.push('c'), pinchStart: () => false, pinch: () => log.push('p'), pinchEnd: () => log.push('pe') }, () => defaults);
  touchpad.update('start', [{ id: 0, x: 100, y: 100 }, { id: 1, x: 160, y: 100 }], 0);
  for (let i = 1; i <= 10; i++) touchpad.update('move', [{ id: 0, x: 100 - i * 3, y: 100 + i * 2 }, { id: 1, x: 160 + i * 3, y: 100 + i * 2 }], i * 16);
  touchpad.update('end', [], 200);
  assert.ok(!log.includes('p') && !log.includes('m'));
  assert.deepEqual([log[0], log.at(-1)], ['s', 'se']);
});

test('the dead zone holds only while a tap is possible, and what it held back still arrives', () => {
  const { log, touchpad } = pad();
  touchpad.update('start', [{ id: 0, x: 0, y: 0 }], 0);
  // Resting, then a 5 px nudge long after the tap window.
  for (let i = 1; i <= 10; i++) touchpad.update('move', [{ id: 0, x: i / 2, y: 0 }], TAP_MS + 100 + i * 16);
  touchpad.update('end', [], 600);
  assert.equal(Math.round(total(log, 'm')), 5);
  assert.equal(log.filter((e) => e[0] === 'c').length, 0);
});

test('slow moves are 1:1 and fast ones reach further, whatever the event rate', () => {
  const run = (distance, ms, rate) => {
    const { log, drive } = pad();
    const steps = Math.round(ms * rate / 1000);
    drive({ steps, ms: 1000 / rate, at: (i) => [[10 + distance * i / steps, 0]] });
    return total(log, 'm');
  };
  for (const rate of [60, 120]) {
    assert.ok(Math.abs(run(30, 1000, rate) - 30) < 0.5, `slow at ${rate} Hz`);
    assert.ok(run(250, 150, rate) > 900, `fast at ${rate} Hz`);
  }
  assert.ok(Math.abs(run(250, 150, 60) / run(250, 150, 120) - 1) < 0.05, 'the same path, the same distance');
  assert.ok(Math.abs(run(80, 300, 60) / run(80, 300, 120) - 1) < 0.05);
});

test('pointer speed scales the curve, acceleration 0 makes it linear', () => {
  assert.equal(gain(0.01, defaults), 1);
  assert.equal(gain(5, { speed: 2, acceleration: 0 }), 2);
  assert.ok(gain(0.5, defaults) < gain(1, defaults));
  assert.equal(gain(5, defaults), 4.5);
});

test('a Regler slider maps the finger to a detent: every value reachable, the ends held', () => {
  for (const name of Object.keys(SETTINGS)) {
    const all = detents(name), [min, max] = SETTINGS[name].range;
    assert.deepEqual([all[0], all.at(-1)], [min, max], name);
    assert.ok(all.includes(SETTINGS[name].initial), `${name}: the default is a detent`);
    // Each detent, touched where the slider draws it, gives back that value.
    for (const v of all) assert.equal(settingAt(name, settingFraction(name, v)), v, `${name} ${v}`);
    // A finger beyond either end holds the end; between two detents it takes the nearer one.
    assert.deepEqual([settingAt(name, -0.4), settingAt(name, 1.7)], [min, max], name);
    const gap = 1 / (all.length - 1);
    assert.equal(settingAt(name, gap * 0.4), all[0]);
    assert.equal(settingAt(name, gap * 0.6), all[1]);
    // The keyboard steps one detent and stops at the ends.
    assert.equal(stepSetting(name, min, -1), min);
    assert.equal(stepSetting(name, max, 1), max);
    assert.equal(stepSetting(name, all[1], 1), all[2]);
  }
  assert.equal(settingText('acceleration', 0), 'aus');
  assert.equal(settingText('speed', 1.25), '1,25×');
});

test('each Regler detent changes what the Mac receives', () => {
  const fast = (settings) => {
    const { log, drive } = pad(settings);
    drive({ steps: 9, ms: 1000 / 60, at: (i) => [[10 + 250 * i / 9, 0]] });
    return total(log, 'm');
  };
  const slow = (settings) => {
    const { log, drive } = pad(settings);
    drive({ steps: 60, ms: 1000 / 60, at: (i) => [[10 + 30 * i / 60, 0]] });
    return total(log, 'm');
  };
  const scroll = (settings) => {
    const { log, drive } = pad(settings);
    drive({ steps: 10, at: (i) => [[0, i * 4], [50, i * 4]] });
    return total(log, 's', 2);
  };
  const rises = (name, measure) => {
    const values = detents(name).map((v) => measure({ ...defaults, [name]: v }));
    values.slice(1).forEach((v, i) => assert.ok(v > values[i] * 1.03, `${name}: detent ${i + 1} reaches further (${values[i]} -> ${v})`));
  };
  rises('speed', slow); // pointer speed counts for slow, precise moves too
  rises('acceleration', fast); // acceleration only for fast ones
  rises('scroll', scroll);
  assert.equal(slow({ ...defaults, acceleration: 2 }), slow({ ...defaults, acceleration: 0 }), 'acceleration leaves slow moves 1:1');
});

test('two fingers scroll by their centre, and lifting one ends the scroll without moving the pointer', () => {
  const { log, touchpad } = pad();
  // Each event reports one finger only, as iOS may.
  let time = 0;
  touchpad.update('start', [{ id: 0, x: 0, y: 0 }], time);
  touchpad.update('start', [{ id: 0, x: 0, y: 0 }, { id: 1, x: 50, y: 0 }], time);
  for (let i = 1; i <= 20; i++) {
    time += 8;
    touchpad.update('move', [{ id: 0, x: 0, y: Math.ceil(i / 2) * 4 }, { id: 1, x: 50, y: Math.floor(i / 2) * 4 }], time);
  }
  touchpad.update('end', [{ id: 0, x: 0, y: 40 }], time + 8);
  for (let i = 1; i <= 10; i++) touchpad.update('move', [{ id: 0, x: 0, y: 40 + i * 5 }], time + 8 + i * 8);
  touchpad.update('end', [], time + 100);
  assert.equal(total(log, 's', 2), 40 * 1.6);
  assert.deepEqual(log.filter((e) => e[0] !== 's'), [['se']]);
});

test('a small, slow scroll is not lost, and a cancelled one ends', () => {
  const slow = pad();
  slow.drive({ steps: 4, ms: 80, at: (i) => [[0, i], [50, i]] });
  assert.equal(total(slow.log, 's', 2), 4 * 1.6);
  assert.equal(slow.log.at(-1)[0], 'se');
  const cancelled = pad();
  cancelled.drive({ steps: 10, at: (i) => [[0, i * 4], [50, i * 4]], end: 'cancel' });
  assert.deepEqual(cancelled.log.at(-1), ['se']);
  assert.equal(cancelled.log.filter((e) => e[0] === 'c').length, 0);
});

test('scroll speed is a setting of its own', () => {
  const { log, drive } = pad({ ...defaults, speed: 2, scroll: 2 });
  drive({ steps: 10, at: (i) => [[0, i * 4], [50, i * 4]] });
  assert.equal(total(log, 's', 2), 40 * 1.6 * 2);
});

test('fingers moving apart pinch instead of scrolling, and nothing else is sent', () => {
  const { log, drive } = pad();
  drive({ steps: 20, at: (i) => [[100 - i * 5, 100 - i * 5], [160 + i * 5, 160 + i * 5]] });
  assert.equal(log[0][0], 'ps');
  assert.ok(log.every((e) => ['ps', 'p', 'pe'].includes(e[0])), JSON.stringify(log.slice(0, 4)));
  const [, scale] = log.at(-1);
  assert.ok(Math.abs(scale - (60 * Math.SQRT2 + 200 * Math.SQRT2) / (60 * Math.SQRT2)) < 0.01);
});

test('a scroll that changes direction follows it', () => {
  const { log, drive } = pad();
  drive({ steps: 30, at: (i) => [[0, i <= 15 ? i * 4 : 120 - i * 4], [50, i <= 15 ? i * 4 : 120 - i * 4]] });
  const signs = log.filter((e) => e[0] === 's' && e[2]).map((e) => Math.sign(e[2]));
  assert.deepEqual([...new Set(signs)], [1, -1]);
  assert.equal(total(log, 's', 2), 0);
});

test('a finger resting on another control does not turn a move into a scroll', () => {
  // touches are the pad's own (targetTouches): a finger holding "Links" is not among them.
  const { log, drive } = pad();
  drive({ steps: 10, at: (i) => [[i * 4, 0]] });
  assert.ok(log.every((e) => e[0] === 'm'));
});

test('three fingers drag: the button is held while they move and released when one lifts', () => {
  const { log, touchpad } = pad();
  const three = (dy) => [{ id: 0, x: 0, y: dy }, { id: 1, x: 40, y: dy }, { id: 2, x: 80, y: dy }];
  touchpad.update('start', three(0).slice(0, 1), 0);
  touchpad.update('start', three(0).slice(0, 2), 5);
  touchpad.update('start', three(0), 10);
  // Slowly, so the pointer follows 1:1.
  for (let i = 1; i <= 10; i++) touchpad.update('move', three(i * 3), 10 + i * 60);
  touchpad.update('end', three(30).slice(0, 2), 700);
  touchpad.update('move', three(40).slice(0, 2), 716);
  touchpad.update('end', [], 730);
  assert.deepEqual([log[0], log.at(-1)], [['ds'], ['de']]);
  assert.ok(log.slice(1, -1).every((e) => e[0] === 'm'), 'only pointer moves in between');
  assert.equal(Math.round(total(log, 'm', 2)), 30);
  assert.equal(log.filter((e) => e[0] === 'c' || e[0] === 's').length, 0);
});

test('three fingers that rest send nothing, and a cancelled drag lets go of the button', () => {
  const still = pad();
  still.drive({ steps: 5, at: () => [[0, 0], [40, 0], [80, 0]] });
  assert.deepEqual(still.log, []);
  const cancelled = pad();
  cancelled.drive({ steps: 10, at: (i) => [[0, i * 3], [40, i * 3], [80, i * 3]], end: 'cancel' });
  assert.deepEqual([cancelled.log[0], cancelled.log.at(-1)], [['ds'], ['de']]);
});

test('the text field relays characters, graphemes and corrections', () => {
  assert.deepEqual(diff(SENTINEL, `${SENTINEL}Grüße`), { removed: 0, added: 'Grüße' });
  assert.deepEqual(diff(`${SENTINEL}a👋🏽`, `${SENTINEL}a`), { removed: 1, added: '' }, 'one backspace for an emoji with a skin tone');
  assert.deepEqual(diff(`${SENTINEL}teh`, `${SENTINEL}the`), { removed: 2, added: 'he' }, 'autocorrect replaces the end');
  assert.deepEqual(diff(SENTINEL, ''), { removed: 1, added: '' }, 'backspace in an empty field');
});

test('the page is laid out into the visible part, also when iOS shifts it for the keyboard', () => {
  const layout = { width: 390, height: 844 };
  assert.deepEqual(frame(layout, null), { top: 0, height: 844, keyboard: false, zoomed: false });
  assert.deepEqual(frame(layout, { height: 844, offsetTop: 0, scale: 1 }), { top: 0, height: 844, keyboard: false, zoomed: false });
  assert.deepEqual(frame(layout, { height: 500, offsetTop: 120, scale: 1 }), { top: 120, height: 500, keyboard: true, zoomed: false });
  // The shortcut bar of an external keyboard is no on-screen keyboard.
  assert.equal(frame(layout, { height: 844 - KEYBOARD_MIN + 20, offsetTop: 0, scale: 1 }).keyboard, false);
  // Zoomed in with two fingers: the page keeps its size, so the zoom magnifies it.
  assert.deepEqual(frame(layout, { height: 300, offsetTop: 200, scale: 2.5 }), { top: 0, height: 844, keyboard: false, zoomed: true });
});

// ---- The switcher (apps.js)
const app = (windows, more = {}) => ({ pid: 412, name: 'Safari', icon: 'com.apple.Safari', front: false, hidden: false,
  windows: windows.map((title, i) => ({ id: 7 + i, title, min: false, main: i === 0 })), ...more });

test('a tap on an app brings it to the front at once, unless there are windows to choose from', () => {
  assert.deepEqual(tapApp(app([])), { t: 'focus', pid: 412 }, 'no window known: as a click in the Dock');
  assert.deepEqual(tapApp(app(['Start'])), { t: 'focus', pid: 412, win: 7 }, 'one window: that one, also out of the Dock');
  assert.equal(tapApp(app(['Start', 'Docs'])), null, 'several windows: the user chooses');
  assert.deepEqual(tapWindow(app(['Start', 'Docs']), { id: 8 }), { t: 'focus', pid: 412, win: 8 });
});

test('a window without a title is named after its app, and a tile says what a tap will do', () => {
  assert.equal(windowTitle(app(['  ']), { title: '  ' }), 'Safari');
  assert.equal(windowTitle(app(['Docs']), { title: ' Docs ' }), 'Docs');
  assert.equal(appLabel(app([])), 'Safari');
  assert.equal(appLabel(app(['Start'], { front: true })), 'Safari, im Vordergrund');
  assert.equal(appLabel(app(['Start', 'Docs', 'Mail'])), 'Safari, 3 Fenster zur Auswahl');
  assert.equal(appLabel(app(['Start', 'Docs'], { front: true, hidden: true })), 'Safari, 2 Fenster zur Auswahl, im Vordergrund, ausgeblendet');
});

test('only a list of the expected shape is shown', () => {
  const list = [app(['Start', 'Docs'], { front: true }), app([], { pid: 9, name: 'Finder', icon: 'com.apple.finder' })];
  assert.deepEqual(readApps({ t: 'apps', list }), list);
  assert.deepEqual(readApps({ t: 'apps', list: [] }), []);
  for (const broken of [{ t: 'apps' }, { t: 'apps', list: 'x' }, { t: 'apps', list: [{ pid: 1 }] },
    { t: 'apps', list: [{ ...list[0], windows: [{ id: 'a', title: 'x' }] }] }, { t: 'apps', list: [{ ...list[0], pid: '412' }] }]) {
    assert.equal(readApps(broken), null, JSON.stringify(broken));
  }
});
