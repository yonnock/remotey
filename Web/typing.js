// The text field the iOS keyboard types into. It mirrors what was typed; every change is diffed and
// replayed on the Mac. A zero-width sentinel keeps the field non-empty, because iOS sends no input
// event for backspace in an empty field.
export const SENTINEL = '​';

const segmenter = globalThis.Intl?.Segmenter ? new Intl.Segmenter() : null;
/** User-perceived characters: an emoji with a skin tone or a flag is one backspace. */
export const graphemes = (s) => (segmenter ? [...segmenter.segment(s)].length : Array.from(s).length);

/** What changed from `before` to `after`: how many characters went, and the text that came. */
export function diff(before, after) {
  let p = 0;
  const max = Math.min(before.length, after.length);
  while (p < max && before[p] === after[p]) p++;
  if (p > 0 && before.charCodeAt(p - 1) >= 0xd800 && before.charCodeAt(p - 1) <= 0xdbff) p--; // keep surrogate pairs whole
  const removed = before.slice(p).replace(SENTINEL, ''), added = after.slice(p).replace(SENTINEL, '');
  return { removed: before.length > p ? Math.max(1, graphemes(removed)) : 0, added };
}

/**
 * Relays `field` to the Mac. `out` gets text(s), backspace(n), and key(k) for Enter and for a single
 * character typed while a modifier is armed (`armed()` says so), which becomes a shortcut.
 */
export function relay(field, out) {
  let before = SENTINEL;
  const reset = () => { field.value = before = SENTINEL; };
  reset();
  field.addEventListener('input', (e) => {
    if (e.isComposing) return; // a composition (Japanese, dictation, dead keys) counts once it ends
    const after = field.value, { removed, added } = diff(before, after);
    if (removed) out.backspace(removed);
    if (added) {
      if (out.armed() && graphemes(added) === 1) { out.key(added.toLowerCase()); return reset(); }
      out.text(added);
    }
    before = after;
    if (!after.startsWith(SENTINEL) || (after.length > 60 && after.endsWith(' '))) reset();
  });
  field.addEventListener('compositionend', () => field.dispatchEvent(new Event('input')));
  field.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); out.key('return'); reset(); }
  });
  field.addEventListener('blur', reset);
}
