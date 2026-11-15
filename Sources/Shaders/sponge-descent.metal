// Sponge Descent — original shader written for Lerping@Home (AGPL-3.0, like
// the rest of this project). An endless dive down the tunnels of an infinite
// Menger sponge built out of the game's own stone bricks.
//
// lerp-category: Minecraft
// lerp-requires: minecraft
//
// Written from the published mathematics (Karl Menger, 1926: split a cube
// into 27, take out the centre and the six face centres, repeat on the 20
// that remain). Every surface is a real block drawn with its real texture
// (stone bricks with their mossy, cracked and chiseled variants, glowstone;
// the other palettes are deepslate, sandstone, quartz and nether bricks), and
// a block about to break shows the game's ten destroy stages.
//
// The world. Space is the sponge mirrored into all eight octants and grown
// outward without end, so it is the same under x -> x/3 about the origin.
// The camera follows a path of three tunnel legs that ends exactly where it
// began, a third the size: one leg along each axis, always towards the
// origin, so every period has one drop down a shaft and two runs through
// level tunnels. Each period is rendered in its own coordinates (scaled by
// 3^n), so float precision never runs out however long it plays, and the
// order of the three legs is drawn per period from the seed. The camera
// looks partly towards the origin (`gaze`), so tunnel walls turn to face it.
//
// Blocks. Nothing is subdivided to a fixed depth. A cube is split into its
// 20 children only while the camera is within `detail` of its own edge
// lengths; past that it is one solid block. So every block on screen spans
// between 1/(3·detail) and 1/detail radians whatever the zoom, and the
// sponge mines itself as you approach: over the last span of the approach a
// block runs through destroy_stage_0..9 across its whole face, as a block
// being mined does, then breaks into the 20 blocks a third its size that it
// is made of, each with its own full 16-texel face. (The game's faces are
// 16 texels, which thirds do not divide, so the parent's texture is never
// cut into thirds: the block breaks whole and its children are new blocks.)
// Nothing is accumulated; the split is a function of where the camera is,
// and the camera of time.
//
// Light, as the game lights it: the fixed per-face shading, smooth-lighting
// corner darkening from the eight neighbours of each face's air cell, and
// sky light on the game's level curve. The sponge is open to the sky at every
// scale, so a face's sky level is set by the size of the empty cube in front
// of it (known for free from the march): full in the big halls, falling a
// level at a time down each smaller hole, so holes within holes read as ever
// darker nested squares. Fog is the distance colour; light blocks glow.
//
// March: a hierarchical DDA. Each step finds the largest empty cube the point
// is in (or the solid block it hit) by descending the levels, then jumps to
// that cube's far face. No distance estimate, no creeping. Textures are
// sampled once, at the hit.
//
// Cost, worst pixel: SD_STEPS (64) steps of at most 11 level tests each, then
// at the hit 8 more level walks for corner darkening and two tile samples.
// Both restart from the deepest cube already known to be shared (SdStart).
//
// lerp-param: speed    float 0.25 3  = 1     "Speed"
// lerp-param: detail   float 4 12    = 6     "Detail"
// lerp-param: mining   float 0 1     = 0.25  "Mining"
// lerp-param: gaze     float 0 0.8   = 0.5   "Look to the core"
// lerp-param: blocks   int 0 4       = 0     "Blocks"
// lerp-param: colorFog color         = (0.42, 0.52, 0.68) "Fog"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -90 90   = 0 "Tilt"
// lerp-param: magnify  float -1 1     = 0 "Zoom"
//
// blocks: 0 stone bricks, 1 deepslate, 2 sandstone, 3 quartz, 4 nether bricks.
// lerp-preset: Deepslate  blocks=1, colorFog=(0.16, 0.18, 0.24)
// lerp-preset: Sandstone  blocks=2, colorFog=(0.62, 0.58, 0.50)
// lerp-preset: Quartz     blocks=3, colorFog=(0.36, 0.40, 0.52)
// lerp-preset: Nether     blocks=4, colorFog=(0.20, 0.03, 0.03)
// lerp-preset: "Fine Grain" detail=10, mining=0.2

