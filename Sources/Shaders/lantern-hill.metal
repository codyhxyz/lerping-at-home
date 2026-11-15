// Lantern Hill — a night procession of mushroom-folk up a spiral hill.
// Original work for Lerping@Home: the hill, the creatures and every texture
// are procedural and of its own design.
//
// lerp-category: Blocks
//
// Blocky mushroom-folk sprout one by one from a glowing patch of soil at the
// foot of a terraced hill, each carrying a lantern, and climb the ledge that
// winds three times round it to the giant mushroom on the summit, where they
// walk in at its door. The queue moves like a crowd: slow stop-and-go waves
// run back down the line, so the walkers near the top stand while those
// further back are still walking, and little ones keep close behind some of
// the grown ones.
//
// Everything is a function of the clock. A walker's place on the path is its
// slot in the queue plus the wave at its own phase; its height comes from the
// ledge under it, with a hop at each step up; its legs swing with distance
// walked, so they stop when it does. The lanterns light the ledge, the bank
// above it and each other's walkers; the giant mushroom lights the summit.
//
// lerp-param: speed        float 0.2 2   = 1   "Walk speed"
// lerp-param: crowd        float 0.4 1.6 = 1   "Crowd"
// lerp-param: light        float 0.3 2   = 1   "Brightness"
// lerp-param: colorLantern color = (1.0, 0.62, 0.26) "Lanterns"
// lerp-param: yaw          float -180 180 = 0 "Turn"
// lerp-param: pitch        float -25 35   = 0 "Tilt"
// lerp-param: magnify      float -1 0.9   = 0 "Zoom"
//
// lerp-preset: "Lantern Hill" crowd=1
// lerp-preset: Glowworms colorLantern=(0.45, 1.0, 0.62), crowd=1.4
// lerp-preset: Stragglers crowd=0.5, speed=0.7

// --- The hill, in blocks. The ledge is an Archimedean spiral: radius
// R0 - PITCH * φ/2π, climbing CLIMB blocks a turn, for three turns.
constant float LH_R0     = 21.0;
constant float LH_PITCH  = 4.6;
constant float LH_CLIMB  = 4.0;
constant float LH_HW     = 1.3;          // half width of the ledge
constant float LH_TOP    = 12.0;         // summit = CLIMB * 3
constant float LH_PHEND  = 18.849556;    // three turns
constant float LH_REND   = 7.2;          // R0 - 3 * PITCH
constant float LH_K      = 0.36605637;   // PITCH / 4π
constant float LH_SSP    = 265.7787;     // arc length of the spiral
constant float LH_STEM   = 1.5;          // half width of the giant mushroom's stem
constant float LH_SEND   = 271.4787;     // SSP + REND - STEM: the door
constant float LH_BOX    = 27.0;         // the hill fits in |x|, |z| < BOX
constant float LH_YMAX   = 21.0;
constant float LH_CAPY   = 18.0;         // underside of the giant mushroom's cap
constant int   LH_STEPS  = 120;
constant float LH_FOCAL  = 2.0;

// --- The queue.
constant float LH_V   = 0.75;     // mean walking speed, blocks/s
constant float LH_A   = 0.7;      // stop-and-go depth (1 = full stops)
constant float LH_P   = 11.0;     // stop-and-go period, s
constant float LH_LAG = 0.35;     // wave phase per slot back down the line
constant float LH_DM  = 0.9191;   // V * A * P / 2π: how far the wave pushes a walker

// ---------------------------------------------------------------------------

static inline float3 lhLin(float3 c) { return c * c; }
static inline float lhHash3(float3 p) { return hash21(p.xy + p.z * float2(17.17, 31.31)); }

// atan2 to about 1e-5 rad, for less than the library's cost: the march asks
// for one at every column.
static inline float lhAtan2(float y, float x) {
    float ax = abs(x), ay = abs(y);
    float a = min(ax, ay) / max(max(ax, ay), 1e-9);
    float s = a * a;
    float r = ((-0.0464964749 * s + 0.15931422) * s - 0.327622764) * s * a + a;
    r = ay > ax ? 1.57079637 - r : r;
    r = x < 0.0 ? 3.14159274 - r : r;
    return y < 0.0 ? -r : r;
}

static inline float lhArcS(float ph) { return LH_R0 * ph - LH_K * ph * ph; }
static inline float lhArcPhi(float s) {
    return (LH_R0 - sqrt(max(LH_R0 * LH_R0 - 4.0 * LH_K * s, 0.0))) / (2.0 * LH_K);
}

// One column of the hill: its top, and where it lies on the path (s), if it does.
struct LhCell {
    float h;
    float s;      // arc length along the path, or -1e9 off it
    int   kind;   // 0 grass, 1 ledge, 2 the sprouting patch
};

static inline LhCell lhCell(int2 c) {
    LhCell o;
    o.s = -1e9;
    o.kind = 0;
    float2 p = float2(c) + 0.5;
    float r = length(p);
    float phi = lhAtan2(p.y, p.x);
    phi += phi < 0.0 ? TWO_PI : 0.0;
    float a = (LH_R0 - r) / LH_PITCH - phi / TWO_PI;
    const float w = LH_HW / LH_PITCH;
    float fa = floor(a);
    float ramp = smoothstep(w, 1.0 - w, a - fa);
    float h = LH_CLIMB * (phi / TWO_PI + fa + ramp);
    h += (hash21(p * 1.37 + 4.1) - 0.5) * 1.7 * sin(PI * ramp);   // rough banks, flat ledges
    o.h = floor(clamp(h, 0.0, LH_TOP));
    float n = round(a);
    float phu = phi + TWO_PI * n;
    if (abs(a - n) <= w && phu >= -0.2 && phu <= LH_PHEND) {
        o.s = lhArcS(phu);
        o.kind = 1;
        o.h = max(floor(LH_CLIMB * phu / TWO_PI), 0.0);
    }
    if (p.x > LH_STEM && p.x < LH_REND + 1.4 && abs(p.y) < LH_HW) {
        o.s = LH_SSP + (LH_REND - p.x);
        o.kind = 1;
        o.h = LH_TOP;
    }
    if (distance(p, float2(LH_R0, -0.6)) < 2.4) o.kind = 2;
    return o;
}

