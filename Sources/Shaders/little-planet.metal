// Little Planet — a walk across a Minecraft world, photographed as a
// stereographic "little planet" panorama. Original work for Lerping@Home.
//
// lerp-category: Minecraft
// lerp-requires: minecraft
//
// The camera stands four blocks above a dirt path and looks
// straight down; every direction round it, the whole sphere of view, is folded
// onto the screen by a stereographic projection. The ground underfoot sits in
// the middle at full size, the horizon closes into a circle, and everything
// that stands up off the ground (trees, hills, cacti) bristles outward from
// the rim into the game's sky, its square sun and its flat cloud layer. As the
// walk goes on the path keeps running through the middle of the disc, the
// planet rolls towards you and turns as the path bends, and the land changes
// under it: plains with oak and birch, lakes, snowy spruce country, desert.
// The walk is lined with trees on a grassy bank: from an eye this low they
// are what stands up out of the rim, and every walk sets out in plains.
//
// The projection is the only unusual thing here; what it projects is the
// ordinary game. Every face is a block's own texture from the installed copy
// of Minecraft: grass tops and leaves grey and tinted from the biome
// colormaps, the grass block's side with its tinted fringe, dirt path (a
// sixteenth lower than the grass, as in the game), dirt, stone, sand,
// sandstone, snow, oak, birch and spruce logs and leaves, cactus, and still
// water animated and tinted over its lake bed. Leaves are cut out by their
// alpha, so the sky and the branches behind show through them; short grass,
// ferns, flowers and dead bushes stand on the ground as the game's crossed
// planes. Light is the game's: fixed shading by face, smooth-lighting corners,
// one light level lost under a canopy and one per block of water, and no sun
// shading at all. The sky is the game's sky and fog colours, its sunrise
// band, its sun texture, and clouds.png laid out twelve blocks a texel.
//
// The world is a heightmap of whole blocks plus trees, traced column by column
// (a 2D walk of the grid), a 7×7 cell at a time: a cell the ray clears is
// crossed in one step, and everything irregular is done once per cell so the
// per-column work is the same for every pixel. Past about 22 blocks (16 for
// rays climbing into the sky; more for a higher eye) the land is drawn flat,
// textured from the same world, fading into the fog, so the disc stays whole.
//
// Cost (about 1.2× `maze`). The march dominates, so nothing is added per
// column step: textures are sampled only at the hit, and even a hash there
// showed up (the path's ragged edge is a few-op dither instead). The cut-out
// leaves are the next cost: a ray that meets a leaf on a clear texel walks the
// crown's own voxels (at most 6 steps, one texture fetch and no world lookups
// each); leaving the crown downward it is traced on once, on a quarter of the
// step budget, and upward it is sky. Then shading: smooth lighting looks up
// the nearer neighbour on each axis only, and plants are found after a ground
// hit by stepping back over at most two columns the ray crossed in the block
// of air above it.
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
constant float LP_FAR_UP = 16.0;   // ... and for rays climbing into the sky
constant int   LP_STEPS = 31;      // column steps for a primary ray (covers LP_FAR diagonally)
constant float LP_TOP   = LP_SEA + 28.5;   // nothing solid above this (land 20.3, tree 8)
constant float LP_CLOUD = LP_SEA + 70.0;   // cloud layer
constant float LP_TREE_CELL = 7.0;
constant float LP_TREE_MAX = 8.0;     // tallest tree, ground to crown

struct LpWorld {
    float2 off;     // seed's offset into the noise
    float2 ph;      // path phases
    float  c0;      // where the climate wave starts
};

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

// --- Terrain. ---------------------------------------------------------------

