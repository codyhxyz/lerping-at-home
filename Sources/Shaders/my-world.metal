// My World — the user's own Minecraft save, filmed as slow cinema.
// Drawn from the world baked out of this Mac's own save and the game's own
// textures (`make minecraft`, scripts/minecraft-world/); none of it is in
// this file or this repo.
//
// lerp-category: Minecraft
// lerp-requires: minecraft world:mine
// lerp-plan: 4
//
// A director, not a camera path. It knows nothing of this save in advance:
// everything comes from the bake's points of interest (kind, place, box,
// the side to see a building from), its routes and the volume itself, so
// any baked save gets the same treatment.
//
// - Who gets screen time: points of interest weighted by kind and by rank
//   within their kind (the bake lists the best first). Where a world has
//   built things they take nearly all of it: clusters and buildings first,
//   then lit places (as far as their light reaches the open air, and a light
//   near a brighter one counts for little). A hilltop is then a place to look
//   from (a long lens on a building) or the start of a reveal, and a shore a
//   rare drift. Buildings under the water or the ground (an ocean ruin, a
//   mineshaft) and lights under water are left out. The first shot is always
//   the best place; never the same place twice running.
// - The move suits the subject: a slow orbit of a building, a held shot
//   while the light changes, a vista from a hilltop, a rise from behind a
//   hill revealing a building beyond, a drift along a shore, a walk along a
//   route at eye height. Every visit varies side, distance, height and hour.
// - What passes: the camera never in a block, under water or outside the
//   save; no void within 110 blocks in frame; nothing filling the frame from
//   a few blocks away (rays probed against the ground); the subject's middle
//   and ends not hidden by the ground. A shot that fails is never shown: the
//   director tries each move's four variants, then the same place from
//   higher, then other places with their own moves, then every place in turn
//   from above, until one passes. Among passing variants of the first, a
//   cheaper one to draw is preferred.
// - The hour is chosen for the shot: golden hour mostly (the sun 9 to 16
//   degrees up, beside or behind the camera, so the subject is lit and the
//   sunset colour sits only on the sun's side of the sky), clear daylight a
//   quarter of the time, a backlit shot now and then. Held shots run through
//   golden hour. Lit places are filmed at blue dusk or under a high full moon,
//   from a little above. A walk goes at blue dusk, the lamps and windows lit.
//   The light moves during the shot; the sun is never in the middle of the
//   frame.
// - Shots of 40 seconds, give or take a fifth. Between them the fog rolls in
//   from the distance and the next shot clears out of it (1.75 s each way).
//
// What the film crew adds to the game's light, with restraint: sun and moon
// shadows (the kit's), the low sun warm on the faces it reaches and shade a
// little cooler, moonlight a little silver, the sky's colours in water and as
// a sheen on ice, the game's clouds, the dim parts of a night opened up (not
// the lamps' pools), and air: distance fades into the horizon's colour in its
// own direction, and a far edge of the save into a light mist.
//
// The planning runs once a frame in lerpPlan (one SIMD group, its checks
// shared across the lanes): the director's choice of shot (point-of-interest
// weights, up to 8 candidate place-and-move pairs of 4 variants each, each
// judged by about 225 heightfield and voxel reads split over the 32 lanes,
// and a 32-ray trace through the first passing variants to price them),
// then this frame's camera. lerpMain gets the camera and the fog as 4 float4s
// and traces one scene.
//
// Parameters:
// - Shot length: how long the director holds a place. Some want long, still
//   takes; some want to see more of their world in ten minutes.
// - Light: directed (each shot at its own hour), golden hour only, or night
//   only (lamps and moonlight). A world built for its night lights, or a
//   watcher who wants the warm hours, can say so; the rest is the director's.
//
// lerp-param: shotLength float 20 90 = 40 "Shot length (s)"
// lerp-param: light      int   0 2   = 0  "Light (directed, golden hour, night)"
//
// lerp-preset: "Golden Hour" light=1
// lerp-preset: "Night Lights" light=2
// lerp-preset: "Long Takes"  shotLength=75

// ---- Development: a contact sheet in one frame -----------------------------
// MW_SHEET_COLS > 0 splits the frame into a grid, cell i showing time
// u.time + i * MW_SHEET_STEP. Always 0 in the shipped file.
constant int   MW_SHEET_COLS = 0;
constant int   MW_SHEET_ROWS = 0;
constant float MW_SHEET_STEP = 20.0;
constant bool  MW_SHEET_SHOTS = false;  // cell i shows the middle of shot i instead
constant int   MW_FORCE_POI = -1;    // >= 0: every shot films this point of interest (development)
constant int   MW_FORCE_MOVE = -1;   // >= 0: and with this move
constant int   MW_FORCE_VARIANT = -1; // >= 0: and this variant only, failed or not

// ---- Moves ------------------------------------------------------------------
constant int MW_ORBIT  = 0;   // a slow arc round a structure from its good side
constant int MW_RISE   = 1;   // a crane up from behind, revealing what is beyond
constant int MW_DRIFT  = 2;   // a low lateral drift along a shore
constant int MW_TRIPOD = 3;   // a held shot while the light changes
constant int MW_WALK   = 4;   // a walk along a route at eye height

// Between shots the game's fog rolls in from the distance until the frame is
// the horizon's colour, and the next shot clears out of it, nearest first:
// one scene traced at a time. MW_FOG seconds each way; MW_TRANSITION 0 cuts.
constant int   MW_TRANSITION = 1;
constant float MW_FOG = 1.75;
constant float MW_EYE      = 1.62;  // the game's eye height
constant int   MW_MAX_POI  = 64;
constant int   MW_CANDIDATES = 8;   // (place, move) pairs the director tries per shot

struct MwShot {
    int    move;
    int    poi;
    float3 p0, p1;     // camera path ends (orbit: unused)
    float3 q0, q1;     // look targets at the ends
    float3 c;          // orbit centre
    float4 orb;        // orbit: angle at start, angle at end, radius, height
    float  lens;       // focal length (short-axis half height = 1)
    float  tick0, tick1;
    int    moon;
    int    route;      // walk: route, start position along it, blocks over the shot (signed)
    float  s0, speed;
    float  score;      // how well it passed mwJudge (0: nothing passed)
    float  cost;       // cells a ray visits, on average, in the shot's middle frame (mwCost)
    float3 sight;      // the point that must stay in sight
    float4 box;        // the subject's own columns (x0, z0, x1, z1), which do not hide it
    float  boxTop;     // ... below this height (an iceberg inside a wreck's box still does)
    float  tilt;       // held and drifting shots: the camera's pitch, set for where the horizon sits (> 9: look at the target)
};

// ---- Hashing -------------------------------------------------------------------
static inline uint mwPcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
static inline float mwRand(uint seed, int k, int salt) {
    return float(mwPcg(seed ^ mwPcg(uint(k) * 9781u + uint(salt) * 6271u + 17u))) / 4294967296.0;
}

// ---- Sharing the director's work across a SIMD group --------------------------
// The checks a plan needs are split among the lanes of a SIMD group by rank
// and summed back: each lane does a 32nd of the work and all get the same
// answer. lerpPlan always shares; a contact sheet (cells at different
// times) shares only in a group whose lanes all fall in one cell.
struct MwCoop { uint rank; uint lanes; bool on; };
// `share` must be the same in every lane of the SIMD group (it is: lerpPlan
// passes true; a contact sheet passes whether the whole group is in one cell).
static inline MwCoop mwCoop(bool share) {
    MwCoop c;
    c.on = share;
    if (share) { c.rank = simd_prefix_exclusive_sum(1u); c.lanes = simd_sum(1u); }
    else       { c.rank = 0u; c.lanes = 1u; }
    return c;
}
static inline float mwSum(MwCoop co, float x) { return co.on ? simd_sum(x) : x; }
static inline float mwMax(MwCoop co, float x) { return co.on ? simd_max(x) : x; }

// ---- Reading the world for cameras ------------------------------------------------
static inline float3 mwBoxMin(int i) { return MCW_POI_BOX_MIN[i].xyz; }
static inline float3 mwBoxMax(int i) { return MCW_POI_BOX_MAX[i].xyz; }
static inline float3 mwView(int i)   { return MCW_POI_VIEW[i].xyz; }

