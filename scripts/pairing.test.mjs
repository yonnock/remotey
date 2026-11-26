import assert from 'node:assert/strict';
import { test } from 'node:test';
import { CODE_LENGTH, Pairing, auth, digits, fragment, pair, session } from '../Web/pairing.js';

// A stand-in for the agent's routes: what each path answers, and a record of what was posted.
function agent(routes) {
  const posted = [];
  const fetcher = async (path, options) => {
    const body = JSON.parse(options.body);
    posted.push({ path, body });
    const answer = typeof routes[path] === 'function' ? routes[path](body) : routes[path];
    if (answer === undefined) return new Response('', { status: 404 });
    if (answer === 'down') throw new TypeError('Load failed');
    return new Response(answer.json === undefined ? '' : JSON.stringify(answer.json), { status: answer.status });
  };
  return { fetcher, posted };
}
const memory = () => { const m = new Map(); return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k), m }; };

test('the fragment: a one-time code, the old token, or nothing of ours', () => {
  assert.deepEqual(fragment('#p=482913'), { code: '482913' });
  assert.deepEqual(fragment('#p=ab%20c'), { code: 'ab c' });
  assert.deepEqual(fragment('#k3y-OLD_t0ken'), { token: 'k3y-OLD_t0ken' });
  assert.equal(fragment(''), null);
  assert.equal(fragment('#'), null);
  assert.equal(fragment('#p='), null);
  assert.equal(fragment('#x=1'), null, 'another key=value is no token');
});

test('what is typed or pasted becomes six digits', () => {
  assert.equal(CODE_LENGTH, 6);
  assert.equal(digits('482 913'), '482913');
  assert.equal(digits('482-913\n'), '482913');
  assert.equal(digits('Code: 482913 (gilt 5 Minuten)'), '482913');
  assert.equal(digits('12345678'), '123456');
  assert.equal(digits(null), '');
});

test('pairing: each answer of the Mac in words the page can say', async () => {
  const cases = [
    [{ status: 200, json: { ok: true, device: { id: 'd1', name: 'iPhone' } } }, { ok: true, device: { id: 'd1', name: 'iPhone' } }],
    [{ status: 403, json: { ok: false, why: 'code' } }, { ok: false, why: 'code' }],
    [{ status: 403, json: { ok: false, why: 'closed' } }, { ok: false, why: 'closed' }],
    [{ status: 403 }, { ok: false, why: 'code' }],
    [{ status: 429 }, { ok: false, why: 'tries' }],
    [undefined, { ok: false, why: 'old' }],
    ['down', { ok: false, why: 'offline' }],
  ];
  for (const [answer, expected] of cases) {
    const { fetcher, posted } = agent({ '/pair': answer });
    assert.deepEqual(await pair({ code: '482913' }, fetcher), expected, JSON.stringify(answer));
    assert.deepEqual(posted, [{ path: '/pair', body: { code: '482913' } }]);
  }
  const { fetcher } = agent({ '/pair': { status: 403, json: { ok: false } } });
  assert.deepEqual(await pair({ token: 'x' }, fetcher), { ok: false, why: 'token' }, 'a token the Mac does not take');
});

test('a session: a ticket, a phone the Mac does not know, an older agent, or no answer', async () => {
  assert.deepEqual(await session(agent({ '/session': { status: 200, json: { ticket: 't1' } } }).fetcher), { ticket: 't1' });
  assert.deepEqual(await session(agent({ '/session': { status: 401, json: { why: 'unpaired' } } }).fetcher), { why: 'unpaired' });
  assert.deepEqual(await session(agent({}).fetcher), { why: 'old' });
  assert.deepEqual(await session(agent({ '/session': 'down' }).fetcher), { why: 'offline' });
});

test('the first message names the ticket and where the page runs, or the old token', () => {
  assert.deepEqual(auth({ ticket: 't1' }, true), { t: 'auth', ticket: 't1', standalone: true });
  assert.deepEqual(auth({ ticket: 't1' }, false), { t: 'auth', ticket: 't1', standalone: false });
  assert.deepEqual(auth({ token: 'old' }, true), { t: 'auth', token: 'old' });
});

