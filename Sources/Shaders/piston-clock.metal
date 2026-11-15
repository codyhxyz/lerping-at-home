// Piston Clock — a wall clock built out of blocks, telling the Mac's time.
// Original work for Lerping@Home. The idea is the redstone display people
// build in block worlds: every pixel of the digits is a block on a piston,
// and the time is written by pushing blocks out of a wall and pulling them
// back in. All art here is procedural; nothing is taken from any game.
//
// lerp-category: Blocks
// lerp-data: clock
//
// - The time is real (`lerp-data: clock`): hours and minutes in pistoned
//   blocks, 3×5 a digit. When the minute turns, the blocks that change slide
//   out or back in a ripple that runs left to right, a column every
//   redstone tick or so. Blocks that are off sit one deep in the wall, so a
//   digit's unused cells show as shadowed pits — the ghost of an 8.
// - Seconds are a ring of sixty lamps round the wall's edge, lit one a second
//   clockwise from the top, drained in a sweep as the minute turns. The colon
//   is two lamps breathing once a second. Two lanterns on the plinth's front
//   corners give the night a warm key light.
// - The sky follows the same clock: a square sun by day, a square moon and
//   blocky stars at night, warm light at dawn and dusk, a deck of flat cube
//   clouds drifting over. Stills (gallery, snapshots) are midnight, 12:00.
// - Every frame is a pure function of (time, seed, parameters, hour at time
//   0). The camera swings slowly round the clock; drag to turn, pinch to zoom.
// - Seed picks the masonry (stone brick, sandstone, dark tile, red brick),
//   the land (meadow, snow, dry grass), the hills and trees, and where the
//   camera's swing starts.
// - Texels: 16 a face, read with a sharpened four-tap so they stay crisp up
//   close and soften, then fade to the face's mean, at distance.
// - GPU cost: about 11 ms a frame at 3456×2234 (night and day). The clock
//   is walked cell by cell only inside its own box (at most 56 cells, a few
//   in practice); the ground is walked in 8×8 patches, crossed whole when the
//   ray is above their hills (bounded by the noise's lattice corners) and
//   their tree's box, and column by column (at most 96) only where it is not.
//   Flat patches are hit as a plane. Then one shadow ray through the same
//   code, eight neighbour reads for corner shading (skipped on open ground
//   and the open wall face), four texel reads.
//
// lerp-param: clock    float -1 24   = -1    "Hour (-1 = now)"
// lerp-param: hour24   bool          = false "24-hour"
// lerp-param: masonry  int 0 4       = 0     "Masonry (0 = new each time)"
// lerp-param: yaw      float -180 180 = 0    "Turn"
// lerp-param: pitch    float -12 40  = 0     "Tilt"
// lerp-param: magnify  float -1 0.8  = 0     "Zoom"
//
// lerp-preset: "Oak and Sandstone" masonry=2
// lerp-preset: "Dark Tile" masonry=3

constant int   PC_STEPS        = 96;    // ground columns a view ray may cross
constant int   PC_SHADOW_STEPS = 40;    // and a shadow ray
constant float PC_FOCAL        = 1.9;
constant float PC_TOP          = 18.0;   // nothing solid at or above this y
constant float PC_RANGE        = 60.0;   // fog is total by here

// Materials.
constant int PC_AIR    = 0;
constant int PC_GRASS  = 1;   // ground top block (biome decides the look)
constant int PC_DIRT   = 2;
constant int PC_WALL   = 3;   // the clock's masonry
constant int PC_LAMP   = 4;   // a seconds lamp
constant int PC_COLON  = 5;
constant int PC_PLINTH = 6;
constant int PC_LOG    = 7;
constant int PC_LEAVES = 8;
constant int PC_DISP   = 9;   // a display column: resolved analytically
constant int PC_DIGIT  = 10;  // a pushed block
constant int PC_ROD    = 11;  // a piston arm
constant int PC_PATH   = 12;
constant int PC_TRIM   = 13;  // pillars and coping
constant int PC_LANTERN = 14; // the two lanterns on the plinth corners

// 3×5 seven-segment glyphs, bit (row*3 + col), row 0 at the top, col 0 left.
constant uint PC_GLYPH[10] = { 31599u, 18724u, 29671u, 31207u, 18925u,
                               31183u, 31695u, 18727u, 31727u, 31215u };

struct PcScene {
    float sec;        // seconds into the current minute
    uint4 now;        // glyph masks shown this minute
    uint4 prev;       // and last minute
    float salt;       // terrain / tree seed
    int   biome;      // 0 meadow, 1 snow, 2 dry grass
    int   masonry;    // 1..4
};

// ---------------------------------------------------------------------------
// The clock's state.

static inline uint4 pcDigits(int m, bool h24) {
    int hh = m / 60, mm = m % 60;
    if (!h24) { hh = hh % 12; if (hh == 0) hh = 12; }
    int d0 = hh / 10;
    return uint4((d0 == 0 && !h24) ? 0u : PC_GLYPH[d0], PC_GLYPH[hh % 10],
                 PC_GLYPH[mm / 10], PC_GLYPH[mm % 10]);
}

// Which digit a display column belongs to (-1 if none) and its column in it.
static inline int pcDigitAt(int x, thread int& cx) {
    // Columns -8..-6 and -4..-2 are digits 0 and 1; 2..4 and 6..8 are 2 and 3.
    int q = x < 0 ? x + 8 : x - 2;
    if (q < 0 || q > 6 || q == 3) return -1;
    cx = q & 3;
    return (x < 0 ? 0 : 2) + q / 4;
}

// Face position of the pushed block in display column (x, y): +1 out, -1 in.
// Returns -9 when (x, y) is not a display cell.
static inline float pcCellF(int x, int y, thread const PcScene& S) {
    if (y < 3 || y > 7) return -9.0;
    int cx;
    int k = pcDigitAt(x, cx);
    if (k < 0) return -9.0;
    int r = 7 - y;
    int b = r * 3 + cx;
    uint mp = k == 0 ? S.prev.x : (k == 1 ? S.prev.y : (k == 2 ? S.prev.z : S.prev.w));
    uint mn = k == 0 ? S.now.x  : (k == 1 ? S.now.y  : (k == 2 ? S.now.z  : S.now.w));
    float a = ((mp >> b) & 1u) ? 1.0 : -1.0;
    float c = ((mn >> b) & 1u) ? 1.0 : -1.0;
    if (a == c) return c;
    float col = float(x + 8);                 // 0 at the left edge
    float d = 0.075 * col + 0.05 * float(r);
    float p = smoothstep(d, d + 0.85, S.sec);
    return mix(a, c, p);
}

// Seconds lamp k (0 at top centre, clockwise): lit at second k, drained in a
// sweep as the minute turns.
static inline float pcLampB(float k, float s) {
    float rise  = saturate((s - k) / 0.3);
    float drain = 1.0 - saturate((s - 0.013 * k - 0.05) / 0.22);
    return max(rise, drain);
}

static inline int pcRingIndex(int x, int y) {
    if (y == 9)  return x >= 0 ? x : 60 + x;
    if (x == 11) return 12 + (8 - y);
    if (y == 1)  return 19 + (11 - x);
    return 42 + (y - 2);                        // x == -11
}

