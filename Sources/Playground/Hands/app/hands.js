import { createHandTracking, OneEuroFilter, VIRTUAL_SPAN } from './hand-tracking.js';

// The playground's half of hand control. Seeing a hand, deciding when it
// counts as a grab and smoothing it are coding cube's `hand-tracking.js`. This
// file does what the cube's `main.js` and `space.js` did with its output — fold
// the per-hand drags into one gesture: one hand drags, a second hand joining
// makes it a two-hand pinch whose midpoint drags and whose span zooms — and
// adds one axis the cube never had: the twist of the pinch, turned like a knob.
//
// What leaves the page is that gesture as movement, in camera frames (1 = the
// width of the picture) and turns (1 = all the way round), for HandControl.swift
// to send on as MIDI. What comes back is what each axis drives, for the
// readout beside the hand.
//
// The drawing is the hand itself, after The Poet Engineer's hand interfaces:
// its skeleton in thin white line over the render, no camera picture, a dial
// round the pinch that turns as the hand does, and the values it is moving
// written beside it.

const TAU = Math.PI * 2;
const post = (message) => globalThis.webkit?.messageHandlers?.hands?.postMessage(message);

const video = document.getElementById('hand-video');
const statusLabel = document.getElementById('hand-status');
const canvas = document.getElementById('hand-overlay');
const context = canvas.getContext('2d');

// space.js's `dragInput`, keeping only the bookkeeping: what the cube did with
// dx, dy and the span (rotate, zoom) is here "send it to the playground". The
// pair's angle is the two-hand twist: a steering wheel rather than a knob.
class Gesture {
  constructor(emit) {
    this.emit = emit;
    this.drag = null;
    this.stroke = null;
  }

  get solo() {
    return this.drag && !this.drag.second ? this.drag.id : null;
  }

  input({ type, id, x = 0, y = 0 }) {
    if (type === 'start') {
      if (this.drag) {
        if (this.drag.second || this.drag.id === id) return false;
        this.#settle();
        this.drag.second = { id, x, y };
        this.drag.pair = inputPair(this.drag, this.drag.second);
        return true;
      }
      this.drag = { id, x, y, second: null, pair: null };
      this.stroke = new Stroke();
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
      // Hands close together make a short wheel whose angle is mostly noise.
      const wheel = this.drag.second && previous.span > VIRTUAL_SPAN * 0.08;
      this.#send({
        // Up is more, as on every fader: the camera's y grows downwards.
        x: (next.x - previous.x) / VIRTUAL_SPAN,
        y: -(next.y - previous.y) / VIRTUAL_SPAN,
        spread: this.drag.second && previous.span > 1 ? (next.span - previous.span) / VIRTUAL_SPAN : 0,
        twist: wheel ? wrap(next.angle - previous.angle) / TAU : 0,
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
      this.stroke = new Stroke();
      return true;
    }
    this.#settle();
    this.drag = null;
    this.emit({ type: 'release' });
    return true;
  }

  /// One hand's knob turned: only a lone pinch is a knob.
  twist(id, turns) {
    if (turns && this.solo === id) this.#send({ x: 0, y: 0, spread: 0, twist: turns });
  }

  /// Where a lone pinch's fingertips are, in frames, for its stroke to judge by.
  grip(id, point) {
    if (this.solo === id) this.stroke?.track(point);
  }

  #send(move) {
    const out = this.stroke && this.solo ? this.stroke.add(move) : move;
    if (out && (out.x || out.y || out.spread || out.twist)) this.emit({ type: 'move', ...out });
  }

  #settle() {
    const held = this.stroke?.flush();
    this.stroke = null;
    if (held) this.#send(held);
  }
}

/// A lone pinch either turns or moves, never both. Twisting swings the palm —
/// which is what the cube tracks — round the fingertips, and lifting rolls the
/// wrist a little, so the pinch point decides: a twist leaves it where it was,
/// a move takes it along. Until one has a clear lead the stroke's movement is
/// held rather than dropped, so a small nudge still lands.
class Stroke {
  static DECIDE = 3 / 256; // three ticks, in frames or in turns

