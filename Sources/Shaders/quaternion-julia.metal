// Quaternion Julia — original shader written for Lerping@Home (AGPL-3.0, like
// the rest of this project). A 3D slice through a 4D quaternion Julia set,
// raymarched. The Julia constant c travels a slow closed loop through 4D while
// the slice hyperplane tilts in and out of the fourth dimension, so the object
// keeps folding into new shapes without ever repeating a cut.
//
// Written from the published mathematics; no code is copied from any article
// or Shadertoy:
//   - the unbounded-distance estimator d = |q| log|q| / (2 |q'|) for the
//     iteration q <- q^n + c, from J. C. Hart, D. J. Sandin and L. H.
//     Kauffman, "Ray tracing deterministic 3-D fractals", SIGGRAPH 1989,
//     with |q'| carried as a running scalar (|q'| <- n |q|^(n-1) |q'|)
//   - slicing the 4D set with a moving hyperplane and morphing c, as
//     explained in Inigo Quilez's "3D Julia sets" article
//     (https://iquilezles.org/articles/juliasets3d/)
//   - penumbra soft shadows from the closest miss along the shadow ray, and
//     distance-field ambient occlusion probed along the normal
//   - cosine colour palettes a + b·cos(2π(c·t + d)) and orbit traps
//
// Why the plain q^n + c looks like turned clay: squaring keeps a quaternion's
// imaginary direction (q^2 = (a^2 - |v|^2, 2a v)), so the set is a complex
// Julia set spun about the real axis, and every slice of it is a lathe-turned
// swirl. Detail beyond that needs something to break the spin. `twist` does:
// the iteration becomes q <- q^n r + c for a unit quaternion r turned `twist`
// radians about c's own imaginary direction. That is still the Julia set of a
// quaternion polynomial (with a non-real coefficient), its escape radius and
// derivative bound are unchanged (|q^n r| = |q|^n), and it folds the spun
// layers into blades, fins and frills. twist = 0 is the classic set.
//
// The c values were picked from contact sheets of many (cReal, cImag) pairs
// for each twist, choosing points just inside the boundary of the twisted
// set's connectedness locus (where the critical orbit stays bounded): deep
// inside, the set is a smooth blob; outside, it shatters into dust. The loop c
// travels is kept small (±0.04, ±0.03) so it stays in that band.
//
// Surface detail comes from three budgets the previous version had capped:
// 12 iterations for q^2 (9 for q^3) instead of 9 (6); a hit tolerance of two
// pixels' footprint at the real drawable size rather than at a 1200-px-tall
// view's (which at 4K was 3.6 px); and normals from a tetrahedron half a
// pixel's footprint across. Shading reads that detail back out: cavity from
// a few-pixel AO tap darkens creases and pores, the pixel-scale Laplacian of
// the estimate (free from the normal's taps) widens the highlight where the
// relief is finer than a pixel (so it does not sparkle), veins are anti-
// aliased contour lines of the real-axis orbit trap, and the material blends
// from a glaze (white specular, Fresnel, studio reflection) toward metal.
//
// Looks:
//   - power 2 (q^2 r + c) or 3 (q^3 r + c)
//   - cut > 0: a plane facing the camera removes the near part of the object;
//     the cut face is coloured by what the orbit does there (interior
//     colouring), so the inside of the set shows its own structure
//   - glass > 0: fresnel reflection of a dark studio, plus a backlight seen
//     through the body, absorbed over a thickness measured with a few
//     inside/outside probes along the refracted ray and tinted by the
//     orbit trap
//
// Parameters added in this revision: lean (was a baked 0.75), twist, metal,
// veins. cReal's range widened to -1.2..0.5. The "Turned" preset (a classic
// lathe-turned slice) was replaced by "Bronze".
//
// Seed: sets the phases of c's loop and of the slice tilt (a different path
// through the same family of shapes) and the camera's orbit angle and height.
//
// Cost control, because this runs full-screen for hours: the march only runs
// inside the set's bounding sphere, whose radius follows from |c|; power and
// twist are template parameters, so no inner loop branches on them (a uniform
// per-iteration test cost ~40% of the frame on an M5); the twist is an 8-flop
// product because the frame is turned so its axis is i; sphere-tracing steps
// are lengthened by 1.2, which the conservative scalar |q'| bound absorbs;
// iterations, march steps, shadow steps, AO taps and glass probes are fixed
// budgets. Tried and dropped: over-relaxed sphere tracing (rejected steps ate
// the gain), fewer iterations while far from the set (far points escape early
// anyway), and a second, coarser normal for curvature (the AO tap does it).
// LerpPreview --bench at 3840x2160 on an Apple M5, mean ms with
// fractal-multiverse at 8.5–9.5 in the same runs, at the bench moment / 60 s /
// 150 s later: default 12.2 / 10.7 / 9.5, Cubic 7.2 / 7.4 / 7.0, Intersected
// 12.5 / 11.6 / 8.2, Glass 11.7 / 11.6 / 10.3, Bronze 13.4 / 12.8 / 11.8.
// (The previous version: default 9.9, Cubic 5.9, Intersected 8.1, Glass
// 10.9, Turned 8.8.)
//
// lerp-param: speed  float 0 2       = 0.5   "Speed"
// lerp-param: power  int   2 3       = 2     "Power"
// lerp-param: cReal  float -1.2 0.5  = -0.48 "c real centre"
// lerp-param: cImag  float 0 1.2     = 0.64  "c imaginary centre"
// lerp-param: lean   float 0 1.57    = 0.4   "c lean into 4D"
// lerp-param: twist  float 0 1.6     = 1.0   "Twist"
// lerp-param: morph  float 0 1       = 0.5   "Morph"
// lerp-param: slice  float 0 1       = 0.5   "4D slice tilt"
// lerp-animate: slice 0.35 0.65 period=240
// lerp-param: cut    float 0 1       = 0.0   "Cut"
// lerp-param: glass  float 0 1       = 0.0   "Glass"
// lerp-param: metal  float 0 1       = 0.0   "Metal"
// lerp-param: veins  float 0 1       = 0.6   "Veins"
// lerp-param: hue    float 0 1       = 0.0   "Palette"
// lerp-param: zoom   float 0.6 1.6   = 0.95  "Zoom"
// lerp-param: colorBack color        = (0.012, 0.014, 0.024) "Background"
//
// lerp-preset: Cubic        power=3, twist=0.5, cReal=-0.25, cImag=0.71, hue=0.5
// lerp-preset: Intersected  cReal=-0.69, cImag=0.27, cut=0.5, hue=1.0, zoom=1.1, slice=animate(0.25, 0.45, period=240)
// lerp-preset: Glass        glass=1.0, twist=0.5, cReal=-0.76, cImag=0.09, hue=0.88, zoom=1.15
// lerp-preset: Bronze       cReal=-0.72, cImag=0.08, metal=0.8, veins=0.3, zoom=1.15