static inline float pcColonB(float s) {
    return 0.45 + 0.55 * (0.5 + 0.5 * cos(TWO_PI * s));
}

// ---------------------------------------------------------------------------
// The world: the clock (a known box, walked cell by cell only inside it) on
// ground that is a heightfield with trees (walked column by column).

constant float3 PC_CLO = float3(-13.0, 0.0, -7.0);   // the clock's cell bounds
constant float3 PC_CHI = float3( 14.0, 11.0, 2.0);   // nothing solid at y >= 11

static inline float pcAmp(float2 p) {
    float r = length(p);
    return r < 15.0 ? 0.0 : smoothstep(15.0, 36.0, r) * mix(1.0, 0.35, smoothstep(0.0, 16.0, p.y));
}

static inline int pcGroundH(int2 c, float salt) {
    float2 p = float2(c) + float2(-0.5, 0.5);
    float amp = pcAmp(p);
    if (amp * 14.0 < 1.0) return 0;
    float n = valueNoise(p * 0.075 + salt);
    return int(floor(n * n * 14.0 * amp));
}

// The same heights, with the noise lattice's four corner hashes kept between
// neighbouring columns of one walk.
struct PcNoiseCache { int2 cell; float4 h; };

static inline int pcGroundHC(float2 p, float amp, float salt, thread PcNoiseCache& nc) {
    float2 st = p * 0.075 + salt;
    float2 i = floor(st);
    int2 ii = int2(i);
    if (any(ii != nc.cell)) {
        nc.cell = ii;
        nc.h = float4(hash21(i), hash21(i + float2(1.0, 0.0)), hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)));
    }
    float2 f = st - i;
    float2 w = f * f * (3.0 - 2.0 * f);
    float n = mix(mix(nc.h.x, nc.h.y, w.x), mix(nc.h.z, nc.h.w, w.x), w.y);
    return int(floor(n * n * 14.0 * amp));
}

// Trees, one per 8×8 patch at most, never in the clearing or in front.
struct PcTree { int2 patch; int2 base; int gh; int height; float th; bool has; };

static inline void pcTreeAt(int2 patch, float salt, thread PcTree& T) {
    T.patch = patch;
    T.th = hash21(float2(patch) + salt * 3.17);
    T.has = T.th <= 0.5;
    if (!T.has) return;
    T.base = patch * 8 + 2 + int2(hash22(float2(patch) * 1.37 + salt) * 3.99);
    float br = length(float2(T.base));
    if (br < 17.0 || (T.base.y > 3 && br < 44.0)) { T.has = false; return; }   // keep the camera's side clear
    T.gh = pcGroundH(T.base, salt);
    T.height = 4 + int(T.th * 6.0) % 3;
}

static inline int pcTreeBlock(int3 c, thread const PcTree& T) {
    if (c.y >= int(PC_TOP)) return PC_AIR;
    int dy = c.y - T.gh;
    if (dy < 0 || dy > T.height + 1) return PC_AIR;
    int2 ad = abs(c.xz - T.base);
    if (ad.x == 0 && ad.y == 0 && dy < T.height) return PC_LOG;
    if (dy >= T.height - 2 && dy < T.height) {
        if (ad.x <= 2 && ad.y <= 2) {
            if (ad.x == 2 && ad.y == 2 && hash21(float2(c.xz) + float(c.y) * 7.1) < 0.6) return PC_AIR;
            return PC_LEAVES;
        }
    } else if (dy >= T.height) {
        if (ad.x + ad.y <= 1 || (dy == T.height && ad.x <= 1 && ad.y <= 1 && hash21(float2(c.xz) + 3.3) < 0.5))
            return PC_LEAVES;
    }
    return PC_AIR;
}

static inline int pcGroundMat(int3 c, int h) {
    if (c.y < h - 1) return PC_DIRT;
    if (h == 0 && c.z >= 2 && c.z <= 14 && abs(c.x) <= 1) return PC_PATH;
    return PC_GRASS;
}

// The clock: plinth, wall, pillars, coping, lanterns. Air elsewhere in its box.
static int pcClockBlock(int3 c, thread const PcScene& S) {
    if (c.y == 0) return PC_PLINTH;
    if ((c.x == -13 || c.x == 13) && c.z == 1 && c.y <= 2)
        return c.y == 1 ? PC_TRIM : PC_LANTERN;
    int ax = c.x;
    bool pillar = (ax == -12 || ax == 12) && c.z >= -6 && c.z <= 0 && c.y <= 10;
    if (pillar) return PC_TRIM;
    if (c.y == 10 && ax >= -11 && ax <= 11 && c.z >= -6 && c.z <= -1) return PC_TRIM;
    if (ax >= -11 && ax <= 11 && c.y >= 1 && c.y <= 9 && c.z >= -5 && c.z <= 0) {
        bool disp = pcCellF(ax, c.y, S) > -5.0;
        if (disp && c.z >= -2) return PC_DISP;
        if (c.z == 0) return PC_AIR;
        if (c.z == -1) {
            if (ax == -11 || ax == 11 || c.y == 1 || c.y == 9) return PC_LAMP;
            if (ax == 0 && (c.y == 4 || c.y == 6)) return PC_COLON;
        }
        return PC_WALL;
    }
    return PC_AIR;
}

static inline bool pcInClockBox(int3 c) {
    return c.x >= -13 && c.x <= 13 && c.y >= 0 && c.y <= 10 && c.z >= -7 && c.z <= 1;
}

// True when every column within one of c is flat ground at height 0 with no
// clock and no tree crown over it: hills need amp*14 >= 1, and crowns come
// only from trees rooted 17+ from the clock and, in front, 44+.
static inline bool pcFlatAround(int2 c) {
    if (c.x >= -14 && c.x <= 14 && c.y >= -8 && c.y <= 2) return false;
    float2 p = float2(c) + float2(-0.5, 0.5);
    float r = length(p) + 1.5;
    float amp = smoothstep(15.0, 36.0, r) * mix(1.0, 0.35, smoothstep(0.0, 16.0, p.y - 1.5));
    if (amp * 14.0 >= 1.0) return false;
    return r + 3.0 < 17.0 || (p.y > 6.5 && r + 3.0 < 44.0);
}

// Solid for corner shading, sharing noise and tree lookups across the
// eight neighbours of one face. Display columns count as open.
static inline bool pcSolidForAO(int3 c, thread const PcScene& S,
                                thread PcNoiseCache& nc, thread PcTree& T) {
    if (c.y >= int(PC_TOP)) return false;
    if (pcInClockBox(c)) { int m = pcClockBlock(c, S); return m != PC_AIR && m != PC_DISP; }
    float2 pc = float2(c.xz) + float2(-0.5, 0.5);
    float amp = pcAmp(pc);
    int h = amp * 14.0 < 1.0 ? 0 : pcGroundHC(pc, amp, S.salt, nc);
    if (c.y < h) return true;
    if (length(float2(c.xz)) < 14.0) return false;          // no crown reaches the clearing
    int2 patch = int2(c.x >> 3, c.z >> 3);
    if (any(patch != T.patch)) pcTreeAt(patch, S.salt, T);
    return T.has && pcTreeBlock(c, T) != PC_AIR;
}

