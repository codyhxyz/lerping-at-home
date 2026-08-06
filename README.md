# Lerping@Home

- Screensaver for macOS that renders procedural shaders with Metal.
- Shaders are single `.metal` files compiled at runtime via `MTLDevice.makeLibrary(source:)`.
- 30 built-in shaders: aurora, color-panels, dithering, dot-grid, dot-orbit, fluted-glass, gem-smoke, god-rays, grain-gradient, halftone-cmyk, halftone-dots, heatmap, liquid-metal, mesh-gradient, metaballs, neuro-noise, paper-texture, perlin-noise, pipes, pulsing-border, simplex-noise, smoke-ring, spiral, static-mesh-gradient, static-radial-gradient, swirl, voronoi, warp, water, waves.
- Custom `.metal` files are supported without rebuilding the engine.
- No Xcode project. Builds with `swiftc` through a Makefile.
- No build-time Metal toolchain and no precompiled shader archive.

## Requirements

- macOS 14 or later.
- Apple Silicon.
- Xcode command-line tools (`swiftc`).

## Install

```sh
make install               # builds and copies Lerping@Home.saver to ~/Library/Screen Savers
make install-playground    # optional: copies LerpPlayground.app to ~/Applications
```

### Screen saver

- Select **Lerping@Home** in System Settings → Screen Saver.
- First activation can show black briefly while Gatekeeper verifies the bundle.
- Shader, preset, frame rate, and render scale are set behind the saver's Options…
  button. Pinning a shader also lets you pin one of its presets.
- Options… also has an **In rotation** gallery: pick which *looks* Shuffle draws
  from, by looking at them. Shuffle rotates over (shader, preset) pairs, not just
  shaders — each shader contributes its declared defaults plus one entry per
  `// lerp-preset:` it declares, which is 114 looks across the 31 shaders rather
  than 31. Every look is a portrait still of itself; click a tile to put it in or
  take it out. They are grouped under a shader heading whose checkbox turns the
  whole group on or off and carries an *n/m* count, and there is a search field,
  Select All / Deselect All (which act on what the search is showing), and a
  status line. New shaders and newly added presets join the rotation
  automatically; selecting nothing means all.
- The stills are rendered into the bundle by `make saver`, so opening Options…
  does no GPU work: the sheet is built in about 120 ms and the pictures are on
  screen a tenth of a second later. That matters because the sheet is built
  inside `legacyScreenSaver`, which is App Sandboxed — see "What the sandbox
  allows" below. Anything the bundle does not have a still for (a custom shader,
  a shader edited since the build) is rendered on the spot, in parallel, into a
  cache inside the sandbox container. Nothing ever blocks the sheet.
- The same gallery is a window of its own in the playground
  (**Shader → Screensaver Rotation…**, ⌥⌘R), where clicking a tile writes the
  screensaver's rotation immediately. It is one implementation, in
  `Sources/LerpCore/RotationGallery.swift`.
- Options… has a **Set desktop picture to the last frame** checkbox, off by default.
  See "Desktop picture handoff" below.

### Playground

Optional, and only for the shader editor described under "Shader playground"
below — the saver does not need it.

- `make install-playground` copies `build/LerpPlayground.app` to
  `~/Applications/LerpPlayground.app`, signs it again and registers it, so typing
  "lerp" into Spotlight offers it. `/Applications`, `/System/Applications` and
  `~/Applications` are the only places Spotlight's Applications category draws
  from; the bundle in `build/` is indexed and `open -a` finds it, but Spotlight
  will not offer it.
- A copy, not a symlink. Spotlight resolves symlinks and indexes the app at its
  real path, so a link in `~/Applications` leaves it exactly as unfindable.
- The installed copy edits the checkout it was installed from, recorded as
  `LerpRepoRoot` in its own `Info.plist` — it cannot walk up to one the way the
  in-repo build does, because nothing above `~/Applications` is a checkout.
  Re-run the target to re-point it.
