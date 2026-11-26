// End to end without disturbing the Mac: starts the agent headless (REMOTEY_HEADLESS=1: no status item, no window,
// no permission prompt, input written to stdout instead of posted) on a free port, opens the real page it serves
// in headless Chromium with touch emulation, pairs with a code, connects with a ticket, and checks that a finger
// on the pad arrives at the agent as pointer moves.
//
// The page's half of pairing: when the page's remote.js names `/session`, the script trusts the page to pair from
// `#p=<code>` and to fetch its ticket itself (mode "page"). Until then (mode "shim"), the script pairs through the
// page's own origin with fetch (so the browser keeps the cookie, as it would for the page), and a small wrapper
// around the page's WebSocket trades the page's token message for `{"t":"auth","ticket":…}` from `POST /session`.
// Everything else, the touch, the pad, the socket and the agent, is the real thing in both modes.
//
// Usage: node scripts/pairing-e2e.mjs [--agent=.build/debug/Remotey] [--mode=auto|page|shim]
// Needs a built agent (swift build) and chrome-headless-shell from the Playwright cache, as ui-verify.mjs does.
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { createServer } from 'node:net';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const agentPath = resolve(arg('agent', '.build/debug/Remotey'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const cleanups = [];
let done = false;
async function finish(code, message) {
  if (done) return;
  done = true;
  console[code ? 'error' : 'log'](message);
  for (const cleanup of cleanups.reverse()) { try { await cleanup(); } catch {} }
  process.exit(code);
}
const fail = (message) => finish(1, `FAIL ${message}`);
const timeout = setTimeout(() => fail('took longer than 60 s'), 60000);

/** A port whose neighbour is free too, never the installed agent's 47800. */
async function freePort() {
  const free = (port) => new Promise((r) => {
    const server = createServer().once('error', () => r(false)).listen(port, '127.0.0.1', () => server.close(() => r(true)));
  });
  for (let i = 0; i < 50; i++) {
    const port = 49152 + Math.floor(Math.random() * 15000);
    if (port !== 47800 && await free(port) && await free(port + 1)) return port;
  }
  throw new Error('no free pair of ports');
}

function chromePath() {
  const root = join(homedir(), 'Library/Caches/ms-playwright');
  const dir = existsSync(root) && readdirSync(root).filter((d) => d.startsWith('chromium_headless_shell')).sort().at(-1);
  if (!dir) throw new Error('no chrome-headless-shell in ~/Library/Caches/ms-playwright');
  return join(root, dir, readdirSync(join(root, dir)).find((d) => d.startsWith('chrome-headless-shell')), 'chrome-headless-shell');
}

// ---- The agent
if (!existsSync(agentPath)) await fail(`no agent at ${agentPath}: swift build first`);
const port = await freePort();
const origin = `http://127.0.0.1:${port}`;
const agent = spawn(agentPath, [], { env: { ...process.env, REMOTEY_HEADLESS: '1', REMOTEY_PORT: String(port) }, stdio: ['ignore', 'pipe', 'inherit'] });
cleanups.push(() => new Promise((r) => { if (agent.exitCode !== null) return r(); agent.once('exit', r); agent.kill('SIGTERM'); }));
const lines = [];
let waiters = [];
let rest = '';
agent.stdout.on('data', (chunk) => {
  rest += chunk;
  const parts = rest.split('\n');
  rest = parts.pop();
  for (const line of parts) { lines.push(line); waiters = waiters.filter((w) => !w()); }
});
agent.on('exit', (code) => { if (!done) fail(`agent ended (${code}): ${lines.slice(-3).join(' | ')}`); });
/** The first line of the agent's that `match` takes, from the start. */
const line = (match, ms = 10000, what = 'a line') => new Promise((r, j) => {
  const look = () => { const found = lines.find(match); if (found) { r(found); return true; } return false; };
  if (look()) return;
  waiters.push(look);
  setTimeout(() => j(new Error(`no ${what} from the agent in ${ms} ms; it said: ${lines.slice(-5).join(' | ')}`)), ms);
});

const [, code, digits] = (await line((l) => l.startsWith('pairing '), 20000, 'pairing offer')).split(' ');
console.log(`ok   agent headless on ${port}, pairing open`);

// ---- Which half of pairing the page has
const remote = await (await fetch(`${origin}/remote.js`)).text();
const mode = arg('mode', 'auto') === 'auto' ? (remote.includes('/session') ? 'page' : 'shim') : arg('mode');
console.log(`ok   mode ${mode}${mode === 'shim' ? ' (the page does not pair yet: the script drives /pair and /session)' : ''}`);

// ---- Chromium
const profile = mkdtempSync(join(tmpdir(), 'remotey-e2e-'));
cleanups.push(() => rmSync(profile, { recursive: true, force: true }));
const chrome = spawn(chromePath(), ['--headless', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
  '--no-first-run', '--disable-gpu', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
cleanups.push(() => new Promise((r) => { if (chrome.exitCode !== null) return r(); chrome.once('exit', r); chrome.kill(); }));
const wsUrl = await new Promise((r, j) => {
  let text = '';
  chrome.stderr.on('data', (d) => { text += d; const m = text.match(/ws:\/\/[^\s]+/); if (m) r(m[0]); });
  setTimeout(() => j(new Error('chrome did not start')), 10000);
});
const socket = new WebSocket(wsUrl);
await new Promise((r) => { socket.onopen = r; });
let nextId = 0;
const pending = new Map();
socket.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { const { r, j } = pending.get(m.id); pending.delete(m.id); m.error ? j(new Error(m.error.message)) : r(m.result); }
};
const cdp = (method, params = {}, sessionId) => new Promise((r, j) => {
  const id = ++nextId;
  pending.set(id, { r, j });
  socket.send(JSON.stringify({ id, method, params, sessionId }));
});

const { targetId } = await cdp('Target.createTarget', { url: 'about:blank' });
const { sessionId } = await cdp('Target.attachToTarget', { targetId, flatten: true });
const s = (method, params) => cdp(method, params, sessionId);
const evaluate = async (expression) => {
  const { result, exceptionDetails } = await s('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
  return result.value;
};
await s('Page.enable');
await s('Runtime.enable');
await s('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });
await s('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
await s('Emulation.setUserAgentOverride', { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1' });

// Holds the page's first `auth` until the script has paired, then sends the ticket in its place.
const shim = `(() => {
  const Real = window.WebSocket;
  let go;
  window.__paired = new Promise((r) => { go = r; });
  window.__go = () => go();
  window.WebSocket = class extends Real {
    send(data) {
      let m = null;
      try { m = JSON.parse(data); } catch {}
      if (m?.t !== 'auth' || m.ticket) return super.send(data);
      window.__paired
        .then(() => fetch('/session', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }))
        .then((r) => r.json())
        .then((j) => { window.__ticket = j.ticket; if (this.readyState === 1) super.send(JSON.stringify({ t: 'auth', ticket: j.ticket, standalone: false })); });
    }
  };
})();`;

try {
  if (mode === 'shim') {
    await s('Page.addScriptToEvaluateOnNewDocument', { source: shim });
    await s('Page.navigate', { url: `${origin}/#e2e-no-token` }); // a fragment, so the page tries to connect
    await sleep(500);
    const paired = await evaluate(`fetch('/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: ${JSON.stringify(digits)} }) }).then(async (r) => ({ status: r.status, body: await r.json() }))`);
    if (paired.status !== 200 || paired.body.ok !== true) await fail(`pairing with the six digits: ${JSON.stringify(paired)}`);
    const visible = await evaluate('document.cookie');
    if (visible.includes('remotey-device')) await fail(`the page's scripts can read the device cookie: ${visible}`);
    console.log(`ok   paired by digits as "${paired.body.device.name}"; the cookie is hidden from scripts`);
    await evaluate('window.__go()');
  } else {
    await s('Page.navigate', { url: `${origin}/#p=${code}` });
  }

  await line((l) => l.startsWith('paired '), 10000, '"paired"');
  await line((l) => l === 'session 1', 10000, '"session 1"');
  const status = await (async () => {
    for (let i = 0; i < 50; i++) { const c = await evaluate("document.querySelector('#status').className"); if (c === 'ok') return c; await sleep(100); }
    return evaluate("document.querySelector('#status').textContent");
  })();
  if (status !== 'ok') await fail(`the page does not say it is connected: ${status}`);
  console.log('ok   the page connected with a ticket');

  // A finger across the pad, as ui-verify.mjs moves one.
  const pad = await evaluate("(() => { const r = document.querySelector('#pad').getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()");
  const touch = (type, points) => s('Input.dispatchTouchEvent', { type, touchPoints: points.map(([x, y], id) => ({ x, y, id })) });
  const before = lines.length;
  await touch('touchStart', [[pad.x - 60, pad.y]]);
  for (let i = 1; i <= 20; i++) { await sleep(16); await touch('touchMove', [[pad.x - 60 + i * 6, pad.y]]); }
  await sleep(40);
  await touch('touchEnd', []);
  // kCGEventMouseMoved is 5; the line names the event's deltas.
  await sleep(300);
  const moves = lines.slice(before).filter((l) => l.startsWith('posted 5 ')).map((l) => l.split(' ').map(Number));
  const dx = moves.reduce((sum, m) => sum + m[2], 0);
  if (!moves.length || dx <= 0) await fail(`no move to the right arrived: ${lines.slice(before).join(' | ') || 'nothing'}`);
  if (lines.slice(before).some((l) => /^posted (1|2|3|4) /.test(l))) await fail('the move clicked');
  console.log(`ok   a finger on the pad arrived as ${moves.length} moves, ${dx} points to the right`);
} catch (error) {
  await fail(error.message);
}
clearTimeout(timeout);
await finish(0, 'ok   end to end');
