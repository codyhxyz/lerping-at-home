// Hedge Maze — the Maze (an homage to Microsoft's 3D Maze screensaver, ssmaze,
// Windows 95) walked through a hedge garden at night in the block game,
// drawn with the game's own textures from the copy installed on this Mac
// (see "Minecraft looks" in PORTING.md). The shader code is original.
//
// lerp-category: Living Worlds
// lerp-requires: minecraft
// lerp-data: maze
//
// The same walk as `maze` — a perfect maze solved hand-on-the-wall, carved and
// timed by MazeData.swift — through a different place. Corridors three blocks
// wide run between leaf-block hedges three high on grass, open to the night
// sky: the moon in one of its phases, stars, the flat cloud layer drifting.
// A dirt path runs down the middle of every corridor, so the maze is drawn on
// the ground. Pillars stand at the junctions and about a third carry a
// lantern, whose light falls off a level a block the way the game's does.
// Short grass, flowers and firefly bushes grow in the corners, and fireflies
// drift round the bushes.
//
// The original's spinning polyhedra are dropped diamonds, turning and bobbing
// on the path; walk over one and the world rolls over until the next. The
// goal is a beacon on its iron base, its beam over the hedges from the first
// step, so the walk always has somewhere to be going.
//
// Each maze is a different garden — oak leaves and stone bricks, spruce and
// mossy stone bricks, birch leaves and birch logs, cherry leaves and cherry
// logs — never the same one twice running; a few hedge sections beside the
// route are flowering azalea.
//
// Lit as the game lights: the night sky light and each block's light level
// through the game's lightmap curve, fixed face shading, smooth corner
// shading. Leaves, glass and plants are cut out by their alpha and the ray
// carries on through the gaps. A pixel takes one ray; only where a real edge
// of geometry crosses it does it take two more.
//
// lerp-param: size        int 4 40     = 10      "Maze size"
// lerp-param: speed       float 0.25 4 = 0.8     "Walk speed (cells/s)"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -60 60   = 0 "Tilt"
// lerp-param: magnify  float -1 1.5 = 0 "Zoom"
// lerp-param: flips       bool         = true    "Flip on pickup"
// lerp-param: style       int 0 4      = 0       "Garden (0 = new each maze)"
// lerp-param: colorGoal   color        = #ffffff "Beam"
//
// lerp-preset: Labyrinth size=24, speed=1.6
// lerp-preset: "Cherry Grove" style=4
// lerp-preset: "Spruce and Moss" style=2


// --- Geometry, in blocks. A maze cell is 4 blocks: a 1-block wall line and a
// 3-block corridor. Cell coordinate c maps to block coordinate 4c + 0.5, so a
// grid line runs down the middle of its column of wall blocks.
constant float HM_EYE    = 1.62;    // eye height
constant float HM_FOCAL  = 1.2;     // ~80° vertical field of view
constant float HM_TOP    = 4.6;     // nothing solid above this (lantern cap 4 + 9/16)
constant float HM_FOG0   = 16.0;    // fog starts
constant float HM_FOG1   = 42.0;    // and is total; nothing is traced past it
constant float HM_CLOUD_Y = 128.0;  // the cloud layer, above this ground

constant int HM_STEPS  = 64;        // block DDA, covers HM_FOG1 on a diagonal
constant int HM_LAYERS = 4;         // cut-out surfaces a ray may pass through

// Column kinds (what stands on a block column) and hit kinds.
#define HK_NONE   -1
#define HK_FLOOR   0
#define HK_HEDGE   1
#define HK_PILLAR  2
#define HK_LPOST   3    // a pillar with a lantern standing on it
#define HK_BASE    4    // the beacon's iron base
#define HK_BEACON  5    // iron block with the beacon on it
#define HK_PLANT   6
#define HK_LAMP    7    // the lantern itself
#define HK_BMODEL  8    // the beacon itself, on its iron block

// Plants.
#define HP_NONE    0
#define HP_GRASS   1
#define HP_POPPY   2
#define HP_DANDELION 3
#define HP_CORNFLOWER 4
#define HP_DAISY   5
#define HP_BUSH    6    // firefly bush

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

// ---------------------------------------------------------------------------
// The world.

struct HmEnv {
    uint2  cells;
    int2   goalCell;   // the goal's maze cell
    int2   goalB;      // the beacon's block column
    float2 goalXZ;     // and its axis
    uint   salt;       // per maze
    uint   style;      // which garden, 0..3
    float  now;
    float  pxA;        // radians per pixel
    float3 zen, hor, fog, cloud;
    float3 grassTint, leafTint;
    float3 beamCol;
    float3 camR, camU;
    int    leaf, pillar, lampFrame, bushFrame;
};

