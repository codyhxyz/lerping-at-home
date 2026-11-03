// Curl Flow — original shader written for Lerping@Home (AGPL-3.0, this repo).
// Technique: Robert Bridson, Jim Hourihan, Marcus Nordenstam, "Curl-Noise for
// Procedural Fluid Flow", ACM SIGGRAPH 2007. In 2D the velocity is the curl
// of a scalar potential, v = (dpsi/dy, -dpsi/dx), which is divergence-free by
// construction: nothing piles up and nothing drains away, so the motion reads
// as an incompressible fluid. The look takes its cue from Tyler Hobbs' essay
// "Flow Fields" (tylerxhobbs.com, 2020): many thin, non-crossing coloured
// curves following one field. Inspiration only; no code from either source.
//
// The potential psi is the prelude's `snoise`, drifting slowly, plus a linear
// term (`current`) that adds a uniform stream so eddies open into lanes.
// `cfNoiseD` below evaluates that same simplex lattice and returns its exact
// analytic gradient alongside the value, so the curl costs one noise
// evaluation instead of three finite-difference ones.
//
// Two layers, both pure functions of (time, seed, parameters):
//
// - Threads. A divergence-free 2D field's streamlines are exactly the level
//   sets of its potential (v . grad psi = 0), so the flow lines are drawn as
//   isolines of psi, with no integration at all. Line spacing is
//   1 / (density * |grad psi|), so lines crowd where the flow runs fast —
//   equal flux between neighbours, as in a real stream-tube diagram — and
//   every other line fades out where they would merge.
// - Particles with finite lifetimes. Spawn sites sit on a jittered grid and
//   each emits one particle per period, re-placed every period from
//   (seed, cell, epoch). A pixel traces its own streamline upstream for
//   CF_STEPS Euler steps (the lifetime), each pulled back onto the pixel's
//   level of psi so long steps cannot wander off the thread. If that path
//   passes a site whose current particle is `age` steps old and the site
//   lies k steps upstream, the particle passed this pixel (age - k) steps
//   ago. That one number places the comet's head and tail, so nothing is
//   accumulated across frames and any t renders in the same fixed work.
//
// Cost: CF_STEPS noise evaluations per pixel; `particles` = 0 skips the trace
// and leaves the threads, at one evaluation.
//
// lerp-param: colorBack     color          = (0.016, 0.020, 0.042) "Background"
// lerp-param: color1        color          = (0.180, 0.620, 0.700) "Teal"
// lerp-param: color2        color          = (0.420, 0.360, 0.820) "Iris"
// lerp-param: color3        color          = (0.900, 0.600, 0.330) "Amber"
// lerp-param: color4        color          = (0.860, 0.330, 0.480) "Rose"
// lerp-param: scale         float 0.3 3    = 1.1  "Scale"
// lerp-param: speed         float 0 3      = 1.0  "Speed"
// lerp-param: evolve        float 0 1      = 0.3  "Field drift"
// lerp-param: current       float 0 1      = 0.65 "Current"
// lerp-param: streakLength  float 0.05 1   = 0.8  "Streak length"
// lerp-param: particles     float 0 1      = 0.85 "Particles"
// lerp-param: lineDensity   float 0 30     = 9    "Line density"
// lerp-param: lineWidth     float 0.3 4    = 1.0  "Line width"
// lerp-param: lineOpacity   float 0 1      = 0.5  "Line opacity"
//
// lerp-preset: Ember     colorBack=(0.020, 0.008, 0.006), color1=(0.95, 0.42, 0.12)
// lerp-preset: Ember     color2=(0.98, 0.72, 0.30), color3=(0.70, 0.12, 0.10), color4=(1.0, 0.86, 0.62)
// lerp-preset: Ember     speed=1.4, streakLength=0.9, particles=1, lineDensity=6, lineOpacity=0.32
// lerp-preset: Ink       colorBack=(0.840, 0.805, 0.730), color1=(0.12, 0.20, 0.32)
// lerp-preset: Ink       color2=(0.70, 0.22, 0.16), color3=(0.18, 0.40, 0.36), color4=(0.83, 0.58, 0.20)
// lerp-preset: Ink       scale=0.8, lineDensity=14, lineWidth=1.4, lineOpacity=0.75, particles=0.6
// lerp-preset: Silk      colorBack=(0.012, 0.010, 0.022), color1=(0.78, 0.80, 0.92), color2=(0.55, 0.62, 0.86)
// lerp-preset: Silk      color3=(0.92, 0.84, 0.94), color4=(0.62, 0.74, 0.82)
// lerp-preset: Silk      scale=0.7, evolve=0.2, lineDensity=22, lineWidth=0.8, lineOpacity=0.22
// lerp-preset: Silk      particles=0.9, streakLength=1.0, speed=0.7

