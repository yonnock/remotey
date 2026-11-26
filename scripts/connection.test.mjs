import assert from 'node:assert/strict';
import { test } from 'node:test';
import { IDLE_MS, Awake } from '../Web/awake.js';
import { CONNECT_MS, Heartbeat, Link, PROBE_MS, RETRY, cause, probe, retryDelay } from '../Web/connection.js';

// A Link with timers the test runs by hand, and a record of what it did.
function rig({ status = null, online = true } = {}) {
  const timers = new Map(), log = [];
  let next = 0, now = 0;
  const env = { status, online };
  const link = new Link({
    open: () => log.push('open'),
    drop: () => log.push('drop'),
    probe: async () => env.status,
    online: () => env.online,
    changed: (state) => log.push(state),
    schedule: (fn, ms) => { timers.set(++next, { fn, at: now + ms }); return next; },
    cancel: (id) => timers.delete(id),
  });
  // Runs every timer due within `ms`, in order, and lets the probes answer.
  const advance = async (ms) => {
    const end = now + ms;
    for (;;) {
      const due = [...timers].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      timers.delete(due[0]);
      now = due[1].at;
      due[1].fn();
      await new Promise((r) => setImmediate(r));
    }
    now = end;
  };
  const settle = () => new Promise((r) => setImmediate(r));
  return { link, log, env, advance, settle, timers, opens: () => log.filter((e) => e === 'open').length };
}

test('the cause of a failure: no network, nothing answers, or the agent is down behind tailscale serve', () => {
  assert.equal(cause({ online: false, status: null }), 'offline');
  assert.equal(cause({ online: false, status: 502 }), 'offline', 'without a network nothing else is known');
  assert.equal(cause({ online: true, status: null }), 'unreachable');
  assert.equal(cause({ online: true, status: 502 }), 'stopped');
  assert.equal(cause({ online: true, status: 404 }), 'stopped', 'the agent answers HEAD with 404: the Mac is there, its socket is not');
});

test('the wait between tries grows and stops growing', () => {
  assert.deepEqual([0, 1, 2, 3, 4, 5, 6, 7, 20].map(retryDelay), [500, 1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000]);
  assert.equal(retryDelay(-1), RETRY.first);
});

test('without a key there is nothing to try', () => {
  const r = rig();
  r.link.begin({ paired: false });
  assert.equal(r.link.state, 'unpaired');
  assert.equal(r.opens(), 0);
});

test('a key the Mac takes: connected, or without the Accessibility permission, no access', () => {
  const r = rig();
  r.link.begin();
  assert.equal(r.link.state, 'connecting');
  r.link.accepted(true);
  assert.equal(r.link.state, 'connected');
  const s = rig();
  s.link.begin();
  s.link.accepted(false);
  assert.equal(s.link.state, 'noAccess');
  assert.equal(s.link.up, true, 'the connection itself works');
});

test('a Mac out of reach is tried again later each time, and the failure stays on show meanwhile', async () => {
  const r = rig({ status: null });
  r.link.begin();
  r.link.lost(); await r.settle();
  assert.equal(r.link.state, 'unreachable');
  const starts = [];
  r.log.length = 0;
  for (let i = 0; i < 5; i++) {
    const before = r.opens();
    let waited = 0;
    while (r.opens() === before) { await r.advance(100); waited += 100; }
    starts.push(waited);
    r.link.lost(); await r.settle();
  }
  assert.deepEqual(starts, [500, 1000, 2000, 4000, 8000]);
  assert.ok(!r.log.includes('connecting'), 'no flicker between the failure and "connecting"');
  assert.equal(r.link.state, 'unreachable');
});

test('a tap tries at once, shows that it does, and starts the intervals over', async () => {
  const r = rig({ status: null });
  r.link.begin();
  for (let i = 0; i < 4; i++) { r.link.lost(); await r.settle(); await r.advance(retryDelay(i)); }
  r.link.lost(); await r.settle();
  const before = r.opens();
  r.link.begin({ ask: true });
  assert.equal(r.opens(), before + 1);
  assert.equal(r.link.state, 'connecting');
  r.link.lost(); await r.settle();
  assert.equal(r.link.state, 'unreachable');
  await r.advance(RETRY.first);
  assert.equal(r.opens(), before + 2, 'the next try after the shortest wait again');
});

test('the agent down and the phone offline are told apart from a Mac out of reach', async () => {
  const r = rig({ status: 502 });
  r.link.begin();
  r.link.lost(); await r.settle();
  assert.equal(r.link.state, 'stopped');
  r.env.online = false;
  await r.advance(RETRY.first);
  r.link.lost(); await r.settle();
  assert.equal(r.link.state, 'offline');
});

test('a connection that worked and is lost is tried again at once, without asking what went wrong', async () => {
  const r = rig({ status: null });
  r.link.begin();
  r.link.accepted(true);
  r.log.length = 0;
  r.link.lost(); await r.settle();
  assert.deepEqual(r.log, ['connecting', 'open']);
  r.link.accepted(true);
  assert.equal(r.link.state, 'connected');
});

test('a try that gets no answer from the Mac in time counts as failed', async () => {
  const r = rig({ status: null });
  r.link.begin();
  await r.advance(CONNECT_MS);
  assert.ok(r.log.includes('drop'), 'the socket is closed');
  assert.equal(r.link.state, 'unreachable');
});

test('a refused key is not tried again until the user asks', async () => {
  const r = rig();
  r.link.begin();
  r.link.refused();
  assert.equal(r.link.state, 'denied');
  await r.advance(60_000);
  r.link.lost(); await r.settle();
  r.link.begin(); // back in sight
  assert.equal(r.opens(), 1);
  r.link.begin({ ask: true });
  assert.equal(r.opens(), 2);
});

