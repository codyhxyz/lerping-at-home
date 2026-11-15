// Lava Veins — the slime-mould network as the lava channels of a block world.
// Original work for Lerping@Home: a block-world homage in the house sense
// (see maze.metal). Every texture is procedural and written here; nothing is
// taken from any game.
//
// The simulation is `physarum`'s, unchanged: PhysarumData.swift runs Jones'
// agents and hands over the trail. This file reads that trail as heat and
// builds a basalt landscape on it, one block per simulation cell. Where the
// trail is a live vein the rock is cut into a trench and filled with lava —
// two blocks deep along a vein's hot spine, one along its flanks. Where the
// trail is fading the vein has crusted over: magma blocks flush with the
// ground, their cracks glowing as long as there is heat left. Everywhere else
// is dark basalt terraced over rolling ground, with a few basalt columns on
// the cold rock. The only light is the lava's own and a little night sky.
//
// So the network's whole life is legible as geography. A fine mesh of
// glowing channels opens in the first seconds, then coarsens over the minute
// into a few big rivers: abandoned channels crust, dim and close, and the
// survivors deepen. At the epoch seam every vein cools to rock and a new
// network breaks through.
//
// The grid is the simulation's own torus, so the ground repeats exactly where
// the trail does and the camera can glide over it forever. Textures are 16
// texels a face, sharp up close and box-filtered to the pixel footprint
// further out, so nothing crawls while the camera moves.
//
// lerp-category: Blocks
// lerp-data: physarum
//
// lerp-param: speed    float 0 40      = 6    "Steps/sec"
// lerp-param: glow     float 0.3 2.5   = 1    "Lava light"
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
constant float LV_CRUST  = 0.34;    // magma crust from here
constant float LV_LAVA   = 0.64;    // open lava, one block down
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
// Textures: 16 x 16 texels a face. `lvTexel` is one texel; `lvSurface`
// filters a block of them to the pixel footprint.

struct LvTex { float3 alb; float3 emit; };

static inline float3 lvLavaRamp(float v) {
    // Quantised, so the lava reads as a palette of flat texels.
    v = floor(saturate(v) * 6.0) / 5.0;
    float3 a = float3(0.45, 0.035, 0.005);
    float3 b = float3(1.00, 0.24, 0.02);
    float3 c = float3(1.00, 0.72, 0.24);
    return v < 0.5 ? mix(a, b, v * 2.0) : mix(b, c, v * 2.0 - 1.0);
}

// `org` is the face's first texel in world texel units, so patterns run on
// across neighbouring blocks.
static LvTex lvTexel(int kind, bool top, int2 tx, int3 blk, float2 org,
                     float heat, float time) {
    LvTex o;
    o.emit = float3(0.0);
    int3 key = int3(blk.x * 16 + tx.x, blk.y * 16 + tx.y, blk.z * 16 + (top ? 7 : 3));
    float r = lvHash(key);
    if (kind == LV_LAVAK) {
        // Slow churning blotches, the texel grid held still while they move.
        float2 p = org + float2(tx);
        float fall = top ? 0.0 : time * 1.2;     // falls down a lava face
        float n = valueNoise(p * 0.21 + float2(time * 0.21, time * 0.13 + fall * 0.21));
        float m = valueNoise(p * 0.47 - float2(time * 0.11, -time * 0.17) + 9.0);
        float v = 0.62 * n + 0.38 * m - 0.08 + 0.6 * (heat - LV_LAVA);
        o.alb = float3(0.0);
        o.emit = lvLavaRamp(v) * 1.05;
        return o;
    }
    if (kind == LV_CRUSTK) {
        float2 p = org + float2(tx);
        float m = valueNoise(p * 0.36 + 3.0 * float(blk.y));
        float crack = 1.0 - smoothstep(0.035, 0.075, abs(m - 0.5));
        float warm = smoothstep(LV_CRUST, LV_LAVA, heat);
        o.alb = float3(0.12, 0.045, 0.03) * (0.75 + 0.5 * r);
        o.emit = crack * float3(1.0, 0.32, 0.05) * (0.25 + 1.6 * warm * warm)
               + float3(0.05, 0.008, 0.0) * warm;
        return o;
    }
    if (kind == LV_PILLAR) {
        if (top) {
            int2 d = abs(2 * tx - 15);
            int ring = max(d.x, d.y);
            float s = (ring > 12) ? 0.14 : ((ring / 4) % 2 == 0 ? 0.11 : 0.095);
            o.alb = float3(s) * float3(0.95, 0.95, 1.0) * (0.9 + 0.2 * r);
        } else {
            float g = (tx.x == 0 || tx.x == 15) ? 0.065 : ((tx.x % 4 == 1) ? 0.085 : 0.11);
            o.alb = float3(g) * float3(0.93, 0.94, 1.0) * (0.92 + 0.16 * r);
        }
        return o;
    }
    // Ash lies on the high ground.
    if (top && blk.y >= 7) {
        float coarse = lvHash(int3(blk.x * 4 + tx.x / 4, blk.z * 4 + tx.y / 4, 57));
        float s = 0.30 + 0.06 * r + 0.04 * coarse;
        if (r < 0.06) s *= 0.55;
        o.alb = float3(s) * float3(1.0, 0.93, 0.86);
        return o;
    }
    // Basalt.
    if (top) {
        float coarse = lvHash(int3(blk.x * 4 + tx.x / 4, blk.z * 4 + tx.y / 4, 91));
        float s = 0.085 + 0.035 * r + 0.03 * coarse;
        if (r > 0.94) s += 0.06;
        o.alb = float3(s) * float3(1.0, 0.95, 0.92);
    } else {
        // Vertical striations, with the odd broken course.
        float col = lvHash(int3(blk.x * 16 + tx.x + blk.z * 16, blk.y, 17));
        int brk = int(lvHash(int3(blk.x + blk.z * 7, tx.x, 23)) * 16.0);
        float s = 0.07 + 0.05 * col + 0.015 * r;
        if (tx.y == brk) s *= 0.55;
        if (tx.y >= 14) s += 0.025;          // a lighter lip under the top face
        o.alb = float3(s) * float3(0.98, 0.94, 0.93);
    }
    return o;
}

