// Hedge Maze — the Maze (an homage to Microsoft's 3D Maze screensaver, ssmaze,
// Windows 95) rebuilt as a block-world garden at night. Original work for
// Lerping@Home: every block, texture and sky here is procedural and written
// for this file; no code, textures or artwork from the original screensaver
// or from any block game.
//
// lerp-category: Blocks
// lerp-data: maze
//
// The same walk as `maze` — a perfect maze solved hand-on-the-wall, carved and
// timed by MazeData.swift — through a different place. The corridors are
// three blocks wide between hedges of leaf blocks three high, open to the
// night: a square moon throws block shadows across the grass, flat cube
// clouds drift over, and stone pillars stand at the junctions, some capped
// with a lantern block that lights the corners round it. The worn path down
// the middle of every corridor is the maze itself, drawn on the ground.
//
// The original's spinning polyhedra are small glowing blocks, turning and
// bobbing at eye height the way a dropped block does; walk through one and
// the world rolls over until you reach the next. The goal is a beacon on an
// iron plinth whose beam stands over the hedges from the first step, so the
// whole walk has somewhere to be going.
//
// Every maze is a different garden — oak hedge and stone pillars, spruce and
// mossy stone, flowering hedge and birch, autumn hedge and dark oak — never
// the same one twice running. Hedge walls beside the route are sometimes hung
// with glowing berries, and a few square fireflies drift about the cells.
//
// Lighting is worked out per texel, not per pixel, so moon shadows and lamp
// pools step in sixteenths of a block like the textures do. Textures are
// sharp-edged texels filtered to the pixel footprint: crisp up close, an even
// tone a few blocks off, with no crawl in between. A pixel takes one ray;
// only where a real edge of geometry crosses it (a hedge top against the
// sky, a corner, the foot of a wall) does it take two more.
//
// lerp-param: size        int 4 40     = 10      "Maze size"
// lerp-param: speed       float 0.25 4 = 0.8     "Walk speed (cells/s)"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -60 60   = 0 "Tilt"
// lerp-param: magnify  float -1 1.5 = 0 "Zoom"
// lerp-param: flips       bool         = true    "Flip blocks"
// lerp-param: style       int 0 4      = 0       "Garden (0 = new each maze)"
// lerp-param: colorGoal   color        = #7fe8ff "Beacon"
// lerp-param: light       float 0 2    = 1       "Brightness"
//
// lerp-preset: Labyrinth size=24, speed=1.6
// lerp-preset: Autumn style=4
// lerp-preset: "Spruce and Moss" style=2

// --- Geometry, in blocks. A maze cell is 4 blocks: a 1-block wall line and a
// 3-block corridor. Cell coordinate c maps to block coordinate 4c + 0.5, so a
// grid line runs down the middle of its column of wall blocks.
constant float HM_EYE    = 1.62;    // eye height
constant float HM_FOCAL  = 1.2;     // ~80° vertical field of view
constant float HM_TOP    = 4.05;    // nothing solid above this
constant float HM_FOG0   = 13.0;    // fog starts
constant float HM_FOG1   = 40.0;    // and is total; nothing is traced past it
constant float HM_CLOUD_Y = 30.0;   // cloud deck height
constant float HM_CLOUD_C = 6.0;    // cloud cell size
constant float HM_LAMP_R = 6.0;     // lantern reach (the 3x3 lookup covers 6)

constant int HM_STEPS = 64;         // primary DDA, covers HM_FOG1 on a diagonal
constant int HM_SHADOW_STEPS = 12;  // moon shadow DDA: rises past HM_TOP in ~9

// Materials.
#define HM_GRASS   0
#define HM_PATH    1
#define HM_LEAF    2
#define HM_STONE   3
#define HM_LOG     4
#define HM_LANTERN 5
#define HM_IRON    6
#define HM_BEACON  7
#define HM_GEM     8

// ---------------------------------------------------------------------------
// Hashes.