// ---------------------------------------------------------------------------
// Tracing.

constant int PC_CLOCK_STEPS = 56;    // the most cells a ray crosses in the clock's box

struct PcHit {
    float  t;
    float3 n;
    int3   cell;
    int    mat;
    float  f;      // the pushed block's face position, for PC_DIGIT / PC_ROD
};

static inline PcHit pcMiss() {
    PcHit h;
    h.t = 1e9; h.mat = PC_AIR; h.n = float3(0.0, 1.0, 0.0); h.cell = int3(0); h.f = 0.0;
    return h;
}

static inline bool pcBox(float3 ro, float3 inv, float3 lo, float3 hi,
                         thread float& t, thread float3& n) {
    float3 t1 = (lo - ro) * inv, t2 = (hi - ro) * inv;
    float3 tn = min(t1, t2), tf = max(t1, t2);
    float a = max(max(tn.x, tn.y), tn.z), b = min(min(tf.x, tf.y), tf.z);
    if (a > b || b <= 0.0) return false;
    t = a;
    if (a == tn.x)      n = float3(-sign(inv.x), 0.0, 0.0);
    else if (a == tn.y) n = float3(0.0, -sign(inv.y), 0.0);
    else                n = float3(0.0, 0.0, -sign(inv.z));
    return true;
}

// Cell walk confined to the clock's box.
static PcHit pcClockTrace(float3 ro, float3 rd, float3 inv, float tMax, thread const PcScene& S) {
    PcHit h = pcMiss();
    float tIn; float3 n;
    if (!pcBox(ro, inv, PC_CLO, PC_CHI, tIn, n) || tIn > tMax) return h;
    float t0 = max(tIn, 0.0);
    int3 cell = clamp(int3(floor(ro + rd * (t0 + 1e-4))), int3(PC_CLO), int3(PC_CHI) - 1);
    if (tIn <= 0.0) cell = int3(floor(ro));
    int3 stp = int3(sign(rd));
    float3 tDelta = abs(inv);
    float3 tNext = (float3(cell) + select(float3(0.0), float3(1.0), rd > 0.0) - ro) * inv;
    float tCur = t0;

    for (int i = 0; i < PC_CLOCK_STEPS; ++i) {
        if (!pcInClockBox(cell) || tCur > tMax) break;
        // In the front row only the plinth and the lantern posts stand, all
        // below y = 3: a ray there heading up and out has nothing left to hit.
        if (cell.z >= 1 && cell.y >= 3 && rd.z >= 0.0 && rd.y >= 0.0) break;
        int m = pcClockBlock(cell, S);
        float tExit = min(min(tNext.x, tNext.y), tNext.z);
        if (m == PC_DISP) {
            float f = pcCellF(cell.x, cell.y, S);
            float3 lo = float3(cell.x, cell.y, f - 1.0), hi = float3(cell.x + 1, cell.y + 1, f);
            float tb; float3 nb;
            if (pcBox(ro, inv, lo, hi, tb, nb) && tb <= tExit + 1e-4) {
                h.t = tb; h.n = nb; h.cell = cell; h.mat = PC_DIGIT; h.f = f; return h;
            }
            float3 rlo = float3(cell.x + 0.34, cell.y + 0.34, -2.0);
            float3 rhi = float3(cell.x + 0.66, cell.y + 0.66, f - 1.0);
            if (f > -0.98 && pcBox(ro, inv, rlo, rhi, tb, nb) && tb <= tExit + 1e-4) {
                h.t = tb; h.n = nb; h.cell = cell; h.mat = PC_ROD; h.f = f; return h;
            }
        } else if (m != PC_AIR) {
            h.t = tCur; h.n = n; h.cell = cell; h.mat = m; return h;
        }
        if (tNext.x <= tNext.y && tNext.x <= tNext.z) {
            tCur = tNext.x; cell.x += stp.x; tNext.x += tDelta.x; n = float3(-float(stp.x), 0.0, 0.0);
        } else if (tNext.y <= tNext.z) {
            tCur = tNext.y; cell.y += stp.y; tNext.y += tDelta.y; n = float3(0.0, -float(stp.y), 0.0);
        } else {
            tCur = tNext.z; cell.z += stp.z; tNext.z += tDelta.z; n = float3(0.0, 0.0, -float(stp.z));
        }
    }
    return h;
}

// What bounds any column in an 8×8 patch: amp is largest at
// the patch's farthest corner from the clock and its nearest edge to the back.
static inline float pcHillCap(float2 plo) {          // 14 × the patch's largest amp
    float2 lo = plo + float2(-0.5, 0.5), hi = plo + float2(6.5, 7.5);   // column centres
    float rmax = length(max(abs(lo), abs(hi)));
    return 14.0 * smoothstep(15.0, 36.0, rmax) * mix(1.0, 0.35, smoothstep(0.0, 16.0, lo.y));
}

