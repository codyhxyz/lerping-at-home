// Little Planet — a walk across a block world, photographed as a stereographic
// "little planet" panorama. Original work for Lerping@Home.
//
// lerp-category: Blocks
//
// The camera stands four blocks above a dirt path and looks
// straight down; every direction round it, the whole sphere of view, is folded
// onto the screen by a stereographic projection. The ground underfoot sits in
// the middle at full size, the horizon closes into a circle, and everything
// that stands up off the ground (trees, hills, cacti) bristles outward from
// the rim into a sky of square block clouds with a square sun. As the walk goes
// on the path keeps running through the middle of the disc, the planet rolls
// towards you and turns as the path bends, and the land changes under it:
// meadow and oak wood, lakes, snowy spruce tundra, desert.
// The walk is lined with trees on a grassy bank: from an eye this low they
// are what stands up out of the rim, and every walk sets out in meadow.
//
// The world is a heightmap of whole blocks plus trees, traced column by column
// (a 2D walk of the grid), a 7×7 cell at a time: a cell the ray clears is
// crossed in one step, and everything irregular is done once per cell so the
// per-column work is the same for every pixel. Past about 22 blocks (more for
// a higher eye) the land is drawn flat, its colour read from the same world,
// fading into the haze, so the disc stays whole. Textures are 16 texels a
// face, sharp-bilinear so texel edges stay hard near the eye without crawling,
// and fade to each face's mean colour as they fall below a pixel.
//
// "Rabbit hole" turns the camera to look straight up instead: the sky becomes
// the hole in the middle and the land closes round it from the edges.
//
// lerp-param: speed    float 0 3     = 1    "Walk speed"
// lerp-param: altitude float 2 24    = 3    "Eye height"
// lerp-param: hour     float 0 1     = 0.5  "Sun height"
// lerp-param: tunnel   bool          = false "Rabbit hole"
// lerp-param: yaw      float -180 180 = 0   "Turn"
// lerp-param: pitch    float -60 60  = 0    "Tilt"
// lerp-param: magnify  float -1 1    = 0    "Zoom"
//
// lerp-animate: hour 0.12 0.8 period=900
//
// lerp-preset: "Little Planet" tunnel=false
// lerp-preset: "Rabbit Hole"  tunnel=true
// lerp-preset: "High Up"      altitude=16, magnify=0.35
// lerp-preset: "Golden Hour"  hour=0.08

constant float LP_SEA   = 32.0;    // y of the water surface
constant float LP_FAR   = 22.0;    // draw distance, blocks, at and below the horizon
constant float LP_FAR_UP = 20.0;   // ... and for rays climbing into the sky
constant int   LP_STEPS = 31;      // column steps for a primary ray (covers LP_FAR diagonally)
constant float LP_TOP   = LP_SEA + 28.5;   // nothing solid above this (land 20.3, tree 8)
constant float LP_CLOUD = LP_SEA + 70.0;   // cloud layer
constant float LP_TREE_CELL = 7.0;
constant float LP_TREE_MAX = 8.0;     // tallest tree, ground to crown

// Materials.
constant int M_GRASS = 0, M_GRASS_SIDE = 1, M_DIRT = 2, M_STONE = 3, M_SAND = 4,
             M_SNOW = 5, M_SNOW_SIDE = 6, M_PATH = 7, M_WATER = 8, M_LOG = 9,
             M_LEAVES = 11, M_SPRUCE = 12, M_CACTUS = 13,
             M_CACTUS_TOP = 14, M_SNOW_LEAVES = 15, M_SANDSTONE = 16;

struct LpWorld {
    float2 off;     // seed's offset into the noise
    float2 ph;      // path phases
    float  c0;      // where the climate wave starts
};

// Colours below are linear: each is an sRGB-ish design value raised to 2.2
// ahead of time, so no pixel pays a pow() for a constant.


// --- The path: a meandering line along +x. ---------------------------------

// (z, dz/dx) of the path at x.
static inline float2 lpPathZD(float x, LpWorld w) {
    float c1, c2;
    float s1 = sincos(x / 41.0 + w.ph.x, c1), s2 = sincos(x / 19.0 + w.ph.y, c2);
    return float2(16.0 * s1 + 7.0 * s2, 16.0 / 41.0 * c1 + 7.0 / 19.0 * c2);
}
static inline float lpPathZ(float x, LpWorld w) { return lpPathZD(x, w).x; }

constant float LP_N1 = 35.0;   // the land's broad swell: five cells
constant float LP_N2 = 14.0;   // its hills: two cells

// The path rides the land's broad swell (the terrain's own largest octave,
// read at the path), so it runs over hills rather than through trenches, and
// stays a causeway two blocks above any lake it crosses.
static inline float lpPathYz(float x, float z, LpWorld w) {
    float n1 = valueNoise((float2(x, z) + w.off) / LP_N1);
    return max(LP_SEA + 2.0, LP_SEA + 2.5 + (n1 - 0.45) * 22.0);
}
static inline float lpPathY(float x, LpWorld w) { return lpPathYz(x, lpPathZ(x, w), w); }

// A smooth periodic 0..1 wave, cheaper than a sine.
static inline float lpWave(float x) {
    float f = abs(fract(x) - 0.5) * 2.0;
    return f * f * (3.0 - 2.0 * f);
}
// Climate (0 cold .. 1 hot) runs along the walk, so the land changes as you
// go, in bands the planet carries past.
static inline float lpTempAt(float x, LpWorld w) {
    float xs = x - w.c0;
    return 0.5 + 0.28 * (lpWave(xs / 522.0) - 0.5) + 0.16 * (lpWave(xs / 232.0 + w.ph.y * 0.16) - 0.5);
}

// Everything about the path at one x: (z, slope factor 1/sqrt(1+z'^2),
// height, climate).
static inline float4 lpPathKnot(float x, LpWorld w) {
    float2 zd = lpPathZD(x, w);
    return float4(zd.x, rsqrt(1.0 + zd.y * zd.y), lpPathYz(x, zd.x, w), lpTempAt(x, w));
}

// valueNoise with its four lattice hashes kept between calls (the clouds use
// it). Same values as valueNoise, bit for bit.
static inline float lpVNc(float2 st, thread float2& key, thread float4& hh) {
    float2 i = floor(st), f = fract(st);
    if (any(i != key)) {
        key = i;
        hh = float4(hash21(i), hash21(i + float2(1.0, 0.0)), hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)));
    }
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hh.x, hh.y, u.x), mix(hh.z, hh.w, u.x), u.y);
}