// The highest surface (ground or water) within r blocks of xz: what a camera
// there must stay above.
static inline float mwSurfaceNear(McWorld W, float2 xz, float r) {
    float m = mcWorldSurface(W, xz);
    m = max(m, mcWorldSurface(W, xz + float2(r, 0.0)));
    m = max(m, mcWorldSurface(W, xz - float2(r, 0.0)));
    m = max(m, mcWorldSurface(W, xz + float2(0.0, r)));
    m = max(m, mcWorldSurface(W, xz - float2(0.0, r)));
    return m;
}

// Whether a column has anything saved: false off the far field and over
// chunks the save never finished (the void the game shows there).
static inline bool mwSaved(McWorld W, float2 xz) {
    float w;
    return mcWorldGround(W, xz, w) > -1e3;
}

// ---- Points of interest ----------------------------------------------------------------
// Whether the camera can film it at all: a structure whose top is under the
// water or the ground (an ocean ruin, a mineshaft) is not seen from the air.
static inline bool mwVisible(McWorld W, int i) {
    float3 lo = mwBoxMin(i), hi = mwBoxMax(i);
    float2 c = (lo.xz + hi.xz) * 0.5;
    float surf = mcWorldSurface(W, c);
    int kind = MCW_POI_KIND[i];
    if (kind == MCW_POI_LIT || kind == MCW_POI_BELL) {
        // Light under water or under the ice is not what a night shot is for.
        float water, ground = mcWorldGround(W, MCW_POI[i].xz, water);
        return MCW_POI[i].y >= surf - 1.5 && water <= ground + 0.01;
    }
    if (kind == MCW_POI_STRUCTURE || kind == MCW_POI_CLUSTER) return hi.y >= surf + 1.0;
    return true;
}

// Screen time: the bake lists the best first within each kind; each kind has
// a weight and the n-th of a kind gets 1 / (1 + 0.7 n) of it.
// Screen time by kind: built things take nearly all of it where a world has
// them; a hilltop or a shore is then a place to look from, not a subject.
static inline float mwKindWeight(int kind, bool built) {
    switch (kind) {
        case MCW_POI_CLUSTER:   return 3.0;
        case MCW_POI_STRUCTURE: return 2.4;
        case MCW_POI_BELL:      return 0.8;
        case MCW_POI_LIT:       return 0.45;
        case MCW_POI_HILLTOP:   return built ? 0.25 : 1.3;
        default:                return built ? 0.4 : 1.2;   // shore
    }
}

static inline bool mwIsBuilt(int kind) {
    return kind == MCW_POI_STRUCTURE || kind == MCW_POI_CLUSTER || kind == MCW_POI_BELL;
}

// How much block light a lit place shows: the light a block above its
// ground over a 5 x 5 spread round it.
static inline float mwLitAmount(McWorld W, int i) {
    float sum = 0.0;
    for (int j = 0; j < 25; ++j) {
        float2 xz = MCW_POI[i].xz + (float2(j % 5, j / 5) - 2.0) * 3.0;
        float4 L = mcwLightAt(W, float3(xz.x, mcWorldSurface(W, xz) + 1.5, xz.y));
        sum += max(L.r, max(L.g, L.b));
    }
    return sum;
}

static inline float mwWeights(McWorld W, thread float* w) {
    bool built = false;
    for (int i = 0; i < min(MCW_POI_COUNT, MW_MAX_POI); ++i)
        built = built || (mwIsBuilt(MCW_POI_KIND[i]) && mwVisible(W, i));
    int seen[6] = {0, 0, 0, 0, 0, 0};
    float total = 0.0, litTop = 0.0;
    for (int i = 0; i < min(MCW_POI_COUNT, MW_MAX_POI); ++i) {
        int k = MCW_POI_KIND[i];
        w[i] = mwVisible(W, i) ? mwKindWeight(k, built) / (1.0 + 0.7 * float(seen[k])) : 0.0;
        if (k == MCW_POI_LIT && w[i] > 0.0) {
            // A lit place is worth a night shot as far as its light reaches
            // the open air, against the brightest of them.
            float a = mwLitAmount(W, i);
            litTop = max(litTop, a);
            w[i] *= saturate(a / max(litTop, 1e-3) * 1.5 - 0.5);
            // Lights near a brighter one are the same place by night.
            for (int j = 0; j < i; ++j)
                if (MCW_POI_KIND[j] == MCW_POI_LIT && distance(MCW_POI[j].xz, MCW_POI[i].xz) < 48.0) w[i] *= 0.25;
        }
        seen[k] += 1;
        total += w[i];
    }
    return total;
}

static inline int mwPickPoi(thread const float* w, float total, float r) {
    float x = r * total;
    int last = 0;
    for (int i = 0; i < min(MCW_POI_COUNT, MW_MAX_POI); ++i) {
        if (w[i] > 0.0) last = i;
        if (x < w[i]) return i;
        x -= w[i];
    }
    return last;
}

// ---- Planning a shot -------------------------------------------------------------------

static inline float mwEase(float f) { return mix(f, f * f * (3.0 - 2.0 * f), 0.35); }

// Camera and target for a fraction f of the shot.
static inline void mwPose(McWorld W, MwShot s, float f, thread float3& ro, thread float3& target) {
    float e = mwEase(f);
    if (s.move == MW_ORBIT) {
        float a = mix(s.orb.x, s.orb.y, e);
        ro = s.c + float3(cos(a) * s.orb.z, s.orb.w, sin(a) * s.orb.z);
        target = mix(s.q0, s.q1, e);
    } else if (s.move == MW_WALK) {
        float sp = s.s0 + s.speed * f;
        float dir = sign(s.speed);
        float h;
        float3 a = float3(0.0), b = float3(0.0);
        for (int i = -2; i <= 2; ++i) {
            a += mcWorldRoute(s.route, sp + float(i), 1.0, h);
            b += mcWorldRoute(s.route, sp + dir * 7.0 + float(i) * 1.5, 1.0, h);
        }
        ro = a / 5.0 + float3(0.0, MW_EYE, 0.0);
        target = b / 5.0 + float3(0.0, MW_EYE - 0.3, 0.0);
    } else {
        ro = mix(s.p0, s.p1, e);
        target = mix(s.q0, s.q1, e);
    }
    if (s.tilt < 9.0) {
        float2 hz = normalize(target.xz - ro.xz + float2(1e-5, 0.0));
        target = ro + float3(hz.x, tan(s.tilt), hz.y) * 10.0;
    }
    // Never a look straight up or down (a route that doubles back can put
    // the look-ahead point under the eye): at most 70 degrees off level.
    float3 d = target - ro;
    float hl = length(d.xz);
    if (hl < 1e-3) { d.xz = float2(1e-3, 0.0); hl = 1e-3; }
    d.y = clamp(d.y, -2.75 * hl, 2.75 * hl);
    target = ro + d;
}

// The first ground (heightfield) along a ray, roughly: what a camera would
// have right in front of its lens.
static inline float mwProbe(McWorld W, float3 ro, float3 rd) {
    float d = 1.2;
    for (int i = 0; i < 12; ++i) {
        float3 p = ro + rd * d;
        if (mcWorldSurface(W, p.xz) > p.y) return d;
        d *= 1.42;
    }
    return 1e4;
}

constant int MW_TV = 35;   // void samples: 5 headings across the frame x 7 distances
constant int MW_TP = 15;   // lens probes: 5 x 3 rays
constant int MW_TL = 24;   // sight-line samples: 8 to the subject's middle and 8 to each end
constant int MW_TPOSE = MW_TV + MW_TP + MW_TL + 1;   // + the camera's own place