static inline uint hmH(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

static inline float hmR(int3 b, int2 t, uint salt) {
    uint k = uint(b.x) * 0x8da6b343u + uint(b.y) * 0xd8163841u + uint(b.z) * 0xcb1ab31fu
           + uint(t.x) * 0x27d4eb2du + uint(t.y) * 0x165667b1u;
    k = hmH(k ^ (salt * 0x9e3779b9u));
    return float(k >> 8) * (1.0 / 16777216.0);
}

static inline float3 hmLin(float3 c) { return pow(max(c, 0.0), 2.2); }

// ---------------------------------------------------------------------------
// The world.

struct HmEnv {
    uint2  cells;
    int2   goalB;      // the beacon's block column
    float2 goalXZ;     // and its axis
    uint   salt;       // per maze
    uint   style;      // which garden, 0..3
    float  now;
    float  pxA;        // radians per pixel
    float  flash;      // outro 0..1
    float3 moonDir, moonCol, amb, lampCol, goalCol, gemCol;
    float3 zen, hor;
    float3 camR, camU;
};

static inline uint hmRec(device const uint* verts, int2 v, uint2 cells) {
    if (v.x < 0 || v.y < 0 || v.x > int(cells.x) || v.y > int(cells.y)) return 0u;
    return verts[v.y * int(cells.x + 1) + v.x];
}

static inline bool hmHasLamp(int2 v, uint salt) {
    return hmR(int3(v.x, 7, v.y), int2(0), salt) < 0.34;
}

// What stands on block column b: 0 air, 1 hedge, 2 pillar, 3 pillar with a
// lantern on top, 4 the beacon. H is its height.
static inline int hmColumn(int2 b, device const uint* verts, thread const HmEnv& E,
                           thread float& H) {
    int2 ci = b >> 2, r = b & 3;
    H = 0.0;
    if (r.x != 0 && r.y != 0) {
        if (b.x == E.goalB.x && b.y == E.goalB.y) { H = 2.0; return 4; }
        return 0;
    }
    uint rec = hmRec(verts, ci, E.cells);
    if (r.x == 0 && r.y == 0) {
        if (rec == 0u) return 0;
        H = 4.0;
        return hmHasLamp(ci, E.salt) ? 3 : 2;
    }
    uint bit = r.x == 0 ? 4u : 1u;
    if ((rec & bit) == 0u) return 0;
    // A hedge block here and there has grown a block taller.
    H = hmR(int3(b.x, 3, b.y), int2(1), E.salt) < 0.09 ? 4.0 : 3.0;
    return 1;
}

// Whether anything stands on column b, without working out what.
static inline float hmSolid(int2 b, device const uint* verts, thread const HmEnv& E) {
    int2 r = b & 3;
    if (r.x != 0 && r.y != 0) return (b.x == E.goalB.x && b.y == E.goalB.y) ? 1.0 : 0.0;
    uint rec = hmRec(verts, b >> 2, E.cells);
    if (r.x == 0 && r.y == 0) return rec != 0u ? 1.0 : 0.0;
    return (rec & (r.x == 0 ? 4u : 1u)) != 0u ? 1.0 : 0.0;
}

// The worn path: the centre block of every cell, joined to the centres of
// the cells it opens on to.
static inline bool hmIsPath(int2 b, device const uint* verts, thread const HmEnv& E) {
    int2 ci = b >> 2, r = b & 3;
    if (r.x == 2 && r.y == 2) return true;
    if (r.y == 2) {
        int2 v = r.x == 3 ? ci + int2(1, 0) : ci;
        return (hmRec(verts, v, E.cells) & 4u) == 0u;
    }
    if (r.x == 2) {
        int2 v = r.y == 3 ? ci + int2(0, 1) : ci;
        return (hmRec(verts, v, E.cells) & 1u) == 0u;
    }
    return false;
}

struct HmHit {
    float t;
    float3 n;
    int kind;     // -1 nothing, 0 floor, else the column kind
    int2 b;
    float H;      // the hit column's height
    float clear;  // closest the ray came to passing a column top, in radians
};

// Steps the ray column by column. Everything solid stands on the floor and
// the eye is below every top, so a ray meets a column's side where it enters
// it or passes over it.
static inline HmHit hmTrace(float3 ro, float3 rd, float tFar, device const uint* verts,
                            thread const HmEnv& E) {
    HmHit h;
    h.t = 1e9; h.kind = -1; h.n = float3(0.0); h.b = int2(0); h.H = 0.0; h.clear = 1e9;
    float tFloor = rd.y < -1e-5 ? -ro.y / rd.y : 1e9;
    float tLim = min(tFloor, tFar);
    float2 d = select(rd.xz, float2(1e-7), abs(rd.xz) < 1e-7);
    float2 inv = 1.0 / d;
    int2 b = int2(floor(ro.xz));
    int2 st = int2(sign(d));
    float2 tDelta = abs(inv);
    float2 tMax = (float2(b) + select(float2(0.0), float2(1.0), d > 0.0) - ro.xz) * inv;
    float tEnter = 0.0;
    bool lastX = true;
    for (int i = 0; i < HM_STEPS; ++i) {
        float tExit = min(tMax.x, tMax.y);
        if (i > 0) {
            float H;
            int kind = hmColumn(b, verts, E, H);
            if (kind != 0) {
                float yE = ro.y + rd.y * tEnter;
                if (yE < H) {
                    h.t = tEnter; h.kind = kind; h.b = b; h.H = H;
                    h.n = lastX ? float3(-float(st.x), 0.0, 0.0) : float3(0.0, 0.0, -float(st.y));
                    return h;
                }
                h.clear = min(h.clear, (yE - H) / max(tEnter, 1e-3));
                if (rd.y < 0.0) {
                    float tTop = (H - ro.y) / rd.y;
                    if (tTop < tExit) {
                        h.t = tTop; h.kind = kind; h.b = b; h.H = H; h.n = float3(0.0, 1.0, 0.0);
                        return h;
                    }
                }
            }
        }
        if (tExit > tLim) break;
        if (rd.y > 0.0 && ro.y + rd.y * tExit > HM_TOP) break;
        tEnter = tExit;
        if (tMax.x < tMax.y) { tMax.x += tDelta.x; b.x += st.x; lastX = true; }
        else                 { tMax.y += tDelta.y; b.y += st.y; lastX = false; }
    }
    if (tFloor <= tFar) {
        h.t = tFloor; h.kind = 0; h.n = float3(0.0, 1.0, 0.0);
        float3 P = ro + rd * tFloor;
        h.b = int2(floor(P.xz));
    }
    return h;
}

// 1 if the moon can see p. The ray climbs past every top within a few blocks.
static inline float hmShadow(float3 p, float3 L, device const uint* verts, thread const HmEnv& E) {
    float2 d = select(L.xz, float2(1e-7), abs(L.xz) < 1e-7);
    float2 inv = 1.0 / d;
    int2 b = int2(floor(p.xz));
    int2 st = int2(sign(d));
    float2 tDelta = abs(inv);
    float2 tMax = (float2(b) + select(float2(0.0), float2(1.0), d > 0.0) - p.xz) * inv;
    float tEnter = 0.0;
    for (int i = 0; i < HM_SHADOW_STEPS; ++i) {
        float tExit = min(tMax.x, tMax.y);
        if (i > 0) {
            float H;
            if (hmColumn(b, verts, E, H) != 0 && p.y + L.y * tEnter < H) return 0.0;
        }
        if (p.y + L.y * tExit > HM_TOP) return 1.0;
        tEnter = tExit;
        if (tMax.x < tMax.y) { tMax.x += tDelta.x; b.x += st.x; }
        else                 { tMax.y += tDelta.y; b.y += st.y; }
    }
    return 1.0;
}

// ---------------------------------------------------------------------------
// Textures: 16×16 texels a face, every texel a hash. `t` runs 0..15 with
// row 0 at the top of a side face.

struct HmTex { float3 alb; float3 emit; };

struct HmCtx {
    uint   style;
    bool   feature;    // a hedge hung with glowing berries
    float3 leaf, grass, lamp, goal, gem;
    float  pulse;
};

static inline HmTex hmTexel(int mat, int3 b, int2 t, thread const HmCtx& c) {
    HmTex o;
    o.emit = float3(0.0);
    float h = hmR(b, t, uint(mat) * 7u + 1u);
    float g = hmR(b, t >> 1, uint(mat) * 7u + 2u);
    switch (mat) {
    case HM_GRASS: {
        o.alb = c.grass * (0.68 + 0.26 * g + 0.22 * h);
        if (h < 0.06) o.alb *= 0.7;
        // A small flower on about one block in ten.
        float f = hmR(b, int2(0), 31u);
        if (f < 0.1) {
            int2 fp = int2(3 + int(hmR(b, int2(1), 32u) * 9.0), 3 + int(hmR(b, int2(2), 33u) * 9.0));
            int2 q = t - fp;
            if (q.x >= 0 && q.x < 2 && q.y >= 0 && q.y < 2) {
                const float3 petals[4] = { float3(0.80, 0.12, 0.10), float3(0.95, 0.80, 0.15),
                                           float3(0.35, 0.45, 0.95), float3(0.92, 0.90, 0.86) };
                o.alb = hmLin(petals[int(f * 40.0) & 3]) * (0.85 + 0.2 * h);
            }
        }
        break;
    }
    case HM_PATH: {
        o.alb = hmLin(float3(0.52, 0.40, 0.25)) * (0.74 + 0.22 * g + 0.2 * h);
        if (h < 0.09) o.alb *= 0.62;
        if (h > 0.95) o.alb *= 1.25;
        break;
    }
    case HM_LEAF: {
        // Leaves in staggered 2x2 clumps, lit on their upper-left texel,
        // with dark gaps where a clump is missing.
        int2 tc = t + int2(0, (t.x >> 1) & 1);
        float clump = hmR(b, tc >> 1, 43u);
        bool lit = (tc.x & 1) == 0 && (tc.y & 1) == 0;
        o.alb = c.leaf * (0.55 + 0.38 * clump + 0.1 * h) * (lit ? 1.15 : 1.0);
        if (clump < 0.14 && h < 0.7) o.alb = c.leaf * (0.2 + 0.12 * h);     // a gap
        else if (h < 0.07) o.alb = c.leaf * 0.3;
        if (c.style == 2u && hmR(b, t >> 1, 41u) < 0.05 && h > 0.15)
            o.alb = hmLin(float3(0.86, 0.48, 0.72)) * (0.8 + 0.3 * h);   // blossom
        if (c.feature && hmR(b, t, 42u) < 0.035) {
            o.alb = hmLin(float3(0.9, 0.5, 0.15));
            o.emit = c.lamp * (1.2 + 0.8 * g);                          // glow berries
        }
        break;
    }
    case HM_STONE: {
        // Two courses of stone brick a block, the lower offset by half.
        int row = t.y >> 3, ry = t.y & 7;
        int rx = (t.x + (row == 0 ? 0 : 8)) & 15;
        float3 stone = hmLin(float3(0.50, 0.49, 0.47)) * (0.82 + 0.22 * h + 0.1 * g);
        if (ry == 0 || rx == 0) stone *= 1.12;
        if (ry == 6 || rx == 14) stone *= 0.84;
        o.alb = (ry == 7 || rx == 15) ? stone * 0.5 : stone;
        if (c.style == 1u) {
            float m = hmR(b, t >> 1, 51u);
            if (m < 0.12 + 0.32 * float(t.y) / 15.0 * (b.y == 0 ? 1.0 : 0.4))
                o.alb = hmLin(float3(0.30, 0.42, 0.18)) * (0.75 + 0.4 * h);
        }
        break;
    }
    case HM_LOG: {
        float col = hmR(b, int2(t.x, 0), 61u);
        if (c.style == 2u) {
            // Birch: pale bark with short dark marks.
            o.alb = hmLin(float3(0.74, 0.73, 0.67)) * (0.86 + 0.1 * col + 0.08 * h);
            if (hmR(b, int2(t.x >> 2, t.y), 62u) < 0.13) o.alb = hmLin(float3(0.20, 0.19, 0.17));
        } else {
            // Dark oak: deep brown with grooves.
            o.alb = hmLin(float3(0.33, 0.23, 0.14)) * (0.7 + 0.4 * col) * (0.9 + 0.2 * h);
            if (col < 0.22) o.alb *= 0.55;
        }
        break;
    }
    case HM_LANTERN: {
        // A lantern: four glowing panes in a dark iron frame.
        bool rim = t.x == 0 || t.y == 0 || t.x == 15 || t.y == 15;
        bool bar = t.x == 7 || t.x == 8 || t.y == 7 || t.y == 8;
        o.alb = hmLin(float3(0.16, 0.14, 0.13)) * (0.8 + 0.4 * h);
        if (!rim) {
            float2 q = abs(float2(t) - 7.5) / 7.5;
            float hot = 1.0 - 0.35 * max(q.x, q.y);
            o.emit = bar ? c.lamp * 0.12 : c.lamp * (0.75 + 0.3 * g + 0.15 * h) * hot;
        }
        break;
    }
    case HM_IRON: {
        bool edge = t.x == 0 || t.y == 0 || t.x == 15 || t.y == 15;
        bool hi = t.x == 1 || t.y == 1, lo = t.x == 14 || t.y == 14;
        o.alb = hmLin(float3(0.66, 0.67, 0.70)) * (0.88 + 0.08 * g + 0.06 * h);
        if (edge) o.alb *= 0.5; else if (hi) o.alb *= 1.2; else if (lo) o.alb *= 0.78;
        if ((t.x == 3 || t.x == 12) && (t.y == 3 || t.y == 12)) o.alb *= 0.6;   // rivets
        break;
    }
    case HM_BEACON: {
        bool rim = t.x == 0 || t.y == 0 || t.x == 15 || t.y == 15;
        bool core = t.x >= 4 && t.x <= 11 && t.y >= 4 && t.y <= 11;
        if (rim) { o.alb = hmLin(float3(0.75, 0.92, 0.95)); o.emit = c.goal * 0.1; }
        else if (core) {
            o.alb = float3(0.2);
            float ring = (t.x == 4 || t.x == 11 || t.y == 4 || t.y == 11) ? 0.6 : 1.0;
            o.emit = c.goal * (1.6 + 0.4 * h) * ring * c.pulse;
        } else { o.alb = hmLin(float3(0.10, 0.25, 0.28)) * (0.8 + 0.4 * h); o.emit = c.goal * 0.12; }
        break;
    }
    default: {   // HM_GEM: the glowing block that stands in for a polyhedron
        bool facet = ((t.x + t.y) & 3) == 0 || ((t.x - t.y + 32) % 5) == 0;
        o.alb = c.gem * (0.4 + 0.3 * g);
        o.emit = c.gem * (0.35 + 0.5 * g + 0.25 * h) * (facet ? 1.6 : 1.0);
        if (t.x == 0 || t.y == 0 || t.x == 15 || t.y == 15) o.emit *= 0.4;
        break;
    }
    }
    return o;
}

// Texels filtered to the pixel. `uv` is in texels across the face (0..16) and
// `fwT` the pixel footprint in texels along each face axis. Close up each
// texel is a hard-edged square whose edges are blended over one pixel; past
// about a texel a pixel the face averages towards a block tone taken from a
// spread of texels, so there is nothing left small enough to crawl.
static inline HmTex hmSample(int mat, int3 b, float2 uv, float2 fwT, thread const HmCtx& c) {
    HmTex o;
    o.alb = float3(0.0); o.emit = float3(0.0);
    float m = smoothstep(0.7, 2.2, max(fwT.x, fwT.y));
    if (m < 1.0) {
        // Bilinear between neighbouring texel centres, with the blend
        // squeezed into the pixel that straddles their shared edge.
        float2 q = uv - 0.5;
        int2 i0 = int2(floor(q));
        float2 f = saturate((fract(q) - 0.5) / max(fwT, float2(1e-3)) + 0.5);
        int2 a = clamp(i0, 0, 15), z = clamp(i0 + 1, 0, 15);
        HmTex t00 = hmTexel(mat, b, int2(a.x, a.y), c), t10 = hmTexel(mat, b, int2(z.x, a.y), c);
        HmTex t01 = hmTexel(mat, b, int2(a.x, z.y), c), t11 = hmTexel(mat, b, int2(z.x, z.y), c);
        o.alb  = mix(mix(t00.alb,  t10.alb,  f.x), mix(t01.alb,  t11.alb,  f.x), f.y);
        o.emit = mix(mix(t00.emit, t10.emit, f.x), mix(t01.emit, t11.emit, f.x), f.y);
        o.alb *= 1.0 - m; o.emit *= 1.0 - m;
    }
    if (m > 0.0) {
        const int2 spread[4] = { int2(3, 5), int2(11, 2), int2(6, 12), int2(13, 10) };
        HmTex s;
        s.alb = float3(0.0); s.emit = float3(0.0);
        for (int k = 0; k < 4; ++k) {
            HmTex tk = hmTexel(mat, b, spread[k], c);
            s.alb += tk.alb; s.emit += tk.emit;
        }
        o.alb += s.alb * (0.25 * m);
        o.emit += s.emit * (0.25 * m);
    }
    return o;
}

// ---------------------------------------------------------------------------
// Light.

// Lanterns on the nine pillars round p. Each stands on a junction post and
// lights the corners of the four cells that meet there.
static inline float3 hmLamps(float3 p, float3 n, device const uint* verts, thread const HmEnv& E) {
    float3 sum = float3(0.0);
    int2 v0 = int2(round((p.xz - 0.5) / 4.0));
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dx = -1; dx <= 1; ++dx) {
            int2 v = v0 + int2(dx, dz);
            if (hmRec(verts, v, E.cells) == 0u || !hmHasLamp(v, E.salt)) continue;
            float3 L = float3(4.0 * float(v.x) + 0.5, 3.5, 4.0 * float(v.y) + 0.5) - p;
            float d2 = dot(L, L);
            float k = saturate(1.0 - d2 / (HM_LAMP_R * HM_LAMP_R));
            if (k <= 0.0) continue;
            float nl = max(dot(n, L * rsqrt(d2)), 0.0);
            float flick = 0.93 + 0.07 * sin(E.now * 5.3 + float(v.x * 7 + v.y * 13));
            sum += E.lampCol * (k * k) * (0.25 + 0.75 * nl) * flick * 1.6 / (1.0 + 0.12 * d2);
        }
    }
    return sum;
}

