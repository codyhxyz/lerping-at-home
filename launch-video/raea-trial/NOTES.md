# raea trial: the launch video's opening

> **Superseded.** The whole edit now renders with raea from `../edit/` (`edit/render.sh vN`; see the project README).
> Since this trial, raea has moved to `~/Documents/raea/` (binary at `~/Documents/raea/bin/raea`).
> `~/Documents/raea-trial-src/` has been deleted, including the source clone; the file/line references below are to
> the GitHub repo. `out/opening-raea-run1-nomask.mp4` has also been deleted. `tsconfig.json` here now points at
> `~/Documents/raea`.

Goal: port the opening (frames 0–539 of `Launch`, 1920x1080, 60 fps) from Remotion 4 to raea, render it once and
compare it with `remotion/out/compare-v8/c-glide.mp4` (the same frames, rendered by Remotion).

Scope was cut mid-trial to **one raea render, timed**: no Remotion renders or benchmarks and no incremental re-render
test. The first raea render came out broken (the title's letters were missing; see Bugs), so the port was rendered a
second time with that fixed. There were no other runs.

## Install

raea version: `0.1.0-canary.2` (GitHub pre-release, 2026-10-31). macOS arm64. No account needed.

I did not run the official installer (`curl -fsSL https://raea.io/install | sh`). It writes `~/.raea/`, a symlink at
`~/.local/bin/raea`, and copies the `raea` and `raea-bevy` skills into `~/.claude/skills/`. Instead I did the same
download by hand, into ~/Documents:

```sh
mkdir -p ~/Documents/raea-trial-src/release && cd ~/Documents/raea-trial-src/release
a=raea-0.1.0-canary.2-macos-arm64.tar.gz; u=https://github.com/shinyobjectz/raea/releases/download/v0.1.0-canary.2
curl -fsSLO $u/$a && curl -fsSLO $u/$a.sha256 && shasum -a 256 -c $a.sha256
tar -xzf $a && xattr -dr com.apple.quarantine raea
# binary: ~/Documents/raea-trial-src/release/raea/bin/raea (342 MB; the release is 420 MB unpacked)
git clone --depth 50 https://github.com/shinyobjectz/raea ~/Documents/raea-trial-src/raea   # source, for reading only
```

What this trial put on disk:

| path | what |
|---|---|
| `~/Documents/raea-trial-src/release/` | the release tarball and the unpacked engine, SDK, docs and skills |
| `~/Documents/raea-trial-src/raea/` | shallow source clone (read to diagnose the bug below) |
| `launch-video/raea-trial/` | this port and its outputs |
| `~/Library/Caches/raea/` | raea's bundle and export cache. **It already existed** (from a Nov 4 session's scratchpad bench). raea copies every `.mp4` export into it (about 190 MB each). I deleted this trial's entries (`exports/6e53fc4ef97e5fbe.*`, `exports/d32a4618cba07537.*`, `bundles/b72c230b60d763c4.js`) and removed its lines from `outputs.list`. |

Nothing was written to `~/.raea`, `~/.local/bin` or `~/.claude/skills`. To remove the trial:
`rm -rf ~/Documents/raea-trial-src launch-video/raea-trial`.

## The port

These files are copies of the Remotion edit's files: `Launch.tsx`, `TitleConcepts.tsx`, `timing.ts`, and `picks.json`
(snapshotted with `opening.camera = "glide"`). `media/` holds symlinks to the project's `footage`, `title-assets`
(as `title`), `audio` and `remotion/public/fonts`. raea resolves `staticFile()` to `/media/...`, then looks in
`<edit dir>/media/`.

Render command (the one that produced `out/opening-raea.mp4`):

```sh
cd launch-video/raea-trial
RAEA_PAGE_ROOT=$PWD ~/Documents/raea-trial-src/release/raea/bin/raea render Launch.tsx \
  --composition Opening -o out/opening-raea.mp4 --quality master
```

Typecheck: `../remotion/node_modules/.bin/tsc --noEmit -p tsconfig.json`. It reports no errors in the port's files and
3 errors in raea's shipped SDK (see Bugs).

### Ported 1:1 (no change)

The opening's timing and camera ran unchanged, as did the motion helpers and every CSS feature it uses:

- **Timing and camera:** the beat grid; `useCamera` (glide), `REVEAL` / `revealOnEntry` and the shuffled reveal
  order; `Sequence` (including `layout="none"`) and `Freeze`.
- **Motion helpers:** `interpolate` with clamping. All the `Easing` functions used (`inOut(cubic)`, `out(back(1.4))`,
  `out(exp)`, `in(quad)`, `in(cubic)`, `out(quad)`, `bezier`) use the same formulas as Remotion; I checked both
  sources.
- **Media:** `<Video>` with `playbackRate` and `muted`; `<Audio>` with `trimBefore` and a `volume(frame)` function;
  `<Img>`; importing `picks.json`.
