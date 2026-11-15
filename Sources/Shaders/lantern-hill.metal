// Lantern Hill — a night procession of mushroom-folk up a spiral hill.
// Original work for Lerping@Home, drawn with the game's own block textures
// (lerp-requires: minecraft; see PORTING.md). The walkers are this look's own
// creatures, not the game's mobs, built from its mushroom and lantern blocks.
//
// lerp-category: Minecraft
// lerp-requires: minecraft
//
// Mushroom-folk come up one by one through a patch of mycelium at the foot of
// a terraced grass hill, each carrying a lantern, and climb the dirt-path
// ledge that winds three times round it to the giant mushroom on the summit,
// where they walk in at a glowstone door. The queue moves like a crowd: slow
// stop-and-go waves run back down the line, so the walkers near the top stand
// while those further back are still walking, and little ones keep close
// behind some of the grown ones.
//
// Everything is a function of the clock. A walker's place on the path is its
// slot in the queue plus the wave at its own phase; its height comes from the
// ledge under it, with a hop at each step up; its legs swing with distance
// walked, so they stop when it does. Light works as the game's does: fixed
// shading per face, a little darkening in corners, and block light falling a
// level a block from each lantern, the shroomlights under the giant cap and
// the glowstone door, over the moon's sky light.
//
// lerp-param: speed    float 0.2 2   = 1   "Walk speed"
// lerp-param: crowd    float 0.4 1.6 = 1   "Crowd"
// lerp-param: light    float 0.3 2   = 1   "Brightness"
// lerp-param: soul     bool          = false "Soul lanterns"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -25 35   = 0 "Tilt"
// lerp-param: magnify  float -1 0.9   = 0 "Zoom"
//
// lerp-preset: "Lantern Hill" crowd=1
// lerp-preset: "Soul Lanterns" soul=true, crowd=1.4
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
    int    part;  // 0,1 legs, 2 stalk, 3 cap, 4 cap top, 5 arm, 6 lantern, 7 lantern cap
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
// Its lantern is the game's lantern at half size (body 6x7x6, cap 4x2x4 px).
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
        lhPart(o, d, inv, float3(2.5, 2.5 + b, 4.5 + w.lz), float3(5.5, 6.0 + b, 7.5 + w.lz), 6, hit);
        lhPart(o, d, inv, float3(3.0, 6.0 + b, 5.0 + w.lz), float3(5.0, 7.0 + b, 7.0 + w.lz), 7, hit);
    }
    return hit.t < before;
}

// ---------------------------------------------------------------------------
// The giant mushroom on the summit: a stem of mushroom-stem blocks, a stepped
// cap of mushroom blocks with a hanging rim, shroomlights set in its
// underside round the stem, and a glowstone door.

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

constant float LH_CAPW = 5.5;

static inline int lhShroom(float3 ro, float3 rd, float3 inv, thread float& t, thread float3& n) {
    int part = -1;
    const float C = LH_CAPY, W = LH_CAPW;
    {
        float3 t1 = (float3(-W, LH_TOP - 0.5, -W) - ro) * inv, t2 = (float3(W, C + 2.75, W) - ro) * inv;
        float3 mn = min(t1, t2), mx = max(t1, t2);
        if (max(max(mn.x, mn.y), mn.z) > min(min(mx.x, mx.y), mx.z)) return part;
    }
    lhBoxW(ro, rd, inv, float3(-LH_STEM, LH_TOP - 0.5, -LH_STEM), float3(LH_STEM, C, LH_STEM), 0, t, n, part);
    lhBoxW(ro, rd, inv, float3(-W, C, -W), float3(W, C + 1.0, W), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-W + 1.0, C + 1.0, -W + 1.0), float3(W - 1.0, C + 2.0, W - 1.0), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-W + 2.5, C + 2.0, -W + 2.5), float3(W - 2.5, C + 2.75, W - 2.5), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-W, C - 0.5, W - 1.0), float3(W, C, W), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-W, C - 0.5, -W), float3(W, C, -W + 1.0), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(W - 1.0, C - 0.5, -W + 1.0), float3(W, C, W - 1.0), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-W, C - 0.5, -W + 1.0), float3(-W + 1.0, C, W - 1.0), 1, t, n, part);
    return part;
}

// ---------------------------------------------------------------------------
// Light, the game's way: sky light from the moon, and block light that falls
// one level a block (Manhattan distance) from each source; the brighter of
// the two wins, through the game's brightness curve.

constant float LH_SHROOM_IN = 3.5;   // shroomlights fill the cap's underside out to here

