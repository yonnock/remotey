// Measures the live view of a running agent: delay from a pointer move to the message that shows it,
// delivered frame rate, CPU time, and whether a burst of pointer moves arrives complete.
// Usage: node scripts/live/bench.mjs --live [--fps=120] [--size=366x420] [--move-rate=240] [--ack-delay=30 | --link=wifi | --link=relay | --link=3mbit | --link=relay,3mbit] [--jpeg] [--still] [--seconds=8]
// Moves the pointer for about 20 seconds and puts it back. --still leaves the pointer alone and measures the stream
// for 8 seconds only, or --seconds: meant for an agent started with REMOTEY_TEST_PATTERN, whose picture moves by itself.
// Close Remotey on the phone first: the most recent viewer gets the live view.
// Frames are answered on arrival, so the numbers are the Mac's side: no decoding, no network.
import './guard.mjs'; // first: refuses without --live
import { execFileSync } from 'node:child_process';
import { POINTER, parseUpdate } from '../../Web/live-view.js';
import { PORT, fail, open, pointer, sleep, token } from './agent.mjs';

const codec = process.argv.includes('--jpeg') ? 'jpeg' : 'h264';
const fps = Number(process.argv.find((arg) => arg.startsWith('--fps='))?.slice(6) || 120);
/** Moves per second while circling. Above the frame rate no interval stays without a move, which shows what the agent can deliver. */
const moveRate = Number(process.argv.find((arg) => arg.startsWith('--move-rate='))?.slice(12) || fps);
/** The phone's display element in CSS pixels. The default is a phone in full view; above the keys it is about 366x420. */
const [width, height] = (process.argv.find((arg) => arg.startsWith('--size='))?.slice(7) || '390x844').split('x').map(Number);
/** Answers every frame this late, like a phone that needs time to receive, decode and draw it. */
const ackDelay = Number(process.argv.find((arg) => arg.startsWith('--ack-delay='))?.slice(12) || 0);
/**
 * --link=wifi answers every frame after a round trip drawn from `tailscale ping` to an iPhone on the same Wi-Fi
 * (30 pings, direct connection, in ms), in order: an answer never overtakes the one before, as on one connection.
 */
const WIFI = [170, 213, 23, 224, 38, 141, 231, 106, 96, 102, 72, 159, 115, 17, 333, 67, 69, 16, 117, 64, 136, 104, 777, 46, 135, 18, 17, 16, 20, 19];
/**
 * --link=relay: the same phone on a mobile network, where no direct connection came about and Tailscale's relay
 * in Paris carried the packets (30 pings a second apart, in ms). The pings are replayed in their order, one a
 * second: what is sent while a ping is under way arrives with it, and later no sooner than the fastest ping
 * takes. So every run has the same link, with its two stalls.
 */
const RELAY = [1695, 96, 153, 163, 186, 88, 110, 84, 182, 200, 590, 97, 146, 205, 255, 171, 94, 125, 116, 230, 161, 178, 178, 136, 197, 218, 285, 120, 104, 102];
/** --link=2mbit: a link that carries this many Mbit/s, one message after the other. With `relay,2mbit` it is the relay that does. */
const link = process.argv.find((arg) => arg.startsWith('--link='))?.slice(7);
const parts = link?.split(',') ?? [];
const mbit = Number(parts.map((part) => /^(\d+(?:\.\d+)?)mbit$/.exec(part)?.[1]).find(Boolean) ?? 0);
const wifi = parts.includes('wifi'), relay = parts.includes('relay');
if (parts.some((part) => part !== 'wifi' && part !== 'relay' && !/^\d+(?:\.\d+)?mbit$/.test(part)) || (wifi && relay)) fail('--link is wifi, relay, a rate such as 2mbit, or relay,2mbit');
let lastAnswer = 0, lastArrival = 0, free = 0;
const started = performance.now();
/** The round trip of a message that leaves at `now`; 20 ms on a link that only has a rate. */
function trip(now) {
  if (wifi) return WIFI[Math.floor(Math.random() * WIFI.length)];
  if (!relay) return 20;
  const second = Math.floor((now - started) / 1000);
  return Math.max(Math.min(...RELAY), RELAY[second % RELAY.length] - (now - started - second * 1000));
}
/**
 * When a message of `bytes` that left the agent `now` reaches the phone, and when the phone's answer reaches the
 * agent. Without --link the phone gets it at once and answers after --ack-delay.
 */
