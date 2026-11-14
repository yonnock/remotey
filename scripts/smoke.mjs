// Smoke test against a running agent: HTTP page, auth, pointer movement, live view flow control.
// Usage: node scripts/smoke.mjs [--h264] [--fps=120] [--capture=/tmp/view.h264]   (moves the cursor a little and back; sends no keystrokes)
// Close Remotey on the phone first: the most recent viewer gets the live view, so an open phone takes it back.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';

const HTTP = 'http://127.0.0.1:47800', WS = 'ws://127.0.0.1:47801/ws';
const codec = process.argv.includes('--h264') ? 'h264' : 'jpeg';
const fps = Number(process.argv.find((arg) => arg.startsWith('--fps='))?.slice(6) || 60);
const capture = process.argv.find((arg) => arg.startsWith('--capture='))?.slice(10);
const packets = [];
const token = readFileSync(`${homedir()}/Library/Application Support/Remotey/token`, 'utf8').trim();
const fail = (msg) => { console.error('FAIL', msg); process.exit(1); };
if (capture && codec !== 'h264') fail('--capture requires --h264');
if (!Number.isInteger(fps) || fps < 30 || fps > 120) fail('--fps must be an integer from 30 to 120');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const cursorX = () => +execFileSync('osascript', ['-l', 'JavaScript', '-e', 'ObjC.import("AppKit"); $.NSEvent.mouseLocation.x']);

const page = await fetch(`${HTTP}/`);
if (page.status !== 200 || !(await page.text()).includes('<title>Remotey</title>')) fail('page');
const icon = await fetch(`${HTTP}/icon.png`);
if (icon.status !== 200 || (await icon.arrayBuffer()).byteLength < 500) fail('icon');
if ((await fetch(`${HTTP}/etc/passwd`)).status !== 404) fail('404');
const decoderModule = await fetch(`${HTTP}/live-view.js`);
if (decoderModule.status !== 200 || !decoderModule.headers.get('content-type')?.startsWith('text/javascript')
    || !(await decoderModule.text()).includes('export class LiveView')) fail('decoder module');
console.log('ok   http: page, decoder module, icon, 404');

/** Opens a socket and sends `first`; resolves with the first reply, or null once the socket closed without one. */
function open(first) {
  const ws = new WebSocket(WS);
  ws.binaryType = 'arraybuffer';
  const closed = new Promise((r) => { ws.onclose = () => r(null); });
  const reply = new Promise((r) => { ws.onmessage = (e) => r(JSON.parse(e.data)); });
  ws.onopen = () => ws.send(JSON.stringify(first));
  return { ws, closed, reply: Promise.race([reply, closed]) };
}
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
const send = (msg) => good.ws.send(JSON.stringify(msg));

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
// Two until the first answer. After that the agent allows for the time an answer takes, up to six pictures.
const MAX_IN_FLIGHT = 2, MAX_WINDOW = 6, HEADER = 20;
let frames = 0, bytes = 0, acking = false, denied = false, held = [], expectKey = true, keyFrames = 0, cursors = 0, moves = 0;
const shown = (frame) => send({ t: 'shown', n: new DataView(frame).getUint32(8, true) });
good.ws.onmessage = (e) => {
  if (typeof e.data === 'string') {
    const m = JSON.parse(e.data);
    if (m.t === 'cursor') {
      if (!(m.w > 0 && m.h > 0 && m.x >= 0 && m.y >= 0) || !Buffer.from(m.png, 'base64').subarray(1, 4).equals(Buffer.from('PNG'))) fail('pointer picture');
      cursors++;
    } else denied = m.ok === false;
    return;
  }
  const head = new DataView(e.data);
  if (!(head.getFloat32(16, true) > 0)) fail('message without the width of the picture');
  // The pointer moved inside the view: no picture, no answer expected.
  if (e.data.byteLength === HEADER) { if (head.getUint32(8, true) !== 0) fail('numbered message without a picture'); moves++; return; }
  if (codec === 'h264') {
    if (head.getUint16(HEADER) === 0xffd8) fail('agent sent JPEG instead of H.264');
    if (expectKey && head.getUint8(HEADER + 3) !== 1) fail('new H.264 stream did not start with an IDR');
    expectKey = false;
    if (head.getUint8(HEADER + 3) === 1) keyFrames++;
    if (head.getUint32(HEADER + 4) !== 1) fail('H.264 payload is not Annex B');
    if (capture) packets.push(Buffer.from(e.data, HEADER + 4));
  } else if (head.getUint16(HEADER) !== 0xffd8) fail('agent did not send the requested JPEG fallback');
  frames++;
  bytes += e.data.byteLength;
  if (acking) shown(e.data); else held.push(e.data);
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
    // An out-of-order answer releases only that frame, not every earlier reference picture.
    // It comes more than a second late, so the window opens all the way: one picture answered, the first still not.
    const later = held.at(-1);
    shown(later);
    send({ t: 'shown', n: new DataView(later).getUint32(8, true) + 1000 });
    await stir();
    shown(later); // duplicate answers cannot create more send credit
    await stir();
    if (frames > MAX_WINDOW + 1) fail(`duplicate, future, or out-of-order answers bypassed the frame window: ${frames} frames`);
    console.log(`ok   view: answers release only their own frame (${frames} frames, at most ${MAX_WINDOW} unanswered)`);
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
good.ws.close();
if (capture) writeFileSync(capture, Buffer.concat(packets));
