// Lantern Hill — villagers walking home at night up a lantern-lit spiral hill.
// Original work for Lerping@Home, drawn with the game's own block textures and
// the game's own mobs on their own models (lerp-requires: minecraft mobs; see
// PORTING.md).
//
// lerp-category: Living Worlds
// lerp-requires: minecraft mobs
//
// Villagers step one by one out of a nether portal at the foot of a terraced
// grass hill and climb the dirt-path ledge that winds three times round it,
// past lanterns on oak fence posts, to the giant mushroom on the summit, where
// they walk in at an open oak door watched by an iron golem. Some have a baby
// villager or a village cat at their heels, now and then a wandering trader
// walks with them, and every villager wears its own profession's clothes in
// the seed's biome. The queue moves like a crowd: slow stop-and-go waves run
// back down the line, so those near the top stand while those further back are
// still walking.
//
// Everything is a function of the clock. A walker's place on the path is its
// slot in the queue plus the wave at its own phase; its height comes from the
// ledge under it, with a hop at each step up; its legs swing with distance
// walked, so they stop when it does. Light is the game's lightmap: fixed
// shading per face, a little darkening in corners, the moon's sky light, and
// block light falling a level a block from each lantern, the shroomlights
// under the giant cap and the portal.
//
// Still not the game's own: the hill's shape and spiral ledge, and the giant
// mushroom's stepped 11-wide cap on a 3x3 stem (a player's build, not a
// generated huge mushroom); the single-file march (no villager AI queues);
// the stars (the game's are tilted squares on a sphere); light that falls
// smoothly by distance rather than a whole level per block; the portal as one
// translucent plane without its particles; the door's and fence post's
// models built here from the kit's pieces; and no mob shadows.
//
// lerp-param: speed    float 0.2 2   = 1   "Walk speed"
// lerp-param: crowd    float 0.4 1.6 = 1   "Crowd"
// lerp-param: light    float 0.3 2   = 1   "Brightness"
// lerp-param: soul     bool          = false "Soul lanterns"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -25 35   = 0 "Tilt"
// lerp-param: magnify  float -1 0.9   = 0 "Zoom"
//
// lerp-react: light <- clock.twilight 0.9..1.25 smooth=10
//
// lerp-preset: "Lantern Hill" crowd=1
// lerp-preset: "Soul Lanterns" soul=true, crowd=1.4
// lerp-preset: Stragglers crowd=0.5, speed=0.7

// --- The hill, in blocks. The ledge is an Archimedean spiral: radius
// R0 - PITCH * φ/2π, climbing CLIMB blocks a turn, for three turns.
constant float LH_R0     = 21.0;
constant float LH_PITCH  = 4.6;
constant float LH_CLIMB  = 4.0;
constant float LH_HW     = 1.3;          // half width of the ledge
constant float LH_TOP    = 12.0;         // summit = CLIMB * 3
constant float LH_PHEND  = 18.849556;    // three turns
constant float LH_REND   = 7.2;          // R0 - 3 * PITCH
constant float LH_K      = 0.36605637;   // PITCH / 4π
constant float LH_SSP    = 265.7787;     // arc length of the spiral
constant float LH_BOX    = 27.0;         // the hill fits in |x|, |z| < BOX
constant float LH_YMAX   = 14.2;         // the march's ceiling: summit + a villager (the cap is traced apart)
constant float LH_CAPY   = 18.0;         // underside of the giant mushroom's cap
constant int   LH_STEPS  = 120;
constant float LH_FOCAL  = 2.0;

// --- The way in and the way out. The path starts straight, along +z at
// x = R0, out of a nether portal standing across it (its plane at z = PZ,
// opening x 20..22, y 0..3), and ends along -x at z = -0.5 through the door in
// the giant mushroom's stem (stem x, z in -2..1; doorway x 0..1, z -1..0, two
// blocks tall; a hollow one block further in).
constant float LH_PZ     = -2.5;
constant float LH_SBORN  = -3.3;         // behind the portal: walkers start here
constant float LH_SGONE  = 273.58;       // a block inside the door: walkers end here

// --- Lamp posts: a lantern on an oak fence post every SP blocks of path,
// 1.2 blocks out from the middle of the ledge; two more on the summit.
constant float LH_SP     = 10.0;
constant float LH_LOFF   = 4.0;
constant float LH_NLAMP  = 25.0;         // last index: LOFF + 25 SP = 254 (LH_LAMP_CELL)
constant float LH_LOUT   = 1.2;

// --- The queue.
constant float LH_V   = 0.75;     // mean walking speed, blocks/s
constant float LH_A   = 0.7;      // stop-and-go depth (1 = full stops)
constant float LH_P   = 11.0;     // stop-and-go period, s
constant float LH_LAG = 0.35;     // wave phase per slot back down the line
constant float LH_DM  = 0.9191;   // V * A * P / 2π: how far the wave pushes a walker

// --- The iron golem at the door, facing down the path.
constant float3 LH_GOLEM   = float3(3.5, 12.0, 1.3);
constant float  LH_GOLEM_H = 1.5707963;

// ---------------------------------------------------------------------------

// atan2 to about 1e-5 rad, for less than the library's cost: the march asks
// for one at every column.
static inline float lhAtan2(float y, float x) {
    float ax = abs(x), ay = abs(y);
    float a = min(ax, ay) / max(max(ax, ay), 1e-9);
    float s = a * a;
    float r = ((-0.0464964749 * s + 0.15931422) * s - 0.327622764) * s * a + a;
    r = ay > ax ? 1.57079637 - r : r;
    r = x < 0.0 ? 3.14159274 - r : r;
    return y < 0.0 ? -r : r;
}

static inline float lhArcS(float ph) { return LH_R0 * ph - LH_K * ph * ph; }
static inline float lhArcPhi(float s) {
    return (LH_R0 - sqrt(max(LH_R0 * LH_R0 - 4.0 * LH_K * s, 0.0))) / (2.0 * LH_K);
}

// Lamp post k stands in the column holding the point LOUT out from the
// ledge's middle at s = LOFF + k SP, on the ledge's height there (lhCell's
// rule at that column's centre), with its lantern a block up. Worked out once
// from those formulas (none of the 26 points lies within 0.004 of a column's
// edge) and kept as a table: computing it in the march made every lane of a
// SIMD group wait on a square root and a sine whenever one lane neared a post.
constant int2 LH_LAMP_CELL[26] = {
    int2(21, 4), int2(16, 13), int2(8, 19), int2(-3, 20), int2(-12, 16), int2(-19, 8), int2(-20, -2),
    int2(-16, -12), int2(-8, -18), int2(3, -19), int2(12, -14), int2(17, -4), int2(15, 6), int2(8, 14),
    int2(-2, 16), int2(-12, 11), int2(-16, 1), int2(-13, -9), int2(-3, -15), int2(7, -12), int2(12, -3),
    int2(9, 7), int2(-1, 11), int2(-10, 6), int2(-10, -5), int2(0, -10) };