// Ground walk, two levels: 8×8 patches the ray passes above (their hills and
// tree both lower than its height across the patch) are crossed in one step;
// the rest column by column. A column reads its height only when the ray
// dips below what that patch's hills could reach, and a tree's cells only
// when the ray passes through its crown.
static PcHit pcTerrainTrace(float3 ro, float3 rd, float3 inv, float tMax, int steps,
                            thread const PcScene& S) {
    PcHit h = pcMiss();
    float t = 0.0;
    if (ro.y >= PC_TOP) {
        if (rd.y >= 0.0) return h;
        t = (PC_TOP - ro.y) * inv.y;
    }
    int2 cell = int2(floor(ro.xz + rd.xz * t));
    int2 stp = int2(sign(rd.xz));
    bool2 pos = rd.xz > 0.0;
    float2 tDelta = abs(inv.xz);
    float3 nSide = float3(0.0, 1.0, 0.0);
    float ys = rd.y > 0.0 ? 1.0 : -1.0;
    int budget = steps;

    PcNoiseCache nc; nc.cell = int2(-99999);
    PcTree T; T.patch = int2(-99999); T.has = false;

    for (int pi = 0; pi < 20; ++pi) {
        int2 patch = int2(cell.x >> 3, cell.y >> 3);
        float2 plo = float2(patch * 8), phi = plo + 8.0;
        float2 tE = (select(plo, phi, pos) - ro.xz) * inv.xz;
        float tPE = min(tE.x, tE.y);
        float yA = ro.y + rd.y * t, yB = ro.y + rd.y * min(tPE, tMax);
        float hillCap = pcHillCap(plo);
        float hillTop = hillCap < 1.0 ? 0.0 : floor(hillCap);
        float yMin = min(yA, yB);
        if (yMin < hillTop) {
            // Tighter: the noise is a weighted mean of its lattice corners, so
            // no column here rises above the highest corner the patch spans.
            float2 s0 = floor((plo + float2(-0.5, 0.5)) * 0.075 + S.salt);
            float2 s1 = floor((plo + float2(6.5, 7.5)) * 0.075 + S.salt) + 1.0;
            float nmax = 0.0;
            for (int q = 0; q < 9; ++q) {
                float2 cq = s0 + float2(float(q % 3), float(q / 3));
                if (cq.x <= s1.x && cq.y <= s1.y) nmax = max(nmax, hash21(cq));
            }
            hillTop = min(hillTop, floor(nmax * nmax * hillCap));
        }
        // A tree stands on ground no higher than hillTop and reaches 8 above it,
        // so a ray that high needs no tree lookup.
        bool over = yMin >= hillTop + 8.0;
        if (!over) {
            if (any(patch != T.patch)) pcTreeAt(patch, S.salt, T);
            over = yMin >= max(hillTop, T.has ? float(T.gh + T.height + 2) : 0.0);
        }
        if (over) {
            // Nothing in this patch reaches the ray: cross it whole.
            if (tPE > tMax || (rd.y > 0.0 && yB >= PC_TOP)) return h;
            t = tPE;
            if (tE.x <= tE.y) {
                cell = int2(pos.x ? int(phi.x) : int(plo.x) - 1,
                            clamp(int(floor(ro.z + rd.z * t)), int(plo.y), int(phi.y) - 1));
                nSide = float3(-float(stp.x), 0.0, 0.0);
            } else {
                cell = int2(clamp(int(floor(ro.x + rd.x * t)), int(plo.x), int(phi.x) - 1),
                            pos.y ? int(phi.y) : int(plo.y) - 1);
                nSide = float3(0.0, 0.0, -float(stp.y));
            }
            continue;
        }

        if (hillTop == 0.0 && !T.has) {
            // Flat ground at y = 0 and nothing on it: the ray dips into it here.
            float t0 = -ro.y * inv.y;
            int2 gc = clamp(int2(floor(ro.xz + rd.xz * t0)), int2(plo), int2(phi) - 1);
            h.t = t0; h.n = float3(0.0, 1.0, 0.0); h.cell = int3(gc.x, -1, gc.y);
            h.mat = pcGroundMat(h.cell, 0);
            return h;
        }

        float2 tNext = (float2(cell) + select(float2(0.0), float2(1.0), pos) - ro.xz) * inv.xz;
        for (int ci = 0; ci < 16; ++ci) {
            if (--budget < 0) return h;
            float tB = min(tNext.x, tNext.y);
            float cA = ro.y + rd.y * t, cB = ro.y + rd.y * tB;
            float yLo = min(cA, cB);

            // Ground.
            int gh = 0;
            if (yLo < hillTop) {
                float2 pc = float2(cell) + float2(-0.5, 0.5);
                float amp = pcAmp(pc);
                gh = amp * 14.0 < 1.0 ? 0 : pcGroundHC(pc, amp, S.salt, nc);
            }
            float tg = 1e9; float3 ng = float3(0.0, 1.0, 0.0); int gy = gh - 1;
            if (yLo < float(gh)) {
                if (cA < float(gh)) { tg = t; ng = nSide; gy = int(floor(cA)); }
                else { tg = (float(gh) - ro.y) * inv.y; }
            }

            // A tree's crown or trunk.
            if (T.has && max(abs(cell.x - T.base.x), abs(cell.y - T.base.y)) <= 2) {
                int lo = T.gh, hi = T.gh + T.height + 1;           // inclusive
                int y0 = int(floor(cA));
                int y1 = int(floor(cB - ys * 1e-4));
                int ya = ys > 0.0 ? max(y0, lo) : min(y0, hi);
                for (int k = 0; k < 10; ++k) {
                    int yc = ya + int(ys) * k;
                    if ((ys > 0.0 && (yc > y1 || yc > hi)) || (ys < 0.0 && (yc < y1 || yc < lo))) break;
                    int m = pcTreeBlock(int3(cell.x, yc, cell.y), T);
                    if (m != PC_AIR) {
                        float tt = (yc == y0) ? t : ((ys > 0.0 ? float(yc) : float(yc + 1)) - ro.y) * inv.y;
                        if (tt < tg) {
                            h.t = tt; h.mat = m; h.cell = int3(cell.x, yc, cell.y);
                            h.n = (yc == y0) ? nSide : float3(0.0, -ys, 0.0);
                            return h;
                        }
                        break;
                    }
                }
            }
            if (tg < 1e8) {
                h.t = tg; h.n = ng; h.cell = int3(cell.x, gy, cell.y);
                h.mat = pcGroundMat(h.cell, gh);
                return h;
            }

            if (tB > tMax || (rd.y > 0.0 && cB >= PC_TOP)) return h;
            t = tB;
            if (tNext.x <= tNext.y) { cell.x += stp.x; tNext.x += tDelta.x; nSide = float3(-float(stp.x), 0.0, 0.0); }
            else                    { cell.y += stp.y; tNext.y += tDelta.y; nSide = float3(0.0, 0.0, -float(stp.y)); }
            if (any(int2(cell.x >> 3, cell.y >> 3) != patch)) break;
        }
    }
    return h;
}

static PcHit pcTrace(float3 ro, float3 rd, float tMax, int steps, thread const PcScene& S) {
    float3 sd = select(rd, float3(1e-6), abs(rd) < 1e-6);
    float3 inv = 1.0 / sd;
    PcHit hc = pcClockTrace(ro, sd, inv, tMax, S);
    PcHit ht = pcTerrainTrace(ro, sd, inv, min(tMax, hc.t), steps, S);
    return ht.t < hc.t ? ht : hc;
}

// Where a ray leaves the fogged disc round the clock.
static inline float pcRangeT(float3 ro, float3 rd, float R) {
    float2 o = ro.xz - float2(0.5, 0.0), d = rd.xz;
    float a = max(dot(d, d), 1e-8), b = dot(o, d), c = dot(o, o) - R * R;
    float disc = b * b - a * c;
    return disc <= 0.0 ? 0.0 : (-b + sqrt(disc)) / a;
}

// ---------------------------------------------------------------------------
// Texels. Each returns a colour for integer texel t (0..15, y up) of a face.
// `side` is 0 for a top face, 1 for a side, 2 for a bottom.

static inline float pcN(int2 t, float salt) { return hash21(float2(t) + salt * 31.7); }

