import React from 'react';
// raea port of remotion/src/TitleConcepts.tsx: imports from 'raea' instead of 'remotion' (./timing is a symlink to
// remotion/src/timing.ts); OffthreadVideo -> Video. Nothing else changed.
import {AbsoluteFill, Easing, Freeze, Img, interpolate, Video, staticFile, useCurrentFrame} from 'raea';
import {beat, DROP} from './timing';

// Every concept draws the same Geist wordmark (title-assets/wordmark-mask.png,
// 3840x746) into the same on-screen rectangle, so they can be swapped in picks.json.
export type Concept =
  | 'liquid-metal-still' | 'titanium' | 'liquid-glass' | 'chrome-gradient' | 'molten' | 'spectral'
  | `metal3d-${string}`;
export const METAL3D = ['chrome', 'black', 'titanium'];
export const CONCEPTS: Concept[] = [
  'titanium', 'liquid-glass', 'chrome-gradient', 'molten', 'spectral', 'liquid-metal-still',
  ...METAL3D.map((look) => `metal3d-${look}` as const),
];

/**
 * The Blender render (title3d/wordmark.py): a full-frame RGBA sequence, one
 * PNG per video frame, frame-locked to the title. The light glide and the slow
 * turn are baked into it. `dir` is title3d/<dir>/ (preview/<look> or final/<look>).
 */
export const METAL3D_FIRST = 100;
export const Metal3DFrame: React.FC<{dir: string; frame: number}> = ({dir, frame}) => (
  <Img
    src={staticFile(`title3d/${dir}/f${String(Math.max(METAL3D_FIRST, frame)).padStart(4, '0')}.png`)}
    style={{position: 'absolute', inset: 0, width: '100%', height: '100%'}}
  />
);

const W = 1920;
const H = 1080;
const ASPECT = 746 / 3840;
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

export type Rect = {left: number; top: number; width: number; height: number};
const rectFor = (width: number, scale: number): Rect => {
  const w = width * scale;
  const h = w * ASPECT;
  return {left: (W - w) / 2, top: (H - h) / 2, width: w, height: h};
};

const mask = (src: string) => {
  const m = `url(${staticFile(src)})`;
  return {WebkitMaskImage: m, maskImage: m, WebkitMaskSize: '100% 100%', maskSize: '100% 100%', WebkitMaskRepeat: 'no-repeat', maskRepeat: 'no-repeat'} as const;
};
const MASK = 'title/wordmark-mask.png';

/** A full-rect layer clipped to the letterforms. */
const Letters: React.FC<{style?: React.CSSProperties; children?: React.ReactNode}> = ({style, children}) => (
  <div style={{position: 'absolute', inset: 0, ...mask(MASK), ...style}}>{children}</div>
);

/** Light streak across the letters; `at` is the frame it starts. */
const Sweep: React.FC<{at: number; strength?: number}> = ({at, strength = 0.95}) => {
  const frame = useCurrentFrame();
  const p = interpolate(frame, [at, at + beat(1.5)], [0, 1], {...clamp, easing: Easing.inOut(Easing.cubic)});
  if (p <= 0 || p >= 1) return null;
  const c = p * 140 - 20;
  return (
    <Letters
      style={{
        background: `linear-gradient(105deg, transparent ${c - 10}%, rgba(255,255,255,${strength}) ${c}%, transparent ${c + 10}%)`,
        mixBlendMode: 'screen',
      }}
    />
  );
};

const Shadow: React.FC<{opacity?: number}> = ({opacity = 1}) => (
  <Img src={staticFile('title/wordmark-shadow.png')} style={{position: 'absolute', inset: 0, width: '100%', height: '100%', opacity}} />
);
const Bevel: React.FC<{opacity?: number; blend?: React.CSSProperties['mixBlendMode']}> = ({opacity = 1, blend = 'overlay'}) => (
  <Img src={staticFile('title/wordmark-bevel.png')} style={{position: 'absolute', inset: 0, width: '100%', height: '100%', opacity, mixBlendMode: blend}} />
);
const Rim: React.FC<{opacity?: number}> = ({opacity = 1}) => (
  <Img src={staticFile('title/concepts/glass-rim.png')} style={{position: 'absolute', inset: 0, width: '100%', height: '100%', opacity, mixBlendMode: 'screen'}} />
);

// ─── Concepts ────────────────────────────────────────────────────────────────

/** iPhone 15 Pro: brushed titanium, warm grey, crisp lit edge. */
const Titanium: React.FC = () => (
  <>
    <Shadow />
    <Letters style={{background: 'linear-gradient(180deg, #f1f0ec 0%, #cfccc6 28%, #8f8b85 49%, #6f6c67 53%, #a7a39d 68%, #dcd9d3 88%, #f4f3f0 100%)'}} />
    <Letters style={{backgroundImage: `url(${staticFile('title/concepts/brushed.png')})`, backgroundSize: '100% 100%', mixBlendMode: 'overlay', opacity: 0.28}} />
    <Bevel opacity={0.9} />
    <Rim opacity={0.9} />
  </>
);