// How good a planned shot is, judged at its start, middle and end: 0 if the
// camera would be in a block or under water, see the void, or have something
// filling the frame from too close; else up to 1, less when the ground hides
// the subject. Shared across the SIMD group (mwCoop).
static inline float mwJudge(McWorld W, MwShot s, float aspect, MwCoop co) {
    float3 ro[3], tg[3];
    for (int i = 0; i < 3; ++i) mwPose(W, s, float(i) * 0.5, ro[i], tg[i]);
    bool walk = s.move == MW_WALK;
    // A walk that doubles back on itself (a route walks out along a branch and back).
    if (walk && (abs(s.speed) < 8.0 || length(ro[2] - ro[0]) < 0.55 * abs(s.speed))) return 0.0;
    bool sight = s.move == MW_ORBIT || s.move == MW_TRIPOD || s.move == MW_RISE;
    float fail = 0.0, nearN = 0.0, blocked = 0.0, voidN = 0.0;
    for (uint task = co.rank; task < uint(3 * MW_TPOSE); task += co.lanes) {
        int pi = int(task) / MW_TPOSE, j = int(task) % MW_TPOSE;
        float3 o = ro[pi], t = tg[pi];
        float3 fwd = normalize(t - o);
        float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
        float3 up = cross(right, fwd);
        if (j < MW_TV) {
            // The ground under headings across the frame, out to the fog or to
            // where the frame's top edge comes down to the ground.
            float pitch = asin(clamp(fwd.y, -1.0, 1.0));
            float top = pitch + atan(1.0 / s.lens);
            float ground = mcWorldSurface(W, o.xz);
            // Only near void counts: farther off, the edge mist (mwEdge) and
            // the haze have taken the world to the horizon's colour, which is
            // what the void shows too.
            float reach = top >= -0.02 ? 110.0 : clamp((o.y - ground) / tan(-top), 8.0, 110.0);
            int a = j / 7, b = j % 7;
            float2 f2 = normalize(fwd.xz + float2(1e-5, 0.0));
            float2 r2 = float2(-f2.y, f2.x);
            float2 d = normalize(f2 + r2 * (float(a) - 2.0) * 0.5 * (aspect / s.lens) * 1.05);
            float dist = min(3.0 * exp2(float(b)), reach);
            if (!mwSaved(W, o.xz + d * dist)) voidN += 1.0;
        } else if (j < MW_TV + MW_TP) {
            int q = j - MW_TV, col = q % 5, row = q / 5;
            if (walk && row == 0) continue;
            float3 rd = normalize(right * (float(col) - 2.0) * 0.45 * aspect + up * (float(row) - 1.0) * 0.8
                                  + fwd * s.lens);
            float hit = mwProbe(W, o, rd);
            float D = length(t - o);
            float lim = walk ? 3.0 : s.move == MW_DRIFT ? 6.0 : (s.move == MW_RISE && pi == 0) ? 5.0
                      : max(6.0, 0.4 * D);
            if (hit < 2.0) fail = 1.0;
            if (hit < lim) nearN += 1.0;
        } else if (j < MW_TV + MW_TP + MW_TL) {
            // The ground (an iceberg, a hill) between the camera and the
            // subject's top, short of the subject's own columns.
            if (!sight || s.sight.y < 0.0 || (s.move == MW_RISE && pi == 0)) continue;
            // Its own blocks do not hide it.
            int q = j - MW_TV - MW_TP, which = q % 3;
            float2 ext = s.box.zw - s.box.xy;
            float2 axis = ext.x > ext.y ? float2(ext.x * 0.3, 0.0) : float2(0.0, ext.y * 0.3);
            float3 aim = s.sight + float3(axis.x, 0.0, axis.y) * float(which == 0 ? 0 : which == 1 ? 1 : -1);
            // Packed toward the subject, where what hides a subject usually is.
            float u2 = float(q / 3 + 1) / float(MW_TL / 3 + 1);
            float L2 = max(distance(o, aim), 1.0);
            float3 p = mix(o, aim, (1.0 - (1.0 - u2) * (1.0 - u2)) * (1.0 - 2.0 / L2));
            float g = mcWorldSurface(W, p.xz);
            if (all(p.xz > s.box.xy) && all(p.xz < s.box.zw) && g <= s.boxTop) continue;
            if (g > p.y + 0.5) blocked += which == 0 ? 3.0 : 1.0;
        } else {
            if (any(o.xz < 4.0) || any(o.xz > MCW_SIZEF.xz - 4.0)) fail = 1.0;
            if (walk) { if (mcWorldSolid(W, o)) fail = 1.0; }
            else if (o.y < mwSurfaceNear(W, o.xz, 1.5) + 1.5) fail = 1.0;
        }
    }
    fail = mwMax(co, fail);
    nearN = mwSum(co, nearN);
    blocked = mwSum(co, blocked);
    voidN = mwSum(co, voidN);
    if (MW_SHEET_COLS > 0) {
        // Development: why it failed, as a negative score.
        if (fail > 0.0) return -1.0;
        if (voidN > 0.0) return -2.0;
        if (nearN > 5.0) return -3.0;
        if (blocked > 2.5) return -4.0;
    }
    if (fail > 0.0 || voidN > 0.0 || nearN > 5.0 || blocked > 2.5) return 0.0;
    return 1.0;
}

// What a shot will cost to draw: 32 real rays through its middle frame, on
// an 8 x 4 grid, and the cells they visit on average. The trace is most of a
// frame's cost, and it is the place that decides it (a field of snow layers
// seen across from low down is dear; the same place from higher up is not),
// so the director measures rather than guesses. One ray a lane in lerpPlan.
constant float MW_COST_OK = 24.0;   // cells per ray a shot may cost without looking for a cheaper variant

static inline float mwCost(McWorld W, MwShot s, float aspect, MwCoop co) {
    float3 ro, tg;
    mwPose(W, s, 0.5, ro, tg);
    float3 fwd = normalize(tg - ro);
    float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, fwd);
    float steps = 0.0;
    for (uint i = co.rank; i < 32u; i += co.lanes) {
        float2 g = (float2(float(i % 8u), float(i / 8u)) + 0.5) / float2(8.0, 4.0) * 2.0 - 1.0;
        float3 rd = normalize(g.x * aspect * right + g.y * up + s.lens * fwd);
        steps += float(mcWorldTrace(W, ro, rd, mcWorldFogEnd()).steps);
    }
    return mwSum(co, steps) / 32.0;
}

static inline MwShot mwBlank(int poi) {
    MwShot s;
    s.move = MW_ORBIT; s.poi = poi;
    s.p0 = s.p1 = s.q0 = s.q1 = s.c = float3(0.0);
    s.orb = float4(0.0);
    s.lens = 2.0; s.tick0 = 23500.0; s.tick1 = 23760.0; s.moon = 0;
    s.route = 0; s.s0 = 0.0; s.speed = 0.0; s.score = 0.0; s.cost = 0.0; s.sight = float3(-1.0); s.box = float4(0.0); s.boxTop = 0.0; s.tilt = 99.0;
    return s;
}

// The subject's middle and size, from its box.
static inline float3 mwSubject(McWorld W, int i, thread float& size, thread float& top) {
    float3 lo = mwBoxMin(i), hi = mwBoxMax(i);
    float2 c = (lo.xz + hi.xz) * 0.5;
    int kind = MCW_POI_KIND[i];
    float surf = mcWorldSurface(W, c);
    if (kind == MCW_POI_STRUCTURE || kind == MCW_POI_CLUSTER) {
        size = max(hi.x - lo.x, hi.z - lo.z) * 0.5;
        top = hi.y;
        float floorY = max(lo.y, min(surf, hi.y - 2.0));
        return float3(c.x, mix(floorY, hi.y, 0.4), c.y);
    }
    size = kind == MCW_POI_LIT ? 7.0 : MCW_POI[i].w * 0.5;
    top = MCW_POI[i].y + 3.0;
    // A hilltop's point is its summit: aim at the body of the hill below it,
    // so the peak sits high in the frame rather than on the frame's middle line.
    if (kind == MCW_POI_HILLTOP) return float3(MCW_POI[i].x, MCW_POI[i].y - 6.0, MCW_POI[i].z);
    return float3(MCW_POI[i].x, max(MCW_POI[i].y, surf) + 1.0, MCW_POI[i].z);
}