// --- Terrain. ---------------------------------------------------------------

struct LpCol {
    float H;      // top of the ground (blocks fill y < H)
    float G;      // top of what a ray stops on: H, or the water surface
    float temp;   // 0 cold .. 1 hot
    float pd;     // distance to the path's centre line
};

// The world is read a 7×7 cell at a time, and everything irregular happens
// once per cell, never per column. The two noise octaves have lattices of
// 35 and 14 blocks laid on the cells' own grid (the seed offset is a whole
// number of cells), so each cell sits inside one lattice square of each and
// its noise is a blend of four hashes fetched on entry. The path has knots at
// the cells' x edges and runs straight between them (within a fifth of a block
// of the curve). A column is then plain arithmetic on what its cell holds, the
// same for every pixel in a SIMD group, which is what the GPU wants.
struct LpCell {
    float2 lo;          // the cell's corner column
    float4 h1, h2;      // lattice hashes of each octave
    float2 o1, o2;      // their lattice squares' origins, in lattice units
    float4 pa, pb;      // path knots at lo.x and lo.x + 7
};

static inline float4 lpHashes(float2 i) {
    return float4(hash21(i), hash21(i + float2(1.0, 0.0)), hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)));
}
static inline float lpBlend(float4 h, float2 f) {
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(h.x, h.y, u.x), mix(h.z, h.w, u.x), u.y);
}
static inline float2 lpSt1(float2 p, LpWorld w) { return (p + w.off) / LP_N1; }
static inline float2 lpSt2(float2 p, LpWorld w) { return (p + w.off) / LP_N2 + float2(5.0, 9.0); }

// Cell `tc`, reusing what it shares with `prev` (a ray always moves to a
// neighbouring cell: same knots when it steps in z, one knot when in x, and
// usually the same lattice squares).
static inline LpCell lpCellNext(float2 tc, LpCell prev, LpWorld w) {
    LpCell c;
    c.lo = tc * LP_TREE_CELL;
    float2 mid = c.lo + 0.5 * LP_TREE_CELL;
    c.o1 = floor(lpSt1(mid, w));
    c.o2 = floor(lpSt2(mid, w));
    c.h1 = all(c.o1 == prev.o1) ? prev.h1 : lpHashes(c.o1);
    c.h2 = all(c.o2 == prev.o2) ? prev.h2 : lpHashes(c.o2);
    float dx = c.lo.x - prev.lo.x;
    if (dx == 0.0) { c.pa = prev.pa; c.pb = prev.pb; }
    else if (dx == LP_TREE_CELL) { c.pa = prev.pb; c.pb = lpPathKnot(c.lo.x + LP_TREE_CELL, w); }
    else if (dx == -LP_TREE_CELL) { c.pb = prev.pa; c.pa = lpPathKnot(c.lo.x, w); }
    else { c.pa = lpPathKnot(c.lo.x, w); c.pb = lpPathKnot(c.lo.x + LP_TREE_CELL, w); }
    return c;
}

static inline LpCell lpCellNone() {
    LpCell c;
    c.lo = float2(1e9); c.o1 = c.o2 = float2(1e9);
    c.h1 = c.h2 = c.pa = c.pb = float4(0.0);
    return c;
}

// One column from its two noise octaves and the path where it stands.
static inline LpCol lpColumnN(float2 cell, float4 path, float n1, float n2) {
    float2 c = cell + 0.5;
    LpCol r;
    float cold = smoothstep(0.42, 0.30, path.w), hot = smoothstep(0.60, 0.70, path.w);
    r.temp = path.w;
    float amp = 1.0 - 0.2 * cold - 0.55 * hot;
    float e = LP_SEA + 1.5 + ((n1 - 0.45) * 26.0 + (n2 - 0.5) * 9.0) * amp;
    r.pd = abs(c.y - path.x) * path.y;
    if (r.pd < 40.0) {
        float py = path.z;
        e = mix(py, e, smoothstep(2.5, 11.0, r.pd));
        // A grassy bank along the walk, so the trees lining it have ground;
        // lakes lie beyond it.
        e = max(e, LP_SEA + 2.5 - 8.0 * smoothstep(10.0, 16.0, r.pd));
        // Keep the land near the walk below the eye: hills rise out of the
        // rim, they do not wall the path in.
        float cap = py + 1.0 + 0.22 * r.pd;
        e = min(e, cap + 2.0 * smoothstep(cap - 2.0, cap + 6.0, e));
    }
    r.H = floor(e);
    r.G = max(r.H, LP_SEA);
    return r;
}

static inline LpCol lpColumnIn(float2 cell, LpCell c, LpWorld w) {
    float2 p = cell + 0.5;
    float n1 = lpBlend(c.h1, lpSt1(p, w) - c.o1);
    float n2 = lpBlend(c.h2, lpSt2(p, w) - c.o2);
    float4 path = mix(c.pa, c.pb, (p.x - c.lo.x) / LP_TREE_CELL);
    return lpColumnN(cell, path, n1, n2);
}

// A column next to cell `c` (one block over at most), for corner shading:
// the lattice hashes are reused when it shares the square, and the path's
// straight run is carried one block past the knot.
static inline LpCol lpColumnNear(float2 cell, LpCell c, LpWorld w) {
    float2 p = cell + 0.5;
    float2 s1 = lpSt1(p, w), s2 = lpSt2(p, w);
    float2 i1 = floor(s1), i2 = floor(s2);
    float n1 = lpBlend(all(i1 == c.o1) ? c.h1 : lpHashes(i1), s1 - i1);
    float n2 = lpBlend(all(i2 == c.o2) ? c.h2 : lpHashes(i2), s2 - i2);
    return lpColumnN(cell, mix(c.pa, c.pb, (p.x - c.lo.x) / LP_TREE_CELL), n1, n2);
}

// --- Trees: at most one per 7×7 cell, trunk kept two blocks in from the
// cell's edge so a canopy never crosses into the next cell. ---------------

struct LpTree {
    float2 trunk;   // column of the trunk
    float  base;    // ground top at the trunk
    float  height;  // trunk height
    int    kind;    // 0 none, 1 oak, 2 spruce, 3 cactus
    float  h;       // per-tree hash
};

