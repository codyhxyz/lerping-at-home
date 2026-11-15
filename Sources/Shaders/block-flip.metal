// Block Flip — original work for Lerping@Home, not a port.
//
// A kinetic wall of blocks. Each block is two slabs glued back to back, the
// front one dyed for the picture on show and the back one for the picture
// to come. Every fifteen seconds or so a wave runs across the wall — out
// from a point, in towards one, round like a clock hand, row by row like a
// typewriter, as a scattered dissolve or along a wandering noise front —
// and each block it reaches lifts out, flips over and settles to the depth
// the new picture asks of it. The wall is a bas-relief as well as a
// picture: bright blocks stand proud, grout and backgrounds sit back, so it
// reads as a sculpture of cubes rather than a flat mosaic.
//
// The pictures are the library's Abstract, Gradients and Patterns shelves
// redrawn with nothing but blocks: an ordered-dithered gradient stepped like
// terrain, concentric rings as a ziggurat, halftone dots of raised blocks, a
// spiral, a Voronoi mosaic with sunken grout, stacked sine waves, a field of
// lamp blocks with pulses of light running through it (each lamp rising as
// it lights), and glazed tiles whose quarter-circle motifs join across the
// joints into Truchet meanders. Each picture takes one of eight dye ramps
// and is dyed into wool, concrete or terracotta: 16×16-texel procedural
// textures, faded to their average as a texel drops under a pixel so nothing
// crawls when the camera drifts.
//
// The flips alternate between turning about the vertical and the horizontal,
// and a block shrinks as it turns so that its corners never leave its own
// cell. That keeps the mechanism honest (a turning block opens a dark gap
// onto the board behind) and lets each pixel be drawn exactly by a short
// walk through the cells under it.
//
// lerp-category: Blocks
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
// Dyes and ramps. Sixteen dyes of my own mixing; each ramp runs dark to light.

constant float3 MF_DYES[16] = {
    float3(0.86, 0.86, 0.83),  // 0 white
    float3(0.55, 0.55, 0.52),  // 1 light grey
    float3(0.24, 0.26, 0.28),  // 2 grey
    float3(0.07, 0.07, 0.09),  // 3 black
    float3(0.42, 0.27, 0.16),  // 4 brown
    float3(0.62, 0.17, 0.15),  // 5 red
    float3(0.90, 0.46, 0.10),  // 6 orange
    float3(0.96, 0.77, 0.20),  // 7 yellow
    float3(0.45, 0.70, 0.11),  // 8 lime
    float3(0.30, 0.40, 0.13),  // 9 green
    float3(0.09, 0.52, 0.56),  // 10 cyan
    float3(0.25, 0.64, 0.85),  // 11 light blue
    float3(0.20, 0.22, 0.58),  // 12 blue
    float3(0.44, 0.18, 0.62),  // 13 purple
    float3(0.74, 0.27, 0.70),  // 14 magenta
    float3(0.93, 0.56, 0.66),  // 15 pink
};

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

static inline float3 mfDye(int ramp, int i) {
    float3 c = MF_DYES[MF_RAMPS[ramp * 5 + clamp(i, 0, 4)]];
    return pow(c, float3(2.2));
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
    pp.mat = int(pp.h4 * 2.999);
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
    float3 alb;
    float  hgt;     // 0..1 of the relief
    int    mat;     // 0 wool, 1 concrete, 2 terracotta, 3 lamp, 4 glazed tile
    int    ramp;
    float  glow;    // lamp brightness
    float3 lampCol;
    float  flip;    // glazed tile orientation
};

