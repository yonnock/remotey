// Smoke test against a running agent: HTTP page, auth rejection, auth success, cursor movement.
// Usage: node scripts/smoke.mjs   (moves the cursor 40pt right and back; sends no keystrokes)
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

const token = readFileSync(`${homedir()}/Library/Application Support/Remotey/token`, 'utf8').trim();
const fail = (msg) => { console.error('FAIL', msg); process.exit(1); };

const page = await fetch('http://127.0.0.1:47800/');
if (page.status !== 200 || !(await page.text()).includes('<title>Remotey</title>')) fail('page');
const icon = await fetch('http://127.0.0.1:47800/icon.png');
if (icon.status !== 200 || (await icon.arrayBuffer()).byteLength < 500) fail('icon');
if ((await fetch('http://127.0.0.1:47800/etc/passwd')).status !== 404) fail('404');
console.log('ok   http: page, icon, 404');

function session(authToken) {
  return new Promise((resolve) => {
    const ws = new WebSocket('ws://127.0.0.1:47801/ws');
    const out = { ws, messages: [], closed: false };
    ws.onopen = () => ws.send(JSON.stringify({ t: 'auth', token: authToken }));
    ws.onmessage = (e) => { out.messages.push(JSON.parse(e.data)); resolve(out); };
    ws.onclose = () => { out.closed = true; resolve(out); };
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const bad = await session('wrong-token');
await sleep(300);
if (bad.messages[0]?.t !== 'denied' || !bad.closed) fail(`bad token not rejected: ${JSON.stringify(bad.messages)}`);
console.log('ok   ws: wrong token denied and closed');

// Unauthenticated input must be dropped: the first message is not an auth message.
const anon = new WebSocket('ws://127.0.0.1:47801/ws');
const anonClosed = new Promise((r) => { anon.onclose = () => r(true); });
anon.onopen = () => anon.send(JSON.stringify({ t: 'm', dx: 500, dy: 500 }));
if (!(await Promise.race([anonClosed, sleep(1000).then(() => false)]))) fail('unauthenticated input not closed');
console.log('ok   ws: input without auth closes the connection');

const good = await session(token);
if (good.messages[0]?.t !== 'ok') fail(`auth failed: ${JSON.stringify(good.messages)}`);
console.log(`ok   ws: authenticated, accessibility=${good.messages[0].ax}`);
good.ws.send(JSON.stringify({ t: 'm', dx: 40, dy: 0 }));
await sleep(400);
good.ws.send(JSON.stringify({ t: 'm', dx: -40, dy: 0 }));
await sleep(200);
good.ws.close();
console.log('done (cursor moved right and back if accessibility=true)');