constant int   CF_STEPS   = 5;       // particle lifetime == upstream trace length
constant float CF_RATE    = 0.67;    // trace steps per second at speed 1
constant float CF_H       = 0.036;   // UV per step per unit velocity
constant float CF_MAXSTEP = 0.07;    // cap on one step, UV
constant float CF_CELL    = 0.22;    // spawn-site grid, UV
constant float CF_RADIUS  = 0.0075;  // particle core radius, UV
constant float CF_GLOW    = 2.0;     // halo reach, multiples of the radius
// Sites keep clear of their cell's edge by a half step plus the halo's reach
// (up to 2x, see `stretch`), so the one cell looked up per segment (its
// midpoint's) is the only one that segment can reach.
constant float CF_MARGIN  = 0.5 * CF_MAXSTEP + 2.0 * CF_GLOW * CF_RADIUS;

// Value and analytic gradient of the prelude's `snoise`: the same lattice,
// permutation, gradients and normalisation, returned as (value, d/dx, d/dy).
// Each corner contributes n * m^4 * (g . x) with m = max(0.5 - |x|^2, 0), so
// its gradient is n * (m^4 g - 8 m^3 (g . x) x).
static float3 cfNoiseD(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
                            -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = glmod2(i, 289.0);
    float3 p = lerpPermute(lerpPermute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 a0 = x - floor(x + 0.5);
    float3 n = 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);

    float2 c0 = x0, c1 = x12.xy, c2 = x12.zw;
    float3 m = max(0.5 - float3(dot(c0, c0), dot(c1, c1), dot(c2, c2)), 0.0);
    float3 m2 = m * m;
    float3 m3 = m2 * m;
    float3 m4 = m2 * m2;
    float2 g0 = float2(a0.x, h.x), g1 = float2(a0.y, h.y), g2 = float2(a0.z, h.z);
    float3 gx = float3(dot(g0, c0), dot(g1, c1), dot(g2, c2));

    float value = dot(n * m4, gx);
    float2 grad = n.x * (m4.x * g0 - 8.0 * m3.x * gx.x * c0)
                + n.y * (m4.y * g1 - 8.0 * m3.y * gx.y * c1)
                + n.z * (m4.z * g2 - 8.0 * m3.z * gx.z * c2);
    return 130.0 * float3(value, grad);
}

struct CFFrame {
    float  scale;
    float2 drift;
    float2 current;   // gradient of the linear (uniform-flow) part of psi
};

// psi and its gradient with respect to p = uv * scale. Steps use that
// gradient as a UV velocity, so a step's length does not change with `scale`.
// A linear term c . p added to the potential is a uniform current at right
// angles to c; it opens the eddies' closed loops into meandering lanes.
static float3 cfField(float2 uv, thread const CFFrame& F) {
    float2 p = uv * F.scale;
    float3 n = cfNoiseD(p + F.drift);
    return float3(n.x + dot(F.current, p), n.yz + F.current);
}

static float3 cfPalette(float hsel, constant LerpUniforms& u) {
    int idx = min(int(hsel * 4.0), 3);
    return idx == 0 ? u.color1.rgb : idx == 1 ? u.color2.rgb : idx == 2 ? u.color3.rgb : u.color4.rgb;
}

struct CFComets {
    float3 rgb;
    float  weight;
};

