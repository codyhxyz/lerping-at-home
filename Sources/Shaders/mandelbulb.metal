// Mandelbulb — original shader written for Lerping@Home (AGPL-3.0, like the
// rest of this project). A slow orbit around the White–Nylander Mandelbulb
// while its power breathes, so the surface keeps re-growing its buds.
//
// Written from the published mathematics; no code is copied from any article
// or Shadertoy:
//   - the spherical-coordinate power z -> z^n + c, with z^n taken as
//     r^n (sin nθ cos nφ, cos nθ, sin nθ sin nφ)    (Daniel White and Paul
//     Nylander, 2009)
//   - the distance estimate 0.5·r·ln r / |dz| with the running derivative
//     |dz| -> n·r^(n-1)·|dz| + 1 (Hart, Sandin and Kauffman, "Ray tracing
//     deterministic 3-D fractals", SIGGRAPH 1989), as explained in Inigo
//     Quilez's "Mandelbulb" article (https://iquilezles.org/articles/mandelbulb/)
//     and Mikael Hvidtfeldt Christensen's "Distance Estimated 3D Fractals (V):
//     The Mandelbulb" (http://blog.hvidtfeldts.net/)
//   - for the Julia bulb the constant c replaces the sample position and the
//     +1 drops out of the derivative
//   - over-relaxed sphere tracing with a fallback step (Keinert et al.,
//     "Enhanced Sphere Tracing", 2014)
//   - orbit-trap colouring (the orbit's closest approach to the origin)
//
// Breathing without a seam: a non-integer power taken literally cuts the bulb
// along the half-plane where atan2 wraps. Here only the polar exponent (θ,
// which acos keeps in [0, π]) and the radial one breathe; the azimuthal
// exponent m is the power rounded to an integer, so cos mφ, sin mφ are exact
// polynomials of (x, z)/ρ — no atan2, no seam, and cheaper. With breathing
// off and a whole-number power (the Classic preset) the polar part is a
// polynomial too, the trig-free form of the formula.
//
// Cost control, because this runs full-screen for hours:
//   - a bounding sphere fitted to the measured extent of the set per power;
//     rays that miss it cost almost nothing.
//   - four fractal iterations while marching: the set barely changes past
//     that at screen scale, and most samples escape in one or two anyway.
//   - the surface tolerance is a pixel cone, but no finer than a 900-px-tall
//     view's, and it widens with every step so grazing rays stop crawling.
//   - over-relaxed steps; shading reuses the hit sample (3 more taps for the
//     normal, 2 for the soft shadow).
//   (A 2x2-quad shared march like dusk-terrain's was tried and cost more:
//   rays converge on the bulb head-on, so speculative strides rarely land.)
// GPU cost, LerpPreview --bench --looks at 3840x2160, Apple M5, mean ms per
// frame (same run: fractal-multiverse 8.5, paper-texture 12.5): defaults
// 9.0, Classic 7.0, Organic 9.5, Julia Bulb 10.0, Surface Flight 12.3.
//
// lerp-param: power    float 2 12  = 8.0  "Power"
// lerp-param: breathe  float 0 3   = 2.0  "Power breathing"
// lerp-param: speed    float 0 3   = 1.0  "Speed"
// lerp-param: distance float 0 1   = 0.65 "Camera distance"
// lerp-param: julia    float 0 1   = 0.0  "Julia"
// lerp-param: palette  float 0 1   = 0.0  "Palette"
// lerp-param: glow     float 0 1   = 0.5  "Glow"
//
// lerp-preset: Classic   breathe=0.0, distance=0.7, palette=0.5, glow=0.6
// lerp-preset: Organic   power=4.0, breathe=0.5, distance=0.72, palette=1.0, glow=0.8
// lerp-preset: "Surface Flight" distance=0.0, breathe=1.0, palette=0.1, glow=0.6
// lerp-preset: "Julia Bulb" julia=1.0, breathe=1.0, distance=0.6, palette=0.75