struct LhEnv {
    float3 zen, fog, sky, warm, lantern, grass, moonDir;
    float  tau, S0, D, time, level;
    int    capLayer, moonLayer, lanternLayer;
};

// Where a walker's lantern is, without the parts only its body needs.
static inline bool lhLanternAt(float j, float tau, float D, float lo, float hi, float sNear,
                               float reach, thread float3& L) {
    if (hash21(float2(j, 11.3)) < 0.12) return false;
    float2 hj = hash22(float2(j, 3.7));
    float s = LH_V * (tau - LH_A * LH_P / TWO_PI * sin(tau * (TWO_PI / LH_P) - j * LH_LAG))
            - (j + hj.x * 0.45) * D;
    if (s < -1.3 || s > LH_SEND + 0.6 || s < lo || s >= hi || abs(s - sNear) > reach) return false;
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
        L = float3(r * c, y, r * sn) + float3(f.y * 4.0 + f.x * 6.0, 4.5, -f.x * 4.0 + f.y * 6.0) * sc;
    } else {
        L = float3(LH_REND - (s - LH_SSP) - 6.0 * sc, LH_TOP + 4.5 * sc, 4.0 * sc);
    }
    return true;
}

static inline float lhManhattan(float3 d) { return abs(d.x) + abs(d.y) + abs(d.z); }

// The brightest lantern level at P among walkers near arc length sc.
static inline float lhLanternsNear(float3 P, float sc, float lo, float hi, float reach, LhEnv E) {
    float lvl = 0.0;
    float2 jr = lhSlots(E.S0, sc, reach, E.D);
    for (int q = 0; q < 8; ++q) {
        float j = jr.x + float(q);
        if (j > jr.y) break;
        float3 L;
        if (!lhLanternAt(j, E.tau, E.D, lo, hi, sc, reach, L)) continue;
        lvl = max(lvl, E.level - lhManhattan(L - P));
    }
    return lvl;
}

// P is the hit nudged half a block into the air in front of the face: the
// game lights a face by the block it faces.
static inline float3 lhLight(float3 P, LhEnv E, constant LerpUniforms& u, thread float& lantern) {
    // Below about this level a lantern is no brighter than the moonlight.
    const float reach = E.level - 5.0;
    float lv = 0.0;
    float r = length(P.xz);
    float phi = lhAtan2(P.z, P.x);
    phi += phi < 0.0 ? TWO_PI : 0.0;
    float a = (LH_R0 - r) / LH_PITCH - phi / TWO_PI;
    float fa = floor(a);
    for (int m = 0; m < 2; ++m) {
        float n = fa + float(m);
        float phu = phi + TWO_PI * n;
        if (phu < -0.4 || phu > LH_PHEND + 0.4) continue;
        float dr = abs(a - n) * LH_PITCH;
        float dy = abs(P.y - max(LH_CLIMB * phu / TWO_PI, 0.0) - 0.4);
        if (dr + dy > reach + 0.5) continue;
        lv = max(lv, lhLanternsNear(P, lhArcS(phu), -2.0, LH_SSP, reach, E));
    }
    if (P.x > -2.0 && abs(P.z) < reach && r < LH_REND + reach && P.y > LH_TOP - reach) {
        float sc = LH_SSP + (LH_REND - clamp(P.x, LH_STEM, LH_REND));
        lv = max(lv, lhLanternsNear(P, sc, LH_SSP, 1e9, reach, E));
    }
    lantern = lv;

    // Shroomlights (15) under the cap: light reaches the cap's top only
    // round its edge. The glowstone door (15).
    float3 q = P - clamp(P, float3(-LH_SHROOM_IN, LH_CAPY - 1.0, -LH_SHROOM_IN),
                            float3(LH_SHROOM_IN, LH_CAPY - 1.0, LH_SHROOM_IN));
    float ds = lhManhattan(q);
    if (P.y > LH_CAPY) ds += 2.0 * max(LH_CAPW + 0.5 - max(abs(P.x), abs(P.z)), 0.0);
    float3 qd = P - clamp(P, float3(LH_STEM + 0.5, LH_TOP + 0.5, -0.5), float3(LH_STEM + 0.5, LH_TOP + 1.5, 0.5));
    float sum = max(15.0 - ds, 15.0 - lhManhattan(qd));

    float bl = mcLight(lv), bs = mcLight(sum);
    float3 block = max(E.lantern * bl, E.warm * bs);
    float3 v = max(E.sky, block);
    // The game's brightness option, set most of the way to "Bright".
    float3 iv = 1.0 - v;
    return mix(v, 1.0 - iv * iv * iv * iv, 0.7) * u.light;
}

