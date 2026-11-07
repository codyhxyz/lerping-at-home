// Critter — a small creature on a toy island that lives off how this Mac is
// used. Original look for Lerping@Home.
//
// LerpPulse (Sources/Pulse) notes once a minute whether anyone is at the
// keyboard and what kind of app is in front; CritterData turns the last weeks
// of that into vitals (Sources/LerpCore/CritterLedger.swift). Here they become
// a creature and its island:
//
// - It hatches from an egg, then grows — baby, child, grown, with a flower on
//   its sprout — by a day's worth of good days at a time. Long unbroken runs,
//   ten-hour days, 2 am sessions and constant app-switching make for days that
//   barely count.
// - Health is the last week. It shows in the critter's colour, its drooping
//   sprout, the grass going dry, and on a bad week a rain cloud of its own.
// - Each good day of the last two weeks is a flower in the meadow, and a new
//   tree comes up every few days of its life, so the island keeps a record.
// - What it is doing is chosen from how it feels: asleep at 3 am or after an
//   eleven-hour day, pacing under a storm cloud after an hour of tab-hopping,
//   stretching when the screensaver came on after a long run without a break,
//   waving after days away, building a sandcastle on a day of making things,
//   hopping and chasing butterflies when things are good. Each session opens
//   with it noticing you and waving; the first chapter is usually its
//   strongest feeling (drawn by squared weight), later ones by weight, with
//   small unscripted beats — a yawn, a sneeze, a sniff — layered over them.
// - The sky is the real time of day and the trees are the real season; the
//   camera comes in from a different side every session.
//
// Each frame is still a function of (time, seed, parameters) plus the vitals,
// which nothing here accumulates. LerpPreview (snapshots, gallery stills) is
// always given a fixed fixture creature; see CritterData.
//
// lerp-data: critter
// lerp-param: mood  int   0 6   = 0    "Mood (0 = live)"
// lerp-param: clock float -1 24 = -1   "Hour (-1 = now)"
// lerp-param: drift float 0 1   = 0.35 "Camera drift"
// lerp-param: act   int   -1 9  = -1   "Activity (-1 = its choice)"

#define ISLAND_R 7.0
#define SEA_Y   -0.2
#define CHAPTER  36.0

#define M_GROUND  1.0
#define M_SEA     2.0
#define M_BODY    3.0
#define M_EYE     4.0
#define M_LEAF    5.0
#define M_TRUNK   6.0
#define M_CANOPY  7.0
#define M_PETAL   8.0
#define M_FCORE   9.0
#define M_EGG    10.0
#define M_NEST   11.0
#define M_ROCK   12.0
#define M_FRUIT  13.0
#define M_CLOUD  14.0
#define M_BLOSSOM 15.0
#define M_CASTLE 16.0

#define ACT_IDLE    0
#define ACT_HOP     1
#define ACT_SLEEP   2
#define ACT_PACE    3
#define ACT_STRETCH 4
#define ACT_CHASE   5
#define ACT_SIT     6
#define ACT_WAVE    7
#define ACT_SICK    8
#define ACT_BUILD   9

struct Pose {
    float3 pos;
    float yaw, sq, lean, roll, armL, armR, eye, step, mouth;
    // lid: upper eyelids down (0 open … 1 shut); lidTilt > 0 drops the outer
    // corners (sad, worried); happy: closed ^^ eyes; mouthO: an open "o";
    // stride: how much the feet swing on `step`; reach: arms swing forward
    // instead of out to the sides; sit: feet out in front.
    float lid, lidTilt, happy, mouthO, stride, reach, sit;
};

struct Scene {
    float3 cpos;
    float3 cs0, cs1;   // cos/sin of yaw, lean, roll
    float  yaw, s, sq, lean, roll, armL, armR, eye, droop, step, mouth;
    int    stage;
    float  lid, lidTilt, happy, mouthO, stride, reach, sit;
    float  bags;       // under-eye shadows, 0…1, from tiredness and a bad week
    float  hatch, wobble;
    float2 focus;
    float  bend, ident, health, bloom, ageDays;
    int    season, trees;
    float4 tree[8];
    float4 rock[3];
    float  cloud, cloudDark;
    float3 cloudPos;
    float  castle;
    float3 castlePos;
    float  time;
    // Which objects this pixel's ray can reach at all: bits 0-7 trees,
    // 8 critter, 9 rocks, 10 cloud, 11 castle. Set once per pixel.
    uint   mask;
};

// ---------------------------------------------------------------- primitives

static inline float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}
static inline float sdEll(float3 p, float3 r) {
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 1e-5);
}
static inline float sdCap(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}
static inline float sdTorus(float3 p, float2 t) {
    return length(float2(length(p.xz) - t.x, p.y)) - t.y;
}
static inline float sdCyl(float3 p, float r, float h) {
    float2 d = abs(float2(length(p.xz), p.y)) - float2(r, h);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}
static inline float3 opU(float3 a, float3 b) { return a.x < b.x ? a : b; }
static inline float3 srgb(float3 c) { return c * c; }   // cheap sRGB → linear

// ---------------------------------------------------------------- world

static inline float groundH(float2 xz, float ident) {
    float d = length(xz);
    float hills = 0.11 * sin(xz.x * 0.55 + ident * 7.0) * sin(xz.y * 0.5 + ident * 3.0)
                + 0.035 * sin(xz.x * 1.7 + ident * 11.0 + sin(xz.y * 1.3)) * sin(xz.y * 1.9 - ident * 5.0);
    hills *= smoothstep(1.4, 3.6, d);
    float shore = smoothstep(ISLAND_R - 1.7, ISLAND_R + 0.9, d);
    return 0.04 + hills * (1.0 - shore) - 0.8 * shore;
}

// The rolled world: everything sinks with the square of its distance from
// the point the camera looks at, so the island curves away to a horizon.
static inline float3 bendP(float3 p, thread const Scene& sc) {
    float2 d = p.xz - sc.focus;
    return float3(p.x, p.y + sc.bend * dot(d, d), p.z);
}
static inline float3 unbendP(float3 q, thread const Scene& sc) {
    float2 d = q.xz - sc.focus;
    return float3(q.x, q.y - sc.bend * dot(d, d), q.z);
}

