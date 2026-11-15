// Smoke test against a running agent: HTTP page, auth, pointer movement, live view flow control.
// Usage: node scripts/smoke.mjs [--h264] [--fps=120] [--capture=/tmp/view.h264]   (moves the cursor a little and back; sends no keystrokes)
// Close Remotey on the phone first: the most recent viewer gets the live view, so an open phone takes it back.
import { writeFileSync } from 'node:fs';
import { H264, JPEG, POINTER, parseH264, parseUpdate } from '../Web/live-view.js';
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
for (const name of ['touchpad.js', 'viewport.js', 'typing.js', 'live-view.js']) files.push([name, 'js']); // imported by remote.js
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
const shown = (n) => send({ t: 'shown', n });
good.onMessage = (e) => {
  if (typeof e.data === 'string') {
    const m = JSON.parse(e.data);
    if (m.t === 'cursor') {
      if (!(m.w > 0 && m.h > 0 && m.x >= 0 && m.y >= 0) || !Buffer.from(m.png, 'base64').subarray(1, 4).equals(Buffer.from('PNG'))) fail('pointer picture');
      cursors++;
    } else if (m.t === 'view') denied = m.ok === false;
    return;
  }
  const update = parseUpdate(e.data);
  if (!(update.width > 0)) fail('update without the width of the picture');
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
  }
}
good.close();
if (capture) writeFileSync(capture, Buffer.concat(packets));
