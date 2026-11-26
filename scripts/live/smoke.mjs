// Smoke test against a running agent: HTTP page, auth, pointer movement, live view flow control.
// Usage: node scripts/live/smoke.mjs --live [--h264] [--fps=120] [--capture=/tmp/view.h264] [--focus] [--display]   (moves the cursor a little and back; sends no keystrokes)
// --focus also brings another app's window to the front and the one that was in front back, so what you see changes for two seconds.
// --display also puts the pointer on another display and back to where it was, on a Mac with more than one.
// Close Remotey on the phone first: the most recent viewer gets the live view, so an open phone takes it back.
import './guard.mjs'; // first: refuses without --live
import { writeFileSync } from 'node:fs';
import { Ahead, H264, JPEG, POINTER, parseH264, parseUpdate } from '../../Web/live-view.js';
import { HTTP, fail, open, pointer, sleep, token } from './agent.mjs';

const codec = process.argv.includes('--h264') ? 'h264' : 'jpeg';
const fps = Number(process.argv.find((arg) => arg.startsWith('--fps='))?.slice(6) || 60);
const capture = process.argv.find((arg) => arg.startsWith('--capture='))?.slice(10);
const packets = [];
if (capture && codec !== 'h264') fail('--capture requires --h264');
if (!Number.isInteger(fps) || fps < 30 || fps > 120) fail('--fps must be an integer from 30 to 120');
const cursorX = () => pointer()[0];

const page = await fetch(`${HTTP}/`);
if (page.status !== 200 || !(await page.text()).includes('<title>Remotey</title>')) fail('page');
const icon = await fetch(`${HTTP}/icon.png`);
if (icon.status !== 200 || (await icon.arrayBuffer()).byteLength < 500) fail('icon');
if ((await fetch(`${HTTP}/etc/passwd`)).status !== 404) fail('404');
const html = await (await fetch(`${HTTP}/`)).text();
// Every file the page names, with the type it needs: a stylesheet served as text/plain is not applied.
const files = [...html.matchAll(/(?:src|href)="\/?([\w.-]+\.(js|css|png))"/g)].map(([, name, ext]) => [name, ext]);
for (const name of ['touchpad.js', 'viewport.js', 'typing.js', 'live-view.js', 'apps.js', 'displays.js']) files.push([name, 'js']); // imported by remote.js
const types = { js: 'text/javascript', css: 'text/css', png: 'image/png' };
for (const [name, ext] of files) {
  const response = await fetch(`${HTTP}/${name}`);
  if (response.status !== 200 || !response.headers.get('content-type')?.startsWith(types[ext])) fail(`${name}: ${response.status} ${response.headers.get('content-type')}`);
}
if (!files.some(([n]) => n === 'remote.css') || !files.some(([n]) => n === 'remote.js')) fail('page names no stylesheet or script');
const csp = page.headers.get('content-security-policy') ?? '';
if (csp.includes('unsafe-inline') || !csp.includes("script-src 'self'")) fail(`content security policy: ${csp}`);
console.log(`ok   http: page, ${files.length} files with their types, icon, 404, no inline code allowed`);

const within = (promise, ms) => Promise.race([promise.then(() => true), sleep(ms).then(() => false)]);

const bad = open({ t: 'auth', token: 'wrong-token' });
if ((await bad.reply)?.t !== 'denied' || !(await within(bad.closed, 1000))) fail('wrong token not denied and closed');
console.log('ok   ws: wrong token denied and closed');

const anon = open({ t: 'm', dx: 500, dy: 500 });
if (!(await within(anon.closed, 1000))) fail('unauthenticated input not closed');
console.log('ok   ws: input without auth closes the connection');

const good = open({ t: 'auth', token });
const hello = await good.reply;
if (hello?.t !== 'ok') fail(`auth failed: ${JSON.stringify(hello)}`);
console.log(`ok   ws: authenticated, accessibility=${hello.ax}`);
const send = good.send;

