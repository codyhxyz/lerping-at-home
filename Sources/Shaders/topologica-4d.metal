// Topologica 4D — a remix of "Topologica" by Otavio Good
// https://www.shadertoy.com/view/4djXzz  (2014-08-21), CC0 1.0:
//   License CC0 - http://creativecommons.org/publicdomain/zero/1.0/
//   To the extent possible under law, the author(s) have dedicated all
//   copyright and related and neighboring rights to this software to the
//   public domain worldwide. This software is distributed without any
//   warranty.
//   -Otavio Good
//
// Kept from Topologica: the slowly orbiting camera and its framing, the
// additive glow along each ray, and the colour curve — a glow colour scaled
// past 1.0 and clamped per channel, so cores burn from blue through cyan to
// white — with its sqrt "gamma". New here: the glowing structure is no longer
// noise but four-dimensional geometry, written for this file.
//
//   mode 0  Tesseractic honeycomb. The edges of Z^4 (every axis-parallel line
//           through an integer point) cut by a 3D hyperplane that tilts in
//           two 4D planes and drifts along its normal. An edge glows where it
//           passes within `slab` of the hyperplane, so the edges lying nearly
//           in the slice show as filaments in patches that come and go,
//           split and reconnect as the slice moves; the edges piercing it are
//           the faint nodes in between.
//   mode 1  24-cell honeycomb {3,4,3,3}, the Voronoi tessellation of the D4
//           lattice, cut the same way. Its edges (axis edges and the
//           (1,0,0,0)-(1/2,1/2,1/2,1/2) diagonals of every 24-cell) also run
//           on whole straight lines.
//   mode 2  Hopf fibration. Great circles of S^3 on nested tori — the fibres
//           over rings of latitude of the base S^2, as dense on every torus as
//           on the Clifford torus — stereographically projected to R^3:
//           linked Villarceau circles. S^3 turns slowly in two planes that mix
//           its two complex coordinates, carrying fibres through the
//           projection pole, so circles swell into lines through infinity and
//           come back.
//   mode 3  Torus-knot weave. (knotP, knotQ) torus knots on the same nested
//           tori (the curves q*alpha - p*beta = const), each linked with its
//           neighbours in and out, under the same rotation of S^3. `fibers`
//           above 1 draws that many parallel copies on each torus: a torus
//           link.
//
// Rendering. Topologica marches a fixed stride and lets coarse samples of a
// singular density draw its contours. Here the march only has to find the
// lines and curves passing near each ray; each one found adds its glow along
// the whole ray in closed form (`t4dGlow`), so filaments a fraction of a pixel
// wide are drawn whole and unaliased, whichever sample finds them.
// - Lattices: every edge line is an axis line through the integer points of
//   some frame (the 24-cell's in three frames, related by D4's triality), so
//   per family the nearest line is a rounding, the ray-line integral is exact
//   and a fixed stride of 0.6 cells finds every line that can show.
// - Curves of S^3: the march steps by distance. For each curve passed, the
//   nearest sample's tangent line (derivative and tangent pulled back through
//   the stereographic projection) predicts the closest approach, one more
//   look there measures it, and that measurement sets the glow.
//
// Parameters: `slab`, `cells`, `tilt` and `drift` shape the lattices;
// `rings`, `fibers`, `knotP` and `knotQ` the curves; `turn` sets the pace of
// the 4D rotation in both. All are added by this remix except `color`,
// `speed`, `gain` and `steps`, which keep Topologica's port's meanings (gain
// rescaled to the new glow, steps now counting lattice strides).
//
// GPU cost at 3840x2160 on an M5 (`LerpPreview --bench --looks`), against
// 16 ms for topologica in the same runs: tesseract 7 ms, 24-cell 11 ms,
// torus knots 12 ms, Hopf 15 ms.
//
// `seed` picks the lattice's 3D orientation (and so the planes the two tilts
// turn in), the lattice offset, the phases of the tilts and of the S^3
// rotation, and the starting orbit.
//
// lerp-param: mode     int 0 3          = 0                "Geometry"
// lerp-param: color    color            = (0.01, 0.1, 1.0) "Glow colour"
// lerp-param: color2   color            = (0.01, 0.1, 1.0) "Second colour"
// lerp-param: dichroic float 0 1        = 0.0              "Dichroic mix"
// lerp-param: speed    float 0 4        = 1.0              "Speed"
// lerp-param: gain     float 10 3000    = 800              "Glow gain"
// lerp-param: width    float 0.002 0.04 = 0.006            "Filament width"
// lerp-param: slab     float 0.02 0.5   = 0.15             "Slice thickness"
// lerp-param: cells    float 0.3 3      = 1.0              "Lattice density"
// lerp-param: tilt     float 0 1.2      = 0.45             "Slice tilt"
// lerp-param: drift    float 0 1        = 0.3              "Slice drift"
// lerp-param: turn     float 0 4        = 1.0              "4D rotation rate"
// lerp-param: rings    int 1 6          = 4                "Nested tori"
// lerp-param: fibers   int 1 16         = 8                "Curves per torus"
// lerp-param: knotP    int 1 7          = 2                "Knot p"
// lerp-param: knotQ    int 1 9          = 3                "Knot q"
// lerp-param: steps    int 8 64         = 16               "March steps"
//
// lerp-preset: "24-Cell Honeycomb" mode=1
// lerp-preset: "Hopf Fibration"    mode=2, color=(0.9, 0.06, 0.6), color2=(0.04, 0.6, 1.0), dichroic=1.0
// lerp-preset: "Torus-Knot Weave"  mode=3, fibers=1, color=(1.0, 0.25, 0.04), color2=(1.0, 0.55, 0.12), dichroic=1.0
// lerp-preset: "Dichroic Lattice"  mode=0, color=(0.9, 0.06, 0.6), color2=(0.04, 0.6, 1.0), dichroic=1.0

