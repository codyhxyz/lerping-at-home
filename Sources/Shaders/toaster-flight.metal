// Toaster Flight — an homage to Berkeley Systems' "Flying Toasters" (After
// Dark, 1989), done with the game's own blocks and items. Original code for
// Lerping@Home; no code or artwork from the original screensaver.
//
// lerp-category: Living Worlds
// lerp-requires: minecraft
//
// The idea kept: a formation of winged kitchen appliances, and slices of
// bread, streaming down and across the night forever. In the game the
// appliance that cooks food is the smoker, so the flock is lit smokers (with
// the odd furnace and blast furnace), each a full block with its fire
// flickering in the front, flying on a pair of elytra hinged at its top
// edges. The toast is the bread item, drawn as the game draws a dropped
// item: the sprite extruded one texel thick, tumbling. The sky is the
// game's: black at midnight over the fog colour at the horizon, small square
// stars, the moon's own texture in a seeded phase, and the flat cloud layer
// read cell by cell from clouds.png, drifting.
//
// Light follows the game too. Blocks take the fixed per-face shading; a lit
// smoker gives off light 13, so the air at each of its faces sits at 12 and
// the whole block and its wings are lit warm by it. The bread is lit as the
// game lights an item, two fixed directional lights and an ambient, under
// the night's sky light. Fog is the game's fog colour, by distance.
//
// The formation is a lattice in the flock's own frame, so every flyer shares
// one orientation and the ray is turned into that frame once. The lattice
// moves along the flight line; a cell holds at most one flyer, kept inside
// its cell, so the first cell the ray finds a hit in is the nearest. Flyers
// live only in a band in front of the camera whose distance from the
// camera's line never changes, so none flies through the lens or pops.
// Textures are sampled only at the hit.
//
// lerp-param: speed    float 0.2 2.5 = 1     "Flight speed"
// lerp-param: density  float 0.05 1  = 0.5   "Flyers"
// lerp-param: toast    float 0 1     = 0.3   "Share of bread"
// lerp-param: flap     float 0.3 2.5 = 0.8   "Wingbeat"
// lerp-param: clouds   bool          = true  "Clouds"
// lerp-param: daylight float 0 1     = 0     "Daylight"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -45 45   = 0 "Tilt"
// lerp-param: magnify  float -1 1     = 0 "Zoom"
//
// lerp-preset: Void clouds=false
// lerp-preset: Day daylight=1

constant float  TT_TEX    = 16.0;                 // block texels per block
constant float  TT_ITEM   = 16.0 / 0.7;           // item texels per block (bread is 0.7 blocks)
constant float3 TT_CELL   = float3(4.2, 4.2, 4.6); // lattice cell, blocks (flock frame)
constant int    TT_STEPS  = 28;
constant float  TT_NEAR_S = 3.6;                  // flyers start this far to the side
constant float  TT_FAR_S  = 19.0;
constant float  TT_BEAM   = 4.6;                  // half-height of the stream, blocks
constant float  TT_FAR    = 32.0;                 // flyers fade into fog by here
constant float  TT_FOCAL  = 1.35;
constant float  TT_CLOUD_TOP = -14.0;
constant float  TT_CLOUD_BOT = -18.0;             // the game's layer is 4 blocks thick
constant float  TT_CLOUD_CELL = 12.0;             // one clouds.png pixel is 12 blocks
constant int    TT_CLOUD_STEPS = 22;
constant float  TT_CLOUD_FAR = 300.0;
constant int    TT_SAMPLES = 2;

struct TtTex {
    texture2d_array<float> tiles, items, skins, maps;
};

// ---------------------------------------------------------------------------
// Hashes (placement only; every surface is a texture).

static inline uint ttPcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
static inline float4 ttHash4(int3 c, uint salt) {
    uint h = ttPcg(uint(c.x) ^ ttPcg(uint(c.y) ^ ttPcg(uint(c.z) ^ salt)));
    uint h2 = ttPcg(h ^ 0x9e3779b9u), h3 = ttPcg(h2), h4 = ttPcg(h3);
    return float4(float(h), float(h2), float(h3), float(h4)) * (1.0 / 4294967296.0);
}
static inline float ttHash2(int2 c, uint salt) {
    return float(ttPcg(uint(c.x) ^ ttPcg(uint(c.y) ^ salt))) * (1.0 / 4294967296.0);
}

