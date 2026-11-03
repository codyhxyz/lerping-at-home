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
//     a short distance-field ambient-occlusion probe along the normal
//   - cosine colour palettes a + b·cos(2π(c·t + d))
//
// The quaternion powers use the closed forms for q = (a, v):
//   q^2 = (a^2 - |v|^2, 2a v)
//   q^3 = (a^3 - 3a|v|^2, (3a^2 - |v|^2) v)
// which is why there is no general quaternion multiply in the inner loop.
// The scalar |q'| over-bounds the true Jacobian (for quaternions q h + h q
// is not 2 q h), so the estimate is conservative. Tracking the Jacobian along
// the three slice axes tightens it and cuts the step count, but on an M5 each
// step then costs more than the steps it saves (about 2x slower overall).
//
// Looks:
//   - power 2 (q^2 + c) or 3 (q^3 + c)
//   - cut > 0: a plane facing the camera removes the near part of the object;
//     the cut face is coloured by what the orbit does there (interior
//     colouring), so the inside of the set shows its own structure
//   - glass > 0: fresnel reflection of a dark studio, plus a backlight seen
//     through the body, absorbed over a thickness measured with a few
//     inside/outside probes along the refracted ray and tinted by the
//     orbit trap
//
// Seed: sets the phases of c's loop and of the slice tilt (a different path
// through the same family of shapes) and the camera's orbit angle and height.
//
// Cost control, because this runs full-screen for hours: the march only runs
// inside the set's bounding sphere, whose radius follows from |c|; the hit
// tolerance is about a pixel's footprint but never finer than a 1200-px-tall
// view's, so 4K and 5K do not pay for sub-pixel detail in extra steps;
// iterations, march steps, shadow steps, AO taps and glass probes are fixed
// budgets; normals are a four-tap tetrahedral gradient taken once per hit.
// LerpPreview --bench at 3840x2160 on an Apple M5, mean ms (fractal-multiverse
// 8.6 in the same runs): default 9.9, Cubic 5.9, Intersected 8.1, Glass 10.9,
// Turned 8.8. The bench moment is one of the dearer ones; the default look
// measured 7.0–8.3 ms 40, 120 and 200 s later.
//
// lerp-param: speed  float 0 2       = 0.5   "Speed"
// lerp-param: power  int   2 3       = 2     "Power"
// lerp-param: cReal  float -0.8 0.4  = -0.16 "c real centre"
// lerp-param: cImag  float 0 1.2     = 0.74  "c imaginary centre"
// lerp-param: morph  float 0 1       = 0.5   "Morph"
// lerp-param: slice  float 0 1       = 0.5   "4D slice tilt"
// lerp-param: cut    float 0 1       = 0.0   "Cut"
// lerp-param: glass  float 0 1       = 0.0   "Glass"
// lerp-param: hue    float 0 1       = 0.0   "Palette"
// lerp-param: zoom   float 0.6 1.6   = 1.0   "Zoom"
// lerp-param: colorBack color        = (0.012, 0.014, 0.024) "Background"
//
// lerp-preset: Cubic        power=3, cReal=0.0, cImag=0.8, hue=0.5
// lerp-preset: Intersected  cut=0.55, slice=0.35, hue=1.0
// lerp-preset: Glass        glass=1.0, cReal=-0.2, cImag=0.70, hue=0.88
// lerp-preset: Turned       cReal=-0.68, cImag=0.28, slice=0.15, hue=0.25, zoom=1.15

constant int   QJ_ITERS   = 9;      // orbit iterations per distance estimate
constant float QJ_BAIL    = 64.0;   // |q|^2 escape threshold
constant int   QJ_STEPS   = 110;    // march budget
constant int   QJ_SHADOW_STEPS = 16;
constant int   QJ_GLASS_PROBES = 7; // thickness probes along the refracted ray
constant float QJ_FOCAL   = 2.2;    // ~49 degree vertical field of view
constant float QJ_REF_PX  = 1200.0; // finest view height the hit tolerance resolves
constant float QJ_PERIOD  = 140.0;  // seconds of (speed=1) time per loop of c

// ---------------------------------------------------------------------------
// Per-frame state, built once in lerpMain and passed down by value.

struct QjFrame {
    float4 c;                 // Julia constant
    float4 bx, by, bz, bo;    // slice: q = bo + p.x*bx + p.y*by + p.z*bz
    float  bound;             // bounding-sphere radius in slice space
    int    power;
    float3 cutN;              // cut plane: points with dot(p, cutN) > cutD are removed
    float  cutD;
    bool   cutOn;
};