constant int   MB_ITERS   = 4;      // fractal iterations per distance estimate
constant int   MB_STEPS   = 44;     // march steps per pixel
constant float MB_BAIL    = 4.0;    // escape radius
constant float MB_FOCAL   = 1.9;    // ~55 degree vertical field of view
constant float MB_REF_PX  = 900.0;  // finest surface tolerance: a view this many px tall

struct MbBulb {
    float n;        // radial / polar exponent (breathes)
    int   m;        // azimuthal exponent (integer)
    bool  whole;    // n == m: the polar part is a polynomial too
    float3 c;       // Julia constant
    float jul;      // 0 Mandelbulb … 1 Julia bulb
};

// The unit complex number b = (cos a, sin a) raised to an integer power
// m in 1…15, i.e. (cos ma, sin ma), by binary exponentiation.
static inline float2 mbCPow(float2 b, int m) {
    float2 w = float2(1.0, 0.0);
    for (int k = 0; k < 4; k++) {
        if ((m >> k) & 1) w = float2(w.x * b.x - w.y * b.y, w.x * b.y + w.y * b.x);
        b = float2(b.x * b.x - b.y * b.y, 2.0 * b.x * b.y);
    }
    return w;
}

// Distance estimate at p, with the orbit trap (min |x|, |y|, |z|, |z|^2).
static inline float mbDE(float3 p, MbBulb B, thread float4& trap) {
    float3 z = p;
    float dr = 1.0;
    float r2 = dot(z, z);
    trap = float4(abs(z), r2);
    float3 cc = mix(p, B.c, B.jul);
    float plus = 1.0 - B.jul;
    for (int i = 0; i < MB_ITERS; i++) {
        if (r2 > MB_BAIL * MB_BAIL) break;
        float ir = rsqrt(r2);
        float r = r2 * ir;
        float rho2 = max(z.x * z.x + z.z * z.z, 1e-14);
        float irho = rsqrt(rho2);
        float2 az = mbCPow(float2(z.x, z.z) * irho, B.m);     // (cos mφ, sin mφ)
        float cth, sth;
        if (B.whole) {
            float2 pz = mbCPow(float2(z.y, rho2 * irho) * ir, B.m);  // (cos nθ, sin nθ)
            cth = pz.x; sth = pz.y;
        } else {
            sth = sincos(B.n * acos(clamp(z.y * ir, -1.0, 1.0)), cth);
        }
        float rn1 = exp2((B.n - 1.0) * log2(r));               // r^(n-1)
        dr = B.n * rn1 * dr + plus;
        z = (rn1 * r) * float3(sth * az.x, cth, sth * az.y) + cc;
        r2 = dot(z, z);
        trap = min(trap, float4(abs(z), r2));
    }
    float r = sqrt(r2);
    return 0.5 * log(r) * r / dr;
}

static inline float mbMap(float3 p, MbBulb B) { float4 t; return mbDE(p, B, t); }

// Ray / sphere: entry and exit distances, or (-1, -1) for a miss.
static inline float2 mbSphere(float3 ro, float3 rd, float rad) {
    float b = dot(ro, rd);
    float c = dot(ro, ro) - rad * rad;
    float h = b * b - c;
    if (h < 0.0) return float2(-1.0);
    h = sqrt(h);
    return float2(-b - h, -b + h);
}

