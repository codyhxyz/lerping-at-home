// Kleinian — original shader written for Lerping@Home (AGPL-3.0, like the
// rest of this project). A slow flight through fractals built from sphere
// inversions, written from the published mathematics; no code is copied
// from Shadertoy or any other renderer:
//   - Apollonian packing: fold space into a period-2 cell and invert in a
//     sphere, repeatedly; the running scale turns |y| into a distance
//     estimate (the construction Inigo Quilez describes for his
//     "Apollonian" fractal).
//   - Pseudo-Kleinian: reflect into a box, invert only inside the unit sphere,
//     repeat; render the orbit of a plane (after Knighty's pseudo-Kleinian,
//     fractalforums.com, 2011).
//   - Kleinian group: the Maskit cusp group mu = 2i of Mumford, Series &
//     Wright, "Indra's Pearls" (2002), extended to upper half-space as Jos
//     Leys does for his Kleinian renders: reduce a point into the fundamental
//     domain and measure the pearls there.
//   - Over-relaxed sphere tracing from Keinert et al., "Enhanced Sphere
//     Tracing" (2014).
//
// Fractal (mode):
//   0 Apollonian — endless nested spheres and lace tunnels, flown along a
//     free corridor of the packing (default).
//   1 Pseudo-Kleinian — cave-like halls with pillars and domes.
//   2 Kleinian group — the Apollonian strip packing as a necklace of kissing
//     pearls, flown alongside.
//   3 Zoom — nested lace shells, the Apollonian gasket carried onto each
//     sphere by inverse stereographic projection. The scene is exactly
//     invariant under (scale 2, turn rho), so the endless dive loops
//     seamlessly: tau and tau + 1 render the same image.
// Shape morphs each mode's main constant (inversion strength, seed-plane
// height, lace width). Seed varies the route, look-around, shape and twist.
//
// Camera: every route is periodic in the fractal's own lattice (so the
// position wraps exactly and never loses precision) and was checked offline
// against the distance estimator over the whole shape and seed range: about
// 0.2 world units of clearance in the Apollonian corridor, 0.3 in the
// pseudo-Kleinian hall, 0.65 beside the pearls. The zoom camera rides the
// axis through each shell's pole, which is always the centre of a hole.
//
// Distance must not change the shape. The hit threshold is one pixel
// footprint of the (halved) estimate, which registers a hit ~2 px off the
// surface in the two packings and ~1 px in the other two. At 3 footprints it
// was ~7 px in the packings, so every gap narrower than ~14 px was sealed far
// away and opened as the camera approached. A ray that runs out of steps
// within KL_CREEP footprints of a surface is creeping along it and is shaded
// as a hit; it used to show fog and glow, a speckled boundary that shifted
// from frame to frame wherever the far field ran the march dry. Occlusion is
// probed at a fixed size in the scene, not one that grows with distance.
//
// Cost, for hours at up to 5K: at most 48 steps, over-relaxed; the hit
// threshold is measured at no more than 1600 rows, so 4K and 5K cost what
// 1600 rows do per pixel; 6 / 12 / 16 fixed folds (an early exit on the fold
// scale stopped the loops unrolling and cost more than it saved); one normal
// tap per pixel, shared across the 2x2 quad. Apple M5, LerpPreview --bench at
// 3840x2160, against fractal-multiverse ~8.7 ms and paper-texture ~13 ms in
// the same runs, measured with the old 3-footprint threshold and 44 steps:
// default ~12 ms, Indra's Pearls ~9 ms, Bone Cathedral ~16.5 ms, Zoom
// Forever ~19 ms, Pearl Halls ~19.5 ms. A CPU step-count model (worst lane
// per 32-pixel SIMD group) puts the two packings ~19% above that now, Indra's
// Pearls ~5% and Zoom Forever ~7%.
//
// lerp-param: mode     int   0 3 = 0    "Fractal"
// lerp-param: shape    float 0 1 = 0.5  "Shape"
// lerp-animate: shape    0.3 0.7 period=220
// lerp-param: speed    float 0 3 = 1.0  "Speed"
// lerp-param: material float 0 1 = 0.25 "Bone / iridescent"
// lerp-param: hue      float 0 1 = 0.0  "Hue"
// lerp-param: fog      float 0 1 = 0.5  "Fog"
// lerp-param: glow     float 0 1 = 0.35 "Glow"
//
// lerp-preset: "Pearl Halls"    mode=1, shape=0.3, material=0.0, fog=0.6
// lerp-preset: "Bone Cathedral" mode=1, shape=0.85, material=0.08, hue=0.3, glow=0.2
// lerp-preset: "Indra's Pearls" mode=2, material=0.85, hue=0.12, fog=0.35
// lerp-preset: "Zoom Forever"   mode=3, material=0.55, hue=0.8, glow=0.5