struct QjSample {
    float d;       // distance estimate (with the cut applied)
    float trap;    // orbit trap: min |q|^2 along the orbit
    float trap2;   // orbit trap: min |q.y| (a coordinate plane), for banding
    bool  face;    // the cut plane, not the set, is the closer surface
};

static inline float4 qjLift(float3 p, QjFrame F) {
    return F.bo + p.x * F.bx + p.y * F.by + p.z * F.bz;
}

// Distance estimate to the sliced Julia set at slice-space point p.
static QjSample qjMap(float3 p, QjFrame F) {
    float4 q = qjLift(p, F);
    float m2 = dot(q, q);
    float md2 = 1.0;                // |q'|^2
    float trap = m2, trap2 = abs(q.y);
    if (F.power == 2) {
        for (int i = 0; i < QJ_ITERS; i++) {
            md2 *= 4.0 * m2;
            float a = q.x;
            q = float4(a * a - dot(q.yzw, q.yzw), 2.0 * a * q.yzw) + F.c;
            m2 = dot(q, q);
            trap = min(trap, m2);
            trap2 = min(trap2, abs(q.y));
            if (m2 > QJ_BAIL) break;
        }
    } else {
        for (int i = 0; i < QJ_ITERS; i++) {
            md2 *= 9.0 * m2 * m2;
            float a = q.x;
            float v2 = dot(q.yzw, q.yzw);
            q = float4(a * (a * a - 3.0 * v2), (3.0 * a * a - v2) * q.yzw) + F.c;
            m2 = dot(q, q);
            trap = min(trap, m2);
            trap2 = min(trap2, abs(q.y));
            if (m2 > QJ_BAIL) break;
        }
    }
    // 0.5 |q| log|q| / |q'|, with log|q| = 0.5 log(m2).
    QjSample s;
    s.d = 0.25 * log(m2) * sqrt(m2 / md2);
    s.trap = trap;
    s.trap2 = trap2;
    s.face = false;
    if (F.cutOn) {
        float dp = dot(p, F.cutN) - F.cutD;
        // Outside the kept half-space the plane is the surface; inside it
        // the set is.
        s.face = dp > s.d;
        s.d = max(s.d, dp);
    }
    return s;
}

static inline float qjDist(float3 p, QjFrame F) { return qjMap(p, F).d; }

// Ray / sphere at the origin: (enter, exit), or exit < enter for a miss.
static inline float2 qjSphere(float3 ro, float3 rd, float r) {
    float b = dot(ro, rd);
    float c = dot(ro, ro) - r * r;
    float h = b * b - c;
    if (h < 0.0) return float2(1.0, -1.0);
    h = sqrt(h);
    return float2(-b - h, -b + h);
}

// Tetrahedral gradient: four estimates, one normal.
static float3 qjNormal(float3 p, float e, QjFrame F) {
    const float2 k = float2(1.0, -1.0);
    return normalize(k.xyy * qjDist(p + k.xyy * e, F) +
                     k.yyx * qjDist(p + k.yyx * e, F) +
                     k.yxy * qjDist(p + k.yxy * e, F) +
                     k.xxx * qjDist(p + k.xxx * e, F));
}

// Penumbra shadow: the narrowest miss along the ray toward the light, as a
// ratio of distance to the surface over distance travelled.
static float qjShadow(float3 p, float3 l, QjFrame F) {
    float tmax = qjSphere(p, l, F.bound).y;
    float res = 1.0;
    float t = 0.01;
    for (int i = 0; i < QJ_SHADOW_STEPS; i++) {
        if (t > tmax) break;
        float d = qjDist(p + l * t, F);
        res = min(res, 9.0 * d / t);
        if (res < 0.002) break;
        t += clamp(d, 0.01, 0.2);
    }
    res = clamp(res, 0.0, 1.0);
    return res * res * (3.0 - 2.0 * res);
}

