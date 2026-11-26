// The connection to the Mac as a small state machine: what state it is in, what a failure most likely means,
// when to try again, and when a connection that says nothing is dead. The socket itself and what the page
// shows for each state live in remote.js; this module only decides.
//
// States:
//   unpaired     the Mac does not know this phone: nothing to try until it is paired
//   connecting   a socket is on its way, or one was lost and is tried again at once
//   connected    the Mac took the key
//   noAccess     the Mac took the key, but lacks the Accessibility permission: it cannot steer
//   paused       the Mac took the key, and someone at the Mac paused remote control there
//   unreachable  nothing answers: Tailscale off on the phone, the Mac asleep or away
//   stopped      the Mac answers, Remotey on it does not
//   denied       the Mac refused the key: the pairing is no longer valid
//   ended        someone at the Mac ended this phone's session ("Trennen"): not tried again until the user asks
//   offline      the phone has no network
// After a failure the state stays on show while it is tried again, at a growing interval: a phone left
// lying does not knock every second, and the notice does not flicker between a failure and "connecting".

export const RETRY = { first: 500, factor: 2, most: 30_000 };
/** How long a socket may take to get the Mac's answer to its key before it counts as failed. */
export const CONNECT_MS = 10_000;
/** How long the page waits for an answer from the page's own origin when it asks what went wrong. */
export const PROBE_MS = 5_000;

/** The wait before try number `attempt` (0 for the first one after a failure). */
export const retryDelay = (attempt) => Math.min(RETRY.most, RETRY.first * RETRY.factor ** Math.max(0, attempt));

/**
 * What a failed attempt most likely means. `online`: whether the phone has a network. `status`: the HTTP
 * status with which the page's own origin answered, or null if nothing answered. Behind `tailscale serve`
 * a Mac whose agent is not running answers 502 (Bad Gateway); a Mac out of reach does not answer at all.
 * Any other answer comes from the agent itself, whose socket still failed: to the user, it does not answer.
 */
export function cause({ online, status }) {
  if (online === false) return 'offline';
  if (status === null || status === undefined) return 'unreachable';
  return 'stopped';
}

export const FAILURES = new Set(['unreachable', 'stopped', 'offline']);
/** States the page leaves only when the user asks: no try by itself, not on coming back, not on the network's return. */
export const HELD = new Set(['denied', 'unpaired', 'ended']);

export class Link {
  /**
   * `hooks`: open() starts a socket; drop() closes it without a word (it timed out); probe() resolves to the
   * HTTP status of the page's origin or null; online() says whether the phone has a network; changed(state)
   * runs on every change of state; schedule(fn, ms) and cancel(id) are the timers.
   */
  constructor(hooks) {
    this.hooks = hooks;
    this.state = 'connecting';
    this.attempt = 0; // tries since the last connection that worked
    this.timer = 0; // the next try
    this.watch = 0; // the time limit of the try under way
    this.generation = 0; // a try that was overtaken by another must not report
  }

  set(state) {
    if (state === this.state) return;
    this.state = state;
    this.hooks.changed(state);
  }

  /** Whether the Mac took the key on the connection there is. */
  get up() { return this.state === 'connected' || this.state === 'noAccess' || this.state === 'paused'; }

  /**
   * Try now: at the start, on a tap, back in sight and when the network returns. Without a key there is
   * nothing to try; a key the Mac refused is not tried again before the user asks (`ask`).
   */
  begin({ paired = true, ask = false } = {}) {
    this.stop();
    if (!paired) return this.set('unpaired');
    // Refused, unknown or sent away at the Mac, a phone is not tried again behind the user's back: the notice or
    // the first start stays until they ask (a tap, a new pairing, the page opened anew).
    if (HELD.has(this.state) && !ask) return;
    // A failure stays on show while it is tried again by itself; a tap shows that something happens, and
    // starts the intervals over.
    if (ask) this.attempt = 0;
    if (ask || !FAILURES.has(this.state)) this.set('connecting');
    const generation = ++this.generation;
    this.watch = this.hooks.schedule(() => { if (generation === this.generation) { this.hooks.drop(); this.lost(); } }, CONNECT_MS);
    this.hooks.open();
  }

  /** The Mac took the key. `steer`: it has the Accessibility permission. */
  accepted(steer) {
    this.hooks.cancel(this.watch);
    this.attempt = 0;
    this.set(steer ? 'connected' : 'noAccess');
  }

  /**
   * What the Mac says about itself while connected, on `ok` and with every change: `ax` whether it may steer,
   * `paused` whether remote control is paused at the Mac. A paused Mac counts before a missing permission:
   * it is what someone there chose.
   */
  mac({ ax, paused }) {
    if (!this.up) return;
    this.set(paused ? 'paused' : ax ? 'connected' : 'noAccess');
  }

  /** The Mac does not know this phone: no tries until it is paired, which starts over with `begin`. */
  unpaired() {
    this.stop();
    this.generation++;
    this.set('unpaired');
  }

  /** The Mac refused the key. */
  refused() {
    this.stop();
    this.generation++;
    this.set('denied');
  }

  /**
   * The Mac said `bye`: someone there ended this phone's session, and the socket closes right after. Coming back
   * into sight or the network returning must not undo that; only a tap does, or the page opened anew.
   */
  ended() {
    this.stop();
    this.generation++;
    this.set('ended');
  }

  /**
   * The socket closed, or timed out, or fell silent. A connection that worked is tried again at once, since
   * most losses are a moment of radio; a try that failed asks what went wrong and waits a little longer each time.
   */
  async lost() {
    if (HELD.has(this.state)) return;
    this.stop();
    if (this.up) { this.attempt = 0; this.set('connecting'); this.begin(); return; }
    const generation = ++this.generation;
    const online = this.hooks.online();
    const status = online ? await this.hooks.probe() : null;
    if (generation !== this.generation) return; // a tap or the return of the page was quicker
    this.set(cause({ online, status }));
    this.timer = this.hooks.schedule(() => this.begin(), retryDelay(this.attempt++));
  }

  /** Out of sight: no tries in the background. The page begins again when it is back. */
  stop() {
    this.hooks.cancel(this.timer);
    this.hooks.cancel(this.watch);
    this.timer = this.watch = 0;
  }
}

/**
 * Silence on a connection: iOS keeps a socket open that no longer carries anything, and the page would wait
 * for it forever. While the page is in sight it says `ping` every `every` ms; the agent answers `pong`. Anything
 * that arrives counts, so a running stream needs no answer. Nothing for `dead` ms: the connection is dead.
 */
export class Heartbeat {
  constructor({ every = 5_000, dead = 15_000 } = {}) {
    this.every = every;
    this.dead = dead;
    this.heardAt = 0;
    this.pingedAt = 0;
  }

  /** The connection starts, or something arrived on it. */
  heard(now) { this.heardAt = now; }

  /** What to do now: 'dead', 'ping', or null. */
  check(now) {
    if (now - this.heardAt >= this.dead) return 'dead';
    if (now - this.pingedAt >= this.every) { this.pingedAt = now; return 'ping'; }
    return null;
  }
}

/**
 * Asks the page's own origin whether anything answers, for `cause`. Resolves to the HTTP status, or null if
 * nothing answered within PROBE_MS. HEAD sends no page along; the agent answers it with 404, which still says
 * that it runs.
 */
export async function probe(fetcher = globalThis.fetch, url = '/') {
  const abort = new AbortController(), timer = setTimeout(() => abort.abort(), PROBE_MS);
  try {
    return (await fetcher(url, { method: 'HEAD', cache: 'no-store', signal: abort.signal })).status;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}