// One polyline segment A->B of the upstream trace, `m` steps from the pixel.
// nA and nB are the planes at its joints: each is the bisector of the two
// segments meeting there and is shared with the neighbour, so every site is
// owned by exactly one segment, and the time-of-flight m + t and the distance
// d to the trace both agree across the joint (a bisector is equidistant from
// both lines). That is what keeps a comet in one piece on a bend.
static void cfSegment(float2 A, float2 B, float2 nA, float2 nB, float m,
                      float slA, float slB, float sl0,
                      float T, float tail, float2 seedOff,
                      constant LerpUniforms& u, thread CFComets& acc) {
    const float range = CF_CELL - 2.0 * CF_MARGIN;
    float2 cell = floor(0.5 * (A + B) / CF_CELL);
    float2 hc = hash22(cell + seedOff);
    float period = float(CF_STEPS) * (1.2 + 1.3 * hc.x);
    float phase = T / period + hc.y;
    float epoch = floor(phase);
    float age = (phase - epoch) * period;                // steps since emission
    float2 ce = cell + float2(0.618, 0.371) * epoch;
    // Most segments meet no live particle; bail before the shading. Nearby
    // pixels trace nearby paths, so this branch is coherent across a SIMD group.
    if (age >= float(CF_STEPS) || hash21(ce * 1.31 + seedOff + 5.0) >= u.particles) return;
    float2 site = cell * CF_CELL + CF_MARGIN + range * hash22(ce + 19.0);

    float a = dot(site - A, nA);
    float b = dot(B - site, nB);
    float2 e = B - A;
    float sl = max(length(e), 1e-6);
    float2 rel = site - A;
    // Owned by this segment, and within reach of its trace (the 4x covers the
    // `stretch` clamp's 2x plus the Hermite bend below).
    if (a < 0.0 || b <= 0.0 || abs(rel.x * e.y - rel.y * e.x) > 4.0 * CF_GLOW * CF_RADIUS * sl) return;
    float t = a / max(a + b, 1e-7);
    // Measured in this pixel's metric. The flow is incompressible, so the gap
    // between neighbouring streamlines scales as 1 / speed and a particle
    // spreads wide wherever the water slows. Scaling by the speed ratio
    // (step length here over step length at the pixel) keeps comets one
    // width everywhere instead of fanning into wedges. It is interpolated
    // between the segment's two ends so it, too, agrees across each joint.
    float stretch = clamp(mix(slA, slB, t) / max(sl0, 1e-6), 0.5, 3.0);
    // Distance to the trace, not to its chord: the bisectors are the curve's
    // tangents at the joints, so a cubic Hermite through A and B bends the
    // chord by h(t) and the comet stops showing a kink once per step.
    float2 eh = e / sl;
    float c = eh.x * rel.y - eh.y * rel.x;              // signed offset from chord
    float aA = eh.x * nA.y - eh.y * nA.x;               // tangent angles vs chord
    float aB = eh.x * nB.y - eh.y * nB.x;
    float hh = sl * (aA * t * (1.0 - t) * (1.0 - t) - aB * t * t * (1.0 - t));
    float d = abs(c - hh) * stretch;

    // The particle left `site` `age` steps ago; the site is m + t steps
    // upstream of this pixel, so the head passed here `j` steps ago.
    float j = age - (m + t);
    float jUV = j * sl0;                                  // distance behind the head
    // A comet: round head at j = 0, a tail that thins and fades by `tail`.
    float along = clamp(j / tail, 0.0, 1.0);
    // ...and tapers in at the spawn site rather than starting square.
    float trail = (1.0 - along) * (1.0 - along) * step(-1.0, j) * smoothstep(0.0, 0.8, m + t);
    float r = CF_RADIUS * (1.0 - 0.55 * along);
    float dc = length(float2(d, min(jUV, 0.0)));
    float life = smoothstep(0.0, 0.6, age) * (1.0 - smoothstep(float(CF_STEPS) - 1.5, float(CF_STEPS), age));
    float core = 1.0 - smoothstep(0.3 * r, r, dc);
    float halo = 0.22 * (1.0 - smoothstep(0.0, CF_GLOW * CF_RADIUS, dc));
    float w = trail * life * (core + halo);
    float head = 1.0 - smoothstep(0.0, 3.0 * CF_RADIUS, abs(jUV));

    float3 col = cfPalette(hash21(ce * 0.73 + seedOff + 3.0), u);
    // A hot white head on a dark ground; on a light one it would only wash out.
    float darkBack = 1.0 - dot(u.colorBack.rgb, float3(0.299, 0.587, 0.114));
    col = mix(col, float3(1.0), 0.45 * head * core * darkBack);
    acc.rgb += col * w;
    acc.weight += w;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float minRes = min(u.resolution.x, u.resolution.y);
    float pxPerUV = 0.5 * minRes;
    float2 uv = lerpUV(pos, u.resolution);

    CFFrame F;
    F.scale = u.scale;
    F.drift = float2(0.031, 0.019) * (u.evolve * u.time) + float2(37.0, 11.0) * u.seed;
    F.current = 3.0 * u.current * float2(cos(0.3), sin(0.3));
    float2 seedOff = float2(91.7, 23.3) * u.seed;
    uv = rotate(uv, TWO_PI * u.seed);

    // Clock in trace steps. Ages are computed per site from this alone.
    float T = u.time * u.speed * CF_RATE + 977.0 * u.seed;
    float tail = max(0.25, u.streakLength * float(CF_STEPS));

    float3 psiHere = float3(0.0);
    CFComets acc = { float3(0.0), 0.0 };

    // Vertices X_0 (the pixel) .. X_STEPS of the upstream trace. Segment
    // X_{k-1} -> X_k is drawn once X_k is final and the direction leaving it
    // is known, because the joint's bisector plane needs both.
    // With particles off only X_0 is needed (for the threads), so the trace
    // and all its noise evaluations are skipped.
    bool comets = u.particles > 0.0;
    int steps = comets ? CF_STEPS : 1;
    float2 x = uv;
    float2 xPrev = uv;
    float2 nPrev = float2(0.0);
    float sl0 = 1.0;                  // step length at the pixel itself
    float slPrev = 1.0;               // step length leaving xPrev
    for (int k = 0; k < steps; k++) {
        float3 f = cfField(x, F);
        if (k == 0) {
            psiHere = f;
        } else {
            // Streamlines are level sets of psi, so pull the predicted point
            // back onto this pixel's level (one Newton step, same evaluation).
            // Long Euler steps then stay on the pixel's own thread.
            float g2 = max(dot(f.yz, f.yz), 1e-6);
            float2 dx = -(f.x - psiHere.x) / (F.scale * g2) * f.yz;
            float dl = length(dx);
            if (dl > 0.5 * CF_MAXSTEP) dx *= 0.5 * CF_MAXSTEP / dl;
            x += dx;
        }

        // Bridson's 2D curl; step upstream, against the flow.
        float2 v = float2(f.z, -f.y);
        float2 s = -v * CF_H;
        float sl = length(s);
        if (sl > CF_MAXSTEP) { s *= CF_MAXSTEP / sl; sl = CF_MAXSTEP; }
        float2 dirOut = s / max(sl, 1e-7);

        if (k == 0) {
            nPrev = dirOut;
            sl0 = sl;
        } else {
            float2 dirIn = normalize(x - xPrev + 1e-7);
            float2 n = normalize(dirIn + dirOut + 1e-7);
            cfSegment(xPrev, x, nPrev, n, float(k - 1), slPrev, sl, sl0,
                      T, tail, seedOff, u, acc);
            nPrev = n;
        }
        slPrev = sl;
        xPrev = x;
        x += s;
    }
    // The last segment ends the particle's life; its far plane is square.
    if (comets) {
        cfSegment(xPrev, x, nPrev, normalize(x - xPrev + 1e-7), float(CF_STEPS - 1),
                  slPrev, slPrev, sl0, T, tail, seedOff, u, acc);
    }

    // Threads: isolines of psi, which are this field's streamlines.
    float3 color = u.colorBack.rgb;
    float gradUV = max(length(psiHere.yz) * F.scale, 1e-4);
    float N = max(u.lineDensity, 0.0) / F.scale;
    if (N > 0.0) {
        float level = psiHere.x * N + 0.5;
        float id = floor(level);
        float dPx = abs(fract(level) - 0.5) / (N * gradUV) * pxPerUV;
        float spacingPx = pxPerUV / (N * gradUV);
        float halfW = max(0.5, 0.55 * u.lineWidth * minRes / 1080.0);
        // Every other line drops out where neighbours would merge; the
        // survivors are twice as far apart, and fade only if even that crowds.
        bool odd = glmod(id, 2.0) > 0.5;
        float keep = odd ? smoothstep(3.0, 6.0, spacingPx / halfW)
                         : smoothstep(1.5, 3.0, spacingPx / halfW);
        float line = (1.0 - smoothstep(halfW - 0.75, halfW + 0.75, dPx)) * keep;
        float hl = hash11(id * 0.137 + 31.0 * u.seed);
        float3 lc = cfPalette(fract(hl * 7.31), u);
        // Faster water reads brighter, which is what makes it look like silk.
        float sheen = 0.55 + 0.45 * smoothstep(0.3, 2.5, length(psiHere.yz));
        float op = u.lineOpacity * (0.55 + 0.45 * hl) * sheen;
        color = mix(color, lc, line * op);
    }

    if (acc.weight > 1e-5) {
        float3 cc = acc.rgb / acc.weight;
        // Near a stagnation point neighbouring streamlines fan apart and a
        // finite particle smears into a wedge; let comets fade out there.
        float moving = smoothstep(0.15, 0.6, length(psiHere.yz));
        float alpha = (1.0 - exp(-2.2 * acc.weight)) * moving;
        color = mix(color, cc, alpha);
    }

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
