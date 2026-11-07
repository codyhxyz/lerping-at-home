// raea port: the Remotion edit's Launch.tsx with only these changes (see NOTES.md):
//  - imports from 'raea' instead of 'remotion'; OffthreadVideo -> Video (raea has no OffthreadVideo)
//  - './fonts' (FontFace + delayRender, which raea has neither of) -> an @font-face <style>
//  - useVideoConfig().durationInFrames -> TOTAL_FRAMES, so the 540-frame 'Opening' composition below still
//    computes the closing card's Sequence exactly as the full Launch composition does
//  - registerRoot at the bottom (raea renders a .tsx that registers its compositions)
import React from 'react';
import {
  AbsoluteFill,
  Audio,
  Composition,
  Easing,
  Img,
  interpolate,
  registerRoot,
  Video,
  Sequence,
  staticFile,
  useCurrentFrame,
} from 'raea';
import picks from './picks.json';
import {beat, CLOSING, DROP, FPS, SONG_START, TOTAL_BEATS, TOTAL_FRAMES} from './timing';
import {Concept, Molten, TitleConcept} from './TitleConcepts';

type Shot = {look: string; beats: number; rate?: number; start?: number};
const montage = picks.montage as Shot[];

const W = 1920;
const H = 1080;
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const label = (slug: string) => slug.replace('--', '  ·  ').replace(/_/g, ' ');

// ─── Opening: one look, then the camera steps back to the whole grid ─────────
//
// The film opens full-frame on a single look (the hero), then pulls back in
// steps, each one revealing a ring of new looks, until the hero turns out to be
// one tile of the 6x6 grid. The title lands over the whole grid, and the wipe
// takes it into the drop.

const COLS = 6;
const ROWS = 6;
const GAP = 6;
const TILE_W = (W - GAP * (COLS + 1)) / COLS;
const TILE_H = (H - GAP * (ROWS + 1)) / ROWS;

const opening = (picks as {opening?: {hero?: string; stages?: number[]; titleAt?: number; camera?: 'steps' | 'glide'}}).opening ?? {};
/** The look the film opens on. It is moved into the centre 2x2 if it is not already there. */
const HERO = opening.hero ?? 'fractal-d--Upstream';
/** Beats the camera steps back on: hero → centre 2x2 → centre 4x4 → whole grid. */
const STAGES = opening.stages ?? [0, 4, 7, 10];
/** Beat the title lands on. */
export const TITLE_AT = opening.titleAt ?? 11;
const MOVE_BEATS = 1.5;
const CENTRE = [2 * COLS + 2, 2 * COLS + 3, 3 * COLS + 2, 3 * COLS + 3];

const layout = (() => {
  const looks = picks.grid.slice(0, COLS * ROWS);
  const at = looks.indexOf(HERO);
  const slot = CENTRE[3];
  if (at === -1) looks[slot] = HERO;
  else if (!CENTRE.includes(at)) [looks[at], looks[slot]] = [looks[slot], looks[at]];
  return looks;
})();
const heroIndex = layout.indexOf(HERO);

type Rect = {x: number; y: number; w: number; h: number};
const tileRect = (i: number): Rect => ({
  x: GAP + (i % COLS) * (TILE_W + GAP),
  y: GAP + Math.floor(i / COLS) * (TILE_H + GAP),
  w: TILE_W,
  h: TILE_H,
});
/** Which camera stage first shows tile i: 0 hero, 1 centre 2x2, 2 centre 4x4, 3 the rest. */
const stageOf = (i: number) => {
  if (i === heroIndex) return 0;
  const col = i % COLS;
  const row = Math.floor(i / COLS);
  const ring = Math.max(Math.abs(col - 2.5), Math.abs(row - 2.5)) - 0.5; // 0, 1, 2 out from the centre
  return ring + 1;
};