static MfPic mfPic(float m, float2 cell, MfCtx c) {
    float2 P = (cell + 0.5) / c.half_;
    MfPicParams pp = m == c.k ? c.pa : c.pb;
    float h1 = pp.h1, h2 = pp.h2, h3 = pp.h3, h4 = pp.h4;
    int prog = pp.prog, ramp = pp.ramp;
    float bay = MF_BAYER[int(glmod(cell.x, 4.0)) + 4 * int(glmod(cell.y, 4.0))];
    float2 C = pp.C;

    MfPic s;
    s.mat = pp.mat;
    s.ramp = ramp;
    s.glow = 0.0;
    s.lampCol = float3(0.0);
    s.flip = 0.0;
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
    case 4: {   // Voronoi mosaic with sunken grout
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
    case 6: {   // lamp blocks, pulses of light running out from a point
        float ph = length(P - C) * 5.0 - c.tt * 1.1 + h3 * 6.0;
        float b = pow(0.5 + 0.5 * cos(ph), 4.0);
        s.glow = b;
        s.lampCol = mix(float3(1.0, 0.62, 0.26), mfDye(ramp, 3) * 1.6 + 0.08, 0.35 * h4);
        s.mat = 3;
        s.hgt = 0.6 * b;
        break;
    }
    default: {  // glazed tiles
        s.flip = mfIHash(cell, m * 13.0 + 5.0 + floor(c.salt * 100.0)) > 0.5 ? 1.0 : 0.0;
        s.mat = 4;
        idx = 1;
        s.hgt = 0.2;
        break;
    }
    }
    s.alb = mfDye(ramp, idx);
    // Terracotta: the same ramp fired earthy.
    if (s.mat == 2) s.alb = mix(s.alb, float3(0.20, 0.10, 0.06), 0.35) * 0.9;
    return s;
}

