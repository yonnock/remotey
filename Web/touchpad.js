// Turns the touches on the live view into what the Mac should do: move the pointer, scroll, click, zoom.
// It knows nothing of the page or the socket, so the tests replay touch sequences through it.
//
// One finger moves the pointer, a tap clicks. Two fingers scroll or pinch: which one is decided once per
// gesture, by whether the fingers travel together or apart. A gesture that had two fingers never moves
// the pointer, even after one of them lifts. Three fingers drag: the left button is held while they move,
// as with three-finger drag on a Mac trackpad, and released when one of them lifts.

/** A tap is shorter than this and travels less than TAP_SLOP pixels. */
export const TAP_MS = 250, TAP_SLOP = 8;
/**
 * Two fingers scroll once their centre travels SCROLL_SLOP pixels (any pixel once a two-finger tap is no
 * longer possible), and pinch once their distance changes PINCH_SLOP pixels.
 */
export const SCROLL_SLOP = 6, PINCH_SLOP = 16;
/** Scroll pixels on the Mac per CSS pixel of finger travel, before the user's scroll speed. */
export const SCROLL_GAIN = 1.6;

/** What the user can set on the Regler page, with the defaults "Std." restores: [min, max, step]. */
export const SETTINGS = {
  speed: { initial: 1, range: [0.5, 2, 0.25] },
  acceleration: { initial: 1, range: [0, 2, 0.25] },
  scroll: { initial: 1, range: [0.5, 2.5, 0.25] },
};

/** Every value a setting can take, from its minimum to its maximum: the detents of its slider. */
export function detents(name) {
  const [min, max, step] = SETTINGS[name].range;
  return Array.from({ length: Math.round((max - min) / step) + 1 }, (_, i) => Math.round((min + i * step) * 100) / 100);
}
/** Where `value` sits on the slider, 0 at the left end and 1 at the right. */
export function settingFraction(name, value) {
  const [min, max] = SETTINGS[name].range;
  return (value - min) / (max - min);
}
/** The detent nearest to `fraction` of the slider's travel; a finger past either end holds the end. */
export function settingAt(name, fraction) {
  const all = detents(name);
  return all[Math.round(Math.min(1, Math.max(0, fraction)) * (all.length - 1))];
}
/** One detent up (+1) or down (-1) from `value`, held at the ends. */
export function stepSetting(name, value, direction) {
  const all = detents(name);
  const here = all.reduce((best, v, i) => (Math.abs(v - value) < Math.abs(all[best] - value) ? i : best), 0);
  return all[Math.min(all.length - 1, Math.max(0, here + Math.sign(direction)))];
}
/** The readout: "1,25×", or "aus" for an acceleration of 0 (a linear pointer). */
export function settingText(name, value) {
  return name === 'acceleration' && value === 0 ? 'aus' : `${String(value).replace('.', ',')}×`;
}

// Finger speed in CSS pixels per millisecond: below SLOW the pointer follows 1:1 (times the speed setting),
// from FAST on it gains the full boost.
const SLOW = 0.08, FAST = 1.2, BOOST = 3.5;
/** The speed is measured over this many milliseconds of touch timestamps, so the event rate does not matter. */
const WINDOW = 32;
/** A pause counts as this long at most, so the first move after resting is slow. */
const MAX_INTERVAL = 50;

/** Mac points per CSS pixel of finger travel at `speed` (CSS pixels per millisecond). */
export function gain(speed, { speed: base, acceleration }) {
  const t = Math.min(1, Math.max(0, (speed - SLOW) / (FAST - SLOW)));
  return base * (1 + acceleration * BOOST * t ** 1.5);
}

const centre = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
const centroid = (points) => {
  let x = 0, y = 0;
  for (const p of points.values()) { x += p.x; y += p.y; }
  return { x: x / points.size, y: y / points.size };
};
const spread = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

export class Touchpad {
  /**
   * `out` receives move(dx, dy) in whole Mac points, scroll(dx, dy), scrollEnd(), click(button), pinchStart() (false refuses),
   * pinch(scale) with the scale since the start, pinchEnd(scale), dragStart() and dragEnd().
   * `settings()` returns { speed, acceleration, scroll } at the moment they are needed.
   */
  constructor(out, settings) {
    this.out = out;
    this.settings = settings;
    this.rest = { x: 0, y: 0 }; // of a point, not yet moved
    this.reset();
  }

  reset() {
    this.state = 'idle';
    this.points = new Map();
  }

  /**
   * One touch event. `touches` are all fingers that started on the pad and are still down, as
   * { id, x, y }; `time` is the event's timestamp in milliseconds; `type` is start, move, end or cancel.
   */
  update(type, touches, time) {
    const now = new Map(touches.map((t) => [t.id, { x: t.x, y: t.y }]));
    if (type === 'start') this.started(now, time);
    else if (type === 'move') this.moved(now, time);
    else this.ended(now, time, type === 'cancel');
    this.points = now;
  }

  started(now, time) {
    if (this.state === 'idle') {
      Object.assign(this, { state: 'pending', start: time, travel: 0, held: { x: 0, y: 0 }, samples: [], last: time });
      if (now.size === 1) return; // otherwise several fingers landed in one event
    }
    if (now.size === 2 && (this.state === 'pending' || this.state === 'pointing')) {
      const [a, b] = now.values();
      Object.assign(this, { state: 'two', from: centre(a, b), spread: spread(a, b), centre: centre(a, b), along: 0, apart: 0, refused: false });
      return;
    }
    // A third finger before two fingers chose to scroll or pinch: a drag, once they move.
    if (now.size === 3 && ['pending', 'pointing', 'two'].includes(this.state)) {
      Object.assign(this, { state: 'three', from: centroid(now), centre: centroid(now), previous: centroid(now), samples: [], last: time });
      return;
    }
    this.finish(); // any other finger: the gesture is over
  }

