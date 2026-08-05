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
- Frame rate drops to 0 fps when the window is occluded.
- Low Power Mode caps the frame rate at 20 fps.
- Internal render scale is selectable at 100%, 75%, or 50%; the compositor upscales.
- The animation clock is frozen while paused, so time does not jump on resume.
- "Still image" (default: after 30 minutes) stops rendering and holds the last frame.

## legacyScreenSaver behavior handled in `Sources/Saver/`

- The system does not call `stopAnimation` and does not destroy saver instances. The saver observes the distributed `com.apple.screensaver.willstop` notification and exits the host process itself. This path runs only for the real saver, never the System Settings preview.
- `isPreview` is unreliable on macOS Tahoe, so a small frame size is also treated as preview.
- `animateOneFrame` is not used; the view drives its own display link.

## Wallpaper mode

- Not implemented.
- `LerpMetalView` has no ScreenSaver dependency and can be hosted elsewhere.
- Path: a menu-bar app placing one `LerpMetalView` per `NSScreen` in a borderless window at `kCGDesktopWindowLevel`, with `ignoresMouseEvents`, `.canJoinAllSpaces`, `.stationary`, and occlusion pausing.

## License

- GPL-3.0-or-later. See `LICENSE`.
- Copyleft: derivative works and redistributed modified versions must also be released under GPL-3.0.
- Shaders ported from [Paper Shaders](https://github.com/paper-design/shaders), and the prelude helpers derived from it, are Apache-2.0 upstream. See `NOTICE.txt`.
- Apache-2.0 is one-way compatible with GPL-3.0, so the combined work is conveyed under GPL-3.0. Apache-2.0 is not compatible with GPL-2.0.
- `Sources/Shaders/aurora.metal` is original work, additionally offered under MIT in its file header.