if (hello.ax) {
  const start = cursorX();
  let dx = 40;
  send({ t: 'm', dx, dy: 0 });
  await sleep(300);
  if (cursorX() === start) { // at the right screen edge: try the other direction
    dx = -40;
    send({ t: 'm', dx, dy: 0 });
    await sleep(300);
  }
  if (Math.abs(cursorX() - start - dx) > 1) fail(`cursor moved ${cursorX() - start}pt instead of ${dx}pt`);
  send({ t: 'm', dx: -dx, dy: 0 });
  console.log('ok   input: cursor follows a move');
} else {
  console.log('skip input: no Accessibility permission');
}

// Live view: the agent may only have a bounded number of frames under way until the client reports
// them shown. Otherwise frames pile up in buffers on a slow link and the picture lags behind.
// Two until the first answer. After that pictures leave while the oldest one under way is younger than the
// fastest answer plus SLACK seconds (SendWindow.swift).
const MAX_IN_FLIGHT = 2, SLACK = 0.2;
let frames = 0, bytes = 0, acking = false, denied = false, held = [], expectKey = true, keyFrames = 0, cursors = 0;
let apps = null, lists = 0, displays = null, fitted = 0, unfitted = 0, fitWidth = 0, onUpdate = null, asked = 0;
const icons = new Map();
const shown = (n) => send({ t: 'shown', n });
good.onMessage = (e) => {
  if (typeof e.data === 'string') {
    const m = JSON.parse(e.data);
    if (m.t === 'cursor') {
      if (!(m.w > 0 && m.h > 0 && m.x >= 0 && m.y >= 0) || !Buffer.from(m.png, 'base64').subarray(1, 4).equals(Buffer.from('PNG'))) fail('pointer picture');
      cursors++;
    } else if (m.t === 'view') denied = m.ok === false;
    else if (m.t === 'apps') { apps = m.list; lists++; }
    else if (m.t === 'displays') displays = m.list;
    else if (m.t === 'icon') {
      if (!Buffer.from(m.png, 'base64').subarray(1, 4).equals(Buffer.from('PNG'))) fail(`icon ${m.id} is no PNG`);
      icons.set(m.id, (icons.get(m.id) ?? 0) + 1);
    }
    return;
  }
  const update = parseUpdate(e.data);
  if (!(update.width > 0) || !(update.height > 0)) fail('update without the size of the view');
  onUpdate?.(update);
  // The pointer moved inside the view: no picture, no answer expected.
  if (update.kind === POINTER) { if (update.picture.length) fail('pointer update with a picture'); return; }
  if (update.kind !== (codec === 'h264' ? H264 : JPEG)) fail(`agent sent a picture of kind ${update.kind} instead of ${codec}`);
  if (codec === 'h264') {
    const { key, data } = parseH264(update.picture);
    if (expectKey && !key) fail('new H.264 stream did not start with an IDR');
    expectKey = false;
    if (key) keyFrames++;
    if (Buffer.from(data.subarray(0, 4)).readUInt32BE() !== 1) fail('H.264 payload is not Annex B');
    if (capture) packets.push(Buffer.from(data));
  } else if (Buffer.from(update.picture.subarray(0, 2)).readUInt16BE() !== 0xffd8) fail('JPEG picture without its marker');
  frames++;
  // Only pictures cut for the newest request count: one of the request before may still be under way.
  if (update.v === asked) { if (update.fitted) { fitted++; fitWidth = update.width; } else unfitted++; }
  bytes += e.data.byteLength;
  if (acking) shown(update.n); else held.push(update.n);
};
/** Moves the cursor in circles for a second so the screen keeps changing; ends where it started. */
async function stir() {
  for (let i = 0; i < fps; i++) {
    const a = (i / fps) * 6 * Math.PI, b = ((i + 1) / fps) * 6 * Math.PI;
    send({ t: 'm', dx: 30 * (Math.cos(b) - Math.cos(a)), dy: 30 * (Math.sin(b) - Math.sin(a)) });
    await sleep(1000 / fps);
  }
  await sleep(200);
}
// The switcher: the list of open apps comes at once, every icon after it and once per connection.
const list = async () => { const n = lists; send({ t: 'apps' }); for (let i = 0; i < 40 && lists === n; i++) await sleep(50); if (lists === n) fail('no list of apps'); return apps; };
await list();
await sleep(1000);
if (!apps.some((a) => a.icon === 'com.apple.finder')) fail('the list of apps lacks the Finder');
if (!apps.every((a) => a.pid > 0 && a.name && Array.isArray(a.windows))) fail('an app without pid, name or windows');
if (!apps.every((a) => icons.get(a.icon) === 1)) fail('not every app got its icon once');
await list();
await sleep(300);
if ([...icons.values()].some((n) => n !== 1)) fail('an icon was sent twice');
console.log(`ok   apps: ${apps.length} apps with ${apps.reduce((n, a) => n + a.windows.length, 0)} windows, each icon once${hello.ax ? '' : ' (no windows without Accessibility)'}`);
if (process.argv.includes('--focus')) {
  // A window of another app, so nothing new opens; then the window that was in front.
  const before = apps.find((a) => a.front), other = apps.find((a) => !a.front && !a.hidden && a.windows.some((w) => !w.min));
  if (!other) console.log('skip focus: no other app with a window on this Space');
  else {
    send({ t: 'focus', pid: other.pid, win: other.windows.find((w) => !w.min).id });
    await sleep(1000);
    if ((await list()).find((a) => a.front)?.pid !== other.pid) fail('the app asked for did not come to the front');
    if (before) {
      send({ t: 'focus', pid: before.pid, win: before.windows.find((w) => w.main)?.id });
      await sleep(1000);
      if ((await list()).find((a) => a.front)?.pid !== before.pid) fail('the app that was in front did not come back');
    }
    console.log('ok   apps: a window of another app comes to the front, and the one before comes back');
  }
}

