// Piston Clock — a redstone piston display built in Minecraft, telling the
// Mac's time. Every pixel of the digits is a block on a sticky piston, the
// seconds are a square of redstone lamps, fifteen to a side, and the whole
// machine stands on a smooth-stone plinth in an ordinary overworld field.
//
// lerp-category: Minecraft
// lerp-requires: minecraft
// lerp-data: clock
//
// - Drawn with the game's own textures (bound at runtime from the copy
//   installed on this Mac; see PORTING.md, "Minecraft looks"): pistons
//   (side, inner face, the extended head and arm), redstone lamps lit and
//   unlit, redstone dust, the masonry, lanterns, grass, logs and leaves, the
//   sun, the moon's phases and the cloud layer.
// - The time is real (`lerp-data: clock`): hours over minutes in pistoned
//   blocks, 3×5 a digit (in 12-hour time the leading digit can only be a
//   1, so it is built as a single column, as a player would build it). When
//   the minute turns, a signal runs along the dust on the plinth and the
//   blocks that change slide out or back behind it, a column every redstone
//   tick or so, the lower rows first. Blocks that are off sit two deep in
//   the wall, where less light reaches them.
// - The face is square, and its frame keeps the seconds: fifteen lamps a
//   side between four corner blocks, one lit each second, clockwise from
//   the top left. A side fills every quarter minute (top by :15, right by
//   :30, bottom by :45, left by :60) and the square goes dark in a sweep as
//   the minute turns. The colon, on its side between hours and minutes,
//   blinks.
// - Lit the way the game lights: fixed face shading, smooth-lighting corner
//   occlusion, sky light and block light (lamps and lanterns, level 15,
//   falling one a block), the game's lightmap colours, sky and fog colours,
//   sunrise glow, square sun and moon crossing east to west on the hour.
//   Stills (gallery, snapshots) are midnight, 12:00.
// - Seed picks the masonry (blackstone and quartz, dark oak and sandstone,
//   deepslate and gold, nether brick and birch), the biome (plains, snowy plains
//   with spruce, savanna with acacia), hills, trees, the moon's phase and
//   where the camera's slow swing starts. Drag to turn, pinch to zoom.
// - GPU cost: the clock is walked cell by cell only inside its own box; the
//   ground in 8×8 patches, crossed whole where the ray is above their hills
//   and tree, column by column only where it is not. No shadow rays (the
//   game casts none). Texture reads happen once, at the hit.
//
// lerp-param: clock    float -1 24   = -1    "Hour (-1 = now)"
// lerp-param: hour24   bool          = false "24-hour"
// lerp-param: masonry  int 0 4       = 0     "Masonry (0 = new each time)"
// lerp-param: yaw      float -180 180 = 0    "Turn"
// lerp-param: pitch    float -12 40  = 0     "Tilt"
// lerp-param: magnify  float -1 0.8  = 0     "Zoom"
//
// lerp-preset: "Dark Oak and Sandstone" masonry=2
// lerp-preset: "Deepslate and Gold" masonry=3

constant int   PC_STEPS        = 96;    // ground columns a view ray may cross
constant float PC_FOCAL        = 1.9;
constant float PC_TOP          = 19.0;   // nothing solid at or above this y
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
constant int PC_LANTERN = 14; // the two lanterns on the plinth corners (a model)
constant int PC_PISTON = 15;  // a sticky piston's base, behind each display pixel
constant int PC_HEAD   = 16;  // an extended piston's head

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
    bool  h24;        // 24-hour: the leading digit is a full 3×5 digit
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

// Which digit a display cell belongs to (-1 if none), and its column and row
// (0 at the top) in it. Hours (digits 0 and 1) are rows 11..15, minutes
// (2 and 3) rows 3..7; both pairs stand in columns -3..-1 and 1..3.
static inline int pcDigitAt(int x, int y, thread int& cx, thread int& r) {
    int q = x + 3;
    if (q < 0 || q > 6 || q == 3) return -1;
    bool hours = y >= 11;
    r = (hours ? 15 : 7) - y;
    if (r < 0 || r > 4) return -1;
    cx = q & 3;
    return (hours ? 0 : 2) + q / 4;
}

