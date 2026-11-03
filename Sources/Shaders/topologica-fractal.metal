// Topologica Fractal — a remix of "Topologica" by Otavio Good
// https://www.shadertoy.com/view/4djXzz  (2014-08-21), CC0 1.0:
//   License CC0 - http://creativecommons.org/publicdomain/zero/1.0/
//   (Upstream's dedication is quoted in full in topologica.metal.)
//
// An original remix written for Lerping@Home, not a port. What it keeps from
// Topologica: glowing filaments in a dark volume, a short fixed-stride march
// that sums glow along each ray, upstream's colour multiply and sqrt
// "gamma", its default blue, and a camera slowly orbiting a centre point.
// What it replaces: upstream's noise lattice becomes a self-similar wire
// network, and the camera flies into it forever.
//
// The network is a kaleidoscopic IFS (Knighty's KIFS, as described in
// Mikael Hvidtfeldt Christensen's "Distance Estimated 3D Fractals" on
// Syntopia). The level loop is written here from that math; no code comes
// from Syntopia or from any Shadertoy other than Topologica's CC0 code.
// Space is sorted once into the chamber x >= y >= z. Then each level folds
// with abs() and one tilted mirror, adds the glow of a few straight wires,
// and scales space by S = 3 about C = (1,1,1). Each level is a copy of the
// one above at a third of the size, so the wires branch into ever-finer
// copies of themselves.
//
// The glow is not sampled at points. Each march step is a straight piece of
// ray, folded with the mirrors chosen at its middle, and the shader finds
// that piece's closest approach to each wire analytically. A tent in where
// that approach falls splits each wire's glow between the two nearest
// pieces, so the coarse wires draw as crisp, unbroken lines with only 7
// steps. The folds are rounded (C1) rather than sharp, so a piece that
// straddles a mirror bends smoothly instead of tearing, and the picture
// stays continuous from pixel to pixel and frame to frame. On the finest
// levels one piece spans several mirrors, so its single bent line is only an
// approximation of the true wires there. That approximation is what curls
// the fine wires into Topologica-like curves, and it is kept as the look.
//
// Seamless zoom. abs() and the tilted mirror never act within `rho` of C.
// The sort's mirrors pass through C and its rounding grows with distance
// from C, so it commutes with scaling about C. (It runs once, before the
// level loop: a rounded fold is not idempotent, so sorting again on every
// level would leave a seam.) Near C, then, one level is exactly the level
// above scaled by 3. The camera zooms toward C by exactly that factor once
// per cycle, and each level's brightness is a window over (level - phase).
// At phase 1 every level stands exactly where the level above stood at
// phase 0, so the wrap has no seam. That only holds while all the camera can
// see at phase 1 lies within `rho` of C, so the view's world scale is derived
// from `rho` and the fog depth every frame. (Checked by rendering 4 ms
// either side of a wrap: the difference matches two ordinary frames 4 ms
// apart.)
//
// Seed: picks the orbit's starting angle and height, the phase of the
// mirror and anchor drift, and where in the zoom cycle the run starts.
//
// GPU cost: steps x 4 levels x 1-3 analytic wires. On an M5 at 3840x2160
// (`LerpPreview --bench --looks`, quiet rounds) the default and the Gold
// Filigree and Ice Lattice looks measure 16.7-17.3 ms against topologica's
// 17.0-17.4 ms in the same rounds. Violet Jacks runs 6 steps to stay under
// it too. `steps` above 7 costs proportionally more than topologica.
//
// lerp-param: color  color          = (0.01, 0.1, 1.0) "Glow colour"
// lerp-param: speed  float 0 4      = 1.0              "Speed"
// lerp-param: zoom   float 0 6      = 1.5              "Zoom (levels/min)"
// lerp-param: gain   float 0.05 4   = 1.0              "Glow gain"
// lerp-param: wire   int 0 2        = 0                "Wire (lattice, filigree, jacks)"
// lerp-param: tilt   float 0 1      = 0.5              "Mirror tilt"
// lerp-param: bloom  float 0 1      = 0.5              "Bloom (fold drift)"
// lerp-param: steps  int 4 16       = 7                "March steps"
//
// lerp-preset: "Gold Filigree" color=(0.42, 0.15, 0.02), wire=1, tilt=0.7
// lerp-preset: "Violet Jacks"  color=(0.22, 0.03, 0.55), wire=2, tilt=0.3, steps=6
// lerp-preset: "Ice Lattice"   color=(0.08, 0.35, 0.6), tilt=1.0, bloom=1.0, zoom=3.0