/** Camera for each stage: the content point at the centre of the frame, and the zoom. */
const cameras = [0, 1, 2, 3].map((stage) => {
  if (stage === 0) {
    // Overscan the hero so its rounded corners sit off-frame.
    const r = tileRect(heroIndex);
    return {cx: r.x + r.w / 2, cy: r.y + r.h / 2, s: Math.max(W / r.w, H / r.h) * 1.04};
  }
  const span = stage * 2; // tiles across the centred block
  const blockW = span * TILE_W + (span - 1) * GAP + 2 * GAP;
  const blockH = span * TILE_H + (span - 1) * GAP + 2 * GAP;
  return {cx: W / 2, cy: H / 2, s: Math.min(W / blockW, H / blockH)};
});

/** `steps` holds at each stage and moves on its beat; `glide` is one continuous
 *  pull-back from the first move to the last, tiles still popping in on their beats. */
const CAMERA = opening.camera ?? 'steps';

const useCamera = (frame: number) => {
  if (CAMERA === 'glide') {
    const from = cameras[0];
    const to = cameras[cameras.length - 1];
    const p = interpolate(frame, [beat(STAGES[1]), beat(STAGES[STAGES.length - 1] + MOVE_BEATS)], [0, 1],
      {...clamp, easing: Easing.inOut(Easing.cubic)});
    const s = Math.exp(Math.log(from.s) + (Math.log(to.s) - Math.log(from.s)) * p);
    // Keep the hero's centre on the path that zooms about a fixed point, so the
    // pan and the zoom read as one move rather than a slide plus a scale.
    const k = (from.s / s - 1) / (from.s / to.s - 1 || 1);
    const drift = interpolate(frame, [0, beat(DROP)], [1.05, 1.0], clamp);
    return {cx: from.cx + (to.cx - from.cx) * k, cy: from.cy + (to.cy - from.cy) * k, s: s * drift};
  }
  let cam = cameras[0];
  for (let k = 1; k < cameras.length; k++) {
    const at = beat(STAGES[k]);
    const p = interpolate(frame, [at, at + beat(MOVE_BEATS)], [0, 1], {...clamp, easing: Easing.bezier(0.3, 0, 0.1, 1)});
    if (p <= 0) break;
    const to = cameras[k];
    cam = {
      cx: cam.cx + (to.cx - cam.cx) * p,
      cy: cam.cy + (to.cy - cam.cy) * p,
      s: Math.exp(Math.log(cam.s) + (Math.log(to.s) - Math.log(cam.s)) * p), // zoom moves in log space
    };
  }
  // A slow drift on top, so the frame never sits dead between steps.
  const drift = interpolate(frame, [0, beat(DROP)], [1.05, 1.0], clamp);
  return {...cam, s: cam.s * drift};
};

// Deterministic shuffle so each ring's tiles pop in scattered, not left-to-right.
const order = (n: number) => {
  const idx = Array.from({length: n}, (_, i) => i);
  let s = 7;
  for (let i = n - 1; i > 0; i--) {
    s = (s * 9301 + 49297) % 233280;
    const j = Math.floor((s / 233280) * (i + 1));
    [idx[i], idx[j]] = [idx[j], idx[i]];
  }
  return idx;
};
const rank = order(COLS * ROWS);

/** Frame tile i starts to appear: on its stage's beat, scattered on sixteenths across the next beat. */
const revealAt = (i: number) => {
  const stage = stageOf(i);
  if (stage === 0) return 0;
  const ring = layout.map((_, j) => j).filter((j) => stageOf(j) === stage);
  const pos = ring.sort((a, b) => rank[a] - rank[b]).indexOf(i);
  return beat(STAGES[stage] + Math.floor((pos / ring.length) * 4) / 4);
};
/** Glide: a tile pops in on the sixteenth just before it slides into frame, so
 *  the pull-back never shows empty grid. */
const revealOnEntry = (i: number) => {
  if (i === heroIndex) return 0;
  const r = tileRect(i);
  for (let f = 0; f < beat(DROP); f++) {
    const {cx, cy, s} = useCamera(f);
    const x = W / 2 + (r.x - cx) * s;
    const y = H / 2 + (r.y - cy) * s;
    if (x < W && y < H && x + r.w * s > 0 && y + r.h * s > 0) {
      const sixteenth = beat(0.25);
      return Math.max(0, Math.floor((f - 6) / sixteenth) * sixteenth);
    }
  }
  return beat(STAGES[STAGES.length - 1]);
};
const REVEAL = layout.map((_, i) => (CAMERA === 'glide' ? revealOnEntry(i) : revealAt(i)));

