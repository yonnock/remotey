// The display picker: the Mac's displays as tiles, laid out as they are arranged. A tap puts the pointer on
// one, and the live view follows it there. Sources/Remotey/Displays.swift makes the list and Wire.swift writes
// it; this module reads the `displays` message, says what a tap asks the Mac for (`display`) and draws the map.

import { t } from './strings.js';

const isDisplay = (d) => Number.isInteger(d?.id) && typeof d.name === 'string'
  && [d.x, d.y, d.w, d.h].every(Number.isFinite) && d.w > 0 && d.h > 0;
/** The list of a `displays` message, or null if it has another shape. */
export const readDisplays = (message) => (Array.isArray(message?.list) && message.list.every(isDisplay) ? message.list : null);

export const tapDisplay = (display) => ({ t: 'display', id: display.id });

/** What a screen reader says for a tile. */
export const displayLabel = (display) => t('display.label', display.name, display.pointer);

/**
 * The arrangement as a map: `ratio` is its width over its height, and each tile's place is given in shares
 * (0...1) of the map, so the map can be drawn at any size.
 */
export function arrange(displays) {
  const left = Math.min(...displays.map((d) => d.x)), top = Math.min(...displays.map((d) => d.y));
  const width = Math.max(...displays.map((d) => d.x + d.w)) - left, height = Math.max(...displays.map((d) => d.y + d.h)) - top;
  return { ratio: width / height,
    tiles: displays.map((d) => ({ id: d.id, left: (d.x - left) / width, top: (d.y - top) / height, width: d.w / width, height: d.h / height })) };
}

export class Picker {
  /** `el` holds the map and is hidden while the Mac has one display. `choose(message)` gets what a tap asks for. */
  constructor(el, choose) {
    this.el = el;
    this.choose = choose;
    this.displays = null;
    this.current = false; // whether the Mac answered since the sheet opened
    el.addEventListener('click', (e) => this.tapped(e.target.closest('button')));
    this.draw();
  }

  /** The sheet opens, or the connection changed under it: the map on show takes no tap until the Mac has answered. */
  reset() {
    this.current = false;
    this.draw();
  }

  /** A list from the Mac: on asking, and again whenever a display is plugged in, removed or rearranged. */
  update(displays) {
    this.displays = displays;
    this.current = true;
    this.draw();
  }

  tapped(button) {
    const display = this.current && button && this.displays.find((d) => String(d.id) === button.dataset.display);
    if (display) this.choose(tapDisplay(display));
  }

  draw() {
    const { el } = this, displays = this.displays ?? [];
    el.hidden = displays.length < 2;
    if (el.hidden) return el.replaceChildren();
    const { ratio, tiles } = arrange(displays);
    el.style.setProperty('--ratio', ratio);
    el.setAttribute('aria-busy', !this.current);
    el.replaceChildren(...displays.map((display, i) => {
      const button = document.createElement('button'), glass = document.createElement('span'), name = document.createElement('span');
      button.type = 'button';
      button.className = 'display';
      button.dataset.display = display.id;
      button.disabled = !this.current;
      button.classList.toggle('here', display.pointer);
      if (display.pointer) button.setAttribute('aria-current', 'true');
      button.setAttribute('aria-label', displayLabel(display));
      for (const side of ['left', 'top', 'width', 'height']) button.style.setProperty(side, `${tiles[i][side] * 100}%`);
      // A display's name comes from its maker: set as text, never as markup.
      name.textContent = display.name;
      name.dir = 'auto';
      glass.append(name);
      button.append(glass);
      return button;
    }));
  }
}