struct LpCol {
    float H;      // top of the ground (blocks fill y < H)
    float G;      // top of what a ray stops on: H, or the water surface
    float temp;   // 0 cold .. 1 hot
    float pd;     // distance to the path's centre line
    bool  path;   // a dirt path block (its top a sixteenth below H)
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
    // The walk is dirt path, a sixteenth lower than the grass as in the game,
    // its edge ragged column by column. (Never under water: it is a causeway.)
    // This runs at every step of the march, so the ragged edge is a few-op
    // dither (golden-ratio steps, broken up by a product term), not a hash.
    r.path = r.pd < 1.55 + 0.25 * fract(dot(cell, float2(0.618034, 0.381966)) + cell.x * cell.y * 0.0731);
    if (r.path) r.G = r.H - 0.0625;
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
    int    kind;    // 0 none, 1 oak, 2 spruce, 3 cactus, 4 birch
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
    else if (fract(h * 7.3 + 0.17) < 0.3) { t.kind = 4; t.height = 5.0 + floor(h2 * 2.0); }
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
    if (t.kind == 1 || t.kind == 4) {   // oak and birch: a 5×5 skirt two deep, a 3×3 layer, a cross on top
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

// Does the ray touch the tree (its trunk, or its crown: oak and birch leaves
// start two below the trunk top, spruce two above the ground) within [t0, t1]?
static inline bool lpTreeBox(LpTree t, float3 ro, float3 ri, float t0, float t1) {
    if (t.kind == 0) return false;
    float crown = t.base + t.height + 2.0;
    float leaf = t.kind == 2 ? t.base + 2.0 : t.base + t.height - 2.0;
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

// --- What a column is made of. ------------------------------------------------

struct LpBiome { bool hot, cold, beach, high, peak; };

static inline LpBiome lpBiomeAt(LpCol col, float2 cell) {
    LpBiome b;
    float tp = col.temp + 0.04 * (hash21(cell + 0.37) - 0.5);   // ragged biome edges
    b.hot = tp > 0.65;
    b.cold = tp < 0.36;
    b.high = col.H > LP_SEA + 12.0 + 2.0 * hash21(cell + 1.3);
    b.peak = col.H > LP_SEA + 17.0 + 2.0 * hash21(cell + 2.9);
    b.beach = col.H <= LP_SEA + 1.0 && !col.path;
    return b;
}

constant int K_GRASS = 0, K_PATH = 1, K_SNOW = 2, K_STONE = 3, K_SAND = 4, K_WATER = 5;

static inline int lpTopKind(LpCol col, LpBiome b) {
    if (col.G > col.H) return K_WATER;
    if (col.path) return K_PATH;
    if (b.peak) return K_SNOW;
    if (b.high) return K_STONE;
    if (b.hot || b.beach) return K_SAND;
    if (b.cold) return K_SNOW;
    return K_GRASS;
}

static inline int lpTopLayer(int kind) {
    switch (kind) {
    case K_PATH:  return MC_DIRT_PATH_TOP;
    case K_SNOW:  return MC_SNOW;
    case K_STONE: return MC_STONE;
    case K_SAND:  return MC_SAND;
    default:      return MC_GRASS_BLOCK_TOP;
    }
}

// The walk's climate (0 cold .. 1 hot) as the game's biome temperature and
// downfall: plains (0.8, 0.4) where every walk sets out, a wetter, deeper
// green toward the taiga, dry savanna-yellow toward the desert.
static inline float2 lpClimate(float tp) {
    float u = saturate((tp - 0.36) / 0.29) - 0.5;
    return float2(0.8 + 0.7 * u, 0.4 - 0.5 * u);
}
static inline float3 lpGrassTint(texture2d_array<float> maps, float tp) {
    float2 c = lpClimate(tp);
    return mcGrassTint(maps, c.x, c.y);
}

// Face coordinates, 0..1 across a face, as the game lays its textures: tops
// by x and z, sides with the picture's top row at the top of the block.
static inline float2 lpFaceUV(float3 p, float3 n) {
    if (abs(n.y) > 0.5) return fract(p.xz);
    float u = abs(n.x) > 0.5 ? fract(p.z) : fract(p.x);
    if (n.x > 0.5 || n.z < -0.5) u = 1.0 - u;
    return float2(u, fract(-p.y));
}

// The game turns each grass top one of four ways.
static inline float2 lpTurn(float2 uv, float r) {
    int k = int(r * 4.0) & 3;
    if (k == 1) return float2(1.0 - uv.y, uv.x);
    if (k == 2) return 1.0 - uv;
    if (k == 3) return float2(uv.y, 1.0 - uv.x);
    return uv;
}

// A lake: still water, tinted, over a bed that loses a light level a block.
static inline float3 lpWater(texture2d_array<float> tiles, float2 uv, float fp, float time,
                             float depth, float2 bedCell, float2 bedUV, float bedFp, float day) {
    float r = hash21(bedCell + 4.4);
    int bed = depth < 1.5 ? MC_SAND : (r < 0.4 ? MC_GRAVEL : (r < 0.8 ? MC_DIRT : MC_CLAY));
    // Lit relative to the surface, which the caller lights at full sky light.
    float3 bedLit = mcLightmap(0.0, 15.0 - depth, day, 0.0) / mcLightmap(0.0, 15.0, day, 0.0);
    float3 floorC = mcTile(tiles, bed, bedUV, bedFp).rgb * bedLit;
    float4 wt = mcTile(tiles, mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, time),
                       uv, fp);
    return mix(floorC, wt.rgb * MC_WATER_TINT, wt.a);
}

// A top face of the land (not water).
static inline float3 lpTopColor(texture2d_array<float> tiles, int kind, float2 cell, float2 uv,
                                float fp, float3 grassTint) {
    if (kind == K_GRASS) uv = lpTurn(uv, hash21(cell * 0.917 + 0.2));
    float3 c = mcTile(tiles, lpTopLayer(kind), uv, fp).rgb;
    return kind == K_GRASS ? c * grassTint : c;
}

// --- Trees. -------------------------------------------------------------------

static inline int lpLeafLayer(int kind) {
    return kind == 2 ? MC_SPRUCE_LEAVES : (kind == 4 ? MC_BIRCH_LEAVES : MC_OAK_LEAVES);
}
static inline int lpLogLayer(int kind, bool end) {
    if (kind == 2) return end ? MC_SPRUCE_LOG_TOP : MC_SPRUCE_LOG;
    if (kind == 4) return end ? MC_BIRCH_LOG_TOP : MC_BIRCH_LOG;
    return end ? MC_OAK_LOG_TOP : MC_OAK_LOG;
}
// Spruce and birch leaves have fixed colours in the game; oak takes the
// biome's foliage colormap.
static inline float3 lpLeafTint(texture2d_array<float> maps, int kind, float tp) {
    if (kind == 2) return float3(0.4300, 0.5943, 0.4015);   // mcFromSRGB(#619961)
    if (kind == 4) return float3(0.5333, 0.6505, 0.3725);   // mcFromSRGB(#80A755)
    float2 c = lpClimate(tp);
    return mcFoliageTint(maps, c.x, c.y);
}

// A ray has met a leaf face at t (normal n). Leaves are cut out by their
// texture's alpha, so walk the tree's voxels from there: each leaf face it
// enters is sampled, and a log stops it. Leaving the crown hands the ray back
// to the trace (returns 2, t where it left): sideways or over the top, or
// down below base + 2, under every leaf of either shape, where only the trunk
// and the ground are left and the trace already knows both. 0: a leaf, 1: a
// log, with t, n and the voxel `v` updated. A third leaf face behind two
// clear texels (one ray in seven) is deep in the crown: it ends the walk as a
// leaf, which the shading then draws at the texture's mean colour (`deep`).
static inline int lpLeafWalk(LpTree tr, float3 ro, float3 rd, float pxA, texture2d_array<float> tiles,
                             thread float& t, thread float3& n, thread float3& v, thread float& logTop,
                             thread bool& deep, thread float3& texel) {
    int layer = lpLeafLayer(tr.kind);
    float3 rdg = select(rd, float3(1e-6), abs(rd) < 1e-6);
    float3 inv = 1.0 / rdg, s = sign(rdg);
    float3 p = ro + rd * t;
    v = floor(p - n * 0.5);
    float3 tMax = (v + step(0.0, rdg) - ro) * inv;
    float3 tD = abs(inv);
    float crown = tr.base + tr.height + 2.0;
    bool leaf = true;
    int clear = 0;
    deep = false;
    for (int i = 0; i < 6; ++i) {
        if (leaf) {
            if (clear == 2) { deep = true; return 0; }   // (counted from the first)
            float fp = t * pxA / max(abs(dot(rd, n)), 0.1);
            float4 c = mcTile(tiles, layer, lpFaceUV(p, n), fp);
            texel = c.rgb;
            if (c.a > 0.5) return 0;
            ++clear;
        }
        if (tMax.x < tMax.y && tMax.x < tMax.z) { t = tMax.x; tMax.x += tD.x; v.x += s.x; n = float3(-s.x, 0.0, 0.0); }
        else if (tMax.y < tMax.z)               { t = tMax.y; tMax.y += tD.y; v.y += s.y; n = float3(0.0, -s.y, 0.0); }
        else                                    { t = tMax.z; tMax.z += tD.z; v.z += s.z; n = float3(0.0, 0.0, -s.z); }
        p = ro + rd * t;
        float2 d = abs(v.xz - tr.trunk);
        if (max(d.x, d.y) > 2.0 || v.y < tr.base + 2.0 || v.y >= crown) return 2;
        float2 span = lpTreeSpan(tr, v.xz, logTop);
        leaf = v.y >= span.x && v.y < span.y;
        if (leaf && v.y < logTop) return 1;
    }
    return 2;
}

// --- Plants: the game's crossed planes (the kit's mcCross), one block tall. -----

// The plant on a column's top, or -1: short grass, ferns toward the taiga,
// the plains' flowers, dead bushes in the desert. `tinted`: takes the grass
// colour.
static inline int lpPlantLayer(float r, int kind, LpBiome b, float tp, thread bool& tinted) {
    tinted = false;
    if (kind == K_GRASS) {
        if (r < 0.2) { tinted = true; return (tp < 0.42 && fract(r * 31.7) < 0.6) ? MC_FERN : MC_SHORT_GRASS; }
        if (r < 0.235) {
            switch (int(fract(r * 517.3) * 6.0)) {
            case 0:  return MC_POPPY;
            case 1:  return MC_DANDELION;
            case 2:  return MC_OXEYE_DAISY;
            case 3:  return MC_CORNFLOWER;
            case 4:  return MC_AZURE_BLUET;
            default: return MC_RED_TULIP;
            }
        }
    } else if (kind == K_SAND && b.hot && r < 0.03) {
        return MC_DEAD_BUSH;
    }
    return -1;
}
constant float LP_PLANT_P = 0.235;   // the most any column carries a plant

// Plants in the block of air above a ground hit: step back over the columns
// the ray crossed since it came down through the top of that block (at most
// two: near the middle, where plants are big, the rays are steep), and take
// the nearest plant it touches. Only columns level with the
// hit can hold one the ray reaches. Returns (rgb, t), t = 1e9 for none.
static inline float4 lpPlants(LpHit h, float3 ro, float3 rd, float pxA, LpWorld w,
                              texture2d_array<float> tiles, float3 grassTint) {
    float4 best = float4(0.0, 0.0, 0.0, 1e9);
    float G = h.col.G;
    float t1 = (G + 1.0 - ro.y) / rd.y;
    float tMin = max(t1 - 0.01, 0.0);    // just above where the ray comes down into the block
    float2 rd2 = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float2 inv = 1.0 / rd2, stp = sign(rd2);
    float2 cell = h.cell;
    for (int i = 0; i < 2; ++i) {
        float r = hash21(cell * 1.17 + 31.7);
        if (r < LP_PLANT_P) {
            LpCol col = all(cell == h.cell) ? h.col : lpColumnNear(cell, h.cc, w);
            if (col.G == G) {
                LpBiome b = lpBiomeAt(col, cell);
                bool tinted;
                int layer = lpPlantLayer(r, lpTopKind(col, b), b, col.temp, tinted);
                McModelHit mh;
                if (layer >= 0 && mcCross(tiles, layer, float3(cell.x, G, cell.y), tinted ? grassTint : float3(1.0),
                                          ro, rd, tMin, best.w, pxA, mh))
                    best = float4(mh.color.rgb, mh.t);
            }
        }
        // back across the face the ray came in by
        float2 tb = (cell + select(float2(1.0), float2(0.0), rd2 > 0.0) - ro.xz) * inv;
        if (max(tb.x, tb.y) <= t1) break;
        if (tb.x > tb.y) cell.x -= stp.x; else cell.y -= stp.y;
    }
    return best;
}

// --- Sky: the game's colours, sunrise band, sun and clouds. ---------------------

struct LpSky {
    float3 L;        // towards the sun
    float2 sunH;     // the sun's compass direction
    float  day;      // the game's sky brightness, 1 by day, falling at dusk
    float3 lit;      // the lightmap at full sky light
    float3 sky;      // overhead
    float3 fog;      // toward the horizon
    float4 rise;     // sunrise colour and strength
};

static inline LpSky lpSkyFor(float hour, float az) {
    LpSky s;
    float el = mix(0.12, 1.1, hour);               // radians above the horizon
    s.sunH = float2(cos(az), sin(az));
    s.L = float3(s.sunH.x * cos(el), sin(el), s.sunH.y * cos(el));
    // The game's sky brightness from the sun's height, and its sky and fog
    // colours (plains), the fog pulled a little toward the sky as at a
    // twelve-chunk render distance.
    float f = sin(el);
    s.day = saturate(f * 2.0 + 0.5);
    s.lit = mcLightmap(0.0, 15.0, s.day, 0.0);
    s.sky = mcSkyAt(s.day);
    s.fog = mix(mcFogAt(s.day), s.sky, 0.146);
    // The sunrise band, the game's formula, for a sun within 0.4 of the horizon.
    s.rise = float4(0.0);
    if (f < 0.4) {
        float g = f / 0.4 * 0.5 + 0.5;
        float a = 1.0 - (1.0 - sin(g * PI)) * 0.99;
        s.rise = float4(mcFromSRGB(float3(g * 0.3 + 0.7, g * g * 0.7 + 0.2, 0.2)), a * a);
    }
    return s;
}

// Fog colour seen along rd: the sunrise tints the half of it facing the sun.
static inline float3 lpFogCol(float3 rd, LpSky s) {
    float2 hd = rd.xz * rsqrt(max(dot(rd.xz, rd.xz), 1e-8));
    float d = max(dot(hd, s.sunH), 0.0) * s.rise.a;
    return mix(s.fog, s.rise.rgb, d);
}

static inline float3 lpSkyColor(float3 rd, LpSky s) {
    float h = max(rd.y, 0.0);
    float k = saturate(h / 0.45);
    float3 c = mix(lpFogCol(rd, s), s.sky, k * (2.0 - k));
    if (s.rise.a > 0.0) {
        float2 hd = rd.xz * rsqrt(max(dot(rd.xz, rd.xz), 1e-8));
        float d = max(dot(hd, s.sunH), 0.0);
        c = mix(c, s.rise.rgb, s.rise.a * d * d * (1.0 - smoothstep(0.0, 0.5, h)));
    }
    return c;
}

// The sun: sun.png on a square thirty units wide at a hundred, as the game
// draws it, added to the sky.
static inline float3 lpSun(texture2d_array<float> skins, float3 rd, LpSky s, float pxA) {
    const float R = 0.15;
    float d = dot(rd, s.L);
    if (d <= 0.5) return float3(0.0);
    float3 ex = normalize(cross(float3(0.0, 1.0, 0.0), s.L));
    float3 ey = cross(s.L, ex);
    float2 q = float2(dot(rd, ex), dot(rd, ey)) / d;
    if (any(abs(q) >= R)) return float3(0.0);
    float2 px = (q / R * 0.5 + 0.5) * MCS_ENVIRONMENT_CELESTIAL_SUN_SIZE;
    float wpx = pxA / d / (2.0 * R) * MCS_ENVIRONMENT_CELESTIAL_SUN_SIZE.x;
    return mcSkin(skins, MCS_ENVIRONMENT_CELESTIAL_SUN, px, wpx).rgb;
}

// The game's cloud layer: clouds.png, one texel a 12-block cell, 4 blocks
// thick, drifting.
constant float LP_CLOUD_S = 12.0;
constant float LP_CLOUD_T = 4.0;

static inline bool lpCloudAt(texture2d_array<float> maps, float2 cc, float2 o) {
    return mcMap(maps, MCM_ENVIRONMENT_CLOUDS, glmod2(cc + o, 256.0) + 0.5, 0.0).a > 0.5;
}

// Seen from below: the bottom face of the cell overhead, or else the first
// side face the ray meets on its way up through the slab. Returns (face
// shade, alpha): the game's 0.7 under, 0.9 and 0.8 on the sides, 0.8 opaque.
static inline float2 lpClouds(texture2d_array<float> maps, float3 ro, float3 rd, float time, float s0, float pxA) {
    if (rd.y <= 0.01) return float2(0.0);
    float tB = (LP_CLOUD - ro.y) / rd.y;
    float fade = 0.8 * (1.0 - smoothstep(150.0, 460.0, tB));
    if (fade <= 0.0) return float2(0.0);
    float2 o = floor(float2(fract(s0 * 7.7), fract(s0 * 3.1)) * 256.0);
    float2 wind = float2(time * 0.6, 0.0);
    float2 q = (ro.xz + rd.xz * tB + wind) / LP_CLOUD_S;
    float2 cc = floor(q), f = q - cc;
    if (lpCloudAt(maps, cc, o)) {
        // Antialias the bottom face's edge where it meets sky.
        float fw = tB * pxA / max(rd.y, 0.05) / LP_CLOUD_S;
        float2 de = min(f, 1.0 - f);
        float2 so = select(float2(-1.0), float2(1.0), f > 0.5);
        float ex = lpCloudAt(maps, cc + float2(so.x, 0.0), o) ? 1.0 : smoothstep(0.0, fw, de.x);
        float ez = lpCloudAt(maps, cc + float2(0.0, so.y), o) ? 1.0 : smoothstep(0.0, fw, de.y);
        return float2(0.7, fade * min(saturate(ex * 2.0), saturate(ez * 2.0)));
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
        if (lpCloudAt(maps, cc, o)) return float2(xs ? 0.9 : 0.8, fade);
    }
    return float2(0.0);
}

// --- Shading a hit. -------------------------------------------------------------

// Past the traced reach, the land is drawn flat: the ray meets a plane just
// above the sea and takes the top face the world has there, lit like one,
// fading into the fog. Everything traced fades into this rather than into
// sky, so the disc stays whole out to the horizon while the trace stays short.
static inline float3 lpFarLand(float3 ro, float3 rd, LpSky sky, LpWorld w, float far, float pxA,
                               float time, texture2d_array<float> tiles, texture2d_array<float> maps) {
    float3 skyC = lpSkyColor(rd, sky);
    if (rd.y >= -1e-4) return skyC;
    float tP = (LP_SEA + 1.0 - ro.y) / rd.y;
    float3 hp = ro + rd * tP;
    float2 cell = floor(hp.xz);
    // One column, read directly: no cell to build for a single lookup.
    float2 p = cell + 0.5;
    float2 zd = lpPathZD(p.x, w);
    float4 path = float4(zd.x, rsqrt(1.0 + zd.y * zd.y), 0.0, lpTempAt(p.x, w));
    path.z = LP_SEA + 4.0;   // the path's height barely shows this far out
    LpCol col = lpColumnN(cell, path, valueNoise(lpSt1(p, w)), valueNoise(lpSt2(p, w)));
    float fp = tP * pxA / max(-rd.y, 0.1);
    int kind = lpTopKind(col, lpBiomeAt(col, cell));
    float3 c = kind == K_WATER
        ? lpWater(tiles, fract(hp.xz), fp, time, col.G - col.H, cell, fract(hp.xz), fp, sky.day)
        : lpTopColor(tiles, kind, cell, fract(hp.xz), fp, lpGrassTint(maps, col.temp));
    c *= sky.lit;
    return mix(c, lpFogCol(rd, sky), smoothstep(far * 0.5, far * 3.0, tP));
}

// Smooth lighting at a corner: the game's 0.2 a solid neighbour, a corner
// boxed in on both sides as dark as it gets.
static inline float lpVertexAO(float s1, float s2) {
    float occ = (s1 > 0.5 && s2 > 0.5) ? 3.0 : s1 + s2;
    return 1.0 - 0.2 * occ;
}

static inline float3 lpShade(LpHit h, float3 ro, float3 rd, float pxA, float far, LpSky sky, LpWorld w,
                             float time, texture2d_array<float> tiles, texture2d_array<float> maps,
                             bool deepLeaf, bool walked, float3 leafTexel) {
    float3 p = ro + rd * h.t;
    float3 n = h.n;
    float fp = h.t * pxA / max(abs(dot(rd, n)), 0.1);
    // Fog: the traced world fades into the flat far land (or, above the
    // horizon, the sky) of its own direction. Above the horizon it holds off
    // longer: that is the silhouette. Smooth lighting and plants are left out
    // where it has mostly taken over.
    float fog = smoothstep(far * (rd.y > 0.0 ? 0.8 : 0.5), far, h.t);
    if (deepLeaf) fp = 1.0;     // the texture's mean
    bool top = n.y > 0.5, bottom = n.y < -0.5;
    float2 uv = lpFaceUV(p, n);
    float tp = h.col.temp;
    LpBiome b = lpBiomeAt(h.col, h.cell);
    float ao = 1.0;
    float3 lit = sky.lit;
    float4 plant = float4(0.0, 0.0, 0.0, 1e9);
    LpCell cc = h.cc;
    float2 clim = lpClimate(tp);

    // Choose the face's texture first and sample it once below: a SIMD group
    // that straddles tops, sides and leaves then waits on one fetch, not on
    // one per kind of face.
    int layer = MC_DIRT;
    float3 tint = float3(1.0);
    bool grassSide = false, water = false, oakTint = false, grassTop = false;
    if (h.what == 1) {
        LpTree tr = h.tree;
        float vy = floor(p.y - n.y * 0.5);
        if (tr.kind == 3) {
            // The cactus model is inset a texel; its texture's clear border is that inset.
            uv = clamp(uv, 1.0 / 16.0, 15.0 / 16.0);
            layer = top ? MC_CACTUS_TOP : MC_CACTUS_SIDE;
        } else if (vy < h.logTop) {
            layer = lpLogLayer(tr.kind, top || bottom);
        } else {
            float lt;
            float2 span = lpTreeSpan(tr, h.cell, lt);
            if (top && tr.kind == 2 && b.cold && p.y > span.y - 0.5) {
                layer = MC_SNOW;                                  // snow lies on the crown
                walked = false;
            } else {
                layer = lpLeafLayer(tr.kind);
                oakTint = tr.kind != 2 && tr.kind != 4;
                tint = oakTint ? float3(1.0) : lpLeafTint(maps, tr.kind, tp);
            }
        }
    } else {
        float H = h.col.H, G = h.col.G;
        int kind = lpTopKind(h.col, b);
        if (top) {
            water = kind == K_WATER;
            if (fog < 0.7) {
            layer = lpTopLayer(kind);
            if (kind == K_GRASS) { grassTop = true; uv = lpTurn(uv, hash21(h.cell * 0.917 + 0.2)); }
            // Smooth lighting: a step up beside the face darkens its corners.
            // Only the nearer neighbour on each axis is looked up: the far
            // one's corners fade out across the face toward this point, and
            // a trench one block wide is all that it would change.
            float2 f = fract(p.xz);
            float2 sn = select(float2(-1.0), float2(1.0), f > 0.5);
            float ox = lpColumnNear(h.cell + float2(sn.x, 0.0), cc, w).G > G + 0.5 ? 1.0 : 0.0;
            float oz = lpColumnNear(h.cell + float2(0.0, sn.y), cc, w).G > G + 0.5 ? 1.0 : 0.0;
            float sx0 = sn.x < 0.0 ? ox : 0.0, sx1 = sn.x > 0.0 ? ox : 0.0;
            float sz0 = sn.y < 0.0 ? oz : 0.0, sz1 = sn.y > 0.0 ? oz : 0.0;
            ao = mix(mix(lpVertexAO(sx0, sz0), lpVertexAO(sx1, sz0), f.x),
                     mix(lpVertexAO(sx0, sz1), lpVertexAO(sx1, sz1), f.x), f.y);
            // Under a crown the sky's light is one level down.
            float lt;
            float2 span = lpTreeSpan(h.tree, h.cell, lt);
            if (span.y > span.x && span.x > p.y) lit = mcLightmap(0.0, 14.0, sky.day, 0.0);
            }
        } else {
            float depth = H - p.y;    // below the column's top
            if (b.hot || b.beach)           layer = depth < 3.0 ? MC_SAND : MC_SANDSTONE;
            else if (b.peak && depth < 1.0) layer = MC_SNOW;
            else if (b.high || depth > 3.5) layer = MC_STONE;
            else if (depth >= 1.0)          layer = MC_DIRT;
            else if (h.col.path)            layer = MC_DIRT_PATH_SIDE;
            else if (b.cold)                layer = MC_GRASS_BLOCK_SNOW;
            else                            grassSide = true;
            // Smooth lighting at the foot of a step.
            if (fog < 0.7) {
                float Gf = lpColumnNear(h.cell + n.xz, cc, w).G;
                ao = mix(0.6, 1.0, saturate(p.y - Gf));
            }
        }
    }

    // The biome colour: the grass colormap, or the foliage one for oak leaves.
    float3 grassTint = oakTint ? mcFoliageTint(maps, clim.x, clim.y) : mcGrassTint(maps, clim.x, clim.y);
    if (oakTint || grassTop) tint = grassTint;
    float3 alb;
    if (water) {
        // The lake bed where the ray would reach it.
        float depth = h.col.G - h.col.H;
        float3 pb = p + rd * (depth / max(-rd.y, 0.05));
        alb = lpWater(tiles, uv, fp, time, depth, floor(pb.xz), fract(pb.xz),
                      (h.t + depth) * pxA / max(-rd.y, 0.1), sky.day);
    } else if (grassSide) {
        alb = mcGrassSide(tiles, uv, fp, grassTint);
    } else {
        // A leaf the walk stopped on is already sampled.
        alb = (walked ? leafTexel : mcTile(tiles, layer, uv, fp).rgb) * tint;
    }
    if (h.what == 0 && top && (grassTop || layer == MC_SAND) && h.t * pxA * 16.0 < 1.5 && fog < 0.7)
        plant = lpPlants(h, ro, rd, pxA, w, tiles, grassTint);

    float3 col = alb * (mcFaceShade(n) * ao) * lit;
    if (plant.w < 1e9) col = plant.rgb * lit;

    if (fog > 0.0) col = mix(col, lpFarLand(ro, rd, sky, w, far, pxA, time, tiles, maps), fog);
    return col;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
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
    int steps = int(float(LP_STEPS) * reach);

    // Trace; a ray that slips through a leaf's clear texels and out of the
    // crown is traced on from where it left, once, on a quarter of the
    // budget, when it is going down onto the ground just under the crown. One
    // going up is out past the crown into the sky: in this projection the
    // crowns stand out of the rim against it.
    LpHit h;
    float t0 = 0.0;
    bool deepLeaf = false, walked = false;
    float3 leafTexel = float3(0.0);
    for (int pass = 0; pass < 2; ++pass) {
        h = lpTrace(ro + rd * t0, rd, far - t0, pass == 0 ? steps : steps / 4, w);
        if (h.what < 0) break;
        h.t += t0;
        if (h.what != 1 || h.tree.kind == 3) break;
        float3 p = ro + rd * h.t;
        if (floor(p.y - h.n.y * 0.5) < h.logTop) break;      // a log
        if (pass == 1) { deepLeaf = true; break; }            // a second crown: its mean colour
        float3 v;
        float lt = h.logTop;
        int r = lpLeafWalk(h.tree, ro, rd, pxA, mcTiles, h.t, h.n, v, lt, deepLeaf, leafTexel);
        walked = r == 0 && !deepLeaf;
        if (r < 2) { h.cell = v.xz; h.logTop = lt; break; }
        h.what = -1;
        if (rd.y > 0.0) break;      // out past the crown into the sky
        t0 = h.t + 1e-3;
    }

    LpSky sky = lpSkyFor(u.hour, seed * TWO_PI + 0.9);
    float3 col;
    if (h.what >= 0) {
        col = lpShade(h, ro, rd, pxA, far, sky, w, u.time, mcTiles, mcMaps, deepLeaf, walked, leafTexel);
    } else {
        col = lpFarLand(ro, rd, sky, w, far, pxA, u.time, mcTiles, mcMaps);
        col += lpSun(mcSkins, rd, sky, pxA);
        float2 cl = lpClouds(mcMaps, ro, rd, u.time, seed, pxA);
        float cb = sky.day;
        col = mix(col, float3(cb * 0.9 + 0.1, cb * 0.9 + 0.1, cb * 0.85 + 0.15) * cl.x, cl.y);
    }

    // The textures and the game's colours are already display values.
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