const Grid: React.FC<{dim?: number}> = ({dim = 0}) => {
  const frame = useCurrentFrame();
  const {cx, cy, s} = useCamera(frame);
  return (
    <AbsoluteFill style={{background: '#050608'}}>
      {layout.map((look, i) => {
        const r = tileRect(i);
        // Tiles are laid out in screen space (no CSS scale), so the zoomed-in
        // hero is drawn from its 1080p master at full resolution.
        const x = W / 2 + (r.x - cx) * s;
        const y = H / 2 + (r.y - cy) * s;
        const w = r.w * s;
        const h = r.h * s;
        if (x > W || y > H || x + w < 0 || y + h < 0) return null;
        const at = REVEAL[i];
        const t =
          i === heroIndex
            ? interpolate(frame, [0, 24], [0, 1], clamp)
            : interpolate(frame, [at, at + 12], [0, 1], {...clamp, easing: Easing.out(Easing.back(1.4))});
        if (t <= 0) return null;
        const big = stageOf(i) <= 1;
        return (
          <div
            key={look}
            style={{
              position: 'absolute',
              left: x,
              top: y,
              width: w,
              height: h,
              borderRadius: 6 * s,
              overflow: 'hidden',
              opacity: Math.min(1, t),
              transform: i === heroIndex ? undefined : `scale(${0.82 + 0.18 * t})`,
            }}
          >
            <Video
              src={staticFile(big ? `footage/1080p/${look}.mp4` : `footage/tiles/${look}.mp4`)}
              muted
              playbackRate={0.8}
              style={{width: '100%', height: '100%', objectFit: 'cover'}}
            />
          </div>
        );
      })}
      {dim > 0 && <AbsoluteFill style={{background: `rgba(4,5,7,${dim})`}} />}
    </AbsoluteFill>
  );
};

export const Title: React.FC<{concept?: Concept}> = ({concept = picks.titleConcept as Concept}) => {
  const frame = useCurrentFrame();
  const t = interpolate(frame, [beat(TITLE_AT), beat(TITLE_AT + 2)], [0, 1], {...clamp, easing: Easing.out(Easing.exp)});
  return (
    <AbsoluteFill>
      {/* The grid steps back as the title lands, but stays legible: the reveal is that it is a grid. */}
      <AbsoluteFill style={{filter: `blur(${2.5 * t}px)`}}>
        <Grid dim={0.38 * t} />
      </AbsoluteFill>
      {/* Scrim: darkens the middle of the grid just enough for the title to read. */}
      <AbsoluteFill
        style={{
          background: 'radial-gradient(ellipse 58% 40% at 50% 50%, rgba(3,4,6,.9), rgba(3,4,6,.35) 70%, rgba(3,4,6,.1))',
          opacity: t,
        }}
      />
      <TitleConcept concept={concept} width={1380} enter={beat(TITLE_AT)} behind={<Grid />} />
    </AbsoluteFill>
  );
};

// ─── Wipe ────────────────────────────────────────────────────────────────────

/** Reveals its children behind a diagonal chrome edge travelling left→right, landing on `end`. */
const Wipe: React.FC<{start: number; end: number; children: React.ReactNode}> = ({start, end, children}) => {
  const frame = useCurrentFrame();
  const p = interpolate(frame, [start, end], [0, 1], {...clamp, easing: Easing.in(Easing.cubic)});
  const skew = 420;
  const x = -skew + p * (W + skew * 2);
  const clip = `polygon(0 0, ${x + skew}px 0, ${x}px ${H}px, 0 ${H}px)`;
  const angle = (Math.atan2(skew, H) * 180) / Math.PI;
  return (
    <AbsoluteFill>
      <AbsoluteFill style={{clipPath: clip}}>{children}</AbsoluteFill>
      {p > 0 && p < 1 && (
        <div
          style={{
            position: 'absolute',
            left: x + skew / 2 - 3,
            top: -200,
            width: 6,
            height: H + 400,
            transform: `rotate(${angle}deg)`,
            background: 'linear-gradient(180deg, #8fd8ff, #ffffff 30%, #ffd7a8 55%, #ffffff 75%, #b9a8ff)',
            boxShadow: '0 0 30px 10px rgba(255,255,255,.55), 0 0 90px 30px rgba(140,190,255,.35)',
          }}
        />
      )}
    </AbsoluteFill>
  );
};

