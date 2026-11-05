// Coding cube's activity.js, minus `document.hasFocus()`: this page is a
// click-through overlay that never takes focus, so the cube's test would
// pause it forever. Visible is active; a minimised or hidden window pauses.
const listeners = new Set();

export const isPageActive = () => !document.hidden;

export function onPageActivity(listener) {
  listeners.add(listener);
  listener(isPageActive());
  if (listeners.size > 1) return;
  const notify = () => {
    const active = isPageActive();
    for (const callback of listeners) callback(active);
  };
  for (const event of ['pageshow', 'pagehide']) window.addEventListener(event, notify);
  document.addEventListener('visibilitychange', notify);
}
