# Porting shaders to Lerping@Home

Lerping@Home shaders are single `.metal` files compiled at runtime. To port a GLSL
shader (paper-design, Shadertoy, etc.), produce one file in `Sources/Shaders/`
defining exactly:

```metal
fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]])
```

(A shader that needs CPU-computed data takes extra bindings on top of that —
see "Shaders that need CPU-computed data" below. Everything else uses the
signature above unchanged.)

Every file gets `Sources/LerpCore/Prelude.swift`'s Metal prelude prepended
before compilation. Read that file first — it defines `LerpUniforms`
(`u.resolution` pixels, `u.time` seconds, `u.seed` random [0,1) per launch,
the four audio levels described under "Audio-reactive shaders", and
`u.viewer`, described under "Head-tracked shaders"), `lerpUV` (centered UV, [-1,1] short axis, y up), `lerpScreenUV` (0..1, y down),
`rotate`, `hash11/21/22`, `valueNoise`, `snoise` (2D simplex), `glmod/2/3`,
`lerpDither`, `PI`, `TWO_PI`. **Do not redefine any prelude symbol** — name
your file-local helpers with a shader-specific prefix (e.g. `mbShape` for
metaballs).

## GLSL → MSL mechanics

| GLSL | MSL |
|---|---|
| `vec2/3/4`, `mat2` | `float2/3/4`, `float2x2` |
| `mat2(a,b,c,d)` | `float2x2(float2(a,b), float2(c,d))` (column-major, same order) |
| `atan(y, x)` | `atan2(y, x)` |
| `inversesqrt` | `rsqrt` |
| `mod(x, y)` | `glmod(x, y)` — NOT `fmod` (differs on negatives) |
| `texture(u_noiseTexture, uv)` randomizers | procedural `hash21`/`valueNoise` from the prelude |
| `gl_FragCoord` | `pos` |
| uniform params (`u_color`, `u_scale`…) | declare them with `// lerp-param:` (below); bake the rest as file-scope `constant` values |
| `fragColor = vec4(c, a)` | `return half4(half3(color), 1.0h)` (opaque; composite any alpha against a baked background color) |
| top-level `const` arrays | `constant float4 NAME[N] = {...};` at file scope |

Loops with `break` on a uniform count: use a fixed `constant int` count.

Uniform params are the one row above worth ignoring: rather than baking every
prop as a `constant`, declare the ones that genuinely change the look as
**parameters** (below) and keep the rest baked.

## Tunable parameters

A shader declares its own parameters in comments, so the `.metal` file stays
the single source of truth — a custom shader dropped into
`~/Library/Application Support/Lerping/Shaders` carries its parameters with it,
with no sidecar file to install.

```metal
// lerp-param: distortion float 0 1 = 0.8 "Distortion"
// lerp-param: colorCount int 1 5   = 5   "Color count"
// lerp-param: mirrored   bool      = false
// lerp-param: colorBack  color     = #06111C "Background"
// lerp-param: color1     color     = (0.043, 0.231, 0.290) "Deep teal"
```

Grammar, one declaration per comment line, anywhere in the file:

```
// lerp-param: NAME TYPE [MIN MAX] = DEFAULT ["Label"]
```

