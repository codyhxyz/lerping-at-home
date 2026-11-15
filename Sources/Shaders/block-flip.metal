// Block Flip — original work for Lerping@Home, not a port. Drawn with the
// game's own block textures (`lerp-requires: minecraft`); nothing hand-drawn.
//
// A kinetic wall of dyed blocks. Each block is two slabs back to back, the
// front one the block of the picture on show and the back one the block of
// the picture to come. Every fifteen seconds or so a wave runs across the
// wall — out from a point, in towards one, round like a clock hand, row by
// row like a typewriter, as a scattered dissolve or along a wandering noise
// front — and each block it reaches lifts out, flips over and settles to the
// depth the new picture asks of it. The wall is a bas-relief as well as a
// picture: bright blocks stand proud, grout and backgrounds sit back.
//
// The pictures are the library's Abstract, Gradients and Patterns shelves
// rebuilt the way players build pixel art: an ordered-dithered gradient
// stepped like terrain, concentric rings as a ziggurat, halftone dots of
// raised blocks, a spiral, a Voronoi mosaic with sunken black grout, stacked
// sine waves — each in wool, concrete, concrete powder or terracotta in one
// of eight ramps of the game's sixteen dyes — plus rings of glazed
// terracotta laid in 2×2 pinwheels, and a field of redstone lamps that switch
// on (and push forward) as pulses run out through it. The board behind is
// polished blackstone. Shading is the game's: 1 / 0.8 / 0.6 / 0.5 by face,
// darkened in the corners, lit lamps full bright.
//
// The flips alternate between turning about the vertical and the horizontal,
// and a block shrinks as it turns so that its corners never leave its own
// cell. That opens a dark gap onto the board behind a turning block, and
// lets each pixel be drawn exactly by a short walk through the cells under
// it.
//
// lerp-category: Minecraft
// lerp-requires: minecraft
//
// lerp-param: rows    float 10 48   = 22  "Rows of blocks"
// lerp-param: speed   float 0.25 3  = 1   "Speed"
// lerp-param: relief  float 0 1     = 0.5 "Relief"
// lerp-param: yaw     float -50 50  = 0   "Turn"
// lerp-param: pitch   float -35 35  = 0   "Tilt"
// lerp-param: magnify float -1 1    = 0   "Zoom"
//
// lerp-preset: Close  rows=12
// lerp-preset: Mosaic rows=40, speed=0.7

constant float MF_FOCAL   = 2.2;    // ~49° on the short axis: a little perspective
constant float MF_PERIOD  = 15.0;   // one picture, wave included
constant float MF_SPREAD  = 8.0;    // how long a wave takes to cross the wall
constant float MF_TURN    = 2.4;    // one block's flip
constant float MF_POP     = 0.36;   // how far a flipping block lifts out
constant float MF_RELIEF  = 0.64;   // the deepest relief, at relief = 1
constant float MF_BACK    = -0.56;  // the dark board behind the blocks
constant int   MF_STEPS   = 7;      // cells walked per ray
constant int   MF_SAMPLES = 4;      // rotated-grid supersampling

// ---------------------------------------------------------------------------
// Dyes and blocks. The game's sixteen dyes, in this file's order: white,
// light grey, grey, black, brown, red, orange, yellow, lime, green, cyan,
// light blue, blue, purple, magenta, pink. Each picture is built in one of
// the dyed blocks the game has in all sixteen.

constant int MF_WOOL = 0, MF_CONCRETE = 1, MF_POWDER = 2, MF_TERRACOTTA = 3, MF_GLAZED = 4,
             MF_LAMP = 5;