static inline LpTree lpTreeIn(float2 tcell, LpCell c, LpWorld w) {
    LpTree t;
    t.kind = 0;
    float h = hash21(tcell * 1.731 + w.off * 0.001 + 4.2);
    float2 o = floor(hash22(tcell + 17.7) * 2.999);
    t.trunk = tcell * LP_TREE_CELL + 2.0 + o;
    t.h = h;
    t.base = 0.0;
    t.height = 0.0;
    if (h > 0.9) return t;
    float4 path = mix(c.pa, c.pb, (t.trunk.x + 0.5 - c.lo.x) / LP_TREE_CELL);
    float temp = path.w + 0.04 * (hash21(t.trunk + 0.37) - 0.5);
    bool cold = temp < 0.36, hot = temp > 0.65;
    // Woods and clearings: the broad octave's own hashes, shuffled.
    float forest = lpBlend(c.h1.wzxy, lpSt1(t.trunk + 0.5, w) - c.o1);
    // The walk is lined with trees: they are what stands up out of the
    // planet's rim, and only things near the eye are tall enough to.
    float pd = abs(t.trunk.y + 0.5 - path.x) * path.y;
    if (pd < 5.0) return t;                       // the path itself stays clear
    bool lining = pd < 12.0;
    float density = hot ? (lining ? 0.5 : 0.22) : (lining ? 0.7 : (forest > 0.5 ? 0.6 : 0.12));
    if (h > density) return t;
    LpCol col = lpColumnIn(t.trunk, c, w);
    t.base = col.H;
    if (col.H < LP_SEA + 1.0) return t;
    float h2 = fract(h * 13.7 + 0.31);
    if (hot) { t.kind = 3; t.height = 2.0 + floor(h2 * 2.5); }
    else if (cold || (col.H > LP_SEA + 9.0 && h2 < 0.5)) { t.kind = 2; t.height = 5.0 + floor(h2 * 2.5); }
    else { t.kind = 1; t.height = 4.0 + floor(h2 * 2.0); }
    return t;
}

// The solid span [a, b) a tree occupies in column `cell`; b <= a for none.
// `logTop`: below it the span is trunk.
static inline float2 lpTreeSpan(LpTree t, float2 cell, thread float& logTop) {
    logTop = -1e9;
    if (t.kind == 0) return float2(0.0, -1.0);
    float2 d = abs(cell - t.trunk);
    float cheb = max(d.x, d.y), man = d.x + d.y;
    float hb = t.base, top = t.base + t.height;
    if (t.kind == 3) {
        if (cheb > 0.0) return float2(0.0, -1.0);
        logTop = 1e9;
        return float2(hb, top);
    }
    if (t.kind == 1) {   // oak: a 5×5 skirt two deep, a 3×3 layer, a cross on top
        if (cheb == 0.0) { logTop = top; return float2(hb, top + 2.0); }
        if (cheb == 1.0) return float2(top - 2.0, man == 1.0 ? top + 2.0 : top + 1.0);
        if (cheb == 2.0) {
            if (man == 4.0) return fract(t.h * 91.3 + cell.x * 0.37 + cell.y * 0.71) < 0.5
                                   ? float2(top - 2.0, top - 1.0) : float2(0.0, -1.0);
            return float2(top - 2.0, top);
        }
        return float2(0.0, -1.0);
    }
    // spruce: a narrow cone
    if (cheb == 0.0) { logTop = top - 1.0; return float2(hb, top + 1.0); }
    if (cheb == 1.0) return man == 1.0 ? float2(hb + 2.0, top) : float2(hb + 2.0, top - 2.0);
    if (cheb == 2.0 && man <= 3.0) return float2(hb + 2.0, man == 2.0 ? hb + 4.0 : hb + 3.0);
    return float2(0.0, -1.0);
}

// --- The trace. -------------------------------------------------------------

struct LpHit {
    float  t;
    float3 n;
    float2 cell;
    int    what;     // 0 ground/water, 1 tree, -1 none
    LpCol  col;
    LpTree tree;
    float  logTop;
    LpCell cc;       // the cell it is in, for shading's neighbour lookups
};

// A height no ground in the cell reaches. The broad octave is all but linear
// over a cell (a fifth of its lattice), so its corners bound it, plus a hair
// for the curve; the hills octave is bounded by its four hashes. Near the walk
// the land is pulled to the path (straight across the cell, so its knots bound
// it) and held under the cap that keeps it below the eye. Trees stand at most
// LP_TREE_MAX above the ground.
static inline float lpCellCeiling(LpCell c, LpWorld w) {
    const float S = LP_TREE_CELL;
    float2 a = lpSt1(c.lo, w) - c.o1, b = lpSt1(c.lo + S, w) - c.o1;
    float n1 = max(max(lpBlend(c.h1, a), lpBlend(c.h1, float2(b.x, a.y))),
                   max(lpBlend(c.h1, float2(a.x, b.y)), lpBlend(c.h1, b))) + 0.06;
    float n2 = max(max(c.h2.x, c.h2.y), max(c.h2.z, c.h2.w));
    float top = LP_SEA + 1.5 + max(0.0, (n1 - 0.45) * 26.0 + (n2 - 0.5) * 9.0);
    float4 pm = 0.5 * (c.pa + c.pb);
    float pd = abs(c.lo.y + 0.5 * S - pm.x) * pm.y;
    float slack = 6.5 + 0.04 * pd;     // every column's path distance is within this
    float pyMax = max(c.pa.z, c.pb.z);
    if (pd - slack < 11.0) top = max(top, pyMax);
    // Right by the walk the land is pulled nearly flat onto the path: at most
    // the pull's weight at the cell's far side times the land's excess.
    if (pd + slack < 11.0)
        top = min(top, pyMax + smoothstep(2.5, 11.0, pd + slack) * max(0.0, top - min(c.pa.z, c.pb.z)));
    if (pd + slack < 40.0) top = min(top, pyMax + 3.0 + 0.22 * (pd + slack));
    if (pd - slack < 16.0) top = max(top, LP_SEA + 2.5);   // the bank
    return max(top, LP_SEA);
}

// Does the ray (inverse direction `ri`) touch the box within [t0, t1]?
static inline bool lpRayBox(float3 ro, float3 ri, float3 lo, float3 hi, float t0, float t1) {
    float3 a = (lo - ro) * ri, b = (hi - ro) * ri;
    float3 tn = min(a, b), tf = max(a, b);
    return max(max(tn.x, tn.y), max(tn.z, t0)) <= min(min(tf.x, tf.y), min(tf.z, t1));
}