// ---------------------------------------------------------------------------
// Sky, as the game draws it.

struct TtSky {
    float3 sky, fog;       // overhead colour and fog / horizon colour
    float3 cloud;          // cloud colour before face shading
    float stars;           // star brightness
    float day;
    float3 L;              // towards the moon (or the sun by day)
    float3 cf, cr, cu;     // the camera's resting frame: the moon is square in it
    float2 mc;             // the moon's centre on that frame's picture plane
    int moon;              // moon phase layer
    float T;
    uint salt;
};

static inline float3 ttSkyBase(float3 rd, TtSky k) {
    // The sky colour overhead, the fog colour at the horizon, and the dark
    // void below it.
    float3 c = mix(k.fog, k.sky, smoothstep(0.0, 0.32, rd.y));
    if (rd.y < 0.0) c = mix(k.fog, k.fog * 0.7, smoothstep(0.0, 0.25, -rd.y));
    return c;
}

static inline float3 ttSky(float3 rd, TtSky k, float pxA, TtTex tx) {
    float3 c = ttSkyBase(rd, k);
    // Stars: small white squares, as the game scatters them.
    if (k.stars > 0.0 && rd.y > 0.0) {
        float3 a = abs(rd);
        float2 f; int face;
        if (a.x > a.y && a.x > a.z) { f = rd.yz / a.x; face = rd.x > 0.0 ? 0 : 1; }
        else if (a.y > a.z)        { f = rd.xz / a.y; face = 2; }
        else                       { f = rd.xy / a.z; face = rd.z > 0.0 ? 4 : 5; }
        float2 g = f * 150.0;
        int2 cell = int2(floor(g));
        float h = ttHash2(cell + int2(face * 977, face * 131), k.salt ^ 0x51u);
        if (h < 0.03) {
            float b = h / 0.03;
            float2 o = fract(g) - 0.5;
            float hs = 0.22 + 0.16 * fract(b * 5.7);
            if (max(abs(o.x), abs(o.y)) < hs)
                c += float3(0.45 + 0.5 * b) * k.stars * smoothstep(0.0, 0.12, rd.y);
        }
    }
    // The moon (or the sun): its own texture, added to the sky as the game
    // adds it, on a square quad.
    float md = dot(rd, k.cf);
    if (md > 0.05) {
        float2 m = float2(dot(rd, k.cr), dot(rd, k.cu)) / md - k.mc;
        float hs = k.day > 0.5 ? 0.30 : 0.20;
        if (abs(m.x) < hs && abs(m.y) < hs) {
            float2 px = (float2(m.x, -m.y) / hs * 0.5 + 0.5) * 32.0;
            float w = pxA * 32.0 / (2.0 * hs);
            int layer = k.day > 0.5 ? MCS_ENVIRONMENT_CELESTIAL_SUN : k.moon;
            float4 s = mcSkin(tx.skins, layer, px, w);
            c += s.rgb * s.a;
        }
    }
    return c;
}

// ---------------------------------------------------------------------------
// Geometry.

struct TtHit {
    float t;        // along the ray, in the part's texels
    float3 n;       // normal in the flock frame
    float3 p;       // hit point relative to the part's box minimum, texels
    int axis;
    int part;       // 0 block, 1 right wing, 2 left wing, 3 bread
};

static inline float ttBox(float3 o, float3 d, float3 bmin, float3 bmax,
                          thread float3& nrm, thread int& axis) {
    float3 inv = 1.0 / d;
    float3 t0 = (bmin - o) * inv, t1 = (bmax - o) * inv;
    float3 tn = min(t0, t1), tf = max(t0, t1);
    float tN = max(max(tn.x, tn.y), tn.z);
    float tF = min(min(tf.x, tf.y), tf.z);
    if (tN > tF || tN <= 0.0) return 1e9;
    if (tN == tn.x)      { axis = 0; nrm = float3(-sign(d.x), 0.0, 0.0); }
    else if (tN == tn.y) { axis = 1; nrm = float3(0.0, -sign(d.y), 0.0); }
    else                 { axis = 2; nrm = float3(0.0, 0.0, -sign(d.z)); }
    return tN;
}