const Flash: React.FC<{at: number; strength: number}> = ({at, strength}) => {
  const frame = useCurrentFrame();
  const o = interpolate(frame, [at, at + 14], [strength, 0], {...clamp, easing: Easing.out(Easing.quad)});
  return o > 0 && frame >= at ? <AbsoluteFill style={{background: 'white', opacity: o}} /> : null;
};

// ─── Montage ─────────────────────────────────────────────────────────────────

const ShotView: React.FC<{shot: Shot; cutAt: number}> = ({shot, cutAt}) => {
  const frame = useCurrentFrame();
  // A small push on every cut, so each downbeat lands physically.
  const punch = interpolate(frame, [cutAt, cutAt + 16], [1.07, 1.0], {...clamp, easing: Easing.out(Easing.cubic)});
  const labelIn = interpolate(frame, [cutAt + 4, cutAt + 16], [0, 1], clamp);
  return (
    <AbsoluteFill style={{background: 'black'}}>
      <AbsoluteFill style={{transform: `scale(${punch})`}}>
        <Video
          src={staticFile(`footage/1080p/${shot.look}.mp4`)}
          muted
          playbackRate={shot.rate ?? 1.5}
          trimBefore={shot.start ?? 0}
          style={{width: '100%', height: '100%'}}
        />
      </AbsoluteFill>
      {picks.labels && (
        <div
          style={{
            position: 'absolute',
            left: 64,
            bottom: 52,
            fontFamily: 'Geist Mono',
            fontWeight: 500,
            fontSize: 22,
            letterSpacing: '0.04em',
            color: 'rgba(255,255,255,.78)',
            textShadow: '0 1px 12px rgba(0,0,0,.6)',
            opacity: labelIn,
          }}
        >
          {label(shot.look)}
        </div>
      )}
    </AbsoluteFill>
  );
};

const Montage: React.FC = () => {
  let cursor = DROP;
  return (
    <>
      {montage.map((shot, i) => {
        const cutBeat = cursor;
        cursor += shot.beats;
        // The first shot starts a beat early: it is what the wipe reveals.
        const from = beat(i === 0 ? cutBeat - 1 : cutBeat);
        const to = beat(i === montage.length - 1 ? cursor + 1 : cursor);
        return (
          <Sequence key={i} from={from} durationInFrames={to - from} layout="none">
            <AbsoluteFill>
              <ShotView shot={shot} cutAt={beat(cutBeat) - from} />
            </AbsoluteFill>
          </Sequence>
        );
      })}
    </>
  );
};

// ─── Closing ─────────────────────────────────────────────────────────────────

const Rise: React.FC<{at: number; children: React.ReactNode}> = ({at, children}) => {
  const frame = useCurrentFrame();
  const t = interpolate(frame, [at, at + beat(1.5)], [0, 1], {...clamp, easing: Easing.out(Easing.exp)});
  return <div style={{opacity: t, transform: `translateY(${(1 - t) * 24}px)`, filter: `blur(${(1 - t) * 8}px)`}}>{children}</div>;
};

