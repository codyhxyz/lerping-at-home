import React from 'react';
import {
  AbsoluteFill,
  Audio,
  Easing,
  Img,
  interpolate,
  OffthreadVideo,
  Sequence,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import picks from './picks.json';
import {beat, CLOSING, DROP, FPS, SONG_START, TOTAL_BEATS} from './timing';
import './fonts';
import {Concept, Molten, TitleConcept} from './TitleConcepts';

type Shot = {look: string; beats: number; rate?: number; start?: number};
const montage = picks.montage as Shot[];

const W = 1920;
const H = 1080;
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const label = (slug: string) => slug.replace('--', '  ·  ').replace(/_/g, ' ');

// ─── Opening: every look at once ────────────────────────────────────────────

const COLS = 6;
const ROWS = 6;
const GAP = 6;

// Deterministic shuffle so tiles pop in scattered, not left-to-right.
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

const Grid: React.FC<{looks: string[]; revealBeats: number; dim?: number}> = ({looks, revealBeats, dim = 0}) => {
  const frame = useCurrentFrame();
  const rank = order(looks.length);
  const tileW = (W - GAP * (COLS + 1)) / COLS;
  const tileH = (H - GAP * (ROWS + 1)) / ROWS;
  // Slow pull-out across the whole title, coming to rest just before the wipe.
  const zoom = interpolate(frame, [0, beat(DROP - 1)], [1.18, 1.0], {...clamp, easing: Easing.out(Easing.quad)});
  return (
    <AbsoluteFill style={{background: '#050608', transform: `scale(${zoom})`}}>
      {looks.slice(0, COLS * ROWS).map((look, i) => {
        // Reveal on sixteenth notes across the first `revealBeats` beats.
        const at = beat((Math.floor((rank[i] / looks.length) * revealBeats * 4)) / 4);
        const t = interpolate(frame, [at, at + 12], [0, 1], {...clamp, easing: Easing.out(Easing.back(1.4))});
        const col = i % COLS;
        const row = Math.floor(i / COLS);
        return (
          <div
            key={look}
            style={{
              position: 'absolute',
              left: GAP + col * (tileW + GAP),
              top: GAP + row * (tileH + GAP),
              width: tileW,
              height: tileH,
              borderRadius: 6,
              overflow: 'hidden',
              opacity: t,
              transform: `scale(${0.82 + 0.18 * t})`,
            }}
          >
            <OffthreadVideo
              src={staticFile(`footage/tiles/${look}.mp4`)}
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
  const t = interpolate(frame, [beat(4), beat(6)], [0, 1], {...clamp, easing: Easing.out(Easing.exp)});
  return (
    <AbsoluteFill>
      {/* The grid steps back as the title lands, so the word owns the frame. */}
      <AbsoluteFill style={{filter: `blur(${4 * t}px)`}}>
        <Grid looks={picks.grid} revealBeats={8} dim={0.5 * t} />
      </AbsoluteFill>
      {/* Scrim: darkens the middle of the grid just enough for the title to read. */}
      <AbsoluteFill
        style={{
          background: 'radial-gradient(ellipse 58% 40% at 50% 50%, rgba(3,4,6,.9), rgba(3,4,6,.35) 70%, rgba(3,4,6,.1))',
          opacity: t,
        }}
      />
      <TitleConcept concept={concept} width={1380} behind={<Grid looks={picks.grid} revealBeats={8} />} />
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
        <OffthreadVideo
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
  return (
    <AbsoluteFill style={{background: '#07080a', opacity: fadeOut}}>
      <AbsoluteFill style={{opacity: 0.32, filter: 'blur(40px) saturate(1.2)', transform: 'scale(1.15)'}}>
        <OffthreadVideo src={staticFile(`footage/1080p/${picks.closingBackground}.mp4`)} muted playbackRate={0.6} />
      </AbsoluteFill>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', gap: 34, flexDirection: 'column'}}>
        <Rise at={land}>
          <div style={{position: 'relative', width: 1000, height: (1000 * 746) / 3840}}>
            <Molten />
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
  const {durationInFrames} = useVideoConfig();
  const end = beat(TOTAL_BEATS);
  return (
    <AbsoluteFill style={{background: 'black'}}>
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