// ---------------------------------------------------------------------------
// Surfaces. uv on a face, in blocks, with v running down the picture.

static inline float2 lhFaceUV(float3 P, float3 N) {
    if (abs(N.y) > 0.5) return P.xz;
    return float2(abs(N.x) > 0.5 ? P.z : P.x, -P.y);
}

static inline float3 lhTerrainTex(texture2d_array<float> T, float3 P, float3 N, LhCell ci, float fw,
                                  LhEnv E) {
    float2 uv = lhFaceUV(P, N);
    bool top = N.y > 0.5;
    float depth = ci.h - P.y;     // below the column's top, for side faces
    if (ci.kind == 1) {
        if (top) return mcTile(T, MC_DIRT_PATH_TOP, uv, fw).rgb;
        if (depth < 1.0) return mcTile(T, MC_DIRT_PATH_SIDE, uv, fw).rgb;
    } else if (ci.kind == 2) {
        if (top) return mcTile(T, MC_MYCELIUM_TOP, uv, fw).rgb;
        if (depth < 1.0) return mcTile(T, MC_MYCELIUM_SIDE, uv, fw).rgb;
    } else {
        if (top) return mcTile(T, MC_GRASS_BLOCK_TOP, uv, fw).rgb * E.grass;
        if (depth < 1.0) return mcGrassSide(T, uv, fw, E.grass);
    }
    // Dirt a few blocks down, then stone.
    float dd = 3.0 + floor(2.0 * hash21(floor(P.xz - N.xz * 0.5) + 3.0));
    return mcTile(T, depth < dd ? MC_DIRT : MC_STONE, uv, fw).rgb;
}

// Returns the colour; `lit` = 0 for surfaces that glow by their own light.
static inline float3 lhCreatureTex(texture2d_array<float> T, LhHit h, LhWalker w, float fw,
                                   LhEnv E, thread float& lit) {
    lit = 1.0;
    float tw = fw / (16.0 * w.sc);          // footprint in tile uv
    float3 rel = h.q - h.lo;
    if (h.part == 6 || h.part == 7) {
        // The lantern block's own picture: body sides from (0,2)-(6,9) and
        // its ends from (0,9)-(6,15); the cap's sides (0,0)-(4,2), ends (0,10)-(4,14).
        float3 px = rel * 2.0;
        bool body = h.part == 6;
        float wdt = body ? 6.0 : 4.0, hgt = body ? 7.0 : 2.0;
        float2 t;
        if (abs(h.n.y) > 0.5) t = float2(px.x, px.z) + float2(0.0, body ? 9.0 : 10.0);
        else t = float2(abs(h.n.x) > 0.5 ? px.z : px.x, (body ? 2.0 : 0.0) + hgt - px.y);
        t.x = clamp(t.x, 0.02, wdt - 0.02);
        lit = 0.0;
        return mcTile(T, E.lanternLayer, t / 16.0, tw * 2.0).rgb;
    }
    float2 uv = lhFaceUV(rel, h.n) / 16.0;
    if (h.part == 3 || h.part == 4) {
        if (h.n.y < -0.5) return mcTile(T, MC_MUSHROOM_BLOCK_INSIDE, uv, tw).rgb;
        int cap = hash21(float2(w.id, 9.1)) < 0.3 ? (E.capLayer == MC_RED_MUSHROOM_BLOCK
                     ? MC_BROWN_MUSHROOM_BLOCK : MC_RED_MUSHROOM_BLOCK) : E.capLayer;
        return mcTile(T, cap, uv + w.id * 7.0, tw).rgb;
    }
    float3 c = mcTile(T, MC_MUSHROOM_STEM, uv, tw).rgb;
    if (h.part != 2) return c * 0.85;
    // Two dark eyes on the front of the stalk (this creature's own face).
    float3 cell = floor(rel - h.n * 0.5);
    if (h.n.z > 0.5 && cell.y == 4.0 && (cell.x == 1.0 || cell.x == 4.0)) c = float3(0.06, 0.05, 0.05);
    return c;
}

static inline float3 lhShroomTex(texture2d_array<float> T, float3 P, float3 N, int part, float fw,
                                 LhEnv E, thread float& lit) {
    lit = 1.0;
    float2 uv = lhFaceUV(P, N);
    if (part == 0) {
        if (N.x > 0.5 && abs(P.z) < 0.5 && P.y < LH_TOP + 2.0) {
            lit = 0.0;   // the door: glowstone, two blocks tall
            return mcTile(T, MC_GLOWSTONE, uv, fw).rgb;
        }
        return mcTile(T, MC_MUSHROOM_STEM, uv, fw).rgb;
    }
    if (N.y < -0.5) {
        if (max(abs(P.x), abs(P.z)) < LH_SHROOM_IN && P.y > LH_CAPY - 0.1) {
            lit = 0.0;
            return mcTile(T, MC_SHROOMLIGHT, uv, fw).rgb;
        }
        return mcTile(T, MC_MUSHROOM_BLOCK_INSIDE, uv, fw).rgb;
    }
    return mcTile(T, E.capLayer, uv, fw).rgb;
}

