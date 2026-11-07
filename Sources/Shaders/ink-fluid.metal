// Ink Fluid — original shader written for Lerping@Home: ink dropped into a
// dark tank of water, stirred by an invisible hand.
//
// The simulation is Jos Stam's stable-fluids method from "Real-Time Fluid
// Dynamics for Games" (GDC 2003) — advect, diffuse, pressure-project, with
// dye carried along — implemented from the paper in
// Sources/LerpCore/InkFluidSolver.swift, plus vorticity confinement from
// Fedkiw, Stam & Jensen, "Visual Simulation of Smoke" (SIGGRAPH 2001). No code
// is taken from either; the paper's routines are named where they appear.
//
// lerp-category: Simulations
// lerp-data: ink-fluid
//
// Sources/LerpCore/InkFluidData.swift runs the solver on the CPU on a coarse
// grid (160 cells on the long axis) at a fixed 20 steps a second, and binds the
// dyes at the two steps either side of the clock plus the flow between them.
// This shader motion-compensates between those two states along the flow,
// upsamples with a cubic B-spline, and lights the result. A screensaver has no
// mouse, so a seeded script stands in for one: fifteen drops of ink, each
// pushed by a short jet that rolls up into an ink drop's mushroom of
// counter-rotating vortices, and a faint drifting swirl. Every 36 s (at speed
// 1) the tank clears and is reseeded from (seed, epoch), which is what keeps
// any frame reachable in bounded work (at most 720 solver steps) and every
// frame a pure function of (time, seed, params).
//
// Ink and the walls: the tank is closed, as in the paper, and dye soaks away
// in a narrow band along each wall so it does not trace the outline. Grid size
// follows the drawable's aspect, so a thumbnail and the full screen of the
// same shape run the same simulation. `speed` is a param this shader adds; it
// scales the clock, not the timestep.
//
// lerp-param: colorBack color          = (0.012, 0.020, 0.035) "Water"
// lerp-param: colorInk1 color          = (0.18, 0.40, 0.95)    "Ink 1"
// lerp-param: colorInk2 color          = (0.86, 0.30, 0.52)    "Ink 2"
// lerp-param: colorInk3 color          = (0.16, 0.78, 0.70)    "Ink 3"
// lerp-param: viscosity float 0 1      = 0.05  "Viscosity"
// lerp-param: stir      float 0 2      = 1     "Stir strength"
// lerp-param: curl      float 0 1      = 0.55  "Curl detail"
// lerp-param: speed     float 0.25 2   = 1     "Speed"
// lerp-param: ink       float 0.25 3   = 1     "Ink density"
// lerp-param: sheen     float 0 1      = 0.5   "Sheen"
//
// viscosity, stir and curl feed the solver (changing one re-runs the epoch);
// ink, sheen and the colours are display-only.
//
// lerp-preset: Sumi     colorBack=(0.030, 0.028, 0.026), colorInk1=(0.55, 0.56, 0.60)
// lerp-preset: Sumi     colorInk2=(0.30, 0.32, 0.38), colorInk3=(0.78, 0.70, 0.58)
// lerp-preset: Sumi     viscosity=0.3, curl=0.2, ink=1.1, sheen=0.7
// lerp-preset: Nebula   colorBack=(0.010, 0.006, 0.022), colorInk1=(0.55, 0.22, 0.95)
// lerp-preset: Nebula   colorInk2=(0.95, 0.35, 0.70), colorInk3=(0.25, 0.55, 1.00)
// lerp-preset: Nebula   viscosity=0.02, stir=1.3, curl=0.8, sheen=0.35
// lerp-preset: Ember    colorBack=(0.022, 0.010, 0.008), colorInk1=(0.95, 0.42, 0.12)
// lerp-preset: Ember    colorInk2=(0.80, 0.12, 0.10), colorInk3=(1.00, 0.72, 0.30)
// lerp-preset: Ember    viscosity=0.05, stir=0.8, curl=0.55, ink=0.9
// lerp-preset: "Kelp Bed" colorBack=(0.006, 0.020, 0.018), colorInk1=(0.10, 0.62, 0.48)
// lerp-preset: "Kelp Bed" colorInk2=(0.55, 0.70, 0.22), colorInk3=(0.08, 0.40, 0.60)
// lerp-preset: "Kelp Bed" viscosity=0.7, stir=1.5, curl=0.15, speed=0.7, sheen=0.6