  constructor() {
    this.kind = null;
    this.held = { x: 0, y: 0, spread: 0, twist: 0 };
    this.start = null;
    this.grip = null;
  }

  track(point) {
    this.start ??= point;
    this.grip = point;
  }

  add(move) {
    if (this.kind === 'turn') return { x: 0, y: 0, spread: 0, twist: move.twist };
    if (this.kind === 'move') return { ...move, twist: 0 };
    for (const key of Object.keys(this.held)) this.held[key] += move[key];
    const moved = this.start ? Math.hypot(this.grip.x - this.start.x, this.grip.y - this.start.y) : 0;
    const turned = Math.abs(this.held.twist);
    const most = Math.max(moved, turned);
    if (most < Stroke.DECIDE || Math.min(moved, turned) * 1.5 > most) return null;
    this.kind = turned > moved ? 'turn' : 'move';
    return this.add(this.flush());
  }

  /// What is held, once: on release a stroke too small to decide still lands.
  flush() {
    const held = this.held;
    this.held = { x: 0, y: 0, spread: 0, twist: 0 };
    return held;
  }
}

function inputPair(a, b) {
  return {
    x: (a.x + b.x) / 2,
    y: (a.y + b.y) / 2,
    span: Math.hypot(a.x - b.x, a.y - b.y),
    angle: Math.atan2(b.y - a.y, b.x - a.x),
  };
}

/// The pinch's angle, smoothed as the cube smooths position, with a degree
/// of backlash so a hand held still does not creep the value.
class Knob {
  static BACKLASH = 1.2 * Math.PI / 180;

  constructor() {
    this.filter = new OneEuroFilter(1.2, 0.4);
    this.reset();
  }

  reset() {
    this.raw = null;
    this.held = null;
    this.filter.reset();
  }

  /// Turns since the last frame.
  update(roll, time) {
    this.raw = this.raw === null ? roll : this.raw + wrap(roll - this.raw);
    const angle = this.filter.filter(this.raw, time);
    if (this.held === null) {
      this.held = angle;
      return 0;
    }
    const held = Math.min(Math.max(this.held, angle - Knob.BACKLASH), angle + Knob.BACKLASH);
    const turned = (held - this.held) / TAU;
    this.held = held;
    return turned;
  }
}

const gesture = new Gesture((message) => {
  // A new grab asks afresh, so a stale legend is never drawn.
  if (message.type === 'grab') {
    readout = null;
    changed.clear();
  }
  post(message);
});

// MARK: - What is drawn

const BONES = [[0, 1], [1, 2], [2, 3], [3, 4], [0, 5], [5, 6], [6, 7], [7, 8], [5, 9], [9, 10], [10, 11],
  [11, 12], [9, 13], [13, 14], [14, 15], [15, 16], [13, 17], [0, 17], [17, 18], [18, 19], [19, 20]];
const TIPS = [4, 8, 12, 16, 20];
const AXIS = { x: 'X', y: 'Y', spread: 'SPREAD', twist: 'TWIST' };
const HINT = { blocked: 'open your hand', ineligible: 'open the other fingers', ready: 'pinch to grab' };
const STATE_ALPHA = { blocked: 0.5, ineligible: 0.6, ready: 0.85, pinching: 0.95, grabbed: 1, reacquiring: 0.5 };
const ink = 'rgba(255, 255, 255, 1)';
const halo = 'rgba(0, 0, 0, 0.38)';
const accent = getComputedStyle(document.documentElement).getPropertyValue('--signal').trim() || '#5fd38d';

/// Everything known about one hand on screen, eased toward what the camera saw.
const shown = new Map(['hand-left', 'hand-right'].map((id) => [id, {
  id, knob: new Knob(), points: null, target: null, alpha: 0, targetAlpha: 0, state: 'searching',
  dragging: false, turned: 0, grip: 0, palm: 40,
}]));

/// What each bound axis drives, from HandControl.swift: null until it says.
let readout = null;
/// The parameter a Learn is waiting to bind, if any.
let learning = null;
const changed = new Map();
let width = 0;
let height = 0;
let frame = 0;
let last = 0;

function resize() {
  const ratio = devicePixelRatio || 1;
  width = innerWidth;
  height = innerHeight;
  canvas.width = Math.round(width * ratio);
  canvas.height = Math.round(height * ratio);
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  wake();
}
addEventListener('resize', resize);
resize();

