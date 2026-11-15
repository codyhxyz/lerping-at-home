// Toaster Flight — an homage to Berkeley Systems' "Flying Toasters" (After
// Dark, 1989), rebuilt in blocks. Original work for Lerping@Home; no code,
// sprites or artwork from the original. What it keeps is the idea: a
// formation of winged toasters, and slices of toast, flying down and across
// the screen forever.
//
// lerp-category: Minecraft
//
// What it becomes when the world is made of cubes: the toasters are box
// models with pixel textures (chrome in banded grey texels, or the odd
// enamel one, glowing elements down in the slots), the wings are one-texel-
// thick feathered boards hinged at the top edges, and the toast is a pixel
// slice with a crust; now and then a toaster finishes a slice and it rises
// out of the slot. The black void became a night over a deck of flat block
// clouds, with a square moon and square stars and a few town lights far
// below the gaps. The formation streams down across the sky towards the deck.
//
// The formation is a lattice in the flock's own frame, so every toaster
// shares one orientation and the ray is turned into that frame once. The
// lattice moves along the flight line; a cell holds at most one flyer, kept
// inside its cell, so the first cell the ray finds a hit in is the nearest.
// Flyers live only in a slab of the side axis in front of the camera: their
// distance from the camera's line never changes, so none can fly through the
// lens and none pops in or out. Texels are nearest-sampled with a footprint-
// wide smoothstep between them, so they stay hard up close and calm far off.
//
// lerp-param: speed    float 0.2 2.5 = 1     "Flight speed"
// lerp-param: density  float 0.05 1  = 0.42  "Toasters"
// lerp-param: toast    float 0 1     = 0.3   "Share of toast"
// lerp-param: flap     float 0.3 2.5 = 0.8   "Wingbeat"
// lerp-param: clouds   float 0 1     = 0.5   "Cloud cover"
// lerp-param: colorZenith  color = (0.012, 0.018, 0.055) "Sky"
// lerp-param: colorHorizon color = (0.11, 0.10, 0.22)   "Horizon"
// lerp-param: colorCloud   color = (0.52, 0.56, 0.70)   "Clouds"
// lerp-param: colorMoon    color = (0.93, 0.94, 0.86)   "Moon"
// lerp-param: stars    float 0 1     = 1     "Stars"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -45 45   = 0 "Tilt"
// lerp-param: magnify  float -1 1     = 0 "Zoom"
//
// lerp-preset: Void clouds=0, colorZenith=(0,0,0), colorHorizon=(0.02,0.02,0.03), stars=0.35, density=0.55
// lerp-preset: Dusk colorZenith=(0.06,0.07,0.2), colorHorizon=(0.55,0.27,0.24), colorCloud=(0.78,0.6,0.62), colorMoon=(1.0,0.82,0.55), stars=0.3
// lerp-preset: Daylight colorZenith=(0.22,0.42,0.82), colorHorizon=(0.62,0.76,0.95), colorCloud=(0.97,0.97,1.0), colorMoon=(1.0,0.97,0.8), stars=0, clouds=0.42

constant float  TT_TEX    = 10.0;                 // model texels per block
constant float3 TT_CELL   = float3(3.6, 3.4, 3.4); // lattice cell, blocks (flock frame)
constant int    TT_STEPS  = 30;
constant float  TT_NEAR_S = 3.0;                  // flyers start this far to the side
constant float  TT_FAR_S  = 15.0;
constant float  TT_BEAM   = 4.2;                  // half-height of the stream, blocks
constant float  TT_FAR    = 26.0;                 // flyers fade out by here
constant float  TT_FOCAL  = 1.35;
constant float  TT_CLOUD_TOP = -12.0;
constant float  TT_CLOUD_BOT = -15.0;
constant float  TT_CLOUD_CELL = 7.0;
constant int    TT_CLOUD_STEPS = 26;
constant float  TT_CLOUD_FAR = 240.0;
constant float  TT_GROUND = -48.0;
constant int    TT_SAMPLES = 2;

