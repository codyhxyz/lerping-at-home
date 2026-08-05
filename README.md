# Lerping@Home

Metal shader screensaver for macOS, built from first principles. Real-time
procedural shaders (the same open-source [Paper Shaders](https://github.com/paper-design/shaders)
aesthetic the Era wallpaper app uses), rendered natively with a strict power
budget, extensible with your own `.metal` files — no Xcode project, no
Electron, no compiled shader archive.

## Build & install

```sh
make install     # builds and copies Lerping@Home.saver to ~/Library/Screen Savers
```

Then pick **Lerping@Home** in System Settings → Screen Saver. First activation may
briefly show black while Gatekeeper verifies the bundle — that's a known
one-time macOS quirk. Options (shader, frame rate, render scale) live behind
the saver's Options… button.

Requires: macOS 14+, Apple Silicon, Xcode command-line toolchain (`swiftc`).
No Metal toolchain needed — all shaders compile at runtime.

## Develop shaders live

```sh
make preview && ./build/LerpPreview
```

- ←/→ switch shader · space pause · `r` recompile current shader · `q` quit
- `./build/LerpPreview --list` — show discovered shaders
- `./build/LerpPreview --snapshot out/` — render every shader to PNG
  (`--size WxH --time T --seed S --shader name`); exits non-zero on compile
  errors, so it doubles as the test suite.

## Custom shaders

Put `.metal` files here:

```
~/Library/Application Support/Lerping/Shaders/
```

`LerpPreview` reads that folder live — edit a shader, hit `r`, see it. The
screensaver can't: `legacyScreenSaver` runs sandboxed and is denied access to
Application Support (its own container is TCC-protected and not writable by
you either). So `make install` **bakes** whatever is in that folder into the
installed `.saver` bundle, which the sandbox can always read. Workflow:

```sh
cp myshader.metal ~/Library/Application\ Support/Lerping/Shaders/
./build/LerpPreview          # iterate here — instant, no reinstall
make install                 # bake into the screensaver when happy
```

`make install-example` drops the plasma template in for reference.

A shader is one fragment function (see `Templates/plasma.metal` for a
commented worked example):

```metal
fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);   // [-1,1] short axis, y up
    float3 color = float3(0.5 + 0.5 * sin(u.time + uv.xyx));
    return half4(half3(color), 1.0h);
}
```

Uniforms: `u.resolution` (pixels), `u.time` (seconds), `u.seed` (random
per-launch, [0,1)). Prelude helpers: `lerpUV`, `lerpScreenUV`, `rotate`,
`hash11/21/22`, `valueNoise`, `snoise` (simplex), `glmod/2/3` (GLSL-style
mod — use instead of `fmod` when porting), `lerpDither` (banding fix), `PI`,
`TWO_PI`. Full prelude source: `Sources/LerpCore/Prelude.swift`.

Porting a Shadertoy/GLSL shader is mostly mechanical: `vec2`→`float2`,
`atan(y,x)`→`atan2`, `inversesqrt`→`rsqrt`, `mod`→`glmod`, `mat2(a,b,c,d)`→
`float2x2(float2(a,b), float2(c,d))`, `gl_FragCoord`→`pos`.

Custom shaders with the same file stem as a built-in override it.

## Architecture

```
Sources/LerpCore/     shared engine (no ScreenSaver dependency)
  Prelude.swift        Metal prelude prepended to every shader at runtime
  ShaderLibrary.swift  discovery (bundle + custom dirs) + runtime compilation
  LerpRenderer.swift    stateless fullscreen-triangle pass encoder
  LerpMetalView.swift   CAMetalLayer view: CADisplayLink, fps cap, occlusion pause
  Snapshot.swift       offscreen render → PNG (tests, thumbnails)
Sources/Shaders/     built-in shaders (.metal source, shipped as Resources)
Sources/Saver/       ScreenSaverView shim + Info.plist
Sources/Preview/     LerpPreview dev app / snapshot CLI
```

Design decisions:

- **Everything compiles at runtime** (`MTLDevice.makeLibrary(source:)`).
  One code path for built-in and custom shaders, no build-time Metal
  toolchain, hot reload for free.
- **Power discipline**: 30 fps default cap via `CADisplayLink.
  preferredFrameRateRange` (never uncapped 120 on ProMotion), hard 0 fps
  when the window is occluded, optional 75%/50% internal render scale
  (upscaled by the compositor — near-indistinguishable for noise shaders),
  clock freezes while paused so animation never jumps. Low Power Mode caps
  the frame rate at 20 fps automatically. The "Still image" option (default:
  after 30 minutes) stops rendering entirely and holds the last frame, so a
  saver left running overnight costs nothing.
- **legacyScreenSaver workarounds baked in** (the post-Sonoma minefield):
  the system never calls `stopAnimation` or destroys instances, so the saver
  listens for the distributed `com.apple.screensaver.willstop` notification
  and exits the host process itself (the Aerial workaround) — real saver
  only, never the System Settings preview. `isPreview` is unreliable on
  Tahoe, so a small frame also counts as preview. `animateOneFrame` is
  ignored; the view drives its own display link.
- **The engine is host-agnostic**: `LerpMetalView` in a desktop-level window
  (`kCGDesktopWindowLevel`, `ignoresMouseEvents`, all-Spaces) would be the
  Era-style live wallpaper — same renderer, different ~100-line shim.
  Deliberately not built yet: a wallpaper renders nearly all the time; a
  screensaver only when you're away.

## Wallpaper mode (future)

Add a menu-bar app target that puts one `LerpMetalView` per `NSScreen` in a
borderless window at desktop level with `.canJoinAllSpaces + .stationary`,
occlusion-paused. All the hard parts (renderer, discovery, power rules)
already live in LerpCore.

## License

Original code: MIT. Ported shaders: Apache 2.0 from Paper Shaders — see
NOTICE.txt.
