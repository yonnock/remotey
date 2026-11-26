// The gesture tour: six steps on the real trackpad, each done when its gesture is recognised. It knows nothing
// of the page: remote.js tells it what the touchpad did (`saw`), and draws what `step` says. The gestures still
// reach the Mac, as they would without the tour: it teaches on the real thing.

/**
 * The steps in order, each with the gesture that completes it. Zooming needs the live view, so without it that
 * step is left out. Tap then drag stays out on purpose (decision log, round 5): three fingers and a held Klick
 * are the ways to drag.
 */
export const STEPS = [
  { key: 'move', done: 'move' },
  { key: 'click', done: 'left' },
  { key: 'scroll', done: 'scroll' },
  { key: 'right', done: 'right' },
  { key: 'drag', done: 'drag' },
  { key: 'zoom', done: 'pinch', view: true },
];

/** A move counts once the pointer went this far, so a touch that was meant as a tap does not end the first step. */
export const MOVE_POINTS = 40;

export class Tour {
  /** `changed()` runs whenever the step or the end changes. */
  constructor(changed = () => {}) {
    this.changed = changed;
    this.steps = [];
    this.index = -1;
    this.travel = 0;
  }

  get on() { return this.index >= 0 && this.index < this.steps.length; }
  get step() { return this.on ? this.steps[this.index] : null; }
  get total() { return this.steps.length; }

  /** Starts over. `view`: the live view is on, so zooming is taught as well. */
  start(view) {
    this.steps = STEPS.filter((s) => !s.view || view);
    this.index = 0;
    this.travel = 0;
    this.changed();
  }

  /** The touchpad recognised `gesture` (move with its distance, left, right, scroll, pinch, drag). */
  saw(gesture, distance = 0) {
    const step = this.step;
    if (!step) return;
    if (gesture === 'move' && step.done === 'move') {
      this.travel += distance;
      if (this.travel < MOVE_POINTS) return;
    } else if (gesture !== step.done) return;
    this.index++;
    this.travel = 0;
    this.changed();
  }

  /** Skipped, or put away: the tour ends where it is. */
  stop() {
    if (this.index === -1) return;
    this.index = -1;
    this.changed();
  }
}