test('a device asks for a ticket before every connection', async () => {
  let n = 0;
  const { fetcher, posted } = agent({ '/session': () => ({ status: 200, json: { ticket: `t${++n}` } }) });
  const pairing = new Pairing({ storage: memory(), fetcher });
  assert.deepEqual(await pairing.credentials(), { ticket: 't1' });
  assert.deepEqual(await pairing.credentials(), { ticket: 't2' }, 'a ticket is good once');
  assert.deepEqual(posted.map((p) => p.path), ['/session', '/session']);
});

test('paired by code: the device is kept, a token from before is not needed any more', async () => {
  const storage = memory();
  storage.setItem('remotey-token', 'old');
  const { fetcher } = agent({ '/pair': { status: 200, json: { ok: true, device: { id: 'd1', name: 'iPhone von A' } } } });
  const pairing = new Pairing({ storage, fetcher });
  assert.deepEqual(await pairing.pair({ code: '482913' }), { ok: true, device: { id: 'd1', name: 'iPhone von A' } });
  assert.deepEqual(pairing.device, { id: 'd1', name: 'iPhone von A' });
  assert.equal(pairing.token, '');
});

test('paired the old way: the token is posted once to become a device, then only tickets', async () => {
  const storage = memory();
  const { fetcher, posted } = agent({
    '/pair': (body) => (body.token === 'old' ? { status: 200, json: { ok: true, device: { id: 'd1', name: 'iPhone' } } } : { status: 403, json: { ok: false } }),
    '/session': { status: 200, json: { ticket: 't' } },
  });
  const pairing = new Pairing({ storage, fetcher });
  pairing.keepToken('old');
  assert.deepEqual(await pairing.credentials(), { ticket: 't' });
  assert.deepEqual(await pairing.credentials(), { ticket: 't' });
  assert.deepEqual(posted.map((p) => p.path), ['/pair', '/session', '/session']);
  assert.deepEqual(posted[0].body, { token: 'old' });
  assert.equal(storage.getItem('remotey-token'), null, 'the token is gone from the phone');
});

test('an agent from before pairing per device: the old token, as before, and asked only once', async () => {
  const { fetcher, posted } = agent({});
  const pairing = new Pairing({ storage: memory(), fetcher });
  pairing.keepToken('old');
  assert.deepEqual(await pairing.credentials(), { token: 'old' });
  assert.deepEqual(await pairing.credentials(), { token: 'old' });
  assert.deepEqual(posted.map((p) => p.path), ['/pair'], 'it said once that it knows no pairing');
});

test('upgrading fails but sessions exist: the token stays the way in until the Mac refuses it', async () => {
  const { fetcher } = agent({ '/pair': { status: 429 }, '/session': { status: 401, json: { why: 'unpaired' } } });
  const pairing = new Pairing({ storage: memory(), fetcher });
  pairing.keepToken('old');
  assert.deepEqual(await pairing.credentials(), { token: 'old' });
});

test('a phone the Mac does not know, without a token: not paired, and what the page kept of it goes', async () => {
  const storage = memory();
  storage.setItem('remotey-device', JSON.stringify({ id: 'd1', name: 'iPhone' }));
  const pairing = new Pairing({ storage, fetcher: agent({ '/session': { status: 401, json: { why: 'unpaired' } } }).fetcher });
  assert.equal(await pairing.credentials(), null);
  assert.equal(pairing.device, null);
});

test('nothing answers: the try failed, and nothing is forgotten', async () => {
  const storage = memory();
  storage.setItem('remotey-device', JSON.stringify({ id: 'd1', name: 'iPhone' }));
  const pairing = new Pairing({ storage, fetcher: agent({ '/session': 'down', '/pair': 'down' }).fetcher });
  await assert.rejects(pairing.credentials());
  pairing.keepToken('old');
  await assert.rejects(pairing.credentials());
  assert.deepEqual(pairing.device, { id: 'd1', name: 'iPhone' });
  assert.equal(pairing.token, 'old');
});

test('a revoked phone forgets device and token', () => {
  const storage = memory();
  const pairing = new Pairing({ storage, fetcher: agent({}).fetcher });
  pairing.keepToken('old');
  storage.setItem('remotey-device', '{"id":"d1","name":"x"}');
  pairing.forget();
  assert.equal(pairing.token, '');
  assert.equal(pairing.device, null);
});