static float3 pcMasonryTex(int style, int2 t, float salt) {
    float n = pcN(t, salt);
    if (style == 2) {                       // dark oak boards
        int plank = t.y / 4;
        float tone = 0.85 + 0.3 * hash21(float2(float(plank), salt * 3.0));
        bool seam = (t.y % 4 == 0) || (t.x == ((plank * 7 + 5) & 15));
        float grain = (hash21(float2(float(t.y), floor(float(t.x) / 3.0)) + salt) > 0.7) ? 0.85 : 1.0;
        return float3(0.25, 0.16, 0.09) * tone * grain * (seam ? 0.6 : 1.0) * (0.92 + 0.14 * n);
    }
    if (style == 3) {                       // dark tile, 4×4
        float3 base = float3(0.20, 0.21, 0.25);
        bool grout = (t.x % 4 == 0) || (t.y % 4 == 0);
        float tileTone = 0.85 + 0.3 * hash21(float2(t / 4) + salt * 5.1);
        return grout ? base * 0.55 : base * tileTone * (0.92 + 0.14 * n);
    }
    if (style == 4) {                       // dark red brick, 8×4 with offsets
        int row = t.y / 4;
        int bx = (t.x + (row & 1) * 4) & 7;
        bool mortar = (t.y % 4 == 0) || bx == 0;
        float tone = 0.8 + 0.4 * hash21(float2(float(row), float((t.x + (row & 1) * 4) / 8)) + salt * 2.3);
        return mortar ? float3(0.11, 0.06, 0.06) * (0.9 + 0.2 * n)
                      : float3(0.30, 0.12, 0.11) * tone * (0.88 + 0.2 * n);
    }
    // dark stone brick, two courses of 8
    int row = t.y / 8;
    int bx = (t.x + (row & 1) * 8) & 15;
    bool mortar = (t.y % 8 == 0) || bx == 0;
    float3 base = float3(0.19, 0.19, 0.21);
    if (mortar) return base * 0.55 * (0.9 + 0.15 * n);
    float edge = (t.y % 8 == 7) ? 1.12 : ((t.y % 8 == 1) ? 0.9 : 1.0);
    float crack = (n > 0.93) ? 0.75 : 1.0;
    return base * edge * crack * (0.86 + 0.26 * n);
}

static float3 pcDigitTex(int style, int2 t, float salt) {
    float n = pcN(t, salt);
    float bev = 1.0;
    if (t.x == 0 || t.y == 15) bev = 1.12;
    if (t.x == 15 || t.y == 0) bev = 0.82;
    bool inner = (t.x == 2 || t.x == 13 || t.y == 2 || t.y == 13) && t.x >= 2 && t.x <= 13 && t.y >= 2 && t.y <= 13;
    if (style == 2) {        // smooth sandstone on dark oak
        float3 b = float3(0.86, 0.76, 0.54);
        float band = (t.y <= 1) ? 0.84 : (t.y >= 14 ? 1.06 : 1.0);
        return b * band * bev * (0.95 + 0.08 * n);
    }
    if (style == 3) {        // gold on dark tile
        float3 b = float3(0.93, 0.72, 0.26);
        if ((t.x + t.y) % 7 == 0 && t.x > 2 && t.y > 2) b *= 1.18;
        return b * bev * (inner ? 0.88 : 1.0) * (0.94 + 0.08 * n);
    }
    if (style == 4) {        // pale birch planks on dark brick
        int plank = t.y / 4;
        float tone = 0.9 + 0.16 * hash21(float2(float(plank), salt));
        bool seam = (t.y % 4 == 0) || (t.x == ((plank * 5 + 3) & 15));
        return float3(0.86, 0.80, 0.64) * tone * (seam ? 0.78 : 1.0) * (0.95 + 0.07 * n);
    }
    // quartz-white on dark stone brick
    float3 b = float3(0.90, 0.88, 0.84);
    return b * bev * (inner ? 0.93 : 1.0) * (0.96 + 0.06 * n);
}

static float3 pcLampTex(int2 t, float b, float salt) {
    float n = pcN(t, salt);
    bool frame = t.x == 0 || t.x == 15 || t.y == 0 || t.y == 15;
    bool bar = (t.x == 5 || t.x == 10 || t.y == 5 || t.y == 10);
    float3 off = frame ? float3(0.22, 0.14, 0.09) : (bar ? float3(0.30, 0.19, 0.11) : float3(0.40, 0.27, 0.15));
    off *= 0.85 + 0.25 * n;
    float2 cc = abs(float2(t) - 7.5);
    float core = 1.0 - saturate(max(cc.x, cc.y) / 8.0);
    float3 on = frame ? float3(0.55, 0.30, 0.12)
                      : (bar ? float3(0.85, 0.52, 0.20) : float3(1.0, 0.80, 0.45) * (0.8 + 0.35 * core));
    on *= 0.88 + 0.2 * n;
    return mix(off, on, b);
}

static float3 pcTexel(int mat, int side, int2 t, float salt, float lampB,
                      int masonry, int biome) {
    t = t & 15;
    float n = pcN(t, salt);
    switch (mat) {
        case PC_WALL:   return pcMasonryTex(masonry, t, salt);
        case PC_DIGIT:  return pcDigitTex(masonry, t, salt);
        case PC_LAMP:
        case PC_COLON:  return pcLampTex(t, lampB, salt);
        case PC_LANTERN: {
            bool frame = t.x <= 1 || t.x >= 14 || t.y <= 1 || t.y >= 14;
            bool bar = t.x == 7 || t.x == 8;
            if (frame || (bar && side == 1)) return float3(0.16, 0.16, 0.18) * (0.8 + 0.4 * n);
            float2 cc = abs(float2(t) - 7.5);
            float core = 1.0 - saturate(length(cc) / 8.0);
            return float3(1.0, 0.74, 0.40) * (0.75 + 0.45 * core) * (0.9 + 0.15 * n);
        }
        case PC_TRIM: {
            // Smooth slab stone: a border and a quiet face.
            bool border = t.x == 0 || t.x == 15 || t.y == 0 || t.y == 15;
            float3 b = (masonry == 2) ? float3(0.50, 0.38, 0.24)
                     : (masonry == 3) ? float3(0.40, 0.41, 0.45)
                     : (masonry == 4) ? float3(0.46, 0.40, 0.36)
                                      : float3(0.46, 0.46, 0.48);
            return b * (border ? 0.82 : 1.0) * (0.95 + 0.08 * n);
        }
        case PC_PLINTH: {
            bool border = t.y == 0 || t.y == 15 || t.x == 0 || t.x == 15;
            bool mid = side == 1 && (t.y == 7 || t.y == 8);
            float3 b = float3(0.55, 0.55, 0.56);
            return b * (border ? 0.8 : (mid ? 0.88 : 1.0)) * (0.92 + 0.12 * n);
        }
        case PC_ROD: {
            float3 b = float3(0.58, 0.47, 0.30);
            return b * ((t.x % 4 == 0) ? 0.8 : 1.0) * (0.9 + 0.15 * n);
        }
        case PC_LOG: {
            if (side != 1) {
                float2 cc = abs(float2(t) - 7.5);
                float ring = max(cc.x, cc.y);
                bool bark = ring > 6.0;
                bool line = !bark && (int(ring) % 3 == 1);
                return bark ? float3(0.30, 0.22, 0.13) * (0.9 + 0.2 * n)
                            : float3(0.66, 0.52, 0.32) * (line ? 0.82 : 1.0) * (0.92 + 0.1 * n);
            }
            bool groove = hash21(float2(float(t.x), salt)) > 0.6;
            return float3(0.33, 0.25, 0.15) * (groove ? 0.7 : 1.0) * (0.85 + 0.25 * n);
        }
        case PC_LEAVES: {
            float3 b = biome == 2 ? float3(0.30, 0.42, 0.14) : float3(0.17, 0.38, 0.13);
            if (n < 0.2) return b * 0.45;
            return b * (0.75 + 0.45 * n);
        }
        case PC_PATH: {
            float3 b = float3(0.52, 0.47, 0.40);
            if (side == 1 && t.y >= 14) b = float3(0.55, 0.50, 0.42);
            return b * (0.78 + 0.4 * n * n);
        }
        default: break;
    }
    float3 dirt = float3(0.42, 0.29, 0.19) * (0.8 + 0.35 * n);
    if (n > 0.9) dirt *= 0.7;
    float3 top = biome == 1 ? float3(0.90, 0.93, 0.97) * (0.93 + 0.08 * n)
               : biome == 2 ? float3(0.62, 0.62, 0.30) * (0.82 + 0.3 * n)
                            : float3(0.33, 0.55, 0.22) * (0.8 + 0.35 * n);
    if (mat == PC_DIRT) return dirt;
    if (side == 0) return top;
    if (side == 2) return dirt;
    int fringe = 13 - int(pcN(int2(t.x, 99), salt) * 2.5);
    return t.y >= fringe ? top * 0.92 : dirt;
}