// Ambient occlusion: how much closer the surface is than the probe distance,
// at four points along the normal.
static float qjAO(float3 p, float3 n, QjFrame F) {
    float occ = 0.0, w = 1.0;
    for (int i = 1; i <= 4; i++) {
        float h = 0.025 * float(i * i);
        occ += w * max(h - qjDist(p + n * h, F), 0.0);
        w *= 0.6;
    }
    return clamp(1.0 - 3.0 * occ, 0.0, 1.0);
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

// ---------------------------------------------------------------------------

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float t = u.speed * u.time;
    float sd = u.seed * 97.0;
    float th = TWO_PI * t / QJ_PERIOD + sd;          // the loop's phase

    // --- c. Every quaternion is a real part plus one imaginary direction, and
    // the set is symmetric about that direction, so c has three meaningful
    // controls: the pair (real part, |imaginary part|), which sets the
    // profile the set is "turned" from, and how far the imaginary direction
    // leans out of the slice into w, which sets how the slice cuts it. The
    // pair circles an ellipse around (cReal, cImag) and the lean rocks, all
    // at integer multiples of one frequency, so the path closes every
    // QJ_PERIOD / speed seconds. The direction's azimuth only spins the
    // object about the slice's x axis.
    QjFrame F;
    F.power = u.power;
    float amp = u.morph;
    float re = u.cReal + 0.10 * amp * cos(th + 1.3 * sd);
    float im = u.cImag + 0.08 * amp * sin(2.0 * th + 0.7 * sd);
    float az = th + 2.1 * sd;
    float lean = 0.75 + 0.45 * amp * sin(3.0 * th + 0.4 * sd);
    float3 dir = float3(cos(lean) * cos(az), cos(lean) * sin(az), sin(lean));
    F.c = float4(re, im * dir);

    // --- Slice: the 3D space (x, y, z) at w = w0, with x (the real axis)
    // tilted toward w. Both rock slowly, so the cut leaves the set's planes
    // of symmetry and the shape loses its lathe-turned regularity.
    float tilt = u.slice * 0.35 * sin(th + 0.9 * sd);
    float w0 = u.slice * 0.25 * sin(2.0 * th + 0.3 * sd);
    float ct = cos(tilt), st = sin(tilt);
    F.bx = float4(ct, 0.0, 0.0, st);
    F.by = float4(0.0, 1.0, 0.0, 0.0);
    F.bz = float4(0.0, 0.0, 1.0, 0.0);
    F.bo = float4(-st, 0.0, 0.0, ct) * w0;

    // Bounding radius. |q| >= |p| on the slice, and the set lies inside
    // |q| <= R where R^n - R = |c| (beyond it |q| grows every iteration).
    float cm = length(F.c);
    float R = 0.5 * (1.0 + sqrt(1.0 + 4.0 * cm));
    if (F.power == 3) {
        R = 1.0 + cm;                                 // above the root; Newton down
        for (int i = 0; i < 3; i++) R -= (R * R * R - R - cm) / (3.0 * R * R - 1.0);
    }
    F.bound = R + 0.02;

    // --- Camera: a slow orbit, height swaying, always looking at the centre.
    float ca = 0.035 * t + sd * 6.2831;
    float ce = 0.35 * sin(0.021 * t + 3.0 * sd) + 0.15;
    float dist = 3.3 / u.zoom;
    float3 ro = dist * float3(cos(ce) * sin(ca), sin(ce), cos(ce) * cos(ca));
    float3 fwd = normalize(-ro);
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
    float3 up = cross(fwd, right);
    float3 rd = normalize(uv.x * right + uv.y * up + QJ_FOCAL * fwd);

    // Cut plane: faces the camera (slightly oblique, so the face catches the
    // light) and removes everything on the camera's side of it.
    F.cutOn = u.cut > 0.001;
    F.cutN = normalize(-fwd + 0.35 * right + 0.25 * up);
    F.cutD = mix(F.bound, -0.25, u.cut);

    // Background: the colour, lifted a little toward the top and in a broad
    // pool behind the object.
    float3 back = u.colorBack.rgb;
    float3 col = back * (0.75 + 0.35 * uv.y + 1.2 * exp(-1.2 * dot(uv, uv)));

    // --- March, inside the bounding sphere only.
    // The hit tolerance is a pixel's footprint, but never finer than a pixel
    // of a QJ_REF_PX-tall view: past that the extra surface detail is
    // sub-pixel noise anyway, and a 5K frame would pay for it in steps.
    float pix = 1.0 / (QJ_FOCAL * min(min(u.resolution.x, u.resolution.y), QJ_REF_PX));
    float2 span = qjSphere(ro, rd, F.bound);
    float hitT = -1.0;
    QjSample hs = { 0.0, 1.0, 1.0, false };
    float minD = 1e9;                                 // closest miss, as an angle
    if (span.y > 0.0) {
        // Plain sphere tracing at full step: the scalar |q'| bound already
        // makes the estimate conservative. (Over-relaxed stepping was tried
        // and lost more to rejected steps than it saved.)
        float tm = max(span.x, 0.0);
        for (int i = 0; i < QJ_STEPS; i++) {
            QjSample s = qjMap(ro + rd * tm, F);
            minD = min(minD, s.d / tm);
            if (s.d < 1.2 * pix * tm) { hitT = tm; hs = s; break; }
            tm += s.d;
            if (tm > span.y) break;
        }
    }

    if (hitT > 0.0) {
        float3 p = ro + rd * hitT;
        float3 n = hs.face ? F.cutN : qjNormal(p, max(0.6 * pix * hitT, 1e-4), F);
        float3 L = normalize(0.55 * right + 0.80 * float3(0.0, 1.0, 0.0) - 0.25 * fwd);
        float3 keyCol = float3(1.30, 1.12, 0.92);
        float3 skyCol = float3(0.13, 0.17, 0.26);
        float3 rimCol = float3(0.30, 0.42, 0.65);

        // Albedo from the orbit traps. On the cut face the orbit is bounded,
        // so both traps vary a lot more there; folded through a cosine they
        // make the interior's bands.
        float tr = sqrt(hs.trap);
        float3 alb;
        if (hs.face) {
            float k = 2.2 * tr + 1.2 * hs.trap2;
            float band = 0.5 + 0.5 * cos(TWO_PI * 3.0 * k);
            alb = qjPal(k + 0.45, u.hue) * (0.45 + 0.55 * band);
        } else {
            alb = qjPal(0.85 * tr + 0.25 * hs.trap2, u.hue);
        }
        alb = alb * alb;                              // to linear

        float occ = qjAO(p, n, F);
        float ndl = dot(n, L);
        float dif = max(ndl, 0.0);
        if (dif > 0.0) dif *= qjShadow(p + n * 0.004, L, F);
        float3 h = normalize(L - rd);
        float nv = clamp(dot(n, -rd), 0.0, 1.0);
        float fre = pow(1.0 - nv, 5.0);
        float spe = pow(max(dot(n, h), 0.0), 48.0) * dif * (0.04 + 0.96 * pow(1.0 - max(dot(h, -rd), 0.0), 5.0));

        float3 opaque = alb * (keyCol * dif
                               + skyCol * (0.6 + 0.4 * n.y) * occ
                               + float3(0.10, 0.07, 0.05) * clamp(-n.y, 0.0, 1.0) * occ)
                      + keyCol * 1.4 * spe
                      + rimCol * pow(1.0 - nv, 3.0) * occ * 0.35;

        float3 glassCol = opaque;
        if (u.glass > 0.001) {
            // Glass: the studio reflected by Schlick fresnel, and through the
            // body a soft backlight absorbed over the thickness found by
            // probing along the refracted ray. Thin walls pass it almost
            // untouched; thick ones go dark and saturated. The tint is the
            // orbit-trap colour normalised to its brightest channel, so the
            // absorption changes hue, not just brightness.
            float kr = 0.06 + 0.94 * fre;
            float3 refl = qjEnv(reflect(rd, n), back) * (0.4 + 0.6 * occ) * 2.5;
            float3 rr = refract(rd, n, 1.0 / 1.45);
            // Probes spaced as i^1.5, out to ~0.75: fine near the surface,
            // where thin walls are told apart, sparse deep inside.
            float thick = 0.0, sPrev = 0.0;
            for (int i = 1; i <= QJ_GLASS_PROBES; i++) {
                float fi = float(i);
                float s = 0.04 * fi * sqrt(fi);
                float inside = 1.0 - smoothstep(0.0, 0.01, qjDist(p + rr * s, F));
                thick += inside * (s - sPrev);
                sPrev = s;
            }
            float3 tint = qjPal(0.35 * tr + 0.15 * hs.trap2 + 0.2, u.hue);
            tint /= max(max(tint.r, tint.g), max(tint.b, 1e-3));
            float3 absorb = exp(-thick * (7.0 * (1.0 - tint) + 2.5));
            float3 behind = float3(0.95, 0.97, 1.0) * (0.45 + 0.55 * clamp(dot(rr, L) + 0.6, 0.0, 1.0));
            float3 trans = behind * absorb;
            glassCol = mix(trans, refl, kr) + keyCol * 3.0 * spe + rimCol * fre * 0.8;
        }
        col = mix(opaque, glassCol, u.glass);
    } else if (minD < 1e8) {
        // Near misses: a faint halo hugging the silhouette.
        col += qjPal(0.3, u.hue) * 0.04 * exp(-minD * 300.0);
    }

    // Tonemap and back to display space.
    col = 1.0 - exp(-1.1 * col);
    col = sqrt(max(col, 0.0));
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