#define QJ_ITERS2 12            // orbit iterations per estimate, q^2 r + c
#define QJ_ITERS3 9             // ... q^3 r + c (its orbits escape faster)
constant float QJ_BAIL    = 16.0;   // |q|^2 escape threshold
constant int   QJ_STEPS   = 100;    // march budget
constant float QJ_RELAX   = 1.2;    // sphere-tracing step multiplier
constant float QJ_HIT_PX  = 2.0;    // hit tolerance, in pixel footprints
constant float QJ_MISS_PX = 6.0;    // a ray out of steps this close counts as a hit
constant int   QJ_SHADOW_STEPS = 12;
constant int   QJ_AO_TAPS = 4;
constant int   QJ_GLASS_PROBES = 7; // thickness probes along the refracted ray
constant float QJ_FOCAL   = 2.2;    // ~49 degree vertical field of view
constant float QJ_PERIOD  = 140.0;  // seconds of (speed=1) time per loop of c

// ---------------------------------------------------------------------------
// Per-frame state, built once in lerpMain and passed down by value.

struct QjFrame {
    float4 c;                 // Julia constant
    float4 rot;               // twist (cos, sin, 0, 0): q <- q^n rot + c
    float3 cn;                // c's imaginary direction (for the plane trap)
    float4 bx, by, bz, bo;    // slice: q = bo + p.x*bx + p.y*by + p.z*bz
    float  bound;             // bounding-sphere radius in slice space
    float3 cutN;              // cut plane: points with dot(p, cutN) > cutD are removed
    float  cutD;
    bool   cutOn;
};