static inline float3 pcMean(int mat, float lampB, int masonry, int biome, int side) {
    switch (mat) {
        case PC_WALL:
            return masonry == 2 ? float3(0.22, 0.14, 0.08) : masonry == 3 ? float3(0.19, 0.20, 0.24)
                 : masonry == 4 ? float3(0.24, 0.10, 0.09) : float3(0.18, 0.18, 0.20);
        case PC_DIGIT:
            return masonry == 2 ? float3(0.85, 0.75, 0.53) : masonry == 3 ? float3(0.92, 0.71, 0.26)
                 : masonry == 4 ? float3(0.82, 0.77, 0.61) : float3(0.89, 0.87, 0.83);
        case PC_LAMP: case PC_COLON:
            return mix(float3(0.36, 0.24, 0.13), float3(0.92, 0.70, 0.38), lampB);
        case PC_TRIM:
            return masonry == 2 ? float3(0.49, 0.37, 0.23) : masonry == 3 ? float3(0.39, 0.40, 0.44)
                 : masonry == 4 ? float3(0.45, 0.39, 0.35) : float3(0.45, 0.45, 0.47);
        case PC_PLINTH: return float3(0.53, 0.53, 0.54);
        case PC_LANTERN: return float3(0.62, 0.46, 0.27);
        case PC_ROD:    return float3(0.55, 0.45, 0.29);
        case PC_LOG:    return side == 1 ? float3(0.31, 0.24, 0.14) : float3(0.55, 0.43, 0.27);
        case PC_LEAVES: return biome == 2 ? float3(0.29, 0.40, 0.14) : float3(0.16, 0.36, 0.12);
        case PC_PATH:   return float3(0.47, 0.43, 0.36);
        default: break;
    }
    float3 dirt = float3(0.42, 0.29, 0.19);
    float3 top = biome == 1 ? float3(0.88, 0.91, 0.95) : biome == 2 ? float3(0.60, 0.60, 0.29)
                            : float3(0.33, 0.55, 0.22);
    if (mat == PC_DIRT || side == 2) return dirt;
    return side == 0 ? top : mix(dirt, top, 0.2);
}

// ---------------------------------------------------------------------------
// Sky.

struct PcLight {
    float3 dir;       // toward the sun or moon
    float3 col;       // its light
    float3 amb;       // sky light
    float3 zenith, horizon;
    float  day;       // 0 night .. 1 day
    float  dusk;      // warm-horizon weight
    float  isSun;
};

static PcLight pcLight(float hour, float rise, float set) {
    PcLight L;
    float alt, phase;
    bool up = hour >= rise && hour <= set;
    if (up) {
        phase = (hour - rise) / (set - rise);
        alt = sin(PI * phase);
    } else {
        float night = 24.0 - (set - rise);
        phase = glmod(hour - set, 24.0) / night;
        alt = -sin(PI * phase);
    }
    float day = smoothstep(-0.12, 0.25, alt);
    float dusk = (1.0 - smoothstep(0.05, 0.4, abs(alt))) ;
    float a = PI * phase;
    // East (+x) to west across the clock's front, a little to its right.
    float3 d = normalize(float3(cos(a), 0.12 + 0.95 * sin(a), 0.62));
    float ca = cos(0.45), sa = sin(0.45);
    d.xz = float2(ca * d.x - sa * d.z, sa * d.x + ca * d.z);
    L.dir = d;
    L.isSun = up ? 1.0 : 0.0;
    float3 sunCol = mix(float3(1.0, 0.55, 0.28), float3(1.0, 0.94, 0.84), smoothstep(0.05, 0.45, alt));
    float3 moonCol = float3(0.42, 0.52, 0.78);
    L.col = up ? sunCol * (0.25 + 0.95 * smoothstep(0.0, 0.3, alt))
               : moonCol * smoothstep(0.0, 0.25, -alt);
    L.amb = mix(float3(0.05, 0.06, 0.10), float3(0.30, 0.37, 0.48), day);
    L.zenith  = mix(float3(0.006, 0.010, 0.030), float3(0.25, 0.45, 0.80), day);
    L.horizon = mix(float3(0.030, 0.040, 0.075), float3(0.62, 0.74, 0.88), day);
    L.horizon = mix(L.horizon, float3(0.85, 0.45, 0.25), dusk * 0.75);
    L.zenith  = mix(L.zenith, float3(0.20, 0.20, 0.38), dusk * 0.5);
    L.day = day;
    L.dusk = dusk;
    return L;
}

static float3 pcSkyBase(float3 rd, thread const PcLight& L) {
    float h = saturate(rd.y * 1.6 + 0.05);
    return mix(L.horizon, L.zenith, sqrt(h));
}

static float3 pcSky(float3 ro, float3 rd, thread const PcLight& L, float time, float px) {
    float3 col = pcSkyBase(rd, L);

    // Stars: square points on a slowly turning dome.
    if (L.day < 0.9 && rd.y > 0.0) {
        float3 r = rd;
        float a = time * 0.0015;
        r.xz = float2(cos(a) * r.x - sin(a) * r.z, sin(a) * r.x + cos(a) * r.z);
        float2 sp = r.xz / (r.y + 0.35) * 70.0;
        float2 ci = floor(sp);
        float hs = hash21(ci + 7.7);
        if (hs > 0.985) {
            float2 fo = sp - ci;
            float sz = 0.18 + 0.2 * hash21(ci + 1.3);
            float2 dd = abs(fo - 0.5);
            float w = 70.0 * px * 0.7 + 0.02;
            float m = 1.0 - smoothstep(sz - w, sz + w, max(dd.x, dd.y));
            col += m * (1.0 - L.day) * 0.7 * smoothstep(0.0, 0.25, rd.y) * float3(0.85, 0.9, 1.0);
        }
    }

    // The square sun or moon.
    float3 Ld = L.dir;
    float cd = dot(rd, Ld);
    if (cd > 0.0) {
        float3 t1 = normalize(cross(float3(0.0, 1.0, 0.0), Ld));
        float3 t2 = cross(Ld, t1);
        float2 q = float2(dot(rd, t1), dot(rd, t2)) / cd;
        float size = L.isSun > 0.5 ? 0.075 : 0.055;
        float e = max(abs(q.x), abs(q.y));
        float w = px * 1.2;
        float disc = 1.0 - smoothstep(size - w, size + w, e);
        if (L.isSun > 0.5) {
            col += disc * float3(1.6, 1.45, 1.1) * smoothstep(-0.05, 0.05, Ld.y);
            col += float3(1.0, 0.7, 0.4) * 0.25 * pow(saturate(cd), 40.0) * smoothstep(-0.05, 0.05, Ld.y);
        } else {
            int2 mt = int2(floor((q / size * 0.5 + 0.5) * 8.0));
            float crater = hash21(float2(mt) + 4.0) > 0.7 ? 0.78 : 1.0;
            col = mix(col, float3(0.86, 0.88, 0.95) * crater, disc * smoothstep(-0.05, 0.05, Ld.y));
            col += float3(0.25, 0.3, 0.45) * 0.12 * pow(saturate(cd), 30.0);
        }
    }

    // A deck of flat, square-edged clouds.
    if (rd.y > 0.02) {
        float tc = (34.0 - ro.y) / rd.y;
        float2 cp = ro.xz + rd.xz * tc + float2(time * 0.35, time * 0.08);
        float2 cell = floor(cp / 6.0);
        float cv = valueNoise(cell * 0.23 + 11.0) * 0.7 + hash21(cell) * 0.3;
        float cover = step(0.6, cv);
        float fade = 1.0 - smoothstep(90.0, 260.0, tc);
        float3 cc = mix(float3(0.10, 0.11, 0.16), float3(0.97, 0.97, 0.98), L.day);
        cc = mix(cc, float3(1.0, 0.72, 0.55), L.dusk * 0.5);
        col = mix(col, cc, cover * fade * 0.85);
    }
    return col;
}

