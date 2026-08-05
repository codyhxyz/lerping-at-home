# Lerping@Home

- Screensaver for macOS that renders procedural shaders with Metal.
- Shaders are single `.metal` files compiled at runtime via `MTLDevice.makeLibrary(source:)`.
- 28 built-in shaders: aurora, color-panels, dithering, dot-grid, dot-orbit, fluted-glass, gem-smoke, god-rays, grain-gradient, halftone-cmyk, halftone-dots, liquid-metal, mesh-gradient, metaballs, neuro-noise, paper-texture, perlin-noise, pulsing-border, simplex-noise, smoke-ring, spiral, static-mesh-gradient, static-radial-gradient, swirl, voronoi, warp, water, waves.
- Custom `.metal` files are supported without rebuilding the engine.
- No Xcode project. Builds with `swiftc` through a Makefile.
- No build-time Metal toolchain and no precompiled shader archive.

## Requirements

- macOS 14 or later.
- Apple Silicon.
- Xcode command-line tools (`swiftc`).

## Install

```sh
make install     # builds and copies Lerping@Home.saver to ~/Library/Screen Savers
```

- Select **Lerping@Home** in System Settings → Screen Saver.
- First activation can show black briefly while Gatekeeper verifies the bundle.
- Shader, frame rate, and render scale are set behind the saver's Options… button.
- Options… also has an **In rotation** checklist: pick which shaders Shuffle draws
  from. New shaders join the rotation automatically; checking nothing means all.
- Options… has a **Set desktop picture to the last frame** checkbox, off by default.
  See "Desktop picture handoff" below.

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

- Split window: `.metal` source on the left, live render on the right.
- Uses the same LerpCore compile path as the screensaver.
- Editing recompiles 300 ms after the last keystroke and swaps the pipeline in place.
- On a compile error the last successful pipeline keeps rendering; the view does not blank and the process does not exit.
- Compile errors are listed in a console below the editor as `line:column`, and marked in the gutter.
- Metal's reported line numbers match the shader file, because the prelude ends with `#line 1`.
- The picker lists `Sources/Shaders/` plus the custom shader directory, and refreshes when files change on disk.
- An externally modified open file reloads if there are no unsaved edits.
- Time scrubber, render scale (100/75/50/25%), and fps readout map onto `LerpUniforms` and `LerpMetalView.Config`.
- Editor has a line-number gutter, MSL syntax highlighting, soft tabs, and auto-indent.

Keys:

- `⌘N` — scaffold a new starter shader into `Sources/Shaders/`.
- `⌘S` — write the buffer back to the `.metal` file.
- `⌘R` — recompile.
- `⌘\` — play/pause.
- `⇧⌘R` — re-roll seed.
- `⇧⌘[` / `⇧⌘]` — previous/next shader.

Other targets:

- `make playground-build` — build only, to `build/LerpPlayground`.
- `make playground-test` — scripted UI test: opens the real window, asserts frames are drawing, edits the shader, breaks it, fixes it. Exits non-zero on any failed check.

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
  LerpRenderer.swift   stateless fullscreen-triangle pass encoder
  LerpMetalView.swift  CAMetalLayer view: CADisplayLink, fps cap, occlusion pause
  Snapshot.swift       offscreen render to PNG
Sources/Shaders/     built-in shaders, shipped as bundle Resources
Sources/Saver/       ScreenSaverView shim + Info.plist
Sources/Preview/     LerpPreview dev app / snapshot CLI
Sources/Playground/  LerpPlayground editor + live render, hot reload
Templates/           example shader
scripts/             loadtest.swift
```

## Runtime behavior

- Frame rate is capped at 30 fps by default via `CADisplayLink.preferredFrameRateRange`.
- Frame rate drops to 0 fps when the window is occluded — but only where AppKit actually
  reports occlusion. It does not for a `legacyScreenSaver` host at the desktop-wallpaper
  layer, which is why the saver gates on the screensaver notifications instead.
- Low Power Mode caps the frame rate at 20 fps.
- Internal render scale is selectable at 100%, 75%, or 50%; the compositor upscales.
- The animation clock is frozen while paused, so time does not jump on resume.
- "Still image" (default: after 30 minutes) stops rendering and holds the last frame.

## legacyScreenSaver behavior handled in `Sources/Saver/`

- The system does not destroy saver instances, and never reports occlusion for a host parked at the desktop-wallpaper layer (`CGWindowLevel -2147483625`, full-screen bounds, `onscreen=false`). Neither of `LerpMetalView`'s own stop paths is reachable there, so such a host renders forever behind the desktop. Measured on macOS 27: **5.5% CPU sustained** (`ps -o time=` delta of 1.65 s over a 30 s window) with the screensaver not running.
- `stopAnimation` *is* called on macOS 27, ~400 ms after `didstop` — contrary to the older Sonoma-era note this file used to carry. It is still not something to rely on: it arrives after the notifications have already stopped rendering, and it never arrives for a host that is not currently displaying the saver. Both `startAnimation` and `stopAnimation` stay wired up, but neither is the primary signal.
- The real saver therefore renders **only** between the distributed `com.apple.screensaver` start and stop notifications, and at no other time. `startAnimation` does not start rendering; a host that never receives a start notification never draws a frame. Same measurement after the change: **0.00 s over 30 s**.
- The host process is never terminated. `exit(0)` on `willstop` raced the lock-screen UI, which is why the lock screen was blank, animated, or static at random. A retained window with its backing store intact costs nothing and makes the lock screen deterministic — it shows the frame the saver stopped on.
- Consequence: after `willstop` the lock screen shows a **frozen** last frame, not animation. `willstop` is the system saying the session is over.
- `com.apple.screensaver.willstart` is not posted on macOS 27; `didstart` is. Both are observed, and `didstop` is observed as a backstop for `willstop`.
- legacyScreenSaver constructs **two** `LerpSaverView` instances per host, and the second one is built ~165 ms *after* `didstart` has already been delivered. "A session is running" is therefore process-wide state, not per-instance: an instance that missed the notification starts from its own `startAnimation`. Observed, not defensive — without it the second instance stays dark for the whole session.
- Only one of those two instances is ever put in a window. Anything with a side effect (the wallpaper handoff) is gated on `window != nil`.
- The System Settings preview instance keeps the classic `startAnimation`/`stopAnimation` contract and ignores the distributed notifications, so a real screensaver cycle cannot freeze the thumbnail.
- `isPreview` is unreliable on macOS Tahoe, so a small frame size is also treated as preview.
- `animateOneFrame` is not used; the view drives its own display link.
- Lifecycle is logged to `com.hergenroeder.lerping` at `info` level; nothing about this path is debuggable without it:

```sh
log show --last 5m --info --style compact --predicate 'subsystem == "com.hergenroeder.lerping"'
```

## Desktop picture handoff

- **Off by default.** Enable with **Set desktop picture to the last frame** in Options….
  Silently replacing someone's wallpaper is not a reasonable default.
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

- GPL-3.0-or-later. See `LICENSE`.
- Copyleft: derivative works and redistributed modified versions must also be released under GPL-3.0.
- Shaders ported from [Paper Shaders](https://github.com/paper-design/shaders), and the prelude helpers derived from it, are Apache-2.0 upstream. See `NOTICE.txt`.
- Apache-2.0 is one-way compatible with GPL-3.0, so the combined work is conveyed under GPL-3.0. Apache-2.0 is not compatible with GPL-2.0.
- `Sources/Shaders/aurora.metal` is original work, additionally offered under MIT in its file header.