constant int MF_BLOCKS[80] = {
    // wool
    MC_WHITE_WOOL, MC_LIGHT_GRAY_WOOL, MC_GRAY_WOOL, MC_BLACK_WOOL,
    MC_BROWN_WOOL, MC_RED_WOOL, MC_ORANGE_WOOL, MC_YELLOW_WOOL,
    MC_LIME_WOOL, MC_GREEN_WOOL, MC_CYAN_WOOL, MC_LIGHT_BLUE_WOOL,
    MC_BLUE_WOOL, MC_PURPLE_WOOL, MC_MAGENTA_WOOL, MC_PINK_WOOL,
    // concrete
    MC_WHITE_CONCRETE, MC_LIGHT_GRAY_CONCRETE, MC_GRAY_CONCRETE, MC_BLACK_CONCRETE,
    MC_BROWN_CONCRETE, MC_RED_CONCRETE, MC_ORANGE_CONCRETE, MC_YELLOW_CONCRETE,
    MC_LIME_CONCRETE, MC_GREEN_CONCRETE, MC_CYAN_CONCRETE, MC_LIGHT_BLUE_CONCRETE,
    MC_BLUE_CONCRETE, MC_PURPLE_CONCRETE, MC_MAGENTA_CONCRETE, MC_PINK_CONCRETE,
    // concrete powder
    MC_WHITE_CONCRETE_POWDER, MC_LIGHT_GRAY_CONCRETE_POWDER, MC_GRAY_CONCRETE_POWDER, MC_BLACK_CONCRETE_POWDER,
    MC_BROWN_CONCRETE_POWDER, MC_RED_CONCRETE_POWDER, MC_ORANGE_CONCRETE_POWDER, MC_YELLOW_CONCRETE_POWDER,
    MC_LIME_CONCRETE_POWDER, MC_GREEN_CONCRETE_POWDER, MC_CYAN_CONCRETE_POWDER, MC_LIGHT_BLUE_CONCRETE_POWDER,
    MC_BLUE_CONCRETE_POWDER, MC_PURPLE_CONCRETE_POWDER, MC_MAGENTA_CONCRETE_POWDER, MC_PINK_CONCRETE_POWDER,
    // terracotta
    MC_WHITE_TERRACOTTA, MC_LIGHT_GRAY_TERRACOTTA, MC_GRAY_TERRACOTTA, MC_BLACK_TERRACOTTA,
    MC_BROWN_TERRACOTTA, MC_RED_TERRACOTTA, MC_ORANGE_TERRACOTTA, MC_YELLOW_TERRACOTTA,
    MC_LIME_TERRACOTTA, MC_GREEN_TERRACOTTA, MC_CYAN_TERRACOTTA, MC_LIGHT_BLUE_TERRACOTTA,
    MC_BLUE_TERRACOTTA, MC_PURPLE_TERRACOTTA, MC_MAGENTA_TERRACOTTA, MC_PINK_TERRACOTTA,
    // glazed terracotta
    MC_WHITE_GLAZED_TERRACOTTA, MC_LIGHT_GRAY_GLAZED_TERRACOTTA, MC_GRAY_GLAZED_TERRACOTTA, MC_BLACK_GLAZED_TERRACOTTA,
    MC_BROWN_GLAZED_TERRACOTTA, MC_RED_GLAZED_TERRACOTTA, MC_ORANGE_GLAZED_TERRACOTTA, MC_YELLOW_GLAZED_TERRACOTTA,
    MC_LIME_GLAZED_TERRACOTTA, MC_GREEN_GLAZED_TERRACOTTA, MC_CYAN_GLAZED_TERRACOTTA, MC_LIGHT_BLUE_GLAZED_TERRACOTTA,
    MC_BLUE_GLAZED_TERRACOTTA, MC_PURPLE_GLAZED_TERRACOTTA, MC_MAGENTA_GLAZED_TERRACOTTA, MC_PINK_GLAZED_TERRACOTTA,
};

// Ramps of dyes, dark to light.
constant int MF_RAMPS[40] = {
    3, 13, 14,  6,  7,   // dusk
    3, 12, 10, 11,  0,   // tide
    3,  4,  9,  8,  7,   // moss
    3,  4,  5,  6,  7,   // ember
    3, 12, 13, 14, 15,   // berry
    3,  2, 10,  1,  0,   // slate
    3, 12, 10,  8,  7,   // lagoon
    3,  4,  5, 15,  0,   // rose
};

constant float MF_BAYER[16] = {
     0.0 / 16.0,  8.0 / 16.0,  2.0 / 16.0, 10.0 / 16.0,
    12.0 / 16.0,  4.0 / 16.0, 14.0 / 16.0,  6.0 / 16.0,
     3.0 / 16.0, 11.0 / 16.0,  1.0 / 16.0,  9.0 / 16.0,
    15.0 / 16.0,  7.0 / 16.0, 13.0 / 16.0,  5.0 / 16.0,
};