// ---------------------------------------------------------------------------
// Hashes.

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
static inline float ttHashTx(int2 c, uint salt) {
    return float(ttPcg(uint(c.x) ^ ttPcg(uint(c.y) ^ salt))) * (1.0 / 4294967296.0);
}
static inline float3 ttLin(float3 c) { return c * c; }   // cheap sRGB -> linear

// ---------------------------------------------------------------------------
// Sky: gradient, a square moon with its square halo, square stars on a cube.

struct TtSky {
    float3 zen, hor, moon, cloud;
    float3 L;          // toward the moon
    float3 cf, cr, cu; // the camera's resting frame: the moon is square in it
    float2 mc;         // the moon's centre on that frame's picture plane
    float stars;
    float T;
    uint salt;
};

constant float TT_MOON_R = 0.055;

static inline float3 ttSkyBase(float3 rd, TtSky k) {
    float h = rd.y;
    float3 c = mix(k.hor, k.zen, smoothstep(-0.02, 0.55, h));
    c += k.hor * 0.6 * exp(-abs(h) * 14.0);                      // horizon band
    // Square halo: Chebyshev distance on the moon's own face.
    float md = dot(rd, k.cf);
    if (md > 0.05) {
        float2 m = float2(dot(rd, k.cr), dot(rd, k.cu)) / md - k.mc;
        float g = max(abs(m.x), abs(m.y));
        c += k.moon * (0.10 * exp(-max(g - TT_MOON_R, 0.0) * 9.0)
                     + 0.05 * exp(-max(g - TT_MOON_R, 0.0) * 2.2));
    }
    return c;
}

static inline float3 ttSky(float3 rd, TtSky k, float pxA) {
    float3 c = ttSkyBase(rd, k);
    // Stars: one texel each on a cube map 220 texels a face.
    if (k.stars > 0.0 && rd.y > 0.0) {
        float3 a = abs(rd);
        float2 f; int face;
        if (a.x > a.y && a.x > a.z) { f = rd.yz / a.x; face = rd.x > 0.0 ? 0 : 1; }
        else if (a.y > a.z)        { f = rd.xz / a.y; face = 2; }
        else                       { f = rd.xy / a.z; face = rd.z > 0.0 ? 4 : 5; }
        int2 cell = int2(floor(f * 110.0));
        float h = ttHashTx(cell + int2(face * 977, face * 131), k.salt ^ 0x51u);
        if (h < 0.022) {
            float b = h / 0.022;
            float tw = 0.75 + 0.25 * sin(k.T * (0.4 + 1.3 * b) + b * 40.0);
            float bright = (0.25 + 0.75 * b * b) * tw;
            float3 sc = mix(float3(0.75, 0.82, 1.0), float3(1.0, 0.9, 0.75), fract(b * 7.0));
            c += sc * bright * k.stars * smoothstep(0.02, 0.25, rd.y) * 0.9;
        }
    }
    // The moon: an 8x8 texel square.
    float md = dot(rd, k.cf);
    if (md > 0.05) {
        float2 m = float2(dot(rd, k.cr), dot(rd, k.cu)) / md - k.mc;
        float2 q = m / TT_MOON_R;
        if (abs(q.x) < 1.0 && abs(q.y) < 1.0) {
            int2 tx = int2(floor((q * 0.5 + 0.5) * 8.0));
            float v = ttHashTx(tx, 0x3a7u);
            float s = 1.0;
            if (v < 0.22) s = 0.78;                         // maria
            else if (v < 0.30) s = 0.88;
            if (tx.x == 0 || tx.y == 0) s *= 0.9;          // a shaded edge
            c = k.moon * s * 1.15;
        }
    }
    return c;
}

// ---------------------------------------------------------------------------
// Model textures. Parts: 0 body, 1 lever, 2 wing, 3 toast slice.
// Faces: 0 +x 1 -x 2 +y 3 -y 4 +z 5 -z (in the part's own frame).
// Returns linear albedo, and in .w how much the slot elements glow.

constant float TT_CHROME[7] = { 0.16, 0.50, 0.95, 0.60, 0.34, 0.70, 0.97 };
constant int   TT_WING_TAIL[10] = { 0, 0, 0, 1, 1, 2, 3, 4, 5, 6 };