function modelled(now, bytes) {
  if (!link) return { arrival: now, answer: now + ackDelay };
  // `free` is when the link has carried the message; then it travels half the round trip, and so does the answer.
  free = Math.max(free, now) + (mbit ? bytes * 8 / (mbit * 1000) : 0);
  lastAnswer = Math.max(lastAnswer, free + trip(now));
  lastArrival = Math.max(lastArrival, free + (lastAnswer - free) / 2);
  return { arrival: lastArrival, answer: lastAnswer };
}
const sh = (cmd, ...args) => execFileSync(cmd, args, { encoding: 'utf8' }).trim();
const pid = (name) => sh('pgrep', '-x', name).split('\n')[0];
/** CPU seconds a process has used so far. */
function cpu(id) {
  const [rest, minutes] = sh('ps', '-o', 'cputime=', '-p', id).split(':').reverse();
  return Number(minutes) * 60 + Number(rest);
}
// The agent that listens on the port, not any process named Remotey: a development build may run beside the app.
const agent = (() => { try { return sh('lsof', '-t', `-iTCP:${PORT}`, '-sTCP:LISTEN').split('\n')[0]; } catch { return fail(`no agent listens on ${PORT}`); } })();
const windowServer = pid('WindowServer');
const quantile = (sorted, q) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * q))];

const agentSocket = open({ t: 'auth', token }), send = agentSocket.send;
const hello = await agentSocket.reply;
if (hello?.t !== 'ok') fail(hello ? 'token refused' : 'agent not running');
if (!hello.ax) fail('no Accessibility permission');
const still = process.argv.includes('--still');
const seconds = Number(process.argv.find((arg) => arg.startsWith('--seconds='))?.slice(10) || 8);
let frames = 0, moves = 0, bytes = 0, onUpdate = null, moveNumber = 0;
/** For each picture: when it left the agent and when it reached the phone (the modelled link, queueing included). */
const travel = [];
agentSocket.onMessage = (e) => {
  if (typeof e.data === 'string') {
    const m = JSON.parse(e.data);
    if (m.t === 'cursor') bytes += e.data.length;
    if (m.t === 'view' && m.ok === false) fail(m.why === 'taken' ? 'another viewer took the live view' : 'no Screen Recording permission');
    return;
  }
  const update = parseUpdate(e.data);
  bytes += e.data.byteLength;
  const now = performance.now(), { arrival, answer } = modelled(now, e.data.byteLength);
  const reached = () => onUpdate?.(update.q);
  if (arrival > now) setTimeout(reached, arrival - now); else reached();
  if (update.kind === POINTER) { moves++; return; } // the pointer moved inside the view: no picture, no answer
  frames++;
  travel.push({ sent: now, arrival });
  if (answer > now) setTimeout(() => send({ t: 'shown', n: update.n }), answer - now); else send({ t: 'shown', n: update.n });
};

/** Runs `work` and reports frame rate, bit rate and CPU use over that time. */
async function measure(label, work) {
  const before = { frames, moves, bytes, travel: travel.length, agent: cpu(agent), windowServer: cpu(windowServer), time: performance.now() };
  await work();
  const seconds = (performance.now() - before.time) / 1000;
  const percent = (id, was) => ((cpu(id) - was) / seconds * 100).toFixed(0).padStart(3);
  console.log(`${label.padEnd(22)} ${((frames - before.frames) / seconds).toFixed(1).padStart(6)} pictures/s  `
    + `${((moves - before.moves) / seconds).toFixed(1).padStart(5)} pointer-only/s  `
    + `${((bytes - before.bytes) * 8 / seconds / 1e6).toFixed(2).padStart(5)} Mbit/s  `
    + `agent ${percent(agent, before.agent)} % CPU  WindowServer ${percent(windowServer, before.windowServer)} % CPU`);
  if (link) {
    // What a phone that draws at 60 Hz shows: at every refresh, the newest picture that has arrived. Pictures that
    // arrive in one burst are one update; the age of the picture on screen is what the user sees as delay.
    const pictures = travel.slice(before.travel).sort((a, b) => a.arrival - b.arrival), ages = [];
    let shown = 0, next = 0, newest = null, lastShown = null;
    for (let t = before.time + 1000; t < before.time + seconds * 1000; t += 1000 / 60) {
      while (next < pictures.length && pictures[next].arrival <= t) newest = pictures[next++];
      if (!newest) continue;
      if (newest !== lastShown) { shown++; lastShown = newest; }
      ages.push(t - newest.sent);
    }
    ages.sort((a, b) => a - b);
    console.log(`${''.padEnd(22)} the phone shows ${(shown / (seconds - 1)).toFixed(1)} new pictures/s; age of the picture on screen `
      + `median ${quantile(ages, 0.5).toFixed(0)} ms, p90 ${quantile(ages, 0.9).toFixed(0)} ms`);
  }
}