// ---------------------------------------------------------------------------
// Walkers. Slot j of the queue holds a grown walker (k = 0) and sometimes a
// little one (k = 1) just behind; a few slots are empty.

struct LhWalker {
    float3 p;       // feet
    float3 F, R;    // forward, right
    float  sc;      // world size of one texel
    float  ph;      // stride phase
    float  bob, lz; // body bob, lantern swing (texels)
    float  s;       // arc length along the path
    float  id;
    bool   ok;
};

// Returns !ok for an empty place, and for a walker further than `reach`
// along the path from arc length `sNear` (before the costly part).
static inline LhWalker lhWalker(float j, int k, float tau, float D, float sNear, float reach) {
    LhWalker w;
    w.ok = false;
    if (hash21(float2(j, 11.3)) < 0.12) return w;
    if (k == 1 && hash21(float2(j, 23.9)) > 0.36) return w;
    float2 hj = hash22(float2(j, 3.7));
    float o = hj.x * 0.45;
    float s = LH_V * (tau - LH_A * LH_P / TWO_PI * sin(tau * (TWO_PI / LH_P) - j * LH_LAG))
            - (j + o) * D - float(k) * 0.95;
    if (s < -1.3 || s > LH_SEND + 0.6 || abs(s - sNear) > reach) return w;
    w.ok = true;
    w.s = s;
    w.id = hash21(float2(j, float(k) + 5.1));
    float size = k == 0 ? 0.9 + 0.18 * hj.y : 0.62 + 0.08 * hj.y;
    w.sc = size / 16.0;
    w.ph = s / size * (TWO_PI / 0.6) + w.id * 6.0;
    float sw = sin(w.ph);
    w.bob = 0.7 * abs(sw);
    w.lz = 0.7 * sin(w.ph + 0.8);

    float2 f;
    if (s < LH_SSP) {
        float ph = lhArcPhi(s);
        float r = LH_R0 - LH_PITCH * ph / TWO_PI;
        float c = cos(ph), sn = sin(ph);
        const float dr = -LH_PITCH / TWO_PI;
        f = normalize(float2(dr * c - r * sn, dr * sn + r * c));
        float hc = LH_CLIMB * ph / TWO_PI;
        float base = floor(hc);
        // The next step up the ledge, and how far ahead of the feet it is.
        float d = lhArcS((base + 1.0) * TWO_PI / LH_CLIMB) - s;
        float rise = 1.0 - smoothstep(0.0, 0.5, d);
        float y = base + rise + 0.3 * sin(PI * rise);
        if (s < 0.0) y = s * 1.15;   // still coming up out of the soil
        w.p = float3(r * c, y, r * sn);
    } else {
        w.p = float3(LH_REND - (s - LH_SSP), LH_TOP, 0.0);
        f = float2(0.0, 1.0);
    }
    f = normalize(mix(f, float2(-1.0, 0.0), smoothstep(LH_SSP - 1.2, LH_SSP + 0.4, s)));
    w.F = float3(f.x, 0.0, f.y);
    w.R = float3(f.y, 0.0, -f.x);
    return w;
}

static inline float3 lhLanternPos(LhWalker w) {
    return w.p + (w.R * 4.0 + float3(0.0, 5.0 + w.bob, 0.0) + w.F * (6.0 + w.lz)) * w.sc;
}

// Which slots can hold a walker within `m` of arc length sc.
static inline float2 lhSlots(float S0, float sc, float m, float D) {
    float wc = S0 - sc;
    return float2(ceil((wc - m - LH_DM - 0.45 * D - 0.95) / D), floor((wc + m + LH_DM) / D));
}

struct LhHit {
    float  t;
    float3 n;     // local normal
    float3 q;     // hit point, local texel units
    float3 lo;    // the part's low corner
    int    part;  // 0,1 legs, 2 stalk, 3 cap, 4 cap top, 5 arm, 6 lantern
};

static inline void lhPart(float3 o, float3 d, float3 inv, float3 lo, float3 hi, int id,
                          thread LhHit& h) {
    float3 t1 = (lo - o) * inv, t2 = (hi - o) * inv;
    float3 mn = min(t1, t2), mx = max(t1, t2);
    float tn = max(max(mn.x, mn.y), mn.z), tf = min(min(mx.x, mx.y), mx.z);
    if (tn > tf || tn <= 0.0 || tn >= h.t) return;
    h.t = tn;
    h.part = id;
    h.n = tn == mn.x ? float3(-sign(d.x), 0.0, 0.0)
        : (tn == mn.y ? float3(0.0, -sign(d.y), 0.0) : float3(0.0, 0.0, -sign(d.z)));
    h.q = o + d * tn;
    h.lo = lo;
}