/// The camera picture laid over the render as a mirror, never stretched, so
/// the hand keeps its shape. Midway between fitting the frame inside the view
/// and filling it: a landscape camera over a tall render pane would otherwise
/// either shrink the hand to a strip or crop most of the sides away.
function toScreen({ x, y }) {
  const w = video.videoWidth || 640;
  const h = video.videoHeight || 480;
  const scale = Math.sqrt((width / w) * (height / h));
  return { x: width / 2 + (0.5 - x) * w * scale, y: height / 2 + (y - 0.5) * h * scale };
}

function feedback({ id, state, visible, dragging, landmarks, roll }, time) {
  const hand = shown.get(id);
  if (!hand) return;
  if (dragging && !hand.dragging) {
    hand.knob.reset();
    hand.turned = 0;
  }
  hand.dragging = Boolean(dragging);
  hand.state = state;
  hand.targetAlpha = visible ? STATE_ALPHA[state] ?? 0.5 : 0;
  if (landmarks) {
    hand.target = landmarks.map(toScreen);
    hand.points ??= hand.target.map((point) => ({ ...point }));
    hand.palm = Math.hypot(hand.target[5].x - hand.target[17].x, hand.target[5].y - hand.target[17].y);
  }
  if (dragging && landmarks) {
    gesture.grip(id, { x: 1 - (landmarks[4].x + landmarks[8].x) / 2, y: (landmarks[4].y + landmarks[8].y) / 2 });
  }
  if (dragging && Number.isFinite(roll)) {
    const turns = hand.knob.update(roll, time);
    hand.turned += turns;
    gesture.twist(id, turns);
  }
  wake();
}

function wake() {
  if (!frame) frame = requestAnimationFrame(draw);
}

function draw(now) {
  frame = 0;
  const dt = last ? Math.min((now - last) / 1000, 0.1) : 1 / 60;
  last = now;
  context.clearRect(0, 0, width, height);
  let busy = false;
  for (const hand of shown.values()) {
    const easeIn = hand.targetAlpha > hand.alpha;
    hand.alpha = approach(hand.alpha, hand.targetAlpha, dt, easeIn ? 0.12 : 0.45);
    hand.grip = approach(hand.grip, hand.dragging ? 1 : 0, dt, 0.09);
    if (hand.target && hand.points) {
      hand.points.forEach((point, index) => {
        point.x = approach(point.x, hand.target[index].x, dt, 0.045);
        point.y = approach(point.y, hand.target[index].y, dt, 0.045);
      });
    }
    if (hand.alpha < 0.004 || !hand.points) {
      if (hand.targetAlpha === 0) hand.points = null;
      continue;
    }
    busy = true;
    drawHand(hand);
  }
  const grabbed = [...shown.values()].filter((hand) => hand.dragging && hand.points && hand.alpha > 0.004);
  if (grabbed.length) drawControl(grabbed, now);
  statusLabel.toggleAttribute('data-quiet', [...shown.values()].some((hand) => hand.targetAlpha > 0));
  if (busy || [...shown.values()].some((hand) => hand.targetAlpha > 0)) wake();
  else last = 0;
}

function drawHand(hand) {
  const { points, alpha } = hand;
  const scale = Math.max(hand.palm, 30);
  context.save();
  context.globalAlpha = alpha;
  context.lineCap = 'round';
  context.lineJoin = 'round';
  strokeTwice(() => {
    context.beginPath();
    for (const [a, b] of BONES) {
      context.moveTo(points[a].x, points[a].y);
      context.lineTo(points[b].x, points[b].y);
    }
  }, 1.1);
  context.fillStyle = ink;
  for (const point of points) dot(point, 1.6);
  for (const tip of TIPS) {
    const pinched = (tip === 4 || tip === 8) && (hand.state === 'pinching' || hand.dragging);
    if (pinched) continue;
    strokeTwice(() => ring(points[tip], scale * 0.11), 1);
  }

  // Where the grab is: between thumb and index, closing as they close.
  const grip = pinchPoint(points);
  const pinching = hand.state === 'pinching' || hand.dragging;
  if (pinching) {
    context.fillStyle = hand.dragging ? accent : ink;
    strokeTwice(() => ring(grip, scale * (0.16 - 0.05 * hand.grip)), 1.4);
    context.globalAlpha = alpha * (0.35 + 0.65 * hand.grip);
    dot(grip, scale * 0.05 * (1 + hand.grip));
  }

  const hint = HINT[hand.state];
  if (hint && !hand.dragging) {
    context.globalAlpha = alpha * 0.85;
    label(hint, { x: points[0].x, y: points[0].y + scale * 0.45 }, 'center', 11, 0.85);
  }
  context.restore();
}