- That path is the **main working tree**, not `$PWD`: installing from a git
  worktree records the checkout the worktree belongs to, because the worktree
  itself is deleted when its branch is done and an app pointed at it would break
  the moment it was. Override it, or install from outside a git repo, with:

```sh
make install-playground PLAYGROUND_REPO=/path/to/lerping-at-home
```

- Either way the target checks before it copies anything: a `PLAYGROUND_REPO`
  with no `Sources/Shaders` in it stops the install and says so, rather than
  baking in a path that does not work.

- If that checkout later moves, the app says so at launch — by name, with the
  path that is gone — and offers a folder picker. It never opens onto an empty
  shader list. What you pick is remembered;
  `defaults delete com.hergenroeder.lerping.playground.installed LerpRepoRoot`
  forgets it, and `LERP_REPO_ROOT=/some/checkout` overrides it for one launch.
- `LerpPlayground --shaders` prints which checkout a copy resolved, how it got
  there, and what it found, and exits non-zero if it found nothing.
  `make install-playground` runs it against the copy it just installed, so the
  target fails if the install cannot see your shaders.
- The installed copy has a bundle identifier of its own
  (`com.hergenroeder.lerping.playground.installed`), so it and the in-repo build
  are two apps and not two copies of one: `make playground` always opens the one
  in `build/`, and neither ever raises the other. They look alike in ⌘-Tab, so
  the installed copy's window title also names the checkout it is editing.
- `make uninstall-playground` removes it. `make clean` does not.

## Live shader development

```sh
make preview && ./build/LerpPreview
```

- `←` / `→` — switch shader.
- `space` — pause.
- `r` — recompile current shader.
- `q` — quit.
- `./build/LerpPreview --list` — print discovered shaders.
- `./build/LerpPreview --snapshot out/` — render every shader to PNG.
  - Flags: `--size WxH`, `--time T`, `--seed S`, `--shader name`.
  - Exits non-zero on compile errors; used as the test suite.

## Shader playground

```sh
make playground
```

- Builds `build/LerpPlayground.app` and opens it. It is a real app bundle
  (`com.hergenroeder.lerping.playground`), not a bare executable, so it has a
  Dock tile, a ⌘-Tab entry and an app menu, and `open -a LerpPlayground` finds
  it from anywhere once it has been built.
- **One instance.** Running `make playground` (or `open -a`, or the Dock icon)
  while it is already open raises the window you have instead of starting a
  second copy. Launching the executable inside the bundle by hand does the same
  thing: it hands off to the running instance and exits.
- Closing the window quits the app.
- Shaders still come from the repo the bundle sits in, so `open`'s working
  directory does not matter. (`make install-playground` puts a copy in
  `~/Applications` where Spotlight will offer it; that one is told which
  checkout to edit, because it has none above it. See "Install" above.)
- Split window: `.metal` source on the left, live render on the right.
- **What it opens on.** The look you last had open, if it is still on disk and
  still compiles — closing the window mid-shader and coming back to a different
  one loses your place, and nothing is worth that. Failing that (a first launch,
  a deleted shader, one that no longer builds) it draws a look at random from the
  looks your *screensaver* shuffles through, preset and all, so it opens on
  something you actually chose rather than on whatever sorts first. It reads that
  rotation and never writes it; the last-opened look is remembered in the app's
  own preferences, not the screensaver's.
  - A rotation with nothing enabled means all of them — the same one policy
    function the saver uses — so no setting can make the playground open onto
    nothing, and a look that will not compile is stepped past rather than opened.
- Uses the same LerpCore compile path as the screensaver.
- Editing recompiles 300 ms after the last keystroke and swaps the pipeline in place.
- On a compile error the last successful pipeline keeps rendering; the view does not blank and the process does not exit.
- Compile errors are listed in a console below the editor as `line:column`; the offending lines are highlighted, and `⌘E` (or clicking the status bar) jumps to the first one.
- Metal's reported line numbers match the shader file, because the prelude ends with `#line 1`.
- The picker lists `Sources/Shaders/` plus the custom shader directory, and refreshes when files change on disk.
- An externally modified open file reloads if there are no unsaved edits.
- Time scrubber, render scale (100/75/50/25%), and fps readout map onto `LerpUniforms` and `LerpMetalView.Config`.
- Editor is a plain `NSTextView` with soft tabs, auto-indent, undo, and find. No syntax highlighting and no line-number gutter.