static inline float3 hmObjCentre(float4 o, float now) {
    return float3(4.0 * o.x + 0.5, HM_EYE - 0.3 + 0.09 * sin(now * 1.6 + o.w), 4.0 * o.y + 0.5);
}

static inline float3 hmPoints(float3 p, float3 n, thread const HmEnv& E, constant LerpMazeFrame& F) {
    float3 sum = float3(0.0);
    for (uint i = 0; i < min(F.dim.z, 8u); ++i) {
        float4 o = F.objects[i];
        if (o.z <= 0.0) continue;
        float3 L = hmObjCentre(o, E.now) - p;
        float d2 = dot(L, L);
        float k = saturate(1.0 - d2 / 25.0);
        sum += E.gemCol * o.z * k * k * max(dot(n, L * rsqrt(d2)), 0.0) * 1.2;
    }
    // The beacon lights its own cell.
    float3 L = float3(E.goalXZ.x, 1.5, E.goalXZ.y) - p;
    float d2 = dot(L, L);
    float k = saturate(1.0 - d2 / 36.0);
    sum += E.goalCol * k * k * (0.2 + 0.8 * max(dot(n, L * rsqrt(max(d2, 1e-4))), 0.0)) * (0.6 + 0.8 * E.flash);
    return sum;
}

// ---------------------------------------------------------------------------
// Sky: gradient, square stars, a square moon, flat cube clouds.