// Does the ray touch the tree (its trunk, or its crown: oak leaves start two
// below the trunk top, spruce two above the ground) within [t0, t1]?
static inline bool lpTreeBox(LpTree t, float3 ro, float3 ri, float t0, float t1) {
    if (t.kind == 0) return false;
    float crown = t.base + t.height + 2.0;
    float leaf = t.kind == 1 ? t.base + t.height - 2.0 : t.base + 2.0;
    float r = t.kind == 3 ? 0.0 : 2.0;
    return lpRayBox(ro, ri, float3(t.trunk.x, t.base, t.trunk.y), float3(t.trunk.x + 1.0, crown, t.trunk.y + 1.0), t0, t1)
        || lpRayBox(ro, ri, float3(t.trunk.x - r, leaf, t.trunk.y - r), float3(t.trunk.x + r + 1.0, crown, t.trunk.y + r + 1.0), t0, t1);
}

static inline LpHit lpTrace(float3 ro, float3 rd, float tFar, int steps, LpWorld w) {
    LpHit hit;
    hit.t = 1e9; hit.what = -1; hit.n = float3(0.0, 1.0, 0.0); hit.cell = float2(0.0);
    hit.logTop = 0.0;
    float2 rd2 = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float2 inv = 1.0 / rd2;
    float2 cell = floor(ro.xz);
    float2 stp = sign(rd2);
    float2 tDelta = abs(inv);
    float2 tMax = (cell + select(float2(0.0), float2(1.0), rd2 > 0.0) - ro.xz) * inv;
    float tEnter = 0.0;
    float3 nEnter = float3(0.0, 1.0, 0.0);

    float2 tcell = float2(1e9);
    LpCell cc = lpCellNone();
    LpTree tree;
    tree.kind = 0; tree.trunk = float2(0.0); tree.base = 0.0; tree.height = 0.0; tree.h = 0.0;

    for (int i = 0; i < steps; ++i) {
        float y0 = ro.y + rd.y * tEnter;

        // Entering a new 7×7 cell: if the ray stays above the cell's ceiling
        // all the way across, cross the whole cell in one step.
        float2 tc = floor(cell / LP_TREE_CELL);
        if (any(tc != tcell)) {
            tcell = tc;
            cc = lpCellNext(tc, cc, w);
            float2 lo = cc.lo, hi = lo + LP_TREE_CELL;
            float2 tb = (select(lo, hi, rd2 > 0.0) - ro.xz) * inv;
            float tOut = min(tb.x, tb.y);
            float yOut = ro.y + rd.y * tOut;
            float yLow = min(y0, yOut);
            float roof = lpCellCeiling(cc, w);
            bool clear = yLow > roof + LP_TREE_MAX;
            if (!clear) {
                tree = lpTreeIn(tc, cc, w);
                float crown = tree.kind != 0 ? tree.base + tree.height + 2.0 : 0.0;
                clear = yLow > max(roof, crown);
                float3 ri = 1.0 / float3(rd2.x, select(rd.y, 1e-6, abs(rd.y) < 1e-6), rd2.y);
                if (!clear && yLow > roof) {
                    // Clear of the ground: only the tree can stop it, so cross
                    // the cell if the ray misses the tree.
                    clear = !lpTreeBox(tree, ro, ri, tEnter, tOut);
                } else if (!clear && rd.y < 0.0 && y0 > roof) {
                    // Coming down from above the ground's ceiling: nothing in the
                    // ground until it reaches it, so jump there, unless the tree
                    // is in the way first.
                    float tR = (roof - ro.y) / rd.y;
                    if (tR > tEnter && !lpTreeBox(tree, ro, ri, tEnter, tR)) {
                        cell = clamp(floor(ro.xz + rd2 * tR), lo, hi - 1.0);
                        tMax = (cell + select(float2(0.0), float2(1.0), rd2 > 0.0) - ro.xz) * inv;
                        tEnter = tR;
                        nEnter = float3(0.0, 1.0, 0.0);
                    }
                }
            }
            if (clear) {
                if (tOut > tFar) break;
                if (rd.y > 0.0 && yOut > LP_TOP) break;
                float2 pp = ro.xz + rd2 * tOut;
                if (tb.x < tb.y) {
                    cell = float2(stp.x > 0.0 ? hi.x : lo.x - 1.0, clamp(floor(pp.y), lo.y, hi.y - 1.0));
                    nEnter = float3(-stp.x, 0.0, 0.0);
                } else {
                    cell = float2(clamp(floor(pp.x), lo.x, hi.x - 1.0), stp.y > 0.0 ? hi.y : lo.y - 1.0);
                    nEnter = float3(0.0, 0.0, -stp.y);
                }
                tMax = (cell + select(float2(0.0), float2(1.0), rd2 > 0.0) - ro.xz) * inv;
                tEnter = tOut;
                continue;
            }
        }

        y0 = ro.y + rd.y * tEnter;
        float tExit = min(tMax.x, tMax.y);
        float y1 = ro.y + rd.y * tExit;
        LpCol col = lpColumnIn(cell, cc, w);

        float best = 1e9; float3 bn = nEnter; int what = -1;
        // Ground: solid below G.
        if (y0 < col.G && tEnter > 0.0) { best = tEnter; what = 0; }
        else if (y1 < col.G) { best = (col.G - ro.y) / rd.y; bn = float3(0.0, 1.0, 0.0); what = 0; }

        // Tree in this column.
        float logTop;
        float2 span = lpTreeSpan(tree, cell, logTop);
        if (span.y > span.x) {
            float tt = 1e9; float3 tn = nEnter;
            if (y0 >= span.x && y0 < span.y && tEnter > 0.0) tt = tEnter;
            else if (rd.y < 0.0 && y0 >= span.y && y1 < span.y) { tt = (span.y - ro.y) / rd.y; tn = float3(0.0, 1.0, 0.0); }
            else if (rd.y > 0.0 && y0 < span.x && y1 >= span.x) { tt = (span.x - ro.y) / rd.y; tn = float3(0.0, -1.0, 0.0); }
            if (tt < best) { best = tt; bn = tn; what = 1; }
        }
        if (what >= 0) {
            hit.t = best; hit.n = bn; hit.cell = cell; hit.what = what;
            hit.col = col; hit.tree = tree; hit.logTop = logTop; hit.cc = cc;
            return hit;
        }
        if (tExit > tFar) break;
        if (rd.y > 0.0 && y1 > LP_TOP) break;
        tEnter = tExit;
        if (tMax.x < tMax.y) { tMax.x += tDelta.x; cell.x += stp.x; nEnter = float3(-stp.x, 0.0, 0.0); }
        else                 { tMax.y += tDelta.y; cell.y += stp.y; nEnter = float3(0.0, 0.0, -stp.y); }
    }
    return hit;
}

// --- Textures: 16×16 texels a face. `ti` is an integer texel coordinate
// (x along the face, y counted down from the top of the block). ------------

