# Lerping@Home: launch video

- `footage/1080p/`: every rotation look (shader + preset) as a 6 s 1080p60 master, rendered frame-exact from the real Metal shaders. Each starts at t=6 s, seed 0.37, the same recipe the gallery thumbnails use.
- `footage/tiles/`, `footage/stills/`, `footage/contact-sheet.jpg`: derived by `footage/make-derivatives.sh`.
- `curation/index.html`: every look looping. Click to pick in order, then "Copy picks.json". Rebuild with `python3 curation/build.py`.
- `title-assets/`: Geist wordmark, masks and metal treatments, plus closing-card pieces (sources in `title-assets/src/`).
- `audio/`: Four Tet, "Parallel Jalebi". The beat grid is in `audio/beats.json`: 133 BPM, downbeat at 0.0240 s, and the drop at bar 96 (2:53.26).
- `edit/`: the edit, rendered by [raea](https://github.com/shinyobjectz/raea) (React/TypeScript on the GPU; the whole video in about a minute and a half). `edit/render.sh vN` writes `remotion/out/launch-mock-vN.mp4` (H.264 CRF 16, AAC 320k) and `launch-mock-vN-preview.mp4` (CRF 26), refuses to overwrite an existing version, and keeps the picks and raea's log it used in `edit/out/vN-<time>/`. `edit/Launch.tsx` and `edit/TitleConcepts.tsx` are the Remotion files with mechanical changes (each file's header lists them); they read `remotion/src/picks.json` and `remotion/src/timing.ts` through the symlinks `edit/picks.json` and `edit/timing.ts` (raea refuses imports outside the edit folder unless a `.git` folder marks a project root, and this project has none), and the assets through symlinks in `edit/media/`. Typecheck: `cd edit && ../remotion/node_modules/.bin/tsc --noEmit -p tsconfig.json` (the 3 errors inside raea's own SDK are raea's). raea quirks that `render.sh` handles:
  - **Pinned to raea 0.1.0-canary.2** at `~/Documents/raea` (the release tarball, unpacked; the official installer was not used, so nothing lives in `~/.raea`, `~/.local/bin` or `~/.claude`). raea is a canary that changes daily: `render.sh` refuses any other version. To move up, unpack the new release there, render, compare against the last version, then bump `PINNED`.
  - **`RAEA_PAGE_ROOT`** must be the edit folder. Without it, an inline-style `url(/media/...)` (the molten title's `maskImage`) loads empty, and the title's letters vanish while raea still exits 0.
  - **Warning check.** That failure's only trace was one WARN line, so `render.sh` fails (exit 3, output kept aside in `edit/out/`) on any warning or error line in raea's log except a short list of known-harmless Bevy startup lines.
  - **Caches off** (`RAEA_BUNDLE_CACHE=0`, `RAEA_EXPORT_CACHE=0`): picks and timing live outside `edit/`, and otherwise every export is copied into `~/Library/Caches/raea`.
  - **Audio limiter.** raea masters through a look-ahead limiter at -1 dBFS and has no way to turn it off (`<Mix>` only allows ceilings at or below 0 dBTP, plus loudness normalisation). The drop's peaks sit about 1 dB under the track's.
- `remotion/`: the previous renderer, kept as the fallback; the picks and the beat grid still live in `remotion/src/`. `npm run studio` to scrub, `npm run render` to export `remotion/out/launch-mock.mp4`. Remotion versions are kept as `out/launch-mock-vN.mp4` with the picks they used in `src/picks.vN.json`. `raea-trial/` is the first raea test of the opening alone (its `NOTES.md` has the side-by-side numbers).
  - `src/picks.json`: grid looks, montage order (beats per shot) (optional per shot: `rate`, the clip's playback speed, default 1.5; `start`; `label: false` for a look that draws its own caption in the label's corner, as the captioned splats do), title treatment, labels on/off. v10 plays splats at `rate: 2.5`: their orbits are slow enough to read as stills at 1.5.
  - `src/timing.ts`: the beat grid. Every cut is `beat(n)`.
  - The opening (16 beats before the drop) starts full-frame on one look, the hero (`fractal-d--Upstream`), and steps back on beats 0/4/7/10: hero, then the centre 2x2, the centre 4x4, and the whole grid. The title lands on beat 11. Override any of these in `picks.json` with `"opening": {"hero": "...", "stages": [0, 4, 7, 10], "titleAt": 11}`.
  - The molten title is time-remapped from `footage/special/liquid-metal-glyphs-120.mp4`, which is 120 frames per shader-second (`LerpRecord --speed 0.5 --seconds 72`, same glyph flags as below). In the opening the metal runs at 2x and surges to 4x by the drop. On the closing card it comes in at 4x and eases to 0.2x as the card fades.

## Re-rendering footage

```sh
footage/render.sh              # every look remotion/src/picks.json uses
footage/render.sh --all        # the whole rotation, for the curation page
footage/render.sh aurora/Ember # just these
```

It renders from a clean snapshot of `origin/main` (never the working checkout, so uncommitted shader edits stay out), builds the recorder once per LerpCore version (`recorder/bin/`), and runs one recorder at a time.

Clips are content-addressed in `footage/store/<look>/<key>.mp4`. The key hashes what decides the pixels: the exact Metal source compiled (prelude + shader), the look's parameter values and drifts, the render settings, and the engine Swift that runs the frame (the renderer and parameter packing for plain shaders; all of LerpCore for shaders with a data provider). A look whose key is already stored is relinked, not rendered, so only shaders that changed get re-rendered, and reverting a shader costs nothing. `footage/1080p/<look>.mp4` is a hard link to the current key. Tiles and stills are made once per key beside it. Nothing is deleted: a replaced pre-store clip becomes `legacy-<date>.mp4`, and `history.tsv` logs each render with the `origin/main` commit it came from.

Rebuild after editing `recorder/RecordMain.swift`: the next `render.sh` rebuilds automatically (the binary name includes its hash), but keys only change when `render_version` in `render.sh` is bumped: do that when an edit changes how frames are made or encoded.

The molten title (`footage/special/liquid-metal-glyphs.mp4`) is LiquidMetal run once per glyph:

```sh
python3 recorder/process_glyphs.py title-assets/wordmark-mask.png recorder/shaders/wordmark-glyphs.png 2760
cd ~/code/claude/lerping-at-home && launch-video/recorder/LerpRecord OUTDIR \
    --size 2760x536 --seconds 10 --only liquid-metal-glyphs \
    --shaders launch-video/recorder/shaders \
    --wordmark launch-video/recorder/shaders/wordmark-glyphs.png
```

## Music licensing

"Parallel Jalebi" is a commercial track. It's fine for the mock, but a public post needs a licensed or royalty-free track. Platforms will mute it or claim it otherwise.

## hdr-compare/ — SDR vs HDR side by side (real HDR video)

    ./hdr-compare/grab.sh                 # real window chrome (opens two windows ~1 s each)
    python3 hdr-compare/build_plate.py    # wallpaper + windows + captions -> plate/mask/layout
    cd hdr-compare/edr-src && ../HDRCompare ../out/lerping-sdr-vs-hdr.mp4 \
        --looks "liquid-metal,gem-smoke/Fire,smoke-ring/Solar,heatmap/Default,pulsing-border" --seconds-each 4.5

With music (`out/lerping-sdr-vs-hdr-v2.mp4`): The Prodigy, "Medusa's Path" (`hdr-compare/audio/`),
110.07 BPM, from the drop after the breakdown at 3:21.30. Render with `--seconds-each 4.36075`
(two bars a look), then mux with `-ss 201.30` and a fade over the last bar. Licensing is the same
problem as the launch track's.

`edr-src/` is `git archive cf7ebd1` (EDR phase 1). The HDR window uses LerpEDR's own
expand pass at a fixed 4x peak. Output: HEVC Main10, HLG BT.2020, SDR white = 203 nits.