// The face's average, which the texels fade into once a texel is smaller
// than a pixel.
static inline LvTex lvMean(int kind, bool top, int3 blk, float heat) {
    LvTex o;
    o.emit = float3(0.0);
    if (kind == LV_LAVAK) {
        o.alb = float3(0.0);
        o.emit = lvLavaRamp(0.42 + 0.6 * (heat - LV_LAVA)) * 1.05;
    } else if (kind == LV_CRUSTK) {
        float warm = smoothstep(LV_CRUST, LV_LAVA, heat);
        o.alb = float3(0.12, 0.045, 0.03);
        o.emit = 0.18 * float3(1.0, 0.32, 0.05) * (0.25 + 1.6 * warm * warm)
               + float3(0.05, 0.008, 0.0) * warm;
    } else if (kind == LV_PILLAR) {
        o.alb = float3(top ? 0.11 : 0.095) * float3(0.94, 0.95, 1.0);
    } else if (top && blk.y >= 7) {
        o.alb = float3(0.33) * float3(1.0, 0.93, 0.86);
    } else {
        o.alb = (top ? float3(0.122) : float3(0.11)) * float3(1.0, 0.95, 0.92);
    }
    return o;
}

static LvTex lvSurface(int kind, bool top, float2 uv, float2 org, int3 blk, float heat,
                       float time, float fwT) {
    LvTex mean = lvMean(kind, top, blk, heat);
    float far = smoothstep(0.55, 1.6, fwT);
    if (far >= 1.0) return mean;
    // Sharp inside a texel; a pixel-wide box filter across each texel seam.
    float2 p = uv * 16.0;
    float2 seam = floor(p + 0.5);
    float2 q = seam + clamp((p - seam) / max(fwT, 1e-3), -0.5, 0.5) - 0.5;
    float2 i = floor(q), f = q - i;
    int2 a = clamp(int2(i), 0, 15), b = clamp(int2(i) + 1, 0, 15);
    // Inside a texel the weights are exactly 0 or 1: fetch only what counts.
    LvTex o = lvTexel(kind, top, int2(a.x, a.y), blk, org, heat, time);
    if (f.x > 0.0) {
        LvTex t10 = lvTexel(kind, top, int2(b.x, a.y), blk, org, heat, time);
        o.alb = mix(o.alb, t10.alb, f.x); o.emit = mix(o.emit, t10.emit, f.x);
    }
    if (f.y > 0.0) {
        LvTex r = lvTexel(kind, top, int2(a.x, b.y), blk, org, heat, time);
        if (f.x > 0.0) {
            LvTex t11 = lvTexel(kind, top, int2(b.x, b.y), blk, org, heat, time);
            r.alb = mix(r.alb, t11.alb, f.x); r.emit = mix(r.emit, t11.emit, f.x);
        }
        o.alb = mix(o.alb, r.alb, f.y); o.emit = mix(o.emit, r.emit, f.y);
    }
    o.alb  = mix(o.alb,  mean.alb,  far);
    o.emit = mix(o.emit, mean.emit, far);
    return o;
}

