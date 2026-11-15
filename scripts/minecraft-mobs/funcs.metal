
// ---- poses, skins, hits

struct MCMOB_Pose {
    float walk;    // walk-cycle position, the game's walkAnimation.position: legs swing as cos(walk * 0.6662)
    float speed;   // stride, 0 standing .. 1 full walk
    float yaw;     // head turn in radians, + toward the mob's left (counter-clockwise from above)
    float pitch;   // head pitch in radians, + looks down
    float graze;   // 0..1 head lowered to eat (pig, cow, sheep, chicken, horse, wolf, fox, cat)
    float flap;    // wings, -1..1; animate it yourself, e.g. sin(time * 12)
    float wag;     // tail, -1..1
};

struct MCMOB_Skin {
    int base;      // the mob's skin: an MCS_* layer (MCM_* for the iron golem)
    int over1;     // overlay drawn on the same boxes, or -1: villager biome type, sheep undercoat, enderman eyes
    int over2;     // villager profession, or -1
    int over3;     // villager profession level badge, or -1
    int fur;       // second model laid over the first (sheep wool), or -1
    float3 tint;   // multiplies over1 and fur: the sheep's dye colour; 1 otherwise
    int flags;     // MCMOB_HAT_FULL, MCMOB_GLOW1
};
constant int MCMOB_HAT_FULL = 1;   // over2 brings a full hat: over1 is not drawn on the head
constant int MCMOB_GLOW1    = 2;   // over1 is emissive (enderman eyes): returned in mcMobColor's .a

struct MCMOB_Hit {
    float  t;       // ray distance, in the caller's units; INFINITY when nothing was hit
    float3 n;       // face normal in mob space (y up, mob facing +z); rotate it back yourself
    float2 px;      // skin pixel to sample (0,0 = top-left of the PNG)
    int    flags;   // the cube's flags: 128 = on the fur model, 256 = on the head
};

static inline MCMOB_Pose mcMobStill() {
    MCMOB_Pose p; p.walk = 0.0; p.speed = 0.0; p.yaw = 0.0; p.pitch = 0.0;
    p.graze = 0.0; p.flap = 0.0; p.wag = 0.0;
    return p;
}
static inline MCMOB_Skin mcMobSkin(int base) {
    MCMOB_Skin s; s.base = base; s.over1 = -1; s.over2 = -1; s.over3 = -1; s.fur = -1;
    s.tint = float3(1.0); s.flags = 0;
    return s;
}
// A villager: base MCS_VILLAGER (or _BABY), biome MCS_VILLAGER_TYPE_* (or
// MCS_VILLAGER_BABY_*), profession MCS_VILLAGER_PROFESSION_* and level
// MCS_VILLAGER_PROFESSION_LEVEL_*, -1 for none. The professions whose
// .mcmeta says hat "full" (farmer, fisherman, fletcher, librarian, shepherd,
// butcher) hide the biome layer's head, as the game does.
static inline MCMOB_Skin mcMobVillagerSkin(int base, int biome, int profession, int level) {
    MCMOB_Skin s = mcMobSkin(base);
    s.over1 = biome; s.over2 = profession; s.over3 = level;
    if (profession == MCS_VILLAGER_PROFESSION_FARMER || profession == MCS_VILLAGER_PROFESSION_FISHERMAN ||
        profession == MCS_VILLAGER_PROFESSION_FLETCHER || profession == MCS_VILLAGER_PROFESSION_LIBRARIAN ||
        profession == MCS_VILLAGER_PROFESSION_SHEPHERD || profession == MCS_VILLAGER_PROFESSION_BUTCHER)
        s.flags |= MCMOB_HAT_FULL;
    return s;
}
// A sheep with its wool, `dye` the wool colour (white is float3(1)). Pass
// woolly = false for a shorn one.
static inline MCMOB_Skin mcMobSheepSkin(bool baby, bool woolly, float3 dye) {
    MCMOB_Skin s = mcMobSkin(baby ? MCS_SHEEP_BABY : MCS_SHEEP);
    if (woolly) {
        s.fur = baby ? MCS_SHEEP_WOOL_BABY : MCS_SHEEP_WOOL;
        if (!baby) s.over1 = MCS_SHEEP_WOOL_UNDERCOAT;
        s.tint = dye;
    }
    return s;
}
static inline MCMOB_Skin mcMobEndermanSkin() {
    MCMOB_Skin s = mcMobSkin(MCS_ENDERMAN); s.over1 = MCS_ENDERMAN_EYES; s.flags = MCMOB_GLOW1;
    return s;
}