static inline MwShot mwOrbit(McWorld W, int poi, uint seed, int k, int variant) {
    MwShot s = mwBlank(poi);
    s.move = MW_ORBIT;
    float size, top;
    float3 c = mwSubject(W, poi, size, top);
    float3 v = mwView(poi);
    float base = length(v) > 0.1 ? atan2(v.z, v.x) : mwRand(seed, k, 11) * 6.2832;
    if (variant == 3) {
        // From the side where the save ends, looking in across the subject:
        // the one view of a place at the edge that never shows the void.
        float2 voidDir = float2(0.0);
        for (int i = 0; i < 8; ++i) {
            float a = float(i) * 0.7854;
            float2 d = float2(cos(a), sin(a));
            if (!mwSaved(W, c.xz + d * 28.0) || any(c.xz + d * 28.0 < 0.0) || any(c.xz + d * 28.0 > MCW_SIZEF.xz))
                voidDir += d;
        }
        if (length(voidDir) > 0.1) base = atan2(voidDir.y, voidDir.x);
        else base += 2.5;
    } else {
        base += float((variant + 1) / 2) * 1.25 * (variant % 2 == 0 ? 1.0 : -1.0);
    }
    // Every visit differs: side (within 45 degrees of the good one), distance and height.
    base += (mwRand(seed, k, 12) - 0.5) * 1.6;
    // Toward a camera with the sun beside it (the sun moves in the east-west
    // plane, so a camera north or south of its subject): light that rakes
    // across the faces and throws visible shadows. Up to 35 degrees.
    if (variant < 3) {
        float toNS = (sin(base) >= 0.0 ? 1.5708 : -1.5708) - base;
        toNS = atan2(sin(toNS), cos(toNS));
        base += clamp(toNS, -0.61, 0.61);
    }
    float dir = mwRand(seed, k, 13) < 0.5 ? -1.0 : 1.0;
    float sweep = 0.55 + 0.3 * mwRand(seed, k, 14);
    float R = clamp(size * 2.1 + 10.0, 16.0, 70.0) * (0.85 + 0.65 * mwRand(seed, k, 15));
    float el = 0.12 + 0.36 * mwRand(seed, k, 16);
    if (variant == 3) {
        // Close in on the edge side and look down over the subject into the world.
        float room = 1e4;
        for (int i = 4; i <= 32; i += 4) {
            float2 p = c.xz + float2(cos(base), sin(base)) * float(i);
            if (!mwSaved(W, p) || any(p < 6.0) || any(p > MCW_SIZEF.xz - 6.0)) { room = float(i) - 4.0; break; }
        }
        R = clamp(min(R, room), 8.0, R);
        el = 0.55;
        sweep *= 0.5;
    }
    s.c = c;
    s.sight = float3(c.x, mix(c.y, top, 0.85), c.z);   // near its top: a deck, a roof
    int kind = MCW_POI_KIND[poi];
    s.box = (kind == MCW_POI_STRUCTURE || kind == MCW_POI_CLUSTER || kind == MCW_POI_BELL)
          ? float4(mwBoxMin(poi).xz - 0.5, mwBoxMax(poi).xz + 0.5) : float4(c.xz - 2.5, c.xz + 2.5);
    s.boxTop = top + 1.0;
    s.orb = float4(base - dir * sweep * 0.5, base + dir * sweep * 0.5, R, R * tan(el));
    // A building is looked down on, from over its top: a low ship or a hut
    // seen from below its own roofline hides behind the first thing in front.
    if (kind == MCW_POI_STRUCTURE || kind == MCW_POI_CLUSTER) s.orb.w = max(s.orb.w, top - c.y + 4.0);
    s.q0 = c; s.q1 = c + float3(0.0, 0.5, 0.0);
    if (variant == 3) {
        float2 in2 = -float2(cos(base), sin(base));
        s.q0 = s.q1 = c + float3(in2.x, 0.0, in2.y) * R * 0.25 - float3(0.0, 1.0, 0.0);
    }
    s.lens = 2.0;
    return s;
}

static inline MwShot mwRise(McWorld W, int poi, uint seed, int k, int variant) {
    MwShot s = mwBlank(poi);
    s.move = MW_RISE;
    float size, top;
    float3 c = mwSubject(W, poi, size, top);
    // What the rise reveals: another place, 40 to 170 blocks on past this
    // one (the variant-th such, best first); with none, the middle of the world.
    int found = -1, n = 0;
    for (int j = 0; j < min(MCW_POI_COUNT, MW_MAX_POI) && found < 0; ++j) {
        float dj = distance(MCW_POI[j].xz, c.xz);
        if (j == poi || dj < 40.0 || dj > 170.0 || !mwVisible(W, j)) continue;
        if (!mwIsBuilt(MCW_POI_KIND[j]) && mwIsBuilt(MCW_POI_KIND[0])) continue;
        if (n++ == variant) found = j;
    }
    float2 toward = found >= 0 ? MCW_POI[found].xz - c.xz : MCW_SIZEF.xz * 0.5 - c.xz;
    float a = atan2(toward.y, toward.x)
            + (found >= 0 ? 0.0 : float((variant + 1) / 2) * 0.9 * (variant % 2 == 0 ? 1.0 : -1.0))
            + (mwRand(seed, k, 21) - 0.5) * 0.2;
    float2 d = float2(cos(a), sin(a));
    float back = max(size * 1.2, 10.0) + 8.0;
    float2 xz0 = c.xz - d * back;
    float g0 = mwSurfaceNear(W, xz0, 1.5);
    s.p0 = float3(xz0.x, max(g0 + 2.5, c.y - 6.0), xz0.y);
    float2 xz1 = c.xz - d * (back * 0.75);
    s.p1 = float3(xz1.x, max(top, c.y) + 12.0 + 6.0 * mwRand(seed, k, 22), xz1.y);
    s.q0 = float3(c.x + d.x * 40.0, s.p0.y + 2.0, c.z + d.y * 40.0);
    s.q1 = float3(c.x + d.x * 60.0, c.y - 4.0, c.z + d.y * 60.0);
    if (found >= 0) {
        float sz, tp;
        float3 r = mwSubject(W, found, sz, tp);
        s.q1 = r;
        s.sight = float3(r.x, mix(r.y, tp, 0.6), r.z);
        int kj = MCW_POI_KIND[found];
        s.box = (kj == MCW_POI_STRUCTURE || kj == MCW_POI_CLUSTER || kj == MCW_POI_BELL)
              ? float4(mwBoxMin(found).xz - 0.5, mwBoxMax(found).xz + 0.5) : float4(r.xz - 2.5, r.xz + 2.5);
        s.boxTop = tp + 1.0;
    }
    s.lens = 1.9;
    return s;
}

static inline MwShot mwDrift(McWorld W, int poi, uint seed, int k, int variant) {
    MwShot s = mwBlank(poi);
    s.move = MW_DRIFT;
    float3 c = MCW_POI[poi].xyz;
    // Which way is land: the dry columns in a ring round the point.
    float2 land = float2(0.0);
    float waterY = -1e4;
    for (int i = 0; i < 12; ++i) {
        float a = float(i) * 0.5236;
        float2 d = float2(cos(a), sin(a));
        float w, g = mcWorldGround(W, c.xz + d * 10.0, w);
        if (g >= w - 0.01) land += d; else waterY = max(waterY, w);
    }
    if (length(land) < 0.1) land = float2(1.0, 0.0);
    land = normalize(land);
    if (waterY < -1e3) waterY = c.y;
    float2 t = float2(-land.y, land.x) * (variant % 2 == 0 ? 1.0 : -1.0);
    float off = 12.0 + 6.0 * mwRand(seed, k, 31) + 6.0 * float(variant / 2);
    float span = 10.0 + 6.0 * mwRand(seed, k, 32);
    float2 mid = c.xz - land * off;
    // Over open water low, over ice (or a frozen sea) higher: flat ice from
    // two blocks up is a frame of one texture.
    float wY, gY = mcWorldGround(W, mid, wY);
    bool open = wY > gY + 0.5;
    float y = max(waterY, mwSurfaceNear(W, mid, 2.0)) + (open ? 2.2 : 5.0) + 2.5 * mwRand(seed, k, 33);
    s.p0 = float3(mid.x - t.x * span, y, mid.y - t.y * span);
    s.p1 = float3(mid.x + t.x * span, y, mid.y + t.y * span);
    float2 look = normalize(land + t * 0.55);
    s.q0 = float3(s.p0.x + look.x * 40.0, c.y + 1.0, s.p0.z + look.y * 40.0);
    s.q1 = float3(s.p1.x + look.x * 40.0, c.y + 1.0, s.p1.z + look.y * 40.0);
    s.lens = 2.0;
    return s;
}