Keys:

- `⌘N` — scaffold a new starter shader into `Sources/Shaders/`.
- `⌘S` — write the buffer back to the `.metal` file.
- `⌘R` — recompile.
- `⌘\` — play/pause.
- `⇧⌘R` — re-roll seed.
- `⇧⌘[` / `⇧⌘]` — previous/next shader.

Other targets:

- `make playground-build` — build only, to `build/LerpPlayground.app`. The app icon is rendered from the `mesh-gradient` shader by `build/LerpPreview`, the same way the saver's System Settings thumbnail is; nothing binary is checked in.
- `make install-playground` / `make uninstall-playground` — the copy Spotlight will offer, in `~/Applications`. See "Install" above.
- `build/LerpPlayground.app/Contents/MacOS/LerpPlayground --shaders` — print the checkout this copy reads, how it resolved it, and the shaders in it. Exits non-zero if there are none.
- `build/LerpPlayground.app/Contents/MacOS/LerpPlayground --capture out.png` — build the real window the way a launch does, say what it opened on and whether that came from the memory or from a draw against your rotation, and write a PNG of it. Reads your screensaver settings, writes none of them, and puts the last-opened memory back as it found it. The render pane is empty in the PNG: it is a `CAMetalLayer`, which `cacheDisplay` cannot reach.
- `make playground-test` — scripted UI test: drives the real window, asserts frames are drawing, edits the shader, breaks it, fixes it. Exits non-zero on any failed check.
  - It runs out of `build/LerpPlaygroundSelfTest.app`, a second bundle holding the same executable under an identifier of its own, so it can neither be mistaken for the app by the single-instance check nor activate it, and its preferences land in a domain of its own.
  - Nothing of it reaches your screen: no Dock tile, no menu bar, no stolen focus, and a window that is real and rendering but at zero opacity. Every exit — including the watchdog that fires if a step never hands on — closes the window, and `alarm(2)` backs that up if the process wedges entirely.

## Custom shaders

- Custom shader directory: `~/Library/Application Support/Lerping/Shaders/`.
- `LerpPreview` reads that directory at runtime; edit a file and press `r` to recompile.
- The installed screensaver cannot read that directory: `legacyScreenSaver` runs sandboxed and is denied access to Application Support.
- `make install` copies the contents of that directory into the `.saver` bundle, which the sandbox can read.
- `make install-example` copies the plasma template into the custom shader directory.
- A custom shader whose filename stem matches a built-in replaces that built-in.

```sh
cp myshader.metal ~/Library/Application\ Support/Lerping/Shaders/
./build/LerpPreview          # iterate without reinstalling
make install                 # copy into the screensaver bundle
```

### Shader contract

- One fragment function per file, with this exact signature:

```metal
fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);   // [-1,1] short axis, y up
    float3 color = float3(0.5 + 0.5 * sin(u.time + uv.xyx));
    return half4(half3(color), 1.0h);
}
```

- Uniforms: `u.resolution` (pixels), `u.time` (seconds), `u.seed` (random per launch, `[0,1)`).
- Prelude helpers: `lerpUV`, `lerpScreenUV`, `rotate`, `hash11/21/22`, `valueNoise`, `snoise` (simplex), `glmod/2/3`, `lerpDither`, `PI`, `TWO_PI`.
- The prelude is prepended to every shader before compilation. Source: `Sources/LerpCore/Prelude.swift`.
- Prelude symbols must not be redefined in a shader file.
- Worked example with comments: `Templates/plasma.metal`.
- Porting reference: `PORTING.md`.

### Shader parameters and presets

Tunable values are declared in the `.metal` file itself, so a shader carries
its parameters and presets wherever the file goes.

```metal
// lerp-param: distortion float 0 1 = 0.8 "Distortion"
// lerp-param: octaves    int 1 8   = 4   "Octaves"
// lerp-param: mirrored   bool      = false
// lerp-param: colorBack  color     = #06111C "Background"
//
// lerp-preset: Lagoon     distortion=0.8, colorBack=#06111C
// lerp-preset: "Deep Sea" distortion=0.2, octaves=6
```

- Syntax: `// lerp-param: NAME TYPE [MIN MAX] = DEFAULT ["Label"]`. Types are
  `float`, `int`, `bool`, `color`; MIN/MAX are required for `float`/`int` only.
  Colour defaults take `#RGB`, `#RRGGBB`, `#RRGGBBAA` or `(r, g, b[, a])`.