// The elytra's outer face, in elytra.png: 10 wide, 20 long, from (36, 2).
// `a` runs 0..10 back from the leading edge, `c` 0..20 out from the hinge.
static inline float2 ttElytraPixel(float a, float c) {
    return float2(36.0 + clamp(a, 0.02, 9.98), 2.0 + clamp(c, 0.02, 19.98));
}

// One elytra wing hinged along the body's x at (hx, hy, hz), swung up by
// `ang`; mirror = -1 for the left wing. The board is 10 x 20 x 2 texels, the
// elytra model's own size, and its shape is the texture's alpha.
static inline void ttWing(float3 o, float3 d, float3 hinge, float ang, float mirror,
                          TtTex tx, thread TtHit& h) {
    float3 r = o - hinge;
    r.z *= mirror;
    float3 dd = float3(d.x, d.y, d.z * mirror);
    float sa = sin(ang), ca = cos(ang);
    // Wing frame: x along the body, y out along the span, z through the board.
    float3 wo = float3(r.x, r.y * sa + r.z * ca, r.y * ca - r.z * sa);
    float3 wd = float3(dd.x, dd.y * sa + dd.z * ca, dd.y * ca - dd.z * sa);
    float3 nrm; int axis = 0;
    float3 bmin = float3(-5.0, 0.0, -1.0), bmax = float3(5.0, 20.0, 1.0);
    float t = ttBox(wo, wd, bmin, bmax, nrm, axis);
    if (t >= h.t) return;
    float3 p = wo + wd * t - bmin;
    float a = 10.0 - p.x;                       // leading edge forward
    if (mcSkin(tx.skins, MCS_EQUIPMENT_WINGS_ELYTRA, ttElytraPixel(a, p.y), 0.0).a < 0.5) return;
    float3 nb = float3(nrm.x, nrm.y * sa + nrm.z * ca, nrm.y * ca - nrm.z * sa);
    nb.z *= mirror;
    h.t = t; h.n = nb; h.p = p; h.axis = axis;
    h.part = mirror > 0.0 ? 1 : 2;
}

// ---------------------------------------------------------------------------
// The flock.

struct TtFlock {
    float3 F, U, S;          // flight, up, side (S points away from the camera)
    float uMid;              // the stream's centre on the up axis
    float shift;             // lattice travel within one cell, blocks
    int shiftCells;
    float T, flapT, time;
    float density, toast;
    uint salt;
};

struct TtSurf {
    float t;                 // blocks
    float3 col;              // lit colour
};

// The game's item lighting: two fixed lights and an ambient.
static inline float ttItemShade(float3 n) {
    const float3 l0 = normalize(float3(0.2, 1.0, -0.7));
    const float3 l1 = normalize(float3(-0.2, 1.0, 0.7));
    return min(1.0, 0.4 + 0.6 * (max(dot(n, l0), 0.0) + max(dot(n, l1), 0.0)));
}