constant float SD_PERIOD = 40.0;      // seconds per threefold zoom at speed 1
constant int   SD_STEPS  = 64;
constant int   SD_LMAX   = 8;         // deepest level ever tested
constant float SD_ROOT   = 9.0;       // edge of the coarsest cube considered
constant float SD_FOCAL  = 1.05;
constant float SD_FOG    = 0.85;      // haze distance, period units at scale 1
constant float SD_BAND   = 0.25;      // crack span, as a fraction of the split distance

constant int3 SD_PERM[6] = { int3(0,1,2), int3(0,2,1), int3(1,0,2),
                             int3(1,2,0), int3(2,0,1), int3(2,1,0) };

// ---------------------------------------------------------------------------
// The path.

// Leg order for period n: which axis each of its three legs runs along. The
// first leg never repeats the previous period's last axis, so a drop is
// always between two level runs. Swapping only the first two entries keeps
// every period's last axis its raw draw, so this needs no recursion.
static inline int3 sdRaw(float n, float salt) {
    return SD_PERM[min(int(hash11(n * 0.6180339 + salt) * 6.0), 5)];
}
static inline int3 sdOrder(float n, float salt) {
    int3 o = sdRaw(n, salt);
    if (o.x == sdRaw(n - 1.0, salt).z) o = int3(o.y, o.x, o.z);
    return o;
}

static inline float3 sdAxis(int a) {
    return float3(a == 0 ? 1.0 : 0.0, a == 1 ? 1.0 : 0.0, a == 2 ? 1.0 : 0.0);
}

struct SdPath {
    float3 W[6];      // W[0] = previous period's last corner, W[1..4] this period's, W[5] next's first
    float3 D[5];      // D[j] = direction of the leg from W[j] to W[j+1]
    float  R[6];      // corner radii
};

static inline SdPath sdPath(float n, float salt) {
    int3 o = sdOrder(n, salt), op = sdOrder(n - 1.0, salt), on = sdOrder(n + 1.0, salt);
    SdPath P;
    float3 c0 = float3(0.5);
    float3 a = c0 - sdAxis(o.x) / 3.0;
    float3 b = a - sdAxis(o.y) / 3.0;
    float3 c1 = c0 / 3.0;
    // previous period's b, in this period's coordinates (×3)
    float3 bp = 3.0 * (c0 - sdAxis(op.x) / 3.0 - sdAxis(op.y) / 3.0);
    // next period's a, in this period's coordinates (÷3)
    float3 an = (c0 - sdAxis(on.x) / 3.0) / 3.0;
    P.W[0] = bp; P.W[1] = c0; P.W[2] = a; P.W[3] = b; P.W[4] = c1; P.W[5] = an;
    P.D[0] = -sdAxis(op.z); P.D[1] = -sdAxis(o.x); P.D[2] = -sdAxis(o.y);
    P.D[3] = -sdAxis(o.z);  P.D[4] = -sdAxis(on.x);
    // Corner radii, as wide as each junction allows (a third of the room at
    // c0 and a, half the 1/9 cavity at b); W[4] is W[1] a third the size.
    P.R[0] = 0.15; P.R[1] = 0.15; P.R[2] = 0.14;
    P.R[3] = 0.05; P.R[4] = 0.05; P.R[5] = 0.14 / 3.0;
    return P;
}

// Horizontal heading of a leg: its own direction if level; across a drop it
// turns from the run before to the run after.
static inline float3 sdHeading(SdPath P, int j, float s) {
    if (P.D[j].y == 0.0) return P.D[j];
    // Turned through the whole drop by angle, so the view spins at an even
    // pace (a normalised linear mix spun three times faster mid-drop).
    float a = smoothstep(0.0, 1.0, s) * (0.5 * PI);
    return normalize(P.D[j - 1] * cos(a) + P.D[j + 1] * sin(a));
}

