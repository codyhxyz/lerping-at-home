// Lava Veins — the slime-mould network as the lava rivers of a Nether basalt delta.
// The terrain and the simulation reading are original work for Lerping@Home;
// every surface is drawn with the game's own block textures, bound from the
// copy installed on this Mac (see the "Minecraft looks" section of PORTING.md).
//
// The simulation is `physarum`'s, unchanged: PhysarumData.swift runs Jones'
// agents and hands over the trail. This file reads that trail as heat and
// builds a basalt delta on it, one block per ~1.5 simulation cells. Where the
// trail is a live vein the ground is cut into a trench of lava, still on top
// and flowing down every step. Where the vein is fading it has crusted over
// into magma blocks flush with the ground. Everywhere else is blackstone
// terraced over rolling ground, basalt on the high ground and in the column
// groves, lit the way the game lights the Nether: lava is light level 15,
// falling a level a block, through the game's lightmap and the dimension's
// ambient light, under the basalt deltas' grey-violet fog.
//
// So the network's whole life is legible as geography. A fine mesh of lava
// opens in the first seconds, then coarsens over the minute into a few big
// rivers: abandoned channels crust into magma and close. At the epoch seam
// every vein cools to rock and a new network breaks through.
//
// The grid is the simulation's own torus, so the ground repeats exactly where
// the trail does and the camera can glide over it forever.
//
// lerp-category: Minecraft
// lerp-requires: minecraft
// lerp-data: physarum
//
// lerp-param: speed    float 0 40      = 6    "Steps/sec"
// lerp-param: drift    float 0 3       = 1    "Glide speed"
// lerp-param: yaw      float -180 180  = 0    "Turn"
// lerp-param: pitch    float -30 40    = 0    "Tilt"
// lerp-param: magnify  float -1 1      = 0    "Zoom"
//
// `speed` is the provider's own: simulation steps a second (its default is 8;
// six makes an epoch 80 s and the channels reroute at a walking pace).

// --- World, in blocks.
constant float LV_HMAX   = 13.0;    // nothing stands taller than this
constant float LV_EYE    = 20.0;    // camera height
constant float LV_FAR    = 100.0;    // view distance; fog is total here
constant int   LV_STEPS  = 150;     // DDA cells, fixed bound
constant float LV_FOCAL  = 1.5;
constant float LV_TILT   = 0.60;    // camera pitch below the horizon (rad)

// Heat thresholds on the trail, which arrives as a fraction of its ceiling.
constant float LV_CRUST  = 0.46;    // magma crust from here
constant float LV_LAVA   = 0.56;    // open lava, one block down
constant float LV_DEEP   = 0.80;    // hot spine, two blocks down

// Column kinds.
constant int LV_ROCK   = 0;
constant int LV_CRUSTK = 1;
constant int LV_LAVAK  = 2;
constant int LV_PILLAR = 3;

// ---------------------------------------------------------------------------
// Hashes and the world's columns.

static inline float lvHash(int3 p) {
    uint h = uint(p.x) * 0x8da6b343u ^ uint(p.y) * 0xd8163841u ^ uint(p.z) * 0xcb1ab31fu;
    h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15; h *= 0x27d4eb2du; h ^= h >> 16;
    return float(h) * (1.0 / 4294967296.0);
}

static inline float2 lvWrap(float2 c, float2 size) { return c - size * floor(c / size); }
static inline float2 lvWrapInv(float2 c, float2 size, float2 inv) { return c - size * floor(c * inv); }

struct LvWorld {
    float2 period;   // the torus, in whole blocks
    float2 inv;      // 1 / period
    float  blend;
    float  fade;
    float  salt;     // per-seed ground
    int    iseed;
};

// Trail heat at the centre of the block whose corner is `cell`. A block is
// about 1.5 simulation cells, so one bilinear tap there averages the patch
// beneath it and channels have no single-cell pinholes.
static inline float lvHeat(texture2d<float> tr, float2 cell, LvWorld w) {
    float2 s = tr.sample(lerpPhysarumSampler, (cell + 0.5) * w.inv).rg;
    return mix(s.x, s.y, w.blend) * w.fade;
}