static bool ttCell(int3 c, float3 oq, float3 d, TtFlock fl, float pxA, float3 rdW,
                   TtSky sky, TtTex tx, thread TtSurf& s) {
    int3 gid = int3(c.x - fl.shiftCells, c.y, c.z);
    float4 h = ttHash4(gid, fl.salt);
    if (h.x >= fl.density) return false;
    float3 cc = (float3(c) + 0.5) * TT_CELL;
    if (cc.z < TT_NEAR_S || cc.z > TT_FAR_S) return false;
    if (abs(cc.y - fl.uMid) > TT_BEAM) return false;
    float4 h2 = ttHash4(gid, fl.salt ^ 0x7f4a7c15u);
    // Jitter within the cell, plus a slow drift fore and aft.
    cc += (h2.xyz - 0.5) * float3(1.2, 0.3, 0.5);
    cc.x += 0.28 * sin(fl.T * (0.11 + 0.08 * h2.w) + h.w * 30.0);
    bool isBread = h.y < fl.toast;

    // Sky light at night, and a lit block's own light (13 in the block,
    // 12 in the air at its faces), warm as the game's block light is.
    // The game's lightmap: open sky above (sky light 15), and a lit block's
    // own light, 13 in the block and 12 in the air at its faces.
    float3 blockLit = mcLightmap(12.0, 15.0, sky.day, 0.0);

    if (isBread) {
        float3 o = (oq - cc) * TT_ITEM;
        float a = fl.T * (0.25 + 0.3 * h2.w) * (h.z < 0.5 ? 1.0 : -1.0) + h.w * 6.283;
        float ca = cos(a), sa = sin(a);
        float3 ro = float3(ca * o.x + sa * o.y, -sa * o.x + ca * o.y, o.z);
        float3 rd = float3(ca * d.x + sa * d.y, -sa * d.x + ca * d.y, d.z);
        float3 nrm; int axis = 0;
        float3 bmin = float3(-8.0, -8.0, -0.5), bmax = float3(8.0, 8.0, 0.5);
        float t = ttBox(ro, rd, bmin, bmax, nrm, axis);
        if (t > 1e8) return false;
        float3 p = ro + rd * t - bmin;
        float tW = t / TT_ITEM;
        float fp = tW * pxA;
        // An extruded sprite: every face shows the texel it is cut from.
        float2 uv = float2(clamp(p.x, 0.02, 15.98), 16.0 - clamp(p.y, 0.02, 15.98)) / 16.0;
        if (mcTile(tx.items, MC_ITEM_BREAD, uv, 0.0).a < 0.5) return false;
        float4 tex = mcTile(tx.items, MC_ITEM_BREAD, uv, axis == 2 ? fp : 0.0);
        float3 nF = float3(ca * nrm.x - sa * nrm.y, sa * nrm.x + ca * nrm.y, nrm.z);
        float3 nW = nF.x * fl.F + nF.y * fl.U + nF.z * fl.S;
        // Bread flies among the smokers and catches some of their light.
        float3 light = mcLightmap(10.0, 15.0, sky.day, 0.0);
        s.t = tW;
        s.col = tex.rgb * light * ttItemShade(nW);
        return true;
    }

    float3 o = (oq - cc) * TT_TEX;
    float3 nn; int ax = 0;
    if (ttBox(o, d, float3(-8.5, -9.0, -29.0), float3(8.5, 27.0, 29.0), nn, ax) > 1e8)
        return false;
    float bob = 1.0 * sin(fl.flapT * 6.283 * 1.1 + h.w * 6.283 + 1.4);
    o.y -= bob;
    TtHit hit; hit.t = 1e9;
    {
        float3 nrm; int axis = 0;
        float t = ttBox(o, d, float3(-8.0), float3(8.0), nrm, axis);
        if (t < 1e8) {
            hit.t = t; hit.n = nrm; hit.axis = axis; hit.part = 0;
            hit.p = o + d * t + 8.0;
        }
    }
    float ang = 0.45 + 0.75 * sin(fl.flapT * 6.283 * 1.1 + h.w * 6.283);
    ttWing(o, d, float3(-1.0, 6.0, 8.0), ang, 1.0, tx, hit);
    ttWing(o, d, float3(-1.0, 6.0, -8.0), ang, -1.0, tx, hit);
    if (hit.t > 1e8) return false;

    float tW = hit.t / TT_TEX;
    float fp = tW * pxA;
    float3 nW = hit.n.x * fl.F + hit.n.y * fl.U + hit.n.z * fl.S;
    float3 light = blockLit;
    float3 col;
    if (hit.part == 0) {
        // Smoker most often; now and then a furnace or a blast furnace.
        float kind = fract(h.z * 13.7);
        int front, side, top, bottom;
        if (kind < 0.62) {
            front = mcFrame(MC_SMOKER_FRONT_ON, MC_SMOKER_FRONT_ON_FRAMES, MC_SMOKER_FRONT_ON_TICKS,
                            fl.time + h.w * 17.0);
            side = MC_SMOKER_SIDE; top = MC_SMOKER_TOP; bottom = MC_SMOKER_BOTTOM;
        } else if (kind < 0.85) {
            front = MC_FURNACE_FRONT_ON;
            side = MC_FURNACE_SIDE; top = MC_FURNACE_TOP; bottom = MC_FURNACE_TOP;
        } else {
            front = mcFrame(MC_BLAST_FURNACE_FRONT_ON, MC_BLAST_FURNACE_FRONT_ON_FRAMES,
                            MC_BLAST_FURNACE_FRONT_ON_TICKS, fl.time + h.w * 17.0);
            side = MC_BLAST_FURNACE_SIDE; top = MC_BLAST_FURNACE_TOP; bottom = MC_BLAST_FURNACE_TOP;
        }
        float3 p = hit.p / 16.0;
        float2 uv; int layer;
        if (hit.axis == 1) {
            uv = p.xz;
            layer = hit.n.y > 0.0 ? top : bottom;
        } else if (hit.axis == 0) {
            uv = float2(hit.n.x > 0.0 ? 1.0 - p.z : p.z, 1.0 - p.y);
            layer = hit.n.x > 0.0 ? front : side;
        } else {
            uv = float2(hit.n.z > 0.0 ? p.x : 1.0 - p.x, 1.0 - p.y);
            layer = side;
        }
        float3 tex = mcTile(tx.tiles, layer, uv, fp).rgb;
        col = tex * light * mcFaceShade(hit.n);
    } else {
        // The elytra: its outer face on the broad sides, and the texel it is
        // cut from on its edges.
        float a = 10.0 - hit.p.x;
        float w = (hit.axis == 2) ? fp * TT_TEX : 0.0;
        float4 tex = mcSkin(tx.skins, MCS_EQUIPMENT_WINGS_ELYTRA, ttElytraPixel(a, hit.p.y), w);
        col = tex.rgb * light * ttItemShade(nW);
    }
    s.t = tW;
    s.col = col;
    return true;
}