static inline MwShot mwTripod(McWorld W, int poi, uint seed, int k, int variant) {
    MwShot s = mwOrbit(W, poi, seed, k, variant);
    s.move = MW_TRIPOD;
    float a = (s.orb.x + s.orb.y) * 0.5;
    float R = s.orb.z * 1.1;
    float2 xz = s.c.xz + float2(cos(a), sin(a)) * R;
    // A hill is held from below its summit, the peak against the sky; anything
    // else from a little above.
    bool hill = MCW_POI_KIND[poi] == MCW_POI_HILLTOP;
    float y = max(mwSurfaceNear(W, xz, 1.5) + 3.0, s.c.y + R * (hill ? -0.05 : 0.12));
    int kind = MCW_POI_KIND[poi];
    if (kind == MCW_POI_STRUCTURE || kind == MCW_POI_CLUSTER) y = max(y, mwBoxMax(poi).y + 2.0);
    // A light is held from a little above, looking down on its pool: across
    // a field of snow layers from low down every ray grazes models (2.6 ms).
    if (kind == MCW_POI_LIT) y = max(y, s.c.y + 4.0 + 0.15 * R);
    s.p0 = float3(xz.x, y, xz.y);
    s.p1 = s.p0 + normalize(s.c - s.p0) * 2.0;
    s.q0 = s.c; s.q1 = s.c;
    s.lens = 2.6;
    return s;
}

// A hilltop as a place to look from: the camera on the summit, a long lens
// on a built place 30 to 220 blocks off (the variant-th, best first), a
// slow push toward it. A world with nothing built holds on the hill itself.
static inline MwShot mwVista(McWorld W, int poi, uint seed, int k, int variant) {
    int found = -1, n = 0;
    for (int j = 0; j < min(MCW_POI_COUNT, MW_MAX_POI) && found < 0; ++j) {
        float dj = distance(MCW_POI[j].xz, MCW_POI[poi].xz);
        if (j == poi || dj < 30.0 || dj > 220.0 || !mwIsBuilt(MCW_POI_KIND[j]) || !mwVisible(W, j)) continue;
        if (n++ == variant) found = j;
    }
    if (found < 0) return mwTripod(W, poi, seed, k, variant);
    MwShot s = mwBlank(poi);
    s.move = MW_TRIPOD;
    float sz, tp;
    float3 r = mwSubject(W, found, sz, tp);
    float2 d = normalize(r.xz - MCW_POI[poi].xz);
    float2 side = float2(-d.y, d.x) * (mwRand(seed, k, 51) - 0.5) * 8.0;
    float2 xz = MCW_POI[poi].xz + d * (2.0 + 4.0 * mwRand(seed, k, 52)) + side;
    s.p0 = float3(xz.x, mwSurfaceNear(W, xz, 1.5) + 2.5 + 3.0 * mwRand(seed, k, 53), xz.y);
    s.p1 = s.p0 + float3(d.x, 0.0, d.y) * 4.0;
    s.q0 = s.q1 = r;
    s.c = r;
    s.sight = float3(r.x, mix(r.y, tp, 0.85), r.z);
    s.box = float4(mwBoxMin(found).xz - 0.5, mwBoxMax(found).xz + 0.5);
    s.boxTop = tp + 1.0;
    s.lens = clamp(distance(s.p0, r) / 22.0, 2.4, 5.0);
    return s;
}

static inline MwShot mwWalk(McWorld W, int poi, uint seed, int k, int variant) {
    MwShot s = mwBlank(poi);
    s.move = MW_WALK;
    s.route = int(mwRand(seed, k, 41 + variant) * float(MCW_ROUTE_COUNT)) % MCW_ROUTE_COUNT;
    float n = float(MCW_ROUTES[s.route].y);
    s.s0 = floor(mwRand(seed, k, 45 + variant) * n);
    s.speed = (variant % 2 == 0 ? 1.0 : -1.0) * min(22.0, n * 0.5);
    s.lens = 1.8;
    return s;
}

static inline MwShot mwPlan(McWorld W, int move, int poi, uint seed, int k, int variant) {
    switch (move) {
        case MW_RISE:   return mwRise(W, poi, seed, k, variant);
        case MW_DRIFT:  return mwDrift(W, poi, seed, k, variant);
        case MW_TRIPOD: return MCW_POI_KIND[poi] == MCW_POI_HILLTOP ? mwVista(W, poi, seed, k, variant)
                                                                    : mwTripod(W, poi, seed, k, variant);
        case MW_WALK:   return mwWalk(W, poi, seed, k, variant);
        default:        return mwOrbit(W, poi, seed, k, variant);
    }
}

// The move a subject gets: what suits its kind, varied by the shot's hash.
static inline int mwMoveFor(int kind, float r) {
    switch (kind) {
        case MCW_POI_STRUCTURE:
        case MCW_POI_CLUSTER:
        case MCW_POI_BELL:  return r < 0.5 ? MW_ORBIT : r < 0.75 ? MW_TRIPOD : r < 0.92 ? MW_RISE : MW_WALK;
        case MCW_POI_LIT:   return r < 0.5 ? MW_TRIPOD : r < 0.85 ? MW_ORBIT : MW_WALK;
        case MCW_POI_HILLTOP: return r < 0.6 ? MW_TRIPOD : MW_RISE;   // a vista, or a reveal
        default:            return r < 0.7 ? MW_DRIFT : MW_TRIPOD;   // shore
    }
}

// ---- Time of day ----------------------------------------------------------------------
// Ticks: 0 sunrise, 6000 noon, 12000 sunset, 18000 midnight. The sun rises in
// the east (+x) and sets in the west, always in the east-west plane.

