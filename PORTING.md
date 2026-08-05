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
| uniform params (`u_color`, `u_scale`…) | bake as file-scope `constant` values with a tasteful palette |
| `fragColor = vec4(c, a)` | `return half4(half3(color), 1.0h)` (opaque; composite any alpha against a baked background color) |
| top-level `const` arrays | `constant float4 NAME[N] = {...};` at file scope |

Loops with `break` on a uniform count: use a fixed `constant int` count.

## Shaders that need CPU-computed data

Almost nothing does. `LerpUniforms` plus procedural noise covers every shader
in this repo except `pipes`, which needs a lattice walk that no fragment shader
can produce on its own. For those cases a shader can opt into a
**data provider**: a Swift object that computes something on the CPU each frame
and binds it for the fragment function.

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

Writing one: conform to `LerpDataProvider` in `Sources/LerpCore/`, register it
in `LerpDataProviders`, and give the shader a matching `// lerp-data:` line.
`PipesData.swift` is the worked example. Two rules:

- **Derive, never accumulate.** `bind(to:uniforms:)` must compute this frame's
  data from `uniforms` alone. A frame in this project is a pure function of
  (shader, time, seed): `--snapshot --time 60` has to produce the same image
  whether or not t = 0…59 were rendered first. That property is what the
  snapshot suite, the playground's time scrubber and thumbnail generation all
  rest on. Regenerating from scratch is cheap — `pipes` replays a ~1000-step
  lattice walk every frame in about 70 µs.
- **Do not write a buffer the GPU may still be reading.** Use `LerpBufferRing`,
  which hands out one of three buffers in rotation.

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