static inline float lpTone(float2 ti, float salt) { return hash21(ti * 1.13 + salt * 7.31 + 0.5); }

static inline float3 lpTexel(int mat, float2 ti, float salt, float fringe, float3 grassCol) {
    float2 tw = glmod2(ti, 16.0);
    float r = lpTone(tw, float(mat) + salt);
    float q = floor(r * 4.0) / 3.0;            // four tones
    switch (mat) {
    case M_GRASS: {
        float3 c = grassCol * (0.80 + 0.30 * q);
        // a few flowers: a 2×2 blot on some blocks
        if (salt > 0.93) {
            float2 fc = floor(float2(fract(salt * 37.0), fract(salt * 53.0)) * 10.0) + 3.0;
            if (all(tw >= fc) && all(tw < fc + 2.0))
                c = fract(salt * 71.0) < 0.5 ? float3(0.71762, 0.03575, 0.01774) : float3(0.89329, 0.66370, 0.04737);
        }
        return c;
    }
    case M_GRASS_SIDE:
    case M_SNOW_SIDE: {
        float drip = 2.0 + floor(hash21(float2(tw.x, 3.3) + salt) * 2.6);
        if (tw.y < drip && fringe > 0.5)
            return mat == M_SNOW_SIDE ? float3(0.83240, 0.87273, 0.93519) * (0.9 + 0.1 * q)
                                      : grassCol * (0.75 + 0.3 * q);
        return float3(0.18994, 0.08724, 0.03575) * (0.78 + 0.3 * q);
    }
    case M_DIRT:      return float3(0.18994, 0.08724, 0.03575) * (0.78 + 0.3 * q);
    case M_STONE: {
        float3 c = float3(0.21764, 0.21764, 0.22733) * (0.84 + 0.22 * q);
        if (r > 0.9) c *= 0.7;
        return c;
    }
    case M_SAND:      return float3(0.71762, 0.59536, 0.27926) * (0.9 + 0.13 * q);
    case M_SANDSTONE: return float3(0.61207, 0.45626, 0.19894) * ((glmod(tw.y, 16.0) < 3.0 ? 1.05 : 0.9) + 0.06 * q);
    case M_SNOW:      return float3(0.85244, 0.89329, 0.95653) * (0.93 + 0.07 * q);
    case M_PATH:      return float3(0.32504, 0.21764, 0.09317) * (0.78 + 0.32 * q);
    case M_WATER:     return float3(0.02899, 0.11899, 0.48544) * (0.85 + 0.2 * q);
    case M_LOG: {
        float stripe = hash21(float2(tw.x, 1.7) + salt);
        float3 c = float3(0.13321, 0.07074, 0.02590) * (0.75 + 0.3 * stripe) * (0.92 + 0.12 * q);
        return c;
    }
    case M_LEAVES: {
        float3 c = grassCol * float3(0.62, 0.8, 0.62) * (0.65 + 0.45 * q);
        if (r < 0.18) c *= 0.45;       // gaps
        return c;
    }
    case M_SPRUCE: {
        float3 c = float3(0.02899, 0.08724, 0.04330) * (0.7 + 0.4 * q);
        if (r < 0.2) c *= 0.5;
        return c;
    }
    case M_SNOW_LEAVES: return float3(0.79311, 0.85244, 0.93519) * (0.88 + 0.12 * q);
    case M_CACTUS: {
        float3 c = float3(0.07074, 0.23725, 0.02899) * (fmod(tw.x, 4.0) < 1.0 ? 0.7 : 1.0) * (0.9 + 0.12 * q);
        if (r > 0.94) c = float3(0.69939, 0.69939, 0.38762);
        return c;
    }
    default: {    // cactus top
        float2 d = abs(tw - 7.5);
        return float3(0.10565, 0.30168, 0.04330) * (max(d.x, d.y) > 5.5 ? 0.75 : 1.0) * (0.9 + 0.12 * q);
    }
    }
}

// Each face's mean, which the texture becomes once a texel is under a pixel.
static inline float3 lpMean(int mat, float fringe, float3 grassCol) {
    switch (mat) {
    case M_GRASS:      return grassCol * 0.95;
    case M_GRASS_SIDE: return fringe > 0.5 ? mix(float3(0.18994, 0.08724, 0.03575) * 0.93, grassCol * 0.9, 0.17)
                                           : float3(0.18994, 0.08724, 0.03575) * 0.93;
    case M_SNOW_SIDE:  return fringe > 0.5 ? mix(float3(0.18994, 0.08724, 0.03575) * 0.93, float3(0.83240, 0.87273, 0.93519), 0.17)
                                           : float3(0.18994, 0.08724, 0.03575) * 0.93;
    case M_DIRT:       return float3(0.18994, 0.08724, 0.03575) * 0.93;
    case M_STONE:      return float3(0.21764, 0.21764, 0.22733) * 0.92;
    case M_SAND:       return float3(0.71762, 0.59536, 0.27926) * 0.96;
    case M_SANDSTONE:  return float3(0.61207, 0.45626, 0.19894) * 0.95;
    case M_SNOW:       return float3(0.85244, 0.89329, 0.95653) * 0.96;
    case M_PATH:       return float3(0.32504, 0.21764, 0.09317) * 0.94;
    case M_WATER:      return float3(0.02899, 0.11899, 0.48544) * 0.95;
    case M_LOG:        return float3(0.13321, 0.07074, 0.02590) * 0.95;
    case M_LEAVES:     return grassCol * float3(0.62, 0.8, 0.62) * 0.75;
    case M_SPRUCE:     return float3(0.02899, 0.08724, 0.04330) * 0.8;
    case M_SNOW_LEAVES:return float3(0.79311, 0.85244, 0.93519) * 0.94;
    case M_CACTUS:     return float3(0.07074, 0.23725, 0.02899) * 0.9;
    default:           return float3(0.10565, 0.30168, 0.04330) * 0.9;
    }
}

