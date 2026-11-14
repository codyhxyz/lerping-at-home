# Growing neural CA: source and implementation notes

Research only: this does **not** implement a look or establish that a model
heals in Lerping. The integration and the growth, damage/recovery and
cold/live reproducibility tests remain to be done.

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
with exceptions for reused figures. Confirm that the repository license
covers the model weights and retain appropriate attribution and license text
before redistributing; no model has been added here. In particular, do not
assume the JavaScript's license alone covers the model data.

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