static inline int mfBlock(int fam, int ramp, int i) {
    return MF_BLOCKS[fam * 16 + MF_RAMPS[ramp * 5 + clamp(i, 0, 4)]];
}

// An integer hash for anything laid out on the grid (cells, texels): the
// prelude's float hashes fall into stripes on integer lattices.
static inline float mfIHash(float2 p, float k) {
    uint2 q = uint2(int2(p) + 65536);
    uint h = q.x * 1597334677u ^ q.y * 3812015801u ^ uint(int(k) + 65536) * 2654435761u;
    h = (h ^ (h >> 16)) * 2246822519u;
    h = (h ^ (h >> 13)) * 3266489917u;
    h ^= h >> 16;
    return float(h) * (1.0 / 4294967296.0);
}

// ---------------------------------------------------------------------------
// Time and seed, shared by every cell.

// What a picture is, fixed for the whole picture: worked out once a pixel
// for the two pictures in play, not once per cell visited.
struct MfPicParams {
    int prog, ramp, mat;
    float h1, h2, h3, h4;
    float2 C;
};

struct MfCtx {
    MfPicParams pa, pb;     // pictures k and k+1
    int shape;              // transition k's wave
    float wh1, wh2, jkey;
    float2 wC;
    float k;        // index of the picture the wall is flipping away from
    float lt;       // seconds into this picture's period
    float tt;       // scaled time
    float salt;     // per-launch offset for every hash
    float half_;    // half the rows: cells per picture unit
    float relief;   // world depth of a full relief step
    float2 ext;     // visible half-extent of the wall, in picture units
    float fog;      // distance at which the wall has faded out
};

static inline float mfHash(float a, float b, float salt) {
    return hash21(float2(a * 1.618 + 0.37 * b + 3.1, salt + b * 7.13));
}

static inline MfPicParams mfParams(float m, float salt, float2 ext) {
    MfPicParams pp;
    pp.h1 = mfHash(m, 1.0, salt); pp.h2 = mfHash(m, 2.0, salt);
    pp.h3 = mfHash(m, 3.0, salt); pp.h4 = mfHash(m, 4.0, salt);
    pp.prog = int(glmod(m * 3.0 + floor(salt * 8.0), 8.0));
    pp.ramp = int(glmod(m * 5.0 + floor(fract(salt * 7.3) * 8.0), 8.0));
    pp.mat = int(pp.h4 * 3.999);   // wool, concrete, powder or terracotta
    pp.C = (float2(pp.h1, pp.h2) - 0.5) * ext * 1.1;
    return pp;
}

// When, from 0 to 1 of the spread, the wave of transition k reaches a cell.
static inline float mfDelay(float2 cell, MfCtx c) {
    float2 P = (cell + 0.5) / c.half_;
    float h1 = c.wh1, h2 = c.wh2;
    float2 C = c.wC;
    float jitter = mfIHash(cell, c.jkey);
    float d;
    switch (c.shape) {
    case 0: {   // out from a point
        d = length(P - C) / length(c.ext + abs(C));
        break;
    }
    case 1: {   // in towards a point
        d = 1.0 - length(P - C) / length(c.ext + abs(C));
        break;
    }
    case 2: {   // a straight front at any angle
        float a = h1 * TWO_PI;
        float2 n = float2(cos(a), sin(a));
        float e = abs(n.x) * c.ext.x + abs(n.y) * c.ext.y;
        d = (dot(P, n) + e) / (2.0 * e);
        break;
    }
    case 3: {   // a clock hand round a point
        float2 q = P - C;
        d = fract(atan2(q.y, q.x) / TWO_PI + h2);
        break;
    }
    case 4:     // a scattered dissolve
        return jitter;
    case 5: {   // square rings out from a point
        float2 q = abs(P - C) / (c.ext + abs(C));
        d = max(q.x, q.y);
        break;
    }
    case 6:     // a wandering noise front
        d = 0.5 + 0.55 * snoise(P * 0.8 + float2(h1, h2) * 40.0);
        break;
    default: {  // typewriter: rows top to bottom, each left to right
        float rows = 2.0 * c.ext.y * c.half_;
        float row = clamp(floor(c.ext.y * c.half_ - cell.y - 0.5), 0.0, rows - 1.0);
        float col = clamp((P.x + c.ext.x) / (2.0 * c.ext.x), 0.0, 1.0);
        return (row + col) / rows;
    }
    }
    return clamp(d, 0.0, 1.0) * 0.93 + 0.07 * jitter;
}

