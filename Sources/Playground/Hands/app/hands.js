import { createHandTracking, VIRTUAL_SPAN } from './hand-tracking.js';

// The playground's half of hand control. Everything about seeing a hand, when it
// counts as a grab and how it is smoothed is coding cube's `hand-tracking.js`,
// unchanged. This file only does what the cube's `main.js` and `space.js` did
// with its output: draw the two cursors, and fold the per-hand drags into one
// gesture — one hand drags, a second hand joining makes it a two-hand pinch
// whose midpoint drags and whose span zooms.
//
// What leaves the page is that gesture as movement, in camera frames (1 = the
// width of the picture), for HandControl.swift to send on as MIDI.

const post = (message) => globalThis.webkit?.messageHandlers?.hands?.postMessage(message);

const video = document.getElementById('hand-video');
const statusLabel = document.getElementById('hand-status');
const cursors = new Map([...document.querySelectorAll('.hand-cursor')].map((cursor) => [cursor.dataset.hand, cursor]));

// space.js's `dragInput`, keeping only the bookkeeping: what the cube did with
// dx, dy and the span (rotate, zoom) is here "send it to the playground".
class Gesture {
  constructor(emit) {
    this.emit = emit;
    this.drag = null;
  }

  input({ type, id, x = 0, y = 0 }) {
    if (type === 'start') {
      if (this.drag) {
        if (this.drag.second || this.drag.id === id) return false;
        this.drag.second = { id, x, y };
        this.drag.pair = inputPair(this.drag, this.drag.second);
        return true;
      }
      this.drag = { id, x, y, second: null, pair: null };
      this.emit({ type: 'grab' });
      return true;
    }

    if (!this.drag || (this.drag.id !== id && this.drag.second?.id !== id)) return false;

    if (type === 'move') {
      const input = this.drag.id === id ? this.drag : this.drag.second;
      const previous = this.drag.second ? this.drag.pair : { x: input.x, y: input.y, span: 0 };
      input.x = x;
      input.y = y;
      const next = this.drag.second ? inputPair(this.drag, this.drag.second) : input;
      if (this.drag.second) this.drag.pair = next;
      this.emit({
        type: 'move',
        // Up is more, as on every fader: the camera's y grows downwards.
        x: (next.x - previous.x) / VIRTUAL_SPAN,
        y: -(next.y - previous.y) / VIRTUAL_SPAN,
        spread: this.drag.second && previous.span > 1 ? (next.span - previous.span) / VIRTUAL_SPAN : 0,
      });
      return true;
    }

    if (type !== 'end' && type !== 'cancel') return false;
    if (this.drag.second) {
      if (this.drag.id === id) {
        this.drag.id = this.drag.second.id;
        this.drag.x = this.drag.second.x;
        this.drag.y = this.drag.second.y;
      }
      this.drag.second = null;
      this.drag.pair = null;
      return true;
    }
    this.drag = null;
    this.emit({ type: 'release' });
    return true;
  }
}

function inputPair(a, b) {
  return {
    x: (a.x + b.x) / 2,
    y: (a.y + b.y) / 2,
    span: Math.hypot(a.x - b.x, a.y - b.y),
  };
}

const gesture = new Gesture(post);

const hands = createHandTracking({
  video,
  onInput: (event) => gesture.input(event),
  onStatus(status, active) {
    statusLabel.hidden = !active;
    statusLabel.value = status;
    statusLabel.toggleAttribute('data-quiet', status.startsWith('Ready') || status === 'Grabbed');
    post({ type: 'status', status, active: Boolean(active) });
  },
  onFeedback({ id, state, visible, x, y }) {
    const cursor = cursors.get(id);
    if (!cursor) return;
    cursor.hidden = !visible;
    if (!visible) return;
    cursor.dataset.state = state;
    cursor.style.setProperty('--hand-x', `${x * 100}vw`);
    cursor.style.setProperty('--hand-y', `${y * 100}vh`);
  },
});

globalThis.lerpHands = {
  enable: () => hands.enable(),
  disable: () => hands.disable(),
};

hands.enable();