struct QjSample {
    float d;       // distance estimate (with the cut applied)
    float trap;    // min |q|^2 along the orbit (a point trap at the origin)
    float trapPl;  // min |q.v . cn|: the plane through the real axis facing c
    float trapAx;  // min |q.v|^2: distance to the real axis
    bool  face;    // the cut plane, not the set, is the closer surface
};

// The camera, built in lerpMain.
struct QjView {
    float3 ro, rd, right, up, fwd, back;
    float  pix;               // pixel footprint per unit distance
};

static inline float4 qjLift(float3 p, QjFrame F) {
    return F.bo + p.x * F.bx + p.y * F.by + p.z * F.bz;
}

// One orbit step, updating |q'|^2. The twist right-multiplies by the unit
// quaternion rot = (cos, sin, 0, 0), i.e. about the i axis: the frame is
// chosen so (see lerpMain) and q * (c + s i) is then two complex products,
// (a, x) and (y, z), eight flops instead of a full quaternion product.
// |q^n rot| = |q|^n and |d(q^n rot)| <= n|q|^(n-1)|dq| for a unit rot, so the
// twist leaves the scalar derivative bound intact.
template <int P, bool TW>
static inline float4 qjIter(float4 q, float m2, thread float& md2, QjFrame F) {
    float a = q.x;
    float v2 = dot(q.yzw, q.yzw);
    float4 r;
    if (P == 2) {
        md2 *= 4.0 * m2;
        r = float4(a * a - v2, 2.0 * a * q.yzw);
    } else {
        md2 *= 9.0 * m2 * m2;
        r = float4(a * (a * a - 3.0 * v2), (3.0 * a * a - v2) * q.yzw);
    }
    if (TW) {
        float c = F.rot.x, s = F.rot.y;
        r = float4(r.x * c - r.y * s, r.x * s + r.y * c, r.z * c + r.w * s, r.w * c - r.z * s);
    }
    return r + F.c;
}

// Distance estimate.
template <int P, bool TW>
static float qjDE(float3 p, QjFrame F) {
    float4 q = qjLift(p, F);
    float m2 = dot(q, q), md2 = 1.0;
    for (int i = 0; i < (P == 2 ? QJ_ITERS2 : QJ_ITERS3); i++) {
        q = qjIter<P, TW>(q, m2, md2, F);
        m2 = dot(q, q);
        if (m2 > QJ_BAIL) break;
    }
    // 0.5 |q| log|q| / |q'|, with log|q| = 0.5 log(m2).
    float d = 0.25 * log(m2) * sqrt(m2 / md2);
    if (F.cutOn) d = max(d, dot(p, F.cutN) - F.cutD);
    return d;
}

// Full sample at a hit: distance plus the orbit traps that colour it.
template <int P, bool TW>
static QjSample qjSample(float3 p, QjFrame F) {
    float4 q = qjLift(p, F);
    float m2 = dot(q, q), md2 = 1.0;
    float trap = m2, trapPl = abs(dot(q.yzw, F.cn)), trapAx = dot(q.yzw, q.yzw);
    for (int i = 0; i < (P == 2 ? QJ_ITERS2 : QJ_ITERS3); i++) {
        q = qjIter<P, TW>(q, m2, md2, F);
        m2 = dot(q, q);
        trap = min(trap, m2);
        trapPl = min(trapPl, abs(dot(q.yzw, F.cn)));
        trapAx = min(trapAx, dot(q.yzw, q.yzw));
        if (m2 > QJ_BAIL) break;
    }
    QjSample s;
    s.d = 0.25 * log(m2) * sqrt(m2 / md2);
    s.trap = trap;
    s.trapPl = trapPl;
    s.trapAx = trapAx;
    s.face = false;
    if (F.cutOn) {
        float dp = dot(p, F.cutN) - F.cutD;
        s.face = dp > s.d;
        s.d = max(s.d, dp);
    }
    return s;
}

// Ray / sphere at the origin: (enter, exit), or exit < enter for a miss.
static inline float2 qjSphere(float3 ro, float3 rd, float r) {
    float b = dot(ro, rd);
    float c = dot(ro, ro) - r * r;
    float h = b * b - c;
    if (h < 0.0) return float2(1.0, -1.0);
    h = sqrt(h);
    return float2(-b - h, -b + h);
}