constant int   KL_STEPS = 48;
constant float KL_SHADE_STEPS = 44.0;      // step count that reads as fully occluded / full glow
constant float KL_OMEGA = 1.4;             // over-relaxation (the two packings)
constant float KL_REF_RES = 1600.0;        // rows the hit threshold is measured at, at most
constant float KL_EPS = 1.0;               // hit threshold in pixel footprints
constant float KL_CREEP = 8.0;             // out of steps this close (footprints): a hit
constant int   KL_APO_ITERS = 6;
constant float KL_APO_K = 0.5;             // Apollonian distance-estimate factor
constant float KL_APO_T = 0.03;            // Apollonian sheet half-thickness, per fold scale
constant int   KL_PK_ITERS = 12;
constant float KL_PK_K = 0.5;              // pseudo-Kleinian distance-estimate factor
constant float KL_PK_T = 0.25;             // pseudo-Kleinian sheet half-thickness, per fold scale
constant int   KL_MK_ITERS = 16;           // Kleinian group reduction steps
constant float KL_FOCAL = 1.6;
constant float KL_ZOOM = 2.0;              // shell radius ratio in "Zoom"
constant float KL_SHELL = 0.015;           // shell half-thickness
constant float KL_ZOOM_DEEP = 0.03;        // zoom: stop marching this far in

// d: a safe step; surf: distance to the actual surface (they differ only in
// the Kleinian group, where empty isometric spheres also bound the step).
struct KlSample { float d; float trap; float surf; };

struct KlScene {
    int    mode;
    float  s;        // Apollonian inversion strength
    float  off;      // pseudo-Kleinian seed-plane height
    float  size;     // pseudo-Kleinian inversion radius squared
    float  lace;     // zoom: pattern density
    float  rho;      // zoom: twist per shell
    float  deep;     // zoom: radius at which the march gives up
};

// ---------------------------------------------------------------------------
// Distance estimators

// Apollonian packing: fold into the period-2 cell, invert in the sphere of
// radius sqrt(s), repeat. The surface is the orbit of the plane y = 0.
static inline KlSample klApollo(float3 p, float s) {
    float scale = 1.0, trap = 1e9;
    for (int i = 0; i < KL_APO_ITERS; i++) {
        p = -1.0 + 2.0 * fract(0.5 * p + 0.5);
        float r2 = max(dot(p, p), 1e-6);
        trap = min(trap, r2);
        float k = s / r2;
        p *= k;
        scale *= k;
    }
    KlSample o; o.d = KL_APO_K * (abs(p.y) - KL_APO_T) / scale; o.trap = trap; o.surf = o.d; return o;
}