// The face of a block: the picture's dye with its material's texels, or the
// lamp and glazed-tile motifs. `fp` is texels per pixel; every pattern fades
// to its own average as it climbs past one. `front` is false for the slabs'
// edges, which show the dye and grain but no motif.
static float3 mfFace(MfPic pic, float2 uv, float2 cell, float face, float fp, bool front,
                     thread float3& emit) {
    float2 tc = floor(uv * 16.0);
    float2 e = min(tc, 15.0 - tc);
    float rimD = min(e.x, e.y);
    float n = mfIHash(cell * 16.0 + tc, face) - 0.5;
    float fade = smoothstep(0.6, 1.6, fp);
    emit = float3(0.0);

    if (pic.mat == 3) {     // lamp: iron frame, amber glass, a filament diamond
        float glass = (front && rimD >= 2.0) ? 1.0 : 0.0;
        float2 dc = abs(tc + 0.5 - 8.0);
        float fil = (dc.x + dc.y < 5.0 && dc.x + dc.y > 2.0) ? 1.0 : 0.0;
        float3 alb = glass > 0.0 ? float3(0.010, 0.005, 0.003) * (0.8 + 0.8 * n)
                                 : float3(0.030, 0.028, 0.028) * (rimD < 1.0 ? 0.6 : 1.0 + n);
        float3 em = glass * pic.lampCol * pic.glow * (0.40 + 0.35 * n + 0.8 * fil);
        float gArea = front ? 144.0 / 256.0 : 0.0;
        float3 avgA = mix(float3(0.028), float3(0.010, 0.005, 0.003), gArea);
        float3 avgE = pic.lampCol * pic.glow * gArea * (0.40 + 0.8 * 32.0 / 144.0);
        emit = mix(em, avgE, fade);
        if (!front) emit += pic.lampCol * pic.glow * 0.05;
        return mix(alb, avgA, fade);
    }
    if (pic.mat == 4) {     // glazed tile: quarter arcs that meet into meanders
        float3 bg = mfDye(pic.ramp, 1), arc = mfDye(pic.ramp, 3), line = mfDye(pic.ramp, 4);
        float3 col = bg;
        if (front) {
            float2 t = tc + 0.5;
            if (pic.flip > 0.0) t.x = 16.0 - t.x;
            float d = min(abs(length(t) - 8.0), abs(length(t - 16.0) - 8.0));
            col = d < 0.9 ? line : (d < 3.2 ? arc : bg);
            float2 ce = min(t, 16.0 - t);
            if (length(ce) < 2.6 && d > 3.2) col = mfDye(pic.ramp, 2);
            col = mix(col, bg * 0.45 + arc * 0.40 + line * 0.15, fade);
        }
        return col * (1.0 + 0.06 * n * (1.0 - fade));
    }
    bool rim = rimD < 1.0;
    float v, mean;
    if (pic.mat == 0) {         // wool: fuzz plus clumps two texels across
        float clump = mfIHash(cell * 8.0 + floor(tc * 0.5), face + 20.0) - 0.5;
        v = 1.0 + 0.20 * n + 0.16 * clump + (rim ? -0.16 : 0.0);
        mean = 1.0 - 0.16 * 60.0 / 256.0;
    } else if (pic.mat == 1) {  // concrete: nearly flat
        v = 1.0 + 0.08 * n + (rim ? -0.09 : 0.0);
        mean = 1.0 - 0.09 * 60.0 / 256.0;
    } else {                    // terracotta: mottled
        float mot = valueNoise(tc * 0.4 + cell * 7.1 + face * 2.0) - 0.5;
        v = 1.0 + 0.12 * n + 0.24 * mot + (rim ? -0.12 : 0.0);
        mean = 1.0 - 0.12 * 60.0 / 256.0;
    }
    return pic.alb * mix(v, mean, fade);
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

static inline bool mfMoving(MfPose o) { return o.p > 0.0 && o.p < 1.0; }

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
static MfHit mfScene(float3 ro, float3 rd, float pxAngle, MfCtx c, float aoIn, thread float& tOut);

static MfHit mfScene(float3 ro, float3 rd, float pxAngle, MfCtx c, float aoIn) {
    float t;
    MfHit r = mfScene(ro, rd, pxAngle, c, aoIn, t);
    r.col = mix(r.col, float3(0.012, 0.011, 0.014), smoothstep(0.55, 1.0, t / c.fog));
    return r;
}

static MfHit mfScene(float3 ro, float3 rd, float pxAngle, MfCtx c, float aoIn, thread float& tOut) {
    const float3 L = normalize(float3(-0.45, 0.55, 0.70));
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
        // The board behind: near black, with a faint grid of the cells. It
        // only shows through a flipping block, so it is always near an edge.
        float2 g = abs(fract(P.xy) - 0.5);
        float line = smoothstep(0.47, 0.5, max(g.x, g.y));
        res.ao = full ? mfOcclusion(P, float3(0, 0, 1), cell, nb, nd) : aoIn;
        res.col = float3(0.018, 0.017, 0.02) * (1.0 - 0.5 * line) * res.ao;
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
    // Grain is keyed by picture, not by face, so it does not change when a
    // picture that came in on a back slab becomes the next flip's front.
    float face = bigFace ? glmod(m, 61.0)
                         : 100.0 + (abs(nl.x) > 0.5 ? 0.0 : 1.0) + (nl.x + nl.y > 0.0 ? 2.0 : 0.0);

    float pxWorld = tHit * pxAngle / max(abs(dot(n, rd)), 0.2);
    float fp = pxWorld / (2.0 * h / 16.0);

    float3 emit;
    float3 alb = mfFace(pic, uv, cell, face, fp, bigFace, emit);

    float diff = max(dot(n, L), 0.0);
    float ao = full ? mfOcclusion(P, n, cell, nb, nd) : aoIn;
    res.ao = ao;
    float3 col = alb * (0.38 + 0.62 * diff) * ao;
    if (pic.mat == 4 && bigFace) {
        float3 hv = normalize(L - rd);
        col += 0.10 * pow(max(dot(n, hv), 0.0), 40.0) * ao;
    }
    col += emit * (0.6 + 0.4 * ao);
    res.col = col;

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

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
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
    MfHit first = mfScene(ro, normalize(uv0.x * right + uv0.y * up + MF_FOCAL * fwd), pxAngle, c, -1.0);
    float3 col = first.col;
    if (first.edge) {
        for (int s = 1; s < MF_SAMPLES; ++s) {
            float2 uv = lerpUV(float4(pos.xy + grid[s], 0.0, 1.0), u.resolution);
            float3 rd = normalize(uv.x * right + uv.y * up + MF_FOCAL * fwd);
            col += mfScene(ro, rd, pxAngle, c, first.ao).col;
        }
        col /= float(MF_SAMPLES);
    }

    col = col / (1.0 + col * 0.3);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
