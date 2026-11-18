// The phone's passkey for unlocking the Mac: made once, when the agent offers an enrolment, and asked for
// whenever the Mac is locked. iOS shows Face ID for both (or Touch ID, or asks for the phone's code). The
// passkey also gives out a secret (WebAuthn's PRF extension) with which the agent has sealed the Mac's
// password; without one the phone cannot be enrolled. See FaceUnlock.swift and Passkey.swift.

/** Base64 as WebAuthn writes it: `-` and `_`, no padding. */
export function encode(buffer) {
  return btoa(String.fromCharCode(...new Uint8Array(buffer))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
export function decode(text) {
  return Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
}

/** One account per Mac, so that enrolling again replaces the passkey instead of adding another. */
const USER = new TextEncoder().encode('remotey');

/** Whether this browser has passkeys at all. */
export const available = () => typeof globalThis.PublicKeyCredential === 'function' && !!globalThis.navigator?.credentials;

/**
 * Makes the passkey for `offer` ({ challenge, salt, name } as the agent sent them) on the page's `host` and
 * returns the `enrol` message for the agent. Rejects if the user declines, or if the passkey lands where it
 * gives out no secret or the browser does not hand over its public key.
 */
export async function create(offer, host = location.hostname, credentials = navigator.credentials) {
  const credential = await credentials.create({ publicKey: {
    rp: { id: host, name: 'Remotey' },
    user: { id: USER, name: offer.name, displayName: offer.name },
    challenge: decode(offer.challenge),
    pubKeyCredParams: [{ type: 'public-key', alg: -7 }], // ES256, what the agent checks
    authenticatorSelection: { authenticatorAttachment: 'platform', residentKey: 'required', userVerification: 'required' },
    attestation: 'none',
    extensions: { prf: { eval: { first: decode(offer.salt) } } },
  } });
  const response = credential.response, secret = credential.getClientExtensionResults().prf?.results?.first;
  const key = response.getPublicKey?.(), authenticator = response.getAuthenticatorData?.();
  if (!secret || !key || !authenticator) throw new Error('This passkey cannot seal the password');
  return { t: 'enrol', cred: encode(credential.rawId), key: encode(key), auth: encode(authenticator),
    client: encode(response.clientDataJSON), prf: encode(secret) };
}

/**
 * Asks the phone for the passkey `key` names ({ id, salt, challenge } from the agent's `lock`) and returns
 * the `unlock` message: its signature for the challenge and the secret. Rejects if the user declines.
 */
export async function get(key, host = location.hostname, credentials = navigator.credentials) {
  const credential = await credentials.get({ publicKey: {
    challenge: decode(key.challenge),
    rpId: host,
    allowCredentials: [{ type: 'public-key', id: decode(key.id) }],
    userVerification: 'required',
    extensions: { prf: { eval: { first: decode(key.salt) } } },
  } });
  const response = credential.response, secret = credential.getClientExtensionResults().prf?.results?.first;
  if (!secret) throw new Error('The passkey gave out no secret');
  return { t: 'unlock', auth: encode(response.authenticatorData), client: encode(response.clientDataJSON),
    sig: encode(response.signature), prf: encode(secret) };
}