static inline float hmBoxCover(float2 d, float s, float px) {
    float2 c = saturate((s - abs(d)) / px + 0.5);
    return c.x * c.y;
}

static inline float hmCloudCell(int2 c, uint salt) {
    float2 q = float2(c) * 0.38 + float2(float(salt & 255u), float((salt >> 8) & 255u)) * 0.37;
    float v = valueNoise(q) * 0.7 + valueNoise(q * 2.3 + 5.1) * 0.3;
    return v > 0.6 ? 1.0 : 0.0;
}

static inline float3 hmSky(float3 ro, float3 rd, thread const HmEnv& E, uint seedSalt) {
    float el = rd.y;
    float3 col = mix(E.hor, E.zen, smoothstep(-0.02, 0.5, el));
    if (el <= 0.0) return col;

    // Stars, on the faces of a cube round the eye.
    float3 a = abs(rd);
    float2 sp; float face;
    if (a.y > max(a.x, a.z)) { sp = rd.xz / a.y; face = 0.0; }
    else if (a.x > a.z)      { sp = rd.zy / a.x; face = rd.x > 0.0 ? 1.0 : 2.0; }
    else                     { sp = rd.xy / a.z; face = rd.z > 0.0 ? 3.0 : 4.0; }
    const float SC = 0.045;
    float2 g = sp / SC;
    int2 gi = int2(floor(g));
    float sh = hmR(int3(gi.x, int(face), gi.y), int2(5), seedSalt);
    if (sh < 0.3) {
        float2 c = (float2(gi) + 0.25 + 0.5 * float2(hmR(int3(gi.x, int(face), gi.y), int2(6), seedSalt),
                                                     hmR(int3(gi.x, int(face), gi.y), int2(7), seedSalt))) * SC;
        float big = sh < 0.03 ? 1.6 : 1.0;
        float cov = hmBoxCover(sp - c, 0.0016 * big, E.pxA);
        float tw = 0.75 + 0.25 * sin(E.now * (0.7 + sh * 3.0) + sh * 60.0);
        col += float3(0.85, 0.9, 1.0) * cov * (0.25 + 1.6 * sh) * tw * smoothstep(0.03, 0.25, el);
    }

    // The moon: a square, with a few darker texels.
    float3 M = E.moonDir;
    float md = dot(rd, M);
    if (md > 0.0) {
        float3 mR = normalize(cross(float3(0.0, 1.0, 0.0), M));
        float3 mU = cross(M, mR);
        float2 p = float2(dot(rd, mR), dot(rd, mU)) / md;
        const float S = 0.062;
        float cov = hmBoxCover(p, S, E.pxA);
        if (cov > 0.0) {
            int2 tx = int2(floor((p / S * 0.5 + 0.5) * 8.0));
            float h = hmR(int3(tx.x, 0, tx.y), int2(9), 3u);
            float3 mc = float3(0.95, 0.95, 0.86) * (h < 0.22 ? 0.7 : (0.92 + 0.1 * h));
            col = mix(col, mc * 1.4, cov);
        }
        float r = max(abs(p.x), abs(p.y));
        col += E.moonCol * 0.25 * exp(-max(r - S, 0.0) * 14.0) * (1.0 - cov);
    }

    // Clouds: one flat deck of square cells, drifting.
    if (el > 0.02) {
        float t = (HM_CLOUD_Y - ro.y) / el;
        float2 q = ro.xz + rd.xz * t;
        float2 qd = q + float2(E.now * 0.45, E.now * 0.12);
        float2 cq = qd / HM_CLOUD_C;
        int2 ci = int2(floor(cq));
        float2 f = cq - floor(cq);
        float fw = t * E.pxA / el / HM_CLOUD_C;
        float occ = hmCloudCell(ci, seedSalt);
        int sx = f.x < 0.5 ? -1 : 1, sz = f.y < 0.5 ? -1 : 1;
        float ex = min(f.x, 1.0 - f.x), ez = min(f.y, 1.0 - f.y);
        occ = mix(occ, hmCloudCell(ci + int2(sx, 0), seedSalt), saturate(0.5 - ex / max(fw, 1e-4)));
        occ = mix(occ, hmCloudCell(ci + int2(0, sz), seedSalt), saturate(0.5 - ez / max(fw, 1e-4)));
        occ = mix(occ, 0.25, smoothstep(0.4, 1.2, fw));
        float fade = 1.0 - smoothstep(110.0, 320.0, t);
        float3 cc = float3(0.045, 0.05, 0.065) + E.moonCol * 0.08 * (0.3 + 0.7 * saturate(dot(rd, M)));
        // The beam lights the cloud it passes through.
        float db = length(q - E.goalXZ);
        cc += E.goalCol * 0.5 * exp(-db * db / 30.0) * (1.0 + E.flash);
        col = mix(col, cc, occ * 0.6 * fade);
    }
    return col;
}