static inline uint hmRec(device const uint* verts, int2 v, uint2 cells) {
    if (v.x < 0 || v.y < 0 || v.x > int(cells.x) || v.y > int(cells.y)) return 0u;
    return verts[v.y * int(cells.x + 1) + v.x];
}

static inline bool hmHasLamp(int2 v, uint salt) {
    return (hmH(uint(v.x) * 0x9e3779b9u ^ uint(v.y) * 0x85ebca6bu ^ salt) & 1023u) < 350u;
}

// What stands on block column b, and its height.
static inline int hmColumn(int2 b, device const uint* verts, thread const HmEnv& E,
                           thread float& H) {
    int2 ci = b >> 2, r = b & 3;
    H = 0.0;
    if (r.x != 0 && r.y != 0) {
        if (ci.x == E.goalCell.x && ci.y == E.goalCell.y) {
            if (b.x == E.goalB.x && b.y == E.goalB.y) { H = 1.0; return HK_BEACON; }
            H = 1.0;
            return HK_BASE;
        }
        return 0;
    }
    uint rec = hmRec(verts, ci, E.cells);
    if (r.x == 0 && r.y == 0) {
        if (rec == 0u) return 0;
        H = 4.0;
        return hmHasLamp(ci, E.salt) ? HK_LPOST : HK_PILLAR;
    }
    uint bit = r.x == 0 ? 4u : 1u;
    if ((rec & bit) == 0u) return 0;
    // A hedge block here and there has grown a block taller.
    H = (hmH(uint(b.x) * 0x27d4eb2du ^ uint(b.y) * 0x165667b1u ^ E.salt) & 1023u) < 92u ? 4.0 : 3.0;
    return HK_HEDGE;
}

