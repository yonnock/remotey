// Locks this Mac and checks the running agent behind the lock screen: it says that the Mac is locked, the
// pointer and the live view go on, a display that sleeps comes back with the next input, a wrong password is
// typed and refused, and the unlock is told.
// Usage: node scripts/live/lock.mjs --live --lock-mac [--password-stdin]
// Keep your hands off keyboard, mouse and Touch ID from the start until it says "unlock the Mac". An Apple Watch
// that unlocks the Mac opens it at the first input and ends the run early: switch that off for the run.
// One wrong password is typed into the lock screen. With --password-stdin the script reads the real one from
// standard input and unlocks the Mac itself, e.g. `op read op://VAULT/ITEM/password | node scripts/live/lock.mjs --live --lock-mac --password-stdin`.
// Close Remotey on the phone first: the most recent viewer gets the live view.
import { asked } from './guard.mjs'; // first: refuses without --live
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { parseUpdate, POINTER } from '../../Web/live-view.js';
import { fail, open, pointer, sleep, token } from './agent.mjs';

if (!asked('--lock-mac')) fail('this locks the Mac: add --lock-mac');
const password = process.argv.includes('--password-stdin') ? readFileSync(0, 'utf8').replace(/\r?\n$/, '') : null;
if (password === '') fail('--password-stdin got no password');
const asleep = () => execFileSync('osascript', ['-l', 'JavaScript', '-e',
  'ObjC.import("CoreGraphics"); String($.CGDisplayIsAsleep($.CGMainDisplayID()))'], { encoding: 'utf8' }).trim() === '1';
const now = () => performance.now();
/** Milliseconds until `ready()` holds, or null after `ms`. */
async function until(ready, ms) {
  const start = now();
  while (now() - start < ms) { if (ready()) return Math.round(now() - start); await sleep(50); }
  return ready() ? Math.round(now() - start) : null;
}

const mac = open({ t: 'auth', token });
let locked = null, pictures = 0, refused = null;
mac.onMessage = (e) => {
  if (typeof e.data === 'string') {
    const m = JSON.parse(e.data);
    if (m.t === 'lock') locked = m.on;
    else if (m.t === 'unlock') refused = m;
    else if (m.t === 'view' && m.ok === false) fail(m.why === 'taken' ? 'another viewer took the live view' : 'no Screen Recording permission');
    return;
  }
  const update = parseUpdate(e.data);
  if (update.kind === POINTER) return;
  pictures++;
  mac.send({ t: 'shown', n: update.n });
};
const hello = await mac.reply;
if (hello?.t !== 'ok') fail(`auth failed: ${JSON.stringify(hello)}`);
if (!hello.ax) fail('no Accessibility permission');
if (await until(() => locked !== null, 2000) === null) fail('the agent did not say whether the Mac is locked');
console.log(`ok   state: the agent says the Mac is ${locked ? 'locked' : 'open'}`);
/** Moves the pointer in circles for a second, so the view has something to show; ends where it started. */
async function stir() {
  for (let i = 0; i < 60; i++) {
    const a = (i / 60) * 6 * Math.PI, b = ((i + 1) / 60) * 6 * Math.PI;
    mac.send({ t: 'm', dx: 30 * (Math.cos(b) - Math.cos(a)), dy: 30 * (Math.sin(b) - Math.sin(a)) });
    await sleep(1000 / 60);
  }
  await sleep(300);
}
mac.send({ t: 'view', on: true, w: 390, h: 844, zoom: 0.5, dpr: 2, codec: 'jpeg', fps: 30 });
await stir();
if (pictures < 5) fail(`only ${pictures} pictures before locking`);

if (!locked) {
  mac.send({ t: 'key', k: 'q', mods: ['ctrl', 'cmd'], n: 1 });
  const ms = await until(() => locked === true, 5000);
  if (ms === null) fail('the Mac did not lock, or the agent did not say so');
  console.log(`ok   state: locked from the phone, told after ${ms} ms`);
}
await sleep(1500); // the lock screen fades in
const open_ = () => { if (locked === false) fail('the Mac was unlocked during the run (Touch ID or an Apple Watch?)'); };

let before = pictures;
const x = pointer()[0];
mac.send({ t: 'm', dx: 40, dy: 0 });
await sleep(400);
const moved = pointer()[0] - x;
mac.send({ t: 'm', dx: -40, dy: 0 });
if (Math.abs(moved) < 1) fail('the pointer does not move behind the lock screen');
await stir();
open_();
if (pictures - before < 5) fail(`only ${pictures - before} pictures of the lock screen`);
console.log(`ok   locked: the pointer follows a move, the live view runs (${pictures - before} pictures)`);

// A display that sleeps: nothing to capture, and posted events alone do not wake it.
execFileSync('pmset', ['displaysleepnow']);
if (await until(asleep, 10000) === null) console.log('skip display: it did not go to sleep');
else {
  await sleep(2000);
  before = pictures;
  const start = now();
  mac.send({ t: 'm', dx: 20, dy: 0 });
  const woke = await until(() => !asleep(), 6000);
  if (woke === null) fail('a move from the phone did not wake the display');
  mac.send({ t: 'm', dx: -20, dy: 0 });
  const shown = await until(() => pictures > before, 12000);
  if (shown === null) fail('no picture after the display woke');
  open_();
  console.log(`ok   display: a move wakes it after ${woke} ms, the live view is back ${Math.round(now() - start)} ms after the move`);
}

// A wrong password: typed into the lock screen's field, refused by the Mac.
await sleep(1000);
refused = null;
let start = now();
mac.send({ t: 'unlock', s: 'remotey-lock-test-not-the-password' });
if (await until(() => refused !== null || locked === false, 15000) === null) fail('no answer to an unlock');
open_();
if (refused.ok !== false || refused.why !== 'password') fail(`a wrong password was answered with ${JSON.stringify(refused)}`);
console.log(`ok   unlock: a wrong password is typed and refused after ${Math.round(now() - start)} ms`);

if (password !== null) {
  await sleep(1500); // the field shakes
  refused = null;
  start = now();
  mac.send({ t: 'unlock', s: password });
  if (await until(() => refused !== null || locked === false, 15000) === null) fail('no answer to an unlock');
  if (locked !== false) fail(`the password did not unlock the Mac: ${JSON.stringify(refused)}`);
  console.log(`ok   unlock: the password opens the Mac after ${Math.round(now() - start)} ms`);
} else {
  console.log('     unlock the Mac now (waiting up to 10 minutes)');
  execFileSync('osascript', ['-e', 'beep 2']);
  if (await until(() => locked === false, 600000) === null) fail('the agent did not say that the Mac was unlocked');
  console.log('ok   state: the agent says the Mac is open again');
}
await sleep(1500);
before = pictures;
await stir();
if (pictures - before < 5) fail(`only ${pictures - before} pictures after unlocking`);
console.log(`ok   open: the live view runs on (${pictures - before} pictures)`);
mac.close();