static inline bool ttWingMask(int a, int c) {
    return a >= TT_WING_TAIL[c] && a <= (c >= 8 ? 8 : 9);
}
// A slice: a square loaf with a wider, rounded crown.
static inline bool ttToastMask(int a, int b) {
    if (a < 0 || a > 7 || b < 0 || b > 7) return false;
    if (b == 6) return true;
    return a >= 1 && a <= 6;
}

// var: x < 0.7 chrome, else enamel; yzw enamel colour (linear) or toast data.
static inline float4 ttTexel(int part, int face, int2 tx, float4 var, uint salt) {
    float n = ttHashTx(tx + int2(face * 31, part * 17), salt);
    if (part == 0) {
        bool chrome = var.x < 0.7;
        float3 metal = float3(0.80, 0.84, 0.92);
        if (face == 2) {                                     // top: two slots
            int a = tx.x, c = tx.y;
            if ((c == 1 || c == 4) && a >= 1 && a <= 8) {
                float glow = (a == 1 || a == 8) ? 0.45 : 0.8 + 0.2 * n;
                return float4(float3(0.02), glow);
            }
            bool rim = a == 0 || a == 9 || c == 0 || c == 5;
            float3 base = chrome ? metal * (rim ? 0.95 : 0.72) : var.yzw * (rim ? 0.75 : 1.0);
            return float4(base * (0.94 + 0.12 * n), 0.0);
        }
        if (face == 3) return float4(float3(0.03), 0.0);     // underside
        int b = clamp(tx.y, 0, 6);
        float row = TT_CHROME[b];
        int a = tx.x;
        int lastA = (face <= 1) ? 5 : 9;
        float edge = (a == 0 || a == lastA) ? 0.78 : 1.0;
        float3 c;
        if (b == 0) c = float3(0.035);                       // black base trim
        else if (chrome || b == 6) c = metal * row;
        else c = var.yzw * (0.62 + 0.55 * (row - 0.55));
        if (face == 0 && (a == 2 || a == 3) && b >= 2 && b <= 5) c = float3(0.03);  // lever slot
        return float4(c * edge * (0.95 + 0.1 * n), 0.0);
    }
    if (part == 1) return float4(float3(face == 2 ? 0.05 : 0.025), 0.0);
    if (part == 2) {                                          // feathers
        int a = clamp(tx.x, 0, 9), c = clamp(tx.y, 0, 9);
        float s = 1.0;
        if (c >= 4 && (a & 1) == 0) s = 0.90;                // primaries
        if (a == TT_WING_TAIL[c]) s = 0.76;                   // feather tips
        if (a >= (c >= 8 ? 8 : 9)) s = 0.84;                 // leading edge
        if (c == 0) s = 0.62;                                // the hinge
        if (face <= 3) s *= 0.85;                            // edges
        return float4(float3(0.99, 0.97, 0.93) * s * (0.97 + 0.06 * n), 0.0);
    }
    // Toast. var.y = doneness, var.z = butter.
    int a = clamp(tx.x, 0, 7), b = clamp(tx.y, 0, 7);
    float3 crust = mix(float3(0.58, 0.30, 0.10), float3(0.25, 0.11, 0.035), var.y);
    if (face <= 3) return float4(crust * (0.9 + 0.2 * n), 0.0);
    bool border = !ttToastMask(a - 1, b) || !ttToastMask(a + 1, b)
               || !ttToastMask(a, b - 1) || !ttToastMask(a, b + 1);
    if (border) return float4(crust * (0.9 + 0.2 * n), 0.0);
    if (var.z > 0.55 && a >= 3 && a <= 4 && b >= 3 && b <= 4) {
        float3 butter = float3(0.98, 0.80, 0.30);
        return float4(butter * ((a == 3 && b == 4) ? 1.05 : 0.9), 0.0);
    }
    float3 crumb = mix(float3(1.0, 0.86, 0.55), float3(0.66, 0.36, 0.13), var.y);
    return float4(crumb * (0.86 + 0.24 * n), 0.0);
}