// Position, tangent and heading at arclength u in [0, 1] (period units).
static inline void sdCamera(SdPath P, float u, thread float3& pos, thread float3& tan,
                            thread float3& head) {
    const float L = 1.0 / 3.0;
    int j = clamp(int(floor(u * 3.0)), 0, 2) + 1;     // leg index into W/D
    float s = clamp(u * 3.0 - float(j - 1), 0.0, 1.0);
    float d = s * L;
    head = sdHeading(P, j, s);
    if (d < P.R[j]) {                                  // leaving the corner at W[j]
        float R = P.R[j], sb = (d + R) / (2.0 * R);
        float3 A = P.D[j - 1], B = P.D[j], W = P.W[j];
        float3 p0 = W - R * A, p2 = W + R * B;
        pos = (1.0 - sb) * (1.0 - sb) * p0 + 2.0 * sb * (1.0 - sb) * W + sb * sb * p2;
        tan = normalize((1.0 - sb) * A + sb * B);
    } else if (d > L - P.R[j + 1]) {                   // entering the corner at W[j+1]
        float R = P.R[j + 1], sb = (d - L + R) / (2.0 * R);
        float3 A = P.D[j], B = P.D[j + 1], W = P.W[j + 1];
        float3 p0 = W - R * A, p2 = W + R * B;
        pos = (1.0 - sb) * (1.0 - sb) * p0 + 2.0 * sb * (1.0 - sb) * W + sb * sb * p2;
        tan = normalize((1.0 - sb) * A + sb * B);
    } else {
        pos = P.W[j] + d * P.D[j];
        tan = P.D[j];
    }
}

// ---------------------------------------------------------------------------
// The sponge.

struct SdCell {
    int    solid;     // 0 empty cube, 1 solid block, 2 outside everything
    float  h;         // edge length
    float3 idx;       // integer index at its level, in |p| space
    int    level;     // level (edge 3^-level)
    float  crack;     // 0..1 for a block about to break
};

// Descend from the root: the first level at which `x` falls in a removed
// child gives an empty cube; the first cube too far from the camera to be
// split is a solid block.
// Where a descent starts: a cube known to be split and not removed, so any
// point inside it (same octant) shares every level above it. The march
// keeps the parent of the last empty cube here, which saves re-walking the
// coarse levels on most steps.
struct SdStart {
    float  H, invh;
    float3 P, sg;
    int    k;
};

static inline SdStart sdRoot() {
    SdStart a;
    a.H = SD_ROOT; a.invh = 3.0 / SD_ROOT; a.P = float3(0.0); a.sg = float3(0.0); a.k = -1;
    return a;
}

static inline SdCell sdQueryFrom(float3 x, float3 cam, float K, float band, thread SdStart& st) {
    SdCell c;
    float3 q = abs(x);
    float3 sg = select(float3(-1.0), float3(1.0), x >= 0.0);
    c.crack = 0.0;
    if (max(q.x, max(q.y, q.z)) >= SD_ROOT) {
        c.solid = 2; c.h = SD_ROOT; c.idx = float3(0.0); c.level = -2;
        return c;
    }
    float3 lo = st.P * st.H;
    if (any(sg != st.sg) || any(q < lo) || any(q >= lo + st.H)) st = sdRoot();
    float H = st.H, invh = st.invh;
    float3 P = st.P;
    // Cubes this large are always split: anything the march can reach lies
    // within 1.6 of the camera, so their centres are within K·H.
    float near = 1.6 / max(K - 0.9, 1.0);
    for (int k = st.k; k <= SD_LMAX; ++k) {
        if (H < near) {
            float3 pc = sg * (P + 0.5) * H - cam;
            float d2 = dot(pc, pc);
            float lim = K * H;
            if (d2 > lim * lim) {
                c.solid = 1; c.h = H; c.idx = P; c.level = k - 1;
                float r = sqrt(d2) / lim;
                c.crack = band > 0.0 ? saturate(1.0 - (r - 1.0) / band) : 0.0;
                return c;
            }
        }
        float3 d = clamp(floor(q * invh) - 3.0 * P, 0.0, 2.0);
        float3 C = 3.0 * P + d;
        float3 one = select(float3(0.0), float3(1.0), d == 1.0);
        float h = H * (1.0 / 3.0);
        if (one.x + one.y + one.z >= 2.0) {
            c.solid = 0; c.h = h; c.idx = C; c.level = k;
            st.H = H; st.invh = invh; st.P = P; st.sg = sg; st.k = k;
            return c;
        }
        P = C; H = h; invh *= 3.0;
    }
    c.solid = 1; c.h = H; c.idx = P; c.level = SD_LMAX;
    return c;
}