constant int   TFR_LEVELS = 4;
constant float TFR_S      = 3.0;   // scale per level
constant float TFR_EYE    = 1.0;   // eye distance from C, camera units
constant float TFR_FOG    = 3.0;   // march depth, camera units
constant float TFR_SIGMA  = 0.004; // wire core radius, in each level's own units
constant float TFR_SOFT   = 0.05;  // fold rounding, in each level's own units
constant float TFR_HALO   = 0.15;  // soft glow around each wire, relative to the core
constant float TFR_SORT_SOFT = 0.12; // sort-mirror rounding, per unit distance from C

// Rounded mirror fold of a ray piece (point p, half-vector h) through the
// plane through the origin with unit normal n: exactly a reflection more
// than `soft` from the plane, a C1 parabola inside, so the folded picture
// stays continuous where a piece of the march straddles a mirror. h is
// carried by the fold's Jacobian.
static void tfrFold(thread float3& p, thread float3& h, float3 n, float soft) {
    float d = dot(p, n);
    float ad = abs(d);
    bool in = ad < soft;
    float sa = in ? 0.5 * (d * d / soft + soft) : ad;
    float g = in ? d / soft : sign(d);
    p += (sa - d) * n;
    h += (g - 1.0) * dot(h, n) * n;
}

static void tfrFoldAbs(thread float3& p, thread float3& h) {
    float3 ap = abs(p);
    bool3 in = ap < TFR_SOFT;
    float3 sa = select(ap, 0.5 * (p * p / TFR_SOFT + TFR_SOFT), in);
    float3 g = select(sign(p), p / TFR_SOFT, in);
    p = sa;
    h *= g;
}

// Cross-section of one wire's glow at squared distance x2 (in core radii):
// a sharp 1/x^2 core, like Topologica's 0.1/|n^2|, plus a soft halo.
// 1/a + H/b written over one divide.
static float tfrProfile(float x2) {
    float a = x2 + 0.03;
    float b = 1.0 + 0.01 * x2;
    return (b + TFR_HALO * a) / (a * b);
}

// Glow of a straight wire seen from one piece of the ray, everything in one
// level's units. The piece is p + s*h, s in [-1, 1]; neighbouring pieces sit
// at s = +-2. b is the closest approach of the ray's line to the wire's line
// and s* where along the ray it happens; a tent in s* hands each approach to
// the two nearest pieces with weights summing to one, so every wire draws as
// one continuous crisp line however coarse the march. `r` is p relative to a
// point on the wire, `w` the wire's unit direction, and the wire is kept for
// u <= 0 along w (the far end is the mirror plane, which completes it).
static float tfrWireGlow(float3 r, float3 h, float3 w, float isig2) {
    float3 rp = r - dot(r, w) * w;
    float3 hp = h - dot(h, w) * w;
    float A = dot(hp, hp) + 1e-9;
    float sStar = -dot(rp, hp) / A;
    float3 cl = rp + sStar * hp;
    float tent = saturate(1.0 - 0.5 * abs(sStar));
    float ends = saturate(1.0 - dot(r + sStar * h, w) * 30.0);
    float x2 = dot(cl, cl) * isig2;
    return tent * ends * tfrProfile(x2);
}

// The same for a wire along a coordinate axis: r2/h2 are the two components
// across it, ru/hu the component along it.
static float tfrAxisGlow(float2 r2, float2 h2, float ru, float hu, float isig2) {
    float A = dot(h2, h2) + 1e-9;
    float sStar = -dot(r2, h2) / A;
    float2 cl = r2 + sStar * h2;
    float tent = saturate(1.0 - 0.5 * abs(sStar));
    float ends = saturate(1.0 - (ru + sStar * hu) * 30.0);
    float x2 = dot(cl, cl) * isig2;
    return tent * ends * tfrProfile(x2);
}

// Fold the ray piece into the chamber x >= y >= z through the mirrors x=y,
// x=z, y=z. All three pass through C = (1,1,1), and the rounding grows with
// distance from C, so this fold commutes with scaling about C and the zoom
// stays exact (see header).
static void tfrSort(thread float3& p, thread float3& h) {
    float soft = TFR_SORT_SOFT * length(p - 1.0);
    tfrFold(p, h, float3(M_SQRT1_2_F, -M_SQRT1_2_F, 0.0), soft);
    tfrFold(p, h, float3(M_SQRT1_2_F, 0.0, -M_SQRT1_2_F), soft);
    tfrFold(p, h, float3(0.0, M_SQRT1_2_F, -M_SQRT1_2_F), soft);
}