// Walk the flock lattice. Returns the nearest flyer within tMax.
static bool ttFlockTrace(float3 ro, float3 rd, float tMax, TtFlock fl, float pxA,
                         TtSky sky, TtTex tx, thread TtSurf& s) {
    float3 o = float3(dot(ro, fl.F), dot(ro, fl.U), dot(ro, fl.S));
    float3 d = float3(dot(rd, fl.F), dot(rd, fl.U), dot(rd, fl.S));
    if (d.z <= 1e-4) return false;
    // Clip to the slab the flock lives in, and to the stream's band.
    float tA = max((TT_NEAR_S - 2.5 - o.z) / d.z, 0.0);
    float tB = min((TT_FAR_S + 2.5 - o.z) / d.z, tMax);
    float bLo = fl.uMid - TT_BEAM - TT_CELL.y, bHi = fl.uMid + TT_BEAM + TT_CELL.y;
    if (abs(d.y) > 1e-5) {
        float ta = (bLo - o.y) / d.y, tb = (bHi - o.y) / d.y;
        tA = max(tA, min(ta, tb));
        tB = min(tB, max(ta, tb));
    } else if (o.y < bLo || o.y > bHi) return false;
    if (tA >= tB) return false;
    d += float3(d.x == 0.0 ? 1e-6 : 0.0, d.y == 0.0 ? 1e-6 : 0.0, 0.0);
    float3 oq = o - float3(fl.shift, 0.0, 0.0);
    float3 p = oq + d * tA;
    float3 cf = floor(p / TT_CELL);
    int3 c = int3(cf);
    float3 st = sign(d);
    float3 tDelta = abs(TT_CELL / d);
    float3 tNext = tA + ((cf + max(st, 0.0)) * TT_CELL - p) / d;
    int3 stepI = int3(st);
    float tCur = tA;
    for (int i = 0; i < TT_STEPS; ++i) {
        if (tCur > tB) break;
        if (ttCell(c, oq, d, fl, pxA, rd, sky, tx, s)) return s.t < tMax;
        if (tNext.x < tNext.y && tNext.x < tNext.z) { tCur = tNext.x; tNext.x += tDelta.x; c.x += stepI.x; }
        else if (tNext.y < tNext.z)                  { tCur = tNext.y; tNext.y += tDelta.y; c.y += stepI.y; }
        else                                         { tCur = tNext.z; tNext.z += tDelta.z; c.z += stepI.z; }
    }
    return false;
}

