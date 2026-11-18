import assert from 'node:assert/strict';
import { test } from 'node:test';
import { create, decode, encode, get } from '../Web/passkey.js';

const bytes = (...values) => new Uint8Array(values).buffer;

test('base64url goes both ways, without padding or the characters a URL takes otherwise', () => {
  const data = new Uint8Array([251, 255, 190, 0, 1]);
  assert.equal(encode(data.buffer), '-_--AAE');
  assert.deepEqual(decode('-_--AAE'), data);
  assert.deepEqual(decode(encode(bytes())), new Uint8Array());
});

/** The phone's side of WebAuthn: records what it was asked, answers with `credential`. */
function phone(credential) {
  const asked = [];
  return { asked, create: async (options) => { asked.push(options); return credential; }, get: async (options) => { asked.push(options); return credential; } };
}
const made = (prf, response = {}) => ({ rawId: bytes(1, 2, 3), getClientExtensionResults: () => ({ prf }),
  response: { clientDataJSON: bytes(4), getPublicKey: () => bytes(5, 6), getAuthenticatorData: () => bytes(7), ...response } });

test('enrolling asks for a passkey of this device that verifies its user and gives out a secret', async () => {
  const device = phone(made({ enabled: true, results: { first: bytes(9, 9) } }));
  const message = await create({ challenge: encode(bytes(1, 1)), salt: encode(bytes(2, 2)), name: 'Mac' }, 'mac.example.ts.net', device);
  assert.deepEqual(message, { t: 'enrol', cred: 'AQID', key: 'BQY', auth: 'Bw', client: 'BA', prf: 'CQk' });
  const { publicKey: asked } = device.asked[0];
  assert.deepEqual(asked.rp, { id: 'mac.example.ts.net', name: 'Remotey' });
  assert.equal(asked.user.name, 'Mac');
  assert.deepEqual(asked.challenge, new Uint8Array([1, 1]));
  assert.deepEqual(asked.pubKeyCredParams, [{ type: 'public-key', alg: -7 }]);
  assert.deepEqual(asked.authenticatorSelection, { authenticatorAttachment: 'platform', residentKey: 'required', userVerification: 'required' });
  assert.deepEqual(asked.extensions.prf.eval.first, new Uint8Array([2, 2]));
});

test('a passkey that gives out no secret, or comes without its public key, enrols nothing', async () => {
  const offer = { challenge: 'AQ', salt: 'Ag', name: 'Mac' };
  await assert.rejects(create(offer, 'h', phone(made({ enabled: true }))));
  await assert.rejects(create(offer, 'h', phone(made(undefined))));
  await assert.rejects(create(offer, 'h', phone(made({ results: { first: bytes(9) } }, { getPublicKey: undefined }))));
  await assert.rejects(create(offer, 'h', { create: async () => { throw new DOMException('declined', 'NotAllowedError'); } }));
});

test('unlocking asks for that one passkey, verified, and sends its signature and secret', async () => {
  const device = phone({ getClientExtensionResults: () => ({ prf: { results: { first: bytes(9), second: undefined } } }),
    response: { authenticatorData: bytes(7, 7), clientDataJSON: bytes(4), signature: bytes(8) } });
  const message = await get({ id: 'AQID', salt: 'Ag', challenge: 'AQ' }, 'mac.example.ts.net', device);
  assert.deepEqual(message, { t: 'unlock', auth: 'Bwc', client: 'BA', sig: 'CA', prf: 'CQ' });
  const { publicKey: asked } = device.asked[0];
  assert.equal(asked.rpId, 'mac.example.ts.net');
  assert.equal(asked.userVerification, 'required');
  assert.deepEqual(asked.allowCredentials, [{ type: 'public-key', id: new Uint8Array([1, 2, 3]) }]);
  assert.deepEqual(asked.challenge, new Uint8Array([1]));
  assert.deepEqual(asked.extensions.prf.eval.first, new Uint8Array([2]));
});

test('without a secret, or declined, nothing is sent', async () => {
  const key = { id: 'AQID', salt: 'Ag', challenge: 'AQ' };
  await assert.rejects(get(key, 'h', phone({ getClientExtensionResults: () => ({}), response: {} })));
  await assert.rejects(get(key, 'h', { get: async () => { throw new DOMException('declined', 'NotAllowedError'); } }));
});