// Pseudo-Kleinian: reflect into the box [-C, C], invert in the sphere of
// radius sqrt(size) only where that expands, repeat. The surface is the
// orbit of the plane z = off.
//
// The box fold is a reflection, not a wrap, so on its own it is not periodic:
// a point 4C further along x needs two more folds to come home, and spends a
// fold iteration doing it. The camera flies along x through eight 4C periods
// per loop, so by the far half it had shed half its iterations: the hall
// thinned to a bare floor and ceiling (under 5% of pixels changing in two
// seconds for 140 s of each 493 s loop, at speed 1), and the loop's wrap back
// to x = 0 was a hard cut. Wrapping x into [-2C, 2C) first changes nothing
// for |x| < 3C, where one fold already lands in the box, and makes the hall
// exactly 4C-periodic, so every stretch of the route sees the full hall and
// the loop closes seamlessly. Camera clearance is unchanged (0.34 units
// over the shape and size range, checked offline as before).
constant float3 KL_PK_C = float3(0.92436, 0.90756, 0.92436);
static inline KlSample klPseudo(float3 p, float size, float off) {
    float df = 1.0, trap = 1e9;
    p.x = glmod(p.x + 2.0 * KL_PK_C.x, 4.0 * KL_PK_C.x) - 2.0 * KL_PK_C.x;
    for (int i = 0; i < KL_PK_ITERS; i++) {
        p = 2.0 * clamp(p, -KL_PK_C, KL_PK_C) - p;
        float r2 = max(dot(p, p), 1e-6);
        trap = min(trap, r2);
        float k = max(size / r2, 1.0);
        p *= k;
        df *= k;
    }
    KlSample o; o.d = KL_PK_K * (abs(p.z - off) - KL_PK_T) / df; o.trap = trap; o.surf = o.d; return o;
}

// Kleinian group: the Maskit cusp group mu = 2i, generated by b(w) = w + 2
// and a(w) = 1/w + 2i, acting on upper half-space by Poincaré extension.
// Coordinates (x, y, h): w = x + iy, h the height. Reduce the point into the
// fundamental domain (wrap x; half-turn about i; apply a inside the unit
// ball) and measure there. The solid is the orbit of the ball over
// |w - (±1 + i)| < 1, which a maps to itself: the Apollonian strip packing
// as a necklace of kissing pearls.
static inline KlSample klMaskit(float3 p) {
    const float a = 2.0;
    float df = 1.0;
    for (int i = 0; i < KL_MK_ITERS; i++) {
        p.x = glmod(p.x + 1.0, 2.0) - 1.0;
        if (p.y > 0.5 * a) { p.x = -p.x; p.y = a - p.y; }
        float r2 = dot(p, p);
        if (r2 >= 1.0 || p.y < 0.0) break;   // in the domain, or in a wall
        float ir = 1.0 / max(r2, 1e-8);
        p = float3(p.x * ir, a - p.y * ir, p.z * ir);
        df *= ir;
    }
    float sx = p.x < 0.0 ? -1.0 : 1.0;
    float dBall = length(p - float3(sx, 0.5 * a, 0.0)) - 1.0;
    // Every other pearl in this frame lies inside an isometric ball, within
    // the strip and |h| <= 1. The floor keeps rays from stalling on the
    // (empty) isometric spheres themselves.
    float slab = max(max(-p.y, p.y - a), abs(p.z) - 1.0);
    float iso = min(min(length(p) - 1.0, length(p - float3(2.0 * sx, 0.0, 0.0)) - 1.0),
                    min(length(p - float3(0.0, a, 0.0)) - 1.0, length(p - float3(2.0 * sx, a, 0.0)) - 1.0));
    float rest = max(slab, max(iso, 0.03));
    // The orbit trap jumps where a pearl straddles two frames, so pearls get
    // one uniform material instead.
    KlSample o; o.d = min(dBall, rest) / df; o.trap = 0.8; o.surf = dBall / df; return o;
}

