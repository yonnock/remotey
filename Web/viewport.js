// The part of the page the user can see, and whether the on-screen keyboard takes part of it.
//
// iOS keeps the layout viewport when the keyboard opens and shrinks the visual viewport instead, often
// also shifting it down (offsetTop) to keep the focused field in sight. The page is laid out into the
// visual viewport, at its offset, so nothing sits behind the keyboard or above the visible top.
// Typing is a different state: a focused field with an external keyboard shows no on-screen keyboard.

/** The visual viewport is shorter than the layout viewport by more than this: an on-screen keyboard. */
export const KEYBOARD_MIN = 120;

/**
 * `layout` is the layout viewport { width, height }, `visual` the visual viewport or null.
 * Returns the box to lay the page out in and whether a keyboard is open. While the user zooms the
 * page with two fingers the page keeps the layout viewport, so the zoom magnifies instead of reflowing.
 */
export function frame(layout, visual) {
  if (!visual || visual.scale > 1.01) return { top: 0, height: layout.height, keyboard: false, zoomed: !!visual };
  const top = Math.max(0, Math.round(visual.offsetTop));
  const height = Math.round(Math.min(visual.height, layout.height - top));
  return { top, height, keyboard: layout.height - visual.height > KEYBOARD_MIN, zoomed: false };
}

/** Calls `apply(frame)` now and whenever the visible part changes. */
export function follow(apply) {
  const root = document.documentElement;
  const update = () => {
    // innerHeight follows a pinch zoom in Safari; the root element keeps the layout viewport's size.
    const now = frame({ width: root.clientWidth, height: root.clientHeight }, window.visualViewport ?? null);
    // A page scrolled by iOS while the keyboard was open would leave an empty band once it closes.
    if (!now.keyboard && !now.zoomed && (scrollX || scrollY)) scrollTo(0, 0);
    apply(now);
  };
  window.visualViewport?.addEventListener('resize', update);
  window.visualViewport?.addEventListener('scroll', update);
  addEventListener('resize', update);
  update();
}