// The display picker: every display with its place, one of them with the pointer.
const places = async () => { displays = null; send({ t: 'displays' }); for (let i = 0; i < 40 && !displays; i++) await sleep(50); if (!displays) fail('no list of displays'); return displays; };
await places();
if (!displays.length || !displays.every((d) => Number.isInteger(d.id) && d.name && d.w > 0 && d.h > 0)) fail('a display without id, name or size');
if (displays.filter((d) => d.pointer).length !== 1) fail('the pointer is on no display, or on several');
console.log(`ok   displays: ${displays.map((d) => `${d.name} ${d.w}×${d.h}`).join(', ')}`);
if (process.argv.includes('--display')) {
  const home = displays.find((d) => d.pointer), other = displays.find((d) => !d.pointer);
  if (!other || !hello.ax) console.log(`skip display: ${other ? 'no Accessibility permission' : 'one display'}`);
  else {
    const [x, y] = pointer();
    send({ t: 'display', id: other.id });
    await sleep(400);
    if ((await places()).find((d) => d.pointer)?.id !== other.id) fail('the pointer did not go to the display asked for');
    send({ t: 'display', id: home.id });
    await sleep(400);
    const [bx, by] = pointer();
    if ((await places()).find((d) => d.pointer)?.id !== home.id || Math.abs(bx - x) > 1 || Math.abs(by - y) > 1) fail(`the pointer came back to ${bx}, ${by} instead of ${x}, ${y}`);
    console.log(`ok   displays: the pointer goes to "${other.name}" and back to where it left "${home.name}"`);
  }
}