// One level's wires, in that level's units, already folded. `k` is the
// (drifting) anchor of the wire shape.
static float tfrWires(float3 p, float3 h, float3 k, int wire, float isig2) {
    float3 r = p - k;
    if (wire == 1) {
        // Filigree: a strut from the origin out to k, and a rib dropping from
        // k toward the y = 0 mirror; the folds of every level branch them
        // into a tree.
        return tfrWireGlow(r, h, normalize(k), isig2)
             + tfrAxisGlow(r.xz, h.xz, r.y, h.y, isig2);
    }
    // Lattice: the three edges of a box through its corner k, mirrored by
    // abs() into the whole frame. Jacks: the same three axis wires pushed
    // 0.3 past k, so they cross there like jacks instead of meeting.
    float ext = wire == 2 ? 0.3 : 0.0;
    return tfrAxisGlow(r.yz, h.yz, r.x - ext, h.x, isig2)
         + tfrAxisGlow(r.xz, h.xz, r.y - ext, h.y, isig2)
         + tfrAxisGlow(r.xy, h.xy, r.z - ext, h.z, isig2);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float time = u.time * u.speed;

    // --- the map ------------------------------------------------------------
    // Sort once, then per level: abs(), one tilted mirror (through p0,
    // normal nt), the wires, then scale by S about C. The mirror and the wire
    // anchor k drift slowly ("bloom"); the seed picks their phase.
    const float3 c = float3(1.0);
    float ph = u.seed * 37.0;
    float drift = u.bloom;
    float3 nt = normalize(float3(-1.0, 0.3 + u.tilt * 0.9 + 0.25 * drift * sin(time * 0.041 + ph),
                                 1.0 - u.tilt * 0.5 + 0.2 * drift * sin(time * 0.029 + ph * 1.3)));
    float3 p0 = float3(0.6, 0.0, 0.0);
    float3 k = (u.wire == 1 ? float3(1.5, 1.3, 1.1) : u.wire == 2 ? float3(1.25, 1.12, 1.05)
                                                    : float3(1.4, 1.2, 1.08))
             + 0.08 * drift * float3(sin(time * 0.037 + ph * 2.1), sin(time * 0.031 + ph * 0.7),
                                     sin(time * 0.023 + ph * 1.9));

    // Radius of the ball around C on which abs() and the tilted mirror are
    // the identity; the view at phase 1 must fit inside it (see header).
    float rho = min(1.0, dot(c - p0, nt)) - TFR_SOFT;
    float viewScale = 0.9 * rho * TFR_S / (TFR_EYE + TFR_FOG); // world per camera unit

    // --- zoom phase: one map per cycle -------------------------------------
    float phase = fract(time * u.zoom / 60.0 + u.seed * 3.0);
    float worldPerCam = viewScale / pow(TFR_S, phase);

    // --- camera: orbits C slowly in camera space ---------------------------
    float az = u.seed * TWO_PI + time * 0.012;
    float el = sin(time * 0.017 + u.seed * 11.0) * 0.5;
    float3 eye = TFR_EYE * float3(cos(el) * cos(az), sin(el), cos(el) * sin(az));
    float3 fwd = normalize(-eye);
    float3 side = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
    float3 up = cross(fwd, side);
    float2 uv = lerpUV(pos, u.resolution);
    float3 dir = normalize(fwd * 1.5 + uv.x * side + uv.y * up);

    // Per-level weights: a window over (level - phase), zero at both ends,
    // so levels enter at the fine end and leave at the coarse end.
    float lw[TFR_LEVELS];
    for (int n = 0; n < TFR_LEVELS; n++) {
        float kk = float(n) - phase;
        lw[n] = smoothstep(-1.0, 0.0, kk)
              * (1.0 - smoothstep(float(TFR_LEVELS) - 2.0, float(TFR_LEVELS) - 1.0, kk));
    }

    float stride = (TFR_EYE + TFR_FOG) / float(u.steps);
    float pix = 1.5 / u.resolution.y;      // one pixel at unit distance, camera units
    float3 hw = dir * (0.5 * stride * worldPerCam);
    float density = 0.0;
    for (int i = 1; i <= u.steps; i++) {
        float t = float(i) * stride;
        float3 p = c + (eye + dir * t) * worldPerCam;
        float3 h = hw;
        float pixLevel = pix * t * worldPerCam;   // one pixel, in level units
        float glow = 0.0;
        tfrSort(p, h);
        for (int n = 0; n < TFR_LEVELS; n++) {
            tfrFoldAbs(p, h);
            float3 q = p - p0;
            tfrFold(q, h, nt, TFR_SOFT);
            p = q + p0;
            if (lw[n] > 0.0) {
                float sig = max(TFR_SIGMA, pixLevel);
                glow += lw[n] * (TFR_SIGMA / sig) * tfrWires(p, h, k, u.wire, 1.0 / (sig * sig));
            }
            p = TFR_S * (p - c) + c;
            h *= TFR_S;
            pixLevel *= TFR_S;
        }
        float fog = 1.0 - smoothstep(0.35 * TFR_FOG, TFR_FOG, t);
        density += glow * fog;
    }

    float3 finalColor = u.color.rgb * density * u.gain * 0.5;
    // Upstream's sqrt "gamma correction".
    float3 color = sqrt(clamp(finalColor, 0.0, 1.0));
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
