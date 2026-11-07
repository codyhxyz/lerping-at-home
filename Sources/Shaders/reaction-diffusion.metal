// Reaction-Diffusion — Gray-Scott coral, dividing spots and fingerprints,
// grown slowly and reseeded every few minutes.
//
// lerp-data: reaction-diffusion
//
// Original work, not a port. The model is the Gray-Scott reaction-diffusion
// system (P. Gray and S. K. Scott, 1983-84), written from Karl Sims'
// explanation in his Reaction-Diffusion Tutorial,
// https://www.karlsims.com/rd.html — his diffusion rates (1.0, 0.5), his 3x3
// Laplacian weights, and his coral (f .0545, k .062) and mitosis (f .0367,
// k .0649) feed/kill values. The fingerprint and worm (f, k) pairs are points
// from J. E. Pearson's map of the system ("Complex Patterns in a Simple
// System", Science 261, 1993) as charted by Robert Munafo. Numbers, not code:
// no code is taken from any of these.
//
// Sources/LerpCore/ReactionDiffusionData.swift steps the simulation on the CPU
// in bounded epochs (see its header for the purity argument) and hands over
// one texel per cell: chemical B just before and just after the clock. This
// shader blends the two, upsamples with a cubic B-spline so cells never show,
// and lights B as a glossy relief.
//
// An epoch is 4,800 steps: the colonies grow out of a few ragged seeds, fill
// the screen, settle, then starve as the kill rate rises at the end and fade
// before a fresh seed. At the default 16 steps per second that is about four
// and a half minutes. "speed" changes only how long it takes in seconds.
//
// Once the colonies have filled the screen the chemistry all but stops: for
// about a third of every epoch fewer than 3% of pixels changed in two
// seconds. A camera drift (1.2 cells a second along a slow curve) and a
// swinging key light were added for that, and they were not enough: the
// user photographed Worms on the lock screen and called it "completely
// still". A frozen picture sliding rigidly at under 1% of the screen a
// second gives the eye nothing moving relative to anything else.
//
// So the chemistry is now stirred (`Stirring` in the Swift file): a slow,
// incompressible flow of wandering eddies carries both chemicals, and the
// reaction keeps mending what it bends. Worms stretch, kink, pinch off and
// rejoin; coral and fingerprint ridges bend, break and reconnect; spots get
// pulled out, divide and crowd. Different parts of the screen move
// differently all the time, for the whole epoch, not only while colonies
// grow. "stir" is the flow's RMS speed in cells per step, so like everything
// else it is the same look at any "speed". Worms are thin and break easily,
// and run at 30 steps a second, so they get less; the slower Fingerprint
// gets more. The drift and the light swing stay. All of it is a
// closed-form function of the clock, so a frame is still a pure function of
// (time, seed, parameters).
//
// There used to be a glow on cells where B was rising, to light the growing
// tips. Under stirring every leading edge is "rising", and it drew a ghost
// beside every moving shape, so it is gone.
//
// lerp-param: feed       float 0.01 0.1    = 0.0545  "Feed rate"
// lerp-param: kill       float 0.045 0.07  = 0.062   "Kill rate"
// lerp-param: seeds      int 1 32          = 8       "Seed colonies"
// lerp-param: speed      float 0 60        = 16      "Steps/sec"
// lerp-param: stir       float 0 0.12      = 0.075   "Stirring"
// lerp-param: relief     float 0 2         = 1       "Relief"
// lerp-param: colorBack  color             = #071019 "Background"
// lerp-param: colorBody  color             = #ef7457 "Body"
// lerp-param: colorGlow  color             = #ffd7b0 "Glow"
//
// The first preset equals the defaults, so the rotation names it rather than
// showing a separate "Defaults" tile.
//
// lerp-preset: Coral feed=0.0545, kill=0.062
// lerp-preset: Mitosis feed=0.0367, kill=0.0649, seeds=8, speed=20, stir=0.065
// lerp-preset: Mitosis colorBack=#04120f, colorBody=#4fc79f, colorGlow=#d9fff0
// lerp-preset: Fingerprint feed=0.037, kill=0.06, seeds=6, speed=14, stir=0.085
// lerp-preset: Fingerprint colorBack=#0b0a0f, colorBody=#d8c7a8, colorGlow=#ffb45e
// lerp-preset: Worms feed=0.078, kill=0.061, seeds=28, speed=30, stir=0.035
// lerp-preset: Worms colorBack=#0d0716, colorBody=#e9579b, colorGlow=#ffd77a