// Surface colour for an orbit-trap value k in [0, 1] — folds, body, bud tips —
// and the glow colour. `sel` slides Bronze (0) → Ice (0.5) → Orchid (1).
static inline float3 mbSurface(float k, float sel, thread float3& glow) {
    const float3 lo[3]  = { float3(0.30, 0.11, 0.05), float3(0.08, 0.20, 0.34), float3(0.26, 0.07, 0.30) };
    const float3 mid[3] = { float3(0.76, 0.52, 0.32), float3(0.52, 0.66, 0.78), float3(0.68, 0.44, 0.76) };
    const float3 hi[3]  = { float3(0.93, 0.78, 0.55), float3(0.74, 0.88, 0.97), float3(0.95, 0.74, 0.86) };
    const float3 gl[3]  = { float3(1.00, 0.42, 0.10), float3(0.18, 0.58, 1.00), float3(0.86, 0.24, 0.96) };
    float x = clamp(sel, 0.0, 1.0) * 2.0;
    int i = min(int(x), 1);
    float w = x - float(i);
    float3 l = mix(lo[i], lo[i + 1], w), m = mix(mid[i], mid[i + 1], w), h = mix(hi[i], hi[i + 1], w);
    glow = mix(gl[i], gl[i + 1], w);
    k = clamp(k, 0.0, 1.0);
    return k < 0.5 ? mix(l, m, smoothstep(0.0, 0.5, k)) : mix(m, h, smoothstep(0.5, 1.0, k));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float T = u.speed * u.time + u.seed * 400.0;

    // --- The bulb. The power breathes slowly about its set value.
    MbBulb B;
    B.n = max(u.power + u.breathe * sin(0.021 * T + u.seed * 6.2831), 1.5);
    B.m = clamp(int(u.power + 0.5), 2, 15);
    B.jul = u.julia;
    B.whole = u.breathe == 0.0 && fract(u.power) == 0.0;
    if (B.whole) B.n = float(B.m);
    // The Julia constant wanders slowly over a sphere of radius ~1, where
    // the set breaks into cages and rings of buds rather than a solid ball.
    float ca = 0.011 * T + u.seed * 17.0;
    float cb = 0.45 * sin(0.0077 * T + u.seed * 23.0);
    B.c = (1.0 + 0.06 * sin(0.013 * T)) * float3(cos(ca) * cos(cb), sin(cb), sin(ca) * cos(cb));
    // Bounding sphere: measured extents of the 4-iteration set (1.10 at
    // power 8, 1.24 at 4, 1.54 at 2.5) plus a margin for the glow.
    float bound = mix(1.0 + 1.5 / max(u.power - u.breathe, 1.5), 1.5, B.jul);

    // --- Camera: a slow orbit that drifts in and out. Close in, it turns to
    // skim the surface along its path, with the bulb's limb as a horizon.
    float az = 0.035 * T + u.seed * TWO_PI;
    float el = 0.45 * sin(0.019 * T + u.seed * 11.0);
    float dist = mix(bound + 0.26, bound + 2.0, u.distance) * (1.0 + 0.05 * sin(0.027 * T));
    float3 radial = float3(cos(el) * cos(az), sin(el), cos(el) * sin(az));
    float3 tangent = float3(-sin(az), 0.0, cos(az));
    float3 ro = dist * radial;
    float skim = 1.0 - smoothstep(0.0, 0.35, u.distance);
    float3 fwd = normalize(mix(-radial, normalize(tangent - 0.9 * radial), skim));
    float3 upHint = normalize(mix(float3(0.0, 1.0, 0.0), radial, skim));
    float3 right = normalize(cross(upHint, fwd));
    float3 up = cross(fwd, right);
    float3 rd = normalize(uv.x * right + uv.y * up + MB_FOCAL * fwd);

    float3 glowCol;
    mbSurface(0.0, u.palette, glowCol);
    float3 bg = mix(float3(0.003, 0.004, 0.008), float3(0.012, 0.012, 0.024), 0.5 + 0.5 * uv.y);
    bg += glowCol * 0.012 * exp(-2.0 * dot(uv, uv));   // faint light behind the bulb
    float3 col = bg;

    // Surface tolerance: a pixel cone, but never finer than a MB_REF_PX-tall
    // view's, so a 5K frame does not march deeper than a small one.
    float px = 1.6 / (MB_FOCAL * min(min(u.resolution.x, u.resolution.y), MB_REF_PX));
    float2 bs = mbSphere(ro, rd, bound);
    if (bs.y > 0.0) {
        float t = max(bs.x, 0.0);
        float tEnd = bs.y;
        bool hit = false;
        int steps = 0;
        float glowAcc = 0.0;
        float d = 1.0;
        float4 trap = float4(1.0);
        float w = 1.3, stepLen = 0.0, prevD = 0.0;
        for (int i = 0; i < MB_STEPS; i++) {
            d = mbDE(ro + rd * t, B, trap);
            if (w > 1.0 && d + prevD < stepLen) {
                // The relaxed step overshot: back up to the plain step.
                t += prevD - stepLen;
                stepLen = prevD;
                w = 1.0;
                continue;
            }
            glowAcc += 1.0 / (1.0 + 4000.0 * d * d);
            // The tolerance widens a little with every step, so rays that
            // graze a silhouette give up instead of crawling along it.
            if (d < px * t * (1.0 + 0.10 * float(i))) { hit = true; break; }
            stepLen = d * w;
            prevD = d;
            t += stepLen;
            steps = i + 1;
            if (t > tEnd) break;
        }
        if (hit) {
            float3 p = ro + rd * t;
            // Forward differences off the hit sample's own distance; the
            // trap is that sample's too.
            float e = max(px * t * 0.5, 1e-4);
            float3 nor = normalize(float3(mbMap(p + float3(e, 0.0, 0.0), B),
                                          mbMap(p + float3(0.0, e, 0.0), B),
                                          mbMap(p + float3(0.0, 0.0, e), B)) - d);

            // Orbit-trap colouring: how close the orbit came to the origin
            // picks the colour; buds (orbits that stay out) read lighter.
            float tr = clamp(trap.w, 0.0, 1.0);
            float3 g;
            float3 alb = mbSurface(0.15 + 0.7 * sqrt(tr) + 0.25 * trap.x, u.palette, g);
            alb *= alb;                                             // to linear

            // Occlusion: orbits that sink deep are in folds, and so are hits
            // that took many steps to reach.
            float occ = clamp(0.3 + 0.9 * sqrt(tr), 0.0, 1.0) * clamp(1.15 - float(steps) / 40.0, 0.2, 1.0);
            float3 L = normalize(right * -0.55 + up * 0.75 - fwd * 0.45);
            float dif = max(dot(nor, L), 0.0);
            // Soft shadow from two taps toward the light: how much of each
            // tap's free radius the surface leaves open.
            float sh = 1.0;
            if (dif > 0.0) {
                float3 q = p + nor * e * 2.0;
                sh = min(sh, mbMap(q + L * 0.05, B) / 0.05);
                sh = min(sh, mbMap(q + L * 0.20, B) / 0.20);
                sh = smoothstep(0.0, 1.0, clamp(sh * 1.4, 0.0, 1.0));
            }
            float fre = clamp(1.0 + dot(rd, nor), 0.0, 1.0);
            float3 H = normalize(L - rd);
            float spe = pow(clamp(dot(nor, H), 0.0, 1.0), 28.0) * dif * sh;
            float sky = 0.5 + 0.5 * dot(nor, up);
            float3 lin = float3(1.00, 0.86, 0.70) * 2.2 * dif * sh
                       + float3(0.16, 0.20, 0.32) * 0.55 * sky * occ
                       + glowCol * 0.35 * clamp(dot(nor, -L), 0.0, 1.0) * occ;   // coloured bounce
            col = alb * lin + float3(1.0, 0.9, 0.8) * 0.25 * spe * (0.3 + 0.7 * tr);
            // Subsurface-ish glow: light seems to well up from inside the
            // folds and leak through grazing edges.
            col += glowCol * u.glow * (0.30 * pow(1.0 - occ, 2.0) + 0.22 * pow(fre, 3.0) * occ);
            // Depth fog from the near side of the bulb backwards.
            float fog = 1.0 - exp(-0.55 * max(t - (length(ro) - 1.0), 0.0));
            col = mix(col, bg, fog);
        }
        col += glowCol * glowAcc * 0.0012 * u.glow;
    }

    col = 1.0 - exp(-1.2 * col);
    col = sqrt(max(col, 0.0));
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