// Sharp bilinear: hard texel edges up close, an even blend at a pixel's width,
// the mean once a texel is smaller than a pixel.
static inline float3 lpSample(int mat, float2 tc, float fwT, float salt, float fringe, float3 grassCol) {
    if (fwT >= 1.3) return lpMean(mat, fringe, grassCol);
    float2 b = floor(tc - 0.5), f = fract(tc - 0.5);
    float2 s = saturate((f - 0.5) / max(fwT, 1e-3) + 0.5);
    float3 c;
    if (all(s == round(s))) {
        c = lpTexel(mat, b + s, salt, fringe, grassCol);   // inside one texel
    } else {
        float3 c00 = lpTexel(mat, b, salt, fringe, grassCol);
        float3 c10 = lpTexel(mat, b + float2(1, 0), salt, fringe, grassCol);
        float3 c01 = lpTexel(mat, b + float2(0, 1), salt, fringe, grassCol);
        float3 c11 = lpTexel(mat, b + float2(1, 1), salt, fringe, grassCol);
        c = mix(mix(c00, c10, s.x), mix(c01, c11, s.x), s.y);
    }
    return mix(c, lpMean(mat, fringe, grassCol), smoothstep(0.45, 1.3, fwT));
}

// --- Sky. -------------------------------------------------------------------

struct LpSky {
    float3 L;        // towards the sun
    float3 sunCol;
    float3 zenith, horizon, glow;
    float3 amb;      // skylight on a face that sees the whole sky
    float3 cloud;
};

static inline LpSky lpSkyFor(float hour, float az) {
    LpSky s;
    float el = mix(0.12, 1.1, hour);               // radians above the horizon
    s.L = normalize(float3(cos(az) * cos(el), sin(el), sin(az) * cos(el)));
    float warm = 1.0 - smoothstep(0.04, 0.4, hour);
    warm *= warm;
    s.sunCol = mix(float3(1.0, 0.95, 0.86), float3(1.0, 0.66, 0.38), warm) * mix(1.7, 2.1, hour);
    s.zenith  = mix(float3(0.00500, 0.02590, 0.17261), float3(0.01540, 0.02899, 0.14830), warm);
    s.horizon = mix(float3(0.26841, 0.42807, 0.68142), float3(0.71762, 0.34935, 0.19894), warm);
    s.glow    = mix(float3(1.0, 0.95, 0.85), float3(1.0, 0.55, 0.25), warm);
    // Skylight takes a little of the sky's own colour: cool shade under a
    // warm low sun.
    float3 skyAvg = 0.5 * (s.horizon + float3(0.04737, 0.14830, 0.53105));
    s.amb   = mix(float3(1.0), skyAvg / dot(skyAvg, float3(0.3, 0.55, 0.15)), 0.35) * mix(0.55, 0.46, warm);
    s.cloud = mix(mix(s.horizon, float3(1.0), 0.75), mix(s.horizon, s.glow, 0.45) * 1.15, warm);
    return s;
}

static inline float3 lpSkyColor(float3 rd, LpSky s) {
    float h = saturate(rd.y);
    float3 c = mix(s.horizon, s.zenith, sqrt(sqrt(h)));
    float g = max(dot(rd, s.L), 0.0);
    float g2 = g * g, g8 = g2 * g2 * g2 * g2;
    c += s.glow * (0.18 * g2 * g2 * g2 + 0.25 * g8 * g8 * g8 * g8 * g8);
    // below the horizon (seen past the draw distance): the haze darkens a little
    if (rd.y < 0.0) c = mix(s.horizon, s.horizon * 0.8, saturate(-rd.y * 3.0));
    return c;
}

// The square sun, aligned to the horizon.
static inline float3 lpSun(float3 rd, LpSky s, float pxA) {
    float3 ex = normalize(cross(float3(0.0, 1.0, 0.0), s.L));
    float3 ey = cross(s.L, ex);
    float d = dot(rd, s.L);
    if (d <= 0.0) return float3(0.0);
    float2 q = float2(dot(rd, ex), dot(rd, ey)) / d;
    float e = max(abs(q.x), abs(q.y)) - 0.055;
    float m = 1.0 - smoothstep(-pxA, pxA, e);
    return s.sunCol * 2.2 * m;
}

// Square clouds: a slab LP_CLOUD_T thick, cut into 12-block cells, drifting.
constant float LP_CLOUD_S = 12.0;
constant float LP_CLOUD_T = 4.0;

static inline float lpCloudAt(float2 cc, float s0, thread float2& key, thread float4& hh) {
    float n = lpVNc(cc * 0.33 + s0 * 13.0, key, hh);
    return step(0.72, n);
}

// Seen from below: the bottom face of the cell overhead, or else the first
// side face the ray meets on its way up through the slab. Returns (shade, alpha).
static inline float2 lpClouds(float3 ro, float3 rd, float time, float s0, float pxA) {
    if (rd.y <= 0.01) return float2(0.0);
    float tB = (LP_CLOUD - ro.y) / rd.y;
    float fade = 0.9 * (1.0 - smoothstep(150.0, 460.0, tB));
    if (fade <= 0.0) return float2(0.0);
    float2 wind = float2(time * 0.9, time * 0.3);
    float2 ck = float2(1e9); float4 chh = float4(0.0);
    float2 q = (ro.xz + rd.xz * tB + wind) / LP_CLOUD_S;
    float2 cc = floor(q), f = q - cc;
    if (lpCloudAt(cc, s0, ck, chh) > 0.5) {
        // Soften the bottom face's edge against the footprint, where it meets sky.
        float fw = tB * pxA / max(rd.y, 0.05) / LP_CLOUD_S;
        float2 de = min(f, 1.0 - f);
        float2 so = select(float2(-1.0), float2(1.0), f > 0.5);
        float ex = lpCloudAt(cc + float2(so.x, 0.0), s0, ck, chh) > 0.5 ? 1.0 : smoothstep(0.0, fw, de.x);
        float ez = lpCloudAt(cc + float2(0.0, so.y), s0, ck, chh) > 0.5 ? 1.0 : smoothstep(0.0, fw, de.y);
        return float2(0.84, fade * min(mix(0.5, 1.0, ex), mix(0.5, 1.0, ez)));
    }
    float tTop = (LP_CLOUD + LP_CLOUD_T - ro.y) / rd.y;
    float2 d = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6) / LP_CLOUD_S;
    float2 inv = 1.0 / d, stp = sign(d);
    float2 tMax = tB + (cc + select(float2(0.0), float2(1.0), d > 0.0) - q) * inv;
    float2 tDelta = abs(inv);
    for (int i = 0; i < 3; ++i) {
        float tc = min(tMax.x, tMax.y);
        if (tc > tTop) break;
        bool xs = tMax.x < tMax.y;
        if (xs) { tMax.x += tDelta.x; cc.x += stp.x; } else { tMax.y += tDelta.y; cc.y += stp.y; }
        if (lpCloudAt(cc, s0, ck, chh) > 0.5) return float2(xs ? 0.97 : 0.9, fade);
    }
    return float2(0.0);
}