// The centre of each post's lantern block, where its light comes from.
constant float3 LH_LAMP_LIGHT[26] = {
    float3(21.5, 1.5, 4.5), float3(16.5, 1.5, 13.5), float3(8.5, 1.5, 19.5), float3(-2.5, 2.5, 20.5),
    float3(-11.5, 2.5, 16.5), float3(-18.5, 2.5, 8.5), float3(-19.5, 3.5, -1.5), float3(-15.5, 3.5, -11.5),
    float3(-7.5, 3.5, -17.5), float3(3.5, 4.5, -18.5), float3(12.5, 4.5, -13.5), float3(17.5, 4.5, -3.5),
    float3(15.5, 5.5, 6.5), float3(8.5, 5.5, 14.5), float3(-1.5, 6.5, 16.5), float3(-11.5, 6.5, 11.5),
    float3(-15.5, 6.5, 1.5), float3(-12.5, 7.5, -8.5), float3(-2.5, 7.5, -14.5), float3(7.5, 8.5, -11.5),
    float3(12.5, 8.5, -2.5), float3(9.5, 9.5, 7.5), float3(-0.5, 10.5, 11.5), float3(-9.5, 10.5, 6.5),
    float3(-9.5, 11.5, -4.5), float3(0.5, 12.5, -9.5) };
constant float3 LH_SUMMIT_LAMP0 = float3(2.5, 13.5, -1.5);
constant float3 LH_SUMMIT_LAMP1 = float3(6.5, 13.5, -1.5);

// One column of the hill: its top, and where it lies on the path (s), if it does.
struct LhCell {
    float h;
    float s;      // arc length along the path, or -1e9 off it
    int   kind;   // 0 grass, 1 path
    bool  lamp;   // a lamp post stands on it
};

// yLow: the lowest the ray is in this column. The ground's own height is
// worked out only when the ray is low enough to reach it (no column's top is
// more than 1.45 over the cone through the ledges at its centre; above that
// the march is here only for walkers, which stand on ledge columns), and lamp
// posts are looked for only when `lamps` and the ray is low enough for one.
static inline LhCell lhCell(int2 c, float yLow, bool lamps) {
    LhCell o;
    o.s = -1e9;
    o.kind = 0;
    o.lamp = false;
    float2 p = float2(c) + 0.5;
    float r = length(p);
    float phi = lhAtan2(p.y, p.x);
    phi += phi < 0.0 ? TWO_PI : 0.0;
    float a = (LH_R0 - r) / LH_PITCH - phi / TWO_PI;
    const float w = LH_HW / LH_PITCH;
    o.h = 0.0;
    if (yLow <= clamp(LH_CLIMB * (LH_R0 - r) / LH_PITCH + 1.45, 0.0, LH_TOP)) {
        float fa = floor(a);
        float ramp = smoothstep(w, 1.0 - w, a - fa);
        float h = LH_CLIMB * (phi / TWO_PI + fa + ramp);
        h += (hash21(p * 1.37 + 4.1) - 0.5) * 1.7 * sin(PI * ramp);   // rough banks, flat ledges
        o.h = floor(clamp(h, 0.0, LH_TOP));
    }
    float n = round(a);
    float phu = phi + TWO_PI * n;
    bool along = phu >= -0.2 && phu <= LH_PHEND;
    if (abs(a - n) <= w && along) {
        o.s = lhArcS(phu);
        o.kind = 1;
        o.h = max(floor(LH_CLIMB * phu / TWO_PI), 0.0);
    }
    // The summit path, on into the doorway.
    if (p.x > -1.0 && p.x < LH_REND + 1.4 && abs(p.y) < LH_HW) {
        o.s = LH_SSP + (LH_REND - p.x);
        o.kind = 1;
        o.h = LH_TOP;
    }
    if (lamps) {
        // Lamp post k stands in the column that holds the point 1.2 blocks out
        // from the ledge at s_k; that column becomes a ledge column.
        float d = (n - a) * LH_PITCH;
        if (d > 0.35 && d < 2.05 && along && yLow < max(floor(LH_CLIMB * phu / TWO_PI), 0.0) + 1.7) {
            float s = lhArcS(phu);
            float k = round((s - LH_LOFF) / LH_SP);
            if (k >= 0.0 && k <= LH_NLAMP && abs(s - LH_LOFF - k * LH_SP) < 1.6 && all(LH_LAMP_CELL[int(k)] == c)) {
                o.lamp = true;
                o.kind = 1;
                o.s = s;
                o.h = max(floor(LH_CLIMB * phu / TWO_PI), 0.0);
            }
        }
        if (c.y == -2 && (c.x == 2 || c.x == 6) && yLow < LH_TOP + 1.7) { o.lamp = true; o.h = LH_TOP; }
    }
    return o;
}

// ---------------------------------------------------------------------------
// Walkers. Slot j of the queue holds a grown villager (k = 0) and sometimes a
// baby villager or a cat (k = 1) just behind; a few slots are empty.

// The queue's clock: all the march and the traces need. What only shading
// needs (LhLook) is worked out after them, so that none of it is held in
// registers across the mob and lantern traces.
struct LhEnv {
    float tau, S0, D, time;
    int   biome;
};

struct LhLook {
    float3 zen, fog, grass, moonDir;
    float  lampLevel, light;
    int    capLayer, moonLayer;
};

struct LhWalker {
    float3 p;        // feet
    float2 f;        // facing, (x, z): heading atan2(f.x, f.y)
    float  s;        // arc length along the path
    float  id;
    float  walk, speed;
    int    type;
    bool   ok;
};

static inline LhWalker lhWalker(float j, int k, LhEnv E) {
    LhWalker w;
    w.ok = false;
    if (hash21(float2(j, 11.3)) < 0.12) return w;
    if (k == 1 && hash21(float2(j, 23.9)) > 0.36) return w;
    float o = hash21(float2(j, 3.7)) * 0.45;
    float wave = E.tau * (TWO_PI / LH_P) - j * LH_LAG;
    float s = LH_V * (E.tau - LH_A * LH_P / TWO_PI * sin(wave)) - (j + o) * E.D - float(k) * 0.95;
    if (s < LH_SBORN || s > LH_SGONE) return w;
    w.ok = true;
    w.s = s;
    w.id = hash21(float2(j, float(k) + 5.1));
    w.type = k == 0 ? MCMOB_VILLAGER : (hash21(float2(j, 41.3)) < 0.3 ? MCMOB_CAT : MCMOB_VILLAGER_BABY);
    // The game's walk animation: its phase runs 4 a block walked here a
    // little brisker, its stride follows the walker's speed.
    w.walk = s * 5.0 + w.id * 9.0;
    w.speed = 0.29 * (1.0 - LH_A * cos(wave));     // up to 0.49: a walk


    float2 f;
    if (s < 0.0) {
        w.p = float3(LH_R0, 0.0, s);       // out of the portal, onto the path
        f = float2(0.0, 1.0);
    } else if (s < LH_SSP) {
        float ph = lhArcPhi(s);
        float r = LH_R0 - LH_PITCH * ph / TWO_PI;
        float c = cos(ph), sn = sin(ph);
        const float dr = -LH_PITCH / TWO_PI;
        f = normalize(float2(dr * c - r * sn, dr * sn + r * c));
        float hc = LH_CLIMB * ph / TWO_PI;
        float base = floor(hc);
        // The next step up the ledge, and how far ahead of the feet it is:
        // a hop up onto it, as a mob jumps a full block.
        float d = lhArcS((base + 1.0) * TWO_PI / LH_CLIMB) - s;
        float rise = 1.0 - smoothstep(0.0, 0.5, d);
        float y = base + rise + 0.3 * sin(PI * rise);
        w.p = float3(r * c, y, r * sn);
    } else {
        w.p = float3(LH_REND - (s - LH_SSP), LH_TOP, -0.5 * saturate((s - LH_SSP) / 1.5));
        f = float2(0.0, 1.0);
    }
    w.f = normalize(mix(f, float2(-1.0, 0.0), smoothstep(LH_SSP - 1.2, LH_SSP + 0.4, s)));
    return w;
}