// Cubic B-spline through four bilinear taps (the hardware does the inner
// weights): C2-smooth, so the coarse grid never shows its cells.
static float4 inkBicubic(texture2d<float> tex, float2 uv, float2 dims) {
    float2 t = uv * dims - 0.5;
    float2 i = floor(t);
    float2 f = t - i;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    float2 w3 = f3 / 6.0;
    float2 g0 = w0 + w1, g1 = w2 + w3;
    float2 p0 = (i - 0.5 + w1 / g0) / dims;   // texel i-1 / i, centre at +0.5
    float2 p1 = (i + 1.5 + w3 / g1) / dims;   // texel i+1 / i+2
    return g0.y * (g0.x * tex.sample(lerpInkSampler, float2(p0.x, p0.y))
                 + g1.x * tex.sample(lerpInkSampler, float2(p1.x, p0.y)))
         + g1.y * (g0.x * tex.sample(lerpInkSampler, float2(p0.x, p1.y))
                 + g1.x * tex.sample(lerpInkSampler, float2(p1.x, p1.y)));
}

static float inkTotal(float4 d) { return d.r + d.g + d.b; }

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpInkFrame& F [[buffer(1)]],
                        texture2d<float> dyeOld [[texture(1)]],
                        texture2d<float> dyeNew [[texture(2)]],
                        texture2d<float> flow   [[texture(3)]]) {
    // The grid is sized to the drawable's aspect, so screen UV is tank UV.
    float2 uv = float2(pos.x, u.resolution.y - pos.y) / u.resolution;
    float2 cell = 1.0 / F.dims;

    // Motion-compensated in-between: the later state is the earlier one
    // carried one step along the flow, so pull each part of the way there.
    float2 vel = flow.sample(lerpInkSampler, uv).xy * cell;
    float  f = F.fraction;
    float4 a = inkBicubic(dyeOld, uv - f * vel, F.dims);
    float4 b = inkBicubic(dyeNew, uv + (1.0 - f) * vel, F.dims);
    float4 d = max(mix(a, b, f), 0.0);

    float total = inkTotal(d);
    float3 tint = (d.r * u.colorInk1.rgb + d.g * u.colorInk2.rgb + d.b * u.colorInk3.rgb)
                / max(total, 1e-4);
    // Steeper than linear at the bottom so a dilute, well-mixed haze sinks
    // back into the water while plumes and filaments keep their edges.
    float density = 1.0 - exp(-2.6 * u.ink * total);
    density = density * (0.35 + 0.65 * density) * F.visibility;

    // Relief from the dye's own gradient, a cell either side, so thick ink
    // reads as a body with a lit shoulder rather than a flat stain.
    float2 q = uv + (1.0 - f) * vel;
    float gx = inkTotal(dyeNew.sample(lerpInkSampler, q + float2(cell.x, 0.0)))
             - inkTotal(dyeNew.sample(lerpInkSampler, q - float2(cell.x, 0.0)));
    float gy = inkTotal(dyeNew.sample(lerpInkSampler, q + float2(0.0, cell.y)))
             - inkTotal(dyeNew.sample(lerpInkSampler, q - float2(0.0, cell.y)));
    float3 normal = normalize(float3(-1.6 * u.ink * float2(gx, gy), 1.0));
    float3 light = normalize(float3(-0.45, 0.6, 0.66));
    float diffuse = 0.78 + 0.32 * dot(normal, light);
    float3 halfway = normalize(light + float3(0.0, 0.0, 1.0));
    float spec = pow(max(0.0, dot(normal, halfway)), 24.0) * smoothstep(0.05, 0.6, density);

    // Thin wisps stay dark and saturated; dense cores lift a little toward
    // their own highlight. Curl adds a faint glint where filaments wind up.
    float3 inkColor = tint * diffuse * mix(0.9, 1.3, density);
    float glint = smoothstep(0.08, 0.6, d.a) * density;

    // Water: a little light from above, nothing at the edges to crop.
    float3 water = u.colorBack.rgb * (0.85 + 0.3 * uv.y);
    float3 color = mix(water, inkColor, density);
    color += u.sheen * (0.22 * spec + 0.06 * glint) * mix(tint, float3(1.0), 0.5) * F.visibility;

    return half4(half3(lerpDither(color, pos)), 1.0h);
}