test('a probe overtaken by a tap does not report', async () => {
  let answer;
  const r = rig();
  r.link.hooks.probe = () => new Promise((resolve) => { answer = resolve; });
  r.link.begin();
  r.link.lost();
  r.link.begin({ ask: true });
  r.link.accepted(true);
  answer(null); await r.settle();
  assert.equal(r.link.state, 'connected');
});

test('out of sight no tries are left behind', async () => {
  const r = rig({ status: null });
  r.link.begin();
  r.link.lost(); await r.settle();
  r.link.stop();
  assert.equal(r.timers.size, 0);
});

test('the heartbeat says ping every five seconds and calls a silent connection dead after fifteen', () => {
  const beat = new Heartbeat();
  beat.heard(0);
  beat.pingedAt = 0;
  const said = [];
  for (let t = 1000; t <= 16000; t += 1000) said.push(beat.check(t));
  assert.deepEqual(said.map((s, i) => s && `${(i + 1)}s ${s}`).filter(Boolean), ['5s ping', '10s ping', '15s dead', '16s dead']);
  // Anything that arrives, a picture or the answer to a ping, keeps it alive.
  const alive = new Heartbeat();
  alive.heard(0);
  for (let t = 1000; t <= 60000; t += 1000) { alive.heard(t - 500); assert.notEqual(alive.check(t), 'dead'); }
});

test('the probe gives the status of the page\'s origin, or null when nothing answers', async (t) => {
  assert.equal(await probe(async (url, options) => { assert.equal(options.method, 'HEAD'); return { status: 502 }; }), 502);
  assert.equal(await probe(async () => { throw new TypeError('Load failed'); }), null);
  // A Mac out of reach over Tailscale often does not refuse, it just never answers.
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const hanging = probe((url, { signal }) => new Promise((_, reject) => signal.addEventListener('abort', () => reject(new Error('aborted')))));
  t.mock.timers.tick(PROBE_MS);
  assert.equal(await hanging, null);
});

// ---- The wake lock.
function lock() {
  const calls = [];
  const fake = { request: async () => { const s = { released: false, release: async () => { s.released = true; calls.push('release'); } }; calls.push('request'); return s; } };
  return { fake, calls };
}

test('the screen is held while the phone is touched, and let go after some minutes without a touch', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const { fake, calls } = lock();
  const awake = new Awake(fake);
  await awake.touched();
  assert.equal(awake.held, true);
  for (let i = 0; i < 5; i++) { t.mock.timers.tick(IDLE_MS - 1000); await awake.touched(); }
  assert.deepEqual(calls, ['request'], 'touches keep it, without asking again');
  t.mock.timers.tick(IDLE_MS);
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(calls, ['request', 'release']);
  assert.equal(awake.held, false);
  await awake.touched();
  assert.deepEqual(calls, ['request', 'release', 'request'], 'the next touch holds it again');
  await awake.release();
});

test('a phone without a wake lock, or one that refuses it, is no error', async () => {
  const none = new Awake(null);
  await none.touched();
  await none.release();
  const awake = new Awake({ request: () => Promise.reject(new Error('NotAllowedError')) });
  await awake.touched();
  assert.equal(awake.held, false);
  await awake.release();
});

test('a phone the Mac does not know: no tries until asked, then it starts over', async () => {
  const r = rig();
  r.link.begin();
  r.link.unpaired();
  assert.equal(r.link.state, 'unpaired');
  await r.advance(60_000);
  assert.equal(r.opens(), 1, 'no try of its own after the Mac said it does not know the phone');
  r.link.begin();
  assert.equal(r.opens(), 1, 'back in sight is no reason to ask again');
  r.link.begin({ ask: true });
  assert.equal(r.link.state, 'connecting');
  assert.equal(r.opens(), 2);
});

test('what the Mac says about itself: steering, a missing permission, a pause at the Mac', () => {
  const r = rig();
  r.link.mac({ ax: true, paused: false });
  assert.equal(r.link.state, 'connecting', 'nothing to say before the Mac took the key');
  r.link.begin();
  r.link.accepted(true);
  r.link.mac({ ax: false, paused: false });
  assert.equal(r.link.state, 'noAccess');
  r.link.mac({ ax: false, paused: true });
  assert.equal(r.link.state, 'paused', 'a pause at the Mac counts before a missing permission');
  assert.ok(r.link.up, 'a paused Mac is still connected');
  r.link.mac({ ax: true, paused: false });
  assert.equal(r.link.state, 'connected');
});

test('a paused Mac that drops the connection is tried again at once, as a connected one', () => {
  const r = rig();
  r.link.begin();
  r.link.accepted(true);
  r.link.mac({ ax: true, paused: true });
  r.link.lost();
  assert.equal(r.link.state, 'connecting');
  assert.equal(r.opens(), 2);
});

test('the wake lock with the timers of a browser, which refuse to run as methods of another object', async () => {
  const real = globalThis.setTimeout;
  const strict = function (fn, ms) { if (this !== undefined && this !== globalThis) throw new TypeError('Illegal invocation'); return real(fn, ms); };
  globalThis.setTimeout = strict;
  try {
    let asked = 0;
    const awake = new Awake({ request: async () => { asked++; return { released: false, release: async () => {} }; } });
    await awake.touched();
    assert.equal(asked, 1, 'the lock was asked for');
    await awake.release();
  } finally { globalThis.setTimeout = real; }
});