// Rolling ground: a few cosines whose wave vectors are whole numbers of
// periods across the torus, so the ground wraps exactly with the trail.
// Two more cosines, multiplied, place the groves of basalt columns. The
// march steps all eight as phasors (see lvMarch), so the tables are shared.
constant int    LV_WAVES = 8;          // 0..5 ground, 6..7 groves
constant float2 LV_K[LV_WAVES] = { float2( 2.0,  1.0), float2(-5.0,  4.0), float2( 7.0, -6.0),
                                   float2( 4.0, 11.0), float2(-13.0, 5.0), float2(11.0, 14.0),
                                   float2(17.0, -9.0), float2(-6.0, 19.0) };
constant float  LV_AMP[6]       = { 1.00, 0.85, 0.70, 0.55, 0.40, 0.30 };
constant float  LV_SALTK[LV_WAVES] = { 1.0, 2.1, 3.7, 5.3, 7.1, 9.9, 1.0, 2.0 };
constant float  LV_PHASE[LV_WAVES] = { 0.0, 1.0, 2.0, 0.0, 4.0, 1.5, 0.0, 0.0 };
constant float  LV_GROVE = 0.72;       // groves stand where the product exceeds this
constant float  LV_FASTAMP = 0.55 + 0.40 + 0.30;   // the most waves 3..5 can add

static inline float lvWavePhase(int j, float2 cell, LvWorld w) {
    return dot(TWO_PI * cell * w.inv, LV_K[j]) + LV_SALTK[j] * w.salt + LV_PHASE[j];
}

static inline float lvGroundOf(float h) { return clamp(floor(5.5 + 1.75 * h), 1.0, 11.0); }

static inline float lvGround(float2 cell, LvWorld w) {
    float h = 0.0;
    for (int j = 0; j < 6; ++j) h += LV_AMP[j] * cos(lvWavePhase(j, cell, w));
    return lvGroundOf(h);
}

static inline float lvGrove(float2 cell, LvWorld w) {
    return cos(lvWavePhase(6, cell, w)) * cos(lvWavePhase(7, cell, w));
}

struct LvCol {
    float top;     // y of the column's top face
    float ground;  // the undisturbed ground level
    float heat;
    int   kind;
};

static inline LvCol lvColumnFrom(texture2d<float> tr, float2 cell, LvWorld w,
                                 float ground, float grove) {
    LvCol c;
    c.heat = lvHeat(tr, cell, w);
    c.ground = ground;
    c.top = c.ground;
    c.kind = LV_ROCK;
    if (c.heat > LV_LAVA) {
        c.kind = LV_LAVAK;
        c.top = c.ground - 0.45;
    } else if (c.heat > LV_CRUST) {
        c.kind = LV_CRUSTK;
    } else if (grove > LV_GROVE && c.heat < 0.2) {
        // Basalt columns stand in groves on the cold rock.
        float2 wc = lvWrapInv(cell, w.period, w.inv);
        float r = lvHash(int3(int(wc.x), int(wc.y), w.iseed ^ 0x51a7));
        float g = (grove - LV_GROVE) / (1.0 - LV_GROVE);
        float dense = 0.06 + 0.4 * g;
        if (r < dense) {
            c.kind = LV_PILLAR;
            c.top = min(c.top + 1.0 + floor(r / dense * 2.5 + 3.5 * g), LV_HMAX);
        }
    }
    return c;
}

static inline LvCol lvColumn(texture2d<float> tr, float2 cell, LvWorld w) {
    return lvColumnFrom(tr, cell, w, lvGround(cell, w), lvGrove(cell, w));
}

// ---------------------------------------------------------------------------
// Light, as the game does it.

// Block light at an air block: lava is level 15 and the level falls by one a
// block, so it is 15 minus the taxicab distance to the nearest lava, less the
// climb above the lava's own level. Rings are searched outwards from the
// block; within two blocks every cell is read, further out eight on each ring.
// Past eight blocks the level is taken as five: below that the game's curve
// is all but the ambient floor.
constant int LV_RINGS = 5;
constant float LV_RING_R[LV_RINGS] = { 3.0, 4.0, 5.0, 6.0, 8.0 };

static inline bool lvIsLava(texture2d<float> tr, float2 cell, LvWorld w) {
    return lvHeat(tr, cell, w) > LV_LAVA;
}