// The walker's boxes, in texels: feet at the origin, +z forward, +x right.
static inline bool lhCreature(float3 ro, float3 rd, LhWalker w, int k, thread LhHit& hit) {
    float3 rel = ro - w.p;
    float is = 1.0 / w.sc;
    float3 o = float3(dot(rel, w.R), rel.y, dot(rel, w.F)) * is;
    float3 d = float3(dot(rd, w.R), rd.y, dot(rd, w.F)) * is;
    d = select(d, float3(1e-6), abs(d) < 1e-6);
    float3 inv = 1.0 / d;
    {
        float3 t1 = (float3(-6.5, -0.5, -6.5) - o) * inv, t2 = (float3(6.5, 17.0, 8.6) - o) * inv;
        float3 mn = min(t1, t2), mx = max(t1, t2);
        float tn = max(max(mn.x, mn.y), mn.z), tf = min(min(mx.x, mx.y), mx.z);
        if (tn > tf || tf <= 0.0 || tn >= hit.t) return false;
    }
    float before = hit.t;
    float sw = sin(w.ph), cw = cos(w.ph);
    float b = w.bob, zs = 1.8 * sw;
    lhPart(o, d, inv, float3(-4.0, max(cw, 0.0) * 1.2, zs - 1.5), float3(-1.0, 4.0 + b, zs + 1.5), 0, hit);
    lhPart(o, d, inv, float3( 1.0, max(-cw, 0.0) * 1.2, -zs - 1.5), float3(4.0, 4.0 + b, -zs + 1.5), 1, hit);
    lhPart(o, d, inv, float3(-3.0, 4.0 + b, -3.0), float3(3.0, 11.0 + b, 3.0), 2, hit);
    lhPart(o, d, inv, float3(-6.0, 11.0 + b, -6.0), float3(6.0, 14.0 + b, 6.0), 3, hit);
    lhPart(o, d, inv, float3(-4.0, 14.0 + b, -4.0), float3(4.0, 16.0 + b, 4.0), 4, hit);
    if (k == 0) {
        lhPart(o, d, inv, float3(3.0, 7.0 + b, -1.0), float3(5.0, 9.0 + b, 6.0), 5, hit);
        lhPart(o, d, inv, float3(2.5, 3.0 + b, 4.5 + w.lz), float3(5.5, 7.0 + b, 7.5 + w.lz), 6, hit);
    }
    return hit.t < before;
}

// ---------------------------------------------------------------------------
// The giant mushroom on the summit.

static inline void lhBoxW(float3 ro, float3 rd, float3 inv, float3 lo, float3 hi, int id,
                          thread float& t, thread float3& n, thread int& part) {
    float3 t1 = (lo - ro) * inv, t2 = (hi - ro) * inv;
    float3 mn = min(t1, t2), mx = max(t1, t2);
    float tn = max(max(mn.x, mn.y), mn.z), tf = min(min(mx.x, mx.y), mx.z);
    if (tn > tf || tn <= 0.0 || tn >= t) return;
    t = tn;
    part = id;
    n = tn == mn.x ? float3(-sign(rd.x), 0.0, 0.0)
      : (tn == mn.y ? float3(0.0, -sign(rd.y), 0.0) : float3(0.0, 0.0, -sign(rd.z)));
}

static inline int lhShroom(float3 ro, float3 rd, float3 inv, thread float& t, thread float3& n) {
    int part = -1;
    const float C = LH_CAPY, W = 5.5;
    {
        float3 t1 = (float3(-W, LH_TOP - 0.5, -W) - ro) * inv, t2 = (float3(W, C + 2.75, W) - ro) * inv;
        float3 mn = min(t1, t2), mx = max(t1, t2);
        if (max(max(mn.x, mn.y), mn.z) > min(min(mx.x, mx.y), mx.z)) return part;
    }
    lhBoxW(ro, rd, inv, float3(-LH_STEM, LH_TOP - 0.5, -LH_STEM), float3(LH_STEM, C, LH_STEM), 0, t, n, part);
    lhBoxW(ro, rd, inv, float3(-W, C, -W), float3(W, C + 1.0, W), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-W + 1.0, C + 1.0, -W + 1.0), float3(W - 1.0, C + 2.0, W - 1.0), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-W + 2.5, C + 2.0, -W + 2.5), float3(W - 2.5, C + 2.75, W - 2.5), 1, t, n, part);
    // A rim hanging from the cap's edge on all four sides.
    lhBoxW(ro, rd, inv, float3(-W, C - 0.5, W - 1.0), float3(W, C, W), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-W, C - 0.5, -W), float3(W, C, -W + 1.0), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(W - 1.0, C - 0.5, -W + 1.0), float3(W, C, W - 1.0), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-W, C - 0.5, -W + 1.0), float3(-W + 1.0, C, W - 1.0), 1, t, n, part);
    return part;
}

// ---------------------------------------------------------------------------
// Light.

struct LhEnv {
    float3 zen, hor, amb, moon, moonDir, lantern, glowCap, glowSpot, capCol;
    float  tau, S0, D, time;
};

// Where a walker's lantern is, without the parts only its body needs: the
// light it casts does not care how its legs or the lantern swing.
static inline bool lhLanternAt(float j, float tau, float D, float lo, float hi, float sNear,
                               thread float3& L) {
    if (hash21(float2(j, 11.3)) < 0.12) return false;
    float2 hj = hash22(float2(j, 3.7));
    float s = LH_V * (tau - LH_A * LH_P / TWO_PI * sin(tau * (TWO_PI / LH_P) - j * LH_LAG))
            - (j + hj.x * 0.45) * D;
    if (s < -1.3 || s > LH_SEND + 0.6 || s < lo || s >= hi || abs(s - sNear) > 3.7) return false;
    float sc = (0.9 + 0.18 * hj.y) / 16.0;
    if (s < LH_SSP) {
        float ph = lhArcPhi(s);
        float r = LH_R0 - LH_PITCH * ph / TWO_PI;
        float c = cos(ph), sn = sin(ph);
        float2 f = float2(-sn, c);                 // near enough the tangent
        float hc = LH_CLIMB * ph / TWO_PI;
        float base = floor(hc);
        float rise = 1.0 - smoothstep(0.0, 0.5, lhArcS((base + 1.0) * TWO_PI / LH_CLIMB) - s);
        float y = s < 0.0 ? s * 1.15 : base + rise;
        L = float3(r * c, y, r * sn) + float3(f.y * 4.0 + f.x * 6.0, 5.35, -f.x * 4.0 + f.y * 6.0) * sc;
    } else {
        L = float3(LH_REND - (s - LH_SSP) - 6.0 * sc, LH_TOP + 5.35 * sc, 4.0 * sc);
    }
    return true;
}