// --- Shading a hit. -----------------------------------------------------------

static inline float3 lpGrassCol(float tp) {
    float3 g = mix(float3(0.11899, 0.32504, 0.04330), float3(0.10565, 0.27926, 0.11899), smoothstep(0.45, 0.33, tp));
    return mix(g, float3(0.27926, 0.34935, 0.05163), smoothstep(0.55, 0.64, tp));
}

// Past the traced reach, the land is drawn flat: the ray meets a plane just
// above the sea and takes the colour of whatever top face the world has
// there, lit like one, in its own haze. Everything traced fades into this
// rather than into sky, so the disc stays whole out to the horizon while
// the trace stays short.
static inline float3 lpFarLand(float3 ro, float3 rd, LpSky sky, LpWorld w, float far) {
    float3 skyC = lpSkyColor(rd, sky);
    if (rd.y >= -1e-4) return skyC;
    float tP = (LP_SEA + 1.0 - ro.y) / rd.y;
    float2 cell = floor(ro.xz + rd.xz * tP);
    // One column, read directly: no cell to build for a single lookup.
    float2 p = cell + 0.5;
    float2 zd = lpPathZD(p.x, w);
    float4 path = float4(zd.x, rsqrt(1.0 + zd.y * zd.y), 0.0, lpTempAt(p.x, w));
    path.z = LP_SEA + 4.0;   // the path's height barely shows this far out
    LpCol col = lpColumnN(cell, path, valueNoise(lpSt1(p, w)), valueNoise(lpSt2(p, w)));
    float H = col.H, tp = col.temp;
    float3 alb;
    bool water = col.G > H;
    if (water)                          alb = float3(0.02896, 0.11899, 0.48557) * (exp(-0.22 * (col.G - H)) * 0.8 + 0.2);
    else if (col.pd < 1.6)              alb = float3(0.30, 0.20, 0.087);
    else if (H > LP_SEA + 17.0)         alb = float3(0.80, 0.85, 0.92);
    else if (H > LP_SEA + 12.0)         alb = float3(0.20, 0.20, 0.21);
    else if (tp > 0.65 || H <= LP_SEA + 1.0) alb = float3(0.69, 0.58, 0.27);
    else if (tp < 0.36)                 alb = float3(0.80, 0.85, 0.92);
    else                                alb = lpGrassCol(tp) * 0.95;
    float3 c = alb * (sky.amb + sky.sunCol * sky.L.y * 0.55);
    if (water) c = mix(c, lpSkyColor(reflect(rd, float3(0.0, 1.0, 0.0)), sky), 0.15 + 0.6 * pow(1.0 - saturate(-rd.y), 4.0));
    return mix(c, skyC, smoothstep(far * 0.5, far * 3.0, tP));
}

static inline float lpVertexAO(float s1, float s2, float sc) {
    float occ = (s1 > 0.5 && s2 > 0.5) ? 3.0 : s1 + s2 + sc;
    return 1.0 - 0.17 * occ;
}