static float lvLavaDistance(texture2d<float> tr, float2 cell, LvWorld w) {
    if (lvIsLava(tr, cell, w)) return 0.0;
    const float2 d1[4] = { float2(1, 0), float2(0, 1), float2(-1, 0), float2(0, -1) };
    for (int k = 0; k < 4; ++k) if (lvIsLava(tr, cell + d1[k], w)) return 1.0;
    const float2 d2[8] = { float2(2, 0), float2(0, 2), float2(-2, 0), float2(0, -2),
                           float2(1, 1), float2(-1, 1), float2(-1, -1), float2(1, -1) };
    for (int k = 0; k < 8; ++k) if (lvIsLava(tr, cell + d2[k], w)) return 2.0;
    for (int r = 0; r < LV_RINGS; ++r) {
        float R = LV_RING_R[r], H = floor(R * 0.5);
        const float2 dir[4] = { float2(1, 0), float2(0, 1), float2(-1, 0), float2(0, -1) };
        for (int k = 0; k < 4; ++k) {
            float2 a = dir[k], b = float2(-a.y, a.x);
            if (lvIsLava(tr, cell + a * R, w)) return R;
            if (lvIsLava(tr, cell + a * (R - H) + b * H, w)) return R;
        }
    }
    return 10.0;
}

// The basalt deltas' fog is also all the Nether has for a sky.
constant float  LV_FOG_NEAR = 18.0;

static inline float lvFog(float t) {
    return saturate((t - LV_FOG_NEAR) / (LV_FAR - LV_FOG_NEAR));
}

// Lava pops: the game's lava particle, thrown up off open lava. Planes climb
// through the air and wrap; where the ray crosses one over a lava block, that
// block may have thrown a pop at that height on this climb. Each is a
// camera-facing sprite that shrinks as it rises, full bright as the game
// draws it.
constant int LV_EMBER_LAYERS = 7;

static float4 lvEmbers(texture2d<float> tr, texture2d_array<float> skins, float3 ro, float3 rd,
                       float3 right, float3 up, float tLimit, float time, LvWorld w, float pxAngle) {
    float4 acc = float4(0.0);                // premultiplied colour, coverage
    float invY = 1.0 / rd.y;
    for (int k = 0; k < LV_EMBER_LAYERS; ++k) {
        float cyc = time * 0.16 + float(k) / float(LV_EMBER_LAYERS) + w.salt * 0.07;
        float ci = floor(cyc), f = cyc - ci;
        float y = 1.0 + f * 13.0;
        float t = (y - ro.y) * invY;
        if (!(t > 0.0) || t > tLimit) continue;
        float2 cell = floor(ro.xz + rd.xz * t);
        float2 wc = lvWrapInv(cell, w.period, w.inv);
        float r = lvHash(int3(int(wc.x), int(wc.y), int(ci) * 31 + k * 977 + w.iseed));
        if (r > 0.08) continue;
        LvCol c = lvColumn(tr, cell, w);
        float rise = y - c.top;
        if (c.kind != LV_LAVAK || rise < 0.0 || rise > 3.0) continue;
        float2 jit = 0.25 + 0.5 * fract(float2(r * 97.0, r * 389.0) * 9.0);
        float3 d = float3(cell.x + jit.x, y, cell.y + jit.y) - ro;
        float tE = dot(d, rd);
        float3 off = d - rd * tE;
        float size = 0.11 * (1.0 - 0.6 * rise / 3.0);     // half-width, in blocks
        float2 q = float2(dot(off, right), dot(off, up)) / size;
        if (max(abs(q.x), abs(q.y)) > 1.0) continue;
        float2 px = float2(0.5 + 0.5 * q.x, 0.5 - 0.5 * q.y) * MCS_PARTICLE_LAVA_SIZE;
        float wpx = pxAngle * tE / (2.0 * size) * MCS_PARTICLE_LAVA_SIZE.x;
        float4 s = mcSkin(skins, MCS_PARTICLE_LAVA, px, wpx);
        float a = s.a * (1.0 - lvFog(tE)) * (1.0 - acc.a);
        acc += float4(s.rgb * a, a);
    }
    return acc;
}