// Lanterns of walkers within reach of arc length sc. `lo`/`hi` keep each
// walker to one of the two stretches of path, so none is counted twice.
static inline float3 lhLanternsNear(float3 P, float3 N, float sc, float lo, float hi, LhEnv E) {
    float3 acc = float3(0.0);
    float2 jr = lhSlots(E.S0, sc, 3.2, E.D);
    for (int q = 0; q < 6; ++q) {
        float j = jr.x + float(q);
        if (j > jr.y) break;
        float3 L;
        if (!lhLanternAt(j, E.tau, E.D, lo, hi, sc, L)) continue;
        L -= P;
        float d2 = dot(L, L);
        float d = sqrt(d2);
        float ndl = dot(N, L / max(d, 1e-3));
        float fall = 1.0 / (1.0 + 2.2 * d2) * (1.0 - smoothstep(2.0, 3.2, d));
        acc += E.lantern * 2.2 * fall * saturate(0.25 + 0.75 * ndl);
    }
    return acc;
}

static inline float3 lhLight(float3 P, float3 N, float faceShade, constant LerpUniforms& u, LhEnv E) {
    float3 l = E.amb * faceShade + E.moon * max(dot(N, E.moonDir), 0.0);

    // Lanterns on the turn of the ledge below this point or the one above,
    // whichever is within a lantern's reach (on a ledge, only its own).
    float r = length(P.xz);
    float phi = lhAtan2(P.z, P.x);
    phi += phi < 0.0 ? TWO_PI : 0.0;
    float a = (LH_R0 - r) / LH_PITCH - phi / TWO_PI;
    float fa = floor(a);
    for (int m = 0; m < 2; ++m) {
        float n = fa + float(m);
        float phu = phi + TWO_PI * n;
        if (phu < -0.4 || phu > LH_PHEND + 0.4) continue;
        float dr = (a - n) * LH_PITCH;
        float dy = P.y - max(LH_CLIMB * phu / TWO_PI, 0.0) - 0.4;
        if (dr * dr + dy * dy > 16.0) continue;
        l += lhLanternsNear(P, N, lhArcS(phu), -2.0, LH_SSP, E);
    }
    // ... and on the walk in across the summit.
    if (P.x > -1.0 && abs(P.z) < 4.5 && r < LH_REND + 3.5 && P.y > LH_TOP - 3.0) {
        float sc = LH_SSP + (LH_REND - clamp(P.x, LH_STEM, LH_REND));
        l += lhLanternsNear(P, N, sc, LH_SSP, 1e9, E);
    }

    // The giant mushroom's gills, and its door.
    float3 G = float3(0.0, LH_CAPY - 1.2, 0.0) - P;
    float g2 = dot(G, G);
    l += E.glowCap * 2.6 / (1.0 + 0.07 * g2) * saturate(0.3 + 0.7 * dot(N, G * rsqrt(g2 + 1e-4)))
       * saturate(LH_CAPY - 0.2 - P.y);   // nothing above the gills sees them
    float3 Dd = float3(2.0, 13.0, 0.0) - P;
    float d2 = dot(Dd, Dd);
    l += E.glowSpot * 1.2 / (1.0 + 0.6 * d2) * saturate(0.3 + 0.7 * dot(N, Dd * rsqrt(d2 + 1e-4)));
    return l * u.light;
}

// ---------------------------------------------------------------------------
// Textures: 16 texels a block, each texel one hashed tone, faded to the
// face's mean once a texel shrinks under a pixel. `fw` is the footprint.

static inline float lhFade(float fw, float texel) { return smoothstep(0.35, 1.1, fw / texel); }

static inline void lhTerrainTex(float3 P, float3 N, LhCell ci, float fw, float time,
                                thread float3& alb, thread float3& emit) {
    emit = float3(0.0);
    float3 tq = floor((P - N * 0.01) * 16.0);
    float hv = lhHash3(tq);
    float ft = lhFade(fw, 1.0 / 16.0);
    bool top = N.y > 0.5;
    float depth = ci.h - P.y;   // below the column's top, for side faces

    const float3 grass = lhLin(float3(0.25, 0.44, 0.17));
    const float3 dirt  = lhLin(float3(0.43, 0.30, 0.20));
    const float3 stone = lhLin(float3(0.42, 0.42, 0.44));
    const float3 path  = lhLin(float3(0.55, 0.47, 0.35));
    const float3 myc   = lhLin(float3(0.47, 0.39, 0.47));

    float3 base, avg;
    if (ci.kind == 1) {
        float edge = depth < 1.0 / 16.0 ? 1.0 : 0.0;
        if (top || edge > 0.5) {
            float3 c = path * (0.8 + 0.4 * hv);
            if (hv > 0.88) c = path * 1.35;
            if (hv < 0.08) c = path * 0.55;
            base = c; avg = path;
        } else {
            base = dirt * (0.8 + 0.4 * hv); avg = dirt;
        }
    } else {
        float3 topCol = ci.kind == 2 ? myc : grass;
        // Grass hangs over the side a jagged 2-4 texels.
        float fringe = (2.0 + floor(3.0 * lhHash3(float3(tq.x, 7.0, tq.z)))) / 16.0;
        if (top) {
            base = topCol * (0.78 + 0.44 * hv); avg = topCol;
            // A few texels of glowing moss (or, on the sprouting patch, spores).
            float glint = lhHash3(tq + 91.0);
            if (glint > (ci.kind == 2 ? 0.93 : 0.988)) {
                float tw = 0.5 + 0.5 * sin(time * 0.8 + glint * 400.0);
                float3 ec = ci.kind == 2 ? float3(0.75, 0.45, 1.0) : float3(0.3, 1.0, 0.8);
                emit = ec * (0.35 + 0.65 * tw) * 0.9 * (1.0 - ft);
                emit += ec * (ci.kind == 2 ? 0.05 : 0.008) * ft;
            }
        } else if (depth < fringe) {
            base = topCol * (0.7 + 0.4 * hv); avg = mix(dirt, topCol, 0.5);
        } else if (depth < 3.0 + 2.0 * lhHash3(float3(floor(P.x), 3.0, floor(P.z)))) {
            base = dirt * (0.78 + 0.44 * hv); avg = dirt;
        } else {
            float3 c = stone * (0.8 + 0.4 * hv);
            if (lhHash3(floor(tq / 2.0) + 5.0) > 0.86) c *= 0.6;
            base = c; avg = stone;
        }
    }
    alb = mix(base, avg, ft);
}