- **CSS:**
  - per-tile `borderRadius` with `overflow: hidden`, `transform: scale()` and opacity;
  - `filter: blur()` and chained `drop-shadow()`;
  - `radial-gradient` and `linear-gradient`;
  - `maskImage` / `WebkitMaskImage` with `maskSize`;
  - `mixBlendMode: screen`;
  - `clipPath: polygon()`, `boxShadow` and `rotate()` (the wipe).
- **The montage label:** the Geist Mono text.
- **The molten title:** it is time-remapped by putting `Freeze frame={metalFrame(...)}` around a `<Video>`. That
  works because raea's `<Video>` seeks to an exact frame (`sourceFrame = startFrom + frame * playbackRate`,
  `sdk/video/src/media.tsx:76`). The renders put the same metal frame on screen.

### Needed changes (5, all mechanical; the diff is marked at the top of each file)

1. `from 'remotion'` → `from 'raea'`.
2. `OffthreadVideo` → `Video`: raea has no `OffthreadVideo`, and its `Video` is already frame-exact. The default
   `objectFit` differs (raea: `cover`; Remotion's `OffthreadVideo`: fill), but every video in this window is 16:9 in a
   16:9 box or sets `objectFit` itself, so this makes no visible difference here.
3. `fonts.ts` used `new FontFace(...)` with `delayRender` / `continueRender`. raea's prelude has no
   `delayRender`/`continueRender`, and its skill says to declare faces with `@font-face`. That is now a `<Fonts/>`
   `<style>` with the same four faces.
4. `useVideoConfig().durationInFrames` → `TOTAL_FRAMES`, so the 540-frame `Opening` composition computes the closing
   card's `Sequence` exactly as the full composition does. Otherwise its duration goes negative, which raea rejects
   with a RangeError, as it should.
5. `registerRoot(...)` at the bottom of `Launch.tsx`, registering `Opening` (540 frames) and `Launch` (full length).

### Couldn't be done

Nothing in this window. Not exercised: the `liquid-glass` concept's SVG `feDisplacementMap` filter (not in the
current picks), the closing card, and frames past 539.

## Bugs and rough edges hit

1. **Inline-style `url(/media/...)` doesn't load. It fails silently: the render exits 0 with the title missing.**
   The title's `maskImage: url(/media/title/wordmark-mask.png)` loaded as empty bytes, so the molten letters were
   masked away entirely. Only the shadow and rim `<Img>`s drew (`out/opening-raea-run1-nomask.mp4`). The only sign
   was one log warning:
   `raea-page: file:///media/title/wordmark-mask.png isn't a file, a data URL or a URL that reads`.
   - Cause: `runtime/page/src/elements.rs:156` (`media_urls`) rewrites `/media/` URLs only in stylesheet text. An
     inline style's URL goes to `FileNet` (`systems/page-net/src/lib.rs:23-51`), which only finds a root-absolute
     path under the roots in `RAEA_PAGE_ROOT`. That variable is not in `docs/settings.md`.
   - Workaround, used for the final render: `RAEA_PAGE_ROOT=<edit dir>`. The composition is unchanged. `<Img src>` and
     `@font-face` URLs were fine without it.
2. **The audio is limited by default.** With no `<Mix>`, raea masters through a look-ahead limiter with a -1 dBFS
   ceiling (`systems/mix/src/offline.rs:169`). Over the drop (7.3–8.9 s) Remotion and the source both peak at
   0.0 dBFS; raea peaks at -0.95 dBFS and its RMS is 0.75 dB lower (-11.75 vs -11.00 dB). I didn't test whether a
   `<Mix>` can turn the limiter off.
3. **The shipped SDK doesn't typecheck on its own.** `csstype` isn't shipped (`sdk/video/src/css.ts:5`), and
   `sdk/video/src/media.tsx:186` has a type error (`AudioProps` is not assignable to `MediaProps`).
4. **The default export is very large.** `--quality master` came out at 178 Mbit/s (194 MB for 9 s; the reference is
   22.6 Mbit/s). The default (bitrate-targeted) mode was not tried.
5. **Log noise.** Bevy asset-watcher and WebAssetPlugin warnings, plus "Vello bump buffers … grown past 1080p" lines.
   The page grows past 1920x1080 while `blur()` is applied. These are informational.
6. **Different colour tags.** raea tags the file bt709 / bt709 / bt709. The Remotion reference is tagged sRGB
   transfer (`iec61966-2-1`) with an unknown matrix. Pixel values agree (below), but players that honour the tags
   may show a slight gamma difference.

No crashes.

## Timing (540 frames, 1920x1080 at 60 fps, M5 / 10 cores / 32 GB, with the user working on the laptop)