// ---------------------------------------------------------------------------
// The cloud layer: clouds.png, one pixel a 12-block cell, 4 blocks thick.

static inline bool ttCloudAt(int2 c, TtTex tx) {
    uint2 px = uint2(c & 255);
    return tx.maps.read(px, uint(MCM_ENVIRONMENT_CLOUDS)).a > 0.5;
}

// Returns t of the layer hit (or 1e9), with its world normal.
static float ttClouds(float3 ro, float3 rd, float wind, int2 windCells, TtTex tx,
                      thread float3& n) {
    if (rd.y >= -1e-4) return 1e9;
    float t0 = (TT_CLOUD_TOP - ro.y) / rd.y;
    float t1 = (TT_CLOUD_BOT - ro.y) / rd.y;
    if (t0 > TT_CLOUD_FAR) return 1e9;
    float2 o = ro.xz + float2(wind, 0.0);
    float2 d = rd.xz;
    d += float2(d.x == 0.0 ? 1e-6 : 0.0, d.y == 0.0 ? 1e-6 : 0.0);
    float2 p = (o + d * t0) / TT_CLOUD_CELL;
    float2 cf = floor(p);
    int2 c = int2(cf) + windCells;
    if (ttCloudAt(c, tx)) { n = float3(0.0, 1.0, 0.0); return t0; }
    float2 dc = d / TT_CLOUD_CELL;
    float2 st = sign(dc);
    float2 tDelta = abs(1.0 / dc);
    float2 tNext = t0 + (cf + max(st, 0.0) - p) / dc;
    int2 stepI = int2(st);
    for (int i = 0; i < TT_CLOUD_STEPS; ++i) {
        float t; float3 nn;
        if (tNext.x < tNext.y) { t = tNext.x; tNext.x += tDelta.x; c.x += stepI.x; nn = float3(-st.x, 0.0, 0.0); }
        else                   { t = tNext.y; tNext.y += tDelta.y; c.y += stepI.y; nn = float3(0.0, 0.0, -st.y); }
        if (t > t1 || t > TT_CLOUD_FAR) return 1e9;
        if (ttCloudAt(c, tx)) { n = nn; return t; }
    }
    return 1e9;
}

// ---------------------------------------------------------------------------