static inline float sdSolid(float3 x, float3 cam, float K, SdStart st) {
    return sdQueryFrom(x, cam, K, 0.0, st).solid == 1 ? 1.0 : 0.0;
}

// ---------------------------------------------------------------------------
// Block faces: which block this is, as the game would have built it.

static inline float sdH(float3 p, float salt) {
    return hash21(p.xy * float2(1.0, 1.37) + float2(p.z * 0.731 + salt, p.z * 1.913 - salt * 0.37));
}

// The tile layer for a face of block `b`. Each palette is one family of
// building blocks with its own weathered and decorated variants mixed in, as
// a stronghold mixes plain, mossy and cracked stone bricks, plus a rare light
// block. `glow` is set for light blocks, which the game draws at full light.
static inline int sdBlockTile(float3 id, int pal, bool top, thread bool& glow, float time) {
    float h = sdH(id, 0.0), g = sdH(id, 9.7);
    glow = g < 0.012;
    switch (pal) {
    case 1:   // deepslate
        if (glow) return mcFrame(MC_SEA_LANTERN, MC_SEA_LANTERN_FRAMES, MC_SEA_LANTERN_TICKS, time);
        if (h < 0.12) return MC_CRACKED_DEEPSLATE_BRICKS;
        if (h < 0.30) return MC_DEEPSLATE_TILES;
        if (h < 0.36) return MC_CRACKED_DEEPSLATE_TILES;
        if (h < 0.40) return MC_CHISELED_DEEPSLATE;
        return MC_DEEPSLATE_BRICKS;
    case 2:   // sandstone
        if (glow) return top ? MC_OCHRE_FROGLIGHT_TOP : MC_OCHRE_FROGLIGHT_SIDE;
        if (h < 0.25) return top ? MC_SANDSTONE_TOP : MC_SANDSTONE;
        if (h < 0.30) return top ? MC_SANDSTONE_TOP : MC_CHISELED_SANDSTONE;
        return top ? MC_SANDSTONE_TOP : MC_CUT_SANDSTONE;
    case 3:   // quartz
        if (glow) return mcFrame(MC_SEA_LANTERN, MC_SEA_LANTERN_FRAMES, MC_SEA_LANTERN_TICKS, time);
        if (h < 0.25) return top ? MC_QUARTZ_BLOCK_TOP : MC_QUARTZ_BLOCK_SIDE;
        if (h < 0.31) return top ? MC_CHISELED_QUARTZ_BLOCK_TOP : MC_CHISELED_QUARTZ_BLOCK;
        return MC_QUARTZ_BRICKS;
    case 4:   // nether
        if (glow) return h < 0.5 ? MC_GLOWSTONE : MC_SHROOMLIGHT;
        if (h < 0.18) return MC_CRACKED_NETHER_BRICKS;
        if (h < 0.26) return MC_RED_NETHER_BRICKS;
        if (h < 0.30) return MC_CHISELED_NETHER_BRICKS;
        return MC_NETHER_BRICKS;
    default:  // stone bricks, as a stronghold lays them
        if (glow) return MC_GLOWSTONE;
        if (h < 0.20) return MC_MOSSY_STONE_BRICKS;
        if (h < 0.36) return MC_CRACKED_STONE_BRICKS;
        if (h < 0.40) return MC_CHISELED_STONE_BRICKS;
        return MC_STONE_BRICKS;
    }
}

// ---------------------------------------------------------------------------