// The same strip packing flattened to the plane h = 0, now counting every
// disk as a hole: the pearls and the two walls (and their images). Signed
// distance to the union of disks, in w units (negative inside a disk).
static inline float klGasket(float2 w) {
    const float a = 2.0;
    float df = 1.0;
    for (int i = 0; i < KL_MK_ITERS; i++) {
        w.x = glmod(w.x + 1.0, 2.0) - 1.0;
        if (w.y > 0.5 * a) { w.x = -w.x; w.y = a - w.y; }
        float r2 = dot(w, w);
        if (r2 >= 1.0 || w.y < 0.0) break;
        float ir = 1.0 / max(r2, 1e-8);
        w = float2(w.x * ir, a - w.y * ir);
        df *= ir;
    }
    float sx = w.x < 0.0 ? -1.0 : 1.0;
    float d = min(length(w - float2(sx, 0.5 * a)) - 1.0, min(w.y, a - w.y));
    return d / df;
}

// One lace shell: the unit sphere, thickened, keeping only the gasket
// between the disks. The Apollonian packing reaches the sphere by inverse
// stereographic projection (conformal, so circles stay circles); the +z pole
// sits at the centre of a pearl, so it is always a hole.
constant float KL_STEREO = 1.732;          // pole pearl and both wall caps span 60 degrees
static inline KlSample klShell(float3 q, float lace) {
    float r = length(q);
    float3 dir = q / r;
    float2 w0 = dir.xy / max(1.0 + dir.z, 1e-4);
    float g = klGasket(float2(1.0, 1.0) + KL_STEREO * w0);
    // Distance to the lace in the plane, carried back to the sphere. The
    // projection's scale 2 / (1 + |w0|^2) shrinks away from the pole, so the
    // local scale would overshoot: a plane distance dw is at least the arc
    // 2 (atan(rho + dw) - atan(rho)) on the sphere, and at least that arc's
    // chord in space. A point at radius r < 1 is only r times as far.
    float dw = (-g - lace) / KL_STEREO;
    float rho = length(w0);
    float ang = dw > 0.0 ? 2.0 * (atan(rho + dw) - atan(rho)) : dw * 2.0 / (1.0 + rho * rho);
    float strand = (dw > 0.0 ? 2.0 * sin(0.5 * ang) : ang) * min(r, 1.0);
    KlSample o;
    o.d = max(abs(r - 1.0) - KL_SHELL, strand);
    // The gasket's own trap jumps between frames along a strand; colour by
    // latitude instead, which is continuous over the shell.
    o.trap = 0.35 + 0.55 * (0.5 + 0.5 * dir.z);
    o.surf = o.d;
    return o;
}

// Zoom: lace shells at every radius KL_ZOOM^k, each twisted by rho against
// the last, so the scene is exactly invariant under (scale KL_ZOOM, turn rho).
static inline KlSample klZoom(float3 p, KlScene S) {
    float r = max(length(p), 1e-12);
    // Shells nest forever toward the centre; this far in they are a few
    // pixels across and lost in the fog, so tell the march to stop (trap < 0).
    if (r < S.deep) { KlSample o; o.d = 1.0; o.surf = 1.0; o.trap = -1.0; return o; }
    float lr = log2(r) / log2(KL_ZOOM);
    float lk = floor(lr);
    bool innerFirst = (lr - lk) < 0.5;
    KlSample best; best.d = 1e9; best.trap = 1.0; best.surf = 1e9;
    for (int j = 0; j < 2; j++) {
        float lv = lk + float(innerFirst ? j : 1 - j);
        float sc = exp2(lv * log2(KL_ZOOM));
        // Radial distance alone is a lower bound for the shell; only near
        // the shell is the lace pattern worth evaluating.
        float radial = abs(r - sc) - KL_SHELL * sc;
        if (radial >= best.d) continue;
        if (radial > 0.2 * sc) { best.d = radial; best.surf = radial; best.trap = 1.0; continue; }
        float3 q = p / sc;
        q.xy = rotate(q.xy, lv * S.rho);
        KlSample sm = klShell(q, S.lace);
        sm.d *= sc;
        sm.surf *= sc;
        if (sm.d < best.d) best = sm;
    }
    return best;
}