// ---------------------------------------------------------------------------
// Light from the lamps.

static float pcRingParam(float2 q) {
    if (q.y >= 9.5 - 1e-3) return q.x >= 0.0 ? q.x : 60.0 + q.x;
    if (q.x >= 11.5 - 1e-3) return 21.0 - q.y;
    if (q.y <= 1.5 + 1e-3) return 31.0 - q.x;
    return 40.0 + q.y;
}

static float3 pcLampLight(float3 p, float3 n, float s) {
    const float2 lo = float2(-10.5, 1.5), hi = float2(11.5, 9.5);
    float2 q = clamp(p.xy, lo, hi);
    if (all(q == p.xy)) {
        float dl = p.x - lo.x, dr = hi.x - p.x, db = p.y - lo.y, dt = hi.y - p.y;
        float m = min(min(dl, dr), min(db, dt));
        if (m == dl) q.x = lo.x; else if (m == dr) q.x = hi.x; else if (m == db) q.y = lo.y; else q.y = hi.y;
    }
    float up = pcRingParam(q) - 0.5;
    float k0 = floor(up);
    float fr = up - k0;
    float b = mix(pcLampB(glmod(k0, 60.0), s), pcLampB(glmod(k0 + 1.0, 60.0), s), fr);
    float3 v = float3(q, 0.45) - p;
    float d2 = dot(v, v);
    float ndl = saturate((dot(n, v * rsqrt(d2)) + 0.35) / 1.35);
    float3 lampCol = float3(1.0, 0.62, 0.28);
    float3 res = lampCol * b * ndl * 2.2 / (1.0 + 1.1 * d2);

    // The lanterns.
    for (int i = 0; i < 2; ++i) {
        float3 lv = float3(i == 0 ? -12.5 : 13.5, 2.5, 1.5) - p;
        float l2 = dot(lv, lv);
        float ln = saturate((dot(n, lv * rsqrt(l2)) + 0.2) / 1.2);
        res += float3(1.0, 0.66, 0.34) * ln * 3.0 / (1.0 + 0.55 * l2);
    }

    // The colon.
    float cb = pcColonB(s);
    for (int i = 0; i < 2; ++i) {
        float3 cv = float3(0.5, i == 0 ? 4.5 : 6.5, 0.45) - p;
        float c2 = dot(cv, cv);
        float cn = saturate((dot(n, cv * rsqrt(c2)) + 0.35) / 1.35);
        res += lampCol * cb * cn * 0.9 / (1.0 + 1.6 * c2);
    }
    return res;
}

// ---------------------------------------------------------------------------