static inline MCMOB_Pose lhPose(LhWalker w, float time) {
    MCMOB_Pose p = mcMobStill();
    p.walk = w.walk;
    p.speed = w.speed;
    // Some look about as they go.
    p.yaw = fract(w.id * 13.0) < 0.5 ? 0.5 * sin(time * 0.31 + w.id * 37.0) : 0.0;
    p.wag = 0.25 * sin(time * 1.7 + w.id * 20.0);
    return p;
}

// What walks in slot (j, k): the seed's biome for every villager, a
// profession (or none, or a nitwit) and a level for each, a cat's coat.
// Biomes: 0 plains, 1 taiga, 2 snow, 3 savanna, 4 desert, 5 jungle, 6 swamp.
// (Chains of selects rather than arrays: an array indexed per pixel spills.)
static inline int lhBiomeType(int b) {
    return b == 0 ? MCS_VILLAGER_TYPE_PLAINS : b == 1 ? MCS_VILLAGER_TYPE_TAIGA : b == 2 ? MCS_VILLAGER_TYPE_SNOW
         : b == 3 ? MCS_VILLAGER_TYPE_SAVANNA : b == 4 ? MCS_VILLAGER_TYPE_DESERT : b == 5 ? MCS_VILLAGER_TYPE_JUNGLE
         : MCS_VILLAGER_TYPE_SWAMP;
}
static inline int lhBiomeBaby(int b) {
    return b == 0 ? MCS_VILLAGER_BABY_PLAINS : b == 1 ? MCS_VILLAGER_BABY_TAIGA : b == 2 ? MCS_VILLAGER_BABY_SNOW
         : b == 3 ? MCS_VILLAGER_BABY_SAVANNA : b == 4 ? MCS_VILLAGER_BABY_DESERT : b == 5 ? MCS_VILLAGER_BABY_JUNGLE
         : MCS_VILLAGER_BABY_SWAMP;
}
static inline int lhCat(int i) {
    return i == 0 ? MCS_CAT_TABBY : i == 1 ? MCS_CAT_BLACK : i == 2 ? MCS_CAT_RED : i == 3 ? MCS_CAT_SIAMESE
         : i == 4 ? MCS_CAT_BRITISH_SHORTHAIR : i == 5 ? MCS_CAT_CALICO : i == 6 ? MCS_CAT_PERSIAN
         : i == 7 ? MCS_CAT_RAGDOLL : i == 8 ? MCS_CAT_WHITE : i == 9 ? MCS_CAT_JELLIE : MCS_CAT_ALL_BLACK;
}
static inline int lhProfession(int i) {   // 0, 1: none
    return i == 2 ? MCS_VILLAGER_PROFESSION_NITWIT : i == 3 ? MCS_VILLAGER_PROFESSION_ARMORER
         : i == 4 ? MCS_VILLAGER_PROFESSION_BUTCHER : i == 5 ? MCS_VILLAGER_PROFESSION_CARTOGRAPHER
         : i == 6 ? MCS_VILLAGER_PROFESSION_CLERIC : i == 7 ? MCS_VILLAGER_PROFESSION_FARMER
         : i == 8 ? MCS_VILLAGER_PROFESSION_FISHERMAN : i == 9 ? MCS_VILLAGER_PROFESSION_FLETCHER
         : i == 10 ? MCS_VILLAGER_PROFESSION_LEATHERWORKER : i == 11 ? MCS_VILLAGER_PROFESSION_LIBRARIAN
         : i == 12 ? MCS_VILLAGER_PROFESSION_MASON : i == 13 ? MCS_VILLAGER_PROFESSION_SHEPHERD
         : i == 14 ? MCS_VILLAGER_PROFESSION_TOOLSMITH : i == 15 ? MCS_VILLAGER_PROFESSION_WEAPONSMITH : -1;
}
static inline int lhLevel(int i) {
    return i == 0 ? MCS_VILLAGER_PROFESSION_LEVEL_STONE : i == 1 ? MCS_VILLAGER_PROFESSION_LEVEL_IRON
         : i == 2 ? MCS_VILLAGER_PROFESSION_LEVEL_GOLD : i == 3 ? MCS_VILLAGER_PROFESSION_LEVEL_EMERALD
         : MCS_VILLAGER_PROFESSION_LEVEL_DIAMOND;
}
static inline MCMOB_Skin lhSkin(float j, int k, int type, int biome) {
    float h = hash21(float2(j, 31.7 + 7.0 * float(k)));
    if (type == MCMOB_CAT) return mcMobSkin(lhCat(int(h * 11.0)));
    if (type == MCMOB_VILLAGER_BABY) return mcMobVillagerSkin(MCS_VILLAGER_BABY, lhBiomeBaby(biome), -1, -1);
    if (h < 0.05) return mcMobSkin(MCS_WANDERING_TRADER);
    int pr = lhProfession(int(fract(h * 97.31) * 16.0));
    float lh = fract(h * 31.13);
    int lv = (pr < 0 || pr == MCS_VILLAGER_PROFESSION_NITWIT) ? -1 : lhLevel(int(lh * lh * 5.0));
    return mcMobVillagerSkin(MCS_VILLAGER, lhBiomeType(biome), pr, lv);
}

// Which slots can hold a walker within `m` of arc length sc.
static inline float2 lhSlots(float S0, float sc, float m, float D) {
    float wc = S0 - sc;
    return float2(ceil((wc - m - LH_DM - 0.45 * D - 0.95) / D), floor((wc + m + LH_DM) / D));
}

// Where a ray in mob space enters the box [lo, hi], or 1e9.
static inline float lhBoxIn(float3 ro, float3 rd, float3 lo, float3 hi) {
    float3 inv = 1.0 / select(rd, float3(1e-9), abs(rd) < 1e-9);
    float3 a = (lo - ro) * inv, b = (hi - ro) * inv;
    float3 n = min(a, b), f = max(a, b);
    float tn = max(max(n.x, n.y), max(n.z, 0.0)), tf = min(min(f.x, f.y), f.z);
    return tn < tf ? tn : 1e9;
}

// Bounds for the poses this look uses (head turned at most 0.5, stride at
// most 0.5, the golem standing), worked out from the kit's own bones and
// boxes, 0.02 added. The kit's mcMobBounds holds for every pose it allows, so
// it is wider: a villager's ±0.77, where its body here is ±0.47 and only the
// hat brim, a thin slab at 1.7, reaches ±0.64. Rays through that slack were
// most of the traces. KIT: mobs (a pose-limited mcMobBounds). The march still uses the kit's single box, which is
// cheaper to ask of every walker it passes; these sift what it gathered.
static inline float lhMobIn(int type, float3 ro, float3 rd) {
    if (type == MCMOB_VILLAGER)
        return min(lhBoxIn(ro, rd, float3(-0.49, -0.03, -0.38), float3(0.49, 2.05, 0.41)),
                   lhBoxIn(ro, rd, float3(-0.66, 1.68, -0.66), float3(0.66, 1.78, 0.66)));
    if (type == MCMOB_VILLAGER_BABY)
        return min(lhBoxIn(ro, rd, float3(-0.37, -0.03, -0.36), float3(0.37, 1.04, 0.36)),
                   lhBoxIn(ro, rd, float3(-0.59, 0.73, -0.56), float3(0.59, 0.83, 0.56)));
    if (type == MCMOB_CAT)
        return lhBoxIn(ro, rd, float3(-0.20, -0.06, -1.12), float3(0.20, 0.62, 0.69));
    return lhBoxIn(ro, rd, float3(-0.83, -0.02, -0.33), float3(0.83, 2.72, 0.66));   // the iron golem
}