// Tetrahedral gradient at scale e. Also returns, in .w, the mean of the four
// taps minus the centre value over e: a Laplacian at that scale, large where
// the surface bends within the tetrahedron (ridges, pores, crinkles).
template <int P, bool TW>
static float4 qjGrad(float3 p, float e, float d0, QjFrame F) {
    const float2 k = float2(1.0, -1.0);
    float a = qjDE<P, TW>(p + k.xyy * e, F);
    float b = qjDE<P, TW>(p + k.yyx * e, F);
    float c = qjDE<P, TW>(p + k.yxy * e, F);
    float d = qjDE<P, TW>(p + k.xxx * e, F);
    float3 g = k.xyy * a + k.yyx * b + k.yxy * c + k.xxx * d;
    return float4(normalize(g), (0.25 * (a + b + c + d) - d0) / e);
}

// Penumbra shadow: the narrowest miss along the ray toward the light.
template <int P, bool TW>
static float qjShadow(float3 p, float3 l, QjFrame F) {
    float tmax = qjSphere(p, l, F.bound).y;
    float res = 1.0;
    float t = 0.006;
    for (int i = 0; i < QJ_SHADOW_STEPS; i++) {
        if (t > tmax) break;
        float d = qjDE<P, TW>(p + l * t, F);
        res = min(res, 10.0 * d / t);
        if (res < 0.002) break;
        t += clamp(d, 0.006, 0.2);
    }
    res = clamp(res, 0.0, 1.0);
    return res * res * (3.0 - 2.0 * res);
}

// Ambient occlusion at several scales along the normal, from a few pixels'
// worth of relief out to the object's large folds. Each tap is normalised by
// its own height so the finest pores count as much as the deep hollows.
// .y is the first tap alone: how open the surface is a few pixels out, which
// is the cavity term (creases and pores go dark, ridges stay lit).
template <int P, bool TW>
static float2 qjAO(float3 p, float3 n, float h0, QjFrame F) {
    float occ = 0.0, wsum = 0.0, w = 1.0, h = h0, first = 1.0;
    for (int i = 0; i < QJ_AO_TAPS; i++) {
        float a = clamp(qjDE<P, TW>(p + n * h, F) / (0.8 * h), 0.0, 1.0);
        if (i == 0) first = a;
        occ += w * a;
        wsum += w;
        h *= 2.8;
        w *= 0.85;
    }
    return float2(occ / wsum, first);
}

// Orbit-trap palettes, cosine form, blended by `hue`:
// 0 Bone & copper, 0.5 Jade, 1 Violet & gold.
static inline float3 qjPal(float t, float hue) {
    float3 a0 = float3(0.56, 0.46, 0.38), b0 = float3(0.34, 0.27, 0.22), d0 = float3(0.00, 0.06, 0.14);
    float3 a1 = float3(0.30, 0.47, 0.44), b1 = float3(0.24, 0.27, 0.24), d1 = float3(0.58, 0.50, 0.44);
    float3 a2 = float3(0.58, 0.42, 0.42), b2 = float3(0.27, 0.23, 0.13), d2 = float3(0.50, 0.53, 0.04);
    float k = clamp(hue, 0.0, 1.0) * 2.0;
    float3 a = k < 1.0 ? mix(a0, a1, k) : mix(a1, a2, k - 1.0);
    float3 b = k < 1.0 ? mix(b0, b1, k) : mix(b1, b2, k - 1.0);
    float3 d = k < 1.0 ? mix(d0, d1, k) : mix(d1, d2, k - 1.0);
    return clamp(a + b * cos(TWO_PI * (t + d)), 0.0, 1.0);
}

// Dark studio for reflections: a faint gradient, a soft overhead panel and a
// low strip light to one side. The background itself shows only the gradient.
static inline float3 qjEnv(float3 rd, float3 back) {
    float3 c = back * (1.0 + 1.5 * clamp(rd.y, 0.0, 1.0));
    c += float3(0.60, 0.57, 0.52) * smoothstep(0.75, 0.95, rd.y);
    c += float3(0.22, 0.28, 0.40) * exp(-25.0 * rd.y * rd.y) * smoothstep(0.1, 0.7, rd.x);
    return c;
}