constant float T4D_HALF_PI = 1.57079632679;

static float2 t4dTurn(float2 v, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// Glow of one line along the ray, in closed form: the integral over
// y in [y0, y0 + L] of w^3 / (d^2 + w^2)^2, where the squared distance to the
// line is b2 + A y^2 (y measured from the ray's closest approach). A full
// perpendicular crossing at b = 0 gives pi/2 whatever the width, so `gain`
// reads the same at any width; across a line the profile falls as 1/b^3,
// which keeps the space between lines dark.
static float t4dGlow(float b2, float A, float y0, float L, float w) {
    float B = b2 + w * w;
    float sAB = sqrt(A * B);
    float y1 = y0 + L;
    float F1 = y1 / (A * y1 * y1 + B) + atan(y1 * A / sAB) / sAB;
    float F0 = y0 / (A * y0 * y0 + B) + atan(y0 * A / sAB) / sAB;
    return (F1 - F0) * w * w * w / (2.0 * B);
}

// ---- Lattice slices -------------------------------------------------------

// The linear part of the slice: slice coordinates (x, y, z, w-offset) to
// lattice coordinates. A seeded 3D orientation, then the two tilts, which
// turn the slice in the (x,w) and (y,w) planes.
static float4 t4dSliceMap(float4 v, float3 ang) {
    v.xz = t4dTurn(v.xz, ang.z);
    v.yz = t4dTurn(v.yz, ang.z * 1.618 + 0.7);
    v.xw = t4dTurn(v.xw, ang.x);
    v.yw = t4dTurn(v.yw, ang.y);
    return v;
}

// One frame of axis-parallel lines through the integer points, as four
// families, one per axis, handled side by side in the lanes of a float4.
// `dir` and `nrm` are the ray and the slice normal in this frame; what
// depends only on them is worked out once per pixel.
struct T4DFrame {
    float4 dir;
    float4 nrm;
    float4 invA;     // 1 / (ray speed across each family)^2
    float4 dirN;     // dir * nrm
    float4 weight;   // edges piercing the slice steeply show only as nodes
    float4 last;     // the rounded sample of the last step
};

static T4DFrame t4dFrame(float4 dir, float4 nrm) {
    T4DFrame fr;
    fr.dir = dir;
    fr.nrm = nrm;
    fr.invA = 1.0 / max(1.0 - dir * dir, 0.02);
    fr.dirN = dir * nrm;
    float4 inSlice = 1.0 - nrm * nrm;
    fr.weight = inSlice * inSlice;
    fr.last = float4(1e6);
    return fr;
}

// One line's glow, its fade with depth and its presence in the slab.
static float3 t4dLine(float b3, float A, float h, float tcl, float weight, float tint,
                      float maxC, float w, float slab2, float3 c1, float3 c2) {
    float g = t4dGlow(max(b3, 0.0), A, -tcl, maxC, w);
    float depth = clamp(tcl, 0.0, maxC);
    float fade = 1.0 - depth / maxC;
    fade *= fade * smoothstep(0.1, 1.5, depth);
    return mix(c1, c2, tint) * (g * fade * weight * exp(-h * h / slab2));
}

// Within a family the nearest line is just the rounded other three
// coordinates, and along a ray that rounding only ever moves on, so a line is
// met over one unbroken run of samples: the first sample of the run adds the
// line's glow along the whole ray, in closed form, and the rest of the run
// sees the same rounding and adds nothing. Every quantity used belongs to the
// line and the ray, not to the sample, so every sample of the run would
// compute the same glow and the picture has no seams.
static float3 t4dFamilies(float4 y, thread T4DFrame& fr, float tc,
                          float maxC, float w, float slab2, float3 c1, float3 c2) {
    float4 r = round(y);
    float4 f = y - r;
    // Family i has moved to a new line when any coordinate but the i-th
    // rounds differently from the last step.
    float4 moved = select(float4(0.0), float4(1.0), r != fr.last);
    float4 newLine = (moved.x + moved.y + moved.z + moved.w) - moved;
    fr.last = r;

    float4 od = dot(f, fr.dir) - f * fr.dir;
    float4 s = od * fr.invA;                    // sample minus closest approach
    float4 b2 = (dot(f, f) - f * f) - od * s;   // squared 4D miss distance
    // Height of the line above the slice where it passes the ray, and the
    // miss distance within the slice.
    float4 h = (dot(f, fr.nrm) - f * fr.nrm) + s * fr.dirN;
    float4 b3 = b2 - h * h;
    // Skip lines too far off (15 widths in the slice, 2.5 slab heights off
    // it) to add more than a faint trace.
    bool4 fresh = (newLine > 0.5) & (b3 < 225.0 * w * w) & (h * h < 6.25 * slab2) & (fr.weight > 0.02);

    float3 acc = float3(0.0);
    if (any(fresh)) {
        float4 A = 1.0 / fr.invA;
        float4 tcl = tc - s;
        // Dichroic tint: how end-on the ray sees the family.
        float4 tint = abs(fr.dir);
        if (fresh.x) acc += t4dLine(b3.x, A.x, h.x, tcl.x, fr.weight.x, tint.x, maxC, w, slab2, c1, c2);
        if (fresh.y) acc += t4dLine(b3.y, A.y, h.y, tcl.y, fr.weight.y, tint.y, maxC, w, slab2, c1, c2);
        if (fresh.z) acc += t4dLine(b3.z, A.z, h.z, tcl.z, fr.weight.z, tint.z, maxC, w, slab2, c1, c2);
        if (fresh.w) acc += t4dLine(b3.w, A.w, h.w, tcl.w, fr.weight.w, tint.w, maxC, w, slab2, c1, c2);
    }
    return acc;
}

// The orthogonal (and symmetric, so self-inverse) map that takes the four
// mutually orthogonal diagonals (1/2)(+-1,+-1,+-1,+-1) with an even number of
// minus signs onto the coordinate axes. It preserves D4 and carries the
// 24-cell honeycomb's even diagonal edge lines onto the axis lines through
// the half-integer points.
static float4 t4dHad(float4 v) {
    return 0.5 * float4(v.x + v.y + v.z + v.w, v.x + v.y - v.z - v.w,
                        v.x - v.y + v.z - v.w, v.x - v.y - v.z + v.w);
}

// ---- Curves on the nested tori of S^3 ---------------------------------------

static float2 t4dCmul(float2 a, float2 b) {
    return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

// One 4D rotation of S^3, applied to a column. Two seeded fixed turns, then
// the time-varying pair in (0,2) and (1,3) — planes that mix z1 = (x0, x1)
// with z2 = (x2, x3), so curves are carried from torus to torus.
static float4 t4dS3Turn(float4 v, float4 ang) {
    v.xw = t4dTurn(v.xw, ang.z);
    v.yz = t4dTurn(v.yz, ang.w);
    v.xz = t4dTurn(v.xz, ang.x);
    v.yw = t4dTurn(v.yw, ang.y);
    return v;
}

struct T4DCurve {
    float d;      // S^3 distance to the nearest drawn curve
    float id;     // which curve: torus * 64 + copy
    float hue;    // colour phase of that curve
    float dE;     // distance across tori
    float dTg;    // distance along the torus, over |grad psi|
    float safe;   // no drawn curve on any torus is nearer than this
};

// x on S^3, torus coordinates |z1| = cos(eta), |z2| = sin(eta). A (p, q)
// curve on a torus is q*alpha - p*beta = const (the Hopf fibres are the
// (1, 1) curves); psi = arg(z1^q * conj(z2)^p) is that phase without two
// separate angles. Distance: across tori in eta, along the torus in psi
// over |grad psi|.
static T4DCurve t4dTori(float4 x, int P, int Q, int K, int F, bool hopf, float phase) {
    float r1 = max(length(x.xy), 1e-5), r2 = max(length(x.zw), 1e-5);
    float eta = atan2(r2, r1);
    float fk = float(K);
    float k = clamp(floor(eta / T4D_HALF_PI * fk), 0.0, fk - 1.0);
    float etaK = (k + 0.5) * T4D_HALF_PI / fk;

    float2 u1 = x.xy / r1;
    float2 u2 = float2(x.z, -x.w) / r2;
    float2 c = float2(1.0, 0.0);
    for (int i = 0; i < Q; i++) c = t4dCmul(c, u1);
    for (int i = 0; i < P; i++) c = t4dCmul(c, u2);
    float psi = atan2(c.y, c.x);

    float pf = float(P), qf = float(Q);
    float se = sin(etaK), ce = cos(etaK);
    float n = hopf ? max(1.0, round(float(F) * 2.0 * se * ce)) : float(F);
    float sp = (psi - phase - k * 0.9) * n / TWO_PI;
    float j = round(sp);
    float dPsi = (sp - j) * TWO_PI / n;
    float gradPsi = sqrt(qf * qf * se * se + pf * pf * ce * ce) / (se * ce);
    float dT = dPsi / gradPsi;
    float dE = eta - etaK;

    T4DCurve cv;
    cv.d = sqrt(dE * dE + dT * dT);
    float jm = glmod(j, n);
    cv.id = k * 64.0 + jm;
    cv.hue = TWO_PI * jm / n + k * 1.7;
    cv.dE = dE;
    cv.dTg = dT / gradPsi;
    // Curves on the next torus out or in are at least their torus's eta
    // away, which can be nearer than this torus's own curve when that one
    // is sparse (a single knot); stepping must respect both.
    cv.safe = min(cv.d, T4D_HALF_PI / fk - abs(dE));
    return cv;
}

// Half the gradient of d^2 on S^3 at x, for the curve `cv` found there.
static float4 t4dToriGrad(float4 x, T4DCurve cv, int P, int Q) {
    float r1s = max(dot(x.xy, x.xy), 1e-10), r2s = max(dot(x.zw, x.zw), 1e-10);
    float q12 = sqrt(r2s / r1s);
    float4 gEta = float4(-q12 * x.xy, x.zw / q12);
    float4 gPsi = float4(float(Q) * float2(-x.y, x.x) / r1s, -float(P) * float2(-x.w, x.z) / r2s);
    return cv.dE * gEta + cv.dTg * gPsi;
}

// What the S^3 march holds fixed across a pixel.
struct T4DS3 {
    float4 m0, m1, m2, m3;  // columns of the rotation of S^3
    int P, Q, K, F;
    bool hopf;
    float phase;
};

// What the S^3 march knows about one point of the ray.
struct T4DSample {
    T4DCurve cv;
    float3 p;               // the point, in R^3
    float4 x;               // the point on S^3, rotated
    float dR;               // distance to the curve, R^3 units
    float cf;               // R^3 length per S^3 length
    float s;                // ray parameter minus predicted closest approach
    float b2;               // predicted squared miss distance
    float A;                // squared ray speed across the curve
};

static T4DSample t4dLook(float3 ro, float3 rd, float t, thread const T4DS3& g) {
    T4DSample sm;
    sm.p = ro + rd * t;
    float pp = dot(sm.p, sm.p);
    float inv = 1.0 / (1.0 + pp);
    float4 x0 = float4(2.0 * sm.p * inv, (pp - 1.0) * inv);
    sm.x = g.m0 * x0.x + g.m1 * x0.y + g.m2 * x0.z + g.m3 * x0.w;
    sm.cv = t4dTori(sm.x, g.P, g.Q, g.K, g.F, g.hopf, g.phase);
    sm.cf = 0.5 * (1.0 + pp);
    sm.dR = sm.cv.d * sm.cf;
    sm.s = 0.0;
    sm.A = 1.0;
    sm.b2 = sm.dR * sm.dR;
    return sm;
}

// The closest approach the curve's tangent line predicts, which only the best
// sample of each curve needs.
static void t4dPredict(thread T4DSample& sm, float3 rd, thread const T4DS3& g) {
    float3 p = sm.p;
    float4 x = sm.x;
    float pp = dot(p, p);
    float inv = 1.0 / (1.0 + pp);
    // d(x)/dt along the ray, pushed through the rotation.
    float pr = dot(p, rd);
    float4 dx0 = float4(2.0 * inv * (rd - 2.0 * pr * inv * p), 4.0 * pr * inv * inv);
    float4 dx = g.m0 * dx0.x + g.m1 * dx0.y + g.m2 * dx0.z + g.m3 * dx0.w;
    // The curve's tangent, pulled back to R^3.
    float4 tang = float4(float(g.P) * float2(-x.y, x.x), float(g.Q) * float2(-x.w, x.z));
    float4 tg = float4(dot(g.m0, tang), dot(g.m1, tang), dot(g.m2, tang), dot(g.m3, tang));
    float3 T3 = normalize(tg.xyz + p * tg.w);
    float ct = dot(T3, rd);
    sm.A = max(1.0 - ct * ct, 0.1);
    // d(dR^2)/dt, dR = d * cf: both factors change along the ray.
    float slope = 2.0 * sm.cf * (sm.cf * dot(t4dToriGrad(x, sm.cv, g.P, g.Q), dx) + sm.cv.d * sm.cv.d * pr);
    sm.s = slope / (2.0 * sm.A);
    // The tangent line's prediction, but no nearer than distance can shrink
    // (at most 1:1 along the ray) on the way to the predicted point.
    float near = max(sm.dR - abs(sm.s), 0.0);
    sm.b2 = max(sm.dR * sm.dR - sm.A * sm.s * sm.s, near * near);
}

// The glow of a sample's curve along the whole ray.
static float3 t4dCurveGlow(T4DSample sm, float t, float maxDepth, float w, float3 c1, float3 c2) {
    float tClose = t - sm.s;
    float fade = 1.0 - clamp(tClose, 0.0, maxDepth) / maxDepth;
    // A tube of constant S^3 width swells with cf in R^3; let it swell by
    // sqrt(cf) only and dim by cf, so the vast outer circles stay a fine
    // backdrop to the core.
    float g = t4dGlow(sm.b2, sm.A, -tClose, maxDepth, w * sqrt(sm.cf)) / sm.cf;
    return mix(c1, c2, 0.5 + 0.5 * cos(sm.cv.hue)) * (g * fade * fade);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // Topologica's camera: uv in [-1, 1], y up, a slow orbit about the origin.
    float2 frag = float2(pos.x, u.resolution.y - pos.y);
    float2 uv = frag / u.resolution * 2.0 - 1.0;
    float time = u.time * u.speed;
    bool lattice = u.mode < 2;

    float mx = u.seed * TWO_PI + time * 0.02;
    float my = sin(time * 0.03 + u.seed * 17.0) * 0.2 + 0.2;
    float camDist = lattice ? 5.0 : 2.6;
    float3 camPos = float3(cos(my) * cos(mx), sin(my), cos(my) * sin(mx)) * camDist;

    float3 camVec = normalize(-camPos);
    float3 sideNorm = normalize(cross(float3(0.0, 1.0, 0.0), camVec));
    float3 upNorm = cross(camVec, sideNorm);
    float3 rd = normalize(camVec + uv.x * sideNorm * (u.resolution.x / u.resolution.y) + uv.y * upNorm);

    float3 c1 = u.color.rgb;
    float3 c2 = mix(c1, u.color2.rgb, u.dichroic);
    float3 acc = float3(0.0);
    int steps = u.steps;
    float rt = time * u.turn;

    if (lattice) {
        // Slice -> lattice is affine, so each ray is a straight line in 4D.
        float3 ang = float3(u.tilt * sin(rt * 0.031 + u.seed * 41.0),
                            u.tilt * cos(rt * 0.019 + u.seed * 23.0),
                            u.seed * 9.7);
        // The drift moves the lattice along its w axis, nearly the slice
        // normal; (0,0,0,2) is a symmetry of both lattices, so wrap it there
        // and the coordinates stay small however long the saver runs.
        float drift = glmod(time * u.drift * 0.06 + u.seed * 5.0, 2.0);
        float4 shift = float4(hash11(u.seed * 31.0), hash11(u.seed * 57.0),
                              hash11(u.seed * 77.0), drift);
        float4 q0 = t4dSliceMap(float4(camPos * u.cells, 0.0), ang) + shift;
        float4 dir = t4dSliceMap(float4(rd, 0.0), ang);
        float4 nrm = t4dSliceMap(float4(0.0, 0.0, 0.0, 1.0), ang);
        float slab2 = u.slab * u.slab;
        // A fixed stride of 0.6 cells. A family's lines own unit cubes of its
        // other three coordinates, so any line passing within 0.4 cells of
        // the ray (as close as a line can and still show) owns a run of it
        // at least 0.6 long and cannot be stepped over. The 24-cell, with
        // three times the lines, marches half as deep.
        const float stepC = 0.6;
        int n = u.mode == 0 ? steps : steps / 2;
        float maxC = stepC * float(n);           // depth, in cells
        // 24-cell honeycomb: its edges are the axis lines through the
        // half-integer points (the tesseract's, shifted) in three frames —
        // the axes, the even diagonals (t4dHad) and the odd diagonals (t4dHad
        // after flipping w). The D4 lattice's triality, in one line each.
        float4 flip = float4(1.0, 1.0, 1.0, -1.0);
        T4DFrame f0 = t4dFrame(dir, nrm);
        T4DFrame f1 = t4dFrame(t4dHad(dir), t4dHad(nrm));
        T4DFrame f2 = t4dFrame(t4dHad(dir * flip), t4dHad(nrm * flip));
        float w = u.width;
        for (int i = 0; i < n; i++) {
            float tc = float(i) * stepC;
            float4 q = q0 + tc * dir;
            if (u.mode == 0) {
                acc += t4dFamilies(q, f0, tc, maxC, w, slab2, c1, c2);
            } else {
                acc += t4dFamilies(q - 0.5, f0, tc, maxC, w, slab2, c1, c2);
                acc += t4dFamilies(t4dHad(q) - 0.5, f1, tc, maxC, w, slab2, c1, c2);
                acc += t4dFamilies(t4dHad(q * flip) - 0.5, f2, tc, maxC, w, slab2, c1, c2);
            }
        }
    } else {
        float4 ang = float4(rt * 0.043 + u.seed * 11.0, rt * 0.029 + u.seed * 29.0,
                            u.seed * 7.3, u.seed * 13.1);
        T4DS3 g;
        // Columns of the rotation, built once per pixel.
        g.m0 = t4dS3Turn(float4(1, 0, 0, 0), ang);
        g.m1 = t4dS3Turn(float4(0, 1, 0, 0), ang);
        g.m2 = t4dS3Turn(float4(0, 0, 1, 0), ang);
        g.m3 = t4dS3Turn(float4(0, 0, 0, 1), ang);
        g.hopf = u.mode == 2;
        g.P = g.hopf ? 1 : u.knotP;
        g.Q = g.hopf ? 1 : u.knotQ;
        g.K = u.rings;
        g.F = u.fibers;
        g.phase = rt * 0.05;
        const float maxDepth = 7.0;
        // The curves take a quarter more samples than the lattices: each is
        // found by distance, not by a fixed stride.
        int n = (steps * 5) / 4;
        float minStep = maxDepth / float(n) * 0.5;
        // The curve being passed: its best sample so far, and that sample's
        // ray parameter and step.
        T4DSample best;
        float bestT = 0.0, bestL = 0.0;
        bool have = false;
        // Distance to the current curve at the last sample, and whether it
        // has started growing: if it then shrinks again the ray is coming up
        // on another strand of the same curve (a knot passes a point many
        // times), which is a new pass with its own glow.
        float prevD = 0.0;
        bool rising = false;
        float t = 0.0;
        for (int i = 0; i <= n; i++) {
            bool done = i == n || t > maxDepth;
            T4DSample sm;
            if (!done) sm = t4dLook(camPos, rd, t, g);
            bool newPass = false;
            if (have && !done && sm.cv.id == best.cv.id) {
                if (sm.dR > prevD * 1.02) rising = true;
                else if (rising && sm.dR < prevD * 0.98) newPass = true;
            }
            if (have && (done || newPass || sm.cv.id != best.cv.id)) {
                // A curve no sample came within 24 tube widths of adds too
                // little to look at again (the samples step by distance, so
                // none passes a curve much nearer than its nearest sample).
                float far = 24.0 * u.width * sqrt(best.cf);
                if (best.dR < far) {
                    // Leaving a curve: look once more where its best sample
                    // put the closest approach, and keep that if it is nearer.
                    // Each curve's glow then comes from a sample right at its
                    // closest approach, so neighbouring pixels agree.
                    t4dPredict(best, rd, g);
                    float t2 = max(clamp(bestT - best.s, bestT - 1.5 * bestL, bestT + 1.5 * bestL), 0.0);
                    T4DSample r = t4dLook(camPos, rd, t2, g);
                    if (r.cv.id == best.cv.id && r.dR < best.dR) {
                        // There, the measured distance is the miss distance.
                        r.A = best.A;
                        best = r;
                        bestT = t2;
                    }
                    // A prediction the second look did not bear out (the
                    // curve was not there) cannot claim a miss much nearer
                    // than any distance actually measured.
                    float seen = best.dR * 0.5;
                    best.b2 = max(best.b2, seen * seen);
                    acc += t4dCurveGlow(best, bestT, maxDepth, u.width, c1, c2)
                         * smoothstep(far, 0.6 * far, best.dR);
                }
                have = false;
            }
            if (done) break;
            float L = max(0.75 * sm.cv.safe * sm.cf, minStep);
            if (!have || sm.dR < best.dR) {
                best = sm;
                bestT = t;
                bestL = L;
                if (!have) rising = false;
                have = true;
            }
            prevD = sm.dR;
            t += L;
        }
    }
    // Topologica's finish: clamp per channel, then its sqrt "gamma".
    float3 color = sqrt(clamp(acc * u.gain / 100.0, 0.0, 1.0));
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