// Face position of the pushed block in display column (x, y): +1 out, -2 in.
// Returns -9 when (x, y) is not a display cell.
static inline float pcCellF(int x, int y, thread const PcScene& S) {
    int cx, r;
    int k = pcDigitAt(x, y, cx, r);
    if (k < 0) return -9.0;
    if (k == 0 && !S.h24 && cx != 2) return -9.0;   // 12-hour: the leading 1 is one column
    int b = r * 3 + cx;
    uint mp = k == 0 ? S.prev.x : (k == 1 ? S.prev.y : (k == 2 ? S.prev.z : S.prev.w));
    uint mn = k == 0 ? S.now.x  : (k == 1 ? S.now.y  : (k == 2 ? S.now.z  : S.now.w));
    float a = ((mp >> b) & 1u) ? 1.0 : -2.0;
    float c = ((mn >> b) & 1u) ? 1.0 : -2.0;
    if (a == c) return c;
    // Behind the signal on the dust below (0 at its left end), and up the wall.
    float d = 0.075 * float(x + 8) + 0.05 * float(y - 3);
    float p = smoothstep(d, d + 0.85, S.sec);
    return mix(a, c, p);
}

// Seconds lamp k (0 at the left end of the top side, clockwise, fifteen a
// side): on from second k, switched off in a sweep (a tick or so a lamp) as
// the minute turns. Lamps switch, they do not fade.
static inline bool pcLampOn(int k, float s) {
    return s >= float(k) || s < 0.05 + 0.013 * float(k);
}

// The square is cells -8..8 by 1..17; its four corner cells are not lamps.
static inline int pcRingIndex(int x, int y) {
    if (y == 17) return x + 7;                  // top, left to right
    if (x == 8)  return 15 + (16 - y);          // right, downward
    if (y == 1)  return 30 + (7 - x);           // bottom, right to left
    return 45 + (y - 2);                        // left (x == -8), upward
}

// The lamp cell holding ring index k.
static inline int2 pcRingCell(int k) {
    if (k < 15) return int2(k - 7, 17);
    if (k < 30) return int2(8, 16 - (k - 15));
    if (k < 45) return int2(7 - (k - 30), 1);
    return int2(-8, 2 + (k - 45));
}

// The colon, on its side: two lamps on for a second, off for a second.
static inline bool pcColonOn(float s) { return glmod(s, 2.0) < 1.0; }

// ---------------------------------------------------------------------------
// The world: the clock (a known box, walked cell by cell only inside it) on
// ground that is a heightfield with trees (walked column by column).

constant float3 PC_CLO = float3(-10.0, 0.0, -8.0);   // the clock's cell bounds
constant float3 PC_CHI = float3( 11.0, 19.0, 2.0);   // nothing solid at y >= 19

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
    if ((c.x == -10 || c.x == 10) && c.z == 1 && c.y <= 2)
        return c.y == 1 ? PC_TRIM : PC_LANTERN;
    int ax = c.x;
    bool pillar = (ax == -9 || ax == 9) && c.z >= -7 && c.z <= 0 && c.y <= 18;
    if (pillar) return PC_TRIM;
    if (c.y == 18 && ax >= -8 && ax <= 8 && c.z >= -7 && c.z <= -1) return PC_TRIM;
    if (ax >= -8 && ax <= 8 && c.y >= 1 && c.y <= 17 && c.z >= -6 && c.z <= 0) {
        bool disp = pcCellF(ax, c.y, S) > -5.0;
        if (disp && c.z >= -3) return PC_DISP;
        if (disp && c.z == -4) return PC_PISTON;
        if (c.z == 0) return PC_AIR;
        if (c.z == -1) {
            bool edgeX = ax == -8 || ax == 8, edgeY = c.y == 1 || c.y == 17;
            if (edgeX && edgeY) return PC_TRIM;      // a corner block
            if (edgeX || edgeY) return PC_LAMP;
            if ((ax == -1 || ax == 1) && c.y == 9) return PC_COLON;
        }
        return PC_WALL;
    }
    return PC_AIR;
}

static inline bool pcInClockBox(int3 c) {
    return c.x >= -10 && c.x <= 10 && c.y >= 0 && c.y <= 18 && c.z >= -8 && c.z <= 1;
}

// True when every column within one of c is flat ground at height 0 with no
// clock and no tree crown over it: hills need amp*14 >= 1, and crowns come
// only from trees rooted 17+ from the clock and, in front, 44+.
static inline bool pcFlatAround(int2 c) {
    if (c.x >= -11 && c.x <= 11 && c.y >= -9 && c.y <= 2) return false;
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
    if (pcInClockBox(c)) { int m = pcClockBlock(c, S); return m != PC_AIR && m != PC_DISP && m != PC_LANTERN; }
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
    float  f;      // the pushed block's face position, for PC_DIGIT / PC_HEAD / PC_ROD
    float4 mcol;   // lantern: the shared model's texel and
    float  mshade; // whether the game face-shades it
};