static inline float3 critterLocal(float3 q, thread const Scene& sc) {
    float3 p = q - sc.cpos;
    float c = sc.cs0.x, s = sc.cs1.x;
    p = float3(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
    float cl = sc.cs0.y, sl = sc.cs1.y;
    p = float3(p.x, p.y * cl + p.z * sl, -p.y * sl + p.z * cl);
    float cr = sc.cs0.z, sr = sc.cs1.z;
    return float3(p.x * cr - p.y * sr, p.x * sr + p.y * cr, p.z);
}

// ---------------------------------------------------------------- the critter

static float3 sdCritter(float3 q, thread const Scene& sc) {
    float s = sc.s;
    float bound = length(q - sc.cpos - float3(0.0, 1.1 * s, 0.0)) - 2.4 * s;
    if (bound > 0.2) return float3(bound, M_BODY, 0.0);
    float3 p = critterLocal(q, sc);

    if (sc.stage == 0) {
        float3 e = p;
        e.xy = rotate(e.xy, sc.wobble);
        float3 ec = e - float3(0.0, 0.4, 0.0);
        float taper = 1.0 - 0.14 * clamp(ec.y / 0.4, -1.0, 1.0);
        float egg = sdEll(ec, float3(0.29 * taper, 0.4, 0.29 * taper));
        float3 np = p - float3(0.0, 0.06, 0.0);
        float nest = sdTorus(np, float2(0.3, 0.1))
                   + 0.012 * sin(atan2(np.z, np.x) * 26.0 + np.y * 50.0);
        return egg < nest ? float3(egg, M_EGG, 0.0) : float3(nest * 0.8, M_NEST, 0.0);
    }

    float hz = rsqrt(sc.sq);
    float3 bc = float3(0.0, 0.95 * s * sc.sq, 0.0);
    float body = sdEll(p - bc, float3(1.0 * hz, 0.95 * sc.sq, 0.92 * hz) * s);
    // Feet swing by `stride` (so a blend never spins them); sitting puts
    // them out in front.
    float sw = 0.13 * sc.stride * sin(sc.step);
    float fx = 0.42 - 0.05 * sc.sit, fy = 0.12 + 0.05 * sc.sit, fz = 0.24 + 0.42 * sc.sit;
    float feet = min(sdEll(p - float3(-fx, fy, fz + sw) * s, float3(0.21, 0.13, 0.27) * s),
                     sdEll(p - float3( fx, fy, fz - sw) * s, float3(0.21, 0.13, 0.27) * s));
    body = smin(body, feet, 0.07 * s);
    // Arms long enough to wave over its head, a mitten on each. `reach`
    // swings them forward (patting, reaching) instead of out to the side.
    float3 shL = bc + float3(-0.74 * hz * s, 0.08 * s, 0.08 * s);
    float3 shR = bc + float3( 0.74 * hz * s, 0.08 * s, 0.08 * s);
    float rc = sc.reach;
    float3 dL = normalize(float3(-sin(sc.armL) * (1.0 - rc) - 0.15 * rc, -cos(sc.armL), mix(0.3, sin(sc.armL), rc)));
    float3 dR = normalize(float3( sin(sc.armR) * (1.0 - rc) + 0.15 * rc, -cos(sc.armR), mix(0.3, sin(sc.armR), rc)));
    float3 hL = shL + dL * 0.84 * s, hR = shR + dR * 0.84 * s;
    float arms = min(sdCap(p, shL, hL, 0.095 * s), sdCap(p, shR, hR, 0.095 * s));
    arms = smin(arms, min(length(p - hL), length(p - hR)) - 0.145 * s, 0.05 * s);
    body = smin(body, arms, 0.06 * s);
    float3 res = float3(body, M_BODY, 0.0);

    // Eyes: an upper lid (a tilted plane; outer corners down reads sad or
    // worried), and on a happy face they bend into closed ^^ arches.
    float hp = abs(sc.happy);   // < 0: sleeping, closed the other way up
    float eyeH = mix((0.12 * sc.eye + 0.02) * s, 0.032 * s, hp);
    float3 er = float3((0.085 + 0.012 * hp) * s, eyeH, 0.07 * s);
    float3 eo = float3(0.34 * hz * s, 0.1 * s * sc.sq, 0.83 * hz * s);
    float3 eL = p - (bc + float3(-eo.x, eo.y, eo.z));
    float3 eR = p - (bc + eo);
    float arch = 6.5 / s * sc.happy;
    eL.y += arch * eL.x * eL.x - 0.025 * s * sc.happy;
    eR.y += arch * eR.x * eR.x - 0.025 * s * sc.happy;
    float lt = sc.lidTilt, h0 = eyeH * (1.0 - 2.0 * sc.lid), lk = rsqrt(1.0 + lt * lt);
    float eyes = min(max(sdEll(eL, er), (eL.y - h0 - lt * eL.x) * lk),
                     max(sdEll(eR, er), (eR.y - h0 + lt * eR.x) * lk));
    res = opU(res, float3(eyes * (1.0 - 0.35 * hp), M_EYE, 0.0));

    // Sprout: longer with each stage; on a bad week it wilts forward and one
    // leaf hangs.
    float3 top = bc + float3(0.0, 0.92 * sc.sq * s, 0.0);
    float len = (0.2 + 0.08 * float(sc.stage)) * s;
    float3 sdir = normalize(float3(0.0, 1.0 - 0.75 * sc.droop, 0.1 + 1.3 * sc.droop));
    float3 tip = top + sdir * len;
    res = opU(res, float3(sdCap(p, top - float3(0.0, 0.06 * s, 0.0), tip, 0.035 * s), M_LEAF, 0.0));
    float ls = (0.95 + 0.2 * float(sc.stage)) * s;
    float3 a = p - tip; a.xy = rotate(a.xy, -(0.5 + 0.8 * sc.droop)); a.x += 0.18 * ls;
    float3 b = p - tip; b.x = -b.x; b.xy = rotate(b.xy, -(0.5 + 1.9 * sc.droop)); b.x += 0.18 * ls;
    float leaves = min(sdEll(a, float3(0.19, 0.035, 0.1) * ls), sdEll(b, float3(0.19, 0.035, 0.1) * ls));
    res = opU(res, float3(leaves, M_LEAF, 0.0));
    if (sc.stage >= 3) {
        float3 h = p - (tip + sdir * 0.05 * s);
        float pm = 1.0 + 0.3 * cos(5.0 * atan2(h.z, h.x));
        float bloom = sdEll(float3(h.x / pm, h.y, h.z / pm), float3(0.22, 0.06, 0.22) * s) * 0.8;
        res = opU(res, float3(bloom, M_BLOSSOM, 0.0));
        res = opU(res, float3(length(h - float3(0.0, 0.04 * s, 0.0)) - 0.07 * s, M_FCORE, 0.0));
    }
    return res;
}

// ---------------------------------------------------------------- the island

static float3 sdTree(float3 q, float4 T, int i, thread const Scene& sc) {
    float ts = T.w;
    float3 p = q - T.xyz;
    float trunk = sdCap(p, float3(0.0, -0.1, 0.0), float3(0.0, 1.0 * ts, 0.0),
                        (0.11 - 0.035 * clamp(p.y / ts, 0.0, 1.0)) * ts);
    float c = sdEll(p - float3(0.0, 1.25 * ts, 0.0), float3(0.62, 0.52, 0.62) * ts);
    c = smin(c, sdEll(p - float3(0.3 * ts, 1.05 * ts, 0.14 * ts), float3(0.42) * ts), 0.14 * ts);
    c = smin(c, sdEll(p - float3(-0.27 * ts, 1.08 * ts, -0.12 * ts), float3(0.42) * ts), 0.14 * ts);
    c = smin(c, sdEll(p - float3(0.02 * ts, 1.62 * ts, 0.03 * ts), float3(0.36) * ts), 0.14 * ts);
    float3 res = trunk < c ? float3(trunk, M_TRUNK, float(i)) : float3(c, M_CANOPY, float(i));
    // Fruit on a healthy island (not in winter).
    if (sc.health > 0.55 && sc.season != 3) {
        float fr = 0.075 * ts;
        float f = length(p - float3(0.5, 1.12, 0.38) * ts) - fr;
        f = min(f, length(p - float3(-0.32, 1.35, 0.5) * ts) - fr);
        if (sc.health > 0.75) f = min(f, length(p - float3(0.12, 0.98, -0.6) * ts) - fr);
        res = opU(res, float3(f, M_FRUIT, float(i)));
    }
    return res;
}

static float3 sdFlowers(float3 q, float gh, thread const Scene& sc) {
    if (q.y - gh > 0.42) return float3(q.y - gh - 0.36, M_PETAL, 0.0);
    const float cell = 0.6;
    float2 c = floor(q.xz / cell);
    float2 inCell = q.xz - (c + 0.5) * cell;
    float border = cell * 0.5 - max(abs(inCell.x), abs(inCell.y));
    float empty = float3(border + 0.09, M_PETAL, 0.0).x;
    float2 jit = (hash22(c + 17.0) - 0.5) * 0.2;
    float2 center = (c + 0.5) * cell + jit;
    float dc = length(center);
    float pres = hash21(c * 1.37 + 3.1 + sc.ident * 11.0);
    float density = 0.04 + 0.32 * sc.bloom;
    if (pres > density || dc < 1.35 || dc > ISLAND_R - 1.4) return float3(empty, M_PETAL, 0.0);
    float base = gh;
    float fh = 0.15 + 0.1 * hash21(c + 5.5);
    float3 lp = q - float3(center.x, base, center.y);
    float gust = 0.6 + 0.4 * sin(sc.time * 0.31 + center.x * 0.4);
    float3 sway = float3(sin(sc.time * 1.7 + pres * 40.0 + center.x), 0.0,
                         cos(sc.time * 1.3 + pres * 23.0 + center.y)) * 0.03 * gust;
    float stem = sdCap(lp, float3(0.0), float3(0.0, fh, 0.0) + sway, 0.012);
    float3 hp = lp - float3(0.0, fh, 0.0) - sway;
    float pm = 1.0 + 0.32 * cos(5.0 * atan2(hp.z, hp.x) + pres * 30.0);
    float head = sdEll(float3(hp.x / pm, hp.y, hp.z / pm), float3(0.075, 0.025, 0.075)) * 0.75;
    float core = length(hp - float3(0.0, 0.018, 0.0)) - 0.028;
    float3 res = float3(stem, M_LEAF, 0.0);
    res = opU(res, float3(head, M_PETAL, pres / max(density, 1e-3)));
    res = opU(res, float3(core, M_FCORE, 0.0));
    res.x = min(res.x, empty + 0.2);   // never step past the next cell's flower
    return res;
}

static float3 sdCloud(float3 q, thread const Scene& sc) {
    float3 p = q - sc.cloudPos;
    float k = sc.cloud;
    float bound = length(p) - 0.9 * k;
    if (bound > 0.3) return float3(bound, M_CLOUD, 0.0);
    float jit = sc.cloudDark * 0.03 * sin(sc.time * 23.0);
    float d = sdEll(p, float3(0.46, 0.2, 0.32) * k);
    d = smin(d, length(p - float3(0.28 + jit, 0.08, 0.04) * k) - 0.24 * k, 0.12 * k);
    d = smin(d, length(p - float3(-0.3, 0.06 - jit, -0.03) * k) - 0.22 * k, 0.12 * k);
    d = smin(d, length(p - float3(0.02, 0.2, 0.02) * k) - 0.25 * k, 0.12 * k);
    // A flat underside, so it reads as a cloud and not a hat.
    d = max(d, -p.y - 0.09 * k);
    return float3(d, M_CLOUD, 0.0);
}

static float3 sdCastle(float3 q, thread const Scene& sc) {
    float3 p = q - sc.castlePos;
    float bound = length(p - float3(0.0, 0.2, 0.0)) - 0.5;
    if (bound > 0.2) return float3(bound, M_CASTLE, 0.0);
    float d = sdCyl(p - float3(0.0, 0.07, 0.0), 0.3, 0.07) - 0.02;
    d = min(d, sdCyl(p - float3(0.0, 0.2, 0.0), 0.2, 0.08) - 0.015);
    d = min(d, sdCyl(p - float3(0.18, 0.22, 0.12), 0.07, 0.17) - 0.01);
    d = min(d, sdCyl(p - float3(-0.17, 0.22, -0.1), 0.07, 0.17) - 0.01);
    d = min(d, sdCyl(p - float3(0.0, 0.35, 0.0), 0.09, 0.08) - 0.01);
    // Built from the bottom up over the chapter.
    d = max(d, p.y - 0.48 * sc.castle);
    return float3(d, M_CASTLE, 0.0);
}

// (distance, material, material detail, distance to everything but the
// ground and sea) — the last lets the march take long steps over open ground.
static float4 mapScene(float3 p, thread const Scene& sc, bool full, bool flowers = true) {
    float3 q = bendP(p, sc);
    float3 res = float3(1e5, 0.0, 0.0);
    float3 land = float3(1e5, 0.0, 0.0);
    if (full) {
        float gh = groundH(q.xz, sc.ident);
        land = float3((q.y - gh) * 0.8, M_GROUND, 0.0);
        land = opU(land, float3(q.y - SEA_Y, M_SEA, 0.0));
        if (flowers) res = sdFlowers(q, gh, sc);
    }
    // Trees: bound all of them, model only the two nearest.
    float b0 = 1e5, b1 = 1e5;
    int i0 = -1, i1 = -1;
    for (int i = 0; i < 8; i++) {
        if (i >= sc.trees) break;
        float4 T = sc.tree[i];
        if (T.w <= 0.0 || ((sc.mask >> i) & 1u) == 0u) continue;
        float b = length(q - float3(T.x, T.y + 1.15 * T.w, T.z)) - 1.05 * T.w;
        if (b < b0) { b1 = b0; i1 = i0; b0 = b; i0 = i; }
        else if (b < b1) { b1 = b; i1 = i; }
    }
    for (int j = 0; j < 2; j++) {
        int i = j == 0 ? i0 : i1;
        float b = j == 0 ? b0 : b1;
        if (i < 0) break;
        res = opU(res, b > 0.3 ? float3(b, M_CANOPY, float(i)) : sdTree(q, sc.tree[i], i, sc));
    }
    for (int i = 0; i < 3; i++) {
        if ((sc.mask & 512u) == 0u) break;
        float3 rp = q - sc.rock[i].xyz;
        float r = sc.rock[i].w;
        float b = length(rp) - r;
        res = opU(res, float3(b > 0.2 ? b : sdEll(rp, float3(1.0, 0.62, 0.85) * r), M_ROCK, 0.0));
    }
    if ((sc.mask & 256u) != 0u) res = opU(res, sdCritter(q, sc));
    if (sc.cloud > 0.01 && (sc.mask & 1024u) != 0u) res = opU(res, sdCloud(q, sc));
    if (sc.castle > 0.001 && (sc.mask & 2048u) != 0u) res = opU(res, sdCastle(q, sc));
    return float4(opU(land, res), res.x);
}

// Ground and flowers only — for the second pass, which pass 1 has already
// shown nothing else can be hit in.
static float3 mapMeadow(float3 p, thread const Scene& sc) {
    float3 q = bendP(p, sc);
    float gh = groundH(q.xz, sc.ident);
    return opU(float3((q.y - gh) * 0.8, M_GROUND, 0.0), sdFlowers(q, gh, sc));
}

static float3 calcNormal(float3 p, thread const Scene& sc) {
    const float2 e = float2(0.0012, -0.0012);
    return normalize(e.xyy * mapScene(p + e.xyy, sc, true).x + e.yyx * mapScene(p + e.yyx, sc, true).x
                   + e.yxy * mapScene(p + e.yxy, sc, true).x + e.xxx * mapScene(p + e.xxx, sc, true).x);
}

// Can a ray reach this bent-space sphere? Its world centre is unbent, and the
// radius padded for how much the bend shifts it across its own extent.
static inline bool rayReaches(float3 ro, float3 rd, float3 c, float r, thread const Scene& sc) {
    float3 w = unbendP(c, sc);
    float pad = 2.0 * sc.bend * length(c.xz - sc.focus) * r + 0.05;
    float3 oc = ro - w;
    float b = dot(oc, rd);
    float cc = dot(oc, oc) - (r + pad) * (r + pad);
    float h = b * b - cc;
    return h > 0.0 && (cc < 0.0 || b < 0.0);
}

// Soft shadow of a sphere (after Inigo Quilez). Shadows here are soft blobs
// under round things, so every caster is a sphere: no shadow ray is marched.
static inline float sphShadow(float3 ro, float3 rd, float4 sph, float k) {
    float3 oc = ro - sph.xyz;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - sph.w * sph.w;
    float h = b * b - c;
    float d = sqrt(max(0.0, sph.w * sph.w - h)) - sph.w;
    float t = -b - sqrt(max(h, 0.0));
    return t < 0.0 ? 1.0 : smoothstep(0.0, 1.0, 2.5 * k * d / t);
}

// `skip` names the caster the shaded point belongs to (0…7 a tree, 8 the
// critter, -1 none), which must not shadow itself.
static float softShadow(float3 q, float3 L, thread const Scene& sc, int skip) {
    float sh = 1.0;
    for (int i = 0; i < 8; i++) {
        if (i >= sc.trees) break;
        float4 T = sc.tree[i];
        if (T.w <= 0.0 || i == skip) continue;
        sh *= sphShadow(q, L, float4(T.x, T.y + 1.3 * T.w, T.z, 0.6 * T.w), 2.0);
        sh *= sphShadow(q, L, float4(T.x, T.y + 0.5 * T.w, T.z, 0.1 * T.w), 3.0);
    }
    if (skip != 8) {
        float r = sc.stage == 0 ? 0.33 : 0.95 * sc.s;
        sh *= sphShadow(q, L, float4(sc.cpos + float3(0.0, sc.stage == 0 ? 0.4 : 0.95 * sc.s * sc.sq, 0.0), r), 2.5);
    }
    if (sc.cloud > 0.01) sh *= sphShadow(q, L, float4(sc.cloudPos, 0.45 * sc.cloud), 1.5);
    if (sc.castle > 0.01) sh *= sphShadow(q, L, float4(sc.castlePos + float3(0.0, 0.15, 0.0), 0.25 * sc.castle), 2.5);
    return sh;
}

// Ambient occlusion from the same spheres that cast the shadows: the
// cosine-weighted solid angle each one covers (after Inigo Quilez).
static inline float sphOcc(float3 pos, float3 nor, float4 sph) {
    float3 di = sph.xyz - pos;
    float l2 = dot(di, di);
    return max(0.0, dot(nor, di) * rsqrt(l2)) * sph.w * sph.w / l2;
}

static float ambientOcc(float3 q, float3 n, thread const Scene& sc, int skip) {
    float occ = 0.0;
    for (int i = 0; i < 8; i++) {
        if (i >= sc.trees) break;
        float4 T = sc.tree[i];
        if (T.w <= 0.0 || i == skip) continue;
        occ += sphOcc(q, n, float4(T.x, T.y + 1.3 * T.w, T.z, 0.6 * T.w));
        occ += sphOcc(q, n, float4(T.x, T.y + 0.3 * T.w, T.z, 0.13 * T.w));
    }
    if (skip != 8) {
        float r = sc.stage == 0 ? 0.33 : 0.95 * sc.s;
        occ += sphOcc(q, n, float4(sc.cpos + float3(0.0, sc.stage == 0 ? 0.4 : 0.95 * sc.s * sc.sq, 0.0), r));
    } else {
        // the critter's own feet and underside sit in its shadow
        occ += 0.6 * smoothstep(0.35 * sc.s, 0.0, q.y - sc.cpos.y) * smoothstep(0.2, -0.6, n.y);
    }
    if (sc.castle > 0.01) occ += sphOcc(q, n, float4(sc.castlePos + float3(0.0, 0.12, 0.0), 0.25 * sc.castle));
    return clamp(1.0 - 1.4 * occ, 0.0, 1.0);
}

// ---------------------------------------------------------------- behaviour

// `castle` is where the sandcastle stands (BUILD faces it and pats it).
static Pose makePose(int act, float t, float r, float s, float az, float2 right, float2 castle,
                     constant CritterState& S) {
    Pose P;
    float joy = S.joy;
    float breath = sin(t * 1.8 + r * 6.0);
    P.pos = float3(0.0);
    P.yaw = az + 0.25 * sin(r * 12.0);
    P.sq = 1.0 + 0.025 * breath;
    P.lean = 0.0; P.roll = 0.0;
    P.armL = 0.5 + 0.05 * breath; P.armR = P.armL;
    float bl = fract(t * 0.29 + r * 3.0);
    P.eye = 1.0 - (smoothstep(0.0, 0.02, bl) - smoothstep(0.02, 0.045, bl));
    // The feet always step on the same clock; activities only change how far.
    P.step = t * 14.0; P.stride = 0.0;
    P.mouth = mix(-0.8, 1.0, joy);
    // The week in its face: heavy lids when tired, worried brows when low.
    float tired = clamp((0.55 - S.energy) / 0.45, 0.0, 1.0);
    P.lid = 0.45 * tired;
    P.lidTilt = 0.7 * clamp((0.6 - joy) / 0.5, 0.0, 1.0);
    P.happy = 0.0; P.mouthO = 0.0; P.reach = 0.0; P.sit = 0.0;
    switch (act) {
        case ACT_IDLE: {
            P.yaw = az + 0.55 * sin(t * 0.37 + r * 6.0);
            P.roll = 0.07 * sin(t * 0.61 + r);
            break;
        }
        case ACT_HOP: {
            float ph = fract(t * 0.85);
            float air = ph < 0.6 ? sin(ph / 0.6 * PI) : 0.0;
            float land = ph >= 0.6 ? exp(-(ph - 0.6) * 18.0) : 0.0;
            P.pos.y = 0.4 * s * air;
            P.sq = 1.0 - 0.24 * land + 0.1 * air;
            P.armL = P.armR = 0.6 + 2.1 * air;
            P.yaw = az + 0.45 * sin(t * 0.4 + r * 5.0);
            P.mouth = 1.0;
            P.mouthO = 0.75 * air;
            P.happy = air * smoothstep(0.55, 0.85, joy);
            P.lid = 0.0;
            break;
        }
        case ACT_SLEEP: {
            // A good week curls up facing you, eyes closed in a smile; a
            // burnt-out one lies face down where it dropped.
            float worn = clamp((0.55 - S.health) / 0.3, 0.0, 1.0);
            P.sq = mix(0.82, 0.74, worn) + 0.035 * sin(t * 1.1);
            P.eye = 0.0; P.lid = 0.0; P.lidTilt = 0.0;
            P.happy = -0.9;
            P.roll = mix(0.4, 0.08, worn);
            P.lean = mix(-0.18, 0.6, worn);
            P.armL = P.armR = mix(0.95, 1.45, worn);
            P.reach = 0.7 * (1.0 - worn);
            P.yaw = az + mix(0.2, 0.35, worn);
            P.pos.y = -0.06 * s * worn;
            P.mouth = mix(0.5, -0.3, worn);
            break;
        }
        case ACT_PACE: {
            float x = 1.15 * sin(t * 0.8 + r * 6.0);
            float vx = cos(t * 0.8 + r * 6.0);
            P.pos = float3(right.x * x, abs(sin(t * 7.0)) * 0.05 * s, right.y * x);
            P.yaw = az + 1.5708 * clamp(vx * 3.0, -1.0, 1.0);
            P.stride = 1.0;
            P.lean = 0.16;
            P.armL = 0.45 + 0.25 * sin(t * 7.0); P.armR = 0.45 - 0.25 * sin(t * 7.0);
            P.lid = max(P.lid, 0.15); P.lidTilt = 0.75;
            P.mouth = -0.7;
            break;
        }
        case ACT_STRETCH: {
            float c = fract(t / 7.0) * 7.0;
            float k = smoothstep(0.3, 1.8, c) - smoothstep(4.6, 6.2, c);
            P.armL = P.armR = mix(0.5, 2.9, k);
            P.sq = 1.0 + 0.2 * k;
            P.happy = k;
            P.lid = P.lid * (1.0 - k);
            P.lean = 0.0;
            P.roll = 0.03 * sin(t * 9.0) * k;
            P.mouth = 1.0;
            P.mouthO = 0.7 * k;
            break;
        }
        case ACT_CHASE: {
            // Same phase as the butterfly, so one chase follows on from another.
            float a = t * 0.55 - 0.55;
            P.pos = float3(cos(a) * 1.25, abs(sin(t * 7.0)) * 0.09 * s, sin(a) * 1.25);
            P.yaw = atan2(-sin(a), cos(a));
            P.stride = 1.0;
            P.armL = 1.5 + 0.35 * sin(t * 7.0); P.armR = 1.5 - 0.35 * sin(t * 7.0);
            P.mouth = 1.0; P.mouthO = 0.45; P.lid = 0.0;
            break;
        }
        case ACT_SIT: {
            // Sitting back on its bottom, feet out, three-quarters to you.
            float side = r < 0.5 ? -1.0 : 1.0;
            P.yaw = az + side * (0.85 + 0.25 * sin(t * 0.23 + r * 5.0));
            P.sq = 0.9 + 0.02 * breath;
            P.lean = -0.25;
            P.sit = 1.0;
            P.roll = 0.05 * sin(t * 0.7);
            P.armL = P.armR = 0.8; P.reach = 0.6;
            P.lid = max(P.lid, 0.3);
            P.mouth = max(P.mouth, 0.4);
            break;
        }
        case ACT_WAVE: {
            P.yaw = az;
            P.armR = 2.7 + 0.35 * sin(t * 9.0);
            P.armL = 0.55;
            P.pos.y = 0.03 * s * abs(sin(t * 4.5));
            P.mouth = 1.0; P.mouthO = 0.3;
            P.happy = 0.85; P.lid = 0.0;
            break;
        }
        case ACT_SICK: {
            P.sq = 0.86;
            P.lean = 0.28;
            P.eye = min(P.eye, 0.8);
            P.lid = max(P.lid, 0.45); P.lidTilt = 0.85;
            P.armL = P.armR = 0.3;
            P.roll = 0.05 * sin(t * 38.0) * step(0.75, fract(t * 0.17));
            P.yaw = az + 0.25;
            P.mouth = -0.9;
            break;
        }
        case ACT_BUILD: {
            // Kneels at the castle and pats it with both mittens.
            float2 u = normalize(right * 0.8 + float2(sin(az), cos(az)) * 0.55);
            float2 at = castle - u * (0.38 + 0.95 * s);
            P.pos = float3(at.x, 0.0, at.y);
            P.yaw = atan2(u.x, u.y);
            float pat = abs(sin(t * 5.0));
            P.reach = 1.0;
            P.armL = P.armR = 0.95 + 0.45 * pat;   // lands on the cusp
            P.lean = 0.2 + 0.08 * pat;
            P.sq = 0.96 - 0.04 * pat;
            P.lid = max(P.lid, 0.25);
            P.mouth = 1.0;
            break;
        }
    }
    return P;
}

// The first chapter is drawn by squared weight — usually the strongest
// feeling, not always; later ones by plain weight.
static int pickActivity(float chapter, float seed, constant CritterState& S) {
    float w[10] = { S.w0.x, S.w0.y, S.w0.z, S.w0.w, S.w1.x, S.w1.y, S.w1.z, S.w1.w, S.w2.x, S.w2.y };
    float pw = chapter < 0.5 ? 2.0 : 1.0;
    float total = 0.0;
    for (int i = 0; i < 10; i++) total += pow(max(w[i], 0.0), pw);
    float r = hash11(chapter * 12.9898 + seed * 78.233) * total;
    for (int i = 0; i < 10; i++) {
        r -= pow(max(w[i], 0.0), pw);
        if (r <= 0.0) return i;
    }
    return 0;
}

static inline Pose blendPose(Pose a, Pose b, float k) {
    Pose P;
    P.pos = mix(a.pos, b.pos, k);
    float dy = b.yaw - a.yaw;
    dy -= TWO_PI * floor((dy + PI) / TWO_PI);
    P.yaw = a.yaw + dy * k;
    P.sq = mix(a.sq, b.sq, k); P.lean = mix(a.lean, b.lean, k); P.roll = mix(a.roll, b.roll, k);
    P.armL = mix(a.armL, b.armL, k); P.armR = mix(a.armR, b.armR, k);
    P.eye = mix(a.eye, b.eye, k); P.step = b.step; P.mouth = mix(a.mouth, b.mouth, k);
    P.lid = mix(a.lid, b.lid, k); P.lidTilt = mix(a.lidTilt, b.lidTilt, k);
    P.happy = mix(a.happy, b.happy, k); P.mouthO = mix(a.mouthO, b.mouthO, k);
    P.stride = mix(a.stride, b.stride, k); P.reach = mix(a.reach, b.reach, k);
    P.sit = mix(a.sit, b.sit, k);
    return P;
}

// A little unscripted moment every 6–12 s, over whatever it is doing: a
// yawn, a sneeze, sniffing a flower, looking up at a falling leaf, a shiver
// of delight. `w` fades it (0 during a chapter blend).
static void addBeat(thread Pose& P, float t, float seed, int act, float w) {
    float slot = floor(t / 9.0);
    float start = 1.0 + 4.5 * hash11(slot * 2.71 + seed * 13.0);
    float ph = (t - slot * 9.0 - start) / 2.4;
    if (ph <= 0.0 || ph >= 1.0) return;
    float env = smoothstep(0.0, 0.2, ph) * smoothstep(1.0, 0.75, ph) * w;
    int kind = act == ACT_SICK ? 1 : min(int(hash11(slot * 5.13 + seed * 31.0) * 5.0), 4);
    if (kind == 0) {            // yawn
        P.mouthO = mix(P.mouthO, 1.0, env);
        P.lid = mix(P.lid, 0.8, env); P.happy *= 1.0 - env;
        P.lean -= 0.12 * env;
        P.armL += 0.6 * env; P.armR += 0.6 * env;
        P.sq += 0.06 * env;
    } else if (kind == 1) {     // sneeze: wind up… achoo
        float wind = smoothstep(0.05, 0.55, ph) * (1.0 - smoothstep(0.58, 0.62, ph));
        float jolt = smoothstep(0.57, 0.62, ph) * (1.0 - smoothstep(0.7, 0.95, ph));
        P.lean += (-0.18 * wind + 0.34 * jolt) * w;
        P.lid = mix(P.lid, 0.7, wind * w);
        P.mouthO = mix(P.mouthO, 0.55, wind * w);
        P.eye = mix(P.eye, 0.0, jolt * w);
        P.sq -= 0.1 * jolt * w;
        P.armL += 0.5 * jolt * w; P.armR += 0.5 * jolt * w;
    } else if (kind == 2) {     // sniff a flower
        P.lean += 0.38 * env;
        P.happy = mix(P.happy, 0.9, env);
        P.mouth = mix(P.mouth, 0.8, env);
        P.sq += 0.025 * sin(t * 18.0) * env;
    } else if (kind == 3) {     // look up at a falling leaf
        P.lean -= 0.34 * env;
        P.roll += 0.12 * env;
        P.eye = mix(P.eye, 1.15, env); P.lid *= 1.0 - env;
        P.mouthO = mix(P.mouthO, 0.35, env);
    } else {                    // a little shiver of delight
        P.roll += 0.06 * sin(t * 45.0) * env;
        P.sq += 0.05 * sin(t * 30.0) * env;
        P.happy = mix(P.happy, 1.0, env);
        P.mouth = mix(P.mouth, 1.0, env); P.mouthO = mix(P.mouthO, 0.25, env);
        P.armL += 0.4 * env; P.armR += 0.4 * env;
    }
}

// The first seconds of a session: it is looking off to one side, notices
// you (a jolt and a "!"), turns to face you and waves.
static Pose doubleTake(Pose P, float time, float az, float s) {
    Pose D = P;
    float jolt = smoothstep(0.55, 0.68, time) * (1.0 - smoothstep(0.7, 1.05, time));
    float turn = smoothstep(0.8, 1.45, time);
    float wv = smoothstep(1.35, 1.75, time);
    D.pos = float3(0.0, 0.12 * s * jolt, 0.0);
    D.yaw = mix(az + 1.15 + 0.12 * sin(time * 1.7), az, turn);
    D.sq = 1.0 + 0.13 * jolt;
    D.lean = -0.12 * jolt; D.roll = 0.0;
    D.eye = mix(P.eye, 1.25, smoothstep(0.55, 0.65, time));
    D.lid = 0.0; D.lidTilt = 0.0;
    D.happy = 0.9 * wv;
    D.mouth = wv;
    D.mouthO = 0.7 * smoothstep(0.55, 0.65, time) * (1.0 - smoothstep(1.1, 1.4, time)) + 0.3 * wv;
    D.armL = 0.5 + 0.7 * jolt;
    D.armR = mix(0.5 + 0.7 * jolt, 2.7 + 0.35 * sin(time * 9.0), wv);
    D.stride = 2.0 * turn * (1.0 - turn);   // a shuffle while it turns
    D.reach = 0.0; D.sit = 0.0;
    return D;
}

// ---------------------------------------------------------------- 2D overlays

static inline float sdSeg(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}
static inline float sdZ(float2 p) {
    float d = sdSeg(p, float2(-0.45, 0.5), float2(0.45, 0.5));
    d = min(d, sdSeg(p, float2(0.45, 0.5), float2(-0.45, -0.5)));
    return min(d, sdSeg(p, float2(-0.45, -0.5), float2(0.45, -0.5)));
}
static inline float sdHeart(float2 p) {
    p.x = abs(p.x); p.y += 0.55;
    if (p.y + p.x > 1.0) return length(p - float2(0.25, 0.75)) - 0.35355;
    float2 a = p - float2(0.0, 1.0);
    float2 b = p - 0.5 * max(p.x + p.y, 0.0);
    return sqrt(min(dot(a, a), dot(b, b))) * sign(p.x - p.y);
}

struct Cam { float3 ro, fw, rt, up; float focal; };

static inline float3 project(float3 wp, Cam c) {
    float3 v = wp - c.ro;
    float z = dot(v, c.fw);
    return float3(float2(dot(v, c.rt), dot(v, c.up)) * c.focal / max(z, 1e-3), z);
}

// ---------------------------------------------------------------- sky

static float3 skyColor(float3 rd, float3 sunDir, float3 moonDir, float night, float golden, float time) {
    float y = clamp(rd.y, -0.2, 1.0);
    float3 top = mix(mix(float3(0.30, 0.58, 0.95), float3(0.40, 0.42, 0.76), golden), float3(0.02, 0.035, 0.11), night);
    float3 hor = mix(mix(float3(0.62, 0.82, 0.98), float3(1.0, 0.66, 0.46), golden), float3(0.09, 0.12, 0.26), night);
    float3 c = mix(hor, top, pow(smoothstep(-0.05, 0.65, y), 0.7));
    float sd = max(dot(rd, sunDir), 0.0);
    c += (1.0 - night) * (pow(sd, 600.0) * float3(1.0, 0.92, 0.7) * 2.5
                        + pow(sd, 10.0) * mix(float3(0.18, 0.15, 0.08), float3(0.55, 0.25, 0.08), golden));
    float md = max(dot(rd, moonDir), 0.0);
    c += night * (smoothstep(0.9993, 0.9996, md) * float3(0.95, 0.95, 0.85) + pow(md, 60.0) * float3(0.08, 0.1, 0.18));
    if (rd.y > 0.0) {
        float2 cp = rd.xz / (rd.y + 0.18) * 1.2 + float2(time * 0.008, 0.0);
        float n = valueNoise(cp * 1.1) * 0.62 + valueNoise(cp * 2.6 + 4.0) * 0.38;
        float cl = smoothstep(0.56, 0.78, n) * smoothstep(0.0, 0.22, rd.y);
        float3 cc = mix(mix(float3(1.0, 0.99, 0.97), float3(1.0, 0.76, 0.66), golden), float3(0.16, 0.18, 0.3), night);
        c = mix(c, cc, cl * 0.9);
        if (night > 0.01) {
            float2 st = float2(atan2(rd.z, rd.x), asin(rd.y)) * 70.0;
            float2 cell = floor(st);
            float h = hash21(cell);
            float2 off = hash22(cell + 3.0) - 0.5;
            float star = smoothstep(0.12, 0.0, length(fract(st) - 0.5 - off * 0.6)) * step(0.965, h);
            star *= 0.6 + 0.4 * sin(time * (1.0 + 3.0 * h) + h * 40.0);
            c += night * star * (1.0 - cl) * float3(0.9, 0.92, 1.0);
        }
    }
    return c;
}

// ---------------------------------------------------------------- main

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant CritterState& S [[buffer(1)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float time = u.time;
    float seed = u.seed;

    // ---- who it is today
    Scene sc;
    sc.time = time;
    sc.ident = S.identity;
    sc.health = S.health;
    sc.bloom = S.bloom;
    sc.ageDays = S.ageDays;
    float g = S.growth;
    sc.stage = g < 0.25 ? 0 : (g < 3.0 ? 1 : (g < 10.0 ? 2 : 3));
    sc.s = mix(0.3, 0.5, smoothstep(0.25, 12.0, g));
    sc.hatch = smoothstep(0.06, 0.25, g) * (1.0 - S.unborn);
    sc.wobble = (0.03 * sin(time * 1.3) + (0.06 + 0.12 * sc.hatch) * sin(time * 11.0)
                 * step(0.8 - 0.25 * sc.hatch, fract(time * 0.13 + seed))) * (1.0 - 0.7 * S.unborn);
    int m = int(S.month);
    sc.season = (m >= 3 && m <= 5) ? 0 : ((m >= 6 && m <= 8) ? 1 : ((m >= 9 && m <= 11) ? 2 : 3));
    sc.droop = clamp((0.6 - S.health) / 0.45, 0.0, 1.0);
    sc.bend = 0.011;

    // ---- what it is doing
    float az = TWO_PI * fract(seed * 7.31 + S.identity) + time * 0.02 * u.drift;
    float2 right = float2(cos(az), -sin(az));
    float tl = time + seed * 997.0;
    float chapter = floor(time / CHAPTER);
    float inCh = time - chapter * CHAPTER;
    float2 castle2 = right * 0.5 + float2(sin(az), cos(az)) * 0.35;
    int act = sc.stage == 0 ? ACT_IDLE : (u.act >= 0 ? u.act : pickActivity(chapter, seed, S));
    int prevAct = (chapter < 0.5 || u.act >= 0) ? act : pickActivity(chapter - 1.0, seed, S);
    float rr = hash11(chapter * 3.7 + seed * 17.0);
    float rp = hash11((chapter - 1.0) * 3.7 + seed * 17.0);
    Pose P = makePose(act, tl, rr, sc.s, az, right, castle2, S);
    float k = chapter < 0.5 ? 1.0 : smoothstep(0.0, 2.5, inCh);
    if (k < 1.0) P = blendPose(makePose(prevAct, tl, rp, sc.s, az, right, castle2, S), P, k);
    if (act == ACT_IDLE || act == ACT_SIT || act == ACT_BUILD || act == ACT_PACE || act == ACT_SICK)
        addBeat(P, tl, seed, act, k * k);
    // It notices you when the screensaver comes up (unless it is asleep).
    float dtake = (sc.stage > 0 && act != ACT_SLEEP && chapter < 0.5) ? 1.0 - smoothstep(3.4, 4.3, time) : 0.0;
    if (dtake > 0.0) P = blendPose(P, doubleTake(P, time, az, sc.s), dtake);
    if (sc.stage == 0) { P.pos = float3(0.0); P.yaw = az; }
    float2 cxz = P.pos.xz;
    sc.cpos = float3(cxz.x, groundH(cxz, sc.ident) + P.pos.y, cxz.y);
    // A bad week shows whatever the light: it sags, wider and lower, and has
    // shadows under its eyes when tired.
    float sag = clamp((0.65 - S.health) / 0.45, 0.0, 1.0);
    sc.yaw = P.yaw; sc.sq = P.sq * (1.0 - 0.1 * sag); sc.lean = P.lean; sc.roll = P.roll;
    sc.armL = P.armL; sc.armR = P.armR; sc.eye = P.eye; sc.step = P.step; sc.mouth = P.mouth;
    sc.lid = clamp(P.lid, 0.0, 0.85); sc.lidTilt = P.lidTilt; sc.happy = clamp(P.happy, -1.0, 1.0);
    sc.mouthO = clamp(P.mouthO, 0.0, 1.0); sc.stride = P.stride; sc.reach = P.reach; sc.sit = P.sit;
    sc.bags = clamp(0.9 * max(1.0 - 1.6 * S.energy, 0.0) + 0.6 * sag, 0.0, 1.0);
    sc.cs0 = cos(float3(sc.yaw, sc.lean, sc.roll));
    sc.cs1 = sin(float3(sc.yaw, sc.lean, sc.roll));

    float sick = (act == ACT_SICK ? k : 0.0) + (prevAct == ACT_SICK ? 1.0 - k : 0.0);
    float storm = (act == ACT_PACE ? k : 0.0) + (prevAct == ACT_PACE ? 1.0 - k : 0.0);
    sc.cloud = max(sick, storm) * mix(0.8, 1.0, sc.s);
    sc.cloudDark = storm;
    sc.cloudPos = float3(sc.cpos.x, sc.cpos.y + 2.1 * sc.s + 0.53 + 0.04 * sin(time * 1.3), sc.cpos.z);
    // The castle starts as a mound, grows over the chapter and, when the
    // chapter ends, sinks back into the sand rather than vanishing.
    sc.castle = (act == ACT_BUILD ? k * mix(0.3, 1.0, smoothstep(1.0, CHAPTER * 0.8, inCh)) : 0.0)
              + (prevAct == ACT_BUILD ? 1.0 - k : 0.0);
    sc.castlePos = float3(castle2.x, groundH(castle2, sc.ident), castle2.y);

    // ---- camera
    float3 target = float3(sc.cpos.x * 0.5, 0.35 + sc.s * 0.8, sc.cpos.z * 0.5);
    sc.focus = target.xz;
    float dist = 4.6, height = 2.35;
    Cam cam;
    cam.ro = target + float3(sin(az) * dist, height, cos(az) * dist);
    cam.fw = normalize(target - cam.ro);
    cam.rt = normalize(cross(cam.fw, float3(0.0, 1.0, 0.0)));
    cam.up = cross(cam.rt, cam.fw);
    cam.focal = 2.7;
    float3 rd = normalize(uv.x * cam.rt + uv.y * cam.up + cam.focal * cam.fw);

    // ---- the island's record: trees by age, rocks by identity
    sc.trees = int(clamp(2.0 + floor(S.ageDays / 3.0), 2.0, 8.0));
    float2 camDir = normalize(float2(sin(az), cos(az)));
    for (int i = 0; i < 8; i++) {
        float a = float(i) * 2.39996 + S.identity * 6.283;
        float r = 3.1 + hash11(float(i) * 7.13 + S.identity * 91.0) * 2.6;
        float2 xz = float2(cos(a), sin(a)) * r;
        float born = max(0.0, float(i) - 1.0) * 3.0;
        float size = 0.7 + 0.35 * clamp((S.ageDays - born) / 12.0, 0.0, 1.0);
        // Never let a tree stand between the camera and the critter.
        float blocks = dot(normalize(xz), camDir) > 0.72 ? 1.0 : 0.0;
        sc.tree[i] = float4(xz.x, groundH(xz, sc.ident), xz.y, blocks > 0.5 ? 0.0 : size);
    }
    for (int i = 0; i < 3; i++) {
        float a = float(i) * 2.1 + S.identity * 4.0 + 0.7;
        float2 xz = float2(cos(a), sin(a)) * (ISLAND_R - 0.4 + 0.3 * float(i));
        sc.rock[i] = float4(xz.x, groundH(xz, sc.ident) + 0.05, xz.y, 0.28 + 0.1 * float(i));
    }

    // ---- light from the real clock
    float hour = S.hour + time / 3600.0;
    float ha = (hour - 6.0) / 12.0 * PI;
    float sunUp = sin(ha);
    float3 sunDir = normalize(float3(cos(ha) * 0.85, max(sunUp, -0.3) * 0.95 + 0.05, -0.45));
    float3 moonDir = normalize(float3(-0.4, 0.75, -0.5));
    float night = 1.0 - smoothstep(-0.12, 0.1, sunUp);
    float golden = (1.0 - smoothstep(0.08, 0.42, sunUp)) * (1.0 - night);
    float3 L = normalize(mix(sunDir, moonDir, night));
    float3 sunCol = mix(mix(float3(1.12, 1.04, 0.92), float3(1.25, 0.8, 0.52), golden), float3(0.45, 0.56, 0.95) * 0.75, night);
    float3 skyAmb = mix(mix(float3(0.55, 0.7, 0.95), float3(0.75, 0.6, 0.65), golden), float3(0.2, 0.27, 0.52), night);

    // ---- which objects this ray can meet
    sc.mask = 0u;
    for (int i = 0; i < 8; i++) {
        float4 T = sc.tree[i];
        if (i < sc.trees && T.w > 0.0 && rayReaches(cam.ro, rd, T.xyz + float3(0.0, 1.0 * T.w, 0.0), 1.2 * T.w, sc))
            sc.mask |= 1u << uint(i);
    }
    if (rayReaches(cam.ro, rd, sc.cpos + float3(0.0, 1.1 * sc.s, 0.0), 2.4 * sc.s + 0.25, sc)) sc.mask |= 256u;
    for (int i = 0; i < 3; i++)
        if (rayReaches(cam.ro, rd, sc.rock[i].xyz, sc.rock[i].w + 0.25, sc)) sc.mask |= 512u;
    if (sc.cloud > 0.01 && rayReaches(cam.ro, rd, sc.cloudPos, 0.9 * sc.cloud + 0.3, sc)) sc.mask |= 1024u;
    if (sc.castle > 0.001 && rayReaches(cam.ro, rd, sc.castlePos + float3(0.0, 0.2, 0.0), 0.75, sc)) sc.mask |= 2048u;

    // ---- march
    float t = 0.5;
    float3 hit = float3(0.0);
    bool found = false;
    // Pass 1 leaves the flowers out, so it can stride over open ground.
    for (int i = 0; i < 96; i++) {
        float3 p = cam.ro + rd * t;
        float4 h = mapScene(p, sc, true, false);
        if (h.x < 0.0005 * t) { hit = h.xyz; found = true; break; }
        float step = h.x * 0.85;
        // Over open ground the sphere step is the height above it, which
        // crawls on a grazing ray. If the ground is what is nearest, step by
        // the vertical gap over the ray's descent instead (slopes here stay
        // under 0.4).
        if (h.y == M_GROUND || h.y == M_SEA) {
            float2 dq = p.xz - sc.focus;
            float vy = rd.y + 2.0 * sc.bend * dot(dq, rd.xz);
            float gap = h.x / 0.8;
            float along = 0.9 * gap / max(-vy + 0.4 * length(rd.xz), 0.05);
            step = max(step, min(along, h.w * 0.85));
        }
        t += step;
        // Above everything and climbing (the bend only lifts it further): sky.
        if (t > 45.0 || (p.y + sc.bend * dot(p.xz - sc.focus, p.xz - sc.focus) > 2.6 && rd.y > 0.0)) break;
    }
    // Pass 2: if that landed on the meadow, back up to the top of the flower
    // layer and come down again with the flowers in.
    if (found && hit.y == M_GROUND) {
        float3 p = cam.ro + rd * t;
        float2 dq = p.xz - sc.focus;
        if (length(p.xz) < ISLAND_R - 1.2 && length(p.xz) > 1.1) {
            float vy = rd.y + 2.0 * sc.bend * dot(dq, rd.xz);
            float tg = t;
            float tb = max(0.5, t - 0.34 / max(-vy, 0.08));
            for (int i = 0; i < 24; i++) {
                float3 h = mapMeadow(cam.ro + rd * tb, sc);
                if (h.x < 0.0003 * tb) { if (h.y != M_GROUND) { hit = h.xyz; t = tb; } break; }
                tb += h.x * 0.9;
                if (tb > tg - 0.001) break;
            }
        }
    }

    float3 col;
    if (!found) {
        col = skyColor(rd, sunDir, moonDir, night, golden, time);
    } else {
        float3 p = cam.ro + rd * t;
        float3 q = bendP(p, sc);
        float mat = hit.y;
        float3 n;
        if (mat == M_GROUND || mat == M_SEA) {
            // Height field: the normal of q.y = groundH(q.xz) in world space.
            float2 dq = p.xz - sc.focus;
            float2 grad = 2.0 * sc.bend * dq;
            if (mat == M_GROUND) {
                const float e = 0.01;
                float h0 = groundH(q.xz, sc.ident);
                grad = float2(groundH(q.xz + float2(e, 0.0), sc.ident) - h0,
                              groundH(q.xz + float2(0.0, e), sc.ident) - h0) / e - grad;
                n = normalize(float3(-grad.x, 1.0, -grad.y));
            } else {
                n = normalize(float3(grad.x, 1.0, grad.y));
            }
        } else {
            n = calcNormal(p, sc);
        }
        float3 alb = float3(0.5);
        float spec = 0.0, shine = 16.0, emit = 0.0, rim = 0.0;
        float gh = groundH(q.xz, sc.ident);
        float season = float(sc.season);

        float3 palette[5] = { float3(0.5, 0.85, 0.66), float3(1.0, 0.66, 0.52), float3(1.0, 0.84, 0.42),
                              float3(0.74, 0.64, 0.96), float3(0.52, 0.74, 1.0) };
        float3 bodyCol = palette[int(S.identity * 5.0) % 5];
        bodyCol = mix(bodyCol, float3(0.64, 0.66, 0.58), (1.0 - S.health) * 0.65);

        if (mat == M_GROUND) {
            float3 lush = season == 3.0 ? float3(0.86, 0.9, 0.94)
                        : (season == 2.0 ? float3(0.6, 0.74, 0.42) : float3(0.52, 0.78, 0.44));
            float3 dry = float3(0.74, 0.68, 0.42);
            float3 grass = mix(lush, dry, smoothstep(0.65, 0.2, S.health) * (season == 3.0 ? 0.2 : 1.0));
            float dap = valueNoise(q.xz * 2.2 + 7.0);
            grass *= 0.88 + 0.2 * dap;
            float tri = step(0.82, hash21(floor(q.xz * 5.0))) * step(fract(q.z * 5.0), 1.0 - abs(fract(q.x * 5.0) - 0.5) * 2.0);
            grass *= 1.0 - 0.1 * tri;
            float3 sand = float3(0.97, 0.89, 0.7) * (0.95 + 0.08 * valueNoise(q.xz * 6.0));
            float wet = smoothstep(SEA_Y + 0.08, SEA_Y, gh);
            sand = mix(sand, sand * float3(0.82, 0.78, 0.7), wet);
            alb = mix(grass, sand, smoothstep(0.0, -0.1, gh));
            // a worn patch where the critter stands
            alb = mix(alb, float3(0.78, 0.7, 0.52), (1.0 - smoothstep(0.35, 0.8, length(q.xz))) * 0.35 * (season == 3.0 ? 0.0 : 1.0));
        } else if (mat == M_SEA) {
            float depth = SEA_Y - gh;
            alb = mix(float3(0.42, 0.9, 0.86), float3(0.18, 0.46, 0.78), smoothstep(0.0, 0.7, depth));
            alb = mix(alb, alb * float3(0.35, 0.45, 0.7), night * 0.5);
            float ang = atan2(q.z, q.x);
            float foam = 1.0 - smoothstep(0.0, 0.05 + 0.025 * sin(time * 1.4 + ang * 9.0), depth);
            float ripple = valueNoise(q.xz * 3.0 + float2(time * 0.25, time * 0.18));
            alb += ripple * 0.06;
            alb = mix(alb, float3(1.0), foam * 0.85);
            spec = 0.9; shine = 80.0;
            n = normalize(n + float3(0.05 * sin(q.x * 4.0 + time), 0.0, 0.05 * cos(q.z * 4.0 + time * 1.2)));
        } else if (mat == M_BODY) {
            float3 lp = critterLocal(q, sc);
            float s = sc.s;
            float hz = rsqrt(sc.sq);
            float3 bc = float3(0.0, 0.95 * s * sc.sq, 0.0);
            float3 rel = (lp - bc) / s;
            // Its own colour, only a little greyed by a bad week (the sag,
            // the wilt and the tired eyes say the rest, and survive the night).
            alb = mix(palette[int(S.identity * 5.0) % 5], float3(0.64, 0.66, 0.58), (1.0 - S.health) * 0.3);
            // lighter tummy
            alb = mix(alb, mix(alb, float3(1.0, 0.98, 0.92), 0.55),
                      smoothstep(0.35, 0.7, rel.z) * smoothstep(0.25, -0.3, rel.y));
            // blush
            float2 ck = float2(abs(rel.x) - 0.56 * hz, rel.y + 0.1);
            alb = mix(alb, float3(1.0, 0.55, 0.6), smoothstep(0.15, 0.06, length(ck)) * step(0.0, rel.z) * 0.8);
            // shadows under the eyes when it is worn out
            float2 ue = float2(abs(rel.x) - 0.34 * hz, rel.y - 0.1 * sc.sq);
            float bag = smoothstep(0.22, 0.06, abs(length(ue / float2(0.12, 0.19)) - 1.0))
                      * smoothstep(-0.07, -0.13, ue.y) * step(0.3, rel.z);
            alb = mix(alb, alb * float3(0.55, 0.45, 0.68), bag * sc.bags * 0.85);
            // mouth: a curve deep enough to read as a smile or a frown from
            // across the room, or an open "o" (a "D" when it is happy)
            float mx = rel.x, my = rel.y + 0.14 * sc.sq;
            float amp = 5.4 * sc.mouth;
            float cx = clamp(mx, -0.12, 0.12);
            float slope = amp * 2.8 * cx;
            float dm = length(float2(mx - cx, (my + amp * (0.01 - cx * cx * 1.4)) * rsqrt(1.0 + slope * slope)));
            float line = smoothstep(0.03, 0.02, dm) * (1.0 - smoothstep(0.15, 0.4, sc.mouthO));
            float2 orad = float2(0.04 + 0.04 * sc.mouthO, 0.02 + 0.07 * sc.mouthO);
            float2 mo = float2(mx, my + 0.01) / orad;
            float lip = mo.y - (1.0 - 0.75 * clamp(sc.mouth, 0.0, 1.0));   // flat top on a "D"
            float open = smoothstep(1.0, 0.85, max(length(mo), 1.0 + lip)) * step(0.05, sc.mouthO);
            alb = mix(alb, float3(0.28, 0.12, 0.12), max(line, open) * step(0.5, rel.z));
            alb = mix(alb, float3(0.95, 0.45, 0.5), open * smoothstep(-0.25, -0.6, mo.y) * step(0.5, rel.z));
            // feet a shade darker
            alb *= mix(1.0, 0.85, smoothstep(0.3, 0.15, lp.y / s));
            // a warm fill at night, so its colour survives the moonlight
            alb *= mix(float3(1.0), float3(1.6, 1.35, 1.0), night);
            emit = night * 0.035 * (0.4 + 0.6 * max(dot(n, -rd), 0.0));
            spec = 0.18; shine = 20.0; rim = 0.55;
        } else if (mat == M_EYE) {
            float3 lp = critterLocal(q, sc);
            float s = sc.s;
            float hz = rsqrt(sc.sq);
            float3 bc = float3(0.0, 0.95 * s * sc.sq, 0.0);
            float3 e = lp - (bc + float3(sign(lp.x) * 0.34 * hz * s, 0.1 * s * sc.sq, 0.83 * hz * s));
            alb = float3(0.04, 0.035, 0.06);
            float glint = smoothstep(0.03 * s, 0.018 * s, length(e.xy - float2(0.025, 0.045) * s));
            alb = mix(alb, float3(1.6), glint * step(0.3, sc.eye) * step(sc.lid, 0.4) * (1.0 - abs(sc.happy)));
            spec = 1.0; shine = 60.0;
        } else if (mat == M_LEAF) {
            alb = mix(float3(0.42, 0.76, 0.3), float3(0.62, 0.55, 0.3), sc.droop * 0.8);
            emit = night * 0.25 * S.health;
        } else if (mat == M_TRUNK) {
            alb = float3(0.55, 0.38, 0.25) * (0.85 + 0.15 * sin(q.y * 40.0 + q.x * 7.0));
        } else if (mat == M_CANOPY) {
            float h = hash11(hit.z * 4.1 + S.identity * 9.0);
            float3 c;
            if (season == 0.0) c = mix(float3(0.5, 0.78, 0.38), float3(1.0, 0.75, 0.82), step(0.5, h));
            else if (season == 1.0) c = float3(0.3, 0.62, 0.3) * (0.9 + 0.2 * h);
            else if (season == 2.0) c = h < 0.33 ? float3(1.0, 0.62, 0.24) : (h < 0.66 ? float3(0.96, 0.44, 0.26) : float3(1.0, 0.8, 0.32));
            else c = float3(0.22, 0.45, 0.32);
            c = mix(c, c * float3(0.85, 0.8, 0.6), (1.0 - S.health) * 0.5);
            float bump = valueNoise(q.xz * 7.0 + q.y * 5.0);
            c *= 0.85 + 0.25 * bump;
            if (season == 3.0) c = mix(c, float3(0.97, 0.98, 1.0), smoothstep(0.45, 0.75, n.y));
            alb = c;
            rim = 0.25;
        } else if (mat == M_PETAL) {
            float h = hit.z;
            float3 pal[6] = { float3(1.0, 0.98, 0.95), float3(1.0, 0.6, 0.72), float3(1.0, 0.86, 0.3),
                              float3(0.95, 0.35, 0.35), float3(0.72, 0.58, 1.0), float3(1.0, 0.62, 0.3) };
            alb = pal[int(fract(h * 7.31) * 6.0)];
        } else if (mat == M_FCORE) {
            alb = float3(1.0, 0.82, 0.25);
        } else if (mat == M_EGG) {
            float3 lp = critterLocal(q, sc);
            lp.xy = rotate(lp.xy, sc.wobble);
            alb = float3(0.99, 0.96, 0.88);
            float spots = smoothstep(0.62, 0.66, valueNoise(lp.xy * 9.0 + lp.z * 7.0 + S.identity * 20.0));
            alb = mix(alb, bodyCol * 0.9, spots);
            float ang = atan2(lp.z, lp.x);
            float zig = 0.43 + 0.035 * (2.0 * abs(fract(ang * 2.2) - 0.5) * 2.0 - 1.0);
            float crack = step(abs(lp.y - zig), 0.008 + 0.006 * sc.hatch) * step(0.05, sc.hatch)
                        * step(fract(ang / TWO_PI + 0.5), 0.25 + 0.75 * sc.hatch);
            alb = mix(alb, float3(0.35, 0.28, 0.22), crack);
            spec = 0.3; shine = 30.0; rim = 0.3;
        } else if (mat == M_NEST) {
            alb = float3(0.78, 0.62, 0.36) * (0.8 + 0.3 * valueNoise(q.xz * 40.0));
        } else if (mat == M_ROCK) {
            alb = float3(0.62, 0.62, 0.64) * (0.85 + 0.2 * valueNoise(q.xz * 8.0 + q.y * 6.0));
        } else if (mat == M_FRUIT) {
            alb = sc.season == 2 ? float3(1.0, 0.45, 0.15) : float3(0.95, 0.2, 0.2);
            spec = 0.6; shine = 40.0;
        } else if (mat == M_CLOUD) {
            // slate, not black: lit on top, a shade darker underneath
            alb = mix(float3(0.74, 0.78, 0.86), float3(0.52, 0.55, 0.66), sc.cloudDark);
            alb *= mix(0.8, 1.2, smoothstep(-0.3, 0.7, n.y));
            emit = sc.cloudDark * step(0.9, fract(time * 0.37)) * step(0.4, fract(time * 9.0)) * 1.5;
        } else if (mat == M_BLOSSOM) {
            float hue = fract(S.identity * 3.7);
            alb = mix(float3(1.0, 0.55, 0.7), float3(1.0, 0.85, 0.35), hue);
            emit = night * 0.35;
        } else if (mat == M_CASTLE) {
            alb = float3(0.93, 0.83, 0.6) * (0.9 + 0.12 * valueNoise(q.xz * 30.0 + q.y * 20.0));
        }
        alb = srgb(alb);

        float ndl = dot(n, L);
        int self = mat == M_CANOPY || mat == M_TRUNK || mat == M_FRUIT ? int(hit.z)
                 : (mat == M_BODY || mat == M_EYE || mat == M_LEAF || mat == M_EGG || mat == M_BLOSSOM ? 8 : -1);
        if (mat == M_LEAF && length(q - sc.cpos) > 2.5 * sc.s) self = -1;   // a flower stem, not the sprout
        float sh = mat == M_SEA && t > 9.0 ? 1.0 : softShadow(q + n * 0.01, L, sc, self);
        float2 cs = q.xz * 0.16 + float2(0.05, 0.022) * time;
        float cloudShade = smoothstep(0.52, 0.72, valueNoise(cs) * 0.65 + valueNoise(cs * 2.3 + 5.0) * 0.35);
        sh *= 1.0 - 0.42 * cloudShade * (1.0 - night);
        float dif = smoothstep(-0.05, 0.3, ndl) * mix(0.25, 1.0, sh);
        float ao = ambientOcc(q, n, sc, self);
        float3 lin = srgb(sunCol) * dif * 1.05;
        lin += srgb(skyAmb) * (0.55 + 0.45 * n.y) * 0.5 * ao;
        lin += srgb(float3(0.5, 0.65, 0.35)) * (0.5 - 0.5 * n.y) * 0.18 * ao * (1.0 - 0.85 * night);
        col = alb * lin;
        float3 hv = normalize(L - rd);
        col += srgb(sunCol) * spec * pow(max(dot(n, hv), 0.0), shine) * sh;
        if (mat == M_SEA) {
            float fres = pow(1.0 - max(dot(n, -rd), 0.0), 4.0);
            col = mix(col, srgb(skyColor(reflect(rd, n), sunDir, moonDir, night, golden, time)), fres * 0.7);
        }
        col += srgb(skyAmb) * rim * pow(clamp(1.0 + dot(n, rd), 0.0, 1.0), 3.0) * ao;
        col += emit * srgb(float3(1.0, 0.9, 0.55));
        // Haze toward the horizon.
        float fog = 1.0 - exp(-0.00035 * t * t);
        float3 haze = mix(mix(float3(0.62, 0.82, 0.98), float3(1.0, 0.66, 0.46), golden), float3(0.09, 0.12, 0.26), night);
        col = mix(col, srgb(haze), fog);
        col = sqrt(max(col, 0.0));
    }
    float depth = found ? t : 1e5;

    // ---- floating things: Zzz, hearts, sparkles, rain, butterfly, fireflies
    float3 head = unbendP(sc.cpos + float3(0.0, 2.1 * sc.s, 0.0), sc);
    float zzz = (act == ACT_SLEEP ? k : 0.0) + (prevAct == ACT_SLEEP ? 1.0 - k : 0.0);
    if (zzz > 0.01) {
        for (int i = 0; i < 3; i++) {
            float ph = fract(time * 0.22 + float(i) / 3.0);
            float3 wp = head + cam.rt * (0.15 + 0.35 * ph) + float3(0.0, 0.0 + 0.5 * ph, 0.0);
            float3 pj = project(wp, cam);
            float size = (0.07 + 0.08 * ph) * cam.focal / pj.z;
            float d = sdZ((uv - pj.xy) / size) * size;
            float a = sin(ph * PI) * zzz * step(pj.z, depth);
            col = mix(col, float3(0.25, 0.3, 0.45), a * smoothstep(0.16 * size, 0.1 * size, d));
            col = mix(col, float3(1.0), a * smoothstep(0.09 * size, 0.04 * size, d));
        }
    }
    float love = ((act == ACT_WAVE || act == ACT_STRETCH) ? k : 0.0)
               + ((prevAct == ACT_WAVE || prevAct == ACT_STRETCH) ? 1.0 - k : 0.0);
    love = max(love, dtake * smoothstep(1.6, 2.2, time));
    if (love > 0.01) {
        for (int i = 0; i < 2; i++) {
            float ph = fract(time * 0.3 + float(i) * 0.5);
            float3 wp = head + cam.rt * (0.35 * sin(float(i) * 2.0 + 1.0) - 0.15) + float3(0.0, 0.0 + 0.45 * ph, 0.0);
            float3 pj = project(wp, cam);
            float size = 0.12 * cam.focal / pj.z;
            float d = sdHeart((uv - pj.xy) / size) * size;
            float a = sin(ph * PI) * love;
            col = mix(col, float3(1.0), a * smoothstep(0.1 * size, 0.04 * size, d));
            col = mix(col, float3(1.0, 0.4, 0.5), a * smoothstep(0.02 * size, -0.03 * size, d));
        }
    }
    float glee = (((act == ACT_HOP || act == ACT_CHASE) ? k : 0.0)
               + ((prevAct == ACT_HOP || prevAct == ACT_CHASE) ? 1.0 - k : 0.0)) * smoothstep(0.55, 0.8, S.joy);
    if (glee > 0.01) {
        for (int i = 0; i < 5; i++) {
            float ph = fract(time * 0.45 + float(i) * 0.2 + hash11(float(i)) * 0.3);
            float a0 = float(i) * 1.257 + floor(time * 0.45 + float(i) * 0.2) * 2.1;
            float3 wp = unbendP(sc.cpos, sc) + float3(cos(a0) * 0.6 * sc.s * 2.0, (1.0 + 1.6 * ph) * sc.s, sin(a0) * 0.6 * sc.s * 2.0);
            float3 pj = project(wp, cam);
            float size = 0.09 * cam.focal / pj.z * sin(ph * PI);
            float2 g2 = abs(uv - pj.xy) / max(size, 1e-4);
            float star = smoothstep(1.0, 0.6, sqrt(g2.x) + sqrt(g2.y)) * step(pj.z, depth + 0.3);
            col = mix(col, float3(1.0, 0.97, 0.75), star * glee);
        }
    }
    if (sick > 0.01) {
        float3 cp = project(unbendP(sc.cloudPos, sc), cam);
        float3 fp = project(unbendP(sc.cpos, sc), cam);
        float w = 0.35 * sc.cloud * cam.focal / cp.z;
        float lane = 0.016 * cam.focal / cp.z * 4.0;
        float colId = floor((uv.x - cp.x) / lane);
        float hr = hash11(colId * 1.7 + 0.3);
        float ph = fract(hr + time * (0.9 + 0.5 * hr));
        float dropY = mix(cp.y - 0.05, fp.y, ph);
        float inside = step(abs(uv.x - cp.x), w) * smoothstep(0.2, 0.08, abs(fract((uv.x - cp.x) / lane) - 0.5));
        float streak = smoothstep(0.045, 0.0, abs(uv.y - dropY)) * inside * step(0.3, hr);
        col = mix(col, float3(0.62, 0.76, 1.0), streak * 0.8 * sick);
    }
    // Lightning out of the storm cloud, to the ground beside it.
    float flash = storm * step(0.9, fract(time * 0.37)) * step(0.4, fract(time * 9.0));
    if (flash > 0.01) {
        float3 top = project(unbendP(sc.cloudPos + float3(0.0, -0.08, 0.0), sc), cam);
        float3 g0 = sc.cpos + float3(cam.rt.x, 0.0, cam.rt.z) * (0.75 + 1.4 * sc.s);
        float3 bot = project(unbendP(float3(g0.x, groundH(g0.xz, sc.ident), g0.z), sc), cam);
        float2 ax = bot.xy - top.xy, nx = normalize(float2(-ax.y, ax.x)) * 0.025 * cam.focal / top.z;
        float bolt = 1e5;
        float2 pa = top.xy;
        for (int i = 1; i <= 4; i++) {
            float2 pb = top.xy + ax * (float(i) / 4.0) + nx * (i == 4 ? 0.0 : (i % 2 == 1 ? 1.0 : -1.0));
            bolt = min(bolt, sdSeg(uv, pa, pb));
            pa = pb;
        }
        float bw = 0.006 * cam.focal / top.z;
        col = mix(col, float3(0.35, 0.3, 0.55), flash * smoothstep(2.6 * bw, 1.8 * bw, bolt));
        col = mix(col, float3(1.0, 0.96, 0.62), flash * smoothstep(1.3 * bw, 0.6 * bw, bolt));
        col += 0.07 * flash;
    }
    // Frazzled: a scribble beside its head that keeps redrawing itself.
    float stress = clamp((0.4 - S.calm) / 0.3, 0.0, 1.0);
    float zzzOff = 1.0 - min(zzz, 1.0);
    float frazzle = max(storm, stress * 0.8) * zzzOff * (1.0 - dtake) * step(0.5, float(sc.stage));
    if (frazzle > 0.01) {
        float3 pj = project(unbendP(sc.cpos + float3(0.0, 1.95 * sc.s, 0.0), sc) - cam.rt * 1.05 * sc.s, cam);
        float size = 0.15 * cam.focal / pj.z;
        float2 b = (uv - pj.xy) / size;
        if (dot(b, b) < 2.6) {
            float d = 1e5;
            float jit = floor(time * 5.0);
            float2 prev = float2(0.0);
            for (int i = 0; i <= 18; i++) {
                float th = float(i) * 0.7 + jit * 0.37;
                float2 cur = float2(cos(th) + 0.45 * cos(3.7 * th + jit), 0.8 * sin(th) + 0.45 * sin(2.9 * th + 1.3 * jit)) * 0.62;
                if (i > 0) d = min(d, sdSeg(b, prev, cur));
                prev = cur;
            }
            col = mix(col, float3(0.22, 0.2, 0.3), frazzle * smoothstep(0.085, 0.045, d) * step(pj.z, depth + 0.3));
        }
    }
    // A sweat drop when it is stressed or poorly, sliding down by its head.
    float sweat = max(max(storm, sick), stress) * zzzOff * (1.0 - dtake) * step(0.5, float(sc.stage));
    if (sweat > 0.01) {
        float ph = fract(time * 0.45);
        float3 pj = project(unbendP(sc.cpos + float3(0.0, (1.7 - 0.35 * ph) * sc.s, 0.0), sc) + cam.rt * 1.05 * sc.s, cam);
        float size = 0.12 * cam.focal / pj.z;
        float2 b = (uv - pj.xy) / size;
        float tear = length(float2(b.x * (1.0 + 1.8 * max(b.y, 0.0)), b.y)) - 0.5;
        float a = sweat * smoothstep(0.0, 0.15, ph) * smoothstep(1.0, 0.75, ph) * step(pj.z, depth + 0.3);
        col = mix(col, float3(0.2, 0.33, 0.6), a * smoothstep(0.12, 0.06, tear));
        col = mix(col, float3(0.68, 0.87, 1.0), a * smoothstep(0.03, -0.02, tear));
        col = mix(col, float3(1.0), a * smoothstep(0.12, 0.07, length(b - float2(-0.16, -0.08))));
    }
    // "!" — it has noticed you.
    float bang = dtake * smoothstep(0.5, 0.6, time) * (1.0 - smoothstep(1.9, 2.3, time));
    if (bang > 0.01) {
        float3 pj = project(head + float3(0.0, 0.12, 0.0) + cam.rt * 0.45 * sc.s, cam);
        float pop = smoothstep(0.5, 0.62, time) * (1.0 + 0.4 * exp(-max(time - 0.62, 0.0) * 8.0));
        float size = 0.24 * pop * cam.focal / pj.z;
        float2 b = (uv - pj.xy) / max(size, 1e-4);
        float d = min(sdSeg(b, float2(0.0, 0.08), float2(0.0, 0.62)) - (0.08 + 0.07 * clamp(b.y / 0.62, 0.0, 1.0)),
                      length(b - float2(0.0, -0.24)) - 0.12);
        col = mix(col, float3(0.3, 0.16, 0.1), bang * smoothstep(0.11, 0.07, d));
        col = mix(col, float3(1.0, 0.84, 0.25), bang * smoothstep(0.035, 0.0, d));
    }
    // The butterfly: big, saturated and outlined so it stands out from the
    // falling petals, with a dotted trail. Its phase runs on, so a chase
    // that follows a chase does not jump.
    float flutter = (act == ACT_CHASE ? k : 0.0) + (prevAct == ACT_CHASE ? 1.0 - k : 0.0);
    if (flutter > 0.01) {
        float3 pal[4] = { float3(1.0, 0.5, 0.05), float3(0.15, 0.5, 1.0), float3(1.0, 0.25, 0.65), float3(1.0, 0.82, 0.05) };
        float3 wc = pal[int(fract(S.identity * 5.3) * 4.0) % 4];
        for (int j = 6; j >= 0; j--) {
            float tj = time - float(j) * 0.14;
            float a = (tl - float(j) * 0.14) * 0.55;
            float3 fly = unbendP(float3(cos(a) * 1.3, 0.0, sin(a) * 1.3), sc);
            fly.y = groundH(fly.xz, sc.ident) - sc.bend * dot(fly.xz - sc.focus, fly.xz - sc.focus)
                  + 0.75 + 0.18 * sin(tj * 3.1);
            float3 pj = project(fly, cam);
            float vis = step(pj.z, depth + 0.2) * flutter;
            if (j > 0) {
                if (j == 1) continue;
                float dot0 = length(uv - pj.xy) - 0.007 * cam.focal / pj.z;
                col = mix(col, float3(1.0), vis * 0.55 * (1.0 - float(j) / 7.0) * smoothstep(0.004, 0.0, dot0));
                continue;
            }
            float size = 0.4 * cam.focal / pj.z;
            float2 bp = (uv - pj.xy) / size;
            if (dot(bp, bp) > 2.0) continue;
            float flap = 0.25 + 0.75 * abs(sin(time * 13.0));
            float2 wp = float2(abs(bp.x) / flap - 0.45, bp.y - 0.1);
            float wing = min(length(wp * float2(1.0, 0.9)) - 0.42, length((wp - float2(-0.05, -0.45)) * float2(1.2, 1.0)) - 0.28);
            col = mix(col, float3(0.12, 0.08, 0.14), smoothstep(0.08, 0.04, wing * flap) * vis);
            float3 wcol = mix(wc, float3(1.0), smoothstep(0.1, 0.05, length(wp - float2(0.12, 0.12))));
            col = mix(col, wcol, smoothstep(0.02, -0.02, wing) * vis);
            col = mix(col, float3(0.12, 0.08, 0.14), smoothstep(0.1, 0.05, length(bp * float2(2.2, 0.55))) * vis);
        }
    }
    if (night > 0.2 && S.health > 0.4) {
        int count = int(4.0 + 10.0 * S.health);
        for (int i = 0; i < 14; i++) {
            if (i >= count) break;
            float fi = float(i);
            float a = fi * 2.4 + time * (0.05 + 0.04 * hash11(fi)) + S.identity * 3.0;
            float r = 1.8 + 3.5 * hash11(fi * 3.3);
            float2 xz = float2(cos(a), sin(a)) * r;
            float3 wp = unbendP(float3(xz.x, groundH(xz, sc.ident) + 0.35 + 0.25 * sin(time * 0.7 + fi), xz.y), sc);
            float3 pj = project(wp, cam);
            float glow = exp(-dot(uv - pj.xy, uv - pj.xy) / pow(0.012 * cam.focal / pj.z * 6.0, 2.0) * 3.0);
            float pulse = 0.5 + 0.5 * sin(time * 2.0 + fi * 1.7);
            col += float3(0.85, 1.0, 0.45) * glow * pulse * night * step(pj.z, depth + 0.3) * 0.9;
        }
    }

    // ---- the season in the air, in front of everything: spring petals,
    // summer seed fluff, autumn leaves, winter snow. Three layers for depth.
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float cell = 0.2 - 0.045 * fl;
        float fall = (sc.season == 1 ? -0.03 : (sc.season == 3 ? 0.07 : 0.055)) * (1.0 - 0.25 * fl);
        float2 pp = uv + float2(0.025 * time * (sc.season == 3 ? 0.3 : 1.0) + fl * 3.1, fall * time);
        float2 id = floor(pp / cell);
        float hp1 = hash21(id + fl * 17.0);
        if (hp1 > (sc.season == 3 ? 0.55 : 0.3)) continue;
        float2 f = fract(pp / cell) - 0.5;
        float2 jit = (hash22(id + 3.0 + fl) - 0.5) * 0.36;
        float ph = time * (0.8 + hp1 * 2.0) + hp1 * 40.0;
        f -= jit + float2(0.07 * sin(ph), 0.0);
        float size = (0.17 + 0.07 * hp1) * (1.0 - 0.22 * fl);
        float2 g2 = rotate(f, ph * 0.7) / size;
        float shape, tone = hash11(hp1 * 91.0);
        float3 pc;
        if (sc.season == 3) {
            shape = length(g2) - 0.55;
            pc = float3(1.0);
        } else if (sc.season == 1) {
            shape = min(length(g2) - 0.25, length(float2(abs(g2.x), g2.y * 0.9) - float2(0.25, 0.25)) - 0.2);
            pc = float3(1.0, 1.0, 0.95);
        } else {
            g2.x *= 1.0 + 0.6 * sin(ph * 2.0);     // tumbling
            shape = length(g2 * float2(1.0, 2.0)) - 0.6;
            pc = sc.season == 2
               ? (tone < 0.33 ? float3(1.0, 0.55, 0.2) : (tone < 0.66 ? float3(0.92, 0.32, 0.2) : float3(1.0, 0.78, 0.28)))
               : (tone < 0.5 ? float3(1.0, 0.72, 0.8) : float3(1.0, 0.86, 0.9));
        }
        float a = smoothstep(0.06, -0.06, shape) * (0.85 - 0.2 * fl) * mix(1.0, 0.45, night);
        col = mix(col, pc * mix(1.0, 0.5, night), a);
    }

    // ---- finish: gentle vignette, a little warmth
    float2 sp = lerpScreenUV(pos, u.resolution) - 0.5;
    col *= 1.0 - 0.28 * dot(sp, sp) * 1.6;
    col = lerpDither(col, pos);
    return half4(half3(clamp(col, 0.0, 1.0)), 1.0h);
}