- Declared parameters become extra fields on `LerpUniforms`, so the shader
  reads them as `u.distortion`, `u.colorBack` — the `lerpMain` signature and
  the buffer bindings are unchanged, and a shader with no parameters compiles
  and renders exactly as before.
- `// lerp-preset: NAME  key=value, …` names a set of overrides; quote names
  with spaces, and repeat the name on later lines to split a long preset.
- A malformed declaration is a compile error naming the line.
- 28 of the 30 built-in shaders declare parameters mirroring the upstream
  paper-design props, with defaults set to this project's current look and the
  upstream looks available as presets.
- Inspect and drive them from the CLI:

```sh
./build/LerpPreview --params swirl                                   # declarations + presets
./build/LerpPreview --snapshot build/x --shader swirl --preset Candy
./build/LerpPreview --snapshot build/x --shader swirl --param twist=0.6
```

- There is no settings UI for parameters yet; every host renders at the
  declared defaults. Details and porting guidance: `PORTING.md`.

### Shaders with CPU-computed data

- A shader that needs more than the 16-byte uniform block — a table, a segment
  list, an occupancy grid — declares a data provider with a comment on one of
  its first lines: `// lerp-data: pipes`.
- The provider computes that data on the CPU each frame and binds it at
  fragment buffer index 1 and up; index 0 stays `LerpUniforms`.
- It also supplies the MSL struct declarations the shader reads it with, spliced
  into the prelude ahead of `#line 1` so error line numbers still match the file.
- A provider must *derive* its data from `(time, seed)` every frame, never
  accumulate across frames — a rendered frame is a pure function of
  (shader, time, seed, parameters), which is what makes `--snapshot --time T`
  reproducible.
- Only `pipes` uses one. Every other shader keeps the plain
  `fragment half4 lerpMain(float4, constant LerpUniforms&)` signature.
- Protocol and registry: `Sources/LerpCore/DataProvider.swift`. Worked example:
  `Sources/LerpCore/PipesData.swift`. Details in `PORTING.md`.

### GLSL → Metal mapping

| GLSL | Metal |
|---|---|
| `vec2` / `vec3` / `vec4` | `float2` / `float3` / `float4` |
| `mat2(a,b,c,d)` | `float2x2(float2(a,b), float2(c,d))` |
| `atan(y,x)` | `atan2(y,x)` |
| `inversesqrt` | `rsqrt` |
| `mod` | `glmod` (not `fmod`; results differ for negatives) |
| `gl_FragCoord` | `pos` |

## Layout

```
Sources/LerpCore/     shared engine, no ScreenSaver dependency
  Prelude.swift        Metal prelude prepended to every shader at runtime
  ShaderLibrary.swift  shader discovery (bundle + custom dirs) + runtime compilation
  ShaderParameters.swift  `// lerp-param:` / `// lerp-preset:` parsing, layout and packing
  DataProvider.swift   optional per-frame CPU→GPU data for shaders that need it
  PipesData.swift      data provider for pipes: deterministic lattice walk
  LerpRenderer.swift   stateless fullscreen-triangle pass encoder
  LerpMetalView.swift  CAMetalLayer view: CADisplayLink, fps cap, occlusion pause
  Snapshot.swift       offscreen render to PNG