/// The dial round the grab, the meter of the value it last moved, and what
/// every bound axis is driving.
function drawControl(grabbed, now) {
  const pinches = grabbed.map((hand) => pinchPoint(hand.points));
  const centre = pinches.length > 1
    ? { x: (pinches[0].x + pinches[1].x) / 2, y: (pinches[0].y + pinches[1].y) / 2 }
    : pinches[0];
  const palm = Math.max(...grabbed.map((hand) => hand.palm), 30);
  const radius = Math.max(26, palm * 0.42);
  const alpha = Math.min(...grabbed.map((hand) => hand.alpha)) * Math.min(...grabbed.map((hand) => hand.grip));
  const turned = pinches.length > 1
    ? Math.atan2(pinches[1].y - pinches[0].y, pinches[1].x - pinches[0].x) / TAU
    : grabbed[0].turned;

  context.save();
  context.globalAlpha = alpha;
  if (pinches.length > 1) {
    strokeTwice(() => {
      context.beginPath();
      context.moveTo(pinches[0].x, pinches[0].y);
      context.lineTo(pinches[1].x, pinches[1].y);
    }, 0.8, 0.55);
  }

  // Sixty ticks, every fifth long, turning with the hand.
  strokeTwice(() => {
    context.beginPath();
    for (let index = 0; index < 60; index += 1) {
      const angle = turned * TAU + index / 60 * TAU;
      const inner = radius - (index % 5 ? 3 : 7);
      context.moveTo(centre.x + Math.cos(angle) * inner, centre.y + Math.sin(angle) * inner);
      context.lineTo(centre.x + Math.cos(angle) * radius, centre.y + Math.sin(angle) * radius);
    }
  }, 0.9, 0.7);

  const rows = (readout || []).map((row) => ({ ...row, at: changed.get(row.axis) ?? 0 }));
  const focus = rows.reduce((best, row) => (!best || row.at > best.at ? row : best), null);
  if (focus) {
    // A knob's meter: 270° from bottom-left, round the top, to bottom-right.
    const start = 0.75 * Math.PI;
    const sweep = 1.5 * Math.PI;
    const outer = radius + 7;
    context.lineCap = 'round';
    strokeTwice(() => {
      context.beginPath();
      context.arc(centre.x, centre.y, outer, start, start + sweep);
    }, 1, 0.3);
    context.strokeStyle = halo;
    context.lineWidth = 5;
    context.beginPath();
    context.arc(centre.x, centre.y, outer, start, start + sweep * focus.fraction);
    context.stroke();
    context.strokeStyle = accent;
    context.lineWidth = 2.5;
    context.stroke();
  }

  // The legend, as lines of [text, size, opacity, colour].
  const lines = [];
  if (learning) {
    lines.push([`LEARN → ${learning.toUpperCase()}`, 11, 1, accent], ['twist, or move, to bind it', 10, 0.7]);
  } else if (readout && !rows.length) {
    lines.push(['NOTHING BOUND', 11, 0.9], ['right-click a parameter, Learn…', 10, 0.6]);
  }
  for (const row of rows) {
    const lit = row === focus && now - row.at < 1200;
    lines.push([`${AXIS[row.axis] ?? '·'} · ${row.param.toUpperCase()}`, 10, lit ? 0.95 : 0.6]);
    lines.push([row.value, lit ? 16 : 13, lit ? 1 : 0.75, lit ? accent : ink, lit ? 26 : 19]);
  }

  // On the thumb's side, clear of the other fingers, unless there is no room.
  const wide = Math.max(0, ...lines.map(([text, size]) => measure(text, size)));
  const fits = (side) => side > 0 ? centre.x + radius + 42 + wide < width - 8 : centre.x - radius - 42 - wide > 8;
  const thumbward = grabbed.length > 1 ? 1 : Math.sign(centre.x - grabbed[0].points[17].x) || 1;
  const side = fits(thumbward) || !fits(-thumbward) ? thumbward : -thumbward;
  const left = side < 0;
  const elbow = { x: centre.x + side * (radius + 14), y: centre.y - radius * 0.7 };
  const anchor = { x: elbow.x + side * 22, y: elbow.y };
  strokeTwice(() => {
    context.beginPath();
    context.moveTo(centre.x + side * radius * 0.72, centre.y - radius * 0.72);
    context.lineTo(elbow.x, elbow.y);
    context.lineTo(anchor.x, anchor.y);
  }, 0.8, 0.6);
  const align = left ? 'right' : 'left';
  const textX = anchor.x + side * 6;
  let y = anchor.y + 4;
  for (const [text, size, opacity, color = ink, advance = 17] of lines) {
    label(text, { x: textX, y }, align, size, opacity, color);
    y += advance;
  }
  context.restore();
}