// ---------------------------------------------------------------------------
// Sky: the night's colour, square stars, the moon's own picture (drawn on
// black, so added), and the flat cloud layer from clouds.png.

constant float LH_CLOUD_Y = 46.0;

static inline float3 lhSky(float3 ro, float3 rd, LhEnv E, float pxAngle,
                           texture2d_array<float> S, texture2d_array<float> M) {
    float y = rd.y;
    float3 col = mix(E.fog, E.zen, smoothstep(-0.02, 0.35, y));
    if (y > 0.03) {
        float2 q = rd.xz / (y + 0.3) * 90.0;
        float2 c = floor(q), f = q - c;
        float hs = hash21(c + 7.3);
        if (hs > 0.985) {
            float sz = 0.15 + 0.12 * fract(hs * 91.0);
            float cell = 90.0 * pxAngle / (y + 0.3);
            float2 e = abs(f - 0.5);
            float on = 1.0 - smoothstep(sz - cell * 0.5, sz + cell * 0.5, max(e.x, e.y));
            col += float3(0.75) * on * smoothstep(0.03, 0.2, y) * min(1.0, (2.0 * sz) / max(cell, 1e-4));
        }
    }
    float3 m = E.moonDir;
    float3 mu = normalize(cross(float3(0.0, 1.0, 0.0), m));
    float3 mv = cross(m, mu);
    float dm = dot(rd, m);
    if (dm > 0.0) {
        float2 pm = float2(dot(rd, mu), dot(rd, mv)) / dm;
        const float MS = 0.065;
        if (max(abs(pm.x), abs(pm.y)) < MS) {
            float2 px = (float2(pm.x, -pm.y) / MS * 0.5 + 0.5) * 32.0;
            col += mcSkin(S, E.moonLayer, px, pxAngle / (2.0 * MS) * 32.0).rgb;
        }
    }
    if (y > 0.0) {
        float t = (LH_CLOUD_Y - ro.y) / y;
        float2 cp = ro.xz + rd.xz * t + float2(E.time * 0.6, 0.0);
        float2 px = glmod2(cp / 12.0, 256.0);
        float4 cl = mcMap(M, MCM_ENVIRONMENT_CLOUDS, px, t * pxAngle / max(y, 0.05) / 12.0);
        float fade = exp(-t * 0.006);
        col = mix(col, E.fog * 2.4 + float3(0.02), cl.a * 0.8 * fade);
    }
    return col;
}

// ---------------------------------------------------------------------------