// ---------------------------------------------------------------------------
// Light.

// How much lava is near a point, from a handful of bilinear taps of the
// trail: open lava only, crust barely counts.
static inline float lvLavaNear(texture2d<float> tr, float2 xz, LvWorld w) {
    float g = 0.0;
    const float2 ring[6] = { float2(1.9, 0.0), float2(0.95, 1.65), float2(-0.95, 1.65),
                             float2(-1.9, 0.0), float2(-0.95, -1.65), float2(0.95, -1.65) };
    float h0 = lvHeat(tr, xz - 0.5, w);
    g += 0.34 * smoothstep(LV_CRUST, LV_DEEP, h0);
    for (int k = 0; k < 6; ++k) {
        float h = lvHeat(tr, xz - 0.5 + ring[k], w);
        g += 0.11 * smoothstep(LV_CRUST, LV_DEEP, h);
    }
    return g;
}

// Embers: sparks rising off open lava, each a camera-facing square a few
// texels across. Ten horizontal planes climb from the lava to the sky and
// wrap; where the ray crosses one over a lava block, that block may have
// thrown a spark at that height on this climb.
constant int LV_EMBER_LAYERS = 7;

static float3 lvEmbers(texture2d<float> tr, float3 ro, float3 rd, float3 right, float3 up,
                       float tLimit, float time, LvWorld w, float pxAngle) {
    float3 acc = float3(0.0);
    float invY = 1.0 / rd.y;
    for (int k = 0; k < LV_EMBER_LAYERS; ++k) {
        float cyc = time * 0.085 + float(k) / float(LV_EMBER_LAYERS) + w.salt * 0.07;
        float ci = floor(cyc), f = cyc - ci;
        float y = 1.0 + f * 13.0;
        float t = (y - ro.y) * invY;
        if (!(t > 0.0) || t > tLimit) continue;
        float2 cell = floor(ro.xz + rd.xz * t);
        float2 wc = lvWrapInv(cell, w.period, w.inv);
        float r = lvHash(int3(int(wc.x), int(wc.y), int(ci) * 31 + k * 977 + w.iseed));
        if (r > 0.057) continue;              // ~0.4 sparks per lava block per climb
        LvCol c = lvColumn(tr, cell, w);
        float rise = y - c.top;
        if (c.kind != LV_LAVAK || rise < 0.0) continue;
        float2 jit = 0.25 + 0.5 * fract(float2(r * 97.0, r * 389.0) * 9.0);
        float3 d = float3(cell.x + jit.x, y, cell.y + jit.y) - ro;
        float tE = dot(d, rd);
        float3 off = d - rd * tE;
        float age = saturate(rise / 9.0);
        float size = 0.09 * (1.0 - 0.5 * age);
        float m = max(abs(dot(off, right)), abs(dot(off, up)));
        float aa = max(pxAngle * tE, 1e-4);
        float cov = saturate((size - m) / aa + 0.5) * saturate(size / aa);
        float flick = 0.75 + 0.25 * sin(time * 7.0 + r * 900.0);
        float3 hot = mix(float3(1.0, 0.62, 0.22) * 2.4, float3(0.8, 0.12, 0.02) * 1.2, age);
        float fade = (1.0 - age * age) * smoothstep(0.0, 0.4, rise);
        float fog = smoothstep(0.4 * LV_FAR, LV_FAR, tE);
        acc += hot * cov * flick * fade * (1.0 - fog);
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
                        texture2d<float> trail [[texture(1)]]) {
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

    // --- Sky and haze.
    float3 haze = float3(0.026, 0.011, 0.013);
    float3 sky = mix(float3(0.030, 0.012, 0.020), float3(0.006, 0.005, 0.014),
                     saturate(rd.y * 2.5));
    float3 col = sky;

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
        float2 wc = lvWrap(hcell, w.period);

        // Face coordinates, 0..1 across the face, v up on the sides.
        float2 fuv, org;
        int3 blk;
        float by = floor(P.y - (top ? 0.5 : 0.0));
        if (top)              { fuv = fract(P.xz);                  blk = int3(int(wc.x), int(by), int(wc.y));         org = wc * 16.0; }
        else if (n.x != 0.0)  { fuv = float2(fract(P.z), fract(P.y)); blk = int3(int(wc.x) * 3 + 1, int(by), int(wc.y)); org = float2(wc.y, by) * 16.0; }
        else                  { fuv = float2(fract(P.x), fract(P.y)); blk = int3(int(wc.x), int(by), int(wc.y) * 3 + 2); org = float2(wc.x, by) * 16.0; }

        // A crust block shows magma only in its own top block; the rock
        // beneath it is basalt.
        int kind = hc.kind;
        if (kind == LV_CRUSTK && !top && P.y < hc.top - 1.0) kind = LV_ROCK;
        if (kind == LV_PILLAR && !top && P.y < hc.ground) kind = LV_ROCK;

        float cosA = max(abs(dot(rd, n)), 0.2);
        float fwT = 16.0 * tHit * pxAngle / cosA;
        LvTex s = lvSurface(kind, top, fuv, org, blk, hc.heat, T, fwT);

        // Corner shade: a top face darkens towards taller neighbours, a side
        // face towards the ground in front of it.
        float ao = 1.0;
        if (top) {
            // Only the nearer edge on each axis can shade this point, so only
            // two neighbours are looked up.
            float2 f = fract(P.xz);
            float2 side = select(float2(1.0), float2(-1.0), f < 0.5);
            float2 e = min(f, 1.0 - f);                 // distance to that edge
            float hx = lvColumnBeside(trail, hcell, float2(side.x, 0.0), stp, z, rx, rz, w).top;
            float hz = lvColumnBeside(trail, hcell, float2(0.0, side.y), stp, z, rx, rz, w).top;
            float y0 = hc.top + 0.01;
            float occ = step(y0, hx) * (1.0 - smoothstep(0.0, 0.5, e.x))
                      + step(y0, hz) * (1.0 - smoothstep(0.0, 0.5, e.y));
            ao = 1.0 - 0.45 * saturate(occ);
            // The lip of a drop catches the light: one texel, filtered.
            float y1 = hc.top - 0.01;
            float lipW = max(1.0 / 16.0, 0.7 * fwT / 16.0);
            float lip = max(step(hx, y1) * (1.0 - smoothstep(0.0, lipW, e.x)),
                            step(hz, y1) * (1.0 - smoothstep(0.0, lipW, e.y)));
            if (kind != LV_LAVAK) s.alb *= 1.0 + 0.6 * lip;
        } else {
            float front = lvColumnBeside(trail, hcell, n.xz, stp, z, rx, rz, w).top;
            ao = mix(0.5, 1.0, smoothstep(0.0, 0.9, P.y - front));
        }

        // Light: lava glow from below, a dim night sky from above.
        float near = lvLavaNear(trail, P.xz + n.xz * 0.6, w);
        float lift = max(0.0, P.y - (hc.ground - 1.0));
        float lavaL = near * exp(-0.22 * lift);
        float face = top ? 1.0 : (n.x != 0.0 ? 0.62 : 0.42);
        float3 light = float3(0.16, 0.17, 0.27) * face * ao
                     + u.glow * float3(1.0, 0.36, 0.10) * (2.6 * lavaL + 5.0 * lavaL * lavaL)
                       * mix(ao, 1.0, 0.4) * (top ? 0.8 : 1.0);
        col = s.alb * light + s.emit * u.glow;

        // Haze, warmed where it hangs over lava.
        float fog = smoothstep(0.4 * LV_FAR, LV_FAR, tHit);
        fog = fog * fog * (3.0 - 2.0 * fog);
        float3 h = haze + float3(0.10, 0.03, 0.01) * near * u.glow;
        col = mix(col, h, fog);
    } else {
        col = mix(sky, haze, saturate(1.0 - rd.y * 4.0));
    }
    col += u.glow * lvEmbers(trail, ro, rd, right, up, hit ? tHit : LV_FAR, T, w, pxAngle);

    // Gentle shoulder, then display gamma.
    col = 1.0 - exp(-col * 1.1);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
