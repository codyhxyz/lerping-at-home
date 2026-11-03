# Metal capabilities: what the engine uses, what it now adds, what it skips

Lerping@Home draws every look as one fullscreen fragment pass, optionally fed
by a CPU data provider (`// lerp-data:`). Before this change it already used
the Metal 4 compiler (`MTL4Compiler`, macOS 26+), inline tensors in a fragment
shader (`neural-field`, `// lerp-requires: metal4`), EDR output, frame pacing
and per-look GPU cost (`LerpGPUCost`, `LerpPreview --bench`).

This note records the survey of Apple's Metal stack
([sample code index](https://developer.apple.com/metal/sample-code/)), the
one feature built from it, and concrete recommendations for the rest.

## Built: GPU-stepped simulations for data providers

`Sources/LerpCore/GPUSimulation.swift` (`LerpGPUSimulation`), driven from a new
`LerpDataProvider.encodeCompute(into:uniforms:params:)` hook that
`LerpRenderer.encodePass` calls on the frame's command buffer before the render
pass opens. Every host already draws through `encodePass` (the saver inside
`legacyScreenSaver`, the playground, `LerpPreview --snapshot`, gallery
thumbnails, the crossfade's outgoing look, `--bench`), so all of them get it
with no host changes. The hook is a no-op by default, so every existing shader
encodes exactly the same commands as before: all 33 shaders snapshot
byte-identical before and after, at two (time, seed) pairs.

### Why this one

- The three simulations being written now (reaction-diffusion, physarum,
  stable fluids) are all grid stencils. On the CPU they cost milliseconds a
  step at screen-filling sizes, and a simulation's whole cost is paid again on
  every cold catch-up (`--snapshot --time T`, the scrubber, a look switch
  mid-epoch, the desktop handoff). On the GPU a 330×220 step costs about as
  much as one dispatch: ~9 µs.
- None of the alternatives below removes a real bottleneck today except
  MetalFX upscaling, and that one trades image quality for a frame budget
  only a few looks exceed (see the table at the end).

### How the purity contract survives

A frame is still a pure function of (shader, time, seed, parameters):

1. **Bounded epochs.** The provider maps the clock to `(epoch, step)` with no
   history, exactly as `LifeData` does. The epoch length depends only on the
   parameters, so reaching any time costs at most one epoch of steps.
2. **Reseed from the key.** The seed passes build generation 0 from
   `LerpGPUSimulation.Key` = `(seed, epoch, grid size, config floats)` alone.
   Use `lerpSimHash(x, y, salt)`: an integer hash with a bit-identical CPU
   twin (`LerpGPUSimulation.hashBits`), unlike the prelude's float hashes.
3. **Catch-up keyed on the whole input.** `advance(_:to:of:)` steps cached
   state forward only when the key matches and the target is ahead.
   Otherwise it reseeds. A command buffer that errors clears the cache, and if
   the render encoder cannot be made, `encodePass` still commits the compute
   work, so the CPU's idea of the current generation never gets ahead of the
   bytes on the GPU.
4. **Deterministic kernels.** Passes run in order on one serial compute
   encoder. Rules for kernel authors:
   - Each thread writes only its own texels of a ping-ponged plane and reads
     only current textures (or its own threadgroup tile).
   - No float atomics: their order isn't fixed, so their sum isn't either.
     Integer atomics commute and are fine, into a `pingPong: false` plane
     (fixed-point deposits, counts).
   - Float math is deterministic on one machine (same GPU, same compiled
     code, `mathMode = .fast` as everywhere else). Don't expect bit-identical
     floats across GPU families or OS updates. That's fine here, because stills
     are rendered and cached on the machine that shows them. Integer state, as
     in `sandpile`, is identical everywhere.

Measured with a throwaway harness (not shipped) that runs one provider frame
by frame for 20 s of clock and a fresh one cold to the same time, then compares
the textures: identical in every case tried (1, 2 and 3 sources; growing,
settling and settled phases; blocked against plain stepping).

### Using it from a provider

```swift
final class MySimData: LerpDataProvider {
    let sim = try? LerpGPUSimulation(
        device: device, label: "my-sim", source: kernels,       // MSL, compiled after
        planes: [.init("state", pixelFormat: .rg32Float)],      // LerpPrelude.helpers
        seed: [.init("mySeed")],                                // + kernelHeader
        step: [.init("myStep")],
        blockedStep: .init("mySteps", stepsPerDispatch: 8, tileSide: 64, halo: 8,
                           threadgroupSide: 32))                // optional

    func encodeCompute(into cb: MTLCommandBuffer, uniforms: LerpUniforms,
                       params: LerpParameterValues?) {
        let (epoch, step, config) = clock(uniforms, params)     // pure, LifeData-style
        let key = LerpGPUSimulation.Key(seed: uniforms.seed, epoch: epoch,
                                        width: cols, height: rows, config: config)
        textures = sim?.advance(cb, to: step, of: key)
    }
    func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        encoder.setFragmentTexture(textures?[0] ?? placeholder, index: 1)
    }
}
```

Kernel bindings, every dispatch: `texture(i)` is plane *i*'s current texture,
`texture(planes + i)` its next one, and `buffer(0)` is `constant LerpSimFrame&`
(`size`, `seed`, `epoch`, `step`, `pass`, `iteration`, `count`, `config[4]`).
Kernels bounds-check against `f.size`, because dispatches are whole
threadgroups.

- `Pass(kernel, domain:, repeats:, writes:)`: `repeats` runs it N times in a
  row (a Jacobi solve). `writes` names the planes it produces; only those swap.
- `Plane(label, pixelFormat:, extent:, pingPong:, atomic:)`: `extent` fixes a
  size that isn't the grid (one agent per texel). `pingPong: false` is a single
  texture bound at both indices, for scratch and integer-atomic targets.
- `BlockedStep` is temporal blocking. One dispatch loads a tile into threadgroup
  memory, runs `f.count` steps there, and writes back the core that the tile
  edge cannot have reached yet. Stepping a small grid is bound by dispatch
  overhead, not arithmetic, and blocking turns 8 dispatches into one. It must
  produce the same bits as the plain passes, which stay the reference and the
  fallback (a GPU that cannot run the threadgroup size, or
  `blockingEnabled = false`). It replaces the whole step and writes every
  plane, so it suits single-pass stencils.

Compute pipelines are built in the provider's `init`, which `ShaderLibrary`
runs on its background compile queue, never on the render thread. A provider
whose kernels fail to build should bind a placeholder and tell its shader
(`sandpile` passes `ready = 0` and draws a quiet fallback field) rather than
leave a texture slot unbound. No `// lerp-requires:` is needed: compute and
32-bit integer read/write textures exist on every Mac that runs macOS 14.

### The showcase: `sandpile`

`Sources/Shaders/sandpile.metal` + `Sources/LerpCore/SandpileData.swift`. This is
the Abelian sandpile (Bak, Tang & Wiesenfeld, 1987). Grains pour into one to
three sources chosen from `(seed, epoch)`, every unstable cell topples `h/4`
times per step, and the pile settles into the model's fractal. Order-independence
is a theorem for this model, so the parallel schedule reaches the same pattern a
serial one would, and its state is all integers. Each story pours, settles
(budget 0.34·rows² steps, measured: 0.31·rows² for the slowest case of every
grain dropped at once), holds, fades and reseeds. The clock runs steps ∝ phase²
so the front advances evenly.

Measured on an M5 (default 220 rows, so 330×220 cells for 16:10):

| | cost |
|---|---|
| live stepping, blocked (≤ ~10 steps/frame) | 0.027 ms GPU/frame mean, 0.12 ms max |
| live stepping, plain | 0.061 ms GPU/frame mean |
| fragment pass at 5120×2880 | 0.61 ms (4% of a 60 fps frame) |
| worst cold catch-up (19,304 steps), blocked 64-cell tiles | 70–130 ms GPU, 1.6–2.7 ms CPU encode |
| same, blocked 32-cell tiles | 161 ms GPU, 1.7 ms encode |
| same, one step per dispatch | 174 ms GPU, 17–28 ms encode |

Contention from other GPU work inflates these severalfold (seen while
parallel builds ran). A cold catch-up happens on a snapshot, a scrub backwards,
the desktop handoff, and a rotation switch into the look mid-epoch, because the
clock keeps running across looks. The last of these costs one long frame,
comparable to `game-of-life`'s R-pentomino catch-up on the CPU.

### Migration notes for the CPU simulations

- **Reaction-diffusion** fits directly: one `rg32Float` (or `rg16Float`) plane
  and a 5-point Laplacian step. Gray-Scott needs thousands of steps per
  epoch, so add a `BlockedStep` (the halo is one cell per step) and compare it
  against the plain pass with `blockingEnabled = false`. Seed with
  `lerpSimHash`.
- **Physarum**: agents in a fixed-extent `rgba32Float` plane (x, y, heading,
  spare), trail at grid size, deposit as an `r32Uint` plane with
  `pingPong: false, atomic: true`. Step passes: clear deposit
  (`writes: [deposit]`), then move agents (reads trail, `writes: [agents]`,
  domain = agents, and `atomic_fetch_add` fixed-point deposits into the
  deposit plane), then diffuse and decay (reads trail and deposit,
  `writes: [trail]`). Integer deposits keep it deterministic, which a float
  scatter would not be. No blocking (scatter isn't a local stencil).
- **Stable fluids**: planes velocity `rg32Float`, dye `rgba16Float`, pressure
  and divergence `r32Float`. Steps: advect (`writes: [velocity, dye]`),
  divergence (`writes: [divergence]`), Jacobi (`writes: [pressure]`,
  `repeats: 20–40`), project (`writes: [velocity]`). That's 25–45 dispatches a
  step, roughly 0.3–0.5 ms, so keep epochs short in *steps* (a few thousand
  at most). Run 30–60 steps a second, or the worst catch-up passes a second.
  Warm-starting the Jacobi solve from the previous step's pressure is legal:
  pressure is a plane, so it is part of the generation like everything else.
- In every case: move the stepping loop into kernels, keep the clock-to-
  `(epoch, step)` mapping and the epoch length exactly as the CPU version had
  them, and let `advance` own the cache. Delete the provider's own
  ring buffers: nothing is written from the CPU any more.

## Assessed, not built

### MetalFX spatial upscaling, for heavy looks at 5K (recommend: next, opt-in)

`LerpPreview --bench --size 5120x2880` on an M5, mean GPU ms per frame:
paper-texture 23.5 (141% of a 60 fps budget), pipes 13.7, halftone-cmyk 12.8,
voronoi 12.4, pulsing-border 12.0, smoke-ring 11.9, perlin-noise 10.8,
neural-field 9.7. Everything else is under 9.3, and half the list is under 4.

`MTLFXSpatialScaler` (macOS 13+, check `MTLFXSpatialScalerDescriptor.supportsDevice`)
renders at, say, 0.67× per axis (0.44× the pixels) and upscales. That would put
paper-texture at ~11 ms. Recommendation:

- Make it a per-shader opt-in, `// lerp-render-scale: 0.67`, never global.
  Halftone, dithering, dot-grid and anything with hard 1-px structure would
  smear, and they are among the heavy ones. Soft looks (smoke-ring,
  perlin-noise, paper-texture's fibres at 5K) can take it.
- Apply `lerpDither` after the upscale, in the output pass, not in the shader.
  Dither at low resolution becomes blocky noise once upscaled.
- It is deterministic, so snapshots and thumbnails stay pure. Snapshots should
  go through the same path so a tile matches the screen.
- The temporal scaler is not a fit. It needs per-pixel motion vectors and
  sub-pixel jitter, which procedural fullscreen shaders do not have, and it
  accumulates history, which breaks the frame-is-a-pure-function rule.
- A cheaper first step without the framework: render at reduced size and let
  the existing EDR or crossfade composite pass sample it bilinearly. Ship that
  first if quality is acceptable. Rasterization rate maps (variable-rate
  shading) are a third option for looks whose detail is concentrated
  centrally.

### Mesh / object shaders, for point and line art (recommend: later, with a geometry path)

`pipes` costs 13.7 ms at 5K because the fragment shader searches a lattice at
every pixel. Drawn as geometry (tube segments from `PipesData`'s node buffer),
it would cost per segment, not per pixel. A future GPU physarum could draw
agents as points. Plain instanced quads cover both, though. Mesh and object
shaders (macOS 13+) add value only when the GPU decides how much geometry to
emit (LOD, culling, amplification from simulation state). Both need a
`// lerp-geometry:` render path with a vertex stage, blending and probably
MSAA, which is a larger engine change than this one. Do instanced quads first.

### Indirect command buffers (recommend: no)

These pay off when CPU encoding of many draws is the bottleneck. Here a frame is
one draw plus a handful of dispatches, and the blocked stepper already cut
catch-up encoding to ~2 ms. A GPU-driven "step until stable" would be the one
use, and it is deliberately excluded: the step count must come from the clock
on the CPU, or catch-up isn't keyed on the input.

### Metal 4 command model (recommend: not until the render loop moves)

`MTL4CommandQueue`, `MTL4ArgumentTable`, residency sets, explicit barriers,
and the unified compute/blit encoder. Explicit barriers could trim
per-dispatch cost for the stepper. But the frame would have to be encoded on an
`MTL4CommandBuffer` end to end, and the renderer, EDR, crossfade and snapshot
paths all use the classic queue. `PipelineCompiler.swift` already moved only
the compiler, for that reason. Revisit when macOS 26 is the floor.

### Metal 4 machine learning (recommend: a learned-CA showcase on top of the stepper)

`neural-field` already runs inline tensor ops in a fragment shader. The same
`matmul2d` in a compute kernel turns `LerpGPUSimulation` into a host for
neural cellular automata (Mordvintsev et al., "Growing Neural Cellular
Automata", Distill 2020): per-cell 3×3 perception plus a small MLP per step.
Its stochastic update mask must come from `lerpSimHash(cell, step, seed)` to
stay deterministic. It needs `// lerp-requires: metal4`, and trained weights
under a licence compatible with AGPL. `MTL4MachineLearningCommandEncoder`
(Core ML packages on the GPU timeline) is overkill for networks this size.

### Not relevant here

Hardware ray tracing has no triangles to trace in an SDF or procedural look.
Tile shaders and imageblocks might fuse the EDR expand into the main pass, for
little gain at one pass. Sparse textures and the shader converter aren't
relevant. Binary pipeline archives were measured and left off by default; see
the header of `LerpPipelineArchiveStore`.