// ---------------------------------------------------------------------------
// The glowing blocks: a cube of half-size s turning about y.

static inline bool hmCube(float3 ro, float3 rd, float3 c, float s, float ang, float tMax,
                          thread float& tHit, thread float3& nW, thread float2& fuv) {
    float ca = cos(ang), sa = sin(ang);
    float3 o = ro - c;
    float3 ol = float3(ca * o.x + sa * o.z, o.y, -sa * o.x + ca * o.z);
    float3 dl = float3(ca * rd.x + sa * rd.z, rd.y, -sa * rd.x + ca * rd.z);
    dl = select(dl, float3(1e-7), abs(dl) < 1e-7);
    float3 inv = 1.0 / dl;
    float3 t1 = (-s - ol) * inv, t2 = (s - ol) * inv;
    float3 tn = min(t1, t2), tf = max(t1, t2);
    float tN = max(max(tn.x, tn.y), tn.z), tF = min(min(tf.x, tf.y), tf.z);
    if (tN > tF || tN <= 0.0 || tN >= tMax) return false;
    float3 nl;
    float3 lp = (ol + dl * tN) / (2.0 * s) + 0.5;
    if (tN == tn.x)      { nl = float3(-sign(dl.x), 0.0, 0.0); fuv = lp.zy; }
    else if (tN == tn.y) { nl = float3(0.0, -sign(dl.y), 0.0); fuv = lp.xz; }
    else                 { nl = float3(0.0, 0.0, -sign(dl.z)); fuv = lp.xy; }
    nW = float3(ca * nl.x - sa * nl.z, nl.y, sa * nl.x + ca * nl.z);
    tHit = tN;
    return true;
}

// ---------------------------------------------------------------------------
// Fireflies: square motes, one in about a third of the cells, each wandering
// round the middle of its own cell and glowing on and off. The ray visits
// cells along its way to the hit, at most one test a cell.