  moved(now, time) {
    if (this.state === 'pending' || this.state === 'pointing') {
      const [id, p] = [...now][0] ?? [];
      const q = this.points.get(id);
      if (!q) return;
      const dx = p.x - q.x, dy = p.y - q.y, distance = Math.hypot(dx, dy);
      this.sample(distance, time);
      if (this.state === 'pending') {
        this.travel += distance;
        this.held.x += dx; this.held.y += dy;
        // The dead zone only holds while a tap is still possible. What it held back is sent once it is a move.
        if (this.travel < TAP_SLOP && time - this.start < TAP_MS) return;
        this.state = 'pointing';
        return this.move(this.held.x, this.held.y);
      }
      return this.move(dx, dy);
    }
    if (this.state === 'three' || this.state === 'dragging') {
      if (now.size !== 3 || this.points.size !== 3) return;
      const c = centroid(now);
      // Speed from each event's travel, so what the slop held back does not count as one fast jump.
      this.sample(Math.hypot(c.x - this.previous.x, c.y - this.previous.y), time);
      this.previous = c;
      if (this.state === 'three') {
        if (Math.hypot(c.x - this.from.x, c.y - this.from.y) < TAP_SLOP) return;
        this.state = 'dragging';
        this.out.dragStart();
        this.centre = this.from; // what the slop held back is the start of the drag
      }
      const dx = c.x - this.centre.x, dy = c.y - this.centre.y;
      this.centre = c;
      return this.move(dx, dy);
    }
    if (now.size !== 2 || this.points.size !== 2) return;
    const [a, b] = now.values(), c = centre(a, b);
    if (this.state === 'two') {
      const along = Math.hypot(c.x - this.from.x, c.y - this.from.y), apart = Math.abs(spread(a, b) - this.spread);
      this.travel = Math.max(this.travel, along, apart);
      Object.assign(this, { centre: c, along, apart });
      // A page without a live view has nothing to zoom: it refuses, and the fingers scroll.
      if (apart >= PINCH_SLOP && apart > along && !this.refused) {
        if (this.out.pinchStart() === false) this.refused = true;
        else this.state = 'pinching';
      }
      if (this.state === 'two') {
        const scrolls = this.refused || (along >= apart && (along >= SCROLL_SLOP || (along >= 1 && time - this.start >= TAP_MS)));
        if (!scrolls) return;
        this.state = 'scrolling';
        this.centre = this.from; // what the slop held back is the start of the scroll
      }
    }
    if (this.state === 'scrolling') {
      const f = SCROLL_GAIN * this.settings().scroll;
      this.out.scroll((c.x - this.centre.x) * f, (c.y - this.centre.y) * f);
      this.centre = c;
    } else if (this.state === 'pinching') {
      this.scale = spread(a, b) / this.spread;
      this.out.pinch(this.scale);
    }
  }

  ended(now, time, cancelled) {
    const quick = !cancelled && time - this.start < TAP_MS && this.travel < TAP_SLOP;
    if (this.state === 'two') {
      this.rightTap = quick;
      // Too slow for a tap, too short to have started a scroll: still a scroll, however small.
      const dx = this.centre.x - this.from.x, dy = this.centre.y - this.from.y;
      if (!quick && !cancelled && this.along && this.along >= this.apart) {
        const f = SCROLL_GAIN * this.settings().scroll;
        this.out.scroll(dx * f, dy * f);
        this.out.scrollEnd();
      }
    }
    if (now.size) {
      // A finger lifted from two: what remains is not a new gesture.
      if (this.state !== 'done') this.finish();
      return;
    }
    if (this.state === 'pending' && quick) this.out.click('left');
    else if ((this.state === 'two' || this.state === 'done') && this.rightTap && quick) this.out.click('right');
    this.finish();
    this.state = 'idle';
    this.rightTap = false;
  }

  finish() {
    if (this.state === 'scrolling') this.out.scrollEnd();
    else if (this.state === 'pinching') this.out.pinchEnd(this.scale ?? 1);
    else if (this.state === 'dragging') this.out.dragEnd();
    if (this.state !== 'idle') this.state = 'done';
  }

  sample(distance, time) {
    const interval = Math.min(MAX_INTERVAL, Math.max(0, time - this.last));
    this.last = time;
    this.samples.push({ time, interval, distance });
    while (this.samples.length > 1 && time - this.samples[0].time > WINDOW) this.samples.shift();
  }

  /** Finger speed over the last few events. */
  speed() {
    let distance = 0, interval = 0;
    for (const s of this.samples) { distance += s.distance; interval += s.interval; }
    return distance / Math.max(4, interval);
  }

  // The Mac moves its pointer by whole points. The page draws the pointer ahead of the Mac's answer, so it
  // has to know by how many: whole points leave here, and the rest counts for the next move.
  move(dx, dy) {
    if (!dx && !dy) return;
    const g = gain(this.speed(), this.settings());
    this.rest.x += dx * g;
    this.rest.y += dy * g;
    const x = Math.trunc(this.rest.x), y = Math.trunc(this.rest.y);
    if (!x && !y) return;
    this.rest.x -= x;
    this.rest.y -= y;
    this.out.move(x, y);
  }
}