static float3 ttScene(float3 ro, float3 rd, float pxA, TtSky sky, TtFlock fl,
                      float wind, int2 windCells, bool clouds, TtTex tx) {
    float3 cn = float3(0.0);
    float tc = clouds ? ttClouds(ro, rd, wind, windCells, tx, cn) : 1e9;

    float3 col = ttSky(rd, sky, pxA, tx);
    if (tc < 1e8) {
        // The game's cloud faces: top full, sides 0.9 and 0.8, underside 0.7;
        // drawn at 0.8 opacity, and fogged with distance.
        float face = cn.y > 0.5 ? 1.0 : (abs(cn.x) > 0.5 ? 0.9 : 0.8);
        float3 cc = sky.cloud * face;
        cc = mix(cc, sky.fog, smoothstep(40.0, TT_CLOUD_FAR, tc));
        col = mix(col, cc, 0.8);
    }

    TtSurf s;
    float tMax = min(tc, TT_FAR);
    if (ttFlockTrace(ro, rd, tMax, fl, pxA, sky, tx, s)) {
        // Far flyers fade into whatever is behind them (the cloud layer is
        // fogged on its own, longer scale), so none turns into a dark
        // silhouette against lit clouds.
        float fade = smoothstep(TT_FAR * 0.55, TT_FAR, s.t);
        col = mix(s.col, col, fade);
    }
    return col;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcItems [[texture(9)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    TtTex tx = { mcTiles, mcItems, mcSkins, mcMaps };
    float minRes = min(u.resolution.x, u.resolution.y);
    float T = u.time + u.seed * 400.0;
    uint salt = uint(u.seed * 16777216.0) * 2654435761u + 12345u;

    // Camera: level above the cloud layer, looking a little down, swaying gently.
    float sway = 0.06 * sin(T * 0.021) + 0.02 * sin(T * 0.047 + 1.0);
    float3 ro = float3(0.0, 0.25 * sin(T * 0.033), 0.0);
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 fwd = normalize(float3(sin(sway), -0.2, cos(sway)));
    float3 right = normalize(cross(upHint, fwd));
    float lens = lerpLook(u.yaw, u.pitch, u.magnify, upHint, right, fwd);
    float3 up = cross(fwd, right);
    float pxA = 2.0 / (minRes * TT_FOCAL * lens);

    // The game's sky and fog colours for this much daylight (0 = midnight).
    float b = u.daylight;
    TtSky sky;
    sky.day = b;
    sky.sky = mcSkyAt(b);
    sky.fog = mcFogAt(b);
    sky.cloud = mcLightmap(0.0, 15.0, b, 0.0);   // white, lit as a sky-lit face
    sky.stars = saturate(1.0 - 2.0 * b) * 0.9;
    float mAz = -0.40 + 0.12 * (fract(u.seed * 7.31) - 0.5);
    sky.L = normalize(float3(sin(mAz), 0.33, cos(mAz)));
    sky.cf = normalize(float3(0.0, -0.2, 1.0));
    sky.cr = normalize(cross(upHint, sky.cf));
    sky.cu = cross(sky.cf, sky.cr);
    sky.mc = float2(dot(sky.L, sky.cr), dot(sky.L, sky.cu)) / dot(sky.L, sky.cf);
    // A phase of the moon from the seed; full most often, never new.
    float ph = fract(u.seed * 3.17);
    sky.moon = ph < 0.4 ? MCS_ENVIRONMENT_CELESTIAL_MOON_FULL_MOON
             : ph < 0.5 ? MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_GIBBOUS
             : ph < 0.6 ? MCS_ENVIRONMENT_CELESTIAL_MOON_THIRD_QUARTER
             : ph < 0.7 ? MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_CRESCENT
             : ph < 0.8 ? MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_CRESCENT
             : ph < 0.9 ? MCS_ENVIRONMENT_CELESTIAL_MOON_FIRST_QUARTER
             :            MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_GIBBOUS;
    sky.T = T;
    sky.salt = salt;

    TtFlock fl;
    fl.F = normalize(float3(-1.0, -0.36, -0.15));
    fl.U = normalize(float3(0.0, 1.0, 0.0) - fl.F * fl.F.y);
    fl.S = cross(fl.F, fl.U);
    if (fl.S.z < 0.0) fl.S = -fl.S;
    float travel = u.time * 0.65 * u.speed + u.seed * 977.0;
    float cells = floor(travel / TT_CELL.x);
    fl.shift = travel - cells * TT_CELL.x;
    fl.shiftCells = int(cells);
    fl.T = T;
    fl.time = u.time;
    fl.flapT = u.time * u.flap + u.seed * 50.0;
    fl.density = u.density * 0.9;
    fl.uMid = dot(float3(0.0, -2.6, 9.0), fl.U);
    fl.toast = u.toast;
    fl.salt = salt;

    // The cloud layer drifts the way the flock flies; whole cells are kept as
    // integers so the pattern never loses precision. The seed picks where on
    // clouds.png the camera is.
    float drift = -(T * 0.6) / TT_CLOUD_CELL;
    float driftCells = floor(drift);
    float wind = (drift - driftCells) * TT_CLOUD_CELL;
    int2 windCells = int2(int(driftCells) + int(salt & 255u), int((salt >> 8) & 255u));

    const float2 offs[2] = { float2(0.25, 0.25), float2(-0.25, -0.25) };
    float3 col = float3(0.0);
    for (int i = 0; i < TT_SAMPLES; ++i) {
        float4 p = pos;
        p.xy += offs[i];
        float2 uv = lerpUV(p, u.resolution);
        float3 rd = normalize(uv.x * right + uv.y * up + lens * TT_FOCAL * fwd);
        col += ttScene(ro, rd, pxA, sky, fl, wind, windCells, u.clouds != 0, tx);
    }
    col /= float(TT_SAMPLES);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