// Walker w's mob space, and whether the ray meets its bounds before tLim.
static inline bool lhWalkerRay(float3 ro, float3 rd, LhWalker w, float tLim,
                               thread float3& lro, thread float3& lrd) {
    if (dot(w.p - ro, rd) - 1.6 > tLim) return false;
    // mcMobRay, with the heading's cosine and sine already in hand (f.y, f.x).
    float3 pp = ro - w.p;
    lro = float3(w.f.y * pp.x - w.f.x * pp.z, pp.y, w.f.x * pp.x + w.f.y * pp.z);
    lrd = float3(w.f.y * rd.x - w.f.x * rd.z, rd.y, w.f.x * rd.x + w.f.y * rd.z);
    float2 b = mcMobBounds(w.type, lro, lrd);
    return b.x < b.y && b.x < tLim;
}

static inline MCMOB_Pose lhGolemPose(float time) {
    MCMOB_Pose p = mcMobStill();
    p.yaw = 0.7 * sin(time * 0.23);
    p.pitch = 0.15;
    return p;
}

// A lantern on an oak fence post standing on the block whose top corner is
// org. KIT: models (mcFencePost; see KIT-REQUESTS)
static inline void lhLampPost(texture2d_array<float> T, int lanternLayer, float3 org, float3 ro, float3 rd,
                              float tMin, float pxA, thread McModelHit& best, thread bool& lantern) {
    McModelHit fh;
    fh.t = best.t;
    mcModelBoxElem(T, MC_OAK_PLANKS, (ro - org) * 16.0, rd, mcModelInv(rd), float3(6.0, 0.0, 6.0),
                   float3(10.0, 16.0, 10.0), float4(6.0, 0.0, 10.0, 16.0), float4(6.0, 6.0, 10.0, 10.0),
                   float4(6.0, 6.0, 10.0, 10.0), tMin, pxA, 1.0, fh);
    if (fh.t < best.t) { best = fh; lantern = false; }
    McModelHit lh;
    if (mcLantern(T, lanternLayer, org + float3(0.0, 1.0, 0.0), false, ro, rd, tMin, best.t, pxA, lh)) {
        best = lh;
        lantern = true;
    }
}

// ---------------------------------------------------------------------------
// The giant mushroom on the summit: a 3x3 stem of mushroom-stem blocks with a
// doorway and a hollow behind it, a stepped cap of mushroom blocks with a
// hanging rim, and shroomlights set in its underside round the stem.

static inline void lhBoxW(float3 ro, float3 rd, float3 inv, float3 lo, float3 hi, int id,
                          thread float& t, thread float3& n, thread int& part) {
    float3 t1 = (lo - ro) * inv, t2 = (hi - ro) * inv;
    float3 mn = min(t1, t2), mx = max(t1, t2);
    float tn = max(max(mn.x, mn.y), mn.z), tf = min(min(mx.x, mx.y), mx.z);
    if (tn > tf || tn <= 0.0 || tn >= t) return;
    t = tn;
    part = id;
    n = tn == mn.x ? float3(-sign(rd.x), 0.0, 0.0)
      : (tn == mn.y ? float3(0.0, -sign(rd.y), 0.0) : float3(0.0, 0.0, -sign(rd.z)));
}

static inline bool lhInBox(float3 ro, float3 inv, float3 lo, float3 hi) {
    float3 t1 = (lo - ro) * inv, t2 = (hi - ro) * inv;
    float3 mn = min(t1, t2), mx = max(t1, t2);
    float tn = max(max(mn.x, mn.y), mn.z), tf = min(min(mx.x, mx.y), mx.z);
    return tn <= tf && tf > 0.0;
}

static inline int lhShroom(float3 ro, float3 rd, float3 inv, thread float& t, thread float3& n) {
    int part = -1;
    const float C = LH_CAPY;
    if (!lhInBox(ro, inv, float3(-6.0, LH_TOP - 1.0, -6.0), float3(5.0, C + 3.0, 5.0))) return part;
    // Stem, round the doorway (x 0..1, z -1..0, y 12..14) and the hollow behind it.
    lhBoxW(ro, rd, inv, float3(-2.0, LH_TOP - 1.0, -2.0), float3(1.0, C, -1.0), 0, t, n, part);
    lhBoxW(ro, rd, inv, float3(-2.0, LH_TOP - 1.0,  0.0), float3(1.0, C,  1.0), 0, t, n, part);
    lhBoxW(ro, rd, inv, float3(-2.0, LH_TOP - 1.0, -1.0), float3(-1.0, C, 0.0), 0, t, n, part);
    lhBoxW(ro, rd, inv, float3(-1.0, LH_TOP + 2.0, -1.0), float3(1.0, C, 0.0), 0, t, n, part);
    // Cap.
    lhBoxW(ro, rd, inv, float3(-6.0, C, -6.0), float3(5.0, C + 1.0, 5.0), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-5.0, C + 1.0, -5.0), float3(4.0, C + 2.0, 4.0), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-3.0, C + 2.0, -3.0), float3(2.0, C + 3.0, 2.0), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-6.0, C - 1.0, 4.0), float3(5.0, C, 5.0), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-6.0, C - 1.0, -6.0), float3(5.0, C, -5.0), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(4.0, C - 1.0, -5.0), float3(5.0, C, 4.0), 1, t, n, part);
    lhBoxW(ro, rd, inv, float3(-6.0, C - 1.0, -5.0), float3(-5.0, C, 4.0), 1, t, n, part);
    return part;
}

// The open oak door, swung back against the doorway's +z side: 16 x 32 x 3 px.
// KIT: models (mcDoor; the 3 px edges here take the picture's first columns)
static inline bool lhDoor(texture2d_array<float> T, float3 ro, float3 rd, float3 inv, float pxA, float tMax,
                          thread float& t, thread float3& n, thread float3& alb) {
    const float3 lo = float3(0.0, LH_TOP, -0.1875), hi = float3(1.0, LH_TOP + 2.0, 0.0);
    float3 t1 = (lo - ro) * inv, t2 = (hi - ro) * inv;
    float3 mn = min(t1, t2), mx = max(t1, t2);
    float tn = max(max(mn.x, mn.y), mn.z), tf = min(min(mx.x, mx.y), mx.z);
    if (tn > tf || tn <= 0.0 || tn >= tMax) return false;
    float3 nn = tn == mn.x ? float3(-sign(rd.x), 0.0, 0.0)
              : (tn == mn.y ? float3(0.0, -sign(rd.y), 0.0) : float3(0.0, 0.0, -sign(rd.z)));
    float3 q = (ro + rd * tn - lo) * 16.0;     // pixels: x 0..16, y 0..32, z 0..3
    bool top = q.y >= 16.0;
    float v = top ? 32.0 - q.y : 16.0 - q.y;
    float2 px;
    if (abs(nn.z) > 0.5)      px = float2(nn.z > 0.0 ? q.x : 16.0 - q.x, v);
    else if (abs(nn.x) > 0.5) px = float2(q.z, v);
    else { px = float2(q.x, q.z); top = nn.y > 0.0; }
    float4 c = mcModelTexel(T, top ? MC_OAK_DOOR_TOP : MC_OAK_DOOR_BOTTOM, px, float4(0.0, 0.0, 16.0, 16.0),
                            tn * pxA);
    if (c.a < 0.5) return false;   // its windows
    t = tn;
    n = nn;
    alb = c.rgb;
    return true;
}