// March and shade one ray: the linear colour, or col plus a faint halo on a miss.
template <int P, bool TW>
static float3 qjScene(QjFrame F, QjView V, float3 col, constant LerpUniforms& u) {
    float3 ro = V.ro, rd = V.rd;
    float pix = V.pix;
    float2 span = qjSphere(ro, rd, F.bound);
    float hitT = -1.0;
    float minD = 1e9;                                 // closest miss, as an angle
    if (span.y > 0.0) {
        float tm = max(span.x, 0.0), d = 1.0;
        for (int i = 0; i < QJ_STEPS; i++) {
            float3 p = ro + rd * tm;
            d = qjDE<P, TW>(p, F);
            minD = min(minD, d / tm);
            if (d < QJ_HIT_PX * pix * tm) { hitT = tm; break; }
            // Lengthened steps, except where the cut plane (an exact
            // distance) is what limits the step: overshooting it would land
            // inside the solid.
            bool planeLimited = F.cutOn && dot(p, F.cutN) - F.cutD >= d - 1e-6;
            tm += planeLimited ? d : QJ_RELAX * d;
            if (tm > span.y) break;
        }
        // Grazing rays that run out of steps hugging a fold: call it a hit
        // rather than leave a dark seam along the silhouette.
        if (hitT < 0.0 && tm < span.y && d < QJ_MISS_PX * pix * tm) hitT = tm;
    }

    if (hitT > 0.0) {
        float3 p = ro + rd * hitT;
        QjSample hs = qjSample<P, TW>(p, F);
        float e = max(0.5 * pix * hitT, 1e-5);
        float4 g = hs.face ? float4(F.cutN, 0.0) : qjGrad<P, TW>(p, e, hs.d, F);
        float3 n = g.xyz;
        // Relief finer than the footprint: widen the highlight there rather
        // than let a tight lobe sparkle across sub-pixel ridges. The cut face
        // is flat; give it a satin finish rather than a mirror.
        float rough = hs.face ? 0.55 : clamp(abs(g.w) * 4.0, 0.0, 1.0);

        float3 L = normalize(0.4 * V.right + 0.8 * float3(0.0, 1.0, 0.0) - 0.6 * V.fwd);
        float3 L2 = normalize(-0.7 * V.right + 0.35 * float3(0.0, 1.0, 0.0) + 0.6 * V.fwd);  // cool back light
        float3 keyCol = float3(1.82, 1.57, 1.29);
        float3 skyCol = float3(0.20, 0.25, 0.39);
        float3 rimCol = float3(0.30, 0.42, 0.65);

        float tr = sqrt(hs.trap);
        float3 alb;
        float vein = 0.0;
        if (hs.face) {
            float k = 2.2 * tr + 1.2 * hs.trapPl;
            float band = 0.5 + 0.5 * cos(TWO_PI * 3.0 * k);
            alb = qjPal(k + 0.45, u.hue) * (0.45 + 0.55 * band);
        } else {
            // Body colour from where the orbit passes nearest the origin and
            // the plane facing c; veins are thin contour lines of the
            // real-axis trap, which wrap the folds like strata. fwidth keeps
            // each line about a pixel wide however finely they bunch.
            float k = 0.9 * tr + 0.7 * hs.trapPl;
            alb = qjPal(k, u.hue);
            float vk = 6.0 * sqrt(hs.trapAx);
            float vf = abs(fract(vk) - 0.5) * 2.0;           // 1 on a vein, 0 between
            float vw = fwidth(vk) * 2.0 + 0.04;
            vein = u.veins * (1.0 - smoothstep(0.0, vw * 2.0, 1.0 - vf));
        }
        alb = 0.25 + 0.75 * alb;                          // lift the palette's dark trough
        alb = alb * alb;                                  // to linear

        float2 ao = qjAO<P, TW>(p, n, 4.0 * e + 0.002, F);
        float occ = ao.x;
        float cav = mix(1.0, smoothstep(0.25, 0.9, ao.y), 0.7);   // 0 in creases, 1 on ridges
        float dif = max(dot(n, L), 0.0);
        // Full glass shows no diffuse; skip the shadow ray it would not use.
        if (dif > 0.0 && u.glass < 0.999) dif *= qjShadow<P, TW>(p + n * 2.0 * e, L, F);
        float3 h = normalize(L - rd);
        float nv = clamp(dot(n, -rd), 0.0, 1.0);
        float fre = pow(1.0 - nv, 5.0);

        // Material: a glaze (dielectric, white specular, F0 0.04) blended
        // toward metal (tinted specular, little diffuse). Veins are darker,
        // rougher and, on metal, a contrasting tint.
        float metal = u.metal;
        float3 veinCol = qjPal(0.62, u.hue);
        veinCol *= veinCol;
        float3 dAlb = mix(alb, veinCol * 0.35, vein);
        float3 F0 = mix(float3(0.04), mix(alb, veinCol, vein) * 1.4, metal);
        float3 Fr = F0 + (1.0 - F0) * fre;
        float gloss = (1.0 - rough) * (1.0 - 0.6 * vein);
        float expo = mix(24.0, 360.0, gloss * gloss);
        float spe = pow(max(dot(n, h), 0.0), expo) * (expo + 8.0) / 25.0 * dif;
        float3 refl = qjEnv(reflect(rd, n), V.back) * 2.2 * occ * mix(0.35, 1.0, gloss);
        float3 h2 = normalize(L2 - rd);
        float spe2 = pow(max(dot(n, h2), 0.0), 0.5 * expo) * (0.5 * expo + 8.0) / 25.0
                   * max(dot(n, L2), 0.0) * occ;

        float3 diffuse = dAlb * (keyCol * dif
                                 + skyCol * (0.6 + 0.4 * n.y) * occ
                                 + float3(0.10, 0.07, 0.05) * clamp(-n.y, 0.0, 1.0) * occ);
        float3 opaque = diffuse * (1.0 - 0.7 * metal) * (1.0 - 0.5 * fre)
                      + Fr * (keyCol * spe + refl + float3(0.68, 0.9, 1.35) * spe2)
                      + rimCol * pow(1.0 - nv, 3.0) * occ * 0.25;
        opaque *= mix(0.3, 1.0, cav);

        float3 glassCol = opaque;
        if (u.glass > 0.001) {
            // Glass: the studio reflected by Schlick fresnel, and through the
            // body a soft backlight absorbed over the thickness found by
            // probing along the refracted ray. Thin walls pass it almost
            // untouched; thick ones go dark and saturated. The tint is the
            // orbit-trap colour normalised to its brightest channel, so the
            // absorption changes hue, not just brightness.
            float kr = 0.06 + 0.94 * fre;
            float3 grefl = qjEnv(reflect(rd, n), V.back) * (0.4 + 0.6 * occ) * 2.5;
            float3 rr = refract(rd, n, 1.0 / 1.45);
            // Probes spaced as i^1.5, out to ~0.75: fine near the surface,
            // where thin walls are told apart, sparse deep inside.
            float thick = 0.0, sPrev = 0.0;
            for (int i = 1; i <= QJ_GLASS_PROBES; i++) {
                float fi = float(i);
                float s = 0.04 * fi * sqrt(fi);
                float inside = 1.0 - smoothstep(0.0, 0.01, qjDE<P, TW>(p + rr * s, F));
                thick += inside * (s - sPrev);
                sPrev = s;
            }
            float3 tint = qjPal(0.35 * tr + 0.15 * hs.trapPl + 0.2, u.hue);
            tint /= max(max(tint.r, tint.g), max(tint.b, 1e-3));
            float3 absorb = exp(-thick * (7.0 * (1.0 - tint) + 2.5));
            float3 behind = float3(0.95, 0.97, 1.0) * (0.45 + 0.55 * clamp(dot(rr, L) + 0.6, 0.0, 1.0));
            float3 trans = behind * absorb;
            glassCol = mix(trans, grefl, kr) + keyCol * 0.5 * spe + rimCol * fre * 0.8;
        }
        col = mix(opaque, glassCol, u.glass);
    } else if (minD < 1e8) {
        // Near misses: a faint halo hugging the silhouette.
        col += qjPal(0.3, u.hue) * 0.04 * exp(-minD * 300.0);
    }
    return col;
}