| run | wall clock | frames/s (wall) | raea's own figures | peak memory |
|---|---:|---:|---|---:|
| raea run 1 (title mask broken; first launch, cold bundle cache) | 18.07 s | 29.9 | 39.0 fps, 25.5 ms a frame, setup 0.20 s | 1.85 GB |
| **raea run 2 (final, `out/opening-raea.mp4`)** | **14.58 s** | **37.0** | 43.1 fps, 23.2 ms a frame, setup 0.11 s | 1.70 GB |
| Remotion as configured / `--concurrency 8` | not run (scope change) | | | |

- Wall clock covers the whole command: bundling, decoding 36 streams, compositing and VideoToolbox H.264 encoding,
  plus AAC audio.
- `RAEA_*` env vars are part of raea's export-cache key, so run 2 was a real render, not a cache hit.
- An identical re-render (same inputs and env) would be served from the export cache
  (`runtime/bundle/src/cache.rs`). That is the only "incremental" mechanism seen here; it was not tested.

## Fidelity (final render vs `c-glide.mp4`)

The two are frame-aligned: raea frame f matches Remotion frame f better than it matches f±1 in every frame checked.
Every frame (540) was compared with ffmpeg's `ssim` and `psnr` filters (`out/ssim.log`, `out/psnr.log`).

| segment | frames | mean SSIM (min) | mean PSNR, dB (min) |
|---|---|---|---|
| whole opening | 0–539 | **0.9833** (0.9435 @ 291) | **39.16** (28.48) |
| hero, full frame | 0–119 | 0.9791 (0.9528) | 38.60 (31.20) |
| glide zoom-out | 120–299 | 0.9744 (0.9435) | 35.35 (28.48) |
| grid + molten title | 300–405 | 0.9889 (0.9588) | 42.09 (31.38) |
| wipe | 406–432 | 0.9905 (0.9885) | 41.44 (40.07) |
| montage shot 1 + label | 433–539 | 0.9955 (0.9921) | 42.71 (39.81) |

The two files can't be told apart by eye. These all match:

- the camera path;
- which tile pops in on which beat, and the back-eased scale;
- the rounded corners;
- the blur, dim and scrim;
- the molten title, down to the metal frame;
- the wipe's chrome edge;
- the Geist Mono label.

The differences are edge-level only. They show in moving tiles: resampling and sub-pixel placement, and now and then
a neighbouring source frame where `playbackRate=0.8` falls between frames (`out/stills/diff-291-x8.png`, the
difference amplified 8x). On top of that there is encoder noise: VideoToolbox against x264 at CRF 16.

The two dips:

- **The zoom-out (frames 120–299):** the most motion, and the most source pixels being resampled.
- **Frames 296–300:** the title landing. The grid's `blur(0→2.5px)` and the title's `blur(24px→0)` ramp fastest
  there, and Chrome's and raea's (Vello's) gaussian blurs differ slightly.

Audio is aligned within 1.2 ms (normalised correlation 0.998). Levels match until the drop, where raea's limiter takes
off 0.75 dB (bug 2).

## Outputs

- `out/opening-raea.mp4`: the raea render, frames 0–539, 1920x1080, 60 fps, H.264 plus AAC.
- `out/compare.mp4`: Remotion (top) over raea (bottom) at full resolution (1920x2160), labelled. Audio track 1 is
  Remotion's, track 2 is raea's.
- `out/compare-side-by-side.mp4`: the same, half-size and side by side (1920x540), with raea's audio.
- `out/still-sheet.jpg`: pairs at 0.5, 2.0, 3.0, 4.0, 5.0, 6.5, 7.5 and 8.5 s, each annotated with that frame's SSIM
  and PSNR. The full-resolution PNGs are in `out/stills/`.
- `out/stills/title-crop-6.5.png`: a close-up of the title, Remotion over raea.
- `out/stills/diff-291-x8.png`: the worst frame's difference, amplified 8x.
- `out/opening-raea-run1-nomask.mp4`: run 1, kept as evidence of bug 1. It can be deleted (191 MB).
- `out/render.log`, `out/render-run1.log`: the full render logs, with `/usr/bin/time -l`.

## Recommendation: not yet

**For:**

- The port was almost free: five mechanical edits, and the rest of `Launch.tsx` and `TitleConcepts.tsx` ran as
  written.
- Fidelity is effectively identical (SSIM 0.983 with no visible differences).
- 540 frames with 36 simultaneous videos rendered in 14.6 s with the laptop still usable. For rough scale only (not
  measured here): the brief's figure of about 11 minutes for Remotion's 2,629 frames is about 4 frames/s.

**Against, for now:**

- It is a canary that "changes daily", with no stable release and no docs.
- It failed silently on this exact edit: the title disappeared and the command still exited 0. The fix needed an
  undocumented env var found by reading the Rust source.
- It changes the audio master by default.
- Its exports are about 8x larger at `master` quality.

A broken frame with exit code 0 is the failure that matters most for a launch asset. Remotion stays the source of
truth. The raea port in this folder can run as a fast preview render alongside it, since it is the same code. Revisit
once raea has a tagged release that loads inline-style media URLs.