// The portal's obsidian frame (the bottom row is the ground's own top).
static inline bool lhPortalFrame(float3 ro, float3 rd, float3 inv, thread float& t, thread float3& n) {
    if (!lhInBox(ro, inv, float3(19.0, 0.0, -3.0), float3(23.0, 4.0, -2.0))) return false;
    int part = -1;
    lhBoxW(ro, rd, inv, float3(19.0, 0.0, -3.0), float3(20.0, 4.0, -2.0), 0, t, n, part);
    lhBoxW(ro, rd, inv, float3(22.0, 0.0, -3.0), float3(23.0, 4.0, -2.0), 0, t, n, part);
    lhBoxW(ro, rd, inv, float3(20.0, 3.0, -3.0), float3(22.0, 4.0, -2.0), 0, t, n, part);
    return part >= 0;
}

// ---------------------------------------------------------------------------
// Light, the game's way: the lightmap of the moon's sky light and the block
// light at P, which falls one level a block (Manhattan distance) from each
// lantern (15, a soul lantern 10), the shroomlights (15) and the portal (11).

static inline float lhManhattan(float3 d) { return abs(d.x) + abs(d.y) + abs(d.z); }

static inline float lhLampsAt(float3 P, float level) {
    float lv = 0.0;
    float r = length(P.xz);
    float phi = lhAtan2(P.z, P.x);
    phi += phi < 0.0 ? TWO_PI : 0.0;
    float a = (LH_R0 - r) / LH_PITCH - phi / TWO_PI;
    float fa = floor(a);
    for (int m = 0; m < 2; ++m) {
        float n = fa + float(m);
        float phu = phi + TWO_PI * n;
        if (phu < -0.4 || phu > LH_PHEND + 0.4) continue;
        float dr = abs((a - n) * LH_PITCH + LH_LOUT);
        float dy = abs(P.y - max(LH_CLIMB * phu / TWO_PI, 0.0) - 1.5);
        if (dr + dy > level + 1.5) continue;
        // The lamps either side along the path; the next ones out are a
        // whole spacing further and never the brightest.
        float kc = floor((lhArcS(phu) - LH_LOFF) / LH_SP);
        for (int q = 0; q <= 1; ++q) {
            float k = kc + float(q);
            if (k < 0.0 || k > LH_NLAMP) continue;
            lv = max(lv, level - lhManhattan(LH_LAMP_LIGHT[int(k)] - P));
        }
    }
    lv = max(lv, level - lhManhattan(LH_SUMMIT_LAMP0 - P));
    lv = max(lv, level - lhManhattan(LH_SUMMIT_LAMP1 - P));
    return lv;
}

constant float LH_SHROOM_IN = 3.5;   // shroomlights fill the cap's underside out to here

// P is the hit nudged half a block into the air in front of the face: the
// game lights a face by the block it faces.
static inline float3 lhLight(float3 P, LhLook E) {
    float lv = lhLampsAt(P, E.lampLevel);
    // Shroomlights under the cap (round its centre at x = z = -0.5): light
    // reaches the cap's top only round its edge.
    float3 c = P - float3(-0.5, 0.0, -0.5);
    float3 q = c - clamp(c, float3(-LH_SHROOM_IN + 0.5, LH_CAPY + 0.5, -LH_SHROOM_IN + 0.5),
                            float3(LH_SHROOM_IN - 0.5, LH_CAPY + 0.5, LH_SHROOM_IN - 0.5));
    float ds = lhManhattan(q);
    if (P.y > LH_CAPY) ds += 2.0 * max(6.0 - max(abs(c.x), abs(c.z)), 0.0);
    float3 qp = P - clamp(P, float3(20.5, 0.5, LH_PZ), float3(21.5, 2.5, LH_PZ));
    float blk = max(lv, max(15.0 - ds, 11.0 - lhManhattan(qp)));
    return mcLightmap(max(blk, 0.0), 15.0, 0.0, 0.0) * E.light;
}

// ---------------------------------------------------------------------------
// Surfaces. uv on a face, in blocks, with v running down the picture.

static inline float2 lhFaceUV(float3 P, float3 N) {
    if (abs(N.y) > 0.5) return P.xz;
    return float2(abs(N.x) > 0.5 ? P.z : P.x, -P.y);
}

static inline float3 lhTerrainTex(texture2d_array<float> T, float3 P, float3 N, int2 cell, LhCell ci, float fw,
                                  LhLook E) {
    float2 uv = lhFaceUV(P, N);
    bool top = N.y > 0.5;
    float depth = ci.h - P.y;     // below the column's top, for side faces
    // The portal frame's bottom row, flush with the ground.
    if (top && cell.y == -3 && cell.x >= 19 && cell.x <= 22 && ci.h == 0.0) return mcTile(T, MC_OBSIDIAN, uv, fw).rgb;
    if (ci.kind == 1 && distance(float2(cell) + 0.5, float2(LH_R0, -0.6)) >= 2.4) {
        if (top) return mcTile(T, MC_DIRT_PATH_TOP, uv, fw).rgb;
        if (depth < 1.0) return mcTile(T, MC_DIRT_PATH_SIDE, uv, fw).rgb;
    } else if (distance(float2(cell) + 0.5, float2(LH_R0, -0.6)) < 2.4) {
        // The patch of mycelium round the portal.
        if (top) return mcTile(T, MC_MYCELIUM_TOP, uv, fw).rgb;
        if (depth < 1.0) return mcTile(T, MC_MYCELIUM_SIDE, uv, fw).rgb;
    } else {
        if (top) return mcTile(T, MC_GRASS_BLOCK_TOP, uv, fw).rgb * E.grass;
        if (depth < 1.0) return mcGrassSide(T, uv, fw, E.grass);
    }
    // Dirt a few blocks down, then stone.
    float dd = 3.0 + floor(2.0 * hash21(floor(P.xz - N.xz * 0.5) + 3.0));
    return mcTile(T, depth < dd ? MC_DIRT : MC_STONE, uv, fw).rgb;
}

// Returns the colour; `lit` = 0 for surfaces that glow by their own light.
static inline float3 lhShroomTex(texture2d_array<float> T, float3 P, float3 N, int part, float fw,
                                 LhLook E, thread float& lit) {
    lit = 1.0;
    float2 uv = lhFaceUV(P, N);
    if (part == 0) return mcTile(T, MC_MUSHROOM_STEM, uv, fw).rgb;
    if (N.y < -0.5) {
        if (max(abs(P.x + 0.5), abs(P.z + 0.5)) < LH_SHROOM_IN && P.y > LH_CAPY - 0.1) {
            lit = 0.0;
            return mcTile(T, MC_SHROOMLIGHT, uv, fw).rgb;
        }
        return mcTile(T, MC_MUSHROOM_BLOCK_INSIDE, uv, fw).rgb;
    }
    return mcTile(T, E.capLayer, uv, fw).rgb;
}

// ---------------------------------------------------------------------------
// Sky: the game's night sky and fog colours, square stars, the moon's own
// picture (drawn on black, so added), and the flat cloud layer from clouds.png.

constant float LH_CLOUD_Y = 46.0;