send({ t: 'view', on: true, w: 390, h: 844, zoom: 0.5, dpr: 3, codec, fps });
await stir();
if (denied) {
  console.log('skip view: no Screen Recording permission');
} else {
  if (frames < 1 || frames > MAX_IN_FLIGHT) fail(`${frames} frames without a "shown", expected 1 to ${MAX_IN_FLIGHT}`);
  console.log(`ok   view: stream waits after ${frames} unanswered frames`);
  if (cursors < 1) fail('no pointer picture for a new view');
  console.log('ok   view: pointer picture arrives separately');
  if (hello.ax) {
    // An out-of-order answer releases only that frame, not every earlier reference picture. It comes more than a
    // second late, which allows for answers that slow: pictures leave until the unanswered first one is older than
    // that answer took plus the slack, then the stream waits for it.
    const later = held.at(-1);
    shown(later);
    send({ t: 'shown', n: later + 1000 });
    await stir();
    const released = frames;
    shown(later); // duplicate answers cannot create more send credit
    await stir();
    if (frames > released) fail(`a duplicate answer released ${frames - released} more frames`);
    // At most the two before, and the slack's worth of frames with a few for timer jitter.
    const most = MAX_IN_FLIGHT + Math.ceil(SLACK * fps) + 4;
    if (frames > most) fail(`future or out-of-order answers bypassed the frame window: ${frames} frames, expected at most ${most}`);
    console.log(`ok   view: answers release only their own frame (${frames} frames, then none while the oldest stays unanswered)`);
    acking = true;
    held.forEach(shown);
    const startFrames = frames, startBytes = bytes, startTime = performance.now();
    await stir();
    const seconds = (performance.now() - startTime) / 1000;
    console.log(`info ${codec} (requested ${fps} fps): received ${((frames - startFrames) / seconds).toFixed(1)} fps, ${((bytes - startBytes) * 8 / seconds / 1e6).toFixed(2)} Mbit/s (includes 200ms idle)`);
    if (frames < 10) fail(`only ${frames} frames while answering each one`);
    console.log(`ok   view: stream runs while frames are answered (${frames} frames)`);
    // Frames captured while the view switches off are never answered; the next view must not wait for them.
    acking = false;
    send({ t: 'view', on: false });
    await stir();
    frames = 0;
    expectKey = true;
    acking = true;
    send({ t: 'view', on: true, w: 390, h: 844, zoom: 0.5, dpr: 3, codec, fps });
    await stir();
    if (frames < 10) fail(`only ${frames} frames after switching the view off and on`);
    console.log(`ok   view: stream runs again after off and on (${frames} frames)`);
    const beforeResize = frames, keysBeforeResize = keyFrames;
    send({ t: 'view', on: true, w: 420, h: 700, zoom: 1, dpr: 2, codec, fps });
    await stir();
    if (frames - beforeResize < 10) fail('stream stalled after resize');
    if (codec === 'h264' && keyFrames === keysBeforeResize) fail('resized H.264 stream has no new IDR');
    console.log('ok   view: resize continues with a fresh stream');
    // "Auto": the agent picks the region, the window in front, whole. With no such window (the Finder's desktop
    // in front) the pictures come as asked for by zoom, and say so.
    fitted = unfitted = 0;
    send({ t: 'view', on: true, w: 390, h: 844, zoom: 1, dpr: 2, codec, fps, fit: 'window', v: ++asked });
    await stir();
    if (fitted + unfitted < 10) fail('stream stalled when asked to fit the window in front');
    if (fitted && unfitted > 2) fail(`${unfitted} pictures not fitted among ${fitted} fitted ones`);
    // As wide as the window or wider (then its height limits), and never magnified beyond 2x.
    if (fitted && fitWidth < 390 / 2 - 1) fail(`fitted view of ${fitWidth} points: more than 2x`);
    console.log(fitted ? `ok   view: fitted to the window in front, ${Math.round(fitWidth)} points across (${(390 / fitWidth).toFixed(2)}x)`
      : 'ok   view: no window in front to fit, the view keeps its zoom');
    fitted = 0;
    send({ t: 'view', on: true, w: 390, h: 844, zoom: 1, dpr: 2, codec, fps, v: ++asked });
    await stir();
    if (fitted) fail('pictures still fitted after the page took the zoom back');
    console.log('ok   view: back to the zoom set by hand');

    // The pointer the page draws ahead of the Mac (`Ahead`): the place an update names and the moves it does not
    // include yet lead to where the pointer ends up, whichever update that is. So the pointer on the page
    // neither jumps back nor ahead when an answer arrives.
    const ahead = Object.assign(new Ahead(), { displays: await places() });
    const leads = [];
    let last = null, number = 1000;
    const place = (update) => [update.left + update.x * update.width, update.top + update.y * update.height];
    const onMac = (update) => { const at = ahead.onMac(update); return at ? [at.x, at.y] : place(update); };
    onUpdate = (update) => { last = update; leads.push({ q: update.q, sent: number, to: onMac(update) }); };
    const settled = async () => { for (let i = 0; i < 40 && last?.q !== number; i++) await sleep(50); if (last?.q !== number) fail('no update names the last move sent'); };
    const differ = (a, b) => Math.abs(a[0] - b[0]) > 0.51 || Math.abs(a[1] - b[1]) > 0.51;
    send({ t: 'm', dx: 1, dy: 0, q: ++number }); // for an update that names where the pointer is
    await settled();
    const from = place(last);
    // Whole points, as the page sends them, a few milliseconds apart: updates arrive while moves are under way,
    // and each leads to where the moves sent by then take the pointer.
    leads.length = 0;
    const after = new Map([[number, from]]);
    for (let i = 0; i < 120; i++) {
      const [dx, dy] = [i % 2 ? 4 : 1, i % 3 ? -2 : 1], was = after.get(number);
      ahead.moved(++number, dx, dy);
      after.set(number, [was[0] + dx, was[1] + dy]);
      send({ t: 'm', dx, dy, q: number });
      if (i % 4 === 3) await sleep(3);
    }
    await settled();
    const off = leads.find((lead) => differ(lead.to, after.get(lead.sent)));
    if (off) fail(`an update that includes move ${off.q} of ${off.sent} sent leads to ${off.to} instead of ${after.get(off.sent)}`);
    const stages = new Set(leads.map((lead) => lead.q)).size, under = leads.filter((lead) => lead.q !== lead.sent).length;
    if (differ(place(last), after.get(number))) fail(`the pointer is at ${place(last)} instead of ${after.get(number)}`);
    const [px, py] = pointer(), main = ahead.displays.find((d) => d.x === 0 && d.y === 0);
    if (Math.abs(place(last)[0] - px) > 1 || (main && Math.abs(place(last)[1] - (main.h - py)) > 1)) fail(`the updates name ${place(last)}, the Mac has the pointer at ${px}, ${main.h - py}`);
    // Against the edge of the desktop, all at once: the Mac holds the pointer there, and so does the page.
    leads.length = 0;
    for (let i = 0; i < 4; i++) { ahead.moved(++number, -5000, 0); send({ t: 'm', dx: -5000, dy: 0, q: number }); }
    await settled();
    const edge = place(last), wrong = leads.find((lead) => differ(lead.to, edge));
    if (wrong) fail(`against the edge, an update that includes move ${wrong.q} leads to ${wrong.to} instead of ${edge}`);
    // A move that leaves the pointer where it is, at the edge, is answered too: else the page would add it to
    // the next place the Mac names, wherever the Mac's own mouse has put the pointer by then.
    ahead.moved(++number, -5000, 0);
    send({ t: 'm', dx: -5000, dy: 0, q: number });
    await settled();
    if (differ(place(last), edge)) fail(`pushed against the edge, the pointer went to ${place(last)}`);
    const back = [Math.round(from[0] - 1 - edge[0]), Math.round(from[1] - edge[1])];
    ahead.moved(++number, ...back);
    send({ t: 'm', dx: back[0], dy: back[1], q: number });
    await settled();
    console.log(`ok   view: the pointer drawn ahead is where the Mac puts it (${stages} updates of 120 moves, ${under} with moves under way; `
      + `held at the edge at ${edge.map(Math.round)}), and is back where it was`);
    onUpdate = null;
  }
}
good.close();
if (capture) writeFileSync(capture, Buffer.concat(packets));