static inline float3 hmFireflies(float3 ro, float3 rd, float tHit, thread const HmEnv& E) {
    float3 sum = float3(0.0);
    float tEnd = min(tHit, HM_FOG1);
    float2 o = ro.xz / 4.0, d = select(rd.xz, float2(1e-7), abs(rd.xz) < 1e-7);
    float2 inv = 1.0 / d;
    int2 c = int2(floor(o));
    int2 st = int2(sign(d));
    float2 tDelta = abs(inv) * 4.0;
    float2 tMax = (float2(c) + select(float2(0.0), float2(1.0), d > 0.0) - o) * inv * 4.0;
    for (int i = 0; i < 16; ++i) {
        float h = hmR(int3(c.x, 11, c.y), int2(3), E.salt);
        if (h < 0.34) {
            float ph = h * 97.0, ph2 = h * 53.0;
            float3 p = float3(4.0 * float(c.x) + 2.5 + 0.9 * sin(E.now * 0.21 + ph),
                              1.25 + 0.55 * sin(E.now * 0.17 + ph2),
                              4.0 * float(c.y) + 2.5 + 0.9 * sin(E.now * 0.26 + ph2 * 1.3));
            float tc = dot(p - ro, rd);
            if (tc > 0.2 && tc < tEnd) {
                float3 q = ro + rd * tc - p;
                float2 sq = float2(dot(q, E.camR), dot(q, E.camU));
                float px = tc * E.pxA;
                const float S = 0.035;
                float cov = hmBoxCover(sq, S, px);
                float on = smoothstep(0.1, 0.8, sin(E.now * 0.55 + ph * 1.7));
                float glow = exp(-dot(q, q) * 30.0) * 0.25;
                // A mote smaller than the pixel keeps its light, spread.
                float shrink = min(1.0, (2.0 * S) * (2.0 * S) / (px * px + 1e-6));
                sum += float3(0.75, 1.0, 0.35) * on * (cov * 1.6 * max(1.0, shrink) + glow)
                     * (1.0 - smoothstep(HM_FOG0, HM_FOG1, tc));
            }
        }
        float tExit = min(tMax.x, tMax.y);
        if (tExit > tEnd) break;
        if (tMax.x < tMax.y) { tMax.x += tDelta.x; c.x += st.x; }
        else                 { tMax.y += tDelta.y; c.y += st.y; }
    }
    return sum;
}

// ---------------------------------------------------------------------------

struct HmCache {
    bool valid, skyValid;
    float3 sky;
    int kind;
    int2 b, tid;
    float3 n, irr;
};

static inline float hmFaceShade(float3 n) {
    return n.y > 0.5 ? 1.0 : (n.y < -0.5 ? 0.5 : (abs(n.x) > 0.5 ? 0.62 : 0.82));
}