// ---------------------------------------------------------------------------
// Pictures. One per index m, evaluated per cell: a dye, a material and how
// proud the block stands. Texel detail (lamps, glazed tiles) comes later.

struct MfPic {
    int   layer;    // the block's texture in mcTiles
    float hgt;      // 0..1 of the relief
    float rot;      // quarter turns of the face (glazed terracotta)
    bool  lit;      // a lit redstone lamp: full bright, whatever the shading
};

static MfPic mfPic(float m, float2 cell, MfCtx c) {
    float2 P = (cell + 0.5) / c.half_;
    MfPicParams pp = m == c.k ? c.pa : c.pb;
    float h1 = pp.h1, h2 = pp.h2, h3 = pp.h3, h4 = pp.h4;
    int prog = pp.prog, ramp = pp.ramp, fam = pp.mat;
    float bay = MF_BAYER[int(glmod(cell.x, 4.0)) + 4 * int(glmod(cell.y, 4.0))];
    float2 C = pp.C;

    MfPic s;
    s.rot = 0.0;
    s.lit = false;
    int idx = 0;            // ramp entry, also the relief step
    switch (prog) {
    case 0: {   // dithered gradient, stepped like terrain
        float a = h1 * TWO_PI;
        float v = 0.5 + 0.30 * dot(P, float2(cos(a), sin(a))) / max(c.ext.x, 1.0)
                + 0.30 * snoise(P * 0.7 + h2 * 60.0);
        float x = clamp(v, 0.0, 1.0) * 3.999;
        idx = int(x) + (fract(x) > bay ? 1 : 0);
        s.hgt = floor(x + 0.5) * 0.25;
        break;
    }
    case 1: {   // concentric rings as a ziggurat
        float w = 0.15 + 0.10 * h3;
        int k = int(glmod(floor(length(P - C) / w) + floor(h4 * 6.0), 6.0));
        idx = k < 4 ? k + 1 : 7 - k;
        s.hgt = float(idx - 1) / 3.0;
        break;
    }
    case 2: {   // halftone dots of raised blocks
        float L = 0.58 + 0.20 * h3;
        float2 q = rotate(P, h1 * 1.57) / L;
        float2 lc = q - floor(q) - 0.5;
        float2 dotP = rotate((floor(q) + 0.5) * L, -h1 * 1.57);
        float f = 0.5 + 0.5 * snoise(dotP * 0.55 + h2 * 30.0);
        bool inDot = length(lc) < mix(0.16, 0.48, f);
        idx = inDot ? (f > 0.5 ? 4 : 3) : 1;
        s.hgt = inDot ? 1.0 : 0.0;
        break;
    }
    case 3: {   // spiral arms
        float2 q = P - C * 0.5;
        float arms = 2.0 + floor(h3 * 2.0);
        float v = atan2(q.y, q.x) / TWO_PI * arms + log(length(q) + 0.04) * (0.9 + 0.5 * h4);
        idx = 1 + int(fract(v) * 4.0);
        s.hgt = float(idx - 1) / 3.0;
        break;
    }
    case 4: {   // Voronoi mosaic with sunken black grout
        float g = 1.6 + 0.9 * h3;
        float2 q = P * g + h1 * 17.0;
        float2 iq = floor(q);
        float d1 = 9.0, d2 = 9.0;
        float2 id = float2(0.0);
        for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x) {
            float2 o = iq + float2(x, y);
            float2 sp = o + 0.15 + 0.7 * hash22(o + h2 * 9.0);
            float d = length(q - sp);
            if (d < d1) { d2 = d1; d1 = d; id = o; }
            else if (d < d2) { d2 = d; }
        }
        float r = mfIHash(id, 31.0 + m);
        bool grout = (d2 - d1) / g * c.half_ < 0.8;
        idx = grout ? 0 : 1 + int(r * 3.999);
        s.hgt = grout ? 0.0 : 0.35 + 0.65 * mfIHash(id, 47.0 + m);
        break;
    }
    case 5: {   // stacked sine waves
        float2 q = rotate(P, (h1 - 0.5) * 0.8);
        float y = q.y + (0.10 + 0.08 * h3) * sin(q.x * (2.2 + 1.5 * h2) + h4 * 6.0)
                      + 0.05 * sin(q.x * 5.3 + h1 * 9.0);
        int k = int(glmod(floor(y / 0.17), 6.0));
        idx = k < 4 ? k + 1 : 7 - k;
        s.hgt = float(idx - 1) / 3.0;
        break;
    }
    case 6: {   // redstone lamps, rings of them switching on as a pulse runs out
        float ph = length(P - C) * 5.0 - c.tt * 1.1 + h3 * 6.0;
        float b = pow(0.5 + 0.5 * cos(ph), 4.0);
        s.lit = b > 0.3;
        s.layer = s.lit ? MC_REDSTONE_LAMP_ON : MC_REDSTONE_LAMP;
        s.hgt = 0.6 * b;
        return s;
    }
    default: {  // glazed terracotta, laid in 2×2 pinwheels, in rings of colour
        float2 grp = floor(cell * 0.5);
        float w = 0.16 + 0.10 * h3;
        float2 G = (grp * 2.0 + 1.0) / c.half_;
        int k = int(glmod(floor(length(G - C) / w) + floor(h4 * 6.0), 6.0));
        idx = k < 4 ? k + 1 : 7 - k;
        // Which quarter turn each of the four takes: two different pinwheels.
        int q = int(glmod(cell.x, 2.0)) + 2 * int(glmod(cell.y, 2.0));
        const float spinA[4] = { 0.0, 1.0, 3.0, 2.0 };
        const float spinB[4] = { 2.0, 3.0, 1.0, 0.0 };
        s.rot = h2 > 0.5 ? spinA[q] : spinB[q];
        s.hgt = float(idx - 1) / 6.0;
        fam = MF_GLAZED;
        break;
    }
    }
    s.layer = mfBlock(fam, ramp, idx);
    return s;
}