// Whether the sun's disc would sit in the middle of the frame (a sun dead
// centre is a snapshot, not a composition).
static inline bool mwSunCentral(float3 look, float ticks, float lens, float aspect) {
    float3 sun = mcWorldSunDir(glmod(ticks, 24000.0));
    float3 right = normalize(cross(look, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, look);
    float z = dot(sun, look);
    if (z <= 0.0) return false;
    float2 sp = float2(dot(sun, right), dot(sun, up)) / z * lens;
    return abs(sp.x) < 0.5 * aspect && sp.y > -0.9 && sp.y < 1.1;
}

// The same light on the other side of noon, still running forward.
static inline float2 mwMirror(float2 tk) {
    return float2(glmod(12000.0 - tk.y, 24000.0), glmod(12000.0 - tk.x, 24000.0));
}

// Day shots put the sun behind or beside the camera so the subject is lit:
// golden hour (the sun 12 to 25 degrees up) mostly, clear daylight often,
// and the occasional backlit shot toward a low sun. Night is mostly blue
// dusk or a high moon, exposed for the lights.
static inline float2 mwHours(MwShot s, int kind, float3 look, float r, float r2, int lightMode, float aspect,
                             bool hero) {
    // A walk goes at blue dusk, the lamps and windows lit: at eye height the
    // sun's shadow rays cost 3 to 5 ms among walls and plants, and with the
    // sun just under the horizon there are none to trace.
    if (s.move == MW_WALK && lightMode != 1) { float a = 12900.0 + 300.0 * r2; return float2(a, a + 250.0); }
    bool night = lightMode == 2 || (lightMode == 0 && kind == MCW_POI_LIT && !hero);
    if (night) {
        if (s.move == MW_TRIPOD && lightMode != 2) return float2(12600.0, 13500.0);   // the lamps come up
        if (r < 0.6) { float a = 12950.0 + 450.0 * r2; return float2(a, a + 250.0); }  // blue dusk
        float a = 16500.0 + 3000.0 * r2;                                            // a high moon
        return float2(a, a + 400.0);
    }
    // Looking west, the morning sun is behind the camera; looking east, the evening sun.
    bool morning = abs(look.x) < 0.3 ? r2 < 0.5 : look.x < 0.0;
    bool daylight = !hero && lightMode == 0 && r > 0.75;
    bool backlit = !hero && !daylight && r < 0.12;
    if (backlit) morning = !morning;
    float2 tk;
    if (daylight) {
        float a = morning ? 2200.0 + 1600.0 * r2 : 8200.0 + 1600.0 * r2;
        tk = float2(a, a + 500.0);
    } else if (s.move == MW_TRIPOD) {
        // The light changing over a held frame: into golden hour, or through it.
        tk = morning ? float2(23700.0, 24500.0) : float2(11200.0, 12000.0);
    } else if (s.move == MW_DRIFT) {
        tk = morning ? float2(24000.0, 24450.0) : float2(11550.0, 12000.0);
    } else {
        float a = morning ? 23800.0 + 350.0 * r2 : 11700.0 + 250.0 * r2;   // the sun 9 to 16 degrees up
        tk = float2(a, a + 260.0);
    }
    if (mwSunCentral(look, mix(tk.x, tk.y, 0.5), s.lens, aspect)) tk = mwMirror(tk);
    return tk;
}

// The place shot k first picks: the best place for shot 0 (open on the place
// with the most screen time), else a draw weighted by screen time.
static inline int mwFirstPick(thread const float* w, float total, uint seed, int k) {
    if (k < 0) return -1;
    if (k == 0) {
        int best = 0;
        float most = -1.0;
        for (int i = 0; i < min(MCW_POI_COUNT, MW_MAX_POI); ++i)
            if (w[i] > most) { most = w[i]; best = i; }
        return best;
    }
    return mwPickPoi(w, total, mwRand(seed, k, 1));
}

// Shot k: its subject, move, camera and light.
static inline MwShot mwShot(McWorld W, thread const float* w, float total, uint seed, int k, float aspect,
                            int lightMode, MwCoop co) {
    // Not the place either of the last two shots filmed (as first picked).
    int poi = mwFirstPick(w, total, seed, k);
    int before1 = mwFirstPick(w, total, seed, k - 1), before2 = mwFirstPick(w, total, seed, k - 2);
    before2 = -1;   // only the shot just before: a world with one building films it often, from new sides
    if (k > 0 && poi == before1) {
        float wx[MW_MAX_POI];
        float tx = 0.0;
        for (int i = 0; i < min(MCW_POI_COUNT, MW_MAX_POI); ++i) {
            wx[i] = (i == before1 || i == before2) ? 0.0 : w[i];
            tx += wx[i];
        }
        if (tx > 0.0) poi = mwPickPoi(wx, tx, mwRand(seed, k, 4));
    }
    if (MW_FORCE_POI >= 0) poi = min(MW_FORCE_POI, MCW_POI_COUNT - 1);
    int kind = MCW_POI_KIND[poi];
    int move = MW_FORCE_MOVE >= 0 ? MW_FORCE_MOVE : mwMoveFor(kind, k == 0 ? 0.0 : mwRand(seed, k, 2));
    if (lightMode == 1 && move == MW_WALK) move = MW_ORBIT;   // a walk is a dusk shot (mwHours); golden hour only orbits
    MwShot best = mwPlan(W, move, poi, seed, k, max(MW_FORCE_VARIANT, 0));
    best.score = mwJudge(W, best, aspect, co);
    best.cost = best.score > 0.0 ? mwCost(W, best, aspect, co) : 1e9;
    if (MW_FORCE_VARIANT >= 0) return best;
    // Candidates in order until one passes: this place with its move, this
    // place from an orbit set higher, then other places (none of the last
    // two shots') with their own moves, alternating with orbits. Within a
    // candidate, the first variant that passes and is cheap enough, else the
    // cheapest that passes; only the first candidate looks for a cheaper
    // variant of a shot that passed. A shot that fails is never chosen while anything
    // passes; MW_CANDIDATES is sized so that across 400 shots on each test
    // world something always did (see the file's notes).
    float wx[MW_MAX_POI];
    float tx = 0.0;
    for (int i = 0; i < min(MCW_POI_COUNT, MW_MAX_POI); ++i) {
        wx[i] = (i == before1 || i == before2 || i == poi) ? 0.0 : w[i];
        tx += wx[i];
    }
    for (int c = 0; c < MW_CANDIDATES && (best.score <= 0.0 || (c == 0 && best.cost > MW_COST_OK)); ++c) {
        int p = poi, mv = move;
        bool high = false;
        if (c == 1) { mv = MW_ORBIT; high = true; }
        else if (c >= 2) {
            if (tx <= 0.0) break;
            p = mwPickPoi(wx, tx, mwRand(seed, k, 60 + c));
            mv = (c & 1) == 1 ? MW_ORBIT : mwMoveFor(MCW_POI_KIND[p], mwRand(seed, k, 70 + c));
        }
        for (int v = (c == 0 ? 1 : 0); v < 4; ++v) {
            MwShot s = mwPlan(W, mv, p, seed, k, v);
            if (high) { s.orb.w *= 1.8; s.orb.z *= 1.2; }
            s.score = mwJudge(W, s, aspect, co);
            if (s.score <= 0.0) { if (best.score <= 0.0 && s.score < best.score) best.score = s.score; continue; }
            s.cost = mwCost(W, s, aspect, co);
            if (best.score <= 0.0 || s.cost < best.cost) { best = s; kind = MCW_POI_KIND[p]; }
            if (best.cost <= MW_COST_OK) break;
        }
    }
    // Still nothing: every place in turn, from an orbit set high, until one
    // passes. Rare (one shot in 400 on the test worlds before this stage).
    for (int p = 0; p < min(MCW_POI_COUNT, MW_MAX_POI) && best.score <= 0.0; ++p) {
        if (w[p] <= 0.0 || p == before1) continue;
        for (int v = 0; v < 4 && best.score <= 0.0; ++v) {
            MwShot s = mwOrbit(W, p, seed, k, v);
            s.orb.w *= 1.8; s.orb.z *= 1.2;
            s.score = mwJudge(W, s, aspect, co);
            if (s.score > 0.0) { best = s; best.cost = mwCost(W, s, aspect, co); kind = MCW_POI_KIND[p]; }
        }
    }
    float3 ro, tg;
    mwPose(W, best, 0.5, ro, tg);
    float2 tk = mwHours(best, kind, normalize(tg - ro), mwRand(seed, k, 3), mwRand(seed, k, 5), lightMode, aspect,
                        k == 0);
    best.tick0 = tk.x; best.tick1 = tk.y;
    best.moon = 0;
    if (best.move == MW_TRIPOD || best.move == MW_DRIFT) {
        // Where the horizon sits: a little above the middle, for more of the
        // place than of the sky, as far as the subject stays near the middle.
        float3 look = normalize(tg - ro);
        float ps = asin(clamp(look.y, -1.0, 1.0)), m = atan(0.25 / best.lens);
        best.tilt = clamp(-atan(0.2 / best.lens), ps - m, ps + m);
    }
    return best;
}

// ---- Shot timing -----------------------------------------------------------------------
// Shot k runs from mwStart(k) to mwStart(k + 1): the nominal length, give or
// take a fifth.
static inline float mwStart(uint seed, int k, float len) {
    return k == 0 ? 0.0 : (float(k) + (mwRand(seed, k, 7) - 0.5) * 0.4) * len;
}

// ---- Light ----------------------------------------------------------------------------
// What a film crew adds to the game's light: the low sun warm on the faces it
// reaches (the kit's shadow already takes sky light off the rest, which the
// game's lightmap leaves blue), and moonlight silvering what the moon reaches.
static inline float3 mwKey(float3 sun, float key) {
    if (sun.y > -0.05) {
        float low = smoothstep(0.6, 0.1, sun.y) * smoothstep(-0.05, 0.04, sun.y);
        // Warm where the low sun reaches, a little cooler where it does not:
        // the contrast a low sun makes, which the game's flat sky light hides.
        float3 warm = mix(float3(1.05, 1.03, 1.0), float3(1.55, 1.18, 0.82), low);
        float3 cool = mix(float3(1.0), float3(0.80, 0.86, 1.0), low);
        return mix(cool, warm, key);
    }
    float moonUp = saturate(-sun.y * 3.0);
    return 1.0 + key * moonUp * float3(0.45, 0.52, 0.68);
}

// The sky right at the horizon along rd's heading: the fog colour with the
// sunset glow over it, as mcWorldSky draws the horizon. Distance hazes
// toward it, and the sky below the horizon is it, so the ground meets the
// sky without a seam where the render distance ends.
// The game's fan has a hard edge; read flat along the horizon that edge
// would be a vertical seam, so here the glow falls off smoothly with heading.
static inline float3 mwHorizon(float3 rd, float3 sun) {
    float3 flat = normalize(float3(rd.x, 0.0, rd.z) + float3(1e-5, 0.0, 0.0));
    float4 glow = mcSunsetAt(sun.y);
    float2 S = normalize(sun.xz + float2(1e-6, 0.0));
    float fan = glow.a * pow(saturate(dot(flat.xz, S)), 3.0);
    return mix(mcWorldSkyFog(flat, sun), glow.rgb, fan * 0.6);
}

static inline float3 mwSky(McWorld W, float3 rd, float3 sun, int moon) {
    if (rd.y < 0.0) return mwHorizon(rd, sun);
    float3 sky = mcWorldSky(W, rd, sun, moon);
    // Just above the horizon, ease into the game's sky; not round the sun or
    // moon, whose discs would be smeared.
    if (abs(dot(rd, sun)) > 0.93) return sky;
    return mix(mwHorizon(rd, sun), sky, smoothstep(0.0, 0.05, rd.y));
}

// The sky's gradient alone (no sun, moon or stars), for a sheen on ice.
static inline float3 mwSkyGlow(float3 rd, float3 sun) {
    float3 hz = mwHorizon(rd, sun);
    return mix(hz, mcSkyAt(mcSkyDay(sun.y)), 1.0 - exp(-max(rd.y, 0.0) * 6.0));
}

static inline float3 mwColor(McWorld W, McWorldHit h, float3 rd, float3 sun, int moon, float tMax) {
    if (h.t >= tMax) return mwSky(W, rd, sun, moon);
    if (h.color.a < 0.0) return mwHorizon(rd, sun);
    float3 L = sun.y > -0.05 ? sun : -sun;
    bool flat = (h.flags & MCW_HIT_FLAT) != 0u;
    bool far = (h.flags & MCW_HIT_FAR) != 0u;
    float3 sn = flat && dot(h.n, L) < 0.0 ? -h.n : h.n;
    float sh = 1.0;
    // Shadows only where they can show: the sun up, or the moon well up
    // (over about 17 degrees). With the sun on the horizon they change
    // nothing the eye can see, and a ray skimming the ground under a low moon
    // is the dearest there is for a shadow too faint to matter.
    bool shadows = sun.y > 0.01 || sun.y < -0.3;
    if (shadows && h.waterT < 0.0 && (h.flags & (MCW_HIT_FAR | MCW_HIT_EMISSIVE)) == 0u) {
        // The top of a thin model (a snow layer, a carpet, a slab) casts its
        // shadow ray from the top of its cell: mcWorldShadow dims a ray for
        // every model cell it crosses, whatever is in it, so at a low sun a
        // field of snow layers would shade itself in stripes.
        float3 sp = h.p;
        if ((h.flags & MCW_HIT_MODEL) != 0u && sn.y > 0.5) sp.y = floor(h.p.y - 1e-3) + 1.0;
        // Cast shadows to 48 blocks; past that, which faces the sun reaches.
        // (Cost: a shadow ray at a low sun skims the ground; 48 against 64
        // is about 0.3 ms in the village.)
        sh = h.t < 48.0 ? mcWorldShadow(W, sp, sn, L) : (dot(sn, L) > 0.0 ? 1.0 : 0.0);
    }
    float3 col = h.color.rgb * mcWorldLight(W, h, mcLightDay(sun.y), sh);
    float key = (h.waterT < 0.0 && (h.flags & MCW_HIT_EMISSIVE) == 0u)
              ? sh * (0.35 + 0.65 * saturate(dot(sn, L))) * (far ? 0.7 : 1.0) : 0.0;
    return col * mwKey(sun, key);
}

// The game's fog colour, reached over a long ramp instead of the game's last
// tenth: distance reads as air, and the edge of the render distance is not a
// line across the frame.
// And the same air thickens toward the edge of what the save holds (where
// its owner never went), so the world ends in mist rather than at a cliff
// over the void: the director never looks at a near edge, and a far one
// fades. Distance to the edge: the far field's rectangle exactly, and the
// save's missing chunks by the far field's 16 x 16 tiles round the point.
constant float MW_EDGE_MIST = 22.0;
static inline float mwEdge(McWorld W, float2 xz) {
    float2 lo = float2(MCW_FAR_ORIGIN), hi = lo + float2(MCW_FAR_SIZE);
    float d = min(min(xz.x - lo.x, hi.x - xz.x), min(xz.y - lo.y, hi.y - xz.y));
    int2 tile = int2(floor((xz - lo) / 16.0));
    for (int j = -1; j <= 1; ++j)
        for (int i = -1; i <= 1; ++i) {
            int2 t = tile + int2(i, j);
            if (any(t < 0) || any(t >= MCWK_FAR_TILES)) continue;
            if (W.farMax.read(uint2(t)).r != 0) continue;
            float2 a = lo + float2(t) * 16.0;
            float2 q = max(max(a - xz, xz - (a + 16.0)), float2(0.0));
            d = min(d, length(q));
        }
    return d;
}

static inline float3 mwHaze(McWorld W, float3 col, float3 ro, float3 rd, float t, float3 sun, float fogEnd) {
    float f = saturate((t - 0.62 * fogEnd) / (0.38 * fogEnd));
    f = f * f * (3.0 - 2.0 * f);
    // Only far off: the director keeps void out of the nearest 110 blocks.
    if (t > 100.0) {
        float e = (1.0 - saturate(mwEdge(W, (ro + rd * t).xz) / MW_EDGE_MIST)) * smoothstep(100.0, 140.0, t);
        f = max(f, 0.75 * e * e * (3.0 - 2.0 * e));
    }
    if (f <= 0.0) return col;
    return mix(col, mwHorizon(rd, sun), f);
}

// Fresnel weight of a surface's reflection along rd.
static inline float mwFresnel(float3 rd, float3 n) {
    float c = saturate(-dot(rd, n));
    return 0.02 + 0.98 * pow(1.0 - c, 5.0);
}

// ---- Drawing ---------------------------------------------------------------------------

// The frame's camera: where, which way, the lens and the hour. The plan
// works it out once a frame; a pixel keeps only this across its trace.
struct MwCam { float3 ro; float3 fwd; float lens; float ticks; int moon; };

static inline MwCam mwCamera(McWorld W, MwShot s, float f) {
    MwCam c;
    float3 tg;
    mwPose(W, s, f, c.ro, tg);
    c.fwd = normalize(tg - c.ro);
    c.lens = s.lens;
    c.ticks = glmod(mix(s.tick0, s.tick1, f), 24000.0);
    c.moon = s.moon;
    return c;
}

static inline float3 mwRender(McWorld W, MwCam cam, float2 uv, float fog, float mixOther, float3 sunOther) {
    float3 ro = cam.ro, fwd = cam.fwd;
    float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(uv.x * right + uv.y * up + cam.lens * fwd);
    float3 sun = mcWorldSunDir(cam.ticks);
    float fogEnd = mcWorldFogEnd();
    McWorldHit h = mcWorldTrace(W, ro, rd, fogEnd);
    float3 col = mwColor(W, h, rd, sun, cam.moon, fogEnd);
    if (h.waterT >= 0.0) {
        // Water reflects the sky's colours (the game's water reflects nothing).
        float3 refl = mwSkyGlow(reflect(rd, mcWorldWaterN(h)), sun);
        // Water whose bed is past the render distance: deep water, which the
        // horizon's air takes as the surface itself recedes.
        if (h.t >= fogEnd) col = mwHorizon(rd, sun) * mcWorldTint(W, (ro + rd * h.waterT).xz, 2) * 0.35;
        col = mcWorldWater(W, h, ro, rd, col, h.t >= fogEnd ? 16.0 : h.t - h.waterT, mcLightDay(sun.y), refl);
    }
    // (The kit can report a water surface a little past tMax: clamp, so it hazes fully.)
    float tFog = min(h.waterT >= 0.0 ? h.waterT : h.t, fogEnd);
    if (h.t < fogEnd || h.waterT >= 0.0) col = mwHaze(W, col, ro, rd, tFog, sun, fogEnd);
    if (h.layerT >= 0.0) {
        // The translucent layer (ice), lit as the kit lights it, with a sheen
        // of sky on its upper faces, hazed to its own distance.
        float3 P = ro + rd * h.layerT;
        float3 n = mcWorldLayerN(h);
        float3 front = h.layerColor.rgb * mcWorldLightAt(W, P, n, mcLightDay(sun.y), 1.0)
                     * ((h.flags & MCW_HIT_LAYER_SHADE) != 0u ? mcFaceShade(n) : 1.0);
        if (n.y > 0.5) front = mix(front, mwSkyGlow(reflect(rd, n), sun), mwFresnel(rd, n) * 0.55);
        front = mwHaze(W, front, ro, rd, min(h.layerT, fogEnd), sun, fogEnd);
        col = mix(col, front, h.layerColor.a);
    }
    // The game's clouds over open sky (the kit's: its boxes from clouds.png
    // on the shared wind).
    if (h.t >= fogEnd && h.waterT < 0.0 && h.layerT < 0.0 && rd.y > 0.0) {
        float4 cl = mcWorldClouds(W, ro, rd, 1e5, sun, 0.0, 600.0);
        col = mix(col, cl.rgb, cl.a);
    }
    // Exposed for the night: the game's night is dark on a lit monitor in a
    // dark room; a film crew opens up for the lamps and the moon.
    // Opened up for the dim parts only, so a lamp's pool on snow keeps its colour.
    float lum = dot(col, float3(0.3, 0.59, 0.11));
    col *= 1.0 + 0.6 * (1.0 - mcLightDay(sun.y)) * (1.0 - smoothstep(0.25, 0.7, lum));
    if (fog > 0.0) {
        // The fog between shots: the far side and the sky first, the near
        // side last; its colour the horizon's, between the two shots' hours.
        float dn = (h.t >= fogEnd && h.waterT < 0.0) ? 1.0 : saturate(min(h.waterT >= 0.0 ? h.waterT : h.t, fogEnd) / fogEnd);
        float m = saturate(fog * 2.0 - (1.0 - dn));
        m = m * m * (3.0 - 2.0 * m);
        // At full fog one even colour, halfway between the two hours' fogs, so
        // the frame is the same on both sides of the change whichever way
        // each camera faces.
        float3 even = mix(mcFogAt(mcSkyDay(sun.y)), mcFogAt(mcSkyDay(sunOther.y)), mixOther);
        float3 fc = mix(mwHorizon(rd, sun), even, fog);
        col = mix(col, fc, m);
    }
    return col;
}

// ---- The plan of a frame -----------------------------------------------------------
// What the director decides for time `time`: the shot on screen, how far the
// fog between shots has come in, and (only while it has) the sun of the shot
// on the other side of the change, whose horizon the fog's colour blends
// toward so the frame is the same on both sides of the change. Every
// pixel's work is the same, so it is done once a frame by lerpPlan (one SIMD
// group, the checks shared across its lanes) and handed to lerpMain in a
// buffer. The contact sheet, whose cells are different times, runs it in
// every pixel instead.
struct MwFrame {
    MwShot cur;
    float2 span;     // when the shot starts and ends
    float  fog;      // 0 clear .. 1 all fog
    float  mixOther; // how much of the fog's colour is the other shot's horizon
    float3 sunOther; // that shot's sun at the change
};

static inline MwFrame mwPlanFrame(McWorld W, float time, float seedF, float len, int light, float aspect,
                                  MwCoop co) {
    MwFrame F;
    uint seed = mwPcg(uint(seedF * 16777216.0) + 1u);
    float w[MW_MAX_POI];
    float total = mwWeights(W, w);
    int k = int(floor(time / len));
    if (time < mwStart(seed, k, len)) k -= 1;
    else if (time >= mwStart(seed, k + 1, len)) k += 1;
    float b0 = mwStart(seed, k, len), b1 = mwStart(seed, k + 1, len);
    F.cur = mwShot(W, w, total, seed, k, aspect, light, co);
    F.span = float2(b0, b1);
    float fade = float(MW_TRANSITION) * MW_FOG;
    float fOut = fade > 0.0 ? smoothstep(b1 - fade, b1, time) : 0.0;
    float fIn = (fade > 0.0 && k > 0) ? 1.0 - smoothstep(b0, b0 + fade, time) : 0.0;
    F.fog = max(fOut, fIn);
    F.mixOther = 0.5 * F.fog;
    F.sunOther = float3(0.0, 1.0, 0.0);
    if (F.fog > 0.0) {
        // Only the neighbour's hour is wanted, but the hour is the director's
        // choice for its framing, so the neighbour is planned in full.
        int other = fOut >= fIn ? k + 1 : k - 1;
        MwShot o = mwShot(W, w, total, seed, other, aspect, light, co);
        F.sunOther = mcWorldSunDir(glmod(fOut >= fIn ? o.tick0 : o.tick1, 24000.0));
    }
    return F;
}

kernel void lerpPlan(constant LerpUniforms& u [[buffer(0)]], MCW_BINDINGS,
                     device float4* plan [[buffer(13)]], uint lane [[thread_index_in_simdgroup]]) {
    McWorld W = MCW_WORLD;
    MwFrame F = mwPlanFrame(W, u.time, u.seed, clamp(u.shotLength, 20.0, 90.0), u.light,
                            u.resolution.x / u.resolution.y, mwCoop(true));
    if (lane == 0) {
        MwCam c = mwCamera(W, F.cur, saturate((u.time - F.span.x) / (F.span.y - F.span.x)));
        plan[0] = float4(F.fog, F.mixOther, c.ticks, float(c.moon));
        plan[1] = float4(F.sunOther, c.lens);
        plan[2] = float4(c.ro, 0.0);
        plan[3] = float4(c.fwd, 0.0);
    }
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]], MCW_BINDINGS,
                        constant float4* plan [[buffer(13)]]) {
    McWorld W = MCW_WORLD;
    float2 res = u.resolution;
    float4 P = pos;
    float time = u.time;
    bool edge = false;
    MwShot s = mwBlank(0);
    MwCam cam;
    float fog, mixOther;
    float3 sunOther;
    if (MW_SHEET_COLS > 0) {
        float2 cell = res / float2(MW_SHEET_COLS, MW_SHEET_ROWS);
        int2 ci = int2(pos.xy / cell);
        P.xy = pos.xy - float2(ci) * cell;
        res = cell;
        time += float(ci.y * MW_SHEET_COLS + ci.x) * MW_SHEET_STEP;
        if (MW_SHEET_SHOTS) {
            uint sd = mwPcg(uint(u.seed * 16777216.0) + 1u);
            int kk = ci.y * MW_SHEET_COLS + ci.x;
            float ln = clamp(u.shotLength, 20.0, 90.0);
            time = 0.5 * (mwStart(sd, kk, ln) + mwStart(sd, kk + 1, ln)) + u.time;
        }
        edge = any(P.xy < 1.0);
        uint cid = uint(ci.y * MW_SHEET_COLS + ci.x);
        bool oneCell = simd_all(cid == simd_broadcast_first(cid));
        MwFrame F = mwPlanFrame(W, time, u.seed, clamp(u.shotLength, 20.0, 90.0), u.light, res.x / res.y,
                                mwCoop(oneCell));
        s = F.cur; fog = F.fog; mixOther = F.mixOther; sunOther = F.sunOther;
        cam = mwCamera(W, s, saturate((time - F.span.x) / (F.span.y - F.span.x)));
    } else {
        fog = plan[0].x; mixOther = plan[0].y;
        sunOther = plan[1].xyz;
        cam.ticks = plan[0].z; cam.moon = int(plan[0].w); cam.lens = plan[1].w;
        cam.ro = plan[2].xyz; cam.fwd = plan[3].xyz;
    }
    float2 uv = lerpUV(P, res);
    W.pxA = 2.0 / (cam.lens * min(res.x, res.y));
    float3 col = mwRender(W, cam, uv, fog, mixOther, sunOther);
    if (MW_SHEET_COLS > 0) {
        // Development overlay: a frame coloured by why nothing passed; a
        // square per point-of-interest index (+1), coloured by move.
        if (s.score <= 0.0 && (P.x < 6.0 || P.y < 6.0))
            col = s.score < -3.5 ? float3(1, 0, 1) : s.score < -2.5 ? float3(1, 1, 0) : s.score < -1.5 ? float3(1, 1, 1) : float3(1, 0, 0);
        const float3 mc[5] = {float3(1, 1, 0), float3(0, 1, 0), float3(0, 1, 1), float3(1, 0, 1), float3(1, 0.5, 0)};
        if (P.y > 8.0 && P.y < 13.0 && P.x > res.x - 8.0 - s.cost && P.x < res.x - 8.0) col = float3(1.0);
        int2 b = int2((P.xy - 8.0) / 9.0);
        if (b.y == 0 && b.x >= 0 && b.x <= s.poi && fract((P.x - 8.0) / 9.0) < 0.75 && P.y > 8.0 && P.x < res.x - 60.0)
            col = mc[s.move];
    }
    if (edge) col = float3(0.0);
    return half4(half3(lerpDither(col, pos)), 1.0h);
}
