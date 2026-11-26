// Keeps the phone's screen on while it is used, and lets it go dark once it is not. A phone left lying with the
// page open would otherwise keep its screen lit and the live view streaming until its battery ran out. Once the
// screen locks, the page goes out of sight and switches the live view off.

/** Without a touch for this long, the phone may lock its screen again as it would anyway. */
export const IDLE_MS = 3 * 60_000;

export class Awake {
  /** `lock` is navigator.wakeLock (or null where there is none); `schedule` and `cancel` are the timers. */
  constructor(lock = globalThis.navigator?.wakeLock ?? null,
    // Wrapped: a browser's timers throw "Illegal invocation" when called as a method of another object.
    { schedule = (fn, ms) => setTimeout(fn, ms), cancel = (id) => clearTimeout(id) } = {}) {
    this.lock = lock;
    this.schedule = schedule;
    this.cancel = cancel;
    this.sentinel = null;
    this.asking = null;
    this.timer = 0;
  }

  /** A touch, or the page back in sight: keep the screen on for the next IDLE_MS. */
  async touched() {
    this.cancel(this.timer);
    this.timer = this.schedule(() => this.release(), IDLE_MS);
    if (!this.lock || this.asking || (this.sentinel && !this.sentinel.released)) return;
    // iOS grants the lock only to a page in sight and drops it when the page goes away; asked again next time.
    this.asking = this.lock.request('screen').then((sentinel) => { this.sentinel = sentinel; }, () => {});
    await this.asking;
    this.asking = null;
  }

  /** Lets the screen lock itself again. */
  async release() {
    this.cancel(this.timer);
    this.timer = 0;
    await this.asking;
    const sentinel = this.sentinel;
    this.sentinel = null;
    try { await sentinel?.release(); } catch {}
  }

  /** Whether the screen is held on right now. */
  get held() { return !!this.sentinel && !this.sentinel.released; }
}