static inline float pcVertexAO(bool s1, bool s2, bool c) {
    return (s1 && s2) ? 0.0 : (3.0 - float(s1) - float(s2) - float(c)) / 3.0;
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpClock& clock [[buffer(1)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float minRes = min(u.resolution.x, u.resolution.y);
    float xExt = u.resolution.x / minRes;

    // --- The time.
    float daySec = glmod(clock.hourAtZero * 3600.0 + u.time, 86400.0);
    float hour = daySec / 3600.0;
    int minute = int(floor(daySec / 60.0));
    bool h24 = u.hour24 != 0;

    PcScene S;
    S.sec = daySec - 60.0 * float(minute);
    S.now = pcDigits(minute, h24);
    S.prev = pcDigits((minute + 1439) % 1440, h24);
    float sh = fract(u.seed * 7.31 + 0.13);
    S.salt = floor(u.seed * 977.0) * 0.731;
    S.biome = int(fract(u.seed * 3.71 + 0.4) * 3.0);
    if (S.biome == 2 && fract(u.seed * 13.3) < 0.5) S.biome = 0;   // meadow most often
    S.masonry = u.masonry > 0 ? u.masonry : 1 + int(sh * 4.0);

    PcLight L = pcLight(hour, clock.sunrise, clock.sunset);

    // --- The camera: a slow swing round the clock.
    float tc = u.time + u.seed * 1777.0;
    float yawA = 0.50 * sin(TWO_PI * tc / 310.0) + 0.10 * sin(TWO_PI * tc / 127.0 + 1.0);
    float pitA = 0.20 + 0.06 * sin(TWO_PI * tc / 230.0 + 2.0);
    float dist = max(21.0, 15.0 * PC_FOCAL / xExt);
    float3 pivot = float3(0.5, 5.2, 0.0);
    float3 ro = pivot + dist * float3(sin(yawA) * cos(pitA), sin(pitA), cos(yawA) * cos(pitA));
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 fwd = normalize(pivot - ro);
    float3 right = normalize(cross(fwd, upHint));
    lerpOrbit(u.yaw, u.pitch, u.magnify, pivot, upHint, ro, right, fwd);
    float3 up = cross(right, fwd);
    float3 rd = normalize(uv.x * right + uv.y * up + PC_FOCAL * fwd);
    float px = 2.0 / (PC_FOCAL * minRes);   // radians a pixel

    float time = u.time + u.seed * 500.0;
    float3 col;
    // One trace routine runs twice — the view ray, then (for a lit face) the
    // shadow ray toward the sun or moon — from a loop the compiler cannot
    // unroll, so its code exists once.
    PcHit h = pcMiss();
    float shadow = 0.0;
    {
        float3 o = ro, d = rd;
        float tm = pcRangeT(ro, rd, PC_RANGE + 2.0);
        int steps = PC_STEPS;
        int passes = 2 + int(u.seed > 4.0);
        for (int pass = 0; pass < passes; ++pass) {
            PcHit r = pcTrace(o, d, tm, steps, S);
            if (pass > 0) { shadow = r.mat == PC_AIR ? 1.0 : 0.0; break; }
            h = r;
            if (h.mat == PC_AIR) break;
            float3 hp = ro + rd * h.t;
            if (dot(h.n, L.dir) <= 0.0 || max(L.col.r, L.col.b) <= 0.005) break;
            if (smoothstep(24.0, PC_RANGE, length(hp.xz - float2(0.5, 0.0))) > 0.97) break;
            o = hp + h.n * 2e-3; d = L.dir; tm = 40.0; steps = PC_SHADOW_STEPS;
        }
    }

    float3 hitP = ro + rd * min(h.t, 1e4);
    float fogAt = smoothstep(24.0, PC_RANGE, length(hitP.xz - float2(0.5, 0.0)));
    if (h.mat == PC_AIR) {
        col = pcSky(ro, rd, L, time, px);
    } else if (fogAt > 0.985) {
        col = pcSkyBase(rd, L);     // all but lost in the fog: skip the shading
    } else {
        float3 p = hitP;
        float3 n = h.n;

        // Face coordinates: u across, v up (or along z on tops).
        float3 lp = p;
        if (h.mat == PC_DIGIT) lp.z -= h.f;
        float2 fuv;
        int side;
        if (abs(n.y) > 0.5) { fuv = float2(lp.x, lp.z * -n.y); side = n.y > 0.0 ? 0 : 2; }
        else if (abs(n.x) > 0.5) { fuv = float2(lp.z * n.x, lp.y); side = 1; }
        else { fuv = float2(-lp.x * n.z, lp.y); side = 1; }

        // Lamp state for this block.
        float lampB = 0.0;
        if (h.mat == PC_LAMP) lampB = pcLampB(float(pcRingIndex(h.cell.x, h.cell.y)), S.sec);
        else if (h.mat == PC_COLON) lampB = pcColonB(S.sec);

        float salt = hash21(float2(h.cell.xz) + float(h.cell.y) * 3.7 + float(h.mat));
        int texMat = h.mat;
        // Logs: rings on top/bottom.
        // Texel footprint, in texels.
        float ndv = max(abs(dot(n, rd)), 0.2);
        float w = 16.0 * h.t * px / ndv;
        float2 tcd = fuv * 16.0 - 0.5;
        float2 i0 = floor(tcd);
        float2 fr = tcd - i0;
        float2 a = saturate((fr - 0.5) / max(w, 1e-3) + 0.5);
        int2 ti = int2(i0);
        // Four taps through one copy of the texel code (the loop count is
        // opaque to the compiler, which keeps it from unrolling).
        float3 alb = float3(0.0);
        int taps = w >= 3.0 ? 0 : 4 + int(u.seed > 4.0);   // past 3 texels the mean stands alone
        for (int k = 0; k < taps; ++k) {
            int2 o = int2(k & 1, k >> 1);
            float2 wt = select(1.0 - a, a, bool2(o != 0));
            alb += wt.x * wt.y * pcTexel(texMat, side, ti + o, salt, lampB, S.masonry, S.biome);
        }
        alb = mix(alb, pcMean(texMat, lampB, S.masonry, S.biome, side), smoothstep(0.7, 3.0, w));

        // Corner shading.
        float ao = 1.0;
        float hole = 1.0;     // light that reaches into a piston's hole
        if (h.mat == PC_DIGIT || h.mat == PC_ROD) {
            float2 e = abs(fract(fuv) - 0.5);
            float edge = 0.5 - max(e.x, e.y);
            float depth = saturate(-p.z);
            hole = 1.0 - 0.88 * smoothstep(0.0, 0.9, depth);
            if (n.z > 0.5) ao = 1.0 - 0.5 * depth * (1.0 - smoothstep(0.0, 0.4, edge));
            else           ao = mix(0.6, 1.0, saturate((p.z + 0.05) * 1.6));
        } else if (n.y > 0.5 && h.cell.y == -1 && pcFlatAround(h.cell.xz)) {
            ao = 1.0;   // open ground with nothing standing within a block
        } else if (n.z > 0.5 && h.cell.z == -1 && abs(h.cell.x) <= 10 && h.cell.y >= 2 && h.cell.y <= 8) {
            ao = 1.0;   // the wall's face inside the lamp ring: only piston columns
                        // (counted open) stand in front of it
        } else {
            int3 ni = int3(n);
            int3 ac = h.cell + ni;
            int3 t1 = abs(ni.x) == 1 ? int3(0, 0, 1) : int3(1, 0, 0);
            int3 t2 = abs(ni.y) == 1 ? int3(0, 0, 1) : int3(0, 1, 0);
            PcNoiseCache nc; nc.cell = int2(-99999);
            PcTree T; T.patch = int2(-99999); T.has = false;
            // Neighbours in order: +t1, -t1, +t2, -t2, then the four corners.
            uint solid = 0u;
            int nAO = 8 + int(u.seed > 4.0);
            for (int k = 0; k < nAO; ++k) {
                int2 o = k < 4 ? (k < 2 ? int2(k == 0 ? 1 : -1, 0) : int2(0, k == 2 ? 1 : -1))
                               : int2((k & 1) ? -1 : 1, (k & 2) ? -1 : 1);
                if (pcSolidForAO(ac + t1 * o.x + t2 * o.y, S, nc, T)) solid |= 1u << k;
            }
            bool sA = solid & 1u, sB = solid & 2u, sC = solid & 4u, sD = solid & 8u;
            bool cAC = solid & 16u, cBC = solid & 32u, cAD = solid & 64u, cBD = solid & 128u;
            float3 fp = p - float3(h.cell);
            float g1 = dot(fp, float3(t1)), g2 = dot(fp, float3(t2));
            float v00 = pcVertexAO(sB, sD, cBD), v10 = pcVertexAO(sA, sD, cAD);
            float v01 = pcVertexAO(sB, sC, cBC), v11 = pcVertexAO(sA, sC, cAC);
            ao = mix(mix(v00, v10, g1), mix(v01, v11, g1), g2);
            ao = 0.45 + 0.55 * ao;
        }

        // Flat face shading, as block worlds do it.
        float faceShade = n.y > 0.5 ? 1.0 : (n.y < -0.5 ? 0.55 : (abs(n.x) > 0.5 ? 0.72 : 0.86));

        float ndl = saturate(dot(n, L.dir));
        float3 light = L.amb * ao * faceShade + L.col * ndl * shadow * mix(1.0, faceShade, 0.4);
        light += pcLampLight(p, n, S.sec) * mix(1.0, ao, 0.6);
        col = alb * light * hole;
        if (h.mat == PC_LANTERN) col = alb * (1.1 + 0.3 * light);
        if (h.mat == PC_LAMP || h.mat == PC_COLON) col += alb * lampB * 1.25;

        // Short view distance, measured from the clock.
        float fd = length(p.xz - float2(0.5, 0.0));
        float fog = smoothstep(24.0, PC_RANGE, fd);
        col = mix(col, pcSkyBase(rd, L), fog);
    }

    col = max(col, 0.0);
    col = col / (1.0 + 0.25 * max(col.r, max(col.g, col.b)));   // soft shoulder for the lit lamps
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