// Whether anything stands on column b, without working out what.
static inline float hmSolid(int2 b, device const uint* verts, thread const HmEnv& E) {
    int2 r = b & 3;
    if (r.x != 0 && r.y != 0) {
        int2 ci = b >> 2;
        return (ci.x == E.goalCell.x && ci.y == E.goalCell.y) ? 1.0 : 0.0;
    }
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

// The firefly bush of cell ci, if it has one: which corner block.
static inline bool hmBush(int2 ci, thread const HmEnv& E, thread int2& bush) {
    uint hc = hmH(uint(ci.x) * 0x8da6b343u ^ uint(ci.y) * 0xd8163841u ^ E.salt);
    if ((hc & 255u) >= 56u) return false;
    uint k = (hc >> 8) & 3u;
    bush = ci * 4 + int2((k & 1u) ? 3 : 1, (k & 2u) ? 3 : 1);
    return true;
}

// What grows on block b: only the four corner blocks of a cell, which the
// path never crosses.
static inline int hmPlant(int2 b, thread const HmEnv& E) {
    int2 ci = b >> 2, r = b & 3;
    if ((r.x & 1) == 0 || (r.y & 1) == 0) return HP_NONE;
    if (ci.x < 0 || ci.y < 0 || ci.x >= int(E.cells.x) || ci.y >= int(E.cells.y)) return HP_NONE;
    if (ci.x == E.goalCell.x && ci.y == E.goalCell.y) return HP_NONE;
    int2 bush;
    if (hmBush(ci, E, bush) && bush.x == b.x && bush.y == b.y) return HP_BUSH;
    float f = float(hmH(uint(b.x) * 0x27d4eb2du ^ uint(b.y) * 0x165667b1u ^ (E.salt * 0x9e3779b9u)) >> 8)
            * (1.0 / 16777216.0);
    if (f < 0.40) return HP_GRASS;
    if (f < 0.45) return HP_POPPY;
    if (f < 0.50) return HP_DANDELION;
    if (f < 0.53) return HP_CORNFLOWER;
    if (f < 0.56) return HP_DAISY;
    return HP_NONE;
}

struct HmHit {
    float  t;
    float3 n;
    int    kind;
    int2   b;
    float  H;      // the hit column's height
    float  clear;  // closest the ray came to passing a column top, in radians
    int    part;   // plant type
    McModelHit m;  // a small model's hit: plant, lantern, beacon
};

// Steps the ray column by column from tMin. Everything solid stands on the
// floor and the eye is below every top it can be under, so a ray meets a
// column's side where it enters it or passes over it. A ray that resumes
// inside a column (behind a leaf it saw through) ignores that column's near
// side and carries on.
static inline HmHit hmTrace(float3 ro, float3 rd, float tMin, float tFar,
                            device const uint* verts, thread const HmEnv& E,
                            texture2d_array<float> mcTiles) {
    HmHit h;
    h.t = 1e9; h.kind = HK_NONE; h.n = float3(0.0); h.b = int2(0); h.H = 0.0; h.clear = 1e9;
    h.part = 0;
    float tFloor = rd.y < -1e-5 ? -ro.y / rd.y : 1e9;
    float tLim = min(tFloor, tFar);
    float2 d = select(rd.xz, float2(1e-7), abs(rd.xz) < 1e-7);
    float2 inv = 1.0 / d;
    float3 p0 = ro + rd * tMin;
    int2 b = int2(floor(p0.xz));
    int2 st = int2(sign(d));
    float2 tDelta = abs(inv);
    float2 tMax = (float2(b) + select(float2(0.0), float2(1.0), d > 0.0) - ro.xz) * inv;
    float tEnter = tMin;
    bool lastX = true;
    for (int i = 0; i < HM_STEPS; ++i) {
        float tExit = min(tMax.x, tMax.y);
        float H;
        int kind = hmColumn(b, verts, E, H);
        float yE = ro.y + rd.y * tEnter;
        if (kind != 0) {
            if (yE < H) {
                if (tEnter > tMin) {
                    h.t = tEnter; h.kind = kind; h.b = b; h.H = H;
                    h.n = lastX ? float3(-float(st.x), 0.0, 0.0) : float3(0.0, 0.0, -float(st.y));
                    return h;
                }
            } else if (tEnter > tMin) {
                h.clear = min(h.clear, (yE - H) / max(tEnter, 1e-3));
            }
            if (rd.y < 0.0) {
                float tTop = (H - ro.y) / rd.y;
                if (tTop > max(tEnter, tMin) && tTop < tExit) {
                    h.t = tTop; h.kind = kind; h.b = b; h.H = H; h.n = float3(0.0, 1.0, 0.0);
                    return h;
                }
            }
            if (kind == HK_LPOST && mcLantern(mcTiles, E.lampFrame, float3(float(b.x), 4.0, float(b.y)), false,
                                              ro, rd, max(tEnter - 1e-4, tMin), tExit, E.pxA, h.m)) {
                h.t = h.m.t; h.kind = HK_LAMP; h.n = h.m.n; h.b = b;
                return h;
            }
            if (kind == HK_BEACON && mcBeacon(mcTiles, float3(float(b.x), 1.0, float(b.y)),
                                              ro, rd, max(tEnter - 1e-4, tMin), tExit, E.pxA, h.m)) {
                h.t = h.m.t; h.kind = HK_BMODEL; h.n = h.m.n; h.b = b;
                return h;
            }
        } else if (min(yE, ro.y + rd.y * tExit) < 1.0) {
            // Plants, in the corner blocks of a cell.
            int pl = hmPlant(b, E);
            if (pl != HP_NONE) {
                int layer = pl == HP_GRASS ? MC_SHORT_GRASS
                          : pl == HP_POPPY ? MC_POPPY
                          : pl == HP_DANDELION ? MC_DANDELION
                          : pl == HP_CORNFLOWER ? MC_CORNFLOWER
                          : pl == HP_DAISY ? MC_OXEYE_DAISY : MC_FIREFLY_BUSH;
                if (mcCross(mcTiles, layer, float3(float(b.x), 0.0, float(b.y)),
                            pl == HP_GRASS ? E.grassTint : float3(1.0),
                            ro, rd, max(tEnter - 1e-4, tMin), tExit, E.pxA, h.m)) {
                    h.t = h.m.t; h.kind = HK_PLANT; h.n = h.m.n; h.b = b; h.part = pl;
                    return h;
                }
            }
        }
        if (tExit > tLim) break;
        if (rd.y > 0.0 && ro.y + rd.y * tExit > HM_TOP) break;
        tEnter = tExit;
        if (tMax.x < tMax.y) { tMax.x += tDelta.x; b.x += st.x; lastX = true; }
        else                 { tMax.y += tDelta.y; b.y += st.y; lastX = false; }
    }
    if (tFloor <= tFar && tFloor > tMin) {
        h.t = tFloor; h.kind = HK_FLOOR; h.n = float3(0.0, 1.0, 0.0);
        float3 P = ro + rd * tFloor;
        h.b = int2(floor(P.xz));
    }
    return h;
}

// ---------------------------------------------------------------------------
// Light, the game's way: a block light level that falls by one a block from
// each source (lanterns and the beacon are 15), the sky light at night, and
// the lightmap that turns the two into a colour.

static inline float hmBlockLevel(float3 q, device const uint* verts, thread const HmEnv& E) {
    float lv = 0.0;
    int2 v0 = int2(round((q.xz - 0.5) / 4.0));
    for (int dz = -2; dz <= 2; ++dz) {
        for (int dx = -2; dx <= 2; ++dx) {
            int2 v = v0 + int2(dx, dz);
            if (hmRec(verts, v, E.cells) == 0u || !hmHasLamp(v, E.salt)) continue;
            float3 L = abs(float3(4.0 * float(v.x) + 0.5, 4.5, 4.0 * float(v.y) + 0.5) - q);
            lv = max(lv, 15.0 - (L.x + L.y + L.z));
        }
    }
    float3 Bc = abs(float3(E.goalXZ.x, 1.5, E.goalXZ.y) - q);
    lv = max(lv, 15.0 - (Bc.x + Bc.y + Bc.z));
    return max(lv, 0.0);
}

// The game's lightmap at midnight in the Overworld.
static inline float3 hmLightmap(float blockLevel) {
    return mcLightmap(blockLevel, 15.0, 0.0, 0.0);
}

// ---------------------------------------------------------------------------
// Sky: the night gradient, stars, the moon, the cloud layer.

static inline float hmBoxCover(float2 d, float s, float px) {
    float2 c = saturate((s - abs(d)) / px + 0.5);
    return c.x * c.y;
}

static inline float3 hmSky(float3 ro, float3 rd, thread const HmEnv& E, uint seedSalt, int moonLayer,
                           float3 moonDir, texture2d_array<float> mcSkins, texture2d_array<float> mcMaps) {
    float el = rd.y;
    float3 col = mix(E.hor, E.zen, smoothstep(-0.05, 0.45, el));
    if (el <= 0.0) return col;

    // Stars, small white squares, on the faces of a cube round the eye.
    float3 a = abs(rd);
    float2 sp; float face;
    if (a.y > max(a.x, a.z)) { sp = rd.xz / a.y; face = 0.0; }
    else if (a.x > a.z)      { sp = rd.zy / a.x; face = rd.x > 0.0 ? 1.0 : 2.0; }
    else                     { sp = rd.xy / a.z; face = rd.z > 0.0 ? 3.0 : 4.0; }
    const float SC = 0.045;
    int2 gi = int2(floor(sp / SC));
    float sh = hmR(int3(gi.x, int(face), gi.y), int2(5), seedSalt);
    if (sh < 0.3) {
        float2 c = (float2(gi) + 0.25 + 0.5 * float2(hmR(int3(gi.x, int(face), gi.y), int2(6), seedSalt),
                                                     hmR(int3(gi.x, int(face), gi.y), int2(7), seedSalt))) * SC;
        float cov = hmBoxCover(sp - c, 0.0012 + 0.0012 * sh, E.pxA);
        col += float3(0.5) * cov * (0.5 + 1.5 * sh) * smoothstep(0.02, 0.2, el);
    }

    // The moon, drawn on black and added.
    float md = dot(rd, moonDir);
    if (md > 0.0) {
        float3 mR = normalize(cross(float3(0.0, 1.0, 0.0), moonDir));
        float3 mU = cross(moonDir, mR);
        float2 p = float2(dot(rd, mR), dot(rd, mU)) / md;
        const float S = 0.2;                       // the quad's half-size
        if (max(abs(p.x), abs(p.y)) < S) {
            float2 px = (float2(p.x, -p.y) / S * 0.5 + 0.5) * 32.0;
            col += mcSkin(mcSkins, moonLayer, px, E.pxA / (2.0 * S / 32.0)).rgb;
        }
    }

    // The cloud layer: clouds.png, a pixel to twelve blocks, drifting.
    if (el > 0.01) {
        float t = (HM_CLOUD_Y - ro.y) / el;
        float2 q = ro.xz + rd.xz * t + float2(E.now * 0.6, 0.0);
        float2 px = q / 12.0;
        px = px - 256.0 * floor(px / 256.0);
        float w = t * E.pxA / sqrt(el) / 12.0;
        float4 c = mcMap(mcMaps, MCM_ENVIRONMENT_CLOUDS, px, w);
        float cov = c.a * max(c.r, max(c.g, c.b));
        float fade = 1.0 - smoothstep(300.0, 900.0, t);
        col = mix(col, E.cloud, cov * 0.8 * fade);
    }
    return col;
}

// ---------------------------------------------------------------------------

struct HmCache {
    bool valid, skyValid;
    float3 sky;
    int kind;
    int2 b, tid;
    float3 n, light;
};

// Per-pixel derivatives of a plane hit's position, for anisotropic filtering.
static inline void hmDerivs(float t, float3 rd, float3 n, thread const HmEnv& E,
                            thread float3& dPx, thread float3& dPy) {
    float dn = dot(rd, n);
    dn = abs(dn) < 0.02 ? (dn < 0.0 ? -0.02 : 0.02) : dn;
    float3 dRx = E.camR * E.pxA, dRy = E.camU * E.pxA;
    dPx = t * (dRx - rd * dot(dRx, n) / dn);
    dPy = t * (dRy - rd * dot(dRy, n) / dn);
}

static inline float3 hmScene(float3 ro, float3 rd, thread const HmEnv& E, uint seedSalt,
                             int moonLayer, float3 moonDir,
                             constant LerpMazeFrame& F, device const uint* verts,
                             texture2d_array<float> mcTiles, texture2d_array<float> mcSkins,
                             texture2d_array<float> mcMaps,
                             thread HmCache& cache, thread float& tOut, thread bool& edge) {
    float tMin = 0.0;
    HmHit h;
    float3 col = E.fog;
    edge = false;
    tOut = 1e9;
    for (int layer = 0; layer < HM_LAYERS; ++layer) {
        h = hmTrace(ro, rd, tMin, HM_FOG1, verts, E, mcTiles);
        if (layer == 0) edge = h.clear < 1.5 * E.pxA;
        if (h.kind == HK_NONE) {
            if (cache.skyValid) col = cache.sky;
            else {
                col = rd.y > 0.0 ? hmSky(ro, rd, E, seedSalt, moonLayer, moonDir, mcSkins, mcMaps) : E.fog;
                cache.sky = col; cache.skyValid = true;
            }
            break;
        }
        tOut = h.t;
        float3 P = ro + rd * h.t;
        float3 n = h.n;
        float px = h.t * E.pxA;
        float fogK = smoothstep(HM_FOG0, HM_FOG1, h.t);

        if (h.kind == HK_PLANT) {
            if (layer == 0 && h.m.color.a < 0.9) edge = true;
            float3 q = float3(float(h.b.x) + 0.5, 0.5, float(h.b.y) + 0.5);
            col = h.m.color.rgb * hmLightmap(hmBlockLevel(q, verts, E));
            if (h.part == HP_BUSH) {
                float4 em = mcModelTexel(mcTiles, E.bushFrame, h.m.px, h.m.rect, px);
                col = mix(col, em.rgb, em.a);
            }
            col = mix(col, E.fog, fogK);
            break;
        }

        if (h.kind == HK_LAMP || h.kind == HK_BMODEL) {
            // Lantern and beacon both give light 15.
            col = h.m.color.rgb * hmLightmap(15.0) * (h.m.shade > 0.5 ? mcFaceShade(n) : 1.0);
            col = mix(col, E.fog, fogK);
            edge = edge || layer == 0;
            break;
        }

        // A block face.
        bool top = abs(n.y) > 0.5;
        float2 uvF; float3 aU, aV;
        if (top) { uvF = P.xz; aU = float3(1, 0, 0); aV = float3(0, 0, 1); }
        else if (abs(n.x) > 0.5) { uvF = float2(P.z, P.y); aU = float3(0, 0, 1); aV = float3(0, 1, 0); }
        else { uvF = float2(P.x, P.y); aU = float3(1, 0, 0); aV = float3(0, 1, 0); }
        float2 tuv = top ? fract(uvF) : float2(fract(uvF.x), 1.0 - fract(uvF.y));
        float3 dPx, dPy;
        hmDerivs(h.t, rd, n, E, dPx, dPy);
        float vs = top ? 1.0 : -1.0;
        float2 dx = float2(dot(dPx, aU), vs * dot(dPx, aV));
        float2 dy = float2(dot(dPy, aU), vs * dot(dPy, aV));

        int texL;
        float3 tint = float3(1.0);
        bool cutout = false;
        if (h.kind == HK_FLOOR) {
            texL = hmIsPath(h.b, verts, E) ? MC_DIRT_PATH_TOP : MC_GRASS_BLOCK_TOP;
            if (texL == MC_GRASS_BLOCK_TOP) tint = E.grassTint;
        } else if (h.kind == HK_HEDGE) {
            int2 ci = h.b >> 2, r = h.b & 3;
            uint rec = hmRec(verts, ci, E.cells);
            bool feature = (rec & (r.y == 0 ? 16u : 32u)) != 0u;
            texL = feature ? MC_FLOWERING_AZALEA_LEAVES : E.leaf;
            if (!feature) tint = E.leafTint;
            cutout = true;
        } else if (h.kind == HK_BASE || h.kind == HK_BEACON) {
            texL = MC_IRON_BLOCK;
        } else {
            texL = E.pillar;
        }
        float4 tx = mcTileAniso(mcTiles, texL, tuv, dx, dy);

        if (cutout && tx.a < 0.5) {
            if (layer < HM_LAYERS - 1) {
                if (layer == 0 && tx.a > 0.1) edge = true;
                tMin = h.t + 1e-4;
                continue;
            }
            tx.rgb *= 0.35;   // the last leaf seen through: the hedge's dark inside
        }
        float3 alb = tx.rgb * tint;

        // Geometric edges near the first hit, for the extra samples.
        if (layer == 0) {
            if (cutout && tx.a < 0.9) edge = true;
            float2 fwB = float2(length(dx), length(dy)) * 1.5;
            float fw = max(fwB.x, fwB.y);
            if (h.kind == HK_FLOOR) {
                float2 f = fract(P.xz);
                if (f.x < fw)       edge = edge || hmSolid(h.b - int2(1, 0), verts, E) > 0.0;
                if (f.x > 1.0 - fw) edge = edge || hmSolid(h.b + int2(1, 0), verts, E) > 0.0;
                if (f.y < fw)       edge = edge || hmSolid(h.b - int2(0, 1), verts, E) > 0.0;
                if (f.y > 1.0 - fw) edge = edge || hmSolid(h.b + int2(0, 1), verts, E) > 0.0;
            } else if (!top) {
                edge = edge || (h.H - P.y) < fw || P.y < fw || (h.kind >= HK_BASE && abs(P.y - 1.0) < fw);
                int2 a = h.b + int2(int(n.x), int(n.z));
                int2 td = abs(n.x) > 0.5 ? int2(0, 1) : int2(1, 0);
                float fu = fract(uvF.x);
                if (fu < fw)
                    edge = edge || P.y > 2.9 || hmSolid(h.b - td, verts, E) == 0.0 || hmSolid(a - td, verts, E) > 0.0;
                if (fu > 1.0 - fw)
                    edge = edge || P.y > 2.9 || hmSolid(h.b + td, verts, E) == 0.0 || hmSolid(a + td, verts, E) > 0.0;
            } else {
                float2 f = fract(P.xz);
                edge = edge || min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)) < fw;
            }
        }

        // Light is the same for every sample in the same texel of the same
        // face, so the pixel's extra samples usually reuse it.
        int2 tid = int2(floor(uvF * 16.0));
        float3 light;
        if (cache.valid && cache.kind == h.kind && all(cache.b == h.b) && all(cache.n == n)
            && all(cache.tid == tid)) {
            light = cache.light;
        } else {
            float3 Ps = P;
            if (top) Ps.xz = (floor(P.xz * 16.0) + 0.5) / 16.0;
            float ao;
            if (h.kind == HK_FLOOR) {
                // Smooth lighting's corner shading where the floor meets a hedge.
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
                ao = 1.0 - 0.45 * saturate(occ);
            } else if (top) {
                ao = 1.0;
            } else {
                int2 a = h.b + int2(int(n.x), int(n.z));
                int2 td = abs(n.x) > 0.5 ? int2(0, 1) : int2(1, 0);
                float al = fract(uvF.x);
                float occ = hmSolid(a + td, verts, E) * al * al
                          + hmSolid(a - td, verts, E) * (1.0 - al) * (1.0 - al);
                float lowY = saturate(1.0 - fract(P.y) - floor(P.y));
                occ += 0.8 * lowY * lowY;
                ao = 1.0 - 0.4 * saturate(occ);
            }
            float3 lm = hmLightmap(hmBlockLevel(Ps + n * 0.5, verts, E));
            light = lm * mcFaceShade(n) * ao;
            cache.valid = true; cache.kind = h.kind; cache.b = h.b; cache.n = n; cache.tid = tid;
            cache.light = light;
        }
        col = alb * light;
        col = mix(col, E.fog, fogK);
        break;
    }
    return col;
}