static inline float3 lpShade(LpHit h, float3 ro, float3 rd, float pxA, float far, LpSky sky, LpWorld w,
                             float time) {
    float3 p = ro + rd * h.t;
    float3 n = h.n;
    float fw = h.t * pxA / max(abs(dot(rd, n)), 0.1);
    float fwT = fw * 16.0;

    // Biome colour of grass and leaves.
    float tp = h.col.temp + 0.04 * (hash21(h.cell + 0.37) - 0.5);   // ragged biome edges
    float3 grassCol = lpGrassCol(tp);
    bool cold = tp < 0.36, hot = tp > 0.65;

    // Face coordinates: (along, down) in blocks.
    float2 fc;
    bool top = n.y > 0.5, bottom = n.y < -0.5;
    if (top || bottom) fc = p.xz;
    else if (abs(n.x) > 0.5) fc = float2(p.z * -n.x, -p.y);
    else fc = float2(p.x * n.z, -p.y);
    float blockY = top ? floor(p.y - 0.5) : (bottom ? floor(p.y + 0.5) : floor(p.y));
    float salt = hash21(h.cell * 0.917 + blockY * 3.1 + 0.2);

    int mat;
    float fringe = 0.0;
    float waterDepth = 0.0;
    if (h.what == 1) {
        // A trunk shows only on its sides; leaves and cactus cap everything.
        bool trunk = p.y < h.logTop - 1e-3;
        if (h.tree.kind == 3) mat = top ? M_CACTUS_TOP : M_CACTUS;
        else if (trunk) mat = M_LOG;
        else if (h.tree.kind == 2) mat = (top && cold) ? M_SNOW_LEAVES : M_SPRUCE;
        else mat = M_LEAVES;
    } else {
        float H = h.col.H;
        bool water = h.col.G > H && p.y > H - 1e-3 && top;
        float depth = h.col.H - p.y;    // below the column's own top (sides)
        bool path = h.col.pd < 1.55 + 0.25 * hash21(h.cell + 9.1);
        bool high = H > LP_SEA + 12.0 + 2.0 * hash21(h.cell + 1.3);
        bool peak = H > LP_SEA + 17.0 + 2.0 * hash21(h.cell + 2.9);
        bool beach = H <= LP_SEA + 1.0 && !path;
        if (water) { mat = M_WATER; waterDepth = h.col.G - H; }
        else if (top) {
            if (path) mat = M_PATH;
            else if (peak) mat = M_SNOW;
            else if (high) mat = M_STONE;
            else if (hot || beach) mat = M_SAND;
            else if (cold) mat = M_SNOW;
            else mat = M_GRASS;
        } else {
            if (hot || beach) mat = depth < 3.0 ? M_SAND : M_SANDSTONE;
            else if (high || depth > 3.5) mat = M_STONE;
            else if (path) mat = M_DIRT;
            else if (peak || cold) mat = M_SNOW_SIDE;
            else mat = M_GRASS_SIDE;
            fringe = depth < 1.0 ? 1.0 : 0.0;
            if (peak && depth < 1.0) mat = M_SNOW_SIDE;
        }
    }

    // Grass tops get one of four rotations per block, so the tiling breaks up.
    float2 tc = fc * 16.0;
    if (top && mat == M_GRASS) {
        float2 bl = floor(fc), f = (fc - bl) * 16.0;
        int rot = int(salt * 4.0) & 3;
        if (rot == 1) f = float2(16.0 - f.y, f.x);
        else if (rot == 2) f = 16.0 - f;
        else if (rot == 3) f = float2(f.y, 16.0 - f.x);
        tc = bl * 16.0 + f;
    }
    float3 alb = lpSample(mat, tc, fwT, salt, fringe, grassCol);
    LpCell cc = h.cc;

    // Light: the classic per-face shading, the sun, and dark inside corners.
    float face = top ? 1.0 : (bottom ? 0.5 : (abs(n.x) > 0.5 ? 0.8 : 0.66));
    float ao = 1.0;
    if (top && h.what == 0) {
        float G = h.col.G;
        float2 c = h.cell;
        float sx0 = lpColumnNear(c + float2(-1, 0), cc, w).G > G ? 1.0 : 0.0;
        float sx1 = lpColumnNear(c + float2( 1, 0), cc, w).G > G ? 1.0 : 0.0;
        float sz0 = lpColumnNear(c + float2(0, -1), cc, w).G > G ? 1.0 : 0.0;
        float sz1 = lpColumnNear(c + float2(0,  1), cc, w).G > G ? 1.0 : 0.0;
        float2 f = fract(p.xz);
        float a00 = lpVertexAO(sx0, sz0, 0.0), a10 = lpVertexAO(sx1, sz0, 0.0);
        float a01 = lpVertexAO(sx0, sz1, 0.0), a11 = lpVertexAO(sx1, sz1, 0.0);
        ao = mix(mix(a00, a10, f.x), mix(a01, a11, f.x), f.y);
    } else if (!top && !bottom && h.what == 0) {
        float2 cf = h.cell + n.xz;
        float Gf = lpColumnNear(cf, cc, w).G;
        ao = mix(0.62, 1.0, smoothstep(0.0, 1.0, p.y - Gf));
    }

    float sunN = max(dot(n, sky.L), 0.0);
    float3 light = sky.amb * face * ao + sky.sunCol * sunN * 0.55 * mix(0.85, 1.0, ao);
    float3 col = alb * light;

    if (mat == M_WATER) {
        // Water: depth darkens it, the sky shows in it at a glance.
        col *= exp(-0.22 * waterDepth) * 0.8 + 0.2;
        float fres = pow(1.0 - saturate(-rd.y), 4.0);
        col = mix(col, lpSkyColor(reflect(rd, n), sky), 0.15 + 0.6 * fres);
        // slow texel ripples
        float2 tw = floor(tc);
        float rip = hash21(tw + floor(time * 0.6 + hash21(tw) * 3.0));
        col *= 1.0 + 0.08 * (rip - 0.5) * (1.0 - smoothstep(0.45, 1.3, fwT));
    }

    // Draw distance: the traced world fades into the flat far land (or, above
    // the horizon, the sky) of its own direction.
    // Above the horizon the haze holds off longer: that is the silhouette.
    float fog = smoothstep(far * (rd.y > 0.0 ? 0.8 : 0.5), far, h.t);
    if (fog > 0.0) col = mix(col, lpFarLand(ro, rd, sky, w, far), fog);
    return col;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float seed = u.seed;
    LpWorld w;
    // A whole number of 7-block cells, so the noise lattices stay on the cell grid.
    w.off = floor(float2(seed * 3917.0, fract(seed * 7.13) * 2671.0) / LP_TREE_CELL) * LP_TREE_CELL;
    w.ph = float2(seed * 37.0, fract(seed * 3.7) * 11.0);
    // Every walk opens in temperate country, the climate wave at its middle
    // (warming or cooling by seed); desert and snow come later on.
    w.c0 = seed * 600.0 - 522.0 * (fract(seed * 7.3) < 0.5 ? 0.25 : 0.75);

    // The walk.
    float sx = u.time * 0.55 * u.speed + seed * 600.0;
    float pz = lpPathZ(sx, w);
    float3 ro = float3(sx, lpPathY(sx, w) + 1.0 + u.altitude, pz);
    float3 F = normalize(float3(1.0, 0.0, lpPathZD(sx, w).y));
    float3 R = float3(-F.z, 0.0, F.x);
    float3 U = float3(0.0, 1.0, 0.0);

    // Stereographic projection of the whole sphere of view.
    float minRes = min(u.resolution.x, u.resolution.y);
    float k = 1.2 * exp2(-u.magnify);
    float2 uv = lerpUV(pos, u.resolution);
    float spin = u.yaw * (PI / 180.0) + 0.35 * sin(u.time * 0.011 + seed * 6.0);
    float2 q = rotate(uv, spin) * k;
    float r2 = dot(q, q);
    float down = u.tunnel != 0 ? 1.0 : -1.0;
    float3 dl = float3(2.0 * q.x, 2.0 * q.y, -down * (r2 - 1.0)) / (1.0 + r2);   // (right, fwd, up)
    float pa = u.pitch * (PI / 180.0);
    dl.yz = float2(cos(pa) * dl.y - sin(pa) * dl.z, sin(pa) * dl.y + cos(pa) * dl.z);
    if (u.tunnel != 0) dl.x = -dl.x;
    float3 rd = normalize(dl.x * R + dl.y * F + dl.z * U);
    // Angle a pixel subtends here.
    float pxA = 2.0 * k / (1.0 + r2) * (2.0 / minRes);

    LpSky sky = lpSkyFor(u.hour, seed * TWO_PI + 0.9);

    // A ray climbing into the sky rises slowly and crosses dozens of empty
    // columns before it clears the tallest tree, and in this projection such
    // rays fill most of the screen. So above the horizon the reach shortens
    // (and its haze with it): what stands up out of the rim is near anyway.
    // Steeper still, nothing near the walk reaches that high, so the reach
    // falls to a few cells.
    float far = rd.y > 0.0 ? mix(mix(LP_FAR, LP_FAR_UP, smoothstep(0.0, 0.06, rd.y)), 10.0,
                                 smoothstep(0.08, 0.26, rd.y))
                           : LP_FAR;
    // The reach is set for the default eye height; a higher eye sees further
    // before the haze, so the reach (and the step budget) grow with it.
    float reach = max(1.0, (u.altitude + 1.0) / 6.0);
    far *= reach;
    LpHit h = lpTrace(ro, rd, far, int(float(LP_STEPS) * reach), w);
    float3 col;
    if (h.what >= 0) {
        col = lpShade(h, ro, rd, pxA, far, sky, w, u.time);
    } else {
        col = lpFarLand(ro, rd, sky, w, far);
        col += lpSun(rd, sky, pxA);
        float2 cl = lpClouds(ro, rd, u.time, seed, pxA);
        col = mix(col, sky.cloud * cl.x, cl.y);
    }

    // Gentle shoulder, display gamma.
    col = col / (1.0 + col * 0.3);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
