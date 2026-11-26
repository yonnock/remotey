// The switcher: the Mac's open apps as icons, and the windows of one app to choose from.
// Sources/Remotey/Apps.swift makes the list and Wire.swift writes it; this module reads the `apps` and `icon`
// messages, says what a tap asks the Mac for (`focus`) and draws both views.

import { t } from './strings.js';

/** The most icons the page keeps, and names in its request for the list. */
export const ICONS = 256;

const isWindow = (w) => Number.isInteger(w?.id) && typeof w.title === 'string';
const isApp = (a) => Number.isInteger(a?.pid) && typeof a.name === 'string' && typeof a.icon === 'string'
  && Array.isArray(a.windows) && a.windows.every(isWindow);
/** The list of an `apps` message, or null if it has another shape. */
export const readApps = (message) => (Array.isArray(message?.list) && message.list.every(isApp) ? message.list : null);

/**
 * What a tap on an app asks the Mac for. With one window it is that window, so a minimized one comes out of
 * the Dock; with none known the app comes forward as after a click in the Dock. Null: the app has several
 * windows and the user chooses first, so nothing on the Mac moves before the choice.
 */
export function tapApp(app) {
  if (app.windows.length > 1) return null;
  return { t: 'focus', pid: app.pid, ...(app.windows.length && { win: app.windows[0].id }) };
}
export const tapWindow = (app, window) => ({ t: 'focus', pid: app.pid, win: window.id });

/** A window without a title is named after its app. */
export const windowTitle = (app, window) => window.title.trim() || app.name;

/** What a screen reader says for an app: its name, and what the icon shows without words. */
export function appLabel(app) {
  return [app.name, app.windows.length > 1 && t('apps.choice', app.windows.length), app.front && t('apps.front'),
    app.hidden && t('apps.hidden')].filter(Boolean).join(', ');
}

// Names and titles come from apps and web pages: they are set as text, never as markup, and each runs in its
// own direction, so an Arabic or Hebrew title reads right.
const make = (tag, className, text) => {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) { el.textContent = text; el.dir = 'auto'; }
  return el;
};

export class Switcher {
  /**
   * `parts` are the sheet's elements: `list` (what is tapped), `title`, `note`, `back` and `icon` in its head.
   * `focus(message)` gets what a tap asks the Mac for.
   */
  constructor(parts, focus) {
    this.parts = parts;
    this.focus = focus;
    this.apps = null; // not heard from the Mac yet
    this.current = false; // whether `apps` was sent for this opening of the sheet
    this.chosen = null; // the pid of the app whose windows are shown
    this.notice = '';
    this.pictures = new Map();
    parts.list.addEventListener('click', (e) => this.tapped(e.target.closest('button')));
    // What the finger rests on is lit, and let go of once the finger scrolls the list instead of tapping.
    let pressed = null;
    const release = () => { pressed?.classList.remove('pressed'); pressed = null; };
    parts.list.addEventListener('touchstart', (e) => { release(); pressed = e.target.closest('button'); pressed?.classList.add('pressed'); }, { passive: true });
    for (const type of ['touchmove', 'touchend', 'touchcancel']) parts.list.addEventListener(type, release, { passive: true });
    this.draw();
  }

  /**
   * The sheet opens, or the connection changed under it: all apps again, whatever was chosen. The list
   * known so far is not shown: the order follows use, so the new list would move the icons under a finger
   * that is already on its way. Until the Mac answers, as many blank places stand in as it had apps, and
   * the sheet keeps its height.
   */
  reset() {
    this.chosen = null;
    this.notice = '';
    this.current = false;
    this.draw();
  }

  /** A list from the Mac. An app whose windows are shown keeps them, as long as there is still a choice. */
  update(apps) {
    this.apps = apps;
    this.current = true;
    this.notice = '';
    this.draw();
  }

  /** In place of the list: why there is none. */
  say(text) {
    this.notice = text;
    this.draw();
  }

  /**
   * An icon arrived. It stays for the life of the page, across reconnects: the page names the icons it has
   * when it asks for the list (`known`), and the Mac sends only the others. The newest ICONS are kept.
   */
  picture(id, png) {
    if (typeof id !== 'string' || typeof png !== 'string') return;
    const source = `data:image/png;base64,${png}`;
    this.pictures.delete(id);
    this.pictures.set(id, source);
    if (this.pictures.size > ICONS) this.pictures.delete(this.pictures.keys().next().value);
    for (const img of [this.parts.icon, ...this.parts.list.querySelectorAll('img')]) if (img.dataset.icon === id) img.src = source;
  }