/** Circles at the phone's cadence: with the view on, every frame pans the whole picture. */
async function circles() {
  const started = performance.now();
  for (let i = 0; performance.now() - started < 4000; i++) {
    const a = (i / moveRate) * 4 * Math.PI, b = ((i + 1) / moveRate) * 4 * Math.PI;
    send({ t: 'm', dx: 120 * (Math.cos(b) - Math.cos(a)), dy: 120 * (Math.sin(b) - Math.sin(a)), q: ++moveNumber });
    // Timers are a millisecond or more late, so each wait aims at the next move's time, not at an interval.
    await sleep(Math.max(0, started + (i + 1) * 1000 / moveRate - performance.now()));
  }
}

if (still) {
  send({ t: 'view', on: true, w: width, h: height, zoom: 0.5, dpr: 3, codec, fps });
  await sleep(1500);
  await measure(`${codec} ${fps} fps, ${link ?? `answers after ${ackDelay} ms`}`, () => sleep(seconds * 1000));
  send({ t: 'view', on: false });
  await sleep(100);
  agentSocket.close();
  process.exit(0);
}
const [startX, startY] = pointer();
// The reference: what the Mac spends on a still and on a moving pointer without the live view.
await measure('view off', () => sleep(4000));
await measure('view off, circles', circles);
send({ t: 'view', on: true, w: width, h: height, zoom: 0.5, dpr: 3, codec, fps });
await sleep(1500);
console.log(`${codec}, ${fps} fps requested, frames answered after ${link ? `crossing ${link}` : `${ackDelay} ms`}`);

await measure('idle, view on', () => sleep(4000));

const seen = frames + moves;
await measure('pointer in circles', circles);
if (frames + moves === seen) console.log('VOID: no message while the pointer moved. Another client, such as the phone, has taken the view over.');

// Latency: every message names the last move it includes.
const timed = async (label, vertical = false) => {
  const delays = [];
  for (let i = 0; i < 60; i++) {
    const q = ++moveNumber, sent = performance.now();
    const seen = new Promise((resolve) => { onUpdate = (included) => { if (included === q) resolve(performance.now() - sent); }; });
    send({ t: 'm', dx: vertical ? 0 : i % 2 ? -24 : 24, dy: i % 2 ? -24 : 24, q });
    const delay = await Promise.race([seen, sleep(1500).then(() => null)]);
    if (delay !== null) delays.push(delay);
    await sleep(40 + Math.random() * 30); // not in step with the display
  }
  onUpdate = null;
  delays.sort((a, b) => a - b);
  if (delays.length < 30) console.log(`${label}: only ${delays.length} of 60 moves came back`);
  else console.log(`${label.padEnd(22)} median ${quantile(delays, 0.5).toFixed(1)} ms, p90 ${quantile(delays, 0.9).toFixed(1)} ms, `
    + `max ${delays.at(-1).toFixed(1)} ms  (${delays.length} of 60 moves)`);
};
await timed('move to picture');
// Against the top edge the view cannot follow, so only the pointer's place is sent.
send({ t: 'm', dx: 0, dy: -5000 });
await sleep(300);
send({ t: 'm', dx: 0, dy: 60 });
await sleep(300);
await timed('move at a screen edge', true);

// A burst, as a network delivers it after a hiccup: every move must count.
const [beforeX, beforeY] = pointer();
const step = beforeX > 600 ? -4 : 4;
for (let i = 0; i < 50; i++) send({ t: 'm', dx: step, dy: 0 });
await sleep(400);
const [afterX, afterY] = pointer(), moved = afterX - beforeX;
// The agent carries fractions of a point from earlier moves over, hence the tolerance of one point.
const verdict = Math.abs(moved - step * 50) <= 1 ? 'ok  ' : afterY !== beforeY ? 'VOID (the mouse was moved by hand, run again)' : 'LOST';
console.log(`burst of 50 moves      ${verdict} pointer moved ${moved} pt of ${step * 50} pt`);

const [endX, endY] = pointer();
send({ t: 'm', dx: startX - endX, dy: endY - startY }); // AppKit's y points up, the agent's down
await sleep(200);
send({ t: 'view', on: false });
await sleep(100);
agentSocket.close();