static inline void lhCreatureTex(LhHit h, LhWalker w, float fw, float3 capCol, float3 lantern,
                                 thread float3& alb, thread float3& emit) {
    emit = float3(0.0);
    float3 cell = floor(h.q - h.n * 0.5);          // local texel, absolute
    float3 rc = floor(h.q - h.lo - h.n * 0.5);     // texel within the part
    float hv = lhHash3(cell + w.id * 37.0);
    float ft = lhFade(fw, w.sc);
    const float3 stalk = lhLin(float3(0.86, 0.79, 0.66));
    float3 base, avg;
    if (h.part <= 2 || h.part == 5) {
        float3 c = h.part == 2 ? stalk : stalk * 0.78;
        base = c * (0.86 + 0.28 * hv); avg = c;
        // Two dark eyes on the front of the stalk.
        if (h.part == 2 && h.n.z > 0.5 && rc.y == 4.0 && (rc.x == 1.0 || rc.x == 4.0)) {
            base = float3(0.01, 0.008, 0.01);
        }
        if (h.part == 2 && h.n.z > 0.5 && rc.y == 3.0 && (rc.x == 0.0 || rc.x == 5.0)) {
            base = mix(base, lhLin(float3(0.95, 0.55, 0.55)), 0.5);   // cheeks
        }
    } else if (h.part == 6) {
        // Lantern: an iron frame round glowing panes.
        bool frame = rc.y < 0.5 || rc.y > 2.5 ||
                     (abs(h.n.x) > 0.5 ? (rc.z < 0.5 || rc.z > 1.5) : (rc.x < 0.5 || rc.x > 1.5));
        base = frame ? float3(0.04, 0.035, 0.03) : float3(0.2);
        avg = float3(0.08);
        emit = frame ? float3(0.0) : lantern * 3.2;
        emit = mix(emit, lantern * 1.4, ft);
    } else {
        if (h.n.y < -0.5) {
            // Gills under the cap.
            float g = abs(cell.x) > abs(cell.z) ? cell.z : cell.x;
            base = lhLin(float3(0.62, 0.52, 0.44)) * (fmod(abs(g), 2.0) < 0.5 ? 0.7 : 1.0);
            avg = lhLin(float3(0.62, 0.52, 0.44)) * 0.85;
        } else {
            base = capCol * (0.82 + 0.36 * hv);
            float spot = max(step(0.74, lhHash3(floor(cell / 2.0) + w.id * 11.0)),
                             step(0.95, hv));
            base = mix(base, lhLin(float3(0.93, 0.9, 0.84)), spot);
            avg = mix(capCol, lhLin(float3(0.93, 0.9, 0.84)), 0.28);
        }
    }
    alb = mix(base, avg, ft);
}

static inline void lhShroomTex(float3 P, float3 N, int part, float fw, LhEnv E,
                               thread float3& alb, thread float3& emit) {
    emit = float3(0.0);
    float3 tq = floor((P - N * 0.01) * 16.0);
    float hv = lhHash3(tq + 13.0);
    float ft = lhFade(fw, 1.0 / 16.0);
    if (part == 0) {
        const float3 stem = lhLin(float3(0.8, 0.75, 0.66));
        float streak = lhHash3(float3(tq.x + tq.z * 3.0, 1.0, 0.0));
        alb = mix(stem * (0.8 + 0.2 * streak + 0.15 * hv), stem * 0.92, ft);
        // The door, on the side the path comes in: an arched opening full of light.
        if (N.x > 0.5) {
            float2 d = float2(abs(P.z), P.y - LH_TOP);
            float2 dq = (floor(d * 16.0) + 0.5) / 16.0;
            bool door = dq.x < 0.62 && (dq.y < 1.1 || length(float2(dq.x, dq.y - 1.1)) < 0.62);
            bool trim = !door && dq.x < 0.75 && (dq.y < 1.1 || length(float2(dq.x, dq.y - 1.1)) < 0.75);
            if (door) { alb = float3(0.05); emit = E.glowSpot * (2.4 + 0.5 * hv); }
            if (trim) alb = lhLin(float3(0.35, 0.24, 0.16));
        }
    } else {
        if (N.y < -0.5) {
            // Glowing gills.
            float g = abs(tq.x) > abs(tq.z) ? tq.z : tq.x;
            float stripe = fmod(abs(g), 3.0) < 0.5 ? 0.45 : 1.0;
            alb = float3(0.1);
            emit = E.glowCap * mix(stripe * (0.8 + 0.4 * hv), 0.82, ft) * 1.6;
        } else {
            float3 c = E.capCol * (0.82 + 0.36 * hv);
            // Luminous spots, 3 texels across.
            float3 sq = floor(tq / 4.0);
            float sp = lhHash3(sq + 71.0);
            bool spot = sp > 0.86;
            alb = mix(spot ? float3(0.3) : c, E.capCol * 0.9, ft);
            if (spot) emit = E.glowSpot * (0.45 + 0.15 * sin(E.time * 0.6 + sp * 50.0)) * (1.0 - 0.8 * ft);
            emit += E.capCol * 0.12;   // the whole cap glows faintly
            emit += E.glowSpot * 0.025 * ft;
        }
    }
}