// ---------------------------------------------------------------------------

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float t = u.speed * u.time;
    float sd = u.seed * 97.0;
    float th = TWO_PI * t / QJ_PERIOD + sd;          // the loop's phase

    // --- c. The pair (real part, |imaginary part|) circles a small ellipse
    // around (cReal, cImag), the imaginary part's lean out of the slice into
    // the fourth axis rocks around `lean`, and the twist breathes a little,
    // all at integer multiples of one frequency, so the path closes every
    // QJ_PERIOD / speed seconds.
    QjFrame F;
    float amp = u.morph;
    float re = u.cReal + 0.04 * amp * cos(th + 1.3 * sd);
    float im = u.cImag + 0.03 * amp * sin(2.0 * th + 0.7 * sd);
    float az = th + 2.1 * sd;
    float lean = clamp(u.lean + 0.25 * amp * sin(3.0 * th + 0.4 * sd), 0.0, 1.5);
    // c's imaginary part leans out of the (i, j) plane toward k; the twist
    // turns about c's in-plane direction. Both are written in a frame turned
    // by -az about k, where that direction is i (so the twist is the cheap
    // product in qjIter); az instead turns the slice's y and z axes, which is
    // the same thing seen from the other side: conjugating by a unit
    // quaternion maps the set onto itself rotated, so az only spins the object.
    float3 dir = float3(cos(lean), 0.0, sin(lean));
    F.c = float4(re, im * dir);
    F.cn = dir;
    float tw = u.twist * (1.0 + 0.06 * amp * sin(th + 2.6 * sd));
    bool twisted = u.twist > 0.001;
    F.rot = float4(cos(tw), sin(tw), 0.0, 0.0);

    // --- Slice: the 3D space (x, y, z) at w = w0, with x (the real axis)
    // tilted toward w. Both rock slowly, so the cut leaves the set's planes
    // of symmetry.
    float tilt = u.slice * 0.25 * sin(th + 0.9 * sd);
    float w0 = u.slice * 0.20 * sin(2.0 * th + 0.3 * sd);
    float ct = cos(tilt), st = sin(tilt);
    float caz = cos(az), saz = sin(az);
    F.bx = float4(ct, 0.0, 0.0, st);
    F.by = float4(0.0, caz, -saz, 0.0);
    F.bz = float4(0.0, saz, caz, 0.0);
    F.bo = float4(-st, 0.0, 0.0, ct) * w0;

    // Bounding radius. |q| >= |p| on the slice, and the set lies inside
    // |q| <= R where R^n - R = |c| (beyond it |q| grows every iteration;
    // the unit twist does not change |q^n r|).
    float cm = length(F.c);
    float R = 0.5 * (1.0 + sqrt(1.0 + 4.0 * cm));
    if (u.power == 3) {
        R = 1.0 + cm;                                 // above the root; Newton down
        for (int i = 0; i < 3; i++) R -= (R * R * R - R - cm) / (3.0 * R * R - 1.0);
    }
    F.bound = R + 0.02;

    // --- Camera: a slow orbit, height swaying, always looking at the centre.
    QjView V;
    float ca = 0.035 * t + sd * 6.2831;
    float ce = 0.35 * sin(0.021 * t + 3.0 * sd) + 0.15;
    float dist = 3.3 / u.zoom;
    V.ro = dist * float3(cos(ce) * sin(ca), sin(ce), cos(ce) * cos(ca));
    V.fwd = normalize(-V.ro);
    V.right = normalize(cross(float3(0.0, 1.0, 0.0), V.fwd));
    V.up = cross(V.fwd, V.right);
    V.rd = normalize(uv.x * V.right + uv.y * V.up + QJ_FOCAL * V.fwd);
    V.pix = 1.0 / (QJ_FOCAL * min(u.resolution.x, u.resolution.y));

    // Cut plane: faces the camera (slightly oblique, so the face catches the
    // light) and removes everything on the camera's side of it.
    F.cutOn = u.cut > 0.001;
    F.cutN = normalize(-V.fwd + 0.35 * V.right + 0.25 * V.up);
    F.cutD = mix(F.bound, -0.25, u.cut);

    // Background: the colour, lifted a little toward the top and in a broad
    // pool behind the object.
    V.back = u.colorBack.rgb;
    float3 col = V.back * (0.75 + 0.35 * uv.y + 1.2 * exp(-1.2 * dot(uv, uv)));

    if (u.power == 2) col = twisted ? qjScene<2, true>(F, V, col, u) : qjScene<2, false>(F, V, col, u);
    else              col = twisted ? qjScene<3, true>(F, V, col, u) : qjScene<3, false>(F, V, col, u);

    // Tonemap and back to display space.
    col = 1.0 - exp(-1.1 * col);
    col = sqrt(max(col, 0.0));
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