static inline float3 lhSky(float3 ro, float3 rd, LhLook E, float time, float pxAngle,
                           texture2d_array<float> S, texture2d_array<float> M) {
    float y = rd.y;
    float3 col = mix(E.fog, E.zen, smoothstep(-0.02, 0.35, y));
    if (y > 0.03) {
        float2 q = rd.xz / (y + 0.3) * 90.0;
        float2 c = floor(q), f = q - c;
        float hs = hash21(c + 7.3);
        if (hs > 0.985) {
            float sz = 0.15 + 0.12 * fract(hs * 91.0);
            float cell = 90.0 * pxAngle / (y + 0.3);
            float2 e = abs(f - 0.5);
            float on = 1.0 - smoothstep(sz - cell * 0.5, sz + cell * 0.5, max(e.x, e.y));
            col += float3(0.75) * on * smoothstep(0.03, 0.2, y) * min(1.0, (2.0 * sz) / max(cell, 1e-4));
        }
    }
    float3 m = E.moonDir;
    float3 mu = normalize(cross(float3(0.0, 1.0, 0.0), m));
    float3 mv = cross(m, mu);
    float dm = dot(rd, m);
    if (dm > 0.0) {
        float2 pm = float2(dot(rd, mu), dot(rd, mv)) / dm;
        const float MS = 0.065;
        if (max(abs(pm.x), abs(pm.y)) < MS) {
            float2 px = (float2(pm.x, -pm.y) / MS * 0.5 + 0.5) * 32.0;
            col += mcSkin(S, E.moonLayer, px, pxAngle / (2.0 * MS) * 32.0).rgb;
        }
    }
    if (y > 0.0) {
        float t = (LH_CLOUD_Y - ro.y) / y;
        float2 cp = ro.xz + rd.xz * t + float2(time * 0.6, 0.0);
        float2 px = glmod2(cp / 12.0, 256.0);
        float4 cl = mcMap(M, MCM_ENVIRONMENT_CLOUDS, px, t * pxAngle / max(y, 0.05) / 12.0);
        float fade = exp(-t * 0.006);
        col = mix(col, E.fog * 2.4 + float3(0.02), cl.a * 0.8 * fade);
    }
    return col;
}

// ---------------------------------------------------------------------------

static inline LhLook lhLookFor(constant LerpUniforms& u, texture2d_array<float> M) {
    LhLook K;
    K.light = u.light;
    K.lampLevel = u.soul != 0 ? 10.0 : 15.0;
    // The seed's biome: its villagers' clothes and its grass colour.
    int b = min(int(fract(u.seed * 5.31 + 0.13) * 7.0), 6);
    float2 cl = b == 0 ? float2(0.8, 0.4) : b == 1 ? float2(0.25, 0.8) : b == 2 ? float2(0.0, 0.5)
              : b <= 4 ? float2(1.0, 0.0) : b == 5 ? float2(0.95, 0.9) : float2(0.8, 0.9);
    K.grass = mcGrassTint(M, cl.x, cl.y);
    // Midnight, as the game draws it.
    K.zen = mcSkyAt(0.0);
    K.fog = mcFogAt(0.0);
    K.capLayer = fract(u.seed * 3.7) < 0.6 ? MC_RED_MUSHROOM_BLOCK : MC_BROWN_MUSHROOM_BLOCK;
    int mp = int(u.seed * 8.0) & 7;
    K.moonLayer = mp == 0 ? MCS_ENVIRONMENT_CELESTIAL_MOON_FULL_MOON
                : mp == 1 ? MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_GIBBOUS
                : mp == 2 ? MCS_ENVIRONMENT_CELESTIAL_MOON_THIRD_QUARTER
                : mp == 3 ? MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_CRESCENT
                : mp == 4 ? MCS_ENVIRONMENT_CELESTIAL_MOON_NEW_MOON
                : mp == 5 ? MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_CRESCENT
                : mp == 6 ? MCS_ENVIRONMENT_CELESTIAL_MOON_FIRST_QUARTER
                : MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_GIBBOUS;
    float ma = fract(u.seed * 7.13) * TWO_PI;
    K.moonDir = normalize(float3(cos(ma), 0.75, sin(ma)));
    return K;
}

static inline int lhLanternLayer(constant LerpUniforms& u) {
    return u.soul != 0 ? mcFrame(MC_SOUL_LANTERN, MC_SOUL_LANTERN_FRAMES, MC_SOUL_LANTERN_TICKS, u.time)
                       : mcFrame(MC_LANTERN, MC_LANTERN_FRAMES, MC_LANTERN_TICKS, u.time);
}