// The column one block from the hit along x or z, its slow waves turned on
// from the march's own phasors rather than recomputed.
static LvCol lvColumnBeside(texture2d<float> tr, float2 cell, float2 d, float2 stp,
                            thread const float2* z, thread const float2* rx,
                            thread const float2* rz, LvWorld w) {
    float2 zz[5];
    for (int k = 0; k < 5; ++k) {
        float2 r = d.x != 0.0 ? rx[k] : rz[k];
        float back = d.x != 0.0 ? d.x * stp.x : d.y * stp.y;   // -1: turn the other way
        r.y *= back;
        zz[k] = float2(z[k].x * r.x - z[k].y * r.y, z[k].x * r.y + z[k].y * r.x);
    }
    float2 c = cell + d;
    float h = LV_AMP[0] * zz[0].x + LV_AMP[1] * zz[1].x + LV_AMP[2] * zz[2].x;
    for (int j = 3; j < 6; ++j) h += LV_AMP[j] * cos(lvWavePhase(j, c, w));
    return lvColumnFrom(tr, c, w, lvGroundOf(h), zz[3].x * zz[4].x);
}

// ---------------------------------------------------------------------------

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpPhysarumFrame& F [[buffer(1)]],
                        texture2d<float> trail [[texture(1)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]]) {
    LvWorld w;
    float2 cells = float2(trail.get_width(), trail.get_height());
    w.period = max(round(cells / 1.5), 16.0);
    w.inv = 1.0 / w.period;
    w.blend = F.blend;
    // The provider fades the trail through its epoch seam; a square root keeps
    // the lava up for most of that, so the world is cold for ~3 s, not ~6.
    w.fade = sqrt(saturate(F.fade));
    w.salt = u.seed * 37.0;
    w.iseed = int(u.seed * 65536.0);

    // --- Camera: a slow glide that meanders across the torus.
    float T = u.time;
    float a0 = u.seed * TWO_PI * 3.0;
    float2 d0 = float2(cos(a0), sin(a0)), d1 = float2(-d0.y, d0.x);
    float v = 0.85 * u.drift;
    float om = 0.019, amp = 16.0 * min(u.drift, 1.0);
    float ph = u.seed * 11.0;
    float2 start = fract(float2(u.seed * 7.13, u.seed * 3.71)) * w.period;
    // Everything is periodic, so the camera is folded back onto the torus.
    float2 camXZ = lvWrap(start + d0 * v * T + d1 * amp * sin(om * T + ph), w.period);
    float2 head = normalize(d0 * max(v, 0.05) + d1 * amp * om * cos(om * T + ph) + 1e-5);
    float3 ro = float3(camXZ.x, LV_EYE + 1.5 * sin(0.013 * T + ph), camXZ.y);
    float3 fwd = normalize(float3(head.x * cos(LV_TILT), -sin(LV_TILT), head.y * cos(LV_TILT)));
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 right = normalize(cross(upHint, fwd));
    float lens = lerpLook(u.yaw, u.pitch, u.magnify, upHint, right, fwd);
    float3 up = cross(fwd, right);
    // A portrait screen keeps the landscape's vertical field and narrows the
    // horizontal one, rather than looking up into empty sky.
    float tallness = max(1.0, u.resolution.y / u.resolution.x / 1.25);
    float2 uv = lerpUV(pos, u.resolution) / tallness;
    float focal = lens * LV_FOCAL;
    float3 rd = normalize(uv.x * right + uv.y * up + focal * fwd);
    float pxAngle = 2.0 / (focal * tallness * min(u.resolution.x, u.resolution.y));

    float3 fogCol = MC_FOG_BASALT_DELTAS;
    float3 col = fogCol;

    // --- Heightfield DDA, from where the ray drops below the tallest column.
    bool hit = false;
    float tHit = 0.0;
    float3 n = float3(0.0, 1.0, 0.0);
    LvCol hc;
    float2 hcell = float2(0.0);
    const int NS = 5;                        // waves 0, 1, 2 (ground) and 6, 7 (groves)
    const int ids[NS] = { 0, 1, 2, 6, 7 };
    float2 z[NS], rx[NS], rz[NS];
    float2 stp = float2(1.0);
    if (rd.y < 0.0 || ro.y < LV_HMAX) {
        float t = ro.y > LV_HMAX ? (LV_HMAX - ro.y) / rd.y : 0.0;
        float3 p = ro + rd * t;
        float2 rxz = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
        float2 inv = 1.0 / rxz;
        float2 cell = floor(p.xz);
        stp = sign(rxz);
        float2 tDelta = abs(inv);
        float2 tMax = t + (cell + step(0.0, rxz) - p.xz) * inv;
        int axis = -1;
        // The slow waves, stepped as phasors: crossing into the next cell
        // along x or z turns each by a fixed angle, a complex multiply rather
        // than a cos. Slow ground waves 0-2 bound the ground from above (the
        // fast ones can add at most LV_FASTAMP), so the fast waves are only
        // evaluated, and the trail only read, once the ray is low enough that
        // the column could stop it.
        for (int k = 0; k < NS; ++k) {
            int j = ids[k];
            float ph = lvWavePhase(j, cell, w);
            z[k] = float2(cos(ph), sin(ph));
            float ax = TWO_PI * w.inv.x * LV_K[j].x * stp.x;
            float az = TWO_PI * w.inv.y * LV_K[j].y * stp.y;
            rx[k] = float2(cos(ax), sin(ax));
            rz[k] = float2(cos(az), sin(az));
        }
        for (int i = 0; i < LV_STEPS; ++i) {
            float hs = LV_AMP[0] * z[0].x + LV_AMP[1] * z[1].x + LV_AMP[2] * z[2].x;
            float grove = z[3].x * z[4].x;
            float yIn = ro.y + rd.y * t;
            float tExit = min(tMax.x, tMax.y);
            float yOut = ro.y + rd.y * tExit;
            float yLow = min(yIn, yOut);
            // Lava and crust never stand above the ground; only a column can.
            float bound = grove > LV_GROVE ? LV_HMAX : lvGroundOf(hs + LV_FASTAMP);
            if (yLow < bound) {
                float h = hs;
                for (int j = 3; j < 6; ++j) h += LV_AMP[j] * cos(lvWavePhase(j, cell, w));
                float ground = lvGroundOf(h);
                if (yLow < (grove > LV_GROVE ? LV_HMAX : ground)) {
                    LvCol c = lvColumnFrom(trail, cell, w, ground, grove);
                    if (yIn < c.top) {
                        hit = true; tHit = t; hc = c; hcell = cell;
                        n = axis == 0 ? float3(-stp.x, 0.0, 0.0) : float3(0.0, 0.0, -stp.y);
                        break;
                    }
                    if (yOut < c.top) {
                        hit = true; tHit = (c.top - ro.y) / rd.y; hc = c; hcell = cell;
                        n = float3(0.0, 1.0, 0.0);
                        break;
                    }
                }
            }
            if (tExit > LV_FAR || (rd.y > 0.0 && yOut > LV_HMAX)) break;
            if (tMax.x < tMax.y) {
                t = tMax.x; tMax.x += tDelta.x; cell.x += stp.x; axis = 0;
                for (int k = 0; k < NS; ++k)
                    z[k] = float2(z[k].x * rx[k].x - z[k].y * rx[k].y, z[k].x * rx[k].y + z[k].y * rx[k].x);
            } else {
                t = tMax.y; tMax.y += tDelta.y; cell.y += stp.y; axis = 1;
                for (int k = 0; k < NS; ++k)
                    z[k] = float2(z[k].x * rz[k].x - z[k].y * rz[k].y, z[k].x * rz[k].y + z[k].y * rz[k].x);
            }
        }
    }

    if (hit) {
        float3 P = ro + rd * tHit;
        bool top = n.y > 0.5;

        // Texture coordinates run on in world units (the tiles repeat), and
        // their change across one screen pixel comes from the ray's
        // differentials against the face's plane, exact for a flat face.
        float3 dir = uv.x * right + uv.y * up + focal * fwd;
        float sc = tHit / length(dir);
        float pxUV = 2.0 / (tallness * min(u.resolution.x, u.resolution.y));
        float dn = dot(dir, n);
        float3 dPx = sc * pxUV * (right - dir * dot(right, n) / dn);
        float3 dPy = sc * pxUV * (up    - dir * dot(up,    n) / dn);
        float2 tuv, dux, duy;
        if (top)             { tuv = P.xz;                 dux = dPx.xz;                 duy = dPy.xz; }
        else if (n.x != 0.0) { tuv = float2(P.z, -P.y);    dux = float2(dPx.z, -dPx.y);  duy = float2(dPy.z, -dPy.y); }
        else                 { tuv = float2(P.x, -P.y);    dux = float2(dPx.x, -dPx.y);  duy = float2(dPy.x, -dPy.y); }
        float foot = min(length(dux), length(duy));

        // Which block this face belongs to, and so which texture.
        float blockY = top ? hc.top - 1.0 : floor(P.y);
        int kind = hc.kind;
        if (kind == LV_CRUSTK && !top && P.y < hc.top - 1.0) kind = LV_ROCK;
        if (kind == LV_PILLAR && !top && P.y < hc.ground) kind = LV_ROCK;
        bool high = blockY >= 6.0;            // basalt on the high ground, blackstone below
        float3 tex;
        bool bright = false;                  // lava and magma draw at full brightness
        if (kind == LV_LAVAK) {
            bright = true;
            if (top) {
                tex = mcTileAniso(mcTiles, mcFrame(MC_LAVA_STILL, MC_LAVA_STILL_FRAMES, MC_LAVA_STILL_TICKS, T),
                                  tuv, dux, duy).rgb;
            } else {
                // A lava fall: the flowing texture, half of its 32 px a block.
                int f = mcFrame(MCS_BLOCK_LAVA_FLOW, MCS_BLOCK_LAVA_FLOW_FRAMES, MCS_BLOCK_LAVA_FLOW_TICKS, T);
                tex = mcSkin(mcSkins, f, fract(tuv) * 16.0, foot * 16.0).rgb;
            }
        } else if (kind == LV_CRUSTK) {
            bright = true;
            tex = mcTileAniso(mcTiles, mcFrame(MC_MAGMA, MC_MAGMA_FRAMES, MC_MAGMA_TICKS, T), tuv, dux, duy).rgb;
        } else if (kind == LV_PILLAR || high) {
            tex = mcTileAniso(mcTiles, top ? MC_BASALT_TOP : MC_BASALT_SIDE, tuv, dux, duy).rgb;
        } else {
            tex = mcTileAniso(mcTiles, top ? MC_BLACKSTONE_TOP : MC_BLACKSTONE, tuv, dux, duy).rgb;
        }

        // Smooth lighting's corner shade: a top face darkens towards taller
        // neighbours, a side face towards the ground in front of it.
        float ao = 1.0;
        if (top) {
            // Only the nearer edge on each axis can shade this point, so only
            // two neighbours are looked up.
            float2 f = fract(P.xz);
            float2 side = select(float2(1.0), float2(-1.0), f < 0.5);
            float2 e = min(f, 1.0 - f);
            float hx = lvColumnBeside(trail, hcell, float2(side.x, 0.0), stp, z, rx, rz, w).top;
            float hz = lvColumnBeside(trail, hcell, float2(0.0, side.y), stp, z, rx, rz, w).top;
            float y0 = hc.top + 0.01;
            float occ = step(y0, hx) * (1.0 - smoothstep(0.0, 0.5, e.x))
                      + step(y0, hz) * (1.0 - smoothstep(0.0, 0.5, e.y));
            ao = 1.0 - 0.4 * saturate(occ);
        } else {
            float front = lvColumnBeside(trail, hcell, n.xz, stp, z, rx, rz, w).top;
            ao = mix(0.6, 1.0, smoothstep(0.0, 0.9, P.y - front));
        }

        // Light level of the air block this face looks into.
        float level = 15.0;
        if (!bright) {
            float3 air = floor(P + n * 0.5);
            float lavaY = hc.ground - 1.0;            // lava sits a block below the banks
            float d = lvLavaDistance(trail, air.xz, w) + max(0.0, air.y - lavaY);
            level = max(0.0, 15.0 - d);
        }
        col = tex * mcFaceShade(n) * mcLightmap(level, 0.0, 0.0, 0.1) * (bright ? 1.0 : ao);
        col = mix(col, fogCol, lvFog(tHit));
    }
    float4 pops = lvEmbers(trail, mcSkins, ro, rd, right, up, hit ? tHit : LV_FAR, T, w, pxAngle);
    col = col * (1.0 - pops.a) + pops.rgb;

    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