// Nearest texels with a footprint-wide blend at each texel edge: hard when a
// texel covers many pixels, a box filter when it covers about one.
static inline float4 ttFiltered(int part, int face, float2 q, float wf, float4 var,
                                uint salt, int2 lim) {
    float2 g = q - 0.5;
    float2 i0 = floor(g);
    float2 f = g - i0;
    float w = max(wf, 1e-3);
    float2 fs = clamp((f - 0.5) / w + 0.5, 0.0, 1.0);
    int2 b0 = clamp(int2(i0), int2(0), lim);
    int2 b1 = clamp(int2(i0) + 1, int2(0), lim);
    float4 c00 = ttTexel(part, face, b0, var, salt);
    float4 c10 = ttTexel(part, face, int2(b1.x, b0.y), var, salt);
    float4 c01 = ttTexel(part, face, int2(b0.x, b1.y), var, salt);
    float4 c11 = ttTexel(part, face, b1, var, salt);
    return mix(mix(c00, c10, fs.x), mix(c01, c11, fs.x), fs.y);
}

// ---------------------------------------------------------------------------
// Geometry.

struct TtHit {
    float t;        // along the ray, in model texels
    float3 n;       // normal in the flock frame
    float2 q;       // face coordinates, texels
    int part, face;
    int2 lim;       // texel extent - 1 on this face
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

static inline int ttFace(int axis, float3 nrm) {
    float s = axis == 0 ? nrm.x : (axis == 1 ? nrm.y : nrm.z);
    return axis * 2 + (s > 0.0 ? 0 : 1);
}
static inline float2 ttFaceUV(int axis, float3 p) {
    return axis == 0 ? p.zy : (axis == 1 ? p.xz : p.xy);
}

// A plain part: box [bmin, bmax] in model texels.
static inline void ttPart(float3 o, float3 d, float3 bmin, float3 bmax, int part,
                          thread TtHit& h) {
    float3 nrm; int axis = 0;
    float t = ttBox(o, d, bmin, bmax, nrm, axis);
    if (t >= h.t) return;
    float3 p = o + d * t - bmin;
    float3 ext = bmax - bmin;
    h.t = t; h.n = nrm; h.part = part; h.face = ttFace(axis, nrm);
    h.q = ttFaceUV(axis, p);
    float2 e = ttFaceUV(axis, ext);
    h.lim = int2(ceil(e)) - 1;
}

// One wing, hinged along x at (0, hy, hz) and swung up by `ang`; mirror = -1
// for the left wing. The board is 10 long, 10 out and one texel thick.
static inline void ttWing(float3 o, float3 d, float hy, float hz, float ang, float mirror,
                          thread TtHit& h) {
    float3 r = o - float3(0.0, hy, hz);
    r.z *= mirror;
    float3 dd = float3(d.x, d.y, d.z * mirror);
    float sa = sin(ang), ca = cos(ang);
    // Wing frame: x along the body, y out along the span, z through the board.
    float3 wo = float3(r.x, r.y * sa + r.z * ca, r.y * ca - r.z * sa);
    float3 wd = float3(dd.x, dd.y * sa + dd.z * ca, dd.y * ca - dd.z * sa);
    float3 nrm; int axis = 0;
    float3 bmin = float3(-5.0, 0.0, -0.5), bmax = float3(5.0, 10.0, 0.5);
    float t = ttBox(wo, wd, bmin, bmax, nrm, axis);
    if (t >= h.t) return;
    float3 p = wo + wd * t - bmin;
    int2 tx = clamp(int2(floor(p.xy)), int2(0), int2(9));
    if (!ttWingMask(tx.x, tx.y)) return;
    // Back to the body frame.
    float3 nb = float3(nrm.x, nrm.y * sa + nrm.z * ca, nrm.y * ca - nrm.z * sa);
    nb.z *= mirror;
    h.t = t; h.n = nb; h.part = 2;
    h.face = ttFace(axis, nrm);
    h.q = p.xy;               // feathers on every face read from (along, out)
    h.lim = int2(9);
}

// ---------------------------------------------------------------------------
// The flock.

struct TtFlock {
    float3 F, U, S;          // flight, up, side (S points away from the camera)
    float uMid;              // the stream's centre on the up axis
    float shift;             // lattice travel within one cell, blocks
    int shiftCells;
    float T, flapT;
    float density, toast;
    uint salt;
};

struct TtSurf {
    float t;                 // blocks
    float3 n;                // world
    float4 alb;              // linear albedo, glow
    float refl;
    int part;
};

static bool ttCell(int3 c, float3 oq, float3 d, TtFlock fl, float pxA,
                   float3 rdW, thread TtSurf& s) {
    int3 gid = int3(c.x - fl.shiftCells, c.y, c.z);
    float4 h = ttHash4(gid, fl.salt);
    if (h.x >= fl.density) return false;
    float3 cc = (float3(c) + 0.5) * TT_CELL;
    float sCenter = cc.z;
    if (sCenter < TT_NEAR_S || sCenter > TT_FAR_S) return false;
    if (abs(cc.y - fl.uMid) > TT_BEAM) return false;
    float4 h2 = ttHash4(gid, fl.salt ^ 0x7f4a7c15u);
    // Jitter within the cell, plus a slow drift fore and aft.
    cc += (h2.xyz - 0.5) * float3(1.0, 0.4, 0.5);
    cc.x += 0.28 * sin(fl.T * (0.11 + 0.08 * h2.w) + h.w * 30.0);
    bool isToast = h.y < fl.toast;

    // Into model texels, centred on the flyer.
    float3 o = (oq - cc) * TT_TEX;
    TtHit hit; hit.t = 1e9;
    float4 var;
    if (isToast) {
        // A slice tumbling slowly end over end about the side axis.
        float a = fl.T * (0.25 + 0.3 * h2.w) * (h.z < 0.5 ? 1.0 : -1.0) + h.w * 6.283;
        float ca = cos(a), sa = sin(a);
        float3 ro = float3(ca * o.x + sa * o.y, -sa * o.x + ca * o.y, o.z);
        float3 rd = float3(ca * d.x + sa * d.y, -sa * d.x + ca * d.y, d.z);
        float3 nrm; int axis = 0;
        float3 bmin = float3(-4.0, -4.0, -0.5), bmax = float3(4.0, 4.0, 0.5);
        float t = ttBox(ro, rd, bmin, bmax, nrm, axis);
        if (t > 1e8) return false;
        float3 p = ro + rd * t - bmin;
        int2 tx = clamp(int2(floor(p.xy)), int2(0), int2(7));
        if (!ttToastMask(tx.x, tx.y)) return false;
        hit.t = t;
        hit.n = float3(ca * nrm.x - sa * nrm.y, sa * nrm.x + ca * nrm.y, nrm.z);
        hit.part = 3; hit.face = ttFace(axis, nrm);
        hit.q = p.xy; hit.lim = int2(7);
        var = float4(0.0, h2.w * h2.w * 0.8, fract(h.z * 7.13), 0.0);
    } else {
        // Quick reject against the whole toaster's bounds.
        float3 nn; int ax = 0;
        if (ttBox(o, d, float3(-5.5, -5.0, -13.5), float3(6.5, 14.0, 13.5), nn, ax) > 1e8)
            return false;
        float bob = 0.9 * sin(fl.flapT * 6.283 * 1.1 + h.w * 6.283 + 1.4);
        o.y -= bob;
        ttPart(o, d, float3(-5.0, -4.0, -3.0), float3(5.0, 3.0, 3.0), 0, hit);
        ttPart(o, d, float3(5.0, -1.0, -1.0), float3(6.5, 0.0, 1.0), 1, hit);
        float ang = 0.55 + 0.75 * sin(fl.flapT * 6.283 * 1.1 + h.w * 6.283);
        ttWing(o, d, 3.0, 3.0, ang, 1.0, hit);
        ttWing(o, d, 3.0, -3.0, ang, -1.0, hit);
        // Some are making toast: a slice rises out of one slot, waits, and
        // sinks back, each toaster on its own slow cycle.
        if (h2.w > 0.5) {
            float ph = fract(fl.T * (0.045 + 0.03 * h.z) + h.y * 7.0);
            float rise = smoothstep(0.0, 0.04, ph) * (1.0 - smoothstep(0.55, 0.68, ph));
            float top = 2.0 + 4.0 * rise;
            float z0 = (h.w < 0.5) ? -2.0 : 1.0;
            float3 bmin = float3(-4.0, top - 8.0, z0), bmax = float3(4.0, top, z0 + 1.0);
            float3 nrm; int axis = 0;
            float t = ttBox(o, d, bmin, bmax, nrm, axis);
            if (t < hit.t) {
                float3 p = o + d * t - bmin;
                int2 tx = clamp(int2(floor(p.xy)), int2(0), int2(7));
                if (ttToastMask(tx.x, tx.y)) {
                    hit.t = t; hit.n = nrm; hit.part = 3; hit.face = ttFace(axis, nrm);
                    hit.q = p.xy; hit.lim = int2(7);
                }
            }
        }
        if (hit.t > 1e8) return false;
        // Mostly chrome; now and then a coloured enamel one.
        float3 enamel = float3(0.0);
        float e = fract(h.z * 13.7);
        if (e < 0.25)      enamel = float3(0.62, 0.86, 0.74);
        else if (e < 0.5)  enamel = float3(0.78, 0.16, 0.13);
        else if (e < 0.75) enamel = float3(0.94, 0.86, 0.66);
        else               enamel = float3(0.42, 0.62, 0.88);
        var = float4(h.z, ttLin(enamel));
        if (hit.part == 3) var = float4(0.0, 0.2, 0.0, 0.0);   // fresh toast, unbuttered
    }
    float tW = hit.t / TT_TEX;
    float3 nW = hit.n.x * fl.F + hit.n.y * fl.U + hit.n.z * fl.S;
    float cosi = max(abs(dot(nW, rdW)), 0.3);
    float wf = tW * pxA * TT_TEX / cosi;
    uint salt = fl.salt ^ uint(h.w * 65535.0);
    float4 alb = ttFiltered(hit.part, hit.face, hit.q, wf, var, salt, hit.lim);
    // Far off, settle to the face's average rather than let texels shimmer.
    float4 mean = ttTexel(hit.part, hit.face, hit.lim / 2, var, salt);
    alb = mix(alb, mean, smoothstep(1.2, 3.0, wf) * 0.6);
    s.t = tW;
    s.n = nW;
    s.alb = float4(ttLin(alb.rgb), alb.w);
    s.part = hit.part;
    s.refl = (hit.part == 0) ? (var.x < 0.7 ? 1.0 : 0.3) : (hit.part == 2 ? 0.15 : 0.0);
    return true;
}

// Walk the flock lattice. Returns the nearest flyer within tMax.
static bool ttFlockTrace(float3 ro, float3 rd, float tMax, TtFlock fl, float pxA,
                         thread TtSurf& s) {
    float3 o = float3(dot(ro, fl.F), dot(ro, fl.U), dot(ro, fl.S));
    float3 d = float3(dot(rd, fl.F), dot(rd, fl.U), dot(rd, fl.S));
    if (d.z <= 1e-4) return false;
    // Clip to the slab the flock lives in.
    float tA = max((TT_NEAR_S - 1.6 - o.z) / d.z, 0.0);
    float tB = min((TT_FAR_S + 1.6 - o.z) / d.z, tMax);
    // And to the stream's band on the up axis.
    float bLo = fl.uMid - TT_BEAM - 2.0 * TT_CELL.y, bHi = fl.uMid + TT_BEAM + 2.0 * TT_CELL.y;
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
        if (ttCell(c, oq, d, fl, pxA, rd, s)) return s.t < tMax;
        if (tNext.x < tNext.y && tNext.x < tNext.z) { tCur = tNext.x; tNext.x += tDelta.x; c.x += stepI.x; }
        else if (tNext.y < tNext.z)                  { tCur = tNext.y; tNext.y += tDelta.y; c.y += stepI.y; }
        else                                         { tCur = tNext.z; tNext.z += tDelta.z; c.z += stepI.z; }
    }
    return false;
}