// ---------------------------------------------------------------------------
// Things in the air, once a pixel along its centre ray: the dropped diamonds,
// the beacon's beam, the fireflies.

static inline float3 hmOverlays(float3 col, float3 ro, float3 rd, float tHit, thread const HmEnv& E,
                                constant LerpMazeFrame& F, device const uint* verts,
                                texture2d_array<float> mcItems, texture2d_array<float> mcSkins,
                                thread bool& edge) {
    // The beam: a square column of beacon_beam.png turning slowly, full
    // bright. Narrower than a pixel far off, it keeps its light by covering
    // part of one.
    {
        float2 o = ro.xz - E.goalXZ;
        float a = E.now * 0.4;
        float ca = cos(a), sa = sin(a);
        float2 ol = float2(ca * o.x + sa * o.y, -sa * o.x + ca * o.y);
        float2 dl = float2(ca * rd.x + sa * rd.z, -sa * rd.x + ca * rd.z);
        float tc = max(-dot(o, rd.xz) / max(dot(rd.xz, rd.xz), 1e-6), 0.0);
        float hw = max(0.2, tc * E.pxA * 0.7);
        dl = select(dl, float2(1e-7), abs(dl) < 1e-7);
        float2 inv = 1.0 / dl;
        float2 t1 = (-hw - ol) * inv, t2 = (hw - ol) * inv;
        float2 tn = min(t1, t2), tf = max(t1, t2);
        float tN = max(tn.x, tn.y), tF = min(tf.x, tf.y);
        if (tN < tF && tN > 0.0 && tN < tHit) {
            float y = ro.y + rd.y * tN;
            if (y > 2.0) {
                float2 lp = ol + dl * tN;
                float uu = tn.x > tn.y ? lp.y : lp.x;
                float2 pxl = float2((uu / hw * 0.5 + 0.5) * 16.0, fract(y * 0.25 - E.now * 0.35) * 16.0);
                float4 bt = mcSkin(mcSkins, MCS_BEACON_BEAM, pxl, 0.0);
                float cov = 0.2 / hw;
                float fogK = 0.6 * smoothstep(HM_FOG0, HM_FOG1 * 2.0, tN);
                col = mix(col, mix(bt.rgb * E.beamCol, E.fog, fogK), cov);
            }
        }
    }

    // Dropped diamonds, the stand-ins for the polyhedra: a flat item turning
    // about the vertical, bobbing over the path.
    for (uint i = 0; i < min(F.dim.z, 8u); ++i) {
        float4 o = F.objects[i];
        if (o.z <= 0.0) continue;
        float3 c = float3(4.0 * o.x + 0.5, 0.42 + 0.1 * sin(E.now * 1.6 + o.w), 4.0 * o.y + 0.5);
        float a = E.now * 1.1 + o.w;
        float3 nrm = float3(cos(a), 0.0, sin(a));
        float3 tng = float3(-sin(a), 0.0, cos(a));
        float dn = dot(rd, nrm);
        if (abs(dn) < 1e-4) continue;
        float t = dot(c - ro, nrm) / dn;
        if (t <= 0.0 || t >= tHit) continue;
        float3 q = ro + rd * t - c;
        float s = 0.5 * o.z;
        float2 uv = float2(dot(q, tng) / s + 0.5, 0.5 - q.y / s);
        if (dn > 0.0) uv.x = 1.0 - uv.x;
        if (any(uv < 0.0) || any(uv > 1.0)) continue;
        float4 it = mcItems.sample(mcRepeat, mcCrisp(uv * MC_TILE, t * E.pxA / s * MC_TILE) / MC_TILE,
                                   MC_ITEM_DIAMOND, level(log2(max(t * E.pxA / s * MC_TILE, 1.0))));
        if (it.a < 0.5) continue;
        if (it.a < 0.95) edge = true;
        float3 lp = c;
        col = it.rgb * hmLightmap(hmBlockLevel(lp, verts, E));
        col = mix(col, E.fog, smoothstep(HM_FOG0, HM_FOG1, t));
        tHit = t;
    }

    // Fireflies, round each firefly bush: the game's firefly particle, a
    // small full-bright square fading in and out. The ray visits the cells on
    // its way, testing each cell's bush.
    {
        float tEnd = min(tHit, HM_FOG1);
        float2 o = ro.xz / 4.0;
        float2 d = select(rd.xz, float2(1e-7), abs(rd.xz) < 1e-7);
        float2 inv = 1.0 / d;
        int2 c = int2(floor(o));
        int2 st = int2(sign(d));
        float2 tDelta = abs(inv) * 4.0;
        float2 tMax = (float2(c) + select(float2(0.0), float2(1.0), d > 0.0) - o) * inv * 4.0;
        float4 fc = mcSkin(mcSkins, MCS_PARTICLE_FIREFLY, float2(0.5), 0.0);
        for (int i = 0; i < 16; ++i) {
            int2 bush;
            if (hmBush(c, E, bush)) {
                for (int k = 0; k < 2; ++k) {
                    float ph = float(bush.x * 7 + bush.y * 13 + k * 31);
                    float3 p = float3(float(bush.x) + 0.5 + 0.9 * sin(E.now * 0.23 + ph),
                                      0.9 + 0.6 * sin(E.now * 0.17 + ph * 1.3),
                                      float(bush.y) + 0.5 + 0.9 * sin(E.now * 0.29 + ph * 0.7));
                    float tc = dot(p - ro, rd);
                    if (tc > 0.2 && tc < tEnd) {
                        float3 q = ro + rd * tc - p;
                        float2 sq = float2(dot(q, E.camR), dot(q, E.camU));
                        float on = smoothstep(0.0, 0.7, sin(E.now * 0.5 + ph * 1.7));
                        float cov = hmBoxCover(sq, 0.04, tc * E.pxA);
                        col = mix(col, fc.rgb, cov * on * fc.a * (1.0 - smoothstep(HM_FOG0, HM_FOG1, tc)));
                    }
                }
            }
            float tExit = min(tMax.x, tMax.y);
            if (tExit > tEnd) break;
            if (tMax.x < tMax.y) { tMax.x += tDelta.x; c.x += st.x; }
            else                 { tMax.y += tDelta.y; c.y += st.y; }
        }
    }
    return col;
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpMazeFrame& F [[buffer(1)]],
                        device const uint* verts [[buffer(2)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcItems [[texture(9)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
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
    E.goalCell = int2(floor(F.goal.xy));
    E.goalXZ = 4.0 * F.goal.xy + 0.5;
    E.goalB = int2(floor(E.goalXZ));
    E.salt = uint(F.goal.z * 16777216.0);
    E.style = u.style > 0 ? uint(u.style - 1) & 3u : (F.dim.w & 3u);
    E.now = u.time;
    E.pxA = 2.0 / (minRes * HM_FOCAL * lens);
    E.camR = right;
    E.camU = up;
    E.zen = mcSkyAt(0.03);
    E.hor = mcFogAt(0.0);
    E.fog = E.hor;
    E.cloud = float3(0.13, 0.13, 0.16);
    E.grassTint = mcGrassTint(mcMaps, 0.8, 0.4);
    E.beamCol = u.colorGoal.rgb;
    E.lampFrame = mcFrame(MC_LANTERN, MC_LANTERN_FRAMES, MC_LANTERN_TICKS, u.time);
    E.bushFrame = mcFrame(MC_FIREFLY_BUSH_EMISSIVE, MC_FIREFLY_BUSH_EMISSIVE_FRAMES,
                          MC_FIREFLY_BUSH_EMISSIVE_TICKS, u.time);
    switch (E.style) {
    case 0u:  E.leaf = MC_OAK_LEAVES;    E.pillar = MC_STONE_BRICKS;
              E.leafTint = mcFoliageTint(mcMaps, 0.8, 0.4); break;
    case 1u:  E.leaf = MC_SPRUCE_LEAVES; E.pillar = MC_MOSSY_STONE_BRICKS;
              E.leafTint = mcFromSRGB(float3(0x61, 0x99, 0x61) / 255.0); break;
    case 2u:  E.leaf = MC_BIRCH_LEAVES;  E.pillar = MC_BIRCH_LOG;
              E.leafTint = mcFromSRGB(float3(0x80, 0xA7, 0x55) / 255.0); break;
    default:  E.leaf = MC_CHERRY_LEAVES; E.pillar = MC_CHERRY_LOG;
              E.leafTint = float3(1.0); break;
    }

    uint seedSalt = uint(u.seed * 16777216.0);
    float maz = u.seed * TWO_PI;
    const float mel = 0.5;
    float3 moonDir = float3(cos(mel) * cos(maz), sin(mel), cos(mel) * sin(maz));
    const int phases[8] = { MCS_ENVIRONMENT_CELESTIAL_MOON_FULL_MOON, MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_GIBBOUS,
                            MCS_ENVIRONMENT_CELESTIAL_MOON_THIRD_QUARTER, MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_CRESCENT,
                            MCS_ENVIRONMENT_CELESTIAL_MOON_NEW_MOON, MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_CRESCENT,
                            MCS_ENVIRONMENT_CELESTIAL_MOON_FIRST_QUARTER, MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_GIBBOUS };
    // Any phase but new, which shows nothing.
    int moonLayer = phases[int(u.seed * 7.0) % 7 + (int(u.seed * 7.0) % 7 >= 4 ? 1 : 0)];

    // One sample at the pixel's centre; where a geometric edge crosses the
    // pixel, two more. Their light comes from the cache when they land in
    // the same texel.
    const float2 grid[2] = { float2(0.33, 0.15), float2(-0.15, -0.33) };
    HmCache cache;
    cache.valid = false;
    cache.skyValid = false;
    float2 uv0 = lerpUV(pos, u.resolution);
    float3 rd0 = normalize(uv0.x * right + uv0.y * up + lens * HM_FOCAL * fwd);
    float tFirst;
    bool edge;
    float3 col = hmScene(ro, rd0, E, seedSalt, moonLayer, moonDir, F, verts, mcTiles, mcSkins, mcMaps,
                         cache, tFirst, edge);
    bool edge2 = false;
    float3 over = hmOverlays(col, ro, rd0, tFirst, E, F, verts, mcItems, mcSkins, edge2);
    if (edge || edge2) {
        float3 acc = over;
        for (int s = 0; s < 2; ++s) {
            float4 p = pos;
            p.xy += grid[s];
            float2 uv = lerpUV(p, u.resolution);
            float3 rd = normalize(uv.x * right + uv.y * up + lens * HM_FOCAL * fwd);
            float tS; bool eS, eO = false;
            float3 cS = hmScene(ro, rd, E, seedSalt, moonLayer, moonDir, F, verts, mcTiles, mcSkins, mcMaps,
                                cache, tS, eS);
            acc += edge2 ? hmOverlays(cS, ro, rd, tS, E, F, verts, mcItems, mcSkins, eO)
                         : cS + (over - col);
        }
        col = acc / 3.0;
    } else {
        col = over;
    }

    col *= F.motion.x;
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