static inline float3 lhScene(float3 ro, float3 rd, float pxAngle, constant LerpUniforms& u, LhEnv E,
                             texture2d_array<float> T, texture2d_array<float> S,
                             texture2d_array<float> M) {
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

    float tS = 1e9;
    float3 nS = float3(0.0);
    int sPart = lhShroom(ro, rd, inv, tS, nS);

    // March the hill's columns.
    float3 bLo = float3(-LH_BOX, -2.0, -LH_BOX), bHi = float3(LH_BOX, LH_YMAX, LH_BOX);
    float3 t1 = (bLo - ro) * inv, t2 = (bHi - ro) * inv;
    float3 mn = min(t1, t2), mx = max(t1, t2);
    float tIn = max(max(mn.x, mn.y), max(mn.z, 0.0)), tOut = min(min(mx.x, mx.y), mx.z);
    bool terrainHit = false;
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
                                glow += E.lantern * (0.3 * exp(-d2 / s2) + 0.025 * exp(-d2 * 3.0));
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
        col = lhSky(ro, rd, E, pxAngle, S, M);
    } else {
        float3 alb, N;
        float lit = 1.0, ao = 1.0;
        if (what == 2) {
            LhWalker w = lhWalker(bestJ, bestK, E.tau, E.D, 0.0, 1e9);
            N = w.R * wh.n.x + float3(0.0, wh.n.y, 0.0) + w.F * wh.n.z;
            float cosi = max(abs(dot(rd, N)), 0.15);
            alb = lhCreatureTex(T, wh, w, tBest * pxAngle / cosi, E, lit);
            ao = wh.part <= 1 ? 0.8 : 1.0;
        } else if (what == 3) {
            N = nS;
            float cosi = max(abs(dot(rd, N)), 0.15);
            alb = lhShroomTex(T, P, N, sPart, tBest * pxAngle / cosi, E, lit);
        } else {
            N = nW;
            float cosi = max(abs(dot(rd, N)), 0.08);
            alb = lhTerrainTex(T, P, N, hitInfo, tBest * pxAngle / cosi, E);
            if (what == 1) {
                // Smooth lighting's darkening where a face meets a taller neighbour.
                if (N.y > 0.5) {
                    float2 f = P.xz - float2(hitCell);
                    float h = hitInfo.h;
                    int2 sx = int2(f.x < 0.5 ? -1 : 1, 0), sz = int2(0, f.y < 0.5 ? -1 : 1);
                    float ex = f.x < 0.5 ? f.x : 1.0 - f.x, ez = f.y < 0.5 ? f.y : 1.0 - f.y;
                    if (lhCell(hitCell + sx).h > h) ao *= mix(0.6, 1.0, smoothstep(0.0, 0.5, ex));
                    if (lhCell(hitCell + sz).h > h) ao *= mix(0.6, 1.0, smoothstep(0.0, 0.5, ez));
                } else {
                    int2 nb = hitCell + int2(int(N.x), int(N.z));
                    float hn = lhCell(nb).h;
                    ao *= mix(0.6, 1.0, smoothstep(0.0, 0.5, P.y - hn));
                }
            }
        }
        float shade = mcFaceShade(N);
        if (lit > 0.5) {
            float lantern;
            float3 L = lhLight(P + N * 0.5, E, u, lantern);
            col = alb * shade * ao * L;
        } else {
            col = alb * shade;
        }
        // Fog past the hill, as the game's distance fog.
        float camD = length(ro.xz);
        float fog = smoothstep(camD - 6.0, camD + 40.0, tBest);
        col = mix(col, E.fog, fog);
    }
    col += glow;
    return col;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    // Frame by the geometric mean of the sides, so a tall screen and a wide
    // one both keep the whole hill without a sea of empty ground or sky.
    float meanRes = sqrt(u.resolution.x * u.resolution.y);
    float pxAngle = 2.0 / (meanRes * LH_FOCAL);

    LhEnv E;
    E.time = u.time;
    E.tau = u.time * u.speed + u.seed * 700.0;
    E.S0 = LH_V * E.tau;
    E.D = 3.3 / u.crowd;
    // Carried lanterns light a little less far than a placed one (level 15),
    // so each walker keeps its own pool; soul lanterns are the game's 10.
    bool soul = u.soul != 0;
    E.level = soul ? 10.0 : 11.0;
    E.lanternLayer = soul ? mcFrame(MC_SOUL_LANTERN, MC_SOUL_LANTERN_FRAMES, MC_SOUL_LANTERN_TICKS, u.time)
                          : mcFrame(MC_LANTERN, MC_LANTERN_FRAMES, MC_LANTERN_TICKS, u.time);
    E.warm = float3(1.0, 0.9, 0.74);
    E.lantern = soul ? float3(0.62, 0.9, 1.0) : E.warm;
    E.grass = mcGrassTint(mcMaps, 0.8, 0.4);
    // Night, as the game draws it: a dark blue sky and fog, moonlit sky light.
    E.zen = mcFromSRGB(float3(0.010, 0.012, 0.030));
    E.fog = mcFromSRGB(float3(0.035, 0.045, 0.085));
    E.sky = float3(0.075, 0.085, 0.14);
    E.capLayer = fract(u.seed * 3.7) < 0.6 ? MC_RED_MUSHROOM_BLOCK : MC_BROWN_MUSHROOM_BLOCK;
    const int moons[8] = { MCS_ENVIRONMENT_CELESTIAL_MOON_FULL_MOON, MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_GIBBOUS,
                           MCS_ENVIRONMENT_CELESTIAL_MOON_THIRD_QUARTER, MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_CRESCENT,
                           MCS_ENVIRONMENT_CELESTIAL_MOON_NEW_MOON, MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_CRESCENT,
                           MCS_ENVIRONMENT_CELESTIAL_MOON_FIRST_QUARTER, MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_GIBBOUS };
    E.moonLayer = moons[int(u.seed * 8.0) & 7];
    float ma = fract(u.seed * 7.13) * TWO_PI;
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
    float3 col = lhScene(ro, rd, pxAngle, u, E, mcTiles, mcSkins, mcMaps);

    col = lerpDither(saturate(col), pos);
    return half4(half3(col), 1.0h);
}
