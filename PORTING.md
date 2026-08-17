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
(`u.resolution` pixels, `u.time` seconds, `u.seed` random [0,1) per launch),
`lerpUV` (centered UV, [-1,1] short axis, y up), `lerpScreenUV` (0..1, y down),
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

- **NAME** — a valid MSL identifier, unique in the file, and not `resolution`,
  `time` or `seed`.
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
and **Shader → Save Look as Preset…** (`⇧⌘S`) writes exactly this form back into
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

- **Parameters.** `bind(to:uniforms:)` does not receive the shader's
  `// lerp-param:` values. A provider that needs them — `life` takes its cell
  size and generation rate from `size` and `speed` — implements the `params`
  overload instead; it defaults to the two-argument form, so providers that
  ignore parameters need no change.

A shader with no `// lerp-data:` line gets no provider, is bound exactly as it
always was, and needs no changes.

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