// ---- placing a mob

// World ray -> mob space for a mob whose feet are at `at`, facing `heading`
// radians: 0 faces +z, pi/2 faces +x. The world must be y up, in blocks.
static inline void mcMobRay(float3 ro, float3 rd, float3 at, float heading, thread float3& lro, thread float3& lrd) {
    float c = cos(heading), s = sin(heading);
    float3 p = ro - at;
    lro = float3(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
    lrd = float3(c * rd.x - s * rd.z, rd.y, s * rd.x + c * rd.z);
}
// A mob-space normal (MCMOB_Hit.n) back to the world, for mcFaceShade and lighting.
static inline float3 mcMobNormal(float3 n, float heading) {
    float c = cos(heading), s = sin(heading);
    return float3(c * n.x + s * n.z, n.y, -s * n.x + c * n.z);
}

// ---- bounds

// Ray against a type's bounding box (mob space: blocks, feet on y = 0, facing +z).
// Returns (enter, exit); a miss has enter > exit. Cheap: call it first.
static inline float2 mcMobBounds(int type, float3 ro, float3 rd) {
    float3 inv = 1.0 / select(rd, float3(1e-9), abs(rd) < 1e-9);
    float3 a = (MCMOB_AABB[type * 2].xyz - ro) * inv, b = (MCMOB_AABB[type * 2 + 1].xyz - ro) * inv;
    float3 lo = min(a, b), hi = max(a, b);
    return float2(max(max(lo.x, lo.y), max(lo.z, 0.0)), min(min(hi.x, hi.y), hi.z));
}

// ---- tracing

static inline float2 mcMobFacePx(int cube, int face, float3 f) {
    half4 m = MCMOB_UV[cube * 6 + face];
    int axis = face >> 1;
    float2 ab = axis == 0 ? f.zy : (axis == 1 ? f.xz : f.xy);
    return float2(m.xy) + float2(m.zw) * ab;
}

static inline float mcMobAlpha(MCMOB_Skin s, int cflags, float2 px, bool big,
                               texture2d_array<float> skins, texture2d_array<float> maps) {
    uint2 q = uint2(clamp(px, 0.0, big ? 127.0 : 63.0));
    if (big) return maps.read(q, uint(s.base)).a;
    if ((cflags & 128) != 0) return s.fur >= 0 ? skins.read(q, uint(s.fur)).a : 0.0;
    float a = skins.read(q, uint(s.base)).a;
    if (s.over1 >= 0 && !((s.flags & MCMOB_HAT_FULL) != 0 && (cflags & 256) != 0)) a = max(a, skins.read(q, uint(s.over1)).a);
    if (s.over2 >= 0) a = max(a, skins.read(q, uint(s.over2)).a);
    if (s.over3 >= 0) a = max(a, skins.read(q, uint(s.over3)).a);
    return a;
}

// The nearest textured face of mob `type` in `pose` along a ray in mob space
// (blocks, feet on y = 0, facing +z), closer than tMax. Cut-out texels (hat
// brims, wings, the sheep's shorn skin under its wool) are tested against the
// skin layers in `skin`, and the back of a box shows through them as it does
// in the game.
static inline MCMOB_Hit mcMobTrace(int type, MCMOB_Pose pose, MCMOB_Skin skin, float3 ro, float3 rd, float tMax,
                                  texture2d_array<float> skins, texture2d_array<float> maps) {
    MCMOB_Hit h; h.t = INFINITY; h.n = float3(0.0, 1.0, 0.0); h.px = float2(0.0); h.flags = 0;
    // mob space -> model space: pixels, y down, facing -z; t is unchanged
    float3 om = float3(16.0 * ro.x, 24.0 - 16.0 * ro.y, -16.0 * ro.z);
    float3 dm = float3(16.0 * rd.x, -16.0 * rd.y, -16.0 * rd.z);
    int4 ty = MCMOB_TYPE[type];
    bool big = ty.z != 0;
    float best = tMax;
    float c0 = cos(pose.walk * 0.6662) * pose.speed;
    // the face that wins, kept until the end
    int hitCube = -1, hitFace = 0; float3 hitF = float3(0.0), hitN = float3(0.0);
    for (int b = ty.x; b < ty.x + ty.y; b++) {
        int k = b * 10;
        float4 q0 = MCMOB_BONE[k], q1 = MCMOB_BONE[k + 1], q2 = MCMOB_BONE[k + 2];
        float3 o1 = float3(dot(q0.xyz, om) + q0.w, dot(q1.xyz, om) + q1.w, dot(q2.xyz, om) + q2.w);
        float3 d1 = float3(dot(q0.xyz, dm), dot(q1.xyz, dm), dot(q2.xyz, dm));
        // skip a part whose bounding sphere the ray misses or meets beyond the best hit:
        // it bounds every turn of the part, so no sin/cos is spent on it
        float4 sph = MCMOB_BONE[k + 9];
        float3 oc = o1 - sph.xyz;
        float sa = dot(d1, d1), sb = dot(oc, d1), sc = dot(oc, oc) - sph.w * sph.w;
        float disc = sb * sb - sa * sc;
        if (disc < 0.0) continue;
        float sq = sqrt(disc);
        if ((-sb - sq) > best * sa || (-sb + sq) < 0.0) continue;
        float4 p0 = MCMOB_BONE[k + 3], p1 = MCMOB_BONE[k + 4], p2 = MCMOB_BONE[k + 5];
        float4 rest = MCMOB_BONE[k + 6], an = MCMOB_BONE[k + 7], fl = MCMOB_BONE[k + 8];
        float3 e = rest.xyz + float3(an.x * c0, 0.0, 0.0) + fl.xyz * pose.flap + float3(0.0, an.z * pose.wag, 0.0);
        if (an.y >= 0.0) e += float3(pose.pitch + an.y * pose.graze, -pose.yaw, 0.0);
        float3 s = sin(e), c = cos(e);
        // R = Rz Ry Rx, as the game composes a part's rotation
        float3x3 Rx = float3x3(float3(1, 0, 0), float3(0, c.x, s.x), float3(0, -s.x, c.x));
        float3x3 Ry = float3x3(float3(c.y, 0, -s.y), float3(0, 1, 0), float3(s.y, 0, c.y));
        float3x3 Rz = float3x3(float3(c.z, s.z, 0), float3(-s.z, c.z, 0), float3(0, 0, 1));
        float3x3 Rm = Rz * Ry * Rx;
        float3x3 Rt = transpose(Rm);
        o1 = Rt * o1; d1 = Rt * d1;
        float3 o = float3(dot(p0.xyz, o1) + p0.w, dot(p1.xyz, o1) + p1.w, dot(p2.xyz, o1) + p2.w);
        float3 d = float3(dot(p0.xyz, d1), dot(p1.xyz, d1), dot(p2.xyz, d1));
        float3 inv = 1.0 / select(d, float3(1e-9), abs(d) < 1e-9);
        int cs = int(rest.w), ce = cs + int(an.w);
        for (int ci = cs; ci < ce; ci++) {
            float4 lo = MCMOB_BOX[ci * 2], hi = MCMOB_BOX[ci * 2 + 1];
            float3 ta = (lo.xyz - o) * inv, tb = (hi.xyz - o) * inv;
            float3 tn3 = min(ta, tb), tf3 = max(ta, tb);
            float tn = max(max(tn3.x, tn3.y), tn3.z), tf = min(min(tf3.x, tf3.y), tf3.z);
            if (tn > tf || tf <= 0.0 || tn >= best || tn <= 0.0) continue;
            int flags = int(lo.w);
            if ((flags & 128) != 0 && skin.fur < 0) continue;
            float3 ext = max(hi.xyz - lo.xyz, float3(1e-6));
            // entry face, then (no culling, as the game draws mobs) the back face through a clear texel
            int ax = tn3.x >= tn3.y && tn3.x >= tn3.z ? 0 : (tn3.y >= tn3.z ? 1 : 2);
            float dax = ax == 0 ? d.x : (ax == 1 ? d.y : d.z);
            int face = ax * 2 + (dax < 0.0 ? 1 : 0);
            float t = tn;
            float3 f = saturate((o + d * t - lo.xyz) / ext);
            bool ok = (flags & (1 << face)) != 0;
            if (ok && (flags & 64) != 0) ok = mcMobAlpha(skin, flags, mcMobFacePx(ci, face, f), big, skins, maps) > 0.5;
            if (!ok) {
                if (tf >= best) continue;
                ax = tf3.x <= tf3.y && tf3.x <= tf3.z ? 0 : (tf3.y <= tf3.z ? 1 : 2);
                dax = ax == 0 ? d.x : (ax == 1 ? d.y : d.z);
                face = ax * 2 + (dax > 0.0 ? 1 : 0);
                t = tf;
                f = saturate((o + d * t - lo.xyz) / ext);
                ok = (flags & (1 << face)) != 0;
                if (ok && (flags & 64) != 0) ok = mcMobAlpha(skin, flags, mcMobFacePx(ci, face, f), big, skins, maps) > 0.5;
                if (!ok) continue;
            }
            best = t; hitCube = ci; hitFace = face; hitF = f;
            float sg = (face & 1) != 0 ? 1.0 : -1.0;
            int fa = face >> 1;
            float3 nb = float3(fa == 0 ? sg : 0.0, fa == 1 ? sg : 0.0, fa == 2 ? sg : 0.0);
            // back to model space: (Q^-1)^T R (P^-1)^T n
            float3 n1 = Rm * (p0.xyz * nb.x + p1.xyz * nb.y + p2.xyz * nb.z);
            hitN = q0.xyz * n1.x + q1.xyz * n1.y + q2.xyz * n1.z;
        }
    }
    if (hitCube >= 0) {
        h.t = best;
        h.n = normalize(float3(hitN.x, -hitN.y, -hitN.z));
        h.px = mcMobFacePx(hitCube, hitFace, hitF);
        h.flags = int(MCMOB_BOX[hitCube * 2].w);
    }
    return h;
}

// The unlit colour at a hit: the skin with its overlays composited as the
// game layers them. `w` is the width of one screen pixel in skin pixels at
// the hit (footprint in blocks * 16). .a is the emissive weight (enderman
// eyes); add rgb * a unlit, or ignore it.
static inline float4 mcMobColor(int type, MCMOB_Hit h, MCMOB_Skin s, float w,
                                texture2d_array<float> skins, texture2d_array<float> maps) {
    if (MCMOB_TYPE[type].z != 0) return float4(mcMap(maps, s.base, h.px, w).rgb, 0.0);
    if ((h.flags & 128) != 0) return float4(mcSkin(skins, s.fur, h.px, w).rgb * s.tint, 0.0);
    float4 c = mcSkin(skins, s.base, h.px, w);
    float3 rgb = c.rgb * c.a;
    float glow = 0.0;
    if (s.over1 >= 0 && !((s.flags & MCMOB_HAT_FULL) != 0 && (h.flags & 256) != 0)) {
        float4 o = mcSkin(skins, s.over1, h.px, w);
        if ((s.flags & MCMOB_GLOW1) != 0) glow = o.a;
        rgb = mix(rgb, o.rgb * s.tint, o.a);
    }
    if (s.over2 >= 0) { float4 o = mcSkin(skins, s.over2, h.px, w); rgb = mix(rgb, o.rgb, o.a); }
    if (s.over3 >= 0) { float4 o = mcSkin(skins, s.over3, h.px, w); rgb = mix(rgb, o.rgb, o.a); }
    return float4(rgb, glow);
}