Sources/Shaders/     built-in shaders, shipped as bundle Resources
Sources/Saver/       ScreenSaverView shim + Info.plist
Sources/Preview/     LerpPreview dev app / snapshot CLI
Sources/Playground/  LerpPlayground editor + live render, hot reload
  Info.plist           the .app's identity: bundle id, name, icon
  SelfTest-Info.plist  the same executable under its own id, for --selftest
Templates/           example shader
scripts/             loadtest.swift, sandboxprobe.swift + its plist/entitlements
```

`LerpCore` holds the rotation gallery (`RotationGallery.swift`,
`RotationThumbnails.swift`) and the colours and control helpers it draws with
(`UIChrome.swift`) because it has two hosts that cannot see each other's
sources: the screensaver's Options… sheet and the playground's rotation window.
What stays in `Sources/Playground/` is the part that is the playground's alone —
`RotationWindow.swift`, the window, and `RotationStore.swift`, which writes the
screensaver's ByHost domain the moment you click. `RotationStore` is
*not* hoisted: it needs `-framework ScreenSaver`, and neither the preview app nor
the snapshot renderer should have to link a framework they never use.

## Runtime behavior

- Frame rate is capped at 30 fps by default via `CADisplayLink.preferredFrameRateRange`.
- Frame rate drops to 0 fps when the window is occluded — but only where AppKit actually
  reports occlusion. It does not for a `legacyScreenSaver` host at the desktop-wallpaper
  layer, which is why the saver has a second, independent check; see below.
- Low Power Mode caps the frame rate at 20 fps.
- Internal render scale is selectable at 100%, 75%, or 50%; the compositor upscales.
- The animation clock is frozen while paused, so time does not jump on resume.
- "Still image" (default: after 30 minutes) stops rendering and holds the last frame.

## legacyScreenSaver behavior handled in `Sources/Saver/`

- The system does not destroy saver instances, and never reports occlusion for a host parked at the desktop-wallpaper layer (`CGWindowLevel -2147483625`, full-screen bounds, `onscreen=false`). Neither of `LerpMetalView`'s own stop paths is reachable there, so such a host renders forever behind the desktop. Measured on macOS 27: **5.5% CPU sustained** (`ps -o time=` delta of 1.65 s over a 30 s window) with the screensaver not running.
- **The saver always draws on `startAnimation`.** Gating that on the start notifications produced a permanently black screensaver, twice: legacyScreenSaver spawns the host *after* `willstart`/`didstart` are broadcast, distributed notifications are not queued, and a fresh process therefore cannot ever see the start of its own session. A host only ever observes the stops.
- `stopAnimation` *is* called on macOS 27, ~400 ms after `didstop`. Both `startAnimation` and `stopAnimation` stay wired up; the stop notifications are what usually ends a session first.
- **Nothing about the host tells you which kind it is.** Measured, and each rules out an obvious fix:
  - Both kinds sit at window level `-2147483625`. So does WallpaperAgent's own window.
  - A host that is *visibly rendering the screensaver* has `kCGWindowIsOnscreen` **false** on its own window for the whole session — its layer is composited into a window belonging to WallpaperAgent and its own window is never ordered in. Sampled once a second from outside the process across two real activations, one of them 11 minutes long. `NSWindow.isVisible` and `occlusionState` follow the same window, which is also why occlusion notifications never arrive. Anything keyed on them blacks out the real screensaver.
- So the saver does not classify itself. It draws, and it drops to **one frame a second** only when it can prove nothing it draws can be on screen: every display asleep, the session not on the console, or somebody demonstrably working at the machine for five consecutive seconds (any input at all ends a screensaver, so that cannot be true of the host the user is looking at). All three are verified to answer truthfully inside the sandbox by `make sandbox-probe`.
- Against those stands one piece of positive evidence that overrides all of them: `CAMetalDrawable.presentedTime`, i.e. a frame of ours that actually reached a display. Measured with this view's exact shape — 299 non-zero times out of 300 frames in a window that is on screen, 0 out of 300 in one that is not. It is evidence in one direction only; a visible layer that is composited rather than given a display plane can report zero too, so its absence proves nothing and is never read as proof.
- Parking is one frame a second rather than zero on purpose. A host parked by mistake is a slow screensaver for one second, not a black one, and the frame it draws each second is what re-tests the verdict. Measured on a full-screen 1512×982 hidden host: **1.42% CPU rendering → 0.32% parked**, parked 8 s in.
- The host process is never terminated. `exit(0)` on `willstop` raced the lock-screen UI, which is why the lock screen was blank, animated, or static at random. A retained window with its backing store intact costs nothing and makes the lock screen deterministic — it shows the frame the saver stopped on.
- Consequence: after `willstop` the lock screen shows a **frozen** last frame, not animation. `willstop` is the system saying the session is over.
- A host never sees `willstart`/`didstart` for its own session, but a host that outlives one *does* see the next one's. That is what un-parks a host that parked itself in error. Hosts are reused: the same pid was observed serving two sessions, building a new window for each.
- legacyScreenSaver can construct **two** `LerpSaverView` instances per host, the second ~165 ms after the session has already started. Only one of them is ever put in a window; anything with a side effect (the wallpaper handoff) is gated on `window != nil`.
- The System Settings preview instance keeps the classic `startAnimation`/`stopAnimation` contract, ignores the distributed notifications and is never parked, so neither a real screensaver cycle nor a verdict can freeze or slow the thumbnail.
- `isPreview` is unreliable on macOS Tahoe, so a small frame size is also treated as preview.
- `animateOneFrame` is not used; the view drives its own display link.
- Lifecycle is logged to `com.hergenroeder.lerping` at `info` level; nothing about this path is debuggable without it:

```sh
log show --last 5m --info --style compact --predicate 'subsystem == "com.hergenroeder.lerping"'
```

## What the sandbox allows

`legacyScreenSaver.appex` — the process that hosts the saver *and* builds its
Options… sheet — carries `com.apple.security.app-sandbox`. `make sandbox-probe`
measures what that means, by wrapping `scripts/sandboxprobe.swift` in an .app,
ad-hoc signing it with a transcription of legacyScreenSaver's own entitlements,
and loading the real `.saver` into it. Measured on macOS 27, Apple M5:

| | |
|---|---|
| `NSHomeDirectory()` | `~/Library/Containers/<id>/Data` — a real container |
| `MTLCreateSystemDefaultDevice()` | yes |
| `device.makeLibrary(source:)` | yes, 1–43 ms for a trivial shader |
| write `<container>/Library/Caches/…` | yes |
| write `~/Library/Caches/…` | **denied** — "You don't have permission to save the file" |
| read `~/Library/Application Support/Lerping/Shaders` | yes — the appex holds a read-only exception for `/` |
| read its own `Contents/Resources/Thumbnails` | yes |
| build the real Options… sheet | 121 ms, 114 tiles |
| fill it | 0.16 s — 113 stills off the bundle, 1 rendered |
| reopen it | 90 ms, entirely from memory |

So the sandbox can render, but it cannot cache anywhere the rest of the machine
can see — the stills are baked into the bundle by `make saver`
rather than shared with the playground's `~/Library/Caches` copy, and why
whatever the bundle is missing is cached in the container instead. The read-only
exception for `/` is also why a custom shader in
`~/Library/Application Support/Lerping/Shaders` shows up in the sheet's gallery
even before `make install` bakes it into the bundle.

## Desktop picture handoff

- **Off by default.** Enable with **Set desktop picture to the last frame** in Options….
  Off by default.
- On `com.apple.screensaver.willstop` the saver reads the exact `shaderName`, `time` and
  `seed` the view is on, re-renders that frame offscreen at each display's native pixel
  size via `LerpSnapshot`, writes it to a new PNG, and calls `NSWorkspace.setDesktopImageURL`
  for each `NSScreen`.
- Effect: the desktop, the locked session, and the pre-login login window all show the frame
  the screensaver ended on. macOS propagates it — `wallpaperexportd` mirrors the desktop
  picture to `/var/db/Wallpapers/<uuid>/Wallpaper.png` and to the Preboot volume, which is
  what the pre-login window reads. Verified end to end on macOS 27.
- The export is downscaled to logical points (a 3024x1964 render comes back out as 1512x982),
  so rendering at native panel resolution is already more than enough.
- **Where the file goes:** `legacyScreenSaver` is sandboxed and writing to the real
  `~/Library/Application Support/Lerping/wallpaper/` is denied outright, exactly like the
  custom shader directory. The stills land in the sandbox container instead:

```
~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/
  Library/Application Support/Lerping/wallpaper/<shader>-<id>-<screen>.png