static inline float3 hmScene(float3 ro, float3 rd, thread const HmEnv& E, thread const HmCtx& C0,
                             uint seedSalt, constant LerpMazeFrame& F, device const uint* verts,
                             thread HmCache& cache, thread float& tOut, thread bool& edge) {
    HmHit h = hmTrace(ro, rd, HM_FOG1, verts, E);

    // The glowing blocks, nearer than the hit.
    float tO = h.t;
    int obj = -1;
    float3 oN = float3(0.0);
    float2 oUV = float2(0.0);
    for (uint i = 0; i < min(F.dim.z, 8u); ++i) {
        float4 o = F.objects[i];
        if (o.z <= 0.0) continue;
        float th; float3 nn; float2 fu;
        if (hmCube(ro, rd, hmObjCentre(o, E.now), 0.27 * o.z, E.now * 0.9 + o.w, tO, th, nn, fu)) {
            tO = th; oN = nn; oUV = fu; obj = int(i);
        }
    }

    float3 col;
    float tHit = h.t;
    // Whether a geometric edge (not a texel edge: those are filtered) runs
    // through this pixel, so it needs more samples.
    edge = h.clear < 1.5 * E.pxA;
    if (obj >= 0) {
        edge = true;
        tHit = tO;
        float fwT = tO * E.pxA / max(abs(dot(rd, oN)), 0.1) / (0.54 * F.objects[obj].z) * 16.0;
        HmTex tx = hmSample(HM_GEM, int3(obj, 0, 0), oUV * 16.0, float2(fwT), C0);
        float diff = max(dot(oN, E.moonDir), 0.0);
        col = tx.alb * (E.amb * hmFaceShade(oN) + E.moonCol * diff) + tx.emit;
        col = mix(col, E.hor, smoothstep(HM_FOG0, HM_FOG1, tO));
    } else if (h.kind < 0) {
        // Sky is smooth across a pixel; the second sample reuses the first's.
        if (cache.skyValid) col = cache.sky;
        else {
            col = rd.y > 0.0 ? hmSky(ro, rd, E, seedSalt) : E.hor;
            cache.sky = col; cache.skyValid = true;
        }
    } else {
        float3 P = ro + rd * h.t;
        float3 n = h.n;
        // The pixel's footprint along each face axis, in texels: a cone of
        // radius r cut by the face stretches along axis A by
        // sqrt(1 + (rd.A / rd.n)^2).
        float dn = max(abs(dot(rd, n)), 0.02);
        float r16 = h.t * E.pxA * 16.0;

        // Face coordinates and the block whose face this is.
        float2 uvF;
        int3 blk;
        bool top = abs(n.y) > 0.5;
        float2 da;
        if (top) { uvF = P.xz; da = rd.xz; blk = int3(h.b.x, h.kind == 0 ? -1 : 1, h.b.y); }
        else if (abs(n.x) > 0.5) { uvF = float2(P.z, P.y); da = rd.zy; blk = int3(h.b.x, int(floor(P.y)), h.b.y); }
        else { uvF = float2(P.x, P.y); da = rd.xy; blk = int3(h.b.x, int(floor(P.y)), h.b.y); }
        float2 fw2 = r16 * sqrt(1.0 + (da / dn) * (da / dn));
        float fwT = min(fw2.x, fw2.y);
        float2 tuv = top ? fract(uvF) * 16.0 : float2(fract(uvF.x), 1.0 - fract(uvF.y)) * 16.0;

        // Light is taken at the texel's centre while texels are bigger than
        // a pixel, so shadows and pools step with the texture.
        float3 Ps = P;
        if (fwT < 1.0) {
            float2 sv = (floor(uvF * 16.0) + 0.5) / 16.0;
            if (top) Ps = float3(sv.x, P.y, sv.y);
            else if (abs(n.x) > 0.5) Ps = float3(P.x, sv.y, sv.x);
            else Ps = float3(sv.x, sv.y, P.z);
        }

        HmCtx C = C0;
        int mat;
        if (h.kind == 0) {
            mat = hmIsPath(h.b, verts, E) ? HM_PATH : HM_GRASS;
        } else if (h.kind == 1) {
            mat = HM_LEAF;
            int2 ci = h.b >> 2, r = h.b & 3;
            uint rec = hmRec(verts, ci, E.cells);
            C.feature = (rec & (r.y == 0 ? 16u : 32u)) != 0u;
        } else if (h.kind == 4) {
            mat = P.y >= 1.0 ? HM_BEACON : HM_IRON;
        } else if (h.kind == 3 && P.y >= 3.0) {
            mat = HM_LANTERN;
        } else {
            mat = (E.style >= 2u) ? HM_LOG : HM_STONE;
        }

        HmTex tx = hmSample(mat, blk, tuv, fw2, C);

        float2 fwB = fw2 * (1.5 / 16.0);
        if (h.kind == 0) {
            float2 f = fract(P.xz);
            if (f.x < fwB.x)       edge = edge || hmSolid(h.b - int2(1, 0), verts, E) > 0.0;
            if (f.x > 1.0 - fwB.x) edge = edge || hmSolid(h.b + int2(1, 0), verts, E) > 0.0;
            if (f.y < fwB.y)       edge = edge || hmSolid(h.b - int2(0, 1), verts, E) > 0.0;
            if (f.y > 1.0 - fwB.y) edge = edge || hmSolid(h.b + int2(0, 1), verts, E) > 0.0;
        } else if (!top) {
            edge = edge || (h.H - P.y) < fwB.y || P.y < fwB.y;
            int2 a = h.b + int2(int(n.x), int(n.z));
            int2 td = abs(n.x) > 0.5 ? int2(0, 1) : int2(1, 0);
            float fu = fract(uvF.x);
            if (fu < fwB.x)
                edge = edge || P.y > 2.9 || hmSolid(h.b - td, verts, E) == 0.0 || hmSolid(a - td, verts, E) > 0.0;
            if (fu > 1.0 - fwB.x)
                edge = edge || P.y > 2.9 || hmSolid(h.b + td, verts, E) == 0.0 || hmSolid(a + td, verts, E) > 0.0;
        }

        // Light is the same for every sample that lands in the same texel of
        // the same face, so the pixel's second sample usually reuses it.
        int2 tid = int2(floor(uvF * 16.0));
        float3 irr;
        if (cache.valid && cache.kind == h.kind && all(cache.b == h.b) && all(cache.n == n)
            && all(cache.tid == tid)) {
            irr = cache.irr;
        } else {
            float ao;
            if (h.kind == 0) {
                // Corners where the floor meets the hedges.
                float2 f = fract(Ps.xz);
                float2 cl = 1.0 - f, cr = f;
                cl *= cl; cr *= cr;
                float occ = 0.0;
                occ += hmSolid(h.b + int2(-1, 0), verts, E) * cl.x;
                occ += hmSolid(h.b + int2( 1, 0), verts, E) * cr.x;
                occ += hmSolid(h.b + int2(0, -1), verts, E) * cl.y;
                occ += hmSolid(h.b + int2(0,  1), verts, E) * cr.y;
                occ += hmSolid(h.b + int2(-1, -1), verts, E) * cl.x * cl.y;
                occ += hmSolid(h.b + int2( 1, -1), verts, E) * cr.x * cl.y;
                occ += hmSolid(h.b + int2(-1,  1), verts, E) * cl.x * cr.y;
                occ += hmSolid(h.b + int2( 1,  1), verts, E) * cr.x * cr.y;
                ao = 1.0 - 0.55 * saturate(occ);
            } else if (top) {
                ao = 1.0;
            } else {
                int2 a = h.b + int2(int(n.x), int(n.z));
                int2 td = abs(n.x) > 0.5 ? int2(0, 1) : int2(1, 0);
                float al = abs(n.x) > 0.5 ? fract(Ps.z) : fract(Ps.x);
                float occ = hmSolid(a + td, verts, E) * al * al
                          + hmSolid(a - td, verts, E) * (1.0 - al) * (1.0 - al);
                float lowY = saturate(1.0 - Ps.y);
                occ += 0.8 * lowY * lowY;
                ao = 1.0 - 0.5 * saturate(occ);
            }
            irr = E.amb * hmFaceShade(n) * ao;
            float nm = dot(n, E.moonDir);
            if (nm > 0.0) irr += E.moonCol * nm * hmShadow(Ps + n * 0.01, E.moonDir, verts, E) * (0.6 + 0.4 * ao);
            if (mat != HM_LANTERN) irr += hmLamps(Ps, n, verts, E) * (0.5 + 0.5 * ao);
            irr += hmPoints(Ps, n, E, F) * (0.6 + 0.4 * ao);
            cache.valid = true; cache.kind = h.kind; cache.b = h.b; cache.n = n; cache.tid = tid;
            cache.irr = irr;
        }

        col = tx.alb * irr + tx.emit;
        col = mix(col, E.hor, smoothstep(HM_FOG0, HM_FOG1, h.t));
    }
    tOut = tHit;
    return col;
}

