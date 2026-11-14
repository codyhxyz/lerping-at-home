# Growing neural CA: source and implementation notes

The `neural-ca` look now ports the planarian model below using ordinary GPU
arithmetic, not Metal tensor acceleration. Its deterministic replay, growth,
wound and recovery are checked by `build/LerpPreview --nca-selftest`.

## Prior art and weights

Mordvintsev et al., [Growing Neural Cellular Automata](https://distill.pub/2020/growing-ca/)
(Distill, 2020) supplies the method and an interactive implementation. At
[upstream commit a12c7efa541b5770043a8d5470bffeacfd7b0435](https://github.com/distillpub/post--growing-ca/tree/a12c7efa541b5770043a8d5470bffeacfd7b0435),
`public/webgl_models8/ex3_planarian.json` is a candidate trained model for
the damage-trained example, not a network invented here. Its JSON SHA-256 is
`9cb2696358eec7c3b596c604b550eeb3aa93ca885dc8d177435264322cf2d6ee`.
The two base64-decoded tensors contain respectively 6,272 and 2,064 bytes,
matching `(48 + 1) * 128` and `(128 + 1) * 16`. Their SHA-256 values are
`fdd296bc571d99858a909212654481362770ffb494ac768245fca7f79599849d` and
`38e7b9239dd71a287f830d672c98b5226284d000796d4d5caf7876842d211ae2`.
The sizes and checksums verify the download's structure, not its behavior.

The upstream repository's `LICENSE` is CC BY 4.0; `public/ca.js` separately
has an Apache 2.0 header. The article labels its text and diagrams CC BY 4.0,
with exceptions for reused figures. The repository tree at that commit contains no more-specific license for the
weights; the repository-wide CC BY 4.0 therefore applies to the model. The
separate Apache 2.0 notice applies to `ca.js`. Both license texts and credit
are retained in `third_party/growing-ca` and the distributed bundles.

## Porting constraints

The upstream `public/ca.js` establishes 16 state channels; perception
concatenates identity and two Sobel derivatives; two dense layers have 128
hidden and 16 output channels, with ReLU on the hidden layer. Model bytes are
packed as a texture with output channels across rows and input channels plus
bias down columns; the shader decodes normalized bytes using separate weight
and bias scales and a center of 0.5. Its update mask uses a 0.5 probability.
Its life mask checks the maximum alpha in a 3×3 neighborhood **both before
and after** the proposed update. The latter requires neighboring proposed
updates, so a single per-cell read-old/write-new pass cannot reproduce it.
Its texture read wraps coordinates. The upstream seed sets the alpha and
hidden channels to one at the center and visible RGB to zero.

Use `Sources/LerpCore/GPUSimulation.swift` for deterministic keyed stepping;
see `Sources/LerpCore/SandpileData.swift` and `Sources/Shaders/sandpile.metal`
for provider, fallback and shader conventions. The reference's `Math.random()`
mask cannot support scrubbing: use the documented deterministic cell, step and
seed hash instead. Wounds must likewise be a deterministic part of the epoch
and generation, not a side effect of rendering. Register the provider in
`Sources/LerpCore/DataProvider.swift`, and use `lerp-requires: metal4` as in
`Sources/Shaders/neural-field.metal`; account for compilation or allocation
failure as well as discovery gating.

A successful port must measure growth and recovery after a specified wound
against the undamaged target or a suitable baseline, and compare cold and
incremental access to the same generation, including backwards scrubs. The
article's regeneration examples do not establish that a different boundary,
random mask, wound schedule, precision, or seed works in this port. Measure
actual GPU cost and memory as well; neither has been measured here.

## Port and measured behavior

The state is 16 float channels on a 96×96 toroidal grid. Two GPU passes
compute the dense update and apply the pre/post life masks. At step 320 an
identical, circular wound is applied to all channels. Dropout hashes cell,
step, seed and epoch; each 640-step epoch starts from the center seed. This
changes the WebGL renderer's quantized activation representation and random
stream; it is not a bit-for-bit reproduction. We use scalar Metal arithmetic,
not a tensor API. Eight double-buffered RGBA32Float planes occupy 2.25 MiB
(excluding driver overhead). Compilation/allocation failure draws a fallback.

On an Apple M5, seed 0.37, the self-test measured alpha mass 1 at step 0,
495.15 at 300, 494.99 at 319, 269.50 just after the wound at 320, and
485.57 at 500. Against an unwounded control the per-cell alpha L1 distance
was 227.10 immediately and 60.98 after 180 further steps. That demonstrates
partial recovery on this particular seed, wound, grid, and interval, not
general regeneration or convergence of all channels. Cold and incremental
replay and backward scrub matched bit-for-bit across all 16 channels on that
device. A 500-step cold replay took approximately 94 ms GPU, while the 180
steps after the wound took 34 ms GPU, including the test readback blit; results
are device-dependent.
