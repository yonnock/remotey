// Pairing per device, and the ticket every connection needs. The agent keeps a key for each phone it paired, in
// a cookie the page cannot read; the page only learns whether it has one by asking for a ticket.
//
// A phone gets paired one of three ways:
//   - the QR code's link names a one-time code in its fragment (`#p=…`), which the page posts to `/pair`
//   - the first start shows a field for the six digits the Mac shows beside the code: posted the same way
//   - a phone paired the old way has the old shared token (in its fragment or stored): posted once to become
//     a device, and not needed after that
// Before each connection `/session` gives a ticket that is good once, for half a minute; the socket's first
// message names it. Only a phone that is no device and could not become one (an agent from before pairing per
// device) sends the old token itself.
//
// Nothing here touches the page: `fetch` and `storage` come in, so Node tests drive it.

/** The six digits the Mac shows beside its QR code. */
export const CODE_LENGTH = 6;

/** What the address's fragment holds: a one-time code, the old token, or nothing. */
export function fragment(hash) {
  const text = String(hash ?? '').replace(/^#/, '');
  if (!text) return null;
  if (text.startsWith('p=')) {
    const code = decodeURIComponent(text.slice(2)).trim();
    return code ? { code } : null;
  }
  // The old link carried the token alone. Anything else with an `=` is no token of ours.
  if (text.includes('=')) return null;
  return { token: decodeURIComponent(text) };
}

/** The digits of what was typed or pasted: spaces, dashes and other signs a Mac or a message may add go. */
export const digits = (text) => String(text ?? '').replace(/\D/g, '').slice(0, CODE_LENGTH);

/**
 * Asks `fetcher` to POST `body` as JSON to `path`. Resolves to { status, json } (json null when the answer has
 * none), or to { status: 0 } when nothing answered.
 */
async function post(fetcher, path, body) {
  try {
    const response = await fetcher(path, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body), cache: 'no-store', credentials: 'same-origin' });
    let json = null;
    try { json = await response.json(); } catch {}
    return { status: response.status, json };
  } catch {
    return { status: 0 };
  }
}

/**
 * Pairs this phone with `body`, { code } or { token }. Resolves to { ok: true, device } or { ok: false, why }:
 *   code     the code is wrong or no longer good
 *   closed   the Mac takes no pairing right now
 *   tries    too many tries
 *   token    the old token is not the Mac's
 *   old      the agent knows no pairing per device (an older agent): the old token is all there is
 *   offline  nothing answered
 */
export async function pair(body, fetcher = globalThis.fetch) {
  const { status, json } = await post(fetcher, '/pair', body);
  if (status === 200 && json?.ok === true) return { ok: true, device: readDevice(json.device) };
  if (status === 0) return { ok: false, why: 'offline' };
  if (status === 404 || status === 405 || status === 501) return { ok: false, why: 'old' };
  // An agent that is restarting behind `tailscale serve` answers through the proxy: that is no word on the code.
  if (status >= 500) return { ok: false, why: 'offline' };
  if (status === 429) return { ok: false, why: 'tries' };
  if (json?.why === 'closed') return { ok: false, why: 'closed' };
  return { ok: false, why: 'token' in body ? 'token' : 'code' };
}

const readDevice = (device) => ({ id: typeof device?.id === 'string' ? device.id : '', name: typeof device?.name === 'string' ? device.name : '' });

/**
 * A ticket for the next connection. Resolves to { ticket }, or { why }: `unpaired` (this phone is no device of
 * the Mac's), `old` (an agent without sessions) or `offline` (nothing answered, or not the agent: while it
 * restarts, the proxy in front of it answers with an error of its own).
 */
export async function session(fetcher = globalThis.fetch) {
  const { status, json } = await post(fetcher, '/session', {});
  if (status === 200 && typeof json?.ticket === 'string' && json.ticket) return { ticket: json.ticket };
  if (status === 404 || status === 405 || status === 501) return { why: 'old' };
  // Only the agent's own "I do not know you" unpairs a phone. Anything else is a try that failed.
  if (status === 401) return { why: 'unpaired' };
  return { why: 'offline' };
}

/** The socket's first message. `standalone`: the page runs from the Home Screen. */
export function auth(credentials, standalone) {
  if (credentials.ticket) return { t: 'auth', ticket: credentials.ticket, standalone: !!standalone };
  return { t: 'auth', token: credentials.token };
}

const TOKEN = 'remotey-token', DEVICE = 'remotey-device';

export class Pairing {
  /** `storage` is localStorage or a stand-in; `fetcher` is fetch. */
  constructor({ storage = globalThis.localStorage, fetcher = (...a) => globalThis.fetch(...a) } = {}) {
    this.storage = storage;
    this.fetcher = fetcher;
    this.old = false; // the agent answered that it knows no pairing per device: no need to ask again
    this.tried = false; // the token was refused as a device once on this page: the next connection does not ask again
    this.asking = null; // the answer under way, shared by everyone who asks meanwhile
  }

  read(key) { try { return this.storage?.getItem(key) ?? null; } catch { return null; } }
  write(key, value) { try { if (value === null) this.storage?.removeItem(key); else this.storage?.setItem(key, value); } catch {} }

  /** The old token, as long as this phone needs it. */
  get token() { return this.read(TOKEN) || ''; }
  /** This phone as the Mac named it when it paired, or null. Whether the Mac still knows it, only a ticket tells. */
  get device() { try { return JSON.parse(this.read(DEVICE) ?? 'null'); } catch { return null; } }

  /** Keeps a token from the address for the way it is used until the agent pairs devices. */
  keepToken(token) { if (token) this.write(TOKEN, token); }

  /** Pairs with `body` ({ code } or { token }); a device it became is kept, and the old token is not needed any more. */
  async pair(body) {
    const result = await pair(body, this.fetcher);
    if (result.ok) {
      this.write(DEVICE, JSON.stringify(result.device));
      this.write(TOKEN, null);
      this.old = false;
    } else if (result.why === 'old') this.old = true;
    return result;
  }

  /**
   * What the next connection authenticates with: { ticket }, { token }, or null for a phone that is not paired.
   * Throws when nothing answered, which the connection counts as a failed try. Two connections that ask at the
   * same time share one answer: the page uses only the newest, and a token posted twice would make two devices.
   */
  credentials() {
    this.asking ??= this.ask().finally(() => { this.asking = null; });
    return this.asking;
  }

  async ask() {
    if (this.old) return this.token ? { token: this.token } : null;
    let answer = await session(this.fetcher);
    // The Mac does not know this phone. One paired the old way posts its token once to become a device. Only
    // then: a Home Screen app from before keeps the token in its start address and has it again at every start.
    if (answer.why === 'unpaired' && this.token && !this.tried) {
      const upgraded = await this.pair({ token: this.token });
      if (upgraded.ok) answer = await session(this.fetcher);
      else if (upgraded.why === 'offline') throw new Error('offline');
      // Refused or out of tries: asking at every reconnect would only use up more of them.
      else this.tried = true;
    }
    if (answer.ticket) return { ticket: answer.ticket };
    if (answer.why === 'offline') throw new Error('offline');
    if (answer.why === 'old') this.old = true;
    // Not a device (any more): what the page kept of it goes. The old token is the way in while the Mac takes it.
    else this.write(DEVICE, null);
    return this.token ? { token: this.token } : null;
  }

  /** The Mac revoked this phone: forget it, so the first start shows. */
  forget() {
    this.write(DEVICE, null);
    this.write(TOKEN, null);
  }
}