- **NAME** — a valid MSL identifier, unique in the file, and not one of the
  built-in fields: `resolution`, `time`, `seed`, `audioLevel`, `audioBass`,
  `audioMid`, `audioTreble`, `viewer`. Three names are special rather than
  reserved: `parallax` opts a look into head tracking (see "Head-tracked
  shaders"), and `yaw`, `pitch` and `magnify` into drag to turn and pinch to
  zoom (see "Drag to turn, pinch to zoom").
- **TYPE** — `float`, `int`, `bool` or `color`.
- **MIN MAX** — required for `float` and `int`, rejected for `bool` and
  `color`. The default has to fall inside the range.
- **DEFAULT** — a number; `true`/`false` for a bool; for a colour either
  `#RGB` / `#RRGGBB` / `#RRGGBBAA` or `(r, g, b[, a])` with components 0…1.
  Prefer the float form when you are turning an existing `constant float3` into
  a parameter — it keeps the exact value instead of rounding through 8-bit hex.
- **"Label"** — optional display name. Defaults to the humanised NAME.

Anything malformed is a hard error naming the line, not a silent default.

**Reading them.** Declared parameters are appended to `struct LerpUniforms` in
the generated prelude, so you read them as `u.distortion`, `u.colorBack` and so
on — **the `lerpMain` signature does not change**, and neither does the buffer
binding (`LerpUniforms` is still fragment index 0, data providers still own 1
and up). A `color` arrives as `float4` (use `.rgb`, and `.a` if you gave the
colour a meaningful alpha); a `bool` arrives as an `int` that is 0 or 1. A
shader that declares no parameters is compiled and bound exactly as before.

File-scope `static` helpers can't see `u`, so either pass the value you need as
an argument or take `constant LerpUniforms& u` as a parameter.

**Presets** live in the same file, right under the declarations:

```metal
// lerp-preset: Lagoon      distortion=0.8, swirl=0.35, colorBack=#06111C
// lerp-preset: "Deep Sea"  distortion=0.2, colorBack=(0.0, 0.01, 0.03)
```

Quote the name if it contains spaces. Repeating a name on later lines merges
into one preset, which is how you keep long presets readable. A preset applies
on top of the *defaults*, so anything it doesn't mention returns to its
declared default. Setting a parameter the file doesn't declare is an error.

You don't have to type one. Get the look you want on the playground's sliders
and **Shader → Save as Preset…** (`⇧⌘S`) writes exactly this form back into
the file — only the parameters you moved off their defaults. A new name is
appended after existing presets; reusing a name replaces that preset in place.

A preset is also a stop in the screensaver's shuffle: the rotation is a list of
(shader, preset) pairs, where the shader's declared defaults are one of the
pairs. Adding a preset to a file therefore adds a look to the rotation with no
other change, and a file that declares none still takes its turn at its
defaults. `--snapshot` renders every shader at its defaults and nothing
else, so a preset can never move a snapshot.

**Rules of thumb when porting.** Use the upstream prop names and ranges
verbatim. Set the default to whatever this port currently renders, so the
existing look is preserved; put upstream's own defaults in a preset instead.
Don't invent parameters upstream doesn't have — if the port adds one anyway
(`speed` on a shader that is static upstream, say), say so in the file header.
Don't mechanically expose every internal constant either; a value that stays
baked is fine, it just must not be advertised as tunable.

Inspect and drive them from the CLI:

```sh
./build/LerpPreview --params NAME                       # declarations + presets
./build/LerpPreview --snapshot DIR --shader NAME --preset Lagoon
./build/LerpPreview --snapshot DIR --shader NAME --param distortion=0.2 --param colorBack=#101820
```

Parameters are part of the purity contract: a frame stays a pure function of
(shader, time, seed, parameters). Values are re-packed from scratch on every
change and bound per frame; nothing accumulates.

### Animated parameters

A `float` or `color` parameter can drift on its own, slowly, between two
bounds. Declare it next to its `// lerp-param:`:

```metal
// lerp-param:   foldRotation float 0 1 = 0.4 "Fold rotation"
// lerp-animate: foldRotation 0.2 0.6 period=180
```

```
// lerp-animate: NAME LOW HIGH [period=SECONDS]
```

- **NAME** — a `// lerp-param:` in the same file, above or below. Only
  `float` and `color` animate: an `int` would step and a `bool` would
  flicker, so both are errors.
- **LOW HIGH** — numbers inside the parameter's declared range for a float,
  two colours (`#RRGGBB` or `(r, g, b[, a])`) for a colour, and not equal.
  They are an *envelope*: the value is the weighted sum of two sines —
  the second φ ≈ 1.618 times faster and a quarter of the weight — so the
  main swing covers the middle three quarters, the extremes are touched
  only when both waves agree, and the motion never exactly repeats.
- **period=SECONDS** — one swing of the main wave. Optional (120 s);
  `180s` is accepted; under 10 s is an error, because that is motion, and
  motion belongs in the shader against `u.time`.
- The phase comes from `u.seed` and the parameter's name, so every
  activation starts somewhere different and two parameters with the same
  period do not move in step.
- The declared default is still the parameter's value when something pins
  it, and what Save writes, so keep it inside the bounds.

Anything malformed — an unknown name, a bound out of range, a duplicate
line, a stray option — is a hard error naming the line, like the rest of
the grammar.

**Presets.** A `// lerp-animate:` is part of the declaration, so it is part
of every look that does not override it — a preset that never mentions the
parameter keeps the drift. A preset that **sets a value pins it** there:
a value is a statement of what the parameter is. To drift differently:

```metal
// lerp-preset: Still    foldRotation=0.4
// lerp-preset: Restless foldRotation=animate(0.1, 0.9, period=60)
// lerp-preset: Slower   foldRotation=animate(period=300)
// lerp-preset: Back     foldRotation=animate
```

Still pins it at 0.4; Restless re-bounds it; Slower keeps the declared bounds
at a new period; Back drifts exactly as declared (useful only to undo an
earlier assignment of the same preset). `animate(…)` takes the bounds as a pair or not at all, and `period=`; what
it leaves out comes from the file's `// lerp-animate:`, so a bare
`animate` on a parameter with no declaration is an error. It also works on a
parameter the file holds still, which then drifts only in that look. If a
preset names a parameter twice, the later assignment wins.

**Purity.** The animated value is computed from (time, seed, declaration)
for every frame, never stepped or accumulated, in exactly one place:
`LerpRenderer.encodePass`, from the very `LerpUniforms` the frame is drawn
with. So `--snapshot --time T`, the time scrubber, the gallery's stills, the
crossfade and the desktop handoff all land on the same value at T, and a data
provider's `params` overload is handed the animated value too. A provider that
caches by a parameter (`life`'s board size) rebuilds whenever it changes, so
do not animate a parameter a provider keys a simulation or cache on.

**In the playground** an animated parameter's slider (or colour well) moves as
it plays, and a small waveform toggle beside it is lit while it drifts.
Dragging the slider, typing a value, or a MIDI knob bound to it takes control:
the drift stops for that parameter, holding the value you gave it, until you
click the toggle again. Clicking the toggle off holds the value on screen, so
nothing jumps. `⌘S` / `⇧⌘S` save what you see: a held parameter is written as
`name=value` (which pins it, even at its default), a re-bounded drift as
`name=animate(…)`, and one drifting as declared is not written at all. Saving
the Defaults look cannot pin a parameter — its drift *is* the
`// lerp-animate:` line — so the status line says so; save a preset, or delete
the line.

**From the CLI**, `--params NAME` prints each drift under its parameter
(`animate 0.2 0.6 period=180`) and in presets (`name=animate(…)`).
`--snapshot` renders the value at `--time`; `--param name=0.4` pins it and
`--param 'name=animate(0.1, 0.3, period=60)'` re-bounds it.
`LerpPreview --animate-selftest` checks the grammar, the curve, purity
(cold / warm / scrubbed back, and what a provider is handed), preset
overrides and the Save round trip.

**House style.** Drift is seasoning, not the dish.

- Slow: periods of 60–300 s. If you can watch it move, it is too fast.
- Modest: a fraction of the range, chosen so every point inside the bounds is
  a look you would ship on its own. Check the two ends with `--param`.
- Only parameters whose *motion* looks good — a fold angle, a scale, a warp
  amount. Not a palette count, not a march step count, not anything that
  makes the image pop or re-layout, and not anything the shader already
  animates against `u.time` (that is two clocks fighting).
- One or two per shader. Several things drifting at once reads as unsteady.
- `fractal-multiverse`'s `morph` is the worked example: one drift that each
  form maps onto its own fold parameter.

## Audio-reactive shaders

`LerpUniforms` carries four smoothed levels of whatever the Mac is playing,
each roughly 0…1:

| Field | What it measures |
|---|---|
| `u.audioLevel` | broadband loudness (RMS) |
| `u.audioBass` | ~20–250 Hz |
| `u.audioMid` | ~250–4000 Hz |
| `u.audioTreble` | ~4–16 kHz |

They are fed **only** by the playground, and only while **Shader › React to
System Audio** is on (off at every launch). Everywhere else they are exactly
0: the screensaver, `--snapshot`, the rotation gallery's stills, the web
gallery. That is not a missing feature in the saver — Apple's
`legacyScreenSaver` host, which the saver runs inside, has no
`NSAudioCaptureUsageDescription`, and TCC refuses system-audio capture to a
process without one, so the tap there only ever delivers silence.

Two rules follow:

- **Silence must be the original look.** Use the levels as offsets that vanish
  at 0 (`size + 0.3 * u.audioBass`, not `size * u.audioBass`), so a shader
  looks identical in the saver and in every snapshot. `metaballs` is the worked
  example: each ball swells with one band, scaled by its `audio` parameter.
- **Never feed them into time.** Warping `u.time` by loudness makes motion
  stutter and breaks scrubbing; modulate shape, size or brightness instead.

The levels are live input, the one thing a frame may depend on outside
(shader, time, seed, parameters). Nothing records them, which is why every
frame anything persists — snapshots, thumbnails, the desktop handoff — is still
a pure function of that tuple.

Capture is a Core Audio process tap on every process's output (macOS 14.2+),
analysed with a 1024-point vDSP FFT on a background queue, with a fast-attack,
slow-release envelope (~25 ms up, ~300 ms down). See
`Sources/Playground/SystemAudio.swift`.

## Head-tracked shaders

With **Shader › Track Head with Camera** on, the playground follows the
watcher's face with the Mac's camera and the screen becomes a window: it
stays put, the eye moves, and each pixel's ray runs from the eye through that
pixel's own spot on the glass. Nearer things swing against the head, farther
things follow it, and leaning in widens the view. It is on unless you turn it
off (the choice is remembered), and the camera runs only while the open look
declares `parallax`. The pose stage is a port of this year's MediaPipe +
Kooima + 1€ head-coupled pipeline (`HeadPoseFilter`): depth smoothed harder
than x and y, prediction only while the head is moving, render-rate smoothing
between camera frames, and on losing the face a 0.6 s hold, then a 1.2 s
glide to centre. With no camera to use (none, or access refused) the pointer
stands in for the head: over the
render, or anywhere with Desktop Mode on, moving it moves the eye, and off the
render the view eases back to straight on. Everywhere else `u.viewer` is
exactly 0 — the screensaver, `--snapshot`, the gallery stills.

**Shader › Desktop Mode** puts the open look, with its current values, behind
the desktop icons on every screen, and the head tracker steers it there too.
They are the playground's own windows, gone when it quits: nothing writes the
desktop picture. While Track Head is on, the camera is let go whenever neither
the desktop nor the playground's view can be seen, and taken back when one
can. See `Sources/Playground/DesktopMode.swift`.

A look opts in by declaring one parameter, which is also its strength:

```
// lerp-param: parallax float 0 2 = 1 "Head parallax"
```

and, for a raymarched look, swapping its ray for the prelude's:

```
float3 rd = normalize(uv.x * right + uv.y * up + focal * fwd);              // before
float3 rd = lerpViewerRay(u, u.parallax, uv, focal, right, up, fwd, ro);    // after
```

`lerpViewerRay` moves `ro` to the eye and returns the ray. With the viewer
centred it is the plain camera again. A splat look (`// lerp-data: splat:…`)
needs only the parameter: `SplatData` applies the same camera to its
rasteriser. `menger-sponge` and `splat-owl` are the worked examples.

Fit matters more than mechanics:

- **Good:** real depth and a calm camera — raymarched fractals, solid objects
  in a volume, layered depth, splat captures. Holes and edges that hide and
  reveal what is behind them are what sell it.
- **Poor:** flat 2D designs and screen-space simulations (there is nothing
  behind the glass to reveal), and fast or first-person camera flights, where
  head motion fights the camera's own. Leave those without `parallax`.
- **Scale the gain to the space.** The eye can move about `0.3 × focal` scene
  units. Inside a tunnel that is enough to put it through the wall, so
  `menger-sponge` cuts its gain to a tenth in tunnel mode.

`u.viewer.xyz` is the head's offset (x right, y up, z towards the screen),
divided by the distance the watcher sat at when tracking began, so it is about
the tangent of the angle the head has moved through. **Shader › Recentre Head**
makes wherever they are now the centre. See `Sources/LerpCore/LerpViewer.swift`
and `Sources/Playground/HeadTracker.swift`.

## Drag to turn, pinch to zoom

In the playground, dragging on the render turns a 3D look — the scene moves
with the pointer, like a globe under a hand — and pinching, or scrolling with
two fingers or a wheel, brings it nearer or sends it back. A look opts in by
declaring the angles (degrees) and the zoom (stops) as ordinary parameters:

```
// lerp-param: yaw     float -180 180 = 0 "Turn"
// lerp-param: pitch   float -90  90  = 0 "Tilt"
// lerp-param: magnify float -1   1   = 0 "Zoom"
```

The gestures move them exactly as their sliders do, so presets, Save, MIDI
Learn, hands and `LerpPreview --param magnify=0.5` all work on them with
nothing added. A range that spans 360° wraps; a narrower one is a hard stop,
which is how a terrain keeps the camera out of its ground and a fractal keeps
it from zooming inside itself. Declare only what fits: a look may take any of
the three. At 0 — the default, and wherever nobody has touched them — the
camera is untouched, so the screensaver and the stills are unchanged.

Then hand them to the prelude, between the camera's `right` and its `up`,
passing the world-up hint `right` was crossed from:

```
float3 right = normalize(cross(upHint, fwd));
// An object: swing round a pivot, and walk towards it to zoom.
lerpOrbit(u.yaw, u.pitch, u.magnify, float3(0.0), upHint, ro, right, fwd);
// Or a place: turn where you stand, and lengthen the lens to zoom.
float lens = lerpLook(u.yaw, u.pitch, u.magnify, upHint, right, fwd);
float3 up = cross(fwd, right);
float3 rd = normalize(uv.x * right + uv.y * up + lens * focal * fwd);
```

`lerpLook` returns what to multiply the focal length by. Multiply it into every
use of the focal length, a per-pixel footprint included
(`px = 2.0 / (lens * focal * minRes)`), so a raymarcher's detail sharpens as the
lens lengthens; `lerpOrbit` needs nothing, because a dolly keeps the pixel's
angle. Both turn the whole frame rigidly, so it never degenerates even upside
down, and both work out which way the look's own `right` points, so
`cross(fwd, up)` cameras need nothing different.

Pick by what is under the pointer: `lerpOrbit` when it is near the pivot (a
fractal, an object), `lerpLook` when it is far beyond the camera (a landscape,
a corridor, the inside of a set). Choose wrongly and the scene moves against the
hand, and a zoom walks you into a wall. Find `magnify`'s upper limit by
rendering it: `castle-to-castle` stops at 0.3, past which its capped march
loses the fold. A splat look needs only the parameters (`SplatData` dollies
its camera, or with `:look` turns it in place and lengthens the lens); a look
whose camera is built in Swift uses `LerpTurn.orbit`, `LerpTurn.look` or, for a
fixed camera and a turning object, `LerpTurn.orbitRotation` (`polytope-4d`,
which dollies its own eye distance). `mandelbulb`, `maze` and `mandelbox` (which
uses both) are the worked examples. See `Sources/LerpCore/LerpTurn.swift` and
`Sources/Playground/RenderGestures.swift`.

## Shaders that need CPU-computed data

Almost nothing does. `LerpUniforms` plus procedural noise covers every shader
in this repo except two: `pipes`, which needs a lattice walk that no fragment
shader can produce on its own, and `heatmap`, which needs large-radius blurs
that an integral image computes in O(1) per pixel and a fragment shader cannot.
For those cases a shader can opt into a **data provider**: a Swift object that
computes something on the CPU each frame and binds it for the fragment function.

Opt in with a comment on one of the file's first 40 lines:

```metal
// lerp-data: pipes
```

Then take extra bindings in `lerpMain`. Buffer index 0 stays `LerpUniforms`;
providers own index 1 and up:

```metal
fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpPipesFrame& F [[buffer(1)]],
                        device const uint* nodes [[buffer(2)]])
```

The provider supplies its own MSL declarations (here `LerpPipesFrame`,
`LerpPipesNode`, `lerpPipesDecode`), which the engine splices into the prelude
just ahead of `#line 1` — so compile-error line numbers still point at your
file. Read the provider's `metalPrelude` to see what it binds and where.

A provider can bind textures as well as buffers — `HeatmapData` binds one at
fragment texture 1 and supplies the `constexpr sampler` for it, so its shader
takes `texture2d<float> processed [[texture(1)]]`.

Providers and `// lerp-param:` compose: the parameters ride in the index-0
`LerpUniforms` binding, so a shader can declare both.

Writing one: conform to `LerpDataProvider` in `Sources/LerpCore/`, register it
in `LerpDataProviders`, and give the shader a matching `// lerp-data:` line.
`PipesData.swift` is the worked example. Two rules:

- **Derive, never accumulate.** `bind(to:uniforms:)` must compute this frame's
  data from `uniforms` alone. A frame in this project is a pure function of
  (shader, time, seed): `--snapshot --time 60` has to produce the same image
  whether or not t = 0…59 were rendered first. That property is what the
  `--snapshot`, the playground's time scrubber and thumbnail generation all
  rest on. Regenerating from scratch is cheap — `pipes` replays a ~1000-step
  lattice walk every frame in about 70 µs. Caching is only allowed when the
  cache key *is* the whole input: `heatmap`'s pre-pass reads (seed, drawable
  size) and never the clock, so it is built once per distinct key and rebuilding
  it every frame would produce identical bytes.
- **Do not write a buffer the GPU may still be reading.** Use `LerpBufferRing`,
  which hands out one of three buffers in rotation.

- **If it genuinely cannot be derived, bound it.** A cellular automaton or any
  other iterative simulation has no closed form: generation N is only defined
  through N−1. Do not reach for a feedback texture and give up on purity — the
  cost is not just `--snapshot`, it is the rotation gallery resuming at a still's
  own time and the desktop handoff re-rendering, at native size, whatever
  (time, seed) the saver stopped on after hours of running. Instead reseed on a
  fixed period from `(seed, epoch)`, which caps the work to reach any t at one
  epoch's worth of steps. `life` sizes each epoch to the story it tells and uses
  a sparse board for canonical finite patterns, so even the R-pentomino's full
  1,103 generations stay bounded. Stepping a cached board forward is then legal
  under the caching rule above, because its key is the whole input. See
  `Sources/LerpCore/LifeData.swift`.

- **Simulations can step on the GPU.** A provider may implement
  `encodeCompute(into:uniforms:params:)`, called on the frame's command buffer
  before the render pass, and hand its kernels to `LerpGPUSimulation`, which
  keeps the same bounded-epoch, keyed-catch-up contract with ping-pong
  textures. `SandpileData.swift` is the worked example;
  `docs/metal-capabilities.md` has the kernel rules that keep it deterministic.

- **Parameters.** `bind(to:uniforms:)` does not receive the shader's
  `// lerp-param:` values. A provider that needs them — `life` takes its cell
  size and generation rate from `size` and `speed` — implements the `params`
  overload instead; it defaults to the two-argument form, so providers that
  ignore parameters need no change.

**Pictures.** `// lerp-data: image:<name>` (`ImageData.swift`) binds a photo
at `texture(1)` — decoded into Display P3, so returning
the sample unchanged shows the photo's own pixels — and its 16-bit nearness map
`<name>.depth.png` at `texture(2)`, with `lerpImageSampler` to read them.
`depth-window` is the worked example; `make depth-window` makes the pair from
any photo.

A shader with no `// lerp-data:` line gets no provider, is bound exactly as it
always was, and needs no changes.

**Shaders that need newer hardware.** `neural-field` uses Metal 4 tensors and
Metal Performance Primitives, which exist only on macOS 26+ with a `.metal4`
GPU. It says so on one of its first 40 lines:

```metal
// lerp-requires: metal4
```

`ShaderLibrary.discover()` leaves such a shader out on a machine that cannot run
it, so it is absent from the rotation, the gallery and every picker there,
rather than present as a compile error. `metal4` is the only requirement this
build knows; an unknown word hides nothing. `NeuralFieldData.swift` is also the
worked example of binding a tensor through the classic render encoder: the
tensor sits in an argument buffer (its `gpuResourceID`) bound with
`setFragmentBuffer`, plus `useResource`.

## Minecraft looks

A look on the Minecraft shelf draws with the game's own textures. It says so
on one of its first 40 lines and takes the texture arrays it reads:

```metal
// lerp-category: Minecraft
// lerp-requires: minecraft

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]],    // block faces, 16x16
                        texture2d_array<float> mcItems [[texture(9)]],    // items, 16x16
                        texture2d_array<float> mcSkins [[texture(10)]],   // mobs, particles, sun, moon: 64x64
                        texture2d_array<float> mcMaps  [[texture(11)]])   // clouds, colormaps, rain: 256x256
```

Declare only the arrays you use. They sit at texture 8 and up, beside
whatever `// lerp-data:` provider the look has, which keeps buffer and texture
indices 1 and up (`hedge-maze` walks `maze` and reads tiles).

The textures are Mojang's, so they are not in this repo and never in a
release. `make minecraft` unpacks them from the game installed on this Mac
(`MINECRAFT_JAR=` picks a version, `MINECRAFT_PACK=` lays a 16× resource pack
over it) into `~/Library/Application Support/Lerping/Minecraft`. A Mac that
has not run it has no Minecraft looks: `lerp-requires: minecraft` hides them,
as `metal4` hides `neural-field`. Do not draw a stand-in texture when one is
missing; there is no such case.

**Finding a texture.** `~/Library/Application Support/Lerping/Minecraft/atlas.txt`
lists every constant with its source file, size and frame count. Grep it; do
not guess names.

| Constant | Array | From |
|---|---|---|
| `MC_STONE`, `MC_OAK_LOG_TOP`, … | `mcTiles` | `block/*.png`; an animated strip is one layer per frame, with `MC_X_FRAMES` and `MC_X_TICKS` |
| `MC_ITEM_DIAMOND_SWORD`, … | `mcItems` | `item/*.png` |
| `MCS_PIG_TEMPERATE`, `MCS_PARTICLE_FLAME`, `MCS_ENVIRONMENT_CELESTIAL_SUN`, `MCS_BLOCK_WATER_FLOW`, … | `mcSkins` | anything else up to 64 px, unscaled in the layer's top-left corner, with `MCS_X_SIZE` in pixels |
| `MCM_ENVIRONMENT_CLOUDS`, `MCM_COLORMAP_GRASS`, … | `mcMaps` | anything up to 256 px, with `MCM_X_SIZE` |

To see a texture, Read the PNG itself under `build/minecraft-src/assets/minecraft/textures/`
(mob skins are unwrapped box layouts; look before you map one).

**Sampling.** Pixels are Display P3 with straight alpha, already in the space
shaders here write. The prelude adds, for a shader that requires minecraft:

- `mcTile(mcTiles, layer, uv, footprint)`: a block face. `uv` is 0…1 across
  the face and repeats; `uv.y = 0` is the top row of the picture, so on a side
  face pass `1 - fract(y)`. `footprint` is the width of one screen pixel at the
  hit, in blocks. Texels are hard-edged up close, blend over exactly one pixel
  at their edges, and mip-filter once they are smaller than a pixel, so nothing
  shimmers. `mcTileAniso` takes the uv change per screen pixel instead, for a
  floor running to the horizon.
- `mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, u.time)`:
  the frame of an animated tile.
- `mcSkin(mcSkins, layer, pixel, w)` and `mcMap(mcMaps, layer, pixel, w)`:
  addressed in the picture's own pixels, `w` the screen pixel's width in them.
- The game's conventions, so every look agrees: `mcFaceShade(normal)` (top 1,
  bottom 0.5, z faces 0.8, x faces 0.6), `mcLight(level)` (brightness of light
  level 0…15), `mcLightmap(blockLevel, skyLevel, day, ambient)` (the game's
  whole lightmap: warm block light, sky light that blues as it dims, the
  dimension's ambient, the Brightness option; multiply the texture by it),
  `mcBright(colour)` (the Brightness option alone), `mcSkyAt(day)` /
  `mcFogAt(day)` and the `MC_FOG_*` Nether and End fogs, `mcGrassTint` / `mcFoliageTint(mcMaps, temperature, downfall)`,
  `mcGrassSide(mcTiles, uv, footprint, tint)`, `mcFromSRGB(colour)` for a
  colour quoted from the game, and `MC_WATER_TINT`, `MC_SKY_DAY`, `MC_FOG_DAY`.

- The game's small block models, to call from a march when a ray enters a
  cell that holds one: `mcLantern` (standing or hanging; the soul lantern by
  layer), `mcTorch`, `mcWallTorch`, `mcCross` (short grass, flowers,
  saplings), `mcCrop` (wheat and the other crops by stage) and `mcBeacon`.
  Each takes the block's origin, the ray and a `(tMin, tMax)` range, does its
  own bounding test, and fills a `McModelHit` (distance, normal, tinted colour,
  whether to face-shade). Pass `tMin` a hair below the cell's entry distance:
  it is exclusive and a model face can lie on the cell boundary. The
  `mcModelBox…` and `mcModelQuad…` pieces they are made of are there for a
  model the kit does not have yet. Source and full comments:
  `Sources/LerpCore/MinecraftKit.swift`.

- More of the kit, same calling style (source and comments in
  `MinecraftKit.swift`):
  - Low sun: `mcSkyDay(sunY)`, `mcLightDay(sunY)`, `mcSunsetAt(sunY)`,
    `mcSunsetFan(rd, sun, glow)` and `mcFogToward(fog, glow, look, sun)`, the
    game's sunrise fan and the fog warmed toward the sun.
  - `mcGrassSideAniso(tiles, uv, duvdx, duvdy, tint)` for a bank seen at a slant.
  - `mcCrossFacing` (amethyst clusters and buds on any of six faces),
    `mcFacePlate`, `mcGlowLichen`, `mcVine`; directions are `MC_DIR_DOWN…EAST`.
  - `mcChest(skins, layer, origin, facing, …)`, by skin (normal, trapped, ender).
  - `mcFence(tiles, planksLayer, origin, arms, …)`; with `mcLantern` one block
    up it is the game's lamp post.
  - Small trees: `mcTreeGrow(kind, origin, seed)` (`MC_TREE_OAK`, `BIRCH`,
    `SPRUCE`, grown by the game's rule), `mcTree(…)` (logs, and leaves cut out
    by their alpha) and `mcTreeShade` for the sky light a canopy takes off the
    ground. The look decides where trees stand and calls in when a ray
    enters `mcTreeBounds`.

**Mobs.** A look that says `// lerp-requires: minecraft mobs` also gets the
game's mobs, drawn from their real skins on the game's own box models (the
geometry is dumped from the installed game by `make minecraft`, so it is
machine-local like the textures). It must take both `mcSkins` and `mcMaps`.
A mob stands in its own space: blocks, y up, feet on y = 0, facing +z.

```metal
float3 lro, lrd;
mcMobRay(ro, rd, mobPos, heading, lro, lrd);            // heading 0 faces +z, pi/2 faces +x
float2 b = mcMobBounds(MCMOB_COW, lro, lrd);            // cheap box test first
if (b.x < b.y && b.x < best) {
    MCMOB_Pose pose = mcMobStill(); pose.walk = t * 4.0; pose.speed = 0.4;
    MCMOB_Skin skin = mcMobSkin(MCS_COW_TEMPERATE);
    MCMOB_Hit h = mcMobTrace(MCMOB_COW, pose, skin, lro, lrd, best, mcSkins, mcMaps);
    if (h.t < best) {
        best = h.t;
        float4 c = mcMobColor(MCMOB_COW, h, skin, h.t * pixelAngle * 16.0, mcSkins, mcMaps);
        col = c.rgb * mcFaceShade(mcMobNormal(h.n, heading)) + c.rgb * c.a;   // .a is glow (enderman eyes)
    }
}
```

`MCMOB_Pose` has `walk` and `speed` (the game's walk phase and stride; 0.3–0.6
is a walk), `yaw`, `pitch`, `graze`, `flap`, `wag`. `mcMobVillagerSkin(base,
biome, profession, level)`, `mcMobSheepSkin(baby, woolly, dye)` and
`mcMobEndermanSkin()` build the layered skins. The header of
`~/Library/Application Support/Lerping/Minecraft/mobs.metal` lists every
`MCMOB_*` type and what is not covered. Testing every mob's bounds for every
pixel is the real cost (41 box tests a pixel is about 5 ms at Retina size):
narrow the candidates first, by grid cell or by where the mob is on screen.

Do not hand-build a second copy of anything in the kit. If a look needs a
model or convention it lacks, add it to the kit so the next look has it too.

Several textures are grey and take a tint in the game: grass tops, leaves,
vines, water. The sun and moon are drawn on black and added to the sky.
Leaves, glass and plants carry their shape in alpha.

Read `Sources/LerpCore/MinecraftAssets.swift` for the exact helper source.

## House style

- **Ambience**: this runs as a screensaver. Slow the original's time scale
  (typically 0.2–0.8×) so motion is calm.
- **Seed**: mix `u.seed` into the time/phase (e.g. `t = 0.4*u.time + u.seed*60.0`)
  so every activation looks different.
- **Palette**: baked constants, tasteful, generally dark-leaning (it's a
  screensaver — avoid full-screen white). Look at paper.design's demo
  defaults for reference, or choose your own that fits a calm ambient mood.
- **Finish**: run `color = lerpDither(color, pos);` before returning to avoid
  banding on gradients.
- **Attribution header**: first lines of the file, e.g.
  `// Metaballs — ported from paper-design/shaders (Apache-2.0)`
  `// https://github.com/paper-design/shaders`
  plus any upstream credit the original carries.

## Verify (required)

From the repo root (`build/LerpPreview` already exists; no rebuild needed —
shaders are discovered from `Sources/Shaders/` automatically):

```sh
./build/LerpPreview --snapshot build/snapshots --shader NAME            # t=3
./build/LerpPreview --snapshot build/snapshots-t9 --shader NAME --time 9 --seed 0.31
```

Then actually LOOK at both PNGs (Read them). Pass criteria:
- compiles (CLI prints OK; non-zero exit + diagnostics on failure)
- mean luma printed by the CLI lands in ~0.03–0.85
- the image shows the intended structure (not black, not solid color, not
  obviously broken UVs) and the two timestamps/seeds differ (it animates)
- looks good at 1200x750 — full-screen composition, no vignette-crop assumptions