  /** The names of the icons the page has, for the Mac to leave out: at most ICONS, the newest. */
  known() {
    return [...this.pictures.keys()];
  }

  back() {
    const returning = this.parts.list.contains(document.activeElement);
    const from = this.chosen;
    this.chosen = null;
    this.draw();
    if (returning) this.parts.list.querySelector(`[data-pid="${from}"]`)?.focus();
  }

  tapped(button) {
    if (!button || !this.current) return;
    const app = this.apps.find((a) => String(a.pid) === (button.dataset.pid ?? String(this.chosen)));
    if (!app) return;
    if (button.dataset.win) {
      const window = app.windows.find((w) => String(w.id) === button.dataset.win);
      if (window) this.focus(tapWindow(app, window));
      return;
    }
    const message = tapApp(app);
    if (message) return this.focus(message);
    // The windows take the place of the icons, at least as high as what was in sight of them, so the sheet
    // does not jump under the finger.
    const { list } = this.parts, keyboard = list.contains(document.activeElement);
    const height = Math.min(list.offsetHeight, list.parentElement.clientHeight);
    this.chosen = app.pid;
    this.draw();
    list.style.minHeight = `${height}px`;
    if (keyboard) list.querySelector('button')?.focus();
  }

  draw() {
    const { list, title, note, back, icon } = this.parts;
    const apps = this.current ? this.apps : null;
    const app = apps?.find((a) => a.pid === this.chosen && a.windows.length > 1) ?? null;
    this.chosen = app?.pid ?? null;
    back.hidden = icon.parentElement.hidden = !app;
    title.textContent = app ? app.name : t('apps.title');
    title.dir = app ? 'auto' : 'ltr';
    title.classList.toggle('heading', !app);
    note.textContent = app ? t('apps.windows', app.windows.length) : '';
    if (app) this.show(icon, app);
    const view = this.notice ? 'notice' : app ? 'windows' : apps ? 'grid' : 'grid waiting';
    const changed = list.className !== view;
    list.className = view;
    list.style.minHeight = '';
    list.setAttribute('aria-busy', view === 'grid waiting');
    list.replaceChildren(...(this.notice ? [make('p', '', this.notice)]
      : app ? [...app.windows.map((w) => this.row(app, w)), make('p', 'foot', t('apps.windowsNote'))]
        : apps ? apps.map((a) => this.tile(a))
          : Array.from({ length: this.apps?.length || 8 }, () => make('span', 'app ghost'))));
    if (changed) {
      list.parentElement.scrollTop = 0;
      // The new view fades in; a list that only changed does not flicker.
      list.style.animation = 'none';
      void list.offsetWidth;
      list.style.animation = '';
    }
  }

  /** The icon, or the app's first letter until the icon is here. */
  show(img, app) {
    img.dataset.icon = app.icon;
    const source = this.pictures.get(app.icon);
    if (source) img.src = source; else img.removeAttribute('src');
    img.nextElementSibling.textContent = [...app.name][0]?.toUpperCase() ?? '';
  }

  tile(app) {
    const button = make('button', 'app'), box = make('span', 'icon'), img = make('img');
    button.type = 'button';
    button.dataset.pid = app.pid;
    button.classList.toggle('front', app.front);
    button.classList.toggle('away', app.hidden);
    button.setAttribute('aria-label', appLabel(app));
    img.alt = '';
    box.append(img, make('span', 'letter'));
    this.show(img, app);
    // The number says that a tap opens a choice instead of switching at once.
    if (app.windows.length > 1) box.append(make('b', 'count', app.windows.length));
    button.append(box, make('span', 'name', app.name));
    return button;
  }

  row(app, window) {
    const button = make('button', 'window');
    button.type = 'button';
    button.dataset.win = window.id;
    // The window that is in front on the Mac right now.
    if (app.front && window.main) { button.classList.add('front'); button.setAttribute('aria-current', 'true'); }
    button.append(make('span', 'title', windowTitle(app, window)));
    if (window.min) button.append(make('span', 'state', t('apps.minimized')));
    return button;
  }
}