// The face of a block: its real texture, upright in the orientation it rests
// in (uv 0..1, v up), turned for glazed terracotta. `fp` is the width of a
// screen pixel on the face, in faces.
static float3 mfFace(MfPic pic, float2 uv, float fp, texture2d_array<float> mcTiles) {
    float2 t = float2(uv.x, 1.0 - uv.y);
    int r = int(pic.rot);
    if (r == 1) t = float2(t.y, 1.0 - t.x);
    else if (r == 2) t = 1.0 - t;
    else if (r == 3) t = float2(1.0 - t.y, t.x);
    return mcTile(mcTiles, pic.layer, t, fp).rgb;
}

// ---------------------------------------------------------------------------
// A block's pose during transition k.

struct MfPose {
    float p;        // 0..1 through its flip
    float z;        // lift of its centre
    float h;        // half size
    float axisX;    // 1 when this transition flips about x, 0 about y
    float cs, sn;   // cos and sin of the flip angle
};

// Only the pictures a block is between are evaluated: one at rest, both
// while it flips.
static MfPose mfPoseAt(float2 cell, MfCtx c) {
    // Once the wave has passed everywhere, no cell needs its delay.
    float x = c.lt >= MF_SPREAD + MF_TURN ? 1.0
            : clamp((c.lt - mfDelay(cell, c) * MF_SPREAD) / MF_TURN, 0.0, 1.0);
    float p = x * x * x * (x * (6.0 * x - 15.0) + 10.0);
    float hg = mfPic(p >= 1.0 ? c.k + 1.0 : c.k, cell, c).hgt;
    if (p > 0.0 && p < 1.0) hg = mix(hg, mfPic(c.k + 1.0, cell, c).hgt, p);
    MfPose o;
    o.p = p;
    float th = p * PI;
    o.cs = cos(th); o.sn = sin(th);
    o.h = 0.5 / (abs(o.cs) + abs(o.sn));
    o.z = hg * c.relief + MF_POP * o.sn;
    // Flips alternate about y (even k) and x (odd k). Each flip is drawn in
    // its own frame, the block as it stood before it; the picture coming in
    // is laid on the back slab the way up it will rest.
    o.axisX = glmod(c.k, 2.0);
    return o;
}