// Light in the air — lantern glow, the beam, fireflies, the glowing blocks'
// halos. All soft, so once a pixel along its centre ray is enough.
static inline float3 hmGlows(float3 ro, float3 rd, float tHit, thread const HmEnv& E,
                             constant LerpMazeFrame& F, device const uint* verts) {
    float3 col = float3(0.0);

    // A glow in the air round the lanterns. Lanterns sit above the eye, so
    // only a rising ray can pass one: look round where it crosses their
    // height.
    if (rd.y > 0.03) {
        float tl = (3.5 - ro.y) / rd.y;
        float2 X = ro.xz + rd.xz * tl;
        int2 v0 = int2(floor((X - 0.5) / 4.0));
        for (int k = 0; k < 4; ++k) {
            int2 v = v0 + int2(k & 1, k >> 1);
            if (hmRec(verts, v, E.cells) == 0u || !hmHasLamp(v, E.salt)) continue;
            float3 c = float3(4.0 * float(v.x) + 0.5, 3.5, 4.0 * float(v.y) + 0.5);
            float tc = dot(c - ro, rd);
            if (tc <= 0.0 || tc > tHit + 0.6) continue;
            float3 q = ro + rd * tc - c;
            float d2 = dot(q, q);
            col += E.lampCol * (0.2 * exp(-d2 * 1.8) + 0.025 * exp(-d2 * 0.6))
                 * (1.0 - smoothstep(HM_FOG0, HM_FOG1, tc));
        }
    }

    // The beacon's beam, standing over everything from the top of the beacon.
    {
        float2 o = ro.xz - E.goalXZ;
        float2 d = rd.xz;
        float dd = max(dot(d, d), 1e-6);
        float tc = -dot(o, d) / dd;
        if (tc > 0.0 && tc < tHit && ro.y + rd.y * tc > 2.0) {
            float dist = length(o + d * tc);
            float w = max(0.2, tc * E.pxA * 0.8);
            float core = exp(-(dist * dist) / (w * w)) * (0.2 / w);
            float halo = 0.06 / (1.0 + dist * dist * 0.8);
            float fogK = mix(1.0, 0.45, smoothstep(HM_FOG0, HM_FOG1 * 2.0, tc));
            col += E.goalCol * (core * 1.4 + halo) * fogK * (1.0 + 1.5 * E.flash);
        }
    }

    col += hmFireflies(ro, rd, tHit, E);

    // A soft glow round each glowing block.
    for (uint i = 0; i < min(F.dim.z, 8u); ++i) {
        float4 o = F.objects[i];
        if (o.z <= 0.0) continue;
        float3 c = hmObjCentre(o, E.now);
        float tc = dot(c - ro, rd);
        if (tc > 0.0 && tc < tHit + 0.5) {
            float3 q = ro + rd * tc - c;
            col += E.gemCol * o.z * 0.12 * exp(-dot(q, q) * 3.0);
        }
    }
    return col;
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpMazeFrame& F [[buffer(1)]],
                        device const uint* verts [[buffer(2)]]) {
    float minRes = min(u.resolution.x, u.resolution.y);

    // Camera: level, at eye height, no bob.
    float yaw = F.camera.z, roll = F.camera.w;
    float3 ro = float3(4.0 * F.camera.x + 0.5, HM_EYE, 4.0 * F.camera.y + 0.5);
    float3 fwd = float3(cos(yaw), 0.0, sin(yaw));
    // The eye rides half a block behind the walker: it never meets a wall
    // (the walk keeps 1.5 blocks clear of every one), and a dead end or a
    // corner shows a little of what is round it instead of a face of leaves.
    ro -= fwd * 0.5;
    float3 right0 = float3(-fwd.z, 0.0, fwd.x);
    float3 up0 = float3(0.0, 1.0, 0.0);
    float cr = cos(roll), sr = sin(roll);
    float3 right = right0 * cr + up0 * sr;
    float3 up = up0 * cr - right0 * sr;
    float lens = lerpLook(u.yaw, u.pitch, u.magnify, up0, right, fwd);
    if (u.yaw != 0.0 || u.pitch != 0.0) up = cross(right, fwd);

    HmEnv E;
    E.cells = F.dim.xy;
    E.goalXZ = 4.0 * F.goal.xy + 0.5;
    E.goalB = int2(floor(E.goalXZ));
    E.salt = uint(F.goal.z * 16777216.0);
    E.style = u.style > 0 ? uint(u.style - 1) & 3u : (F.dim.w & 3u);
    E.now = u.time;
    E.pxA = 2.0 / (minRes * HM_FOCAL * lens);
    E.flash = F.goal.w;
    E.camR = right;
    E.camU = up;

    uint seedSalt = uint(u.seed * 16777216.0);
    float maz = u.seed * TWO_PI;
    const float mel = 0.5;
    E.moonDir = float3(cos(mel) * cos(maz), sin(mel), cos(mel) * sin(maz));
    float L = u.light;
    E.moonCol = float3(0.36, 0.44, 0.68) * 1.3 * L;
    E.amb     = float3(0.045, 0.06, 0.11) * L;
    E.lampCol = float3(1.0, 0.4, 0.09) * L;
    E.goalCol = hmLin(u.colorGoal.rgb) * L;
    E.gemCol  = hmLin(float3(0.72, 0.42, 1.0)) * L;
    E.zen = hmLin(float3(0.035, 0.05, 0.13));
    E.hor = hmLin(float3(0.12, 0.17, 0.30));

    const float3 leaves[4] = { float3(0.26, 0.52, 0.17), float3(0.17, 0.36, 0.22),
                               float3(0.30, 0.54, 0.19), float3(0.74, 0.38, 0.11) };
    const float3 grasses[4] = { float3(0.36, 0.58, 0.22), float3(0.30, 0.50, 0.32),
                                float3(0.40, 0.62, 0.25), float3(0.56, 0.55, 0.24) };
    HmCtx C;
    C.style = E.style;
    C.feature = false;
    C.leaf = hmLin(leaves[E.style]);
    C.grass = hmLin(grasses[E.style]);
    C.lamp = E.lampCol;
    C.goal = E.goalCol;
    C.gem = E.gemCol;
    C.pulse = 0.85 + 0.15 * sin(u.time * 2.0) + 1.0 * F.goal.w;

    // One sample at the pixel's centre; where a geometric edge crosses the
    // pixel, two more. Their light comes from the cache when they land in
    // the same texel.
    const float2 grid[2] = { float2(0.33, 0.15), float2(-0.15, -0.33) };
    float3 col = float3(0.0);
    HmCache cache;
    cache.valid = false;
    cache.skyValid = false;
    float2 uv0 = lerpUV(pos, u.resolution);
    float3 rd0 = normalize(uv0.x * right + uv0.y * up + lens * HM_FOCAL * fwd);
    float tFirst;
    bool edge;
    col = hmScene(ro, rd0, E, C, seedSalt, F, verts, cache, tFirst, edge);
    if (edge) {
        for (int s = 0; s < 2; ++s) {
            float4 p = pos;
            p.xy += grid[s];
            float2 uv = lerpUV(p, u.resolution);
            float3 rd = normalize(uv.x * right + uv.y * up + lens * HM_FOCAL * fwd);
            float tS; bool eS;
            col += hmScene(ro, rd, E, C, seedSalt, F, verts, cache, tS, eS);
        }
        col /= 3.0;
    }
    col += hmGlows(ro, rd0, tFirst, E, F, verts);

    col = col / (1.0 + col * 0.3);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col *= F.motion.x;
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