/** Linear / Vercel: white-to-silver gradient, soft bloom, no bevel at all. */
const ChromeGradient: React.FC = () => (
  <>
    <Shadow opacity={0.9} />
    <div style={{position: 'absolute', inset: 0, filter: 'drop-shadow(0 0 28px rgba(255,255,255,.28))'}}>
      <Letters style={{background: 'linear-gradient(180deg, #ffffff 0%, #ffffff 38%, #c9c9d2 72%, #8e8e9a 100%)'}} />
    </div>
    <Rim opacity={0.35} />
  </>
);

/**
 * The product itself: upstream LiquidMetal in image mode, run once per glyph
 * (recorder/shaders/liquid-metal-glyphs.metal), so every letter is its own
 * little liquid-metal logo and the bands roll across the word. Its own motion
 * is the shimmer, so it gets no Sweep. Rendered at the wordmark's exact
 * aspect, so it fills 1:1.
 */
/**
 * The metal's speed is time-remapped rather than played at a fixed rate:
 * `liquid-metal-glyphs-120.mp4` is the same shader rendered at 120 frames per
 * second of shader time (LerpRecord --speed 0.5 --seconds 72 --start 6, so
 * 36 s of metal), and each video frame picks the source frame for the shader
 * time reached by integrating `speed` (1 = the shader's own speed). So the
 * metal can surge into the drop and coast to rest on the closing card without
 * a jump. Speeds below 0.5 repeat source frames.
 */
const METAL_SRC = 'footage/special/liquid-metal-glyphs-120.mp4';
const METAL_SRC_RATE = 120; // source frames per shader-second
const METAL_SRC_FRAMES = 4320;
export type MetalClock = {speed: (frame: number) => number; offset?: number};
const metalFrame = (frame: number, {speed, offset = 0}: MetalClock) => {
  let shaderSeconds = offset;
  for (let f = 0; f < frame; f++) shaderSeconds += speed(f) / 60;
  return Math.min(METAL_SRC_FRAMES - 1, Math.max(0, Math.round(shaderSeconds * METAL_SRC_RATE)));
};

export const Molten: React.FC<{clock?: MetalClock}> = ({clock = {speed: () => 1}}) => {
  const frame = useCurrentFrame();
  return (
    <>
      <Shadow />
      {/* A tight dark halo keeps the chrome's bright edges off bright tiles. */}
      <div style={{position: 'absolute', inset: 0, filter: 'drop-shadow(0 0 1.5px rgba(0,0,0,.85)) drop-shadow(0 4px 14px rgba(0,0,0,.6))'}}>
        <Letters>
          <Freeze frame={metalFrame(frame, clock)}>
            <Video src={staticFile(METAL_SRC)} muted style={{width: '100%', height: '100%', objectFit: 'fill'}} />
          </Freeze>
        </Letters>
      </div>
      <Rim opacity={0.3} />
    </>
  );
};

/** Apple Intelligence: chrome-gradient letters with a slowly turning spectrum glow behind them. */
const Spectral: React.FC = () => {
  const frame = useCurrentFrame();
  const turn = (frame * 1.2) % 360;
  const spectrum = `conic-gradient(from ${turn}deg at 50% 50%, #ff6778, #ffba71, #f5b9ea, #8d99ff, #4cc8ff, #6cf0c2, #ff6778)`;
  return (
    <>
      <div style={{position: 'absolute', inset: '-20%', filter: 'blur(46px)', opacity: 1}}>
        <div style={{position: 'absolute', inset: '16.7%', ...mask(MASK), background: spectrum}} />
      </div>
      <div style={{position: 'absolute', inset: '-20%', filter: 'blur(14px)', opacity: 1}}>
        <div style={{position: 'absolute', inset: '16.7%', ...mask(MASK), background: spectrum}} />
      </div>
      <Letters style={{background: 'linear-gradient(180deg, #ffffff 0%, #f3f3f6 45%, #b9b9c4 100%)'}} />
      <Rim opacity={0.4} />
    </>
  );
};

const LiquidMetalStill: React.FC = () => (
  <>
    <Shadow />
    <Img src={staticFile('title/wordmark-liquid-metal.png')} style={{position: 'absolute', inset: 0, width: '100%', height: '100%'}} />
  </>
);

/**
 * macOS Tahoe Liquid Glass: the letters are glass and refract the live grid
 * behind them. `behind` is a second copy of whatever is under the title; it is
 * displaced through a normal map of the wordmark (with a little chromatic
 * aberration) and clipped to the letters. Full-frame, so it lines up with the
 * real grid pixel for pixel.
 */