// ---------------------------------------------------------------------------
// Sky.

static inline float3 lhSky(float3 rd, LhEnv E, float pxAngle) {
    float y = rd.y;
    float3 col = mix(E.hor, E.zen, sqrt(saturate(y * 1.2)));
    if (y < 0.0) col = E.hor * 0.85;
    if (y > 0.03) {
        // Square stars on a grid over the sky dome.
        float2 q = rd.xz / (y + 0.3) * 90.0;
        float2 c = floor(q), f = q - c;
        float hs = hash21(c + 7.3);
        if (hs > 0.985) {
            float sz = 0.18 + 0.15 * fract(hs * 91.0);
            float cell = 90.0 * pxAngle / (y + 0.3);   // a pixel in grid units
            float2 e = abs(f - 0.5);
            float on = 1.0 - smoothstep(sz - cell * 0.5, sz + cell * 0.5, max(e.x, e.y));
            float tw = 0.7 + 0.3 * sin(E.time * (0.6 + hs) + hs * 100.0);
            col += float3(0.8, 0.85, 1.0) * on * tw * 0.5 * smoothstep(0.03, 0.2, y)
                 * min(1.0, (2.0 * sz) / max(cell, 1e-4));
        }
    }
    // A square moon of 8 x 8 texels.
    float3 m = E.moonDir;
    float3 mu = normalize(cross(float3(0.0, 1.0, 0.0), m));
    float3 mv = cross(m, mu);
    float dm = dot(rd, m);
    if (dm > 0.0) {
        float2 pm = float2(dot(rd, mu), dot(rd, mv)) / dm;
        const float MS = 0.05;
        float2 a = abs(pm);
        if (max(a.x, a.y) < MS) {
            float2 tq = floor((pm + MS) / (2.0 * MS) * 8.0);
            float hv = hash21(tq + 3.1);
            float crater = hv > 0.78 ? 0.78 : 1.0;
            col = float3(0.85, 0.88, 0.95) * crater * (0.9 + 0.1 * hv);
        } else {
            float dd = max(a.x, a.y) - MS;
            col += E.moon * 0.35 * exp(-dd * 30.0);
        }
    }
    return col;
}

// ---------------------------------------------------------------------------