// ---------------------------------------------------------------------------
// The cloud deck: one layer of block clouds on a 2D grid, drifting.

static inline bool ttCloudAt(int2 c, float cover, uint salt) {
    float2 p = float2(c) + float2(float(salt & 1023u), float((salt >> 10) & 1023u));
    float n = valueNoise(p * 0.21) * 0.68 + valueNoise(p * 0.57 + 17.0) * 0.32;
    return n > mix(0.86, 0.30, cover);
}

// Returns t of the deck hit (or 1e9), with its world normal.
static float ttClouds(float3 ro, float3 rd, float wind, int windCells, float cover, uint salt,
                      thread float3& n, thread float& tExit) {
    tExit = 1e9;
    if (rd.y >= -1e-4 || cover <= 0.0) return 1e9;
    float t0 = (TT_CLOUD_TOP - ro.y) / rd.y;
    float t1 = (TT_CLOUD_BOT - ro.y) / rd.y;
    tExit = t1;
    if (t0 > TT_CLOUD_FAR) return 1e9;
    float2 o = ro.xz + float2(wind, 0.0);
    float2 d = rd.xz;
    d += float2(d.x == 0.0 ? 1e-6 : 0.0, d.y == 0.0 ? 1e-6 : 0.0);
    float2 p = (o + d * t0) / TT_CLOUD_CELL;
    float2 cf = floor(p);
    int2 c = int2(cf) + int2(windCells, 0);
    if (ttCloudAt(c, cover, salt)) { n = float3(0.0, 1.0, 0.0); return t0; }
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
        if (ttCloudAt(c, cover, salt)) { n = nn; return t; }
    }
    return 1e9;
}