static inline float3 sdScene(float3 ro, float3 rd, float pxAngle, float s, float K,
                             float la0, constant LerpUniforms& u,
                             texture2d_array<float> mcTiles) {
    float3 fogC = u.colorFog.rgb;
    float band = SD_BAND * u.mining;
    float tMax = 2.0 * SD_FOG * s;
    float3 ird = 1.0 / select(rd, float3(1e-6), abs(rd) < 1e-6);

    float t = 0.0;
    int axis = 0;
    SdCell hit;
    bool found = false;
    float tFace = 0.0;
    float airH = s;          // edge of the last empty cube crossed before the hit
    SdStart st = sdRoot();
    for (int i = 0; i < SD_STEPS; ++i) {
        float3 x = ro + rd * t;
        SdCell c = sdQueryFrom(x, ro, K, band, st);
        if (c.solid == 1) { hit = c; found = true; tFace = t; break; }
        if (c.solid == 2) break;
        airH = c.h;
        // jump to the far face of this empty cube
        float3 sg = select(float3(-1.0), float3(1.0), x >= 0.0);
        float3 lo = c.idx * c.h, hi = lo + c.h;
        float3 a = sg * lo, b = sg * hi;
        float3 bmin = min(a, b), bmax = max(a, b);
        float3 tt = (select(bmin, bmax, rd > 0.0) - x) * ird;
        float te = tt.x; axis = 0;
        if (tt.y < te) { te = tt.y; axis = 1; }
        if (tt.z < te) { te = tt.z; axis = 2; }
        t += max(te, 0.0) + max(c.h * 2e-3, 2e-6);
        if (t > tMax) break;
    }

    // Distance fog, near walls clear.
    float fogAmt = 1.0 - exp(-pow(t / (SD_FOG * s), 1.8));
    if (!found) return fogC;

    float3 n = float3(0.0);
    n[axis] = rd[axis] > 0.0 ? -1.0 : 1.0;
    float3 xh = ro + rd * tFace;                     // t landed a hair inside the block
    float H = hit.h;
    float3 sgh = select(float3(-1.0), float3(1.0), (xh - n * 0.5 * H) >= 0.0);
    float3 ctr = sgh * (hit.idx + 0.5) * H;          // block centre
    float3 loc = saturate((xh - ctr) / H + 0.5);     // 0..1 inside the block
    int a1 = axis == 0 ? 2 : 0;                      // face u axis
    int a2 = axis == 1 ? 2 : 1;                      // face v axis (world up on walls)
    float2 fuv = float2(loc[a1], loc[a2]);

    // Smooth lighting's corner darkening: the eight blocks round the face's air cell.
    float3 t1 = sdAxis(a1), t2 = sdAxis(a2);
    float3 ac = ctr + n * H;
    float s1n = sdSolid(ac - t1 * H, ro, K, st), s1p = sdSolid(ac + t1 * H, ro, K, st);
    float s2n = sdSolid(ac - t2 * H, ro, K, st), s2p = sdSolid(ac + t2 * H, ro, K, st);
    float cnn = sdSolid(ac - t1 * H - t2 * H, ro, K, st), cpn = sdSolid(ac + t1 * H - t2 * H, ro, K, st);
    float cnp = sdSolid(ac - t1 * H + t2 * H, ro, K, st), cpp = sdSolid(ac + t1 * H + t2 * H, ro, K, st);
    float4 vao;   // (--, +-, -+, ++)
    vao.x = (s1n * s2n > 0.5) ? 0.0 : 3.0 - (s1n + s2n + cnn);
    vao.y = (s1p * s2n > 0.5) ? 0.0 : 3.0 - (s1p + s2n + cpn);
    vao.z = (s1n * s2p > 0.5) ? 0.0 : 3.0 - (s1n + s2p + cnp);
    vao.w = (s1p * s2p > 0.5) ? 0.0 : 3.0 - (s1p + s2p + cpp);
    float ao = mix(mix(vao.x, vao.y, fuv.x), mix(vao.z, vao.w, fuv.x), fuv.y) / 3.0;
    ao = 0.45 + 0.55 * ao;

    // The texture: side faces stand upright (uv.y = 0 is the picture's top).
    float2 uv = axis == 1 ? fuv : float2(fuv.x, 1.0 - fuv.y);
    float cosI = max(abs(rd[axis]), 0.05);
    float fp = t * pxAngle * pow(cosI, -0.35) / H;   // one screen pixel, in blocks
    float3 id = hit.idx + float3(la0 + float(hit.level)) * float3(7.0, 13.0, 3.0);
    bool glow;
    int layer = sdBlockTile(id, u.blocks, axis == 1, glow, u.time);
    float3 alb = mcTile(mcTiles, layer, uv, fp).rgb;

    // A block being mined wears the destroy stage over its whole face, blended
    // as the game blends it (twice source times destination).
    if (hit.crack > 0.0) {
        int stage = min(int(hit.crack * 10.0), 9);
        float4 d = mcTile(mcTiles, MC_DESTROY_STAGE_0 + stage, uv, fp);
        alb *= mix(float3(1.0), 2.0 * d.rgb, d.a);
    }

    // Sky light: the sponge is open to the sky at every scale, so a face gets
    // the level of the cavity it looks into, one level less for each step
    // down in hole size, on the game's light curve. Light blocks are at 15.
    float open = saturate((log2(airH / s) + 4.4) / 3.2);
    float level = glow ? 15.0 : floor(5.0 + 10.0 * open + 0.5);
    float light = max(mcLight(level), 0.05);
    float3 col = alb * mcFaceShade(n) * (glow ? 1.0 : ao) * light;
    return mix(col, fogC, fogAmt);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]]) {
    float minRes = min(u.resolution.x, u.resolution.y);
    float salt = floor(u.seed * 977.0) * 0.137;

    // Period n, phase f. The seed also moves the start within a period.
    float tt = u.time * u.speed / SD_PERIOD + fract(u.seed * 7.31);
    float n = floor(tt) + floor(u.seed * 409.0);
    float f = fract(tt);
    float s = exp2(-f * log2(3.0));                 // the camera's scale, 1 -> 1/3
    float uu = (1.0 - s) * 1.5;                     // arclength: world speed falls as 3^-f

    SdPath P = sdPath(n, salt);
    float3 ro, tng, head;
    sdCamera(P, uu, ro, tng, head);

    // The travel frame: level runs keep world up; on a drop, up is the heading.
    float3 upT = normalize(float3(0.0, 1.0, 0.0) + head * 2.0 * max(0.0, -tng.y));
    upT = normalize(cross(normalize(cross(tng, upT)), tng));
    // Look partly towards the origin, the point the whole dive closes on: the
    // tunnel walls turn to face the eye and the nested holes line up on it.
    float3 fwd = normalize(tng + u.gaze * normalize(-ro));
    float3 upHint = upT;
    float3 right = normalize(cross(fwd, upHint));
    // A slow drift off the tunnel's centre line, in proportion to the scale,
    // so the view is never dead symmetric.
    float3 up0 = cross(right, fwd);
    float sw = u.time * 0.11 + u.seed * 40.0;
    ro += 0.022 * s * (right * sin(sw) + up0 * sin(sw * 0.77 + 1.9));
    fwd = normalize(fwd + 0.05 * (right * sin(sw * 0.61 + 0.4) + up0 * sin(sw * 0.53 + 2.6)));
    right = normalize(cross(fwd, upHint));
    float lens = lerpLook(u.yaw, u.pitch, u.magnify, upHint, right, fwd);
    float3 up = cross(right, fwd);
    float pxAngle = 2.0 / (minRes * SD_FOCAL * lens);

    float2 uv = lerpUV(pos, u.resolution);
    float3 rd = normalize(uv.x * right + uv.y * up + lens * SD_FOCAL * fwd);
    float3 col = sdScene(ro, rd, pxAngle, s, u.detail, n, u, mcTiles);

    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
