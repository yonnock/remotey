// Smoke test against a running agent: HTTP page, auth, pointer movement, live view flow control.
// Usage: node scripts/smoke.mjs   (moves the cursor a little and back; sends no keystrokes)
// Close Remotey on the phone first: the most recent viewer gets the live view, so an open phone takes it back.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

const HTTP = 'http://127.0.0.1:47800', WS = 'ws://127.0.0.1:47801/ws';
const token = readFileSync(`${homedir()}/Library/Application Support/Remotey/token`, 'utf8').trim();
const fail = (msg) => { console.error('FAIL', msg); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const cursorX = () => +execFileSync('osascript', ['-l', 'JavaScript', '-e', 'ObjC.import("AppKit"); $.NSEvent.mouseLocation.x']);

const page = await fetch(`${HTTP}/`);
if (page.status !== 200 || !(await page.text()).includes('<title>Remotey</title>')) fail('page');
const icon = await fetch(`${HTTP}/icon.png`);
if (icon.status !== 200 || (await icon.arrayBuffer()).byteLength < 500) fail('icon');
if ((await fetch(`${HTTP}/etc/passwd`)).status !== 404) fail('404');
console.log('ok   http: page, icon, 404');

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
const MAX_IN_FLIGHT = 2;
let frames = 0, acking = false, denied = false, held = [];
const shown = (frame) => send({ t: 'shown', n: new DataView(frame).getUint32(8, true) });
good.ws.onmessage = (e) => {
  if (typeof e.data === 'string') { denied = JSON.parse(e.data).ok === false; return; }
  frames++;
  if (acking) shown(e.data); else held.push(e.data);
};
/** Moves the cursor in circles for a second so the screen keeps changing; ends where it started. */
async function stir() {
  for (let i = 0; i < 60; i++) {
    const a = (i / 20) * 2 * Math.PI, b = ((i + 1) / 20) * 2 * Math.PI;
    send({ t: 'm', dx: 30 * (Math.cos(b) - Math.cos(a)), dy: 30 * (Math.sin(b) - Math.sin(a)) });
    await sleep(16);
  }
  await sleep(200);
}
send({ t: 'view', on: true, w: 390, h: 844, zoom: 0.5, dpr: 3 });
await stir();
if (denied) {
  console.log('skip view: no Screen Recording permission');
} else {
  if (frames < 1 || frames > MAX_IN_FLIGHT) fail(`${frames} frames without a "shown", expected 1 to ${MAX_IN_FLIGHT}`);
  console.log(`ok   view: stream waits after ${frames} unanswered frames`);
  if (hello.ax) {
    acking = true;
    held.forEach(shown);
    await stir();
    if (frames < 10) fail(`only ${frames} frames while answering each one`);
    console.log(`ok   view: stream runs while frames are answered (${frames} frames)`);
    // Frames captured while the view switches off are never answered; the next view must not wait for them.
    acking = false;
    send({ t: 'view', on: false });
    await stir();
    frames = 0;
    acking = true;
    send({ t: 'view', on: true, w: 390, h: 844, zoom: 0.5, dpr: 3 });
    await stir();
    if (frames < 10) fail(`only ${frames} frames after switching the view off and on`);
    console.log(`ok   view: stream runs again after off and on (${frames} frames)`);
  }
}
good.ws.close();