static inline KlSample klMap(float3 p, KlScene S) {
    if (S.mode == 1) return klPseudo(p.xzy, S.size, S.off);
    if (S.mode == 2) return klMaskit(p.xzy);
    if (S.mode == 3) return klZoom(p, S);
    return klApollo(p, S.s);
}

static inline float3 klPal(float t, float3 d) {
    return 0.5 + 0.5 * cos(TWO_PI * (t + d));
}

// ---------------------------------------------------------------------------

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    // Hit threshold and fold LOD use the footprint of a pixel at no more than
    // KL_REF_RES rows, so a 5K frame costs about what a 1600-row frame does
    // per pixel instead of marching ever closer.
    float pix = 2.0 / (KL_FOCAL * min(min(u.resolution.x, u.resolution.y), KL_REF_RES));
    float r0 = hash11(u.seed * 91.7 + 0.3);
    float r1 = hash11(u.seed * 53.1 + 1.7);
    float r2 = hash11(u.seed * 17.9 + 4.1);

    KlScene S;
    S.mode = clamp(u.mode, 0, 3);
    float shape = clamp(u.shape + 0.3 * (r1 - 0.5), 0.0, 1.0);
    S.s = mix(1.05, 1.40, shape);
    S.off = mix(0.12, 0.65, shape);
    S.size = mix(1.0, 1.1, r2);
    S.lace = mix(0.015, 0.07, shape);
    S.rho = mix(0.3, 1.2, r2);

    float tt = u.time * u.speed + u.seed * 400.0;

    float3 ro, fwd;
    float3 wup = float3(0.0, 1.0, 0.0);
    if (S.mode == 1) {
        float period = 4.0 * KL_PK_C.x;
        float d = glmod(tt * 0.06, period * 8.0);
        float ph = TWO_PI * d / (period * 8.0);
        ro = float3(d, -KL_PK_C.z + 0.12 * sin(3.0 * ph), -0.95 + 0.2 * sin(2.0 * ph + 1.0));
        fwd = normalize(float3(1.0, 0.3 * sin(2.0 * ph + r0 * 6.0), 0.35 * sin(ph + r2 * 6.0)));
    } else if (S.mode == 2) {
        float d = glmod(tt * 0.05, 16.0);
        float ph = TWO_PI * d / 16.0;
        // Klein coordinates (x, y, h) -> world (x, h, y).
        ro = float3(d, 0.45 + 0.15 * sin(2.0 * ph), -0.75 + 0.1 * sin(3.0 * ph));
        fwd = normalize(float3(1.0, -0.15 + 0.1 * sin(ph), 0.9 + 0.3 * sin(2.0 * ph + r0 * 6.0)));
    } else if (S.mode == 3) {
        // Distance to the centre shrinks by KL_ZOOM per unit of tau while the
        // camera turns with the shells, so tau and tau + 1 are the same image.
        float tau = fract(tt * 0.025);
        ro = float3(0.0, 0.0, exp2((0.5 - tau) * log2(KL_ZOOM)));
        // The look-around is built in a frame that turns with tau, so that
        // after one loop it has turned exactly one shell's twist.
        float wob = tt * 0.05;
        float turn = tau * S.rho;
        float3 f0 = normalize(float3(0.25 * sin(wob + r0 * 6.0), 0.25 * sin(1.3 * wob + r1 * 6.0), -1.0));
        float roll = 0.2 * sin(0.7 * wob);
        fwd = float3(rotate(f0.xy, turn), f0.z);
        wup = float3(rotate(float2(sin(roll), cos(roll)), turn), 0.0);
    } else {
        float d = glmod(tt * 0.04, 16.0);
        float ph = TWO_PI * d / 16.0;
        ro = float3(d, 1.0 + 0.08 * sin(2.0 * ph + r0 * 6.0), 1.0 + 0.08 * sin(3.0 * ph));
        fwd = normalize(float3(1.0, 0.45 * sin(ph + r2 * 6.0), 0.55 * sin(2.0 * ph + r1 * 6.0)));
    }
    float3 right = normalize(cross(wup, fwd));
    float3 up = cross(fwd, right);
    float3 rd = normalize(uv.x * right + uv.y * up + KL_FOCAL * fwd);
    float camScale = (S.mode == 3) ? length(ro) : 1.0;
    S.deep = camScale * KL_ZOOM_DEEP;

    // Ray march.
    float tmax = 12.0 * camScale;
    float eps0 = 0.0005 * camScale;
    float t = 0.0;
    float trap = 1.0, dHit = 0.0;
    int steps = 0;
    bool hit = false, ended = false;
    // The last sample taken where the march stood (not an overshoot it
    // stepped back from), for a ray that runs out of steps.
    float tLast = 0.0;
    KlSample last; last.d = 1e9; last.trap = 1.0; last.surf = 1e9;
    // Over-relaxed sphere tracing (Keinert et al. 2014, "Enhanced Sphere
    // Tracing"): step omega * d, and if the new unbounding sphere does not
    // overlap the last one, step back and continue unrelaxed.
    float omega = S.mode <= 1 ? KL_OMEGA : 1.0, prevD = 0.0, stepLen = 0.0;
    for (int i = 0; i < KL_STEPS; i++) {
        float eps = eps0 + KL_EPS * pix * t;
        KlSample sm = klMap(ro + rd * t, S);
        steps = i;
        bool fail = omega > 1.0 && (sm.d + prevD) < stepLen;
        if (fail) {
            t -= stepLen;
            stepLen = 0.0;
            omega = 1.0;
            continue;
        }
        if (sm.trap < 0.0) { ended = true; break; }
        if (sm.surf < eps) { hit = true; trap = sm.trap; dHit = sm.surf; break; }
        tLast = t;
        last = sm;
        stepLen = max(sm.d, 0.5 * eps) * omega;
        prevD = sm.d;
        t += stepLen;
        if (t > tmax) { ended = true; break; }
    }
    // Out of steps still skimming a surface: shade it there rather than
    // letting it fall through to fog, which is what made the far field's
    // edge shift from frame to frame.
    if (!hit && !ended && last.surf < eps0 + KL_CREEP * pix * tLast) {
        hit = true;
        t = tLast;
        trap = last.trap;
        dHit = last.surf;
    }

    // Normal, shared across the 2x2 quad: each lane evaluates one tap of the
    // tetrahedral gradient at its own hit point, and the quad sums them. On a
    // smooth surface the four hit points share a gradient, so this is the
    // usual four-tap estimate for a quarter of the cost. Lanes that missed
    // borrow a hit neighbour's point; a quad with no hit skips it. Everything
    // here runs on all four lanes, as quad operations require.
    float3 n = -rd;
    ushort rank = quad_prefix_exclusive_sum(ushort(1));
    ushort firstHit = quad_min(hit ? rank : ushort(4));
    float3 pHit = ro + rd * t;
    float3 pBase = hit ? pHit : quad_shuffle(pHit, firstHit);
    float dBase = hit ? dHit : quad_shuffle(dHit, firstHit);
    float tBase = hit ? t : quad_shuffle(t, firstHit);
    float eN = quad_max(max(eps0, 0.5 * pix * tBase));
    if (firstHit < 4) {
        float3 k = float3((rank == 0 || rank == 3) ? 1.0 : -1.0,
                          (rank >= 2) ? 1.0 : -1.0,
                          (rank == 1 || rank == 3) ? 1.0 : -1.0);
        float tap = klMap(pBase + k * eN, S).surf - dBase;
        float3 g = quad_sum(k * tap);
        n = (dot(g, g) > 0.0) ? normalize(g) : -rd;
    }

    // --- Shade. Everything is dark-leaning: a single warm key from above the
    // camera, a cool fill, and fog that swallows the distance.
    float3 tint = klPal(u.hue + 0.58, float3(0.0, 0.12, 0.25));      // fog / fill hue
    float3 fogCol = 0.010 * tint + float3(0.002, 0.0025, 0.004);
    float3 col = fogCol;
    // Fog distance; in the zoom it counts shells passed (scale-free), so each
    // deeper shell sits further in the haze.
    float tn = (S.mode == 3) ? 1.6 * log2(camScale / max(length(ro + rd * t), 1e-6 * camScale))
                             : t / camScale;
    float sk = min(float(steps) / KL_SHADE_STEPS, 1.0);   // march effort, for occlusion and glow
    if (hit) {
        float3 p = pHit;
        float ndv = clamp(dot(n, -rd), 0.0, 1.0);
        float tr = clamp(trap, 0.0, 1.0);

        // Occlusion: the orbit trap (points that passed near an inversion
        // centre sit deep inside the packing), the step count, and in the two
        // sparse modes one probe along the normal. The dense packings skip
        // the probe: the trap already carries their occlusion. The probe has
        // a fixed size in the scene (in the zoom, a fixed fraction of the
        // shell it lands on, which keeps the dive self-similar): one that grew
        // with distance shaded far crevices darker than the same crevices
        // close up. These sizes match the old probe at a typical hit.
        float probe = 1.0;
        if (S.mode >= 2) {
            float h = S.mode == 3 ? 0.14 * length(p) : 0.13;
            probe = clamp(klMap(p + n * h, S).surf / h, 0.0, 1.0);
        }
        float occ = probe * mix(0.45, 1.0, sqrt(tr)) * (1.0 - 0.6 * sk);

        // Bone: ivory on the open faces, umber in the folds, with faint
        // marble banding from the trap. Iridescent: a thin-film palette on
        // the viewing angle, over a near-black base.
        float vein = 0.5 + 0.5 * sin(18.0 * tr + 4.0 * sqrt(tr));
        float3 bone = mix(float3(0.20, 0.15, 0.11), float3(0.82, 0.74, 0.60), smoothstep(0.0, 0.9, sqrt(tr)));
        bone *= 0.85 + 0.15 * vein;
        float3 film = klPal(1.4 * (1.0 - ndv) + 0.7 * tr + u.hue, float3(0.0, 0.18, 0.36));
        film = mix(float3(dot(film, float3(0.333))), film, 0.7);
        float3 irid = 0.04 + 0.55 * film * film;
        float3 alb = mix(bone, irid, u.material);

        float3 L = normalize(up * 0.8 + right * 0.35 + fwd * 0.25);
        float dif = clamp(dot(n, L) * 0.8 + 0.2, 0.0, 1.0);
        float spec = pow(clamp(dot(reflect(rd, n), L), 0.0, 1.0), 24.0);
        float rim = pow(1.0 - ndv, 4.0);
        float3 lin = float3(1.0, 0.88, 0.72) * dif * 1.1
                   + tint * (0.20 + 0.15 * dot(n, up)) ;
        col = alb * lin * occ;
        col += (0.10 + 0.45 * u.material) * spec * occ * mix(float3(1.0, 0.9, 0.8), film, u.material);
        col += 0.25 * rim * occ * mix(tint, film, u.material);
        float fogK = mix(0.06, 0.5, u.fog);
        col = mix(col, fogCol, 1.0 - exp(-fogK * tn));
    }
    // Glow: light the march itself, strongest where rays skimmed the surface.
    col += u.glow * 0.10 * sk * sk * klPal(u.hue + 0.55, float3(0.0, 0.15, 0.3));

    col = 1.0 - exp(-1.3 * col);
    col = sqrt(max(col, 0.0));
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