static inline float3 lhScene(float3 ro, float3 rd, float pxAngle, constant LerpUniforms& u, LhEnv E) {
    float3 rdg = select(rd, float3(1e-6), abs(rd) < 1e-6);
    float3 inv = 1.0 / rdg;

    float tBest = 1e9;
    int what = 0;            // 0 sky, 1 terrain, 2 walker, 3 giant mushroom, 4 far ground
    float3 nW = float3(0.0, 1.0, 0.0);
    int2 hitCell = int2(0);
    LhCell hitInfo;
    hitInfo.h = 0.0; hitInfo.s = -1e9; hitInfo.kind = 0;
    LhHit wh;
    wh.t = 1e9; wh.part = 0; wh.n = float3(0.0); wh.q = float3(0.0); wh.lo = float3(0.0);
    float bestJ = 0.0;
    int bestK = 0;
    float3 glow = float3(0.0);

    // The giant mushroom.
    float tS = 1e9;
    float3 nS = float3(0.0);
    int sPart = lhShroom(ro, rd, inv, tS, nS);

    // March the hill's columns.
    float3 bLo = float3(-LH_BOX, -2.0, -LH_BOX), bHi = float3(LH_BOX, LH_YMAX, LH_BOX);
    float3 t1 = (bLo - ro) * inv, t2 = (bHi - ro) * inv;
    float3 mn = min(t1, t2), mx = max(t1, t2);
    float tIn = max(max(mn.x, mn.y), max(mn.z, 0.0)), tOut = min(min(mx.x, mx.y), mx.z);
    bool terrainHit = false;
    // Flat ground outside the hill's box is met by the plane below; don't let
    // the march start under it.
    float tGround = rd.y < 0.0 ? -ro.y / rd.y : 1e9;
    if (tIn < tOut && tIn < tGround) {
        float t = tIn + 1e-4;
        float2 p = ro.xz + rd.xz * t;
        int2 cell = int2(floor(p));
        int2 stp = int2(rdg.x > 0.0 ? 1 : -1, rdg.z > 0.0 ? 1 : -1);
        float2 tDelta = abs(inv.xz);
        float2 tMax = (float2(cell) + select(float2(0.0), float2(1.0), rdg.xz > 0.0) - ro.xz) * inv.xz;
        int lastAxis = mn.x > mn.z ? 0 : 1;
        float tPrev = tIn;
        float jDoneLo = 1e9, jDoneHi = -1e9;
        for (int i = 0; i < LH_STEPS; ++i) {
            float tNext = min(min(tMax.x, tMax.y), tOut);
            float yE = ro.y + rd.y * tPrev, yX = ro.y + rd.y * tNext;
            // Nothing in this column reaches the ray (the hill is no taller
            // than its cone, plus a walker): step on without looking.
            float rc = length(float2(cell) + 0.5) - 0.71;
            float hBound = clamp(LH_CLIMB * ((LH_R0 - rc) / LH_PITCH + 0.29) + 0.9, 0.0, LH_TOP) + 1.6;
            if (min(yE, yX) > hBound) {
                if (tNext >= tOut) break;
                if (tMax.x < tMax.y) { tPrev = tMax.x; tMax.x += tDelta.x; cell.x += stp.x; lastAxis = 0; }
                else                 { tPrev = tMax.y; tMax.y += tDelta.y; cell.y += stp.y; lastAxis = 1; }
                continue;
            }
            LhCell ci = lhCell(cell);
            float tHit = 1e9;
            float3 n = float3(0.0, 1.0, 0.0);
            if (yE < ci.h) {
                tHit = tPrev;
                n = lastAxis == 0 ? float3(-float(stp.x), 0.0, 0.0) : float3(0.0, 0.0, -float(stp.y));
            } else if (yX < ci.h) {
                tHit = (ci.h - ro.y) / rdg.y;
            }
            // Walkers whose slots reach this column.
            if (ci.s > -1e8) {
                float2 jr = lhSlots(E.S0, ci.s, 1.3, E.D);
                for (int q = 0; q < 5; ++q) {
                    float j = jr.x + float(q);
                    if (j > jr.y) break;
                    // A walker spans two or three columns: each slot is
                    // tested once per pass across a stretch of ledge.
                    if (j >= jDoneLo && j <= jDoneHi) continue;
                    for (int k = 0; k < 2; ++k) {
                        LhWalker w = lhWalker(j, k, E.tau, E.D, 0.0, 1e9);
                        if (!w.ok) continue;
                        wh.t = min(wh.t, tHit);
                        if (lhCreature(ro, rd, w, k, wh)) { bestJ = j; bestK = k; }
                        if (k == 0) {
                            float3 L = lhLanternPos(w);
                            float tc = dot(L - ro, rd);
                            if (tc > 0.0 && tc < min(tHit, tS)) {
                                float3 dv = ro + rd * tc - L;
                                float d2 = dot(dv, dv);
                                float s2 = max(0.012, (tc * pxAngle) * (tc * pxAngle) * 4.0);
                                glow += E.lantern * (0.5 * exp(-d2 / s2) + 0.05 * exp(-d2 * 3.0));
                            }
                        }
                    }
                }
                jDoneLo = jr.x; jDoneHi = jr.y;
            }
            if (tHit < 1e8) {
                terrainHit = true;
                tBest = tHit;
                nW = n;
                hitCell = cell;
                hitInfo = ci;
                break;
            }
            if (wh.t < tNext || tNext >= tOut) break;
            if (tMax.x < tMax.y) { tPrev = tMax.x; tMax.x += tDelta.x; cell.x += stp.x; lastAxis = 0; }
            else                 { tPrev = tMax.y; tMax.y += tDelta.y; cell.y += stp.y; lastAxis = 1; }
        }
    }
    if (terrainHit) what = 1;
    if (wh.t < tBest) { tBest = wh.t; what = 2; }
    if (tS < tBest) { tBest = tS; what = 3; }
    if (what == 0 && rd.y < 0.0) {
        float tg = -ro.y / rd.y;
        if (tg > 0.0) { tBest = tg; what = 4; hitInfo.h = 0.0; hitInfo.kind = 0; nW = float3(0.0, 1.0, 0.0); }
    }

    float3 col;
    float3 P = ro + rd * tBest;
    if (what == 0) {
        col = lhSky(rd, E, pxAngle);
    } else {
        float3 alb, emit, N;
        float face, ao = 1.0;
        if (what == 2) {
            LhWalker w = lhWalker(bestJ, bestK, E.tau, E.D, 0.0, 1e9);
            N = w.R * wh.n.x + float3(0.0, wh.n.y, 0.0) + w.F * wh.n.z;
            float cosi = max(abs(dot(rd, N)), 0.15);
            float pick = fract(w.id * 7.31 + floor(u.seed * 6.0) / 6.0);
            const float3 caps[6] = { float3(0.66, 0.13, 0.09), float3(0.55, 0.33, 0.15),
                                     float3(0.40, 0.20, 0.55), float3(0.13, 0.42, 0.44),
                                     float3(0.72, 0.60, 0.40), float3(0.78, 0.34, 0.44) };
            float3 capCol = lhLin(caps[int(pick * 6.0) % 6]);
            lhCreatureTex(wh, w, tBest * pxAngle / cosi, capCol, E.lantern, alb, emit);
            face = wh.n.y > 0.5 ? 1.0 : (wh.n.y < -0.5 ? 0.45 : (abs(wh.n.x) > 0.5 ? 0.8 : 0.65));
            ao = wh.part <= 1 ? 0.75 : (wh.part == 3 && wh.n.y < -0.5 ? 0.6 : 1.0);
            if (w.s < 0.0) emit += lhLin(float3(0.7, 0.45, 1.0)) * 0.15 * saturate(-P.y * 3.0 + 0.5);
        } else if (what == 3) {
            N = nS;
            float cosi = max(abs(dot(rd, N)), 0.15);
            lhShroomTex(P, N, sPart, tBest * pxAngle / cosi, E, alb, emit);
            face = N.y > 0.5 ? 1.0 : (N.y < -0.5 ? 0.45 : (abs(N.x) > 0.5 ? 0.8 : 0.65));
        } else {
            N = nW;
            float cosi = max(abs(dot(rd, N)), 0.08);
            lhTerrainTex(P, N, hitInfo, tBest * pxAngle / cosi, E.time, alb, emit);
            face = N.y > 0.5 ? 1.0 : (abs(N.x) > 0.5 ? 0.8 : 0.65);
            if (what == 1) {
                if (N.y > 0.5) {
                    // Shade the edges of a top face that meet a taller neighbour.
                    float2 f = P.xz - float2(hitCell);
                    float h = hitInfo.h;
                    // Only the two neighbours on the near sides of the face are asked.
                    int2 sx = int2(f.x < 0.5 ? -1 : 1, 0), sz = int2(0, f.y < 0.5 ? -1 : 1);
                    float ex = f.x < 0.5 ? f.x : 1.0 - f.x, ez = f.y < 0.5 ? f.y : 1.0 - f.y;
                    if (lhCell(hitCell + sx).h > h) ao *= mix(0.55, 1.0, smoothstep(0.0, 0.55, ex));
                    if (lhCell(hitCell + sz).h > h) ao *= mix(0.55, 1.0, smoothstep(0.0, 0.55, ez));
                } else {
                    // ... and the foot of a side face, where it meets the ground.
                    int2 nb = hitCell + int2(int(N.x), int(N.z));
                    float hn = lhCell(nb).h;
                    ao *= mix(0.5, 1.0, smoothstep(0.0, 0.7, P.y - hn));
                }
            }
        }
        float3 lit = lhLight(P + N * 0.02, N, face, u, E);
        col = alb * lit * ao + emit;

        // Fade into the night past the hill.
        float camD = length(ro.xz);
        float fog = 1.0 - exp(-max(tBest - camD + 8.0, 0.0) * 0.022);
        col = mix(col, E.hor * 0.7, fog);
    }

    // A soft halo round the summit.
    float3 gc = float3(0.0, LH_CAPY - 1.0, 0.0) - ro;
    float tc = dot(gc, rd);
    if (tc > 0.0) {
        float3 dv = ro + rd * min(tc, tBest) - float3(0.0, LH_CAPY - 1.0, 0.0);
        col += E.glowCap * 0.05 / (1.0 + 0.05 * dot(dv, dv));
    }
    col += glow;
    return col;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // Frame by the geometric mean of the sides, so a tall screen and a wide
    // one both keep the whole hill without a sea of empty ground or sky.
    float meanRes = sqrt(u.resolution.x * u.resolution.y);
    float pxAngle = 2.0 / (meanRes * LH_FOCAL);

    LhEnv E;
    E.time = u.time;
    E.tau = u.time * u.speed + u.seed * 700.0;
    E.S0 = LH_V * E.tau;
    E.D = 3.3 / u.crowd;
    E.lantern = lhLin(u.colorLantern.rgb);

    // Three nights, by seed.
    int night = int(u.seed * 3.0) % 3;
    float seedB = fract(u.seed * 7.13);
    if (night == 0) {        // indigo
        E.zen = float3(0.004, 0.006, 0.022); E.hor = float3(0.030, 0.045, 0.095);
        E.capCol = lhLin(float3(0.62, 0.12, 0.16));
        E.glowCap = lhLin(float3(1.0, 0.62, 0.42)) * 0.9; E.glowSpot = lhLin(float3(1.0, 0.85, 0.55));
    } else if (night == 1) { // violet
        E.zen = float3(0.012, 0.005, 0.025); E.hor = float3(0.052, 0.026, 0.060);
        E.capCol = lhLin(float3(0.30, 0.18, 0.55));
        E.glowCap = lhLin(float3(0.75, 0.6, 1.0)) * 0.9; E.glowSpot = lhLin(float3(0.7, 1.0, 0.9));
    } else {                 // teal
        E.zen = float3(0.002, 0.010, 0.014); E.hor = float3(0.012, 0.045, 0.052);
        E.capCol = lhLin(float3(0.10, 0.35, 0.40));
        E.glowCap = lhLin(float3(0.5, 1.0, 0.85)) * 0.8; E.glowSpot = lhLin(float3(0.85, 1.0, 0.6));
    }
    E.amb = E.hor * 0.8 + float3(0.004, 0.006, 0.014);
    E.moon = float3(0.05, 0.06, 0.085);
    float ma = seedB * TWO_PI;
    E.moonDir = normalize(float3(cos(ma), 0.75, sin(ma)));

    // A slow orbit round the hill, drifting nearer and higher and back.
    float ct = u.time + u.seed * 977.0;
    float th = u.seed * TWO_PI + ct * (TWO_PI / 720.0);
    // The outward half of the drift is a plain sine; the inward half is
    // eased by tanh so the camera comes no nearer than ~48.2 (the hill filling
    // more of the frame costs GPU time and buys little).
    float dw = sin(ct * (TWO_PI / 260.0));
    dw = dw >= 0.0 ? dw : 0.3 * tanh(dw / 0.3);
    float dist = 50.0 + 6.0 * dw;
    float hgt = 20.0 + 5.0 * sin(ct * (TWO_PI / 330.0) + 1.3);
    float3 target = float3(0.0, 6.5, 0.0);
    float3 ro = float3(dist * cos(th), hgt, dist * sin(th));
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 fwd = normalize(target - ro);
    float3 right = normalize(cross(upHint, fwd));
    lerpOrbit(u.yaw, u.pitch, u.magnify, target, upHint, ro, right, fwd);
    float3 up = cross(fwd, right);

    float2 uv = (2.0 * float2(pos.x, u.resolution.y - pos.y) - u.resolution) / meanRes;
    float3 rd = normalize(uv.x * right + uv.y * up + LH_FOCAL * fwd);
    float3 col = lhScene(ro, rd, pxAngle, u, E);

    col = col / (1.0 + col * 0.6);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