```

  `setDesktopImageURL` accepts that URL and `wallpaperexportd` mirrors it — verified. The
  consequence is that the desktop picture points into a sandbox container: if the container
  is ever reset, the wallpaper breaks until the next screensaver cycle.
- Every frame is written to a **new** filename. Rewriting the same URL does not refresh the
  desktop picture.
- `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` is never edited
  directly. `WallpaperAgent` holds an in-memory copy and flushes it back over any edit, and
  it lags the API call by seconds, so it is not a way to confirm anything either.
- Generated PNGs older than two minutes are deleted after each successful handoff. Age-based
  rather than "delete everything I did not just write", because with more than one display
  macOS can run more than one saver host and a strict keep-set lets one host delete a still
  another host just handed to the wallpaper agent.
- Multi-display: each `NSScreen` gets its own render at its own aspect ratio. The Preboot
  export is per **user** — one file — so the login window only ever shows the primary
  display's frame. That is a macOS limitation, not something this code can fix.

## Wallpaper mode

- Not implemented; the handoff above is a still image, not a live animated desktop.
- `LerpMetalView` has no ScreenSaver dependency and can be hosted elsewhere.
- Path: a menu-bar app placing one `LerpMetalView` per `NSScreen` in a borderless window at `kCGDesktopWindowLevel`, with `ignoresMouseEvents`, `.canJoinAllSpaces`, `.stationary`, and occlusion pausing.

## License

- AGPL-3.0-or-later. See `LICENSE`.
- Copyleft: derivative works and redistributed modified versions must also be released under AGPL-3.0.
- AGPL-3.0 adds section 13 to GPL-3.0: users interacting with a modified version over a network must be offered its source. This program does no network interaction, so section 13 is inert here.
- Apache-2.0 is one-way compatible with the GPL-3.0 family, so the combined work is conveyed under AGPL-3.0. Apache-2.0 is not compatible with GPL-2.0.
- `Sources/Shaders/aurora.metal` is original work, additionally offered under MIT in its file header.

## Sources

- [paper-design/shaders](https://github.com/paper-design/shaders) — Apache-2.0. 28 of the 31 shaders are ports of it; the prelude's hashes, value noise, simplex noise and banding fix derive from it. Per-shader attribution in `NOTICE.txt`.
- Neuro Noise — original GLSL algorithm by [@zozuar](https://github.com/zozuar), via Paper Shaders.
- Microsoft 3D Pipes (`sspipes`, Copyright (c) 1994-1995 Microsoft Corporation) — `Sources/Shaders/pipes.metal` is an original raymarched SDF sharing no code with it, and reuses its published numeric constants. See `NOTICE.txt`.
- The OpenGL "teapot" material table (emerald, jade, pearl, ruby, turquoise, brass, bronze, copper, gold, silver, plastics, rubbers) — long-published values used by `pipes`.
- [orchetect/swift-midi](https://github.com/orchetect/swift-midi) — MIT. MIDI I/O for the playground, linked statically via `Sources/MIDIDeps`. Formerly named MIDIKit.
- [MIKMIDI](https://github.com/mixedinkey-opensource/MIKMIDI) — MIT. The MIDI mapping model (per-device bindings, MIDI learn, named banks) follows its design. No MIKMIDI code is used and it is not a dependency.