export const LiquidGlassLayer: React.FC<{rect: Rect; behind: React.ReactNode; opacity: number}> = ({rect, behind, opacity}) => {
  const S = 96 * (rect.width / 1380);
  const id = 'lerp-glass';
  const displace = (scale: number, result: string) => (
    <feDisplacementMap in="SourceGraphic" in2="nmap" scale={scale} xChannelSelector="R" yChannelSelector="G" result={result} />
  );
  return (
    <AbsoluteFill style={{opacity}}>
      <svg width={0} height={0} style={{position: 'absolute'}}>
        <filter id={id} x={0} y={0} width={W} height={H} filterUnits="userSpaceOnUse" primitiveUnits="userSpaceOnUse" colorInterpolationFilters="sRGB">
          <feFlood floodColor="rgb(128,128,128)" result="neutral" />
          <feImage href={staticFile('title/concepts/glass-normal.png')} x={rect.left} y={rect.top} width={rect.width} height={rect.height} preserveAspectRatio="none" result="map" />
          <feComposite in="map" in2="neutral" operator="over" result="nmap" />
          {displace(S * 1.1, 'dr')}
          {displace(S, 'dg')}
          {displace(S * 0.9, 'db')}
          <feColorMatrix in="dr" type="matrix" values="1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0" result="r" />
          <feColorMatrix in="dg" type="matrix" values="0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0" result="g" />
          <feColorMatrix in="db" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0" result="b" />
          <feComposite in="r" in2="g" operator="arithmetic" k2={1} k3={1} result="rg" />
          <feComposite in="rg" in2="b" operator="arithmetic" k2={1} k3={1} result="rgb" />
          <feGaussianBlur in="rgb" stdDeviation={1.6} />
        </filter>
      </svg>
      <AbsoluteFill
        style={{
          filter: `url(#${id}) brightness(1.06) saturate(1.3)`,
          WebkitMaskImage: `url(${staticFile(MASK)})`,
          maskImage: `url(${staticFile(MASK)})`,
          WebkitMaskSize: `${rect.width}px ${rect.height}px`,
          maskSize: `${rect.width}px ${rect.height}px`,
          WebkitMaskPosition: `${rect.left}px ${rect.top}px`,
          maskPosition: `${rect.left}px ${rect.top}px`,
          WebkitMaskRepeat: 'no-repeat',
          maskRepeat: 'no-repeat',
        }}
      >
        {behind}
      </AbsoluteFill>
      <div style={{position: 'absolute', ...rect}}>
        <Letters style={{background: 'linear-gradient(180deg, rgba(255,255,255,.16), rgba(255,255,255,.02) 55%, rgba(255,255,255,.08))'}} />
        <Rim opacity={1} />
        <Bevel opacity={0.5} blend="soft-light" />
      </div>
    </AbsoluteFill>
  );
};

/**
 * The title over the opening grid. `behind` is only used by liquid-glass,
 * which needs its own copy of the background to refract.
 */
export const TitleConcept: React.FC<{concept: Concept; width: number; behind?: React.ReactNode; enter?: number}> = ({
  concept,
  width,
  behind,
  enter = beat(4),
}) => {
  const frame = useCurrentFrame();
  const t = interpolate(frame, [enter, enter + beat(2)], [0, 1], {...clamp, easing: Easing.out(Easing.exp)});
  const rect = rectFor(width, 1.25 - 0.25 * t);
  const sweeps = (
    <>
      <Sweep at={enter + beat(4)} strength={concept === 'liquid-glass' ? 0.6 : 0.95} />
      <Sweep at={enter + beat(8)} strength={concept === 'liquid-glass' ? 0.6 : 0.95} />
    </>
  );
  if (concept.startsWith('metal3d-')) {
    // No CSS scale or sweep: the turn and the single light glide are in the render.
    const look = concept.slice('metal3d-'.length);
    return (
      <AbsoluteFill style={{opacity: t, filter: `blur(${(1 - t) * 18}px)`}}>
        <div style={{position: 'absolute', ...rectFor(width, 1), top: rectFor(width, 1).top + 14}}>
          <Shadow opacity={0.9} />
        </div>
        <Metal3DFrame dir={`preview/${look}`} frame={frame} />
      </AbsoluteFill>
    );
  }
  if (concept === 'liquid-glass') {
    return (
      <AbsoluteFill style={{filter: `blur(${(1 - t) * 24}px)`}}>
        <div style={{position: 'absolute', ...rect, opacity: t * 0.85}}>
          <Shadow />
        </div>
        <LiquidGlassLayer rect={rect} behind={behind} opacity={t} />
        <div style={{position: 'absolute', ...rect, opacity: t}}>{sweeps}</div>
      </AbsoluteFill>
    );
  }
  // Molten: the metal runs at twice the shader's speed as the word lands and
  // surges to four times by the drop.
  const surge: MetalClock = {speed: (f) => interpolate(f, [enter, beat(DROP)], [2, 4], {...clamp, easing: Easing.in(Easing.quad)})};
  const Body = {titanium: Titanium, 'chrome-gradient': ChromeGradient, molten: Molten, spectral: Spectral, 'liquid-metal-still': LiquidMetalStill}[concept as 'molten'];
  return (
    <div style={{position: 'absolute', ...rect, opacity: t, filter: `blur(${(1 - t) * 24}px)`}}>
      {concept === 'molten' ? <Molten clock={surge} /> : <Body />}
      {concept !== 'molten' && sweeps}
    </div>
  );
};