static inline float3 lhScene(float3 ro, float3 rd, float pxAngle, LhEnv E, constant LerpUniforms& u,
                             texture2d_array<float> T, texture2d_array<float> S,
                             texture2d_array<float> M) {
    float3 rdg = select(rd, float3(1e-6), abs(rd) < 1e-6);
    float3 inv = 1.0 / rdg;

    // 1. The fixed pieces, distances only (their faces are found again if
    //    one of them is what the pixel shows).
    float tS = 1e9, tF = 1e9, tD = 1e9;
    {
        float3 n;
        float3 alb;
        lhShroom(ro, rd, inv, tS, n);
        lhPortalFrame(ro, rd, inv, tF, n);
        lhDoor(T, ro, rd, inv, pxAngle, min(tS, tF), tD, n, alb);
    }
    float tFixed = min(min(tS, tF), tD);
    float gIn;
    {
        float3 glo, gld;
        mcMobRay(ro, rd, LH_GOLEM, LH_GOLEM_H, glo, gld);
        float2 gb = mcMobBounds(MCMOB_IRON_GOLEM, glo, gld);
        gIn = gb.x < gb.y ? gb.x : 1e9;
    }

    // 2. March the hill's columns for the ground, gathering what else the ray
    //    might meet: the walkers whose bounds it enters (as j * 2 + k) and a
    //    lamp post's column (its corner and the ray's entry distance).
    float tT = 1e9;
    int2 hitCell = int2(0);
    float3 nW = float3(0.0, 1.0, 0.0);
    float4 cand = float4(0.0);
    int nCand = 0;
    float4 lampA = float4(0.0);
    int nLamp = 0;
    float3 bLo = float3(-LH_BOX, -2.0, -LH_BOX), bHi = float3(LH_BOX, LH_YMAX, LH_BOX);
    float3 t1 = (bLo - ro) * inv, t2 = (bHi - ro) * inv;
    float3 mn = min(t1, t2), mx = max(t1, t2);
    float tIn = max(max(mn.x, mn.y), max(mn.z, 0.0)), tOut = min(min(mx.x, mx.y), mx.z);
    float tGround = rd.y < 0.0 ? -ro.y / rd.y : 1e9;
    if (tIn < tOut && tIn < tGround && tIn < tFixed) {
        float t = tIn + 1e-4;
        float2 p = ro.xz + rd.xz * t;
        int2 cell = int2(floor(p));
        int2 stp = int2(rdg.x > 0.0 ? 1 : -1, rdg.z > 0.0 ? 1 : -1);
        float2 tDelta = abs(inv.xz);
        float2 tMax = (float2(cell) + select(float2(0.0), float2(1.0), rdg.xz > 0.0) - ro.xz) * inv.xz;
        int lastAxis = mn.x > mn.z ? 0 : 1;
        float tPrev = tIn;
        float jDoneLo = 1e9, jDoneHi = -1e9;
        for (int i = 0; i < LH_STEPS; ++i) {
            float tNext = min(min(tMax.x, tMax.y), tOut);
            float yE = ro.y + rd.y * tPrev, yX = ro.y + rd.y * tNext;
            // Nothing in this column reaches the ray: step on. Against the
            // cone through the ledges at the column's centre: the ground is
            // at most 1.35 over it; a walker's feet at most 0.05 over it at
            // its own radius (its hop ends a block up as the ledge steps up)
            // and its head 2.09 above them, its body within 0.35 (0.9 of
            // cone) of a column it is in; a lamp post at most 3.12. On the
            // summit, 2.15 over its top. Nothing walks or stands beyond
            // r = 23.5 (the path's start and its lamps are inside that).
            float rCol = length(float2(cell) + 0.5);
            float cone = LH_CLIMB * (LH_R0 - rCol) / LH_PITCH;
            float hBound = rCol < 23.5 ? clamp(cone + 3.15, 0.05, LH_TOP + 2.15) : 0.05;
            if (min(yE, yX) > hBound) {
                if (tNext >= tOut || tNext > tFixed) break;
                if (tMax.x < tMax.y) { tPrev = tMax.x; tMax.x += tDelta.x; cell.x += stp.x; lastAxis = 0; }
                else                 { tPrev = tMax.y; tMax.y += tDelta.y; cell.y += stp.y; lastAxis = 1; }
                continue;
            }
            LhCell ci = lhCell(cell, min(yE, yX), true);
            float tHit = 1e9;
            float3 n = float3(0.0, 1.0, 0.0);
            if (yE < ci.h) {
                tHit = tPrev;
                n = lastAxis == 0 ? float3(-float(stp.x), 0.0, 0.0) : float3(0.0, 0.0, -float(stp.y));
            } else if (yX < ci.h) {
                tHit = (ci.h - ro.y) / rdg.y;
            }
            // A walker over a ledge column is never more than 3.15 above its
            // ledge (its feet a block up, just past a step, and 2.09 tall).
            if (ci.s > -1e8 && min(yE, yX) < ci.h + 3.2) {
                float tLim = min(tHit, tFixed);
                float2 jr = lhSlots(E.S0, ci.s, 1.3, E.D);
                for (int q = 0; q < 5; ++q) {
                    float j = jr.x + float(q);
                    if (j > jr.y) break;
                    // A walker spans two or three columns: each slot is
                    // tested once per pass across a stretch of ledge.
                    if (j >= jDoneLo && j <= jDoneHi) continue;
                    for (int k = 0; k < 2; ++k) {
                        if (nCand >= 4) break;
                        LhWalker w = lhWalker(j, k, E);
                        if (!w.ok) continue;
                        float3 lro, lrd;
                        if (lhWalkerRay(ro, rd, w, tLim, lro, lrd)) {
                            cand = select(cand, float4(2.0 * j + float(k)), int4(0, 1, 2, 3) == int4(nCand));
                            nCand++;
                        }
                    }
                }
                jDoneLo = jr.x; jDoneHi = jr.y;
            }
            if (ci.lamp && min(yE, yX) < ci.h + 1.7 && nLamp == 0) {
                lampA = float4(float(cell.x), ci.h, float(cell.y), tPrev);
                nLamp = 1;
            }
            if (tHit < 1e8) {
                tT = tHit;
                nW = n;
                hitCell = cell;
                break;
            }
            if (tNext >= tOut || tNext > tFixed) break;
            if (tMax.x < tMax.y) { tPrev = tMax.x; tMax.x += tDelta.x; cell.x += stp.x; lastAxis = 0; }
            else                 { tPrev = tMax.y; tMax.y += tDelta.y; cell.y += stp.y; lastAxis = 1; }
        }
    }
    float tLim = min(tT, tFixed);

    // 3. The mobs: the gathered walkers, then the iron golem. A walker still
    //    coming through the portal exists only on the near side of its plane.
    MCMOB_Hit mh;
    mh.t = INFINITY; mh.n = float3(0.0, 1.0, 0.0); mh.px = float2(0.0); mh.flags = 0;
    float bestJ = 0.0;
    int bestK = 0;
    bool golem = false;
    int nMobs = nCand + (gIn < tLim ? 1 : 0);
    for (int c = 0; c < 5; ++c) {
        if (c >= nMobs) break;
        float lim = min(tLim, mh.t), t0 = 0.0;
        float j = 0.0;
        int k = 0, type;
        MCMOB_Pose pose;
        MCMOB_Skin skin;
        float3 lro, lrd;
        if (c < nCand) {
            float v = cand[c];
            j = floor(v * 0.5);
            k = int(v - 2.0 * j);
            LhWalker w = lhWalker(j, k, E);
            if (!w.ok || !lhWalkerRay(ro, rd, w, lim, lro, lrd) || lhMobIn(w.type, lro, lrd) >= lim) continue;
            if (w.s < LH_PZ + 1.0) {
                if (ro.z > LH_PZ) {
                    if (rd.z < 0.0) lim = min(lim, (LH_PZ - ro.z) / rd.z);
                } else {
                    if (rd.z <= 0.0) continue;
                    t0 = (LH_PZ - ro.z) / rd.z;
                    if (t0 >= lim) continue;
                }
            }
            type = w.type;
            pose = lhPose(w, E.time);
            skin = lhSkin(j, k, type, E.biome);
        } else {
            type = MCMOB_IRON_GOLEM;
            mcMobRay(ro, rd, LH_GOLEM, LH_GOLEM_H, lro, lrd);
            if (gIn >= lim || lhMobIn(type, lro, lrd) >= lim) continue;
            pose = lhGolemPose(E.time);
            skin = mcMobSkin(MCM_IRON_GOLEM);
        }
        MCMOB_Hit h = mcMobTrace(type, pose, skin, lro + lrd * t0, lrd, lim - t0, S, M);
        if (h.t < lim - t0) {
            h.t += t0;
            mh = h;
            bestJ = j;
            bestK = k;
            golem = c == nCand;
        }
    }

    // 4. The lamp post.
    McModelHit lampHit;
    lampHit.t = 1e9; lampHit.n = float3(0.0, 1.0, 0.0); lampHit.color = float4(0.0); lampHit.shade = 1.0;
    lampHit.px = float2(0.0); lampHit.rect = float4(0.0);
    bool lampLantern = false;
    if (nLamp > 0) {
        float lim = min(tLim, mh.t);
        lampHit.t = lim;
        lhLampPost(T, lhLanternLayer(u), lampA.xyz, ro, rd, lampA.w - 1e-4, pxAngle, lampHit, lampLantern);
        if (lampHit.t >= lim) lampHit.t = 1e9;
    }

    // 5. What the pixel shows, and its colour.
    // 0 sky, 1 ground, 2 a mob (a walker or the iron golem), 3 giant
    // mushroom, 4 ground beyond the hill, 5 lamp post, 6 portal frame, 8 door
    int what = 0;
    float tBest = 1e9;
    if (tT < tBest) { tBest = tT; what = 1; }
    if (mh.t < tBest) { tBest = mh.t; what = 2; }
    if (lampHit.t < tBest) { tBest = lampHit.t; what = 5; }
    if (tS < tBest) { tBest = tS; what = 3; }
    if (tF < tBest) { tBest = tF; what = 6; }
    if (tD < tBest) { tBest = tD; what = 8; }
    if (what == 0 && rd.y < 0.0) {
        float tg = -ro.y / rd.y;
        if (tg > 0.0) { tBest = tg; what = 4; hitCell = int2(floor((ro.xz + rd.xz * tg))); }
    }

    LhLook K = lhLookFor(u, M);
    float3 col;
    float3 P = ro + rd * tBest;
    float camD = length(ro.xz);
    if (what == 0) {
        col = lhSky(ro, rd, K, u.time, pxAngle, S, M);
    } else {
        if (what == 2) {
            // A mob: its skin, the face shading, and the light where it stands.
            float3 at = LH_GOLEM;
            float heading = LH_GOLEM_H;
            int type = MCMOB_IRON_GOLEM;
            MCMOB_Skin skin = mcMobSkin(MCM_IRON_GOLEM);
            if (!golem) {
                LhWalker w = lhWalker(bestJ, bestK, E);
                type = w.type;
                skin = lhSkin(bestJ, bestK, type, E.biome);
                at = w.p;
                heading = atan2(w.f.x, w.f.y);
            }
            float4 c = mcMobColor(type, mh, skin, tBest * pxAngle * 16.0, S, M);
            col = c.rgb * mcFaceShade(mcMobNormal(mh.n, heading)) * lhLight(at + float3(0.0, 0.8, 0.0), K);
        } else if (what == 5) {
            float3 N = lampHit.n;
            float shade = lampHit.shade > 0.5 ? mcFaceShade(N) : 1.0;
            // The lantern is drawn at its own light, 15.
            float3 L = lampLantern ? mcLightmap(15.0, 15.0, 0.0, 0.0) * K.light : lhLight(P + N * 0.5, K);
            col = lampHit.color.rgb * shade * L;
        } else {
            float3 alb, N;
            float lit = 1.0, ao = 1.0;
            if (what == 3) {
                float t = 1e9;
                int sPart = lhShroom(ro, rd, inv, t, N);
                float cosi = max(abs(dot(rd, N)), 0.15);
                alb = lhShroomTex(T, P, N, sPart, tBest * pxAngle / cosi, K, lit);
                // The doorway and the hollow behind it, in the stem's shade.
                if (sPart == 0 && P.x < 1.0 - 1e-3 && P.x > -1.0 - 1e-3 && P.z > -1.0 - 1e-3 && P.z < 1e-3 &&
                    P.y < LH_TOP + 2.0 + 1e-3) ao = P.x < 0.0 ? 0.35 : 0.6;
            } else if (what == 6) {
                float t = 1e9;
                lhPortalFrame(ro, rd, inv, t, N);
                float cosi = max(abs(dot(rd, N)), 0.15);
                alb = mcTile(T, MC_OBSIDIAN, lhFaceUV(P, N), tBest * pxAngle / cosi).rgb;
            } else if (what == 8) {
                float t = 1e9;
                lhDoor(T, ro, rd, inv, pxAngle, 1e9, t, N, alb);
                ao = 0.8;
            } else {
                N = nW;
                LhCell hitInfo = lhCell(hitCell, -1e9, false);
                if (what == 4) { hitInfo.h = 0.0; hitInfo.kind = 0; N = float3(0.0, 1.0, 0.0); }
                float cosi = max(abs(dot(rd, N)), 0.08);
                alb = lhTerrainTex(T, P, N, hitCell, hitInfo, tBest * pxAngle / cosi, K);
                if (what == 1) {
                    // Smooth lighting's darkening where a face meets a taller neighbour.
                    if (N.y > 0.5) {
                        float2 f = P.xz - float2(hitCell);
                        float h = hitInfo.h;
                        int2 sx = int2(f.x < 0.5 ? -1 : 1, 0), sz = int2(0, f.y < 0.5 ? -1 : 1);
                        float ex = f.x < 0.5 ? f.x : 1.0 - f.x, ez = f.y < 0.5 ? f.y : 1.0 - f.y;
                        if (lhCell(hitCell + sx, -1e9, false).h > h) ao *= mix(0.6, 1.0, smoothstep(0.0, 0.5, ex));
                        if (lhCell(hitCell + sz, -1e9, false).h > h) ao *= mix(0.6, 1.0, smoothstep(0.0, 0.5, ez));
                    } else {
                        int2 nb = hitCell + int2(int(N.x), int(N.z));
                        float hn = lhCell(nb, -1e9, false).h;
                        ao *= mix(0.6, 1.0, smoothstep(0.0, 0.5, P.y - hn));
                    }
                }
            }
            float shade = mcFaceShade(N);
            float3 L = lit > 0.5 ? lhLight(P + N * 0.5, K) : mcLightmap(15.0, 15.0, 0.0, 0.0) * K.light;
            col = alb * shade * ao * L;
        }
        // Fog past the hill, as the game's distance fog.
        col = mix(col, K.fog, smoothstep(camD - 6.0, camD + 40.0, tBest));
    }

    // The portal itself: translucent, its own animated picture at its own
    // light (11), over whatever lies behind it.
    if (abs(rd.z) > 1e-6) {
        float tP = (LH_PZ - ro.z) / rd.z;
        float3 q = ro + rd * tP;
        if (tP > 0.0 && tP < tBest && q.x > 20.0 && q.x < 22.0 && q.y > 0.0 && q.y < 3.0) {
            float cosi = max(abs(rd.z), 0.15);
            int layer = mcFrame(MC_NETHER_PORTAL, MC_NETHER_PORTAL_FRAMES, MC_NETHER_PORTAL_TICKS, u.time);
            float4 pc = mcTile(T, layer, float2(q.x, -q.y), tP * pxAngle / cosi);
            float3 pcol = pc.rgb * mcFaceShade(float3(0.0, 0.0, 1.0)) * mcLightmap(11.0, 15.0, 0.0, 0.0) * K.light;
            pcol = mix(pcol, K.fog, smoothstep(camD - 6.0, camD + 40.0, tP));
            col = mix(col, pcol, pc.a);
        }
    }
    return col;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    // Frame by the geometric mean of the sides, so a tall screen and a wide
    // one both keep the whole hill without a sea of empty ground or sky.
    float meanRes = sqrt(u.resolution.x * u.resolution.y);
    float pxAngle = 2.0 / (meanRes * LH_FOCAL);

    LhEnv E;
    E.time = u.time;
    E.tau = u.time * u.speed + u.seed * 700.0;
    E.S0 = LH_V * E.tau;
    E.D = 3.3 / u.crowd;
    E.biome = min(int(fract(u.seed * 5.31 + 0.13) * 7.0), 6);

    // A slow orbit round the hill, drifting nearer and higher and back.
    float ct = u.time + u.seed * 977.0;
    float th = u.seed * TWO_PI + ct * (TWO_PI / 720.0);
    // The outward half of the drift is a plain sine; the inward half is
    // eased by tanh so the camera comes no nearer than ~48.2 (the hill filling
    // more of the frame costs GPU time and buys little).
    float dw = sin(ct * (TWO_PI / 260.0));
    dw = dw >= 0.0 ? dw : 0.3 * tanh(dw / 0.3);
    float dist = 50.0 + 6.0 * dw;
    float hgt = 20.0 + 5.0 * sin(ct * (TWO_PI / 330.0) + 1.3);
    float3 target = float3(0.0, 6.5, 0.0);
    float3 ro = float3(dist * cos(th), hgt, dist * sin(th));
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 fwd = normalize(target - ro);
    float3 right = normalize(cross(upHint, fwd));
    lerpOrbit(u.yaw, u.pitch, u.magnify, target, upHint, ro, right, fwd);
    float3 up = cross(fwd, right);

    float2 uv = (2.0 * float2(pos.x, u.resolution.y - pos.y) - u.resolution) / meanRes;
    float3 rd = normalize(uv.x * right + uv.y * up + LH_FOCAL * fwd);
    float3 col = lhScene(ro, rd, pxAngle, E, u, mcTiles, mcSkins, mcMaps);

    col = lerpDither(saturate(col), pos);
    return half4(half3(col), 1.0h);
}