/** Starts one beat early, under the wipe; everything else is timed from `land`. */
const Closing: React.FC = () => {
  const frame = useCurrentFrame();
  const land = beat(1);
  const fadeOut = interpolate(frame, [land + beat(13), land + beat(15)], [1, 0], clamp);
  // The metal arrives at the speed it hit the drop with and coasts nearly to a
  // stop as the card fades. It starts 18 shader-seconds in, past the stretch
  // the opening used, so the closing word is not a replay of the opening one.
  const coast = {
    offset: 18,
    speed: (f: number) => interpolate(f, [0, land + beat(13)], [4, 0.2], {...clamp, easing: Easing.inOut(Easing.quad)}),
  };
  return (
    <AbsoluteFill style={{background: '#07080a', opacity: fadeOut}}>
      <AbsoluteFill style={{opacity: 0.32, filter: 'blur(40px) saturate(1.2)', transform: 'scale(1.15)'}}>
        <Video src={staticFile(`footage/1080p/${picks.closingBackground}.mp4`)} muted playbackRate={0.6} />
      </AbsoluteFill>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', gap: 34, flexDirection: 'column'}}>
        <Rise at={land}>
          <div style={{position: 'relative', width: 1000, height: (1000 * 746) / 3840}}>
            <Molten clock={coast} />
          </div>
        </Rise>
        <Rise at={land + beat(2)}>
          <div style={{fontFamily: 'SF Pro', fontWeight: 500, fontSize: 44, letterSpacing: '-0.012em', color: '#f5f5f7'}}>
            Native screensavers for Apple Silicon.
          </div>
        </Rise>
        <Rise at={land + beat(4)}>
          <div style={{fontFamily: 'SF Mono', fontWeight: 500, fontSize: 25, letterSpacing: '0.01em', color: '#a1a1a6'}}>
            github.com/codyhxyz/lerping-at-home
          </div>
        </Rise>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ─── Whole film ──────────────────────────────────────────────────────────────

export const Launch: React.FC = () => {
  const durationInFrames = TOTAL_FRAMES;
  const end = beat(TOTAL_BEATS);
  return (
    <AbsoluteFill style={{background: 'black'}}>
      <Fonts />
      <Audio
        src={staticFile('audio/parallel-jalebi.flac')}
        trimBefore={Math.round(SONG_START * FPS)}
        volume={(f) => interpolate(f, [0, 45, beat(CLOSING + 8), end], [0, 1, 1, 0], clamp)}
      />
      <Sequence durationInFrames={beat(DROP)}>
        <Title />
      </Sequence>
      <Wipe start={beat(DROP - 1)} end={beat(DROP)}>
        <Montage />
      </Wipe>
      <Flash at={beat(DROP)} strength={0.55} />
      {(() => {
        let cursor = DROP;
        return montage.slice(0, -1).map((shot, i) => {
          cursor += shot.beats;
          return <Flash key={i} at={beat(cursor)} strength={0.12} />;
        });
      })()}
      <Sequence from={beat(CLOSING - 1)} durationInFrames={durationInFrames - beat(CLOSING - 1)}>
        <Wipe start={0} end={beat(1)}>
          <Closing />
        </Wipe>
      </Sequence>
    </AbsoluteFill>
  );
};

// ─── raea: fonts and registration ───────────────────────────────────────────

/** remotion/src/fonts.ts loads these with FontFace + delayRender; raea loads @font-face from a <style>. */
const Fonts: React.FC = () => (
  <style>{`
    @font-face { font-family: 'Geist'; font-weight: 100 900; src: url('${staticFile('fonts/Geist-VariableFont_wght.ttf')}'); }
    @font-face { font-family: 'Geist Mono'; font-weight: 500; src: url('${staticFile('fonts/geist-mono-latin-500.woff2')}'); }
    @font-face { font-family: 'SF Pro'; font-weight: 1 1000; src: url('${staticFile('fonts/SFNS.ttf')}'); }
    @font-face { font-family: 'SF Mono'; font-weight: 1 1000; src: url('${staticFile('fonts/SFNSMono.ttf')}'); }
  `}</style>
);

/** The opening trial: frames 0–539 of Launch, the same frames as remotion/out/compare-v8/c-glide.mp4. */
export const OPENING_FRAMES = 540;

registerRoot(() => (
  <>
    <Composition id="Opening" component={Launch} durationInFrames={OPENING_FRAMES} fps={FPS} width={1920} height={1080} />
    <Composition id="Launch" component={Launch} durationInFrames={TOTAL_FRAMES} fps={FPS} width={1920} height={1080} />
  </>
));