// Cubic B-spline of the grid at `g` (in cells, centres at i + 0.5), from four
// bilinear taps: each axis folds its four weights into two taps placed between
// texel pairs. Smooth to the second derivative, so the lighting is too.
static float2 rdTexel(texture2d<float> grid, float2 g, float2 dims) {
    float2 c = g - 0.5;
    float2 i = floor(c);
    float2 f = c - i;
    float2 f2 = f * f;
    float2 f3 = f2 * f;
    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    float2 w3 = f3 / 6.0;
    float2 s0 = w0 + w1;
    float2 s1 = w2 + w3;
    float2 p0 = (i - 0.5 + w1 / s0) / dims;
    float2 p1 = (i + 1.5 + w3 / s1) / dims;
    float2 t00 = grid.sample(lerpRDSampler, float2(p0.x, p0.y)).rg;
    float2 t10 = grid.sample(lerpRDSampler, float2(p1.x, p0.y)).rg;
    float2 t01 = grid.sample(lerpRDSampler, float2(p0.x, p1.y)).rg;
    float2 t11 = grid.sample(lerpRDSampler, float2(p1.x, p1.y)).rg;
    return s0.y * (s0.x * t00 + s1.x * t10) + s1.y * (s0.x * t01 + s1.x * t11);
}

// B at `g`, between the two uploaded steps, mapped to a 0..1 height.
static float rdHeight(texture2d<float> grid, float2 g, constant LerpRDFrame& F) {
    float2 b = rdTexel(grid, g, F.grid);
    return smoothstep(0.02, 0.36, mix(b.x, b.y, F.mix));
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpRDFrame& F [[buffer(1)]],
                        texture2d<float> grid [[texture(1)]]) {
    // Screen to grid with square cells sized by the short axis. The grid has
    // the drawable's aspect up to a 2.5:1 cap; past that the toroidal field
    // simply wraps (the sampler repeats) instead of stretching.
    float cellPx = min(u.resolution.x, u.resolution.y) / min(F.grid.x, F.grid.y);
    // The drift: RD_PAN cells a second, its heading turning once every
    // RD_TURN seconds from a seeded start, integrated in closed form.
    const float RD_PAN = 1.2, RD_TURN = 600.0;
    float w = TWO_PI / RD_TURN;
    float a0 = TWO_PI * u.seed;
    float a = a0 + w * u.time;
    float2 pan = (RD_PAN / w) * float2(sin(a) - sin(a0), cos(a0) - cos(a));
    float2 g = pos.xy / cellPx + pan;

    const float e = 0.7;
    float2 centre = rdTexel(grid, g, F.grid);
    float h = smoothstep(0.02, 0.36, mix(centre.x, centre.y, F.mix));
    float hx = rdHeight(grid, g + float2(e, 0.0), F) - rdHeight(grid, g - float2(e, 0.0), F);
    float hy = rdHeight(grid, g + float2(0.0, e), F) - rdHeight(grid, g - float2(0.0, e), F);
    float2 slope = float2(hx, hy) / (2.0 * e);

    // y runs down the screen, so a light from the upper left is (−x, −y).
    // Wrapped diffuse keeps the shadowed flanks soft, like wet tissue.
    float3 n = normalize(float3(-slope * (2.6 * u.relief), 1.0));
    // Swinging ±0.6 rad about that, once every 80 s.
    float az = atan2(-0.6, -0.45) + 0.6 * sin(TWO_PI * u.time / 80.0 + 5.0 * u.seed);
    float3 l = normalize(float3(0.75 * cos(az), 0.75 * sin(az), 0.66));
    float3 halfway = normalize(l + float3(0.0, 0.0, 1.0));
    float diffuse = saturate((dot(n, l) + 0.25) / 1.25);
    float spec = pow(max(0.0, dot(n, halfway)), 36.0);

    float body = smoothstep(0.28, 0.52, h);
    float fringe = smoothstep(0.0, 0.42, h) * (1.0 - body);
    float crest = smoothstep(0.72, 1.0, h);

    // A slow tonal drift across the colony, new every epoch: deeper and more
    // saturated in some reaches, paler toward the glow colour in others.
    float2 drift = g * 0.035 + float2(97.0 * u.seed, 13.0 * F.epoch);
    float tone = 0.65 * valueNoise(drift) + 0.35 * valueNoise(2.3 * drift + 5.0);
    float3 deep = pow(u.colorBody.rgb, float3(1.7));
    float3 pale = mix(u.colorBody.rgb, u.colorGlow.rgb, 0.3);
    float3 tissue = mix(deep, pale, smoothstep(0.2, 0.8, tone));

    float3 color = u.colorBack.rgb + 0.16 * fringe * u.colorGlow.rgb;
    float3 lit = tissue * (0.22 + 0.88 * diffuse);
    lit = mix(lit, u.colorGlow.rgb, 0.30 * crest * diffuse);
    color = mix(color, lit, body);
    color += (0.55 * u.relief) * spec * body * u.colorGlow.rgb;

    color = mix(u.colorBack.rgb, color, F.visibility);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