// World to the block's own frame (and back, with the transpose).
static inline float3 mfToLocal(float3 w, MfPose o) {
    float cs = o.cs, sn = o.sn;
    if (o.axisX > 0.5) return float3(w.x, w.y * cs + w.z * sn, -w.y * sn + w.z * cs);
    return float3(w.x * cs - w.z * sn, w.y, w.x * sn + w.z * cs);
}
static inline float3 mfToWorld(float3 l, MfPose o) {
    float cs = o.cs, sn = o.sn;
    if (o.axisX > 0.5) return float3(l.x, l.y * cs - l.z * sn, l.y * sn + l.z * cs);
    return float3(l.x * cs + l.z * sn, l.y, -l.x * sn + l.z * cs);
}

static inline float mfBoxSdf(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// How open the space just off a surface is, from the neighbouring blocks
// and the board behind: dark crevices, no rays cast. A point is within
// reach of only the nearer neighbour in x and the nearer in y, so those two
// are the only ones asked.
static float mfOcclusion(float3 P, float3 n, float2 cell, thread const MfPose* nb,
                         thread const float2* nd) {
    float occ = 0.0;
    float3 s1 = P + n * 0.12, s2 = P + n * 0.32;
    for (int i = 0; i < 2; ++i) {
        MfPose o = nb[i];
        float3 ctr = float3(cell + nd[i] + 0.5, o.z);
        float3 b = float3(o.h);
        occ += clamp(0.12 - mfBoxSdf(mfToLocal(s1 - ctr, o), b), 0.0, 0.12) / 0.12 * 0.5;
        occ += clamp(0.32 - mfBoxSdf(mfToLocal(s2 - ctr, o), b), 0.0, 0.32) / 0.32 * 0.5;
    }
    occ += clamp(0.32 - (s2.z - MF_BACK), 0.0, 0.32) / 0.32 * 0.4;
    return 1.0 - 0.6 * clamp(occ, 0.0, 1.0);
}

// One ray's colour, and whether an edge may pass through its pixel (so the
// pixel needs the rest of its samples).
struct MfHit { float3 col; bool edge; float ao; };

// Turned far enough off square (only a drag does that), the wall fades into
// the dark with distance, the way a short view distance does.
// `aoIn` < 0 works out occlusion and the edge test; otherwise the pixel's
// first sample already did, and its occlusion is reused.
static MfHit mfScene(float3 ro, float3 rd, float pxAngle, MfCtx c, float aoIn,
                     texture2d_array<float> mcTiles, thread float& tOut);

static MfHit mfScene(float3 ro, float3 rd, float pxAngle, MfCtx c, float aoIn,
                     texture2d_array<float> mcTiles) {
    float t;
    MfHit r = mfScene(ro, rd, pxAngle, c, aoIn, mcTiles, t);
    r.col = mix(r.col, MC_FOG_DAY, smoothstep(0.55, 1.0, t / c.fog));
    return r;
}

static MfHit mfScene(float3 ro, float3 rd, float pxAngle, MfCtx c, float aoIn,
                     texture2d_array<float> mcTiles, thread float& tOut) {
    MfHit res;
    float zTop = 0.5 + c.relief + (c.lt < MF_SPREAD + MF_TURN ? MF_POP : 0.0) + 0.01;
    float rz = min(rd.z, -1e-3);
    float t0 = max((zTop - ro.z) / rz, 0.0);
    float t1 = (MF_BACK - ro.z) / rz;
    float3 p0 = ro + rd * t0;
    float2 cell = floor(p0.xy);
    float2 rxy = float2(abs(rd.x) < 1e-6 ? 1e-6 : rd.x, abs(rd.y) < 1e-6 ? 1e-6 : rd.y);
    float2 stp = sign(rxy);
    float2 tDelta = abs(1.0 / rxy);
    float2 tMax = t0 + (cell + max(stp, 0.0) - p0.xy) / rxy;

    bool hit = false;
    float tHit = t1;
    float3 nl = float3(0.0), pl = float3(0.0);
    MfPose pose;
    for (int i = 0; i < MF_STEPS; ++i) {
        MfPose o = mfPoseAt(cell, c);
        float3 lo = mfToLocal(ro - float3(cell + 0.5, o.z), o);
        float3 ld = mfToLocal(rd, o);
        float3 inv = 1.0 / ld;
        float3 ta = (-o.h - lo) * inv, tb = (o.h - lo) * inv;
        float3 tn = min(ta, tb), tf = max(ta, tb);
        float tN = max(max(tn.x, tn.y), tn.z), tF = min(min(tf.x, tf.y), tf.z);
        if (tN < tF && tF > 0.0) {
            hit = true; tHit = tN; pose = o;
            pl = lo + ld * tN;
            nl = step(tn.yzx, tn.xyz) * step(tn.zxy, tn.xyz) * -sign(ld);
            break;
        }
        float tNext = min(tMax.x, tMax.y);
        if (tNext > t1) break;
        if (tMax.x < tMax.y) { tMax.x += tDelta.x; cell.x += stp.x; }
        else                 { tMax.y += tDelta.y; cell.y += stp.y; }
    }

    float3 P = ro + rd * tHit;
    tOut = tHit;
    if (!hit) cell = floor(P.xy);
    float2 fr = P.xy - cell;
    float2 nd[2] = { float2(fr.x > 0.5 ? 1.0 : -1.0, 0.0), float2(0.0, fr.y > 0.5 ? 1.0 : -1.0) };
    bool full = aoIn < 0.0;
    MfPose nb[2];
    if (full) { nb[0] = mfPoseAt(cell + nd[0], c); nb[1] = mfPoseAt(cell + nd[1], c); }

    if (!hit) {
        // The board behind: polished blackstone, deep in the blocks' shade.
        // It only shows through a flipping block, so it is always near an
        // edge.
        res.ao = full ? mfOcclusion(P, float3(0, 0, 1), cell, nb, nd) : aoIn;
        float fpB = tHit * pxAngle / max(abs(rd.z), 0.2);
        float3 tex = mcTile(mcTiles, MC_POLISHED_BLACKSTONE, float2(fract(P.x), 1.0 - fract(P.y)), fpB).rgb;
        res.col = tex * 0.8 * 0.45 * res.ao;
        res.edge = true;
        return res;
    }

    float3 n = mfToWorld(nl, pose);
    float h = pose.h;
    // Local +z faces the viewer before the flip, so the front slab is local
    // z > 0 and shows picture k; the back slab shows k+1.
    bool bigFace = abs(nl.z) > 0.5;
    bool frontSlab = bigFace ? (nl.z > 0.0) : (pl.z > 0.0);
    float m = frontSlab ? c.k : c.k + 1.0;
    MfPic pic = mfPic(m, cell, c);
    // Texel coordinates upright in the orientation the face rests in.
    float2 uv;
    if (bigFace) {
        float2 sg = float2(1.0);
        if (!frontSlab) sg = pose.axisX > 0.5 ? float2(1.0, -1.0) : float2(-1.0, 1.0);
        uv = pl.xy * sg / h * 0.5 + 0.5;
    } else if (abs(nl.x) > 0.5) {
        uv = pl.zy / h * 0.5 + 0.5;
    } else {
        uv = pl.xz / h * 0.5 + 0.5;
    }
    uv = clamp(uv, 0.0, 0.9999);

    // One screen pixel on this face, in blocks and in faces (a turning block
    // is smaller than one).
    float pxWorld = tHit * pxAngle / max(abs(dot(n, rd)), 0.2);
    float3 tex = mfFace(pic, uv, pxWorld / (2.0 * h), mcTiles);

    // The game's fixed shading by face (top 1, bottom 0.5, z 0.8, x 0.6),
    // blended by the normal while a block turns, and its smooth-lighting
    // darkening in corners. A lit lamp is full bright.
    float3 n2 = n * n;
    float shade = n2.x * 0.6 + n2.z * 0.8 + n2.y * (n.y > 0.0 ? 1.0 : 0.5);
    float ao = full ? mfOcclusion(P, n, cell, nb, nd) : aoIn;
    res.ao = ao;
    res.col = pic.lit ? tex : tex * shade * ao;

    // Edge test. A point near its own face's border can have a silhouette
    // inside the pixel; so can a point a taller (or flipping) neighbour's
    // outline falls across. Blocks never leave their cells, so nothing else
    // can.
    float2 em = min(uv, 1.0 - uv) * 2.0 * h;
    bool edge = min(em.x, em.y) < 2.0 * pxWorld;
    float2 slope = abs(rd.xy / rz);
    for (int i = 0; i < 2 && !edge && full; ++i) {
        float rise = nb[i].z + 0.5 - P.z;
        if (rise <= 1e-3) continue;
        float2 d = nd[i];
        float toB = d.x > 0.0 ? cell.x + 1.0 - P.x : d.x < 0.0 ? P.x - cell.x
                  : d.y > 0.0 ? cell.y + 1.0 - P.y : P.y - cell.y;
        float reach = rise * (d.x != 0.0 ? slope.x : slope.y);
        edge = toB < reach + 2.0 * pxWorld;
    }
    res.edge = edge;
    return res;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]]) {
    float minRes = min(u.resolution.x, u.resolution.y);
    float half_ = 0.5 * u.rows;

    MfCtx c;
    c.tt = u.time * u.speed + 2.0;
    c.k = floor(c.tt / MF_PERIOD);
    c.lt = c.tt - c.k * MF_PERIOD;
    c.salt = u.seed * 97.0;
    c.half_ = half_;
    c.ext = float2(u.resolution.x / minRes, u.resolution.y / minRes);
    c.pa = mfParams(c.k, c.salt, c.ext);
    c.pb = mfParams(c.k + 1.0, c.salt, c.ext);
    c.shape = int(glmod(c.k * 5.0 + floor(c.salt * 8.0), 8.0));
    c.wh1 = mfHash(c.k, 11.0, c.salt);
    c.wh2 = mfHash(c.k, 12.0, c.salt);
    c.wC = (float2(c.wh1, c.wh2) - 0.5) * c.ext * 1.2;
    c.jkey = c.k * 7.0 + floor(c.salt * 100.0);
    c.relief = u.relief * MF_RELIEF;

    // A slow drift round the wall's centre, so the relief shows its depth.
    float dist = half_ * MF_FOCAL;
    float yawD = 0.32 * sin(0.029 * u.time + u.seed * 6.28);
    float pitD = 0.14 * sin(0.021 * u.time + u.seed * 3.1 + 1.0);
    float3 ro = dist * float3(sin(yawD) * cos(pitD), sin(pitD), cos(yawD) * cos(pitD));
    float3 fwd = normalize(-ro);
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 right = normalize(cross(fwd, upHint));
    lerpOrbit(u.yaw, u.pitch, u.magnify, float3(0.0), upHint, ro, right, fwd);
    c.fog = 2.6 * length(ro);
    float3 up = cross(right, fwd);
    float pxAngle = 2.0 / (minRes * MF_FOCAL);

    // One sample inside a face; the full rotated grid where an edge may be.
    const float2 grid[4] = { float2(0.125, 0.375), float2(0.375, -0.125),
                             float2(-0.125, -0.375), float2(-0.375, 0.125) };
    float2 uv0 = lerpUV(float4(pos.xy + grid[0], 0.0, 1.0), u.resolution);
    MfHit first = mfScene(ro, normalize(uv0.x * right + uv0.y * up + MF_FOCAL * fwd), pxAngle, c, -1.0, mcTiles);
    float3 col = first.col;
    if (first.edge) {
        for (int s = 1; s < MF_SAMPLES; ++s) {
            float2 uv = lerpUV(float4(pos.xy + grid[s], 0.0, 1.0), u.resolution);
            float3 rd = normalize(uv.x * right + uv.y * up + MF_FOCAL * fwd);
            col += mfScene(ro, rd, pxAngle, c, first.ao, mcTiles).col;
        }
        col /= float(MF_SAMPLES);
    }

    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