// ---------------------------------------------------------------------------

static float3 ttScene(float3 ro, float3 rd, float pxA, TtSky sky, TtFlock fl,
                      float wind, int windCells, float cover, float3 cloudCol) {
    float3 cn; float tExit;
    float tc = ttClouds(ro, rd, wind, windCells, cover, fl.salt, cn, tExit);

    // What lies beyond everything: sky above, the dark land below the deck.
    float3 back;
    if (rd.y >= 0.0) back = ttSky(rd, sky, pxA);
    else {
        float3 haze = ttSkyBase(float3(rd.x, -rd.y * 0.3, rd.z), sky) * 0.55;
        float tg = (TT_GROUND - ro.y) / rd.y;
        float2 g = (ro.xz + rd.xz * tg) / 2.0;
        int2 gc = int2(floor(g));
        float3 land = float3(0.004, 0.006, 0.012);
        float lh = ttHashTx(gc, fl.salt ^ 0xbeefu);
        float town = valueNoise(float2(gc) * 0.07 + 3.0);
        float2 gf = fract(g) - 0.5;
        if (lh < 0.012 * smoothstep(0.6, 0.85, town) && max(abs(gf.x), abs(gf.y)) < 0.14)
            land += float3(1.0, 0.55, 0.2) * (0.3 + lh * 15.0) * (0.75 + 0.25 * sin(sky.T * 0.7 + lh * 900.0));
        back = mix(land, haze, smoothstep(30.0, 260.0, tg) * 0.85 + 0.15);
    }

    float3 col = back;
    float3 fogDir = float3(rd.x, max(rd.y, 0.0), rd.z);
    if (tc < 1e8) {
        float3 amb = mix(sky.hor, sky.zen, 0.4) * 1.6;
        float face = cn.y > 0.5 ? 1.0 : (abs(cn.x) > 0.5 ? 0.62 : 0.78);
        float dif = max(dot(cn, sky.L), 0.0);
        float3 cc = cloudCol * face * (amb * 0.7 + sky.moon * (0.10 + 0.22 * dif));
        // Sides darken towards their undersides; tops take a sheen of moon.
        float y = ro.y + rd.y * tc;
        if (cn.y < 0.5) cc *= mix(0.55, 1.0, saturate((y - TT_CLOUD_BOT) / (TT_CLOUD_TOP - TT_CLOUD_BOT)));
        else cc += cloudCol * sky.moon * 0.35 * pow(saturate(dot(reflect(rd, cn), sky.L)), 6.0);
        cc = mix(cc, ttSkyBase(fogDir, sky), smoothstep(25.0, TT_CLOUD_FAR, tc));
        col = mix(back, cc, 0.7);
    }

    TtSurf s;
    float tMax = min(tc, TT_FAR);
    if (ttFlockTrace(ro, rd, tMax, fl, pxA, s)) {
        float3 n = s.n;
        float dif = max(dot(n, sky.L), 0.0);
        // Block-world light: a fixed brightness per face direction (tops
        // brightest, undersides darkest), tinted by the night, plus the moon.
        float face = 0.62 + 0.38 * n.y * (n.y > 0.0 ? 1.0 : 0.55) + 0.1 * abs(n.x);
        float3 night = mix(sky.moon * 0.55, sky.hor * 1.6 + sky.zen * 3.0 + sky.moon * 0.12, 0.45);
        float3 env = ttSkyBase(reflect(rd, n), sky);
        // Soft-clipped, so a daylight sky lights them without blowing out.
        night = night / (1.0 + night);
        env = env / (1.0 + env);
        float3 lit = s.alb.rgb * (night * face * 1.3 + sky.moon * dif * 0.5 + s.refl * env * 1.5);
        if (s.part == 2) lit *= 1.35;                               // feathers catch the moon
        lit += float3(1.0, 0.32, 0.06) * s.alb.w * 0.55;            // the elements
        float fog = smoothstep(TT_FAR * 0.35, TT_FAR, s.t);
        col = mix(lit, ttSkyBase(fogDir, sky), fog);
    }
    return col;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float minRes = min(u.resolution.x, u.resolution.y);
    float T = u.time + u.seed * 400.0;
    uint salt = uint(u.seed * 16777216.0) * 2654435761u + 12345u;

    // Camera: level above the deck, looking a little down, swaying gently.
    float sway = 0.06 * sin(T * 0.021) + 0.02 * sin(T * 0.047 + 1.0);
    float3 ro = float3(0.0, 0.25 * sin(T * 0.033), 0.0);
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 fwd = normalize(float3(sin(sway), -0.2, cos(sway)));
    float3 right = normalize(cross(upHint, fwd));
    float lens = lerpLook(u.yaw, u.pitch, u.magnify, upHint, right, fwd);
    float3 up = cross(fwd, right);
    float pxA = 2.0 / (minRes * TT_FOCAL * lens);

    TtSky sky;
    sky.zen = ttLin(u.colorZenith.rgb);
    sky.hor = ttLin(u.colorHorizon.rgb);
    sky.moon = ttLin(u.colorMoon.rgb);
    float mAz = -0.40 + 0.12 * (fract(u.seed * 7.31) - 0.5);
    sky.L = normalize(float3(sin(mAz), 0.33, cos(mAz)));
    sky.cf = normalize(float3(0.0, -0.2, 1.0));
    sky.cr = normalize(cross(upHint, sky.cf));
    sky.cu = cross(sky.cf, sky.cr);
    sky.mc = float2(dot(sky.L, sky.cr), dot(sky.L, sky.cu)) / dot(sky.L, sky.cf);
    sky.stars = u.stars;
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
    fl.flapT = u.time * u.flap + u.seed * 50.0;
    fl.density = u.density * 0.9;
    fl.uMid = dot(float3(0.0, -2.6, 8.0), fl.U);
    fl.toast = u.toast;
    fl.salt = salt;

    // The deck drifts the way the flock flies, slower; whole cells are kept
    // as an integer so the pattern never loses precision or wraps.
    float drift = -(T * 0.35) / TT_CLOUD_CELL;
    float driftCells = floor(drift);
    float wind = (drift - driftCells) * TT_CLOUD_CELL;
    int windCells = int(driftCells);
    float3 cloudCol = ttLin(u.colorCloud.rgb);

    const float2 offs[2] = { float2(0.25, 0.25), float2(-0.25, -0.25) };
    float3 col = float3(0.0);
    for (int i = 0; i < TT_SAMPLES; ++i) {
        float4 p = pos;
        p.xy += offs[i];
        float2 uv = lerpUV(p, u.resolution);
        float3 rd = normalize(uv.x * right + uv.y * up + lens * TT_FOCAL * fwd);
        col += ttScene(ro, rd, pxA, sky, fl, wind, windCells, u.clouds, cloudCol);
    }
    col /= float(TT_SAMPLES);
    col = col / (1.0 + col * 0.25);
    col = sqrt(max(col, 0.0));
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