function font(size) {
  context.font = `500 ${size}px ui-monospace, SFMono-Regular, Menlo, monospace`;
  if ('letterSpacing' in context) context.letterSpacing = '0.06em';
}

function measure(text, size) {
  font(size);
  return context.measureText(text).width;
}

function pinchPoint(points) {
  return { x: (points[4].x + points[8].x) / 2, y: (points[4].y + points[8].y) / 2 };
}

/// Every line twice: a soft dark one under the white, so it reads on any look.
function strokeTwice(path, lineWidth, opacity = 1) {
  const alpha = context.globalAlpha;
  path();
  context.strokeStyle = halo;
  context.lineWidth = lineWidth + 2.5;
  context.globalAlpha = alpha * opacity;
  context.stroke();
  context.strokeStyle = ink;
  context.lineWidth = lineWidth;
  context.stroke();
  context.globalAlpha = alpha;
}

function ring(point, radius) {
  context.beginPath();
  context.arc(point.x, point.y, radius, 0, TAU);
}

function dot(point, radius) {
  context.beginPath();
  context.arc(point.x, point.y, radius, 0, TAU);
  context.fill();
}

function label(text, { x, y }, align, size, opacity, color = ink) {
  const alpha = context.globalAlpha;
  font(size);
  context.textAlign = align;
  context.textBaseline = 'middle';
  context.globalAlpha = alpha * opacity;
  context.lineWidth = 3;
  context.strokeStyle = halo;
  context.strokeText(text, x, y);
  context.fillStyle = color;
  context.fillText(text, x, y);
  context.globalAlpha = alpha;
}

/// Exponential approach with time constant `tau` seconds, frame-rate free.
function approach(value, target, dt, tau) {
  return target + (value - target) * Math.exp(-dt / tau);
}

function wrap(angle) {
  return angle - TAU * Math.round(angle / TAU);
}

// MARK: - Wiring

const hands = createHandTracking({
  video,
  onInput: (event) => gesture.input(event),
  onStatus(status, active) {
    statusLabel.hidden = !active;
    statusLabel.value = status;
    post({ type: 'status', status, active: Boolean(active) });
  },
  onFeedback: (event) => feedback(event, performance.now()),
});

globalThis.lerpHands = {
  enable: () => hands.enable(),
  disable: () => hands.disable(),
  /// `{rows: [{axis, param, value, fraction}], learning}`: what each bound
  /// axis drives now, and what an armed Learn is waiting to bind.
  readout({ rows, learning: armed }) {
    const now = performance.now();
    const before = new Map((readout || []).map((row) => [row.axis, row.value]));
    for (const row of rows) if (before.has(row.axis) && before.get(row.axis) !== row.value) changed.set(row.axis, now);
    // A binding Learn just made is the one being moved.
    for (const row of rows) if (!before.has(row.axis) && readout) changed.set(row.axis, now);
    readout = rows;
    learning = armed || null;
    wake();
  },
};

hands.enable();