static inline PcHit pcMiss() {
    PcHit h;
    h.t = 1e9; h.mat = PC_AIR; h.n = float3(0.0, 1.0, 0.0); h.cell = int3(0); h.f = 0.0; h.mcol = float4(0.0); h.mshade = 1.0;
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
static PcHit pcClockTrace(float3 ro, float3 rd, float3 inv, float tMax, thread const PcScene& S,
                          texture2d_array<float> mcTiles, int lanternLayer, float pxA) {
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
            // The pushed block, the piston head behind it and the arm.
            float f = pcCellF(cell.x, cell.y, S);
            float3 c0 = float3(cell);
            float best = tExit + 1e-4; float tb; float3 nb; int hm = PC_AIR;
            if (pcBox(ro, inv, float3(c0.xy, f - 1.0), float3(c0.xy + 1.0, f), tb, nb) && tb <= best) {
                best = tb; h.n = nb; hm = PC_DIGIT;
            }
            if (f > -1.75) {
                if (pcBox(ro, inv, float3(c0.xy, f - 1.25), float3(c0.xy + 1.0, f - 1.0), tb, nb) && tb <= best) {
                    best = tb; h.n = nb; hm = PC_HEAD;
                }
                if (pcBox(ro, inv, float3(c0.xy + 0.375, -3.0), float3(c0.xy + 0.625, f - 1.25), tb, nb) && tb <= best) {
                    best = tb; h.n = nb; hm = PC_ROD;
                }
            }
            if (hm != PC_AIR) { h.t = best; h.cell = cell; h.mat = hm; h.f = f; return h; }
        } else if (m == PC_LANTERN) {
            // The game's standing lantern, from the shared model kit.
            McModelHit mh;
            if (mcLantern(mcTiles, lanternLayer, float3(cell), false, ro, rd, tCur - 1e-3, tExit + 1e-4, pxA, mh)) {
                h.t = mh.t; h.n = mh.n; h.cell = cell; h.mat = PC_LANTERN;
                h.mcol = mh.color; h.mshade = mh.shade; return h;
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

static PcHit pcTrace(float3 ro, float3 rd, float tMax, int steps, thread const PcScene& S,
                     texture2d_array<float> mcTiles, int lanternLayer, float pxA) {
    float3 sd = select(rd, float3(1e-6), abs(rd) < 1e-6);
    float3 inv = 1.0 / sd;
    PcHit hc = pcClockTrace(ro, sd, inv, tMax, S, mcTiles, lanternLayer, pxA);
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
// The game's blocks.

struct PcStyle { int wall, digitSide, digitTop, trimSide, trimTop; };

static PcStyle pcStyle(int m) {
    PcStyle st;
    if (m == 2) {          // dark oak planks, sandstone pixels, stripped dark oak trim
        st.wall = MC_DARK_OAK_PLANKS; st.digitSide = MC_SANDSTONE; st.digitTop = MC_SANDSTONE_TOP;
        st.trimSide = MC_STRIPPED_DARK_OAK_LOG; st.trimTop = MC_STRIPPED_DARK_OAK_LOG_TOP;
    } else if (m == 3) {   // deepslate tiles, gold pixels, polished deepslate trim
        st.wall = MC_DEEPSLATE_TILES; st.digitSide = MC_GOLD_BLOCK; st.digitTop = MC_GOLD_BLOCK;
        st.trimSide = MC_POLISHED_DEEPSLATE; st.trimTop = MC_POLISHED_DEEPSLATE;
    } else if (m == 4) {   // nether bricks, birch plank pixels, stone brick trim
        st.wall = MC_NETHER_BRICKS; st.digitSide = MC_BIRCH_PLANKS; st.digitTop = MC_BIRCH_PLANKS;
        st.trimSide = MC_STONE_BRICKS; st.trimTop = MC_STONE_BRICKS;
    } else {               // polished blackstone bricks, quartz pixels, stone brick trim
        st.wall = MC_POLISHED_BLACKSTONE_BRICKS; st.digitSide = MC_QUARTZ_BLOCK_SIDE; st.digitTop = MC_QUARTZ_BLOCK_TOP;
        st.trimSide = MC_STONE_BRICKS; st.trimTop = MC_STONE_BRICKS;
    }
    return st;
}

// Texture axes of a face: u to the right as you face it, v downward (the
// picture's rows), so side faces stand upright and tops have north up.
static inline void pcFaceAxes(float3 n, thread float3& U, thread float3& V) {
    if (n.y > 0.5)       { U = float3(1, 0, 0);  V = float3(0, 0, 1); }
    else if (n.y < -0.5) { U = float3(1, 0, 0);  V = float3(0, 0, -1); }
    else if (n.z > 0.5)  { U = float3(1, 0, 0);  V = float3(0, -1, 0); }
    else if (n.z < -0.5) { U = float3(-1, 0, 0); V = float3(0, -1, 0); }
    else if (n.x > 0.5)  { U = float3(0, 0, -1); V = float3(0, -1, 0); }
    else                 { U = float3(0, 0, 1);  V = float3(0, -1, 0); }
}

// Redstone dust's colour at power 0..15, as the game computes it (sRGB).
static inline float3 pcDustColour(float power) {
    float f = power / 15.0;
    float3 c = float3(f * 0.6 + (f > 0.0 ? 0.4 : 0.3),
                      saturate(f * f * 0.7 - 0.5),
                      saturate(f * f * 0.6 - 0.7));
    return mcFromSRGB(c);
}

// Power on the dust line along the plinth's front at column x: the signal
// that runs out at the turn of the minute, ahead of the pistons.
static inline float pcDustPower(int x, float s) {
    float t0 = 0.075 * float(x + 8) - 0.1;
    return (s >= t0 && s < t0 + 1.2) ? 15.0 : 0.0;
}

// ---------------------------------------------------------------------------
// Light, as the game does it: sky light and block light levels 0..15.

static inline float pcL1(float3 a, float3 b) { float3 d = abs(a - b); return d.x + d.y + d.z; }

// Block light at the air cell in front of a face, from lit lamps and the
// lanterns: 15 at a source, one level less per block.
static float pcBlockLevel(float3 sp, float s) {
    float lvl = 0.0;
    lvl = max(lvl, 15.0 - pcL1(sp, float3(-9.5, 2.25, 1.5)));
    lvl = max(lvl, 15.0 - pcL1(sp, float3(10.5, 2.25, 1.5)));
    if (pcColonOn(s)) {
        lvl = max(lvl, 15.0 - pcL1(sp, float3(-0.5, 9.5, -0.5)));
        lvl = max(lvl, 15.0 - pcL1(sp, float3( 1.5, 9.5, -0.5)));
    }
    // The ring: its nearest lamp, and the ends of the run that is lit.
    int2 q = int2(clamp(floor(sp.xy), float2(-8.0, 1.0), float2(8.0, 17.0)));
    if (q.x > -8 && q.x < 8 && q.y > 1 && q.y < 17) {
        int dl = q.x + 8, dr = 8 - q.x, db = q.y - 1, dt = 17 - q.y;
        int m = min(min(dl, dr), min(db, dt));
        if (m == dl) q.x = -8; else if (m == dr) q.x = 8; else if (m == db) q.y = 1; else q.y = 17;
    } else if (abs(q.x) == 8 && (q.y == 1 || q.y == 17)) {
        // A corner block is no lamp: the neighbour that lights first.
        if (q.x == 8 && q.y == 1) q.y = 2; else q.x = q.x < 0 ? -7 : 7;
    }
    int kn = pcRingIndex(q.x, q.y);
    int kl = int(floor(s));
    int kc[3] = { kn, 0, min(kl, 59) };
    for (int i = 0; i < 3; ++i) {
        if (!pcLampOn(kc[i], s)) continue;
        int2 c = pcRingCell(kc[i]);
        lvl = max(lvl, 15.0 - pcL1(sp, float3(float(c.x) + 0.5, float(c.y) + 0.5, -0.5)));
    }
    return clamp(lvl, 0.0, 15.0);
}

// ---------------------------------------------------------------------------
// Sky.

struct PcSky {
    float3 sun;       // toward the sun (east +x to west -x, through the zenith)
    float  alt;       // its elevation, sine
    float  dayF;      // the game's sky brightness, 0..1
    float3 sky, fog;
    float  fan;       // sunrise / sunset glow strength
    float3 fanCol;
};

static PcSky pcSkyState(float hour, float rise, float set) {
    PcSky K;
    float a;
    if (hour >= rise && hour <= set) {
        a = PI * (hour - rise) / (set - rise);
    } else {
        float night = 24.0 - (set - rise);
        a = PI + PI * glmod(hour - set, 24.0) / night;
    }
    K.sun = float3(cos(a), sin(a), 0.0);
    K.alt = K.sun.y;
    K.dayF = saturate(K.alt * 2.0 + 0.5);
    K.sky = mcSkyAt(K.dayF);
    K.fog = mcFogAt(K.dayF);
    K.fan = 0.0; K.fanCol = float3(0.0);
    if (abs(K.alt) <= 0.4) {
        float g = K.alt / 0.4 * 0.5 + 0.5;
        float al = 1.0 - (1.0 - sin(g * PI)) * 0.99;
        K.fan = al * al;
        K.fanCol = mcFromSRGB(float3(g * 0.3 + 0.7, g * g * 0.7 + 0.2, 0.2));
    }
    return K;
}

// The sunrise glow leaning over the horizon on the sun's side.
static inline float pcFanWeight(float3 rd, thread const PcSky& K) {
    if (K.fan <= 0.0) return 0.0;
    float side = K.sun.x >= 0.0 ? 1.0 : -1.0;
    float2 h = normalize(rd.xz + float2(1e-5, 0.0));
    float toward = saturate(h.x * side);
    return K.fan * toward * toward * (1.0 - smoothstep(-0.05, 0.5, rd.y));
}

static float3 pcSky(float3 ro, float3 rd, thread const PcSky& K, float time, float px, int moonPhase,
                    texture2d_array<float> mcSkins, texture2d_array<float> mcMaps) {
    float3 col = mix(K.fog, K.sky, smoothstep(0.0, 0.3, rd.y));
    col = mix(col, K.fanCol, pcFanWeight(rd, K));

    // Stars: small squares on a turning dome, brighter as the night deepens.
    float starB = saturate(0.25 - K.alt * 2.0) * 0.5;
    if (starB > 0.0 && rd.y > 0.0) {
        float3 r = rd;
        float a = time * 0.0015;
        r.xz = float2(cos(a) * r.x - sin(a) * r.z, sin(a) * r.x + cos(a) * r.z);
        float2 sp = r.xz / (r.y + 0.35) * 70.0;
        float2 ci = floor(sp);
        if (hash21(ci + 7.7) > 0.985) {
            float2 dd = abs(sp - ci - 0.5);
            float sz = 0.15 + 0.15 * hash21(ci + 1.3);
            float w = 70.0 * px * 0.7 + 0.02;
            float m = 1.0 - smoothstep(sz - w, sz + w, max(dd.x, dd.y));
            col += m * starB * smoothstep(0.0, 0.2, rd.y);
        }
    }

    // Sun and moon: the game's square textures, added to the sky.
    float3 axisZ = float3(0.0, 0.0, 1.0);
    for (int i = 0; i < 2; ++i) {
        float3 d = i == 0 ? K.sun : -K.sun;
        float cd = dot(rd, d);
        if (cd <= 0.0) continue;
        float3 t2 = cross(d, axisZ);
        float2 q = float2(dot(rd, axisZ), dot(rd, t2)) / cd;
        float half_ = i == 0 ? 0.15 : 0.10;
        if (max(abs(q.x), abs(q.y)) >= half_) continue;
        float2 pix = (q / (2.0 * half_) + 0.5) * 32.0;
        int layer = i == 0 ? MCS_ENVIRONMENT_CELESTIAL_SUN : moonPhase;
        float w = px / (2.0 * half_) * 32.0;
        float4 c = mcSkin(mcSkins, layer, pix, w);
        col += c.rgb * c.a * smoothstep(-0.03, 0.03, rd.y);
    }

    // The cloud layer: clouds.png, a texel to 12 blocks, drifting east.
    if (rd.y > 0.01) {
        float tc = (120.0 - ro.y) / rd.y;
        float2 cp = ro.xz + rd.xz * tc - float2(time * 0.6, 0.0);
        float2 pix = glmod2(cp / 12.0, 256.0);
        float w = tc * px / 12.0 / max(rd.y, 0.15);
        float4 c = mcMap(mcMaps, MCM_ENVIRONMENT_CLOUDS, pix, w);
        float3 cc = mix(float3(0.08, 0.08, 0.11), float3(1.0), K.dayF);
        cc = mix(cc, K.fanCol, 0.4 * K.fan);
        float fade = 1.0 - smoothstep(300.0, 900.0, tc);
        col = mix(col, cc, 0.8 * c.a * fade);
    }
    return col;
}

static inline float pcVertexAO(bool s1, bool s2, bool c) {
    // The game's smooth lighting: each solid neighbour counts 0.2 of open air.
    bool cc = c || (s1 && s2);
    return (1.0 + (s1 ? 0.2 : 1.0) + (s2 ? 0.2 : 1.0) + (cc ? 0.2 : 1.0)) * 0.25;
}

// ---------------------------------------------------------------------------

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpClock& clock [[buffer(1)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float minRes = min(u.resolution.x, u.resolution.y);

    // --- The time.
    float daySec = glmod(clock.hourAtZero * 3600.0 + u.time, 86400.0);
    float hour = daySec / 3600.0;
    int minute = int(floor(daySec / 60.0));
    bool h24 = u.hour24 != 0;

    PcScene S;
    S.sec = daySec - 60.0 * float(minute);
    S.h24 = h24;
    S.now = pcDigits(minute, h24);
    S.prev = pcDigits((minute + 1439) % 1440, h24);
    float sh = fract(u.seed * 7.31 + 0.13);
    S.salt = floor(u.seed * 977.0) * 0.731;
    S.biome = int(fract(u.seed * 3.71 + 0.4) * 3.0);
    if (S.biome == 2 && fract(u.seed * 13.3) < 0.5) S.biome = 0;   // plains most often
    S.masonry = u.masonry > 0 ? u.masonry : 1 + int(sh * 4.0);
    PcStyle st = pcStyle(S.masonry);
    int moonPhase = MCS_ENVIRONMENT_CELESTIAL_MOON_FULL_MOON;
    {
        int ph = int(fract(u.seed * 5.17 + 0.3) * 8.0);
        if (ph == 1) moonPhase = MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_GIBBOUS;
        else if (ph == 2) moonPhase = MCS_ENVIRONMENT_CELESTIAL_MOON_THIRD_QUARTER;
        else if (ph == 3) moonPhase = MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_CRESCENT;
        else if (ph == 4) moonPhase = MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_CRESCENT;
        else if (ph == 5) moonPhase = MCS_ENVIRONMENT_CELESTIAL_MOON_FIRST_QUARTER;
        else if (ph == 6) moonPhase = MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_GIBBOUS;
    }

    PcSky K = pcSkyState(hour, clock.sunrise, clock.sunset);

    // --- The camera: a slow swing round the clock.
    float tc = u.time + u.seed * 1777.0;
    float yawA = 0.50 * sin(TWO_PI * tc / 310.0) + 0.10 * sin(TWO_PI * tc / 127.0 + 1.0);
    float pitA = 0.20 + 0.06 * sin(TWO_PI * tc / 230.0 + 2.0);
    float dist = 26.0;
    float3 pivot = float3(0.5, 9.3, 0.0);
    float3 ro = pivot + dist * float3(sin(yawA) * cos(pitA), sin(pitA), cos(yawA) * cos(pitA));
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 fwd = normalize(pivot - ro);
    float3 right = normalize(cross(fwd, upHint));
    lerpOrbit(u.yaw, u.pitch, u.magnify, pivot, upHint, ro, right, fwd);
    float3 up = cross(right, fwd);
    float3 dU = uv.x * right + uv.y * up + PC_FOCAL * fwd;    // unnormalised ray
    float3 rd = normalize(dU);
    float px = 2.0 / (PC_FOCAL * minRes);   // radians a pixel

    float time = u.time + u.seed * 500.0;
    float3 col;
    int lanternLayer = mcFrame(MC_LANTERN, MC_LANTERN_FRAMES, MC_LANTERN_TICKS, u.time);
    PcHit h = pcTrace(ro, rd, pcRangeT(ro, rd, PC_RANGE + 2.0), PC_STEPS, S, mcTiles, lanternLayer, px);

    float3 hitP = ro + rd * min(h.t, 1e4);
    float fogAt = smoothstep(24.0, PC_RANGE, length(hitP.xz - float2(0.5, 0.0)));
    float3 fogCol = mix(K.fog, K.fanCol, pcFanWeight(rd, K));
    if (h.mat == PC_AIR) {
        col = pcSky(ro, rd, K, time, px, moonPhase, mcSkins, mcMaps);
    } else if (fogAt > 0.985) {
        col = fogCol;     // all but lost in the fog: skip the shading
    } else {
        float3 p = hitP;
        float3 n = h.n;

        // Ray differentials: how far the hit moves across one screen pixel.
        float dn = dot(dU, n);
        float tP = dot(p - ro, n) / dn;
        float3 ddx = right * (2.0 / minRes), ddy = up * (2.0 / minRes);
        float3 dpdx = tP * (ddx - dU * (dot(ddx, n) / dn));
        float3 dpdy = tP * (ddy - dU * (dot(ddy, n) / dn));

        float3 U, V;
        pcFaceAxes(n, U, V);
        float3 lp = p;
        if (h.mat == PC_DIGIT) lp.z -= h.f;            // the block's own frame
        float2 fuv = float2(dot(lp, U), dot(lp, V));
        float2 gx = float2(dot(dpdx, U), dot(dpdx, V)), gy = float2(dot(dpdy, U), dot(dpdy, V));
        float foot = max(length(dpdx), length(dpdy));
        bool top = n.y > 0.5, bottom = n.y < -0.5;

        float3 alb;
        int layer = MC_STONE;
        float3 tint = float3(1.0);
        bool special = false;
        float3 grassTint = mcGrassTint(mcMaps, S.biome == 2 ? 1.0 : (S.biome == 1 ? 0.0 : 0.8),
                                       S.biome == 2 ? 0.0 : (S.biome == 1 ? 0.5 : 0.4));
        switch (h.mat) {
            case PC_WALL:   layer = st.wall; break;
            case PC_DIGIT:  layer = (top || bottom) ? st.digitTop : st.digitSide; break;
            case PC_TRIM:   layer = (top || bottom) ? st.trimTop : st.trimSide; break;
            case PC_PLINTH: layer = MC_SMOOTH_STONE; break;
            case PC_LAMP:
                layer = pcLampOn(pcRingIndex(h.cell.x, h.cell.y), S.sec) ? MC_REDSTONE_LAMP_ON : MC_REDSTONE_LAMP; break;
            case PC_COLON:
                layer = pcColonOn(S.sec) ? MC_REDSTONE_LAMP_ON : MC_REDSTONE_LAMP; break;
            case PC_PISTON: layer = n.z > 0.5 ? MC_PISTON_INNER : MC_PISTON_SIDE; break;
            case PC_HEAD: {
                // The head: piston_top on its faces, piston_side's rim on its edges.
                if (abs(n.z) > 0.5) { layer = MC_PISTON_TOP; break; }
                float along = abs(n.x) > 0.5 ? -p.y : p.x;
                fuv = float2(along, (h.f - 1.0) - p.z);
                float2 ax = abs(n.x) > 0.5 ? float2(-dpdx.y, -dpdx.z) : float2(dpdx.x, -dpdx.z);
                float2 ay = abs(n.x) > 0.5 ? float2(-dpdy.y, -dpdy.z) : float2(dpdy.x, -dpdy.z);
                gx = ax; gy = ay;
                layer = MC_PISTON_SIDE; break;
            }
            case PC_ROD: {
                // The arm: piston_side's top four rows run along its length.
                float across = abs(n.x) > 0.5 ? fract(p.y) - 0.375 : fract(p.x) - 0.375;
                fuv = float2(p.z, across);
                float2 ax = float2(dpdx.z, abs(n.x) > 0.5 ? dpdx.y : dpdx.x);
                float2 ay = float2(dpdy.z, abs(n.x) > 0.5 ? dpdy.y : dpdy.x);
                gx = ax; gy = ay;
                layer = MC_PISTON_SIDE; break;
            }
            case PC_LANTERN: special = true; alb = h.mcol.rgb; break;   // textured by the kit
            case PC_PATH:   layer = top ? MC_DIRT_PATH_TOP : (bottom ? MC_DIRT : MC_DIRT_PATH_SIDE); break;
            case PC_DIRT:   layer = MC_DIRT; break;
            case PC_LOG: {
                bool end = top || bottom;
                layer = S.biome == 1 ? (end ? MC_SPRUCE_LOG_TOP : MC_SPRUCE_LOG)
                      : S.biome == 2 ? (end ? MC_ACACIA_LOG_TOP : MC_ACACIA_LOG)
                                     : (end ? MC_OAK_LOG_TOP : MC_OAK_LOG);
                break;
            }
            case PC_LEAVES: {
                layer = S.biome == 1 ? MC_SPRUCE_LEAVES : (S.biome == 2 ? MC_ACACIA_LEAVES : MC_OAK_LEAVES);
                tint = S.biome == 1 ? mcFromSRGB(float3(0x61, 0x99, 0x61) / 255.0)
                     : mcFoliageTint(mcMaps, S.biome == 2 ? 1.0 : 0.8, S.biome == 2 ? 0.0 : 0.4);
                break;
            }
            default: {   // grass block (snowy in snowy plains)
                special = true;
                if (bottom) alb = mcTileAniso(mcTiles, MC_DIRT, fuv, gx, gy).rgb;
                else if (S.biome == 1) alb = mcTileAniso(mcTiles, top ? MC_SNOW : MC_GRASS_BLOCK_SNOW, fuv, gx, gy).rgb;
                else if (top) alb = mcTileAniso(mcTiles, MC_GRASS_BLOCK_TOP, fuv, gx, gy).rgb * grassTint;
                else alb = mcGrassSide(mcTiles, fuv, foot, grassTint);
                break;
            }
        }
        if (!special) {
            float4 tx = mcTileAniso(mcTiles, layer, fuv, gx, gy);
            // Leaves as the game's "fast" setting draws them: opaque.
            alb = (h.mat == PC_LEAVES) ? mix(float3(0.06, 0.09, 0.04), tx.rgb, tx.a) * tint : tx.rgb * tint;
        }

        // Redstone dust along the front of the plinth.
        if (h.mat == PC_PLINTH && top && h.cell.z == 1 && h.cell.x >= -8 && h.cell.x <= 8) {
            float4 d = mcTileAniso(mcTiles, MC_REDSTONE_DUST_LINE0, float2(fuv.y, fuv.x), float2(gx.y, gx.x), float2(gy.y, gy.x));
            alb = mix(alb, d.rgb * pcDustColour(pcDustPower(h.cell.x, S.sec)), d.a);
        }

        // Smooth lighting: corner occlusion from the cells beside the face.
        float ao = 1.0;
        bool open = (n.y > 0.5 && h.cell.y == -1 && pcFlatAround(h.cell.xz))
                 || (n.z > 0.5 && h.mat == PC_WALL && abs(h.cell.x) <= 7 && h.cell.y >= 2 && h.cell.y <= 16);
        if (!open && h.mat != PC_LANTERN && h.mat != PC_ROD && h.mat != PC_HEAD) {
            int3 ni = int3(n);
            int3 ac = int3(floor(p + n * 0.5));
            int3 t1 = abs(ni.x) == 1 ? int3(0, 0, 1) : int3(1, 0, 0);
            int3 t2 = abs(ni.y) == 1 ? int3(0, 0, 1) : int3(0, 1, 0);
            PcNoiseCache nc; nc.cell = int2(-99999);
            PcTree T; T.patch = int2(-99999); T.has = false;
            uint solid = 0u;
            int nAO = 8 + int(u.seed > 4.0);
            for (int k = 0; k < nAO; ++k) {
                int2 o = k < 4 ? (k < 2 ? int2(k == 0 ? 1 : -1, 0) : int2(0, k == 2 ? 1 : -1))
                               : int2((k & 1) ? -1 : 1, (k & 2) ? -1 : 1);
                if (pcSolidForAO(ac + t1 * o.x + t2 * o.y, S, nc, T)) solid |= 1u << k;
            }
            bool sA = solid & 1u, sB = solid & 2u, sC = solid & 4u, sD = solid & 8u;
            bool cAC = solid & 16u, cBC = solid & 32u, cAD = solid & 64u, cBD = solid & 128u;
            float g1 = fract(dot(p, float3(t1))), g2 = fract(dot(p, float3(t2)));
            float v00 = pcVertexAO(sB, sD, cBD), v10 = pcVertexAO(sA, sD, cAD);
            float v01 = pcVertexAO(sB, sC, cBC), v11 = pcVertexAO(sA, sC, cAC);
            ao = mix(mix(v00, v10, g1), mix(v01, v11, g1), g2);
        }

        // Light levels at the air in front of the face.
        float3 sp = p + n * 0.5;
        float skyLevel = 15.0;
        if (sp.z < 0.0 && abs(sp.x - 0.5) < 3.5 && ((sp.y > 3.0 && sp.y < 8.0) || (sp.y > 11.0 && sp.y < 16.0)))
            skyLevel = 15.0 - ceil(-sp.z);                 // down a piston's hole
        float blockLevel = pcBlockLevel(sp, S.sec);
        float3 light = mcLightmap(blockLevel, skyLevel, K.dayF, 0.0);
        col = alb * (h.mshade > 0.5 ? mcFaceShade(n) : 1.0) * ao * light;

        // Fog, measured from the clock: a short view distance.
        col = mix(col, fogCol, fogAt);
    }

    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
