// One World — one Minecraft village that every Mac shows at the same moment.
// Original work for Lerping@Home, on the game's own world generator, blocks,
// light, sky and mobs (PORTING.md "Minecraft looks", "Worlds").
//
// lerp-category: Minecraft
// lerp-requires: minecraft mobs world:shared
// lerp-plan: 160
//
// The world is `shared`: seed "Lerping@Home", generated headless by the
// installed game and baked on this Mac. A frame is a pure function of the
// clock, the seed and the parameters: there is no server, and yet two Macs
// side by side show the same sun, the same villagers in the same places, the
// same weather and the same visitor, each through its own camera.
//
// THE CLOCK. The world's time is the game's dayTime, 20 ticks a second of
// UTC since 2026-01-01T00:00:00Z, as a server started then and never paused:
//   s = unix - 1767225600;  game day N = floor(s / 1200);  tick = (s mod 1200) * 20
//   (0 sunrise, 6000 noon, 12000 sunset, 18000 midnight);  moon phase = N mod 8 (0 full).
// So a game day starts at every :00, :20 and :40 of the UTC hour; noon is 5
// minutes in, sunset 10, midnight 15. Sun, moon, stars, sky, fog and light
// are the game's at that tick (the world kit's).
//
// THE VILLAGE'S DAY, by the game's villager schedule: up at tick 10, to work
// at 2000 (each claimed job site: farmers among their crops, librarians at
// their lecterns...), to the meeting place at 9000, about it from 11000, home
// and to bed at 12000. Villagers without a bed stand the night by the bell. The
// iron golem keeps to the meeting place, the cats walk about it, the animals
// graze where worldgen put them; doors open as villagers pass. Every mob,
// bed, job site, door and claim is read from the bake's tables (world.metal:
// MCW_MOB_*, MCW_BEDS, MCW_JOBS, MCW_STOPS, MCW_DOORS); the shader holds no
// data of its own about this world.
//
// EVENTS, on a public timetable (H is the integer hash below, the same in
// the timetable tool, so anyone can list what is coming):
//   every game day  sunrise, the walk to work, the gathering at the bell
//                   (9000-11000), lamps and torches by night, the moon's phase
//   ~5 a UTC day    rain: in each window of 4 game days c = floor(N / 4),
//                   if H(c, 11) % 1000 < 280, for 12000 + H(c, 12) % 12001
//                   ticks from H(c, 13) % (96000 - length) into the window,
//                   fading in and out at the game's 0.01 a tick
//   ~3.5 a UTC day  the wandering trader: in each window of 9 game days
//                   c = floor(N / 9), if H(c, 31) % 1000 < 450, on day
//                   9c + H(c, 32) % 9: walks in at tick 1000 (over the
//                   fields where a clear walk exists, else along the
//                   village's longest open loop), keeps about the bell,
//                   walks out from 9600. Always comes when the rule fires.
//   ~6 a week       a thunderstorm: the rain is thunder if H(c, 14) % 1000
//                   < 170; a bolt in each 30 s of it if H(slot, 41) % 100 <
//                   55, 60-170 blocks out (no sky flash, as with the game's
//                   "Hide Lightning Flashes")
//   ~monthly        the skeleton trap horse: a storm brings one if
//                   H(c, 21) % 1000 < 40, by a bolt 2000 ticks in; it
//                   stands 18000 ticks (15 minutes), as in the game, on
//                   the best lit open ground 20-70 blocks from the bell
//                   (a village path if there is none), so it always comes
//   a few a year    the charged creeper: a storm that lasts into the night
//                   brings one if H(c, 51) % 1000 < 12; a bolt charges it
//                   400 ticks after it comes; it stays until the storm ends
//                   (at most 8000 ticks)
//
// THE CAMERA. Every Mac cuts at the same instants, every 40 s of the shared
// clock (30 shots a game day), to its own shot of the same moment: the seed
// draws, slot by slot, from shots suited to the hour (the meeting place, a
// street at walking pace, a house from its best side, the village from the
// hill or from high over it, the shore toward a low sun, the lamp-lit corners
// by night, a portrait of a villager, the trader, the horse or the creeper
// when one is about), checks each for its whole 40 seconds (room round the
// camera, a clear view, nothing filling the frame's corners, out of doors,
// and no mob appearing or vanishing in sight), and takes the first that
// passes. After dark and under storms it keeps to what has its own light:
// the lamp-lit square, streets and doorways (each checked for lamplight of
// level 8 or more) and the village's lights from the hill or from above;
// never an unlit landscape. The trap horse and the creeper, when about, are
// filmed close (a portrait, most Macs at once). The night is exposed as a
// film crew would: the dim parts opened up, not the lamps' pools. All of it is
// worked out once a frame in lerpPlan.
//
// Not the game's own: the camera and its sun shadows (the kit's), the
// villagers' paths (the bake's loops through the village, by way of the bell,
// not the game's pathfinding), the trader without his llamas (the mobs kit
// has no llama yet), the creeper's charge as its model scaled rather than
// each box swollen by two pixels, and rain that greys but does not
// wet the ground (as in the game).
//
// Parameters are for previewing: `date` and `utc` pin the clock (days since
// 2026-01-01 and the hour, UTC) so any event can be looked at, and `shot`
// holds one kind of shot.
//
// lerp-param: shot    int   -1 8     = -1   "Hold shot (-1: the director)"
// lerp-param: utc     float -1 24    = -1   "Pin UTC hour (preview)"
// lerp-param: date    float -1 4000  = -1   "Pin UTC day since 2026-01-01 (preview)"


// ==== Shared time ===============================================================
// The world's time is the game's dayTime: 20 ticks a second of UTC since
// 2026-01-01T00:00:00Z. So game day N = floor((unix - 1767225600) / 1200),
// the tick within it ((unix - 1767225600) mod 1200) * 20, the moon's phase N mod 8.

struct OwTime {
    int   day;    // game day since the epoch
    float sec;    // seconds into it, 0..1200
    float tick;   // the game's time of day, 0..24000 (0 sunrise, 6000 noon, 12000 sunset, 18000 midnight)
};

static inline OwTime owTime(McWorld W, float t) {
    float s = W.clock.second + t;
    float k = floor(s / 1200.0);
    OwTime o;
    o.day = W.clock.day * 72 + int(k);
    o.sec = s - k * 1200.0;
    o.tick = o.sec * 20.0;
    return o;
}

// The integer hash every rule below is written with; tools/timetable.py has the
// same one, so the timetable it prints is the one every Mac plays.
static inline uint owHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}
static inline uint owH(int a, uint salt) { return owHash(uint(a) ^ owHash(salt * 0x9e3779b9u + 0x632be5abu)); }
static inline int owFloorDiv(int a, int b) { return (a >= 0 ? a : a - b + 1) / b; }

// ==== Routes ======================================================================
// A place is (route, point index). Every village loop starts at the bell, so a
// walk between loops goes by the bell.

static inline float owRouteLen(int r) { return float(MCW_ROUTES[r].y); }

// Steps and direction (+1 or -1) of the shorter way from a to b around loop r.
static inline float owLoopSteps(int r, float a, float b, thread float& dir) {
    float n = owRouteLen(r);
    float f = glmod(b - a, n);
    if (f <= n - f) { dir = 1.0; return f; }
    dir = -1.0; return n - f;
}

struct OwWalk {
    float3 p;        // feet
    float  heading;  // facing as mcMobRay takes it
    float  moved;    // distance walked since the start of the walk (for the legs)
    bool   moving;
};

// Feet at index s on loop r, facing along direction dir.
static inline OwWalk owAt(int r, float s, float dir) {
    OwWalk w;
    float hd;
    // A step back is taken on the segment it ends on, so the heading is that one's.
    float q = dir < 0.0 ? s - 1e-3 : s;
    w.p = mcWorldRoute(r, q, 1.0, hd);
    w.heading = dir < 0.0 ? hd + M_PI_F : hd;
    w.moved = 0.0; w.moving = false;
    return w;
}

// Walk from place A to place B, d steps along the way (clamped to its length).
static inline OwWalk owWalkTo(int rA, float a, int rB, float b, float d, thread float& total) {
    float dir1, dir2;
    if (rA == rB) {
        float L = owLoopSteps(rA, a, b, dir1);
        total = L;
        float k = clamp(d, 0.0, L);
        OwWalk w = owAt(rA, a + dir1 * k, dir1);
        w.moved = k; w.moving = d > 0.0 && d < L;
        return w;
    }
    float L1 = owLoopSteps(rA, a, 0.0, dir1);
    float L2 = owLoopSteps(rB, 0.0, b, dir2);
    total = L1 + L2;
    float k = clamp(d, 0.0, L1 + L2);
    OwWalk w = k < L1 ? owAt(rA, a + dir1 * k, dir1) : owAt(rB, dir2 * (k - L1), dir2);
    w.moved = k; w.moving = d > 0.0 && d < total;
    return w;
}

// A stroll about place (r, c): every 20 s the villager may step a few points
// one way and come back, standing between. Returns the offset in points at
// time t (seconds) and whether it is walking. `amp` the largest step out.
static inline float owStroll(int key, float t, float amp, float speed, thread bool& moving, thread float& dir) {
    float cyc = 20.0;
    float q = floor(t / cyc);
    float u = t - q * cyc;
    uint h = owH(int(q) * 131 + key, 7u);
    float a = floor(float(h % 1000u) / 1000.0 * (2.0 * amp + 1.0)) - amp;   // -amp..amp
    float go = abs(a) / speed;
    float t0 = 3.0 + float((h >> 10) % 5u);                               // stand, then out
    float t1 = t0 + go, t2 = t1 + 4.0 + float((h >> 14) % 3u), t3 = t2 + go;
    moving = (u > t0 && u < t1) || (u > t2 && u < t3);
    dir = (u < t2 ? 1.0 : -1.0) * (a >= 0.0 ? 1.0 : -1.0);
    if (u < t0) return 0.0;
    if (u < t1) return a * (u - t0) / go;
    if (u < t2) return a;
    if (u < t3) return a * (1.0 - (u - t2) / go);
    return 0.0;
}

// ==== The villagers' day ===========================================================
// The game's default villager schedule (Schedule.VILLAGER_DEFAULT): idle from
// tick 10, work from 2000, meet at the bell from 9000, idle from 11000, rest
// from 12000. Each villager keeps the bed and job site the bake says it
// claimed (MCW_MOB_PLACE), and walks the loops by the stops at them (MCW_STOPS).

constant float OW_WALK  = 1.8;    // blocks a second, going somewhere
constant float OW_AMBLE = 0.8;    // strolling

struct OwMob {
    int    type;
    float3 p;
    float  heading;
    MCMOB_Pose pose;
    MCMOB_Skin skin;
    bool   lying;     // in bed: laid flat, head toward `heading`
    bool   shown;
    float  shadowR;   // the game's shadow radius
};

static inline OwMob owMobNone() {
    OwMob m; m.type = 0; m.p = float3(0.0); m.heading = 0.0; m.pose = mcMobStill(); m.skin = mcMobSkin(0);
    m.lying = false; m.shown = false; m.shadowR = 0.5;
    return m;
}

static inline int owRouteOf(int place) { return place / 1024; }
static inline float owIndexOf(int place) { return float(place % 1024); }

// Where villager k meets: a few points out from the bell along a loop, one each.
static inline int owMeetPlace(int k) {
    // The loops leave the bell along the same few paths, so the places are
    // staggered by distance too: 3, 5, 7, 9 or 11 points out, one way or the other.
    int r = k % MCW_ROUTE_COUNT;
    int i = 3 + 2 * (k % 5);
    return r * 1024 + (((k / 5) & 1) != 0 ? i : int(owRouteLen(r)) - i);
}

// The place (route * 1024 + point) of the first stop at item `item` of a kind
// (1 bed, 2 job site), or -1 if no loop reaches it.
static inline int owStopPlace(int kind, int item) {
    if (item < 0) return -1;
    for (int s = 0; s < MCW_STOP_COUNT; ++s) {
        ushort4 S = MCW_STOPS[s];
        if (int(S.z) == kind && int(S.w) == item) return int(S.x) * 1024 + int(S.y);
    }
    return -1;
}

// A villager's profession: its own, or the one its claimed job site gives.
static inline int owProfessionOf(int i) {
    int p = MCW_MOB_INFO[i].y;
    int j = MCW_MOB_PLACE[i].y;
    return p >= 0 ? p : (j >= 0 ? int(MCW_JOBS[j].w) : -1);
}

// Whether a mob can stand with its feet at p: a solid block under it, room
// for its body, no water.
static inline bool owStandable(McWorld W, float3 p) {
    float water;
    float g = mcWorldGround(W, p.xz, water);
    return water <= g + 0.1 && mcWorldSolid(W, p - float3(0.0, 0.5, 0.0))
        && !mcWorldSolid(W, p + float3(0.0, 0.5, 0.0)) && !mcWorldSolid(W, p + float3(0.0, 1.5, 0.0));
}

// Villager k's own place in the ring round the bell at the gathering (and
// for the night, if it has no bed): the cell centre at the first of eight
// bearings (from its own, spaced by the golden angle) 3 to 4 blocks out
// that it can stand on and reach in a straight walk from its meeting point
// P0 over standable cells. Distinct bearings keep any two from one cell.
// w = 0 if none: it then stands at P0.
static inline float4 owRingSpot(McWorld W, int k, float3 P0, float3 bell) {
    float a0 = float(k) * 2.39996323;
    for (int j = 0; j < 8; ++j) {
        float a = a0 + float(j) * 0.785398;
        float r = 3.0 + float((k + j) % 2);
        float3 S = float3(floor(bell.x + sin(a) * r) + 0.5, floor(P0.y + 0.01), floor(bell.z + cos(a) * r) + 0.5);
        bool ok = false;
        for (int dy = 0; dy < 3 && !ok; ++dy) {
            float3 q = S + float3(0.0, float(dy == 1 ? 1 : dy == 2 ? -1 : 0), 0.0);
            if (owStandable(W, q)) { S = q; ok = true; }
        }
        if (!ok) continue;
        float L = distance(P0.xz, S.xz);
        for (int s = 1; s < 6 && ok; ++s) {
            float3 q = mix(P0, S, float(s) / 6.0);
            float3 c = float3(floor(q.x) + 0.5, floor(q.y + 0.01), floor(q.z) + 0.5);
            if (!owStandable(W, c) && !owStandable(W, c + float3(0.0, 1.0, 0.0)) && !owStandable(W, c - float3(0.0, 1.0, 0.0)))
                ok = false;
        }
        if (ok && L > 0.2) return float4(S, 1.0);
    }
    return float4(P0, 0.0);
}

// Feet on the straight leg from A to B, d blocks along (on the ground, a hop up a step).
static inline float3 owLeg(McWorld W, float3 A, float3 B, float d) {
    float L = max(distance(A.xz, B.xz), 1e-3);
    float f = saturate(d / L);
    float3 p = mix(A, B, f);
    float water;
    float g = mcWorldGround(W, p.xz, water);
    p.y = abs(g - p.y) < 1.2 ? max(p.y, g) : p.y;
    return p;
}

// Steps of the walk between two places, by the bell if they are on different loops.
static inline float owWalkLen(int from, int to) {
    int rA = owRouteOf(from), rB = owRouteOf(to);
    float dA, dB;
    float L1 = owLoopSteps(rA, owIndexOf(from), rA == rB ? owIndexOf(to) : 0.0, dA);
    return L1 + (rA == rB ? 0.0 : owLoopSteps(rB, 0.0, owIndexOf(to), dB));
}

static inline OwMob owVillager(McWorld W, int k, OwTime T, float3 bell) {
    // k: the mob's index in MCW_MOB_*. Written as one path for every villager
    // and every hour (the phase only picks numbers). Each phase starts where
    // the last left the villager (a stroll's offset carried over), so no one
    // ever jumps.
    OwMob m = owMobNone();
    int2 claim = MCW_MOB_PLACE[k];
    int prof = owProfessionOf(k);
    int homePlace = owStopPlace(1, claim.x), jobPlace = owStopPlace(2, claim.y);
    bool homed = homePlace >= 0, employed = jobPlace >= 0;
    int meet = owMeetPlace(k);
    int home = homed ? homePlace : meet;
    int rH = owRouteOf(home);
    float iH = owIndexOf(home);
    float dir0;
    float toBell = owLoopSteps(rH, iH, 0.0, dir0);
    uint jit = owH(T.day * 8 + k, 1u);
    float out = min(toBell, 6.0 + float((jit >> 24) % 9u));
    int morning = rH * 1024 + int(glmod(iH + dir0 * out, owRouteLen(rH)));
    int work = employed ? jobPlace : morning;
    float hd0;
    float3 P0 = mcWorldRoute(owRouteOf(meet), owIndexOf(meet), 1.0, hd0);
    float4 ring = owRingSpot(W, k, P0, bell);
    float Lg = ring.w > 0.5 ? distance(P0.xz, ring.xz) : 0.0;

    float tWake = 10.0 + float(jit % 300u);
    float tWork = 2000.0 + float((jit >> 9) % 400u);
    float tMeet = 9000.0 + float((jit >> 18) % 300u);
    float tIdle = 11000.0;
    float tRest = 12000.0 + float(owH(T.day * 8 + k, 2u) % 500u);
    float tk = T.tick;
    float ampWork = !employed ? 4.0 : (prof == 4 ? 2.0 : 0.0);

    // phase: 0 rest, 1 morning, 2 work, 3 meet, 4 evening
    int ph = (tk < tWake || tk >= tRest) ? 0 : tk < tWork ? 1 : tk < tMeet ? 2 : tk < tIdle ? 3 : 4;
    int from = ph == 0 ? meet : ph == 1 ? home : ph == 2 ? morning : ph == 3 ? work : meet;
    int to   = ph == 0 ? home : ph == 1 ? morning : ph == 2 ? work : meet;
    float t0 = ph == 0 ? tRest : ph == 1 ? tWake : ph == 2 ? tWork : ph == 3 ? tMeet : tIdle;
    float since = glmod(tk - t0, 24000.0) / 20.0;
    float speed = ph == 1 ? OW_AMBLE : OW_WALK;
    float amp = ph == 2 ? ampWork : ph == 4 ? 2.0 : 0.0;
    // where the last phase's stroll left it: work's (ph 3 starts from there),
    // the evening's (rest starts from there)
    float carry = 0.0;
    {
        bool mv0; float sd0;
        if (ph == 3 && ampWork > 0.0) {
            float tEndWork = (tMeet - tWork) / 20.0 - owWalkLen(morning, work) / OW_WALK;
            carry = owStroll(k * 977 + 2, max(tEndWork, 0.0), ampWork, OW_AMBLE, mv0, sd0);
        } else if (ph == 0) {
            float tEndEve = (tRest - tIdle) / 20.0 - Lg / OW_AMBLE;
            carry = owStroll(k * 977 + 4, max(tEndEve, 0.0), 2.0, OW_AMBLE, mv0, sd0);
        }
    }

    // the walk from `from` to `to`, by the bell if they are on different loops
    int rA = owRouteOf(from), rB = owRouteOf(to);
    float a = owIndexOf(from) + carry, b = owIndexOf(to);
    float dirA, dirB;
    float L1 = owLoopSteps(rA, a, rA == rB ? b : 0.0, dirA);
    float L2 = rA == rB ? 0.0 : owLoopSteps(rB, 0.0, b, dirB);
    float total = L1 + L2;
    // the evening starts with the leg back from the ring to the meeting point
    float lead = ph == 4 ? Lg / OW_AMBLE : 0.0;
    float d = max(since - lead, 0.0) * speed;
    bool arrived = d >= total;
    float kk = min(d, total);
    int r = kk < L1 || rA == rB ? rA : rB;
    float sIdx = kk < L1 || rA == rB ? a + dirA * kk : dirB * (kk - L1);
    float sdir = kk < L1 || rA == rB ? dirA : dirB;
    bool moving = !arrived && d > 0.0;
    float moved = kk;
    // once there, a stroll about the place
    bool mv = false; float sd = 1.0;
    float o = owStroll(k * 977 + ph, max(since - lead - total / speed, 0.0), amp, OW_AMBLE, mv, sd);
    if (arrived && amp > 0.0) { sIdx += o; sdir = sd; moving = mv; moved = total + since * OW_AMBLE; }
    OwWalk w = owAt(r, sIdx, sdir);
    float3 feet = w.p;
    float heading = w.heading;

    // the ring: at the gathering (and the homeless at night) the last few
    // steps to its own place round the bell; in the evening the first steps back
    bool toRing = ring.w > 0.5 && (ph == 3 || (ph == 0 && !homed)) && arrived;
    bool fromRing = ring.w > 0.5 && ph == 4 && since < lead;
    if (toRing) {
        float dl = d - total;
        feet = owLeg(W, P0, ring.xyz, dl);
        moving = dl < Lg;
        float2 dd = ring.xz - P0.xz; heading = atan2(dd.x, dd.y);
        moved = total + dl;
    } else if (fromRing) {
        float dl = since * OW_AMBLE;
        feet = owLeg(W, ring.xyz, P0, dl);
        moving = true;
        float2 dd = P0.xz - ring.xz; heading = atan2(dd.x, dd.y);
        moved = dl;
    }

    bool baby = (MCW_MOB_INFO[k].w & 1) != 0;
    m.type = baby ? MCMOB_VILLAGER_BABY : MCMOB_VILLAGER;
    m.shown = true;
    m.shadowR = baby ? 0.25 : 0.5;
    m.p = feet;
    m.heading = heading;
    // Standing, they face the bell at the meeting and their block at work.
    float3 look = ph == 3 || (ph == 0 && !homed) ? bell : MCW_JOBS[max(claim.y, 0)].xyz;
    bool faceIt = !moving && arrived && (ph == 3 || (ph == 0 && !homed) || (ph == 2 && employed && !mv));
    if (faceIt) { float2 dd = look.xz - feet.xz; m.heading = atan2(dd.x, dd.y); }
    m.pose.walk = moved * 4.0;   // the game's walk position runs at four times the distance
    m.pose.speed = moving ? 0.3 : 0.0;
    float key = float(k) * 1.7;
    if (!moving) m.pose.yaw = 0.45 * sin(T.sec * 0.31 + key) * smoothstep(0.2, 0.8, sin(T.sec * 0.07 + key * 3.0));
    if (ph == 0 && homed && arrived) {
        float4 B = MCW_BEDS[max(claim.x, 0)];
        m.lying = true;
        m.heading = B.w;
        m.p = B.xyz;
        m.pose.yaw = 0.0;
    }
    return m;
}

// The iron golem keeps to the meeting place: it walks slowly out and back
// along the loops from the bell, and stands a while between.
static inline OwMob owGolem(OwTime T) {
    OwMob m = owMobNone();
    float t = float(owFloorDiv(T.day, 1) % 64) * 1200.0 + T.sec;
    float cyc = 60.0;
    float q = floor(t / cyc), u = t - q * cyc;
    uint h = owH(int(q) + T.day * 0, 21u);
    int r = int(h % uint(MCW_ROUTE_COUNT));
    float a = 3.0 + float((h >> 8) % 6u);
    float dir = ((h >> 16) & 1u) != 0 ? 1.0 : -1.0;
    float v = 0.55;
    float go = a / v;
    float s;
    bool mv = false;
    float hd = dir;
    if (u < 10.0) s = 0.0;
    else if (u < 10.0 + go) { s = (u - 10.0) * v; mv = true; }
    else if (u < 30.0 + go) s = a;
    else if (u < 30.0 + 2.0 * go) { s = a - (u - 30.0 - go) * v; mv = true; hd = -dir; }
    else s = 0.0;
    OwWalk w = owAt(r, dir * (5.0 + s), hd);
    m.type = MCMOB_IRON_GOLEM; m.shown = true; m.shadowR = 1.0;
    m.p = w.p; m.heading = w.heading;
    m.pose.walk = t * v * 4.0 * (mv ? 1.0 : 0.0);
    m.pose.speed = mv ? 0.25 : 0.0;
    m.skin = mcMobSkin(MCM_IRON_GOLEM);
    return m;
}

// A village cat, about the bell, each on its own loop.
static inline OwMob owCat(OwTime T, int j) {
    OwMob m = owMobNone();
    float t = T.sec + float(T.day % 16) * 1200.0;
    bool mv; float sd;
    float o = owStroll(4242 + j * 31, t, 5.0, 1.2, mv, sd);
    OwWalk w = owAt((j * 3 + 1) % MCW_ROUTE_COUNT, 2.0 + o, sd);
    m.type = MCMOB_CAT; m.shown = true; m.shadowR = 0.4;
    m.p = w.p; m.heading = w.heading;
    m.pose.walk = t * 4.0 * 1.2; m.pose.speed = mv ? 0.35 : 0.0;
    m.pose.wag = 0.5 * sin(t * 1.3);
    return m;
}

// The village's animals (cows, sheep, horses) where worldgen put them, grazing.
static inline OwMob owAnimal(int i, OwTime T) {
    OwMob m = owMobNone();
    float4 P = MCW_MOB_POS[i];
    int kind = MCW_MOB_INFO[i].x;
    int v = MCW_MOB_INFO[i].y;
    bool baby = (MCW_MOB_INFO[i].w & 1) != 0;
    m.type = kind == 4 ? (baby ? MCMOB_SHEEP_BABY : MCMOB_SHEEP) : kind == 7 ? (baby ? MCMOB_HORSE_BABY : MCMOB_HORSE)
           : kind == 5 ? (baby ? MCMOB_PIG_BABY : v == 2 ? MCMOB_PIG_COLD : MCMOB_PIG)
           : kind == 6 ? (baby ? MCMOB_CHICKEN_BABY : v == 2 ? MCMOB_CHICKEN_COLD : MCMOB_CHICKEN)
           : (baby ? MCMOB_COW_BABY : v == 1 ? MCMOB_COW_WARM : v == 2 ? MCMOB_COW_COLD : MCMOB_COW);
    m.shown = true; m.shadowR = kind == 7 ? 0.75 : kind == 6 ? 0.3 : kind == 5 ? 0.5 : 0.7;
    m.p = P.xyz;
    float t = T.sec + float(i) * 37.0;
    m.heading = P.w + 0.6 * sin(t * 0.013 + float(i));
    m.pose.graze = smoothstep(0.2, 0.6, sin(t * 0.09 + float(i) * 2.0));
    m.pose.wag = 0.3 * sin(t * 0.8 + float(i));
    return m;
}

// The rank-th point of interest of a kind, or -1.
static inline int owPoi(int kind, int rank) {
    int seen = 0;
    for (int i = 0; i < MCW_POI_COUNT; ++i) {
        if (MCW_POI_KIND[i] != kind) continue;
        if (seen == rank) return i;
        seen++;
    }
    return -1;
}

// The meeting place: between the village's bells, at the feet of whoever stands there.
static inline float3 owMeet() {
    float3 c = float3(0.0); float n = 0.0;
    for (int i = 0; i < MCW_POI_COUNT; ++i)
        if (MCW_POI_KIND[i] == MCW_POI_BELL) { c += MCW_POI[i].xyz; n += 1.0; }
    return n > 0.0 ? c / n - float3(0.0, 2.0, 0.0) : MCW_CENTER;
}

// ==== Weather =======================================================================
// The game's own weather, on a public timetable. Time is cut into windows of
// four game days (80 minutes); in window c = floor(N / 4) it rains if
// H(c, 11) % 1000 < 280, for D = 12000 + H(c, 12) % 12001 ticks (the game's
// 0.5 to 1 day), starting S = H(c, 13) % (96000 - D) ticks into the window. The
// rain is a thunderstorm if H(c, 14) % 1000 < 170. Rain and thunder come and go
// at the game's 0.01 a tick (five seconds). About five showers a UTC day and
// a thunderstorm most days.

struct OwSpell { float start; float len; bool rains; bool thunder; };   // ticks from the window's start

static inline OwSpell owSpell(int c) {
    OwSpell w;
    w.rains = owH(c, 11u) % 1000u < 280u;
    w.len = 12000.0 + float(owH(c, 12u) % 12001u);
    w.start = float(owH(c, 13u) % uint(96000.0 - w.len));
    w.thunder = w.rains && owH(c, 14u) % 1000u < 170u;
    return w;
}

// (rain, thunder) levels, 0..1, at game day N, tick T.
static inline float2 owWeather(int N, float tick) {
    int c = owFloorDiv(N, 4);
    OwSpell w = owSpell(c);
    if (!w.rains) return float2(0.0);
    float tw = float(N - c * 4) * 24000.0 + tick;
    float r = saturate((tw - w.start) / 100.0) * saturate((w.start + w.len - tw) / 100.0);
    return float2(r, w.thunder ? r : 0.0);
}

// ---- Rain: the game's (WeatherEffectRenderer): about the camera, a quad
// through the middle of each column, turned to face the camera, from the
// ground (or a roof) up, textured with environment/rain.png falling at the
// game's speed, fading out to the edge of the radius. The radius is the
// game's "Fast" graphics' 5 (Fancy's 10 costs 5 ms a frame here); the light is
// the camera's, not each column's.
static inline float4 owRain(McWorld W, float3 ro, float3 rd, float tMax, float rain, float day, float ticks) {
    if (rain <= 0.0) return float4(0.0);
    const float R = 5.0;
    float3 lit = mcWorldLightAt(W, ro, float3(0.0), day, 1.0);
    float2 o = ro.xz, d = normalize(rd.xz + float2(1e-6, 0.0));
    int2 cell = int2(floor(o));
    float2 inv = 1.0 / select(d, float2(1e-6), abs(d) < 1e-6);
    float2 stp = sign(d);
    float2 tNext = (select(floor(o), floor(o) + 1.0, d > 0.0) - o) * inv;
    float3 acc = float3(0.0); float aAcc = 0.0;
    for (int i = 0; i < 8; ++i) {
        float2 cc = float2(cell) + 0.5;
        float2 v = cc - o;
        float dist = length(v);
        if (dist < R) {
            float2 nrm = v / max(dist, 1e-3);
            float den = dot(rd.xz, nrm);
            if (den > 1e-4) {
                float t = dist / den;            // the facing quad through the column's middle
                if (t >= tMax + 1.5) break;      // past what the ray hits: no column further on shows
                if (t < tMax) {
                    float3 P = ro + rd * t;
                    float lat = dot(P.xz - cc, float2(-nrm.y, nrm.x));
                    float water;
                    bool on = abs(lat) < 0.5 && P.y < ro.y + R && P.y > ro.y - R;
                    if (on) on = P.y > max(mcWorldGround(W, cc, water), water);
                    if (on) {
                        uint hc = uint(cell.x * cell.x * 3121 + cell.x * 45238971 + cell.y * cell.y * 418711 + cell.y * 13761) & 31u;
                        float sp = 3.0 + float(owHash(uint(cell.x * 73856093) ^ uint(cell.y * 19349663)) % 1000u) / 1000.0;
                        float vOff = -(ticks + float(hc)) / 32.0 * sp;
                        float2 px = float2((lat + 0.5) * 64.0, fract(P.y * 0.25 + vOff) * 256.0);
                        float4 tex = mcMap(W.maps, MCM_ENVIRONMENT_RAIN, px, t * W.pxA * 64.0);
                        float fade = (1.0 - dist * dist / (R * R)) * 0.5 + 0.5;
                        float a = tex.a * fade * rain;
                        acc += (1.0 - aAcc) * a * tex.rgb * lit;
                        aAcc += (1.0 - aAcc) * a;
                    }
                }
            }
        } else if (dist > R + 1.5) break;
        if (tNext.x < tNext.y) { tNext.x += abs(inv.x); cell.x += int(stp.x); }
        else                   { tNext.y += abs(inv.y); cell.y += int(stp.y); }
    }
    return float4(acc, aAcc);
}

// ==== Visitors =====================================================================
// The wandering trader. Time is cut into windows of nine game days (three
// hours); in window c = floor(N / 9) the trader comes if H(c, 31) % 1000 < 450,
// on day c * 9 + H(c, 32) % 9. He walks in over the fields at tick 1000 (in the
// game he appears near a player and makes for the meeting place), keeps about
// the bell through the working day, and walks out again from tick 9600, gone
// before sunset. About three and a half visits a UTC day. The way in is a
// straight walk over open ground the look checks: no step over a block, no
// water, nothing at head height; a day with no such way has no visit.

constant float OW_TRADER_IN  = 1000.0;
constant float OW_TRADER_OUT = 9600.0;
constant float OW_TRADER_WALK = 1.1;
constant float OW_TRADER_WAY = 36.0;   // blocks of field he crosses

static inline bool owTraderDay(int N) {
    int c = owFloorDiv(N, 9);
    return owH(c, 31u) % 1000u < 450u && N == c * 9 + int(owH(c, 32u) % 9u);
}

// Can a mob walk straight from `a` along `dir` for `len` blocks: ground that
// never steps more than one block, no water, nothing in the way at head height.
static inline bool owClearWalk(McWorld W, float2 a, float2 dir, float len) {
    float water;
    float prev = mcWorldGround(W, a, water);
    for (int k = 1; k <= 40; ++k) {
        if (float(k) > len) break;
        float2 q = a + dir * float(k);
        float g = mcWorldGround(W, q, water);
        if (water > g + 0.1 || abs(g - prev) > 1.01) return false;
        if (mcWorldSolid(W, float3(q.x, g + 1.5, q.y))) return false;
        prev = g;
    }
    return true;
}

// The trader's way in for day N: from the field end A to E beside the meeting
// place; w = 1 if there is one.
// Whether loop r is out of doors (open sky over head height) from the bell to point k.
static inline bool owOutdoors(McWorld W, int r, int k) {
    for (int i = 0; i <= k; ++i) {
        float3 p = float3(MCW_ROUTE_POINTS[MCW_ROUTES[r].x + i].xyz) + float3(0.5, 1.5, 0.5);
        if (mcwLightAt(W, p).a < 0.99) return false;
    }
    return true;
}

// His way in: out along a loop from the bell to point k (open sky all the
// way), then the first of eight bearings with a clear walk over the fields.
// If no field walk is clear he comes in along the loop alone, from the
// furthest point out of doors any loop reaches (the director keeps the
// moment he appears there out of sight), so a visit on the timetable always
// happens. w packs the loop + 1, k * 64 and 4096 if he crosses a field.
__attribute__((noinline)) static float4 owTraderWay(McWorld W, int N, thread float3& E) {
    float a0 = float(owH(N, 33u) % 360u) * (M_PI_F / 180.0);
    int rBest = 0, kBest = 3;
    for (int kk = 0; kk < 5; ++kk) {
        int k = 6 + 6 * kk;
        for (int r = 0; r < MCW_ROUTE_COUNT; ++r) {
            // six points beyond k out of doors too: the llamas string out there when he comes by the loop
            if (k + 6 >= int(MCW_ROUTES[r].y) || !owOutdoors(W, r, k + 6)) continue;
            if (k > kBest) { kBest = k; rBest = r; }
            float hd;
            E = mcWorldRoute(r, float(k), 1.0, hd);
            for (int j = 0; j < 8; ++j) {
                float a = a0 + float(j) * (M_PI_F / 4.0);
                float2 dir = float2(sin(a), cos(a));
                if (owClearWalk(W, E.xz, dir, OW_TRADER_WAY + 7.0)) {   // and 7 blocks past his start for the llamas
                    float2 A = E.xz + dir * OW_TRADER_WAY;
                    float water;
                    return float4(A.x, mcWorldGround(W, A, water), A.y, float(r + 1) + 64.0 * float(k) + 4096.0);
                }
            }
        }
    }
    float hd;
    E = mcWorldRoute(rBest, float(kBest), 1.0, hd);
    return float4(E, float(rBest + 1) + 64.0 * float(kBest));
}

// Feet on a straight field walk from a to b, d blocks along: on the ground, a hop up a step.
static inline float3 owFieldAt(McWorld W, float2 a, float2 b, float d) {
    float2 dir = normalize(b - a);
    float2 q = a + dir * d;
    float water;
    float g0 = mcWorldGround(W, q, water);
    float g1 = mcWorldGround(W, q + dir * 0.5, water);
    float y = g1 > g0 ? g0 + (g1 - g0) * smoothstep(0.0, 0.5, fract(dot(q, abs(dir))) - 0.5) : g0;
    return float3(q.x, max(y, g0), q.y);
}

__attribute__((noinline)) static OwMob owTrader(McWorld W, OwTime T, float3 bell, thread float4& way) {
    OwMob m = owMobNone();
    way = float4(0.0);
    // the way is worked out a shot early, so the director can keep his arrival out of sight
    if (!owTraderDay(T.day) || T.tick < OW_TRADER_IN - 800.0) return m;
    float3 E;
    way = owTraderWay(W, T.day, E);
    if (way.w < 0.5 || T.tick < OW_TRADER_IN) return m;   // w: the loop he comes in by, + 1
    int wr = int(way.w) % 64 - 1;                                      // the loop he comes in by
    float wk = float((int(way.w) / 64) % 64);                          // and its point E where he leaves the field
    float field = int(way.w) >= 4096 ? OW_TRADER_WAY : 0.0;            // blocks of field, or none
    float tWalk = field / OW_TRADER_WALK * 20.0;                       // ticks across the field
    float tLoop = wk / OW_TRADER_WALK * 20.0;                          // along the loop from E toward the bell
    float tk = T.tick;
    float tEnd = OW_TRADER_OUT + tLoop + tWalk;
    if (tk >= tEnd) return m;
    m.type = MCMOB_VILLAGER; m.shown = true; m.shadowR = 0.5;
    float moved;
    bool moving = true;
    if (tk < OW_TRADER_IN + tWalk) {
        moved = (tk - OW_TRADER_IN) / 20.0 * OW_TRADER_WALK;
        m.p = owFieldAt(W, way.xz, E.xz, moved);
        float2 d = E.xz - way.xz; m.heading = atan2(d.x, d.y);
    } else if (tk >= OW_TRADER_OUT + tLoop) {
        moved = (tk - OW_TRADER_OUT - tLoop) / 20.0 * OW_TRADER_WALK;
        m.p = owFieldAt(W, E.xz, way.xz, moved);
        float2 d = way.xz - E.xz; m.heading = atan2(d.x, d.y);
    } else {
        // about the bell: along loop 1 between E (point 6) and the bell, and strolling
        float since = (tk - OW_TRADER_IN - tWalk) / 20.0;
        float back = (tk - OW_TRADER_OUT) / 20.0;
        float s;
        float dir = -1.0;
        bool mv;
        // in from E (point 6) to point 3, a stroll about it, and back out from wherever the stroll left him
        float sd;
        float leaveAt = (OW_TRADER_OUT - OW_TRADER_IN - tWalk) / 20.0;
        float s0 = 3.0 + owStroll(777, leaveAt, 2.0, OW_AMBLE, mv, sd);
        if (tk < OW_TRADER_IN + tWalk + tLoop) { s = max(wk - since * OW_TRADER_WALK, 3.0); moving = s > 3.0; }
        else if (tk >= OW_TRADER_OUT) { s = min(s0 + back * OW_TRADER_WALK, wk); dir = 1.0; moving = s < wk; }
        else { s = 3.0 + owStroll(777, since, 2.0, OW_AMBLE, mv, sd); dir = sd; moving = mv; }
        OwWalk w = owAt(wr, s, dir);
        m.p = w.p; m.heading = w.heading;
        moved = since * OW_TRADER_WALK;
    }
    m.pose.walk = moved * 4.0;
    m.pose.speed = moving ? 0.3 : 0.0;
    return m;
}

// The trader's two llamas, on leads, as the game sends them with him. They
// trail him along his own way, llama i at where he was 2.5 (i + 1) seconds
// before; while he keeps about the bell they stand where the walk in left
// them, facing him, and on the way out each falls in behind him once he
// has passed it. Coats as the game picks a trader llama's: one of four, per
// visit.
constant float OW_LLAMA_LAG = 3.0;   // seconds of his walk between him and the first llama

static inline OwMob owLlama(McWorld W, OwTime T, float3 bell, int i, thread float4& extra) {
    OwMob m = owMobNone();
    extra = float4(0.0);
    float4 way;
    OwMob tr = owTrader(W, T, bell, way);
    if (!tr.shown) return m;
    int wr = int(way.w) % 64 - 1;
    float wk = float((int(way.w) / 64) % 64);
    float field = int(way.w) >= 4096 ? OW_TRADER_WAY : 0.0;
    float tWalk = field / OW_TRADER_WALK * 20.0, tLoop = wk / OW_TRADER_WALK * 20.0;
    float lag = OW_LLAMA_LAG * float(i + 1) * 20.0;                  // ticks
    float q = 3.0 + OW_LLAMA_LAG * float(i + 1) * OW_TRADER_WALK;   // its loop point while he waits
    float tk = T.tick;
    float tSample = -1.0;
    if (tk < OW_TRADER_IN + tWalk + tLoop && tk - lag < OW_TRADER_IN) {
        // Not yet where he was when he came: strung out behind his start, on
        // the field line past it (or the loop past E), walking once he walks.
        float behind = (OW_TRADER_IN - (tk - lag)) / 20.0 * OW_TRADER_WALK;
        float3 E;
        float4 w3 = owTraderWay(W, T.day, E);
        if (field > 0.0) {
            m.p = owFieldAt(W, E.xz, w3.xz, OW_TRADER_WAY + behind);
            float2 d = E.xz - w3.xz; m.heading = atan2(d.x, d.y);
        } else {
            OwWalk w = owAt(wr, wk + behind, -1.0);
            m.p = w.p; m.heading = w.heading;
        }
        m.pose.walk = (tk - OW_TRADER_IN) / 20.0 * OW_TRADER_WALK * 4.0;
        m.pose.speed = tk > OW_TRADER_IN ? 0.35 : 0.0;
        m.type = MCMOB_TRADER_LLAMA; m.shown = true; m.shadowR = 0.7;
        m.pose.flap = float(owH(owFloorDiv(T.day, 9), 61u + uint(i)) % 4u);
        return m;
    }
    if (tk < OW_TRADER_IN + tWalk + tLoop) tSample = tk - lag;
    else if (tk >= OW_TRADER_OUT) {
        bool mv; float sd;
        float leaveAt = (OW_TRADER_OUT - OW_TRADER_IN - tWalk) / 20.0;
        float s0 = 3.0 + owStroll(777, leaveAt, 2.0, OW_AMBLE, mv, sd);
        float tPass = OW_TRADER_OUT + max(q - s0, 0.0) / OW_TRADER_WALK * 20.0;
        tSample = max(tk - lag, tPass);
    }
    if (tSample >= 0.0) {
        OwTime Ts = T; Ts.tick = tSample; Ts.sec = tSample / 20.0;
        float4 w2;
        OwMob at = owTrader(W, Ts, bell, w2);
        m.p = at.p; m.heading = at.heading;
        m.pose.walk = at.pose.walk; m.pose.speed = at.pose.speed > 0.0 && tSample == tk - lag ? 0.35 : 0.0;
    } else {
        OwWalk w = owAt(wr, q, 1.0);
        m.p = w.p;
        float2 d = tr.p.xz - w.p.xz; m.heading = atan2(d.x, d.y);
        m.pose.yaw = 0.3 * sin(T.sec * 0.17 + float(i) * 2.0);
    }
    m.type = MCMOB_TRADER_LLAMA; m.shown = true; m.shadowR = 0.7;
    m.pose.flap = float(owH(owFloorDiv(T.day, 9), 61u + uint(i)) % 4u);   // carried as the coat
    return m;
}

// ==== Thunder =======================================================================
// In a thunderstorm the game strikes lightning. Here a bolt falls in each
// 30-second slot of a storm if H(slot, 41) % 100 < 55, at a moment and a
// spot 60 to 170 blocks from the village from H(slot, 42..44). The game's bolt
// (LightningBoltRenderer): eight segments of 16 blocks wandering up to 5
// blocks a segment, drawn bright and additive, on for two ticks one to three
// times. Its sky flash is left out, as the game's "Hide Lightning Flashes"
// option leaves it out.
//
// The skeleton trap horse: when a bolt strikes in the game, by chance it
// leaves a skeleton horse, which stands where it fell until 18000 ticks (15
// minutes) pass. Here a storm in window c brings one if H(c, 21) % 1000 < 40
// (about one storm in 25, so once in some weeks): a bolt 2000 ticks into the
// storm, on open ground 30 to 55 blocks from the bell.

struct OwBolt { bool on; float3 at; uint seed; };

// Open, level ground r0..r1 blocks from the meeting place for a mob to stand
// on: of 24 places drawn from h, the best lit one that is level over 3 x 3,
// dry, and clear to head height (lamplight makes a night event visible). If
// none is, the first loop point out of doors 10 or more points from the
// bell, which every village has: the event always happens.
__attribute__((noinline)) static float3 owSpotNear(McWorld W, float3 meet, uint h, float r0, float r1) {
    float3 best = float3(0.0);
    float bestLit = -1.0;
    for (int j = 0; j < 24; ++j) {
        uint g = owHash(h + uint(j) * 7919u);
        float a = float(g % 3600u) * (M_PI_F / 1800.0);
        float r = r0 + (r1 - r0) * float((g >> 12) % 1000u) / 1000.0;
        float2 q = meet.xz + float2(sin(a), cos(a)) * r;
        float water;
        float y = mcWorldGround(W, q, water);
        bool flat = water <= y + 0.1;
        for (int k = 0; k < 4 && flat; ++k) {
            float2 o = float2(k == 0 ? 1.5 : k == 1 ? -1.5 : 0.0, k == 2 ? 1.5 : k == 3 ? -1.5 : 0.0);
            float w2; float y2 = mcWorldGround(W, q + o, w2);
            if (abs(y2 - y) > 0.5 || w2 > y2 + 0.1) flat = false;
        }
        if (!flat || mcWorldSolid(W, float3(q.x, y + 1.5, q.y)) || mcWorldSolid(W, float3(q.x, y + 2.5, q.y))) continue;
        float4 L = mcwLightAt(W, float3(q.x, y + 1.0, q.y));
        float lit = max(L.r, max(L.g, L.b)) + float(j) * 1e-4;
        if (lit > bestLit) { bestLit = lit; best = float3(q.x, y, q.y); }
    }
    if (bestLit >= 0.0) return best;
    for (int i = 10; i < 60; ++i) {
        float hd;
        float3 p = mcWorldRoute(0, float(i), 1.0, hd);
        if (mcwLightAt(W, p + float3(0.0, 1.5, 0.0)).a > 0.99) return p;
    }
    float hd;
    return mcWorldRoute(0, 10.0, 1.0, hd);
}

// The trap horse of the storm at day N: spot (w = 1 if there is one) and the
// ticks since day N's start at which it fell (x) and goes (y).
static inline float4 owHorse(McWorld W, int N, float3 meet, thread float2& when) {
    when = float2(-1.0);
    for (int back = 0; back < 2; ++back) {
        int c = owFloorDiv(N, 4) - back;
        OwSpell w = owSpell(c);
        if (!w.thunder || owH(c, 21u) % 1000u >= 40u) continue;
        float tS = float(c * 4 - N) * 24000.0 + w.start + 2000.0;   // ticks from day N's start
        float3 p = owSpotNear(W, meet, owH(c, 22u), 20.0, 70.0);
        when = float2(tS, tS + 18000.0);
        return float4(p, 1.0);
    }
    return float4(0.0);
}

static inline OwMob owHorseMob(McWorld W, OwTime T, float3 meet, thread float4& spot) {
    OwMob m = owMobNone();
    float2 when;
    float4 hs = owHorse(W, T.day, meet, when);
    spot = hs.w > 0.5 ? float4(hs.x, hs.z, when) : float4(0.0, 0.0, -1.0, -1.0);
    if (hs.w < 0.5 || T.tick < when.x || T.tick >= when.y) return m;
    m.type = MCMOB_HORSE; m.shown = true; m.shadowR = 0.75;
    m.p = hs.xyz;
    m.heading = float(owH(int(hs.x * 7.0), 23u) % 628u) / 100.0 + 0.3 * sin(T.sec * 0.02);
    m.pose.graze = smoothstep(0.3, 0.7, sin(T.sec * 0.05 + 1.0));
    m.pose.wag = 0.4 * sin(T.sec * 0.9);
    return m;
}

// The charged creeper, the truly rare one. In the game a bolt that falls
// within four blocks of a creeper charges it, and it goes about wrapped in
// the crackling blue of creeper_armor.png. Here a thunderstorm in window c
// that lasts into the night brings one if H(c, 51) % 1000 < 12 (about one
// storm in 80, a few times a year): the creeper is out on open ground 25 to
// 45 blocks from the bell from the first night tick of the storm (13000 to
// 22000, at least 1000 ticks into it), a bolt strikes it 400 ticks later, and
// it keeps to its spot until the storm ends or 8000 ticks pass.

static inline float4 owCreeper(McWorld W, int N, float3 meet, thread float2& when) {
    when = float2(-1.0);
    for (int back = 0; back < 2; ++back) {
        int c = owFloorDiv(N, 4) - back;
        OwSpell w = owSpell(c);
        if (!w.thunder || owH(c, 51u) % 1000u >= 12u) continue;
        float t0 = w.start + 1000.0, t1 = w.start + w.len - 2000.0;   // ticks from the window's start
        float tC = -1.0;
        for (int d = 0; d < 6; ++d) {   // the first night in the storm
            float dayStart = float(d) * 24000.0;
            float a = max(t0, dayStart + 13000.0), b = min(t1, dayStart + 22000.0);
            if (a < b) { tC = a; break; }
        }
        if (tC < 0.0) continue;
        float3 p = owSpotNear(W, meet, owH(c, 52u), 15.0, 60.0);
        float off = float(c * 4 - N) * 24000.0;   // window start, in ticks from day N's start
        when = float2(off + tC, off + min(tC + 8000.0, w.start + w.len));
        return float4(p, 1.0);
    }
    return float4(0.0);
}

static inline OwMob owCreeperMob(McWorld W, OwTime T, float3 meet, thread float4& spot) {
    OwMob m = owMobNone();
    float2 when;
    float4 cs = owCreeper(W, T.day, meet, when);
    spot = cs.w > 0.5 ? float4(cs.x, cs.z, when) : float4(0.0, 0.0, -1.0, -1.0);
    if (cs.w < 0.5 || T.tick < when.x || T.tick >= when.y) return m;
    m.type = MCMOB_CREEPER; m.shown = true; m.shadowR = 0.5;
    m.p = cs.xyz;
    m.heading = float(owH(int(cs.x * 5.0), 53u) % 628u) / 100.0 + 0.5 * sin(T.sec * 0.013);
    m.pose.yaw = 0.5 * sin(T.sec * 0.21);
    m.lying = false;
    m.pose.flap = T.tick >= when.x + 400.0 ? 1.0 : 0.0;   // carried as "charged"
    return m;
}

// The bolt in the current 30-second slot, if one is falling now.
static inline OwBolt owBoltNow(McWorld W, OwTime T, float thunder, float3 meet) {
    OwBolt b; b.on = false; b.at = meet; b.seed = 0u;
    // the horse's bolt first
    float2 when;
    float4 hs = owHorse(W, T.day, meet, when);
    float since = T.tick - when.x;
    if (hs.w > 0.5 && since >= 0.0 && since < 12.0) {
        b.on = since < 2.0 || (since >= 5.0 && since < 7.0) || (since >= 10.0);
        b.at = hs.xyz; b.seed = owH(int(when.x), 45u);
        return b;
    }
    float4 cs = owCreeper(W, T.day, meet, when);
    since = T.tick - when.x - 400.0;
    if (cs.w > 0.5 && since >= 0.0 && since < 12.0) {
        b.on = since < 2.0 || (since >= 5.0 && since < 7.0) || (since >= 10.0);
        b.at = cs.xyz + float3(1.5, 0.0, 0.5); b.seed = owH(int(when.x), 54u);
        return b;
    }
    if (thunder < 0.5) return b;
    int slot = T.day * 40 + int(floor(T.sec / 30.0));
    if (owH(slot, 41u) % 100u >= 55u) return b;
    float t0 = float(owH(slot, 42u) % 560u);                    // ticks into the slot
    float dt = fmod(T.sec, 30.0) * 20.0 - t0;
    uint fl = 1u + owH(slot, 43u) % 3u;
    b.on = dt >= 0.0 && ((dt < 2.0) || (fl > 1u && dt >= 5.0 && dt < 7.0) || (fl > 2u && dt >= 10.0 && dt < 12.0));
    if (!b.on) return b;
    uint g = owH(slot, 44u);
    float a = float(g % 3600u) * (M_PI_F / 1800.0);
    float r = 60.0 + 110.0 * float((g >> 12) % 1000u) / 1000.0;
    float2 q = meet.xz + float2(sin(a), cos(a)) * r;
    float water;
    b.at = float3(q.x, max(mcWorldGround(W, q, water), water), q.y);
    b.seed = g;
    return b;
}

// The bolt's light along a ray, up to distance tMax: its eight wandering
// segments as thin glowing lines.
static inline float3 owBoltLight(OwBolt b, float3 ro, float3 rd, float tMax, float pxA) {
    if (!b.on) return float3(0.0);
    float3 acc = float3(0.0);
    float2 off = float2(0.0);
    float3 prev = b.at;
    for (int j = 0; j < 8; ++j) {
        uint g = owHash(b.seed + uint(j) * 2654435761u);
        if (j > 0) off += float2(float(g % 11u) - 5.0, float((g >> 8) % 11u) - 5.0);
        float3 p0 = j == 0 ? b.at : prev;
        float3 p1 = b.at + float3(off.x, 16.0 * float(j + 1), off.y);
        prev = p1;
        // closest approach of the ray to segment p0..p1
        float3 u = p1 - p0, w0 = ro - p0;
        float A = dot(u, u), B = dot(u, rd), C = dot(w0, u), D = dot(w0, rd);
        float den = A - B * B;
        float sc = den > 1e-6 ? saturate((C - B * D) / den) : 0.0;
        float tc = max(B * sc - D, 0.0);
        if (tc > tMax) continue;
        float3 q = p0 + u * sc - (ro + rd * tc);
        float d = length(q);
        float wpx = max(0.25, tc * pxA * 1.2);
        acc += float3(0.45, 0.45, 0.5) * 2.2 * saturate(1.0 - d / wpx);
    }
    return acc;
}

// The cast: the save's own mobs (MCW_MOB_*), in its order, then the visitors.
constant int OW_TRADER = MCW_MOB_COUNT;
constant int OW_TRAP   = OW_TRADER + 1;
constant int OW_CREEPER = OW_TRAP + 1;
constant int OW_LLAMA0 = OW_CREEPER + 1;   // the trader's two llamas
constant int OW_MOBS   = OW_LLAMA0 + 2;   // at most 32: one lane of the plan's SIMD group each
static_assert(MCW_MOB_COUNT + 5 <= 32, "one-world: more mobs than a SIMD group has lanes");
static_assert(MCW_DOOR_COUNT <= 32, "one-world: more doors than a SIMD group has lanes");

__attribute__((noinline)) static OwMob owMob(McWorld W, int i, OwTime T, float3 bell, thread float4& extra) {
    extra = float4(0.0);
    if (i == OW_TRADER) return owTrader(W, T, bell, extra);
    if (i == OW_TRAP) return owHorseMob(W, T, owMeet(), extra);
    if (i == OW_CREEPER) return owCreeperMob(W, T, owMeet(), extra);
    if (i >= OW_LLAMA0) return owLlama(W, T, bell, i - OW_LLAMA0, extra);
    int kind = MCW_MOB_INFO[i].x;
    if (kind == 0) return owVillager(W, i, T, bell);
    if (kind == 1) return owGolem(T);
    if (kind == 2) return owCat(T, i);
    if (kind >= 3 && kind <= 7) return owAnimal(i, T);
    return owMobNone();   // kinds the mob kit cannot draw yet (8 trader, 9 trader llama, 10 llama, ...): none in shared
}

// A mob's state packed in three float4s, so one lane of a SIMD group can work
// it out and the other 31 read it (every pixel needs every mob, and they are
// the same for all of them).
struct OwPacked {
    float4 a;   // feet, cos(heading)
    float4 b;   // sin(heading), walk, speed, head yaw
    float4 c;   // graze, wag, type + 64 * (shown + 2 * lying), shadow radius
    float4 d;   // the trader's field end, the trap horse's spot (w > 0 when there is one)
};

static inline OwPacked owPack(McWorld W, int i, OwTime T, float3 bell) {
    OwPacked q;
    OwMob m = owMob(W, i, T, bell, q.d);
    q.a = float4(m.p, cos(m.heading));
    q.b = float4(sin(m.heading), m.pose.walk, m.pose.speed, m.pose.yaw);
    int charged = m.type == MCMOB_CREEPER && m.pose.flap > 0.5 ? 4 : 0;   // the creeper's charge
    int coat = m.type == MCMOB_TRADER_LLAMA ? int(m.pose.flap) : 0;     // a llama's coat
    q.c = float4(m.pose.graze, m.pose.wag, float(m.type + 64 * ((m.shown ? 1 : 0) + (m.lying ? 2 : 0) + charged) + 512 * coat), m.shadowR);
    return q;
}

// Rough size of each kind, for the cheap sphere test before the box test.
static inline float owRadius(int type) {
    return type == MCMOB_TRADER_LLAMA ? 1.5 : type == MCMOB_CREEPER ? 1.2 : type == MCMOB_IRON_GOLEM ? 1.7 : type == MCMOB_CAT ? 0.6 : type == MCMOB_COW || type == MCMOB_SHEEP ? 1.2 : type == MCMOB_HORSE ? 1.7 : type == MCMOB_VILLAGER_BABY ? 0.7 : 1.1;
}

// The skin of mob i (it never changes, so it is not packed).
static inline int owProfession(int prof) {
    switch (prof) {
        case 0:  return MCS_VILLAGER_PROFESSION_ARMORER;
        case 1:  return MCS_VILLAGER_PROFESSION_BUTCHER;
        case 2:  return MCS_VILLAGER_PROFESSION_CARTOGRAPHER;
        case 3:  return MCS_VILLAGER_PROFESSION_CLERIC;
        case 4:  return MCS_VILLAGER_PROFESSION_FARMER;
        case 5:  return MCS_VILLAGER_PROFESSION_FISHERMAN;
        case 6:  return MCS_VILLAGER_PROFESSION_FLETCHER;
        case 7:  return MCS_VILLAGER_PROFESSION_LEATHERWORKER;
        case 8:  return MCS_VILLAGER_PROFESSION_LIBRARIAN;
        case 9:  return MCS_VILLAGER_PROFESSION_MASON;
        case 10: return MCS_VILLAGER_PROFESSION_SHEPHERD;
        case 11: return MCS_VILLAGER_PROFESSION_TOOLSMITH;
        case 12: return MCS_VILLAGER_PROFESSION_WEAPONSMITH;
        case 13: return MCS_VILLAGER_PROFESSION_NITWIT;
        default: return -1;
    }
}

static inline MCMOB_Skin owSkin(int i, int code) {
    if (i == OW_TRADER) return mcMobSkin(MCS_WANDERING_TRADER);
    if (i == OW_TRAP) return mcMobSkin(MCS_HORSE_SKELETON);
    if (i == OW_CREEPER) return mcMobSkin(MCS_CREEPER);
    if (i >= OW_LLAMA0) {
        int coat = (code >> 9) & 3;
        return mcMobLlamaSkin(coat == 0 ? MCM_LLAMA_CREAMY : coat == 1 ? MCM_LLAMA_WHITE : coat == 2 ? MCM_LLAMA_BROWN : MCM_LLAMA_GRAY,
                              MCM_EQUIPMENT_LLAMA_BODY_TRADER_LLAMA);
    }
    int4 info = MCW_MOB_INFO[i];
    if (info.x == 0) {
        int prof = owProfessionOf(i);
        int vt = info.z;   // the villager's biome type
        if ((info.w & 1) != 0) {
            int bt = vt == 0 ? MCS_VILLAGER_BABY_DESERT : vt == 1 ? MCS_VILLAGER_BABY_JUNGLE : vt == 3 ? MCS_VILLAGER_BABY_SAVANNA
                   : vt == 4 ? MCS_VILLAGER_BABY_SNOW : vt == 5 ? MCS_VILLAGER_BABY_SWAMP : vt == 6 ? MCS_VILLAGER_BABY_TAIGA
                   : MCS_VILLAGER_BABY_PLAINS;
            return mcMobVillagerSkin(MCS_VILLAGER_BABY, bt, -1, -1);
        }
        int ty = vt == 0 ? MCS_VILLAGER_TYPE_DESERT : vt == 1 ? MCS_VILLAGER_TYPE_JUNGLE : vt == 3 ? MCS_VILLAGER_TYPE_SAVANNA
               : vt == 4 ? MCS_VILLAGER_TYPE_SNOW : vt == 5 ? MCS_VILLAGER_TYPE_SWAMP : vt == 6 ? MCS_VILLAGER_TYPE_TAIGA
               : MCS_VILLAGER_TYPE_PLAINS;
        int level = (prof >= 0 && prof != 13) ? MCS_VILLAGER_PROFESSION_LEVEL_STONE : -1;
        return mcMobVillagerSkin(MCS_VILLAGER, ty, owProfession(prof), level);
    }
    if (info.x == 1) return mcMobSkin(MCM_IRON_GOLEM);
    if (info.x == 2) {
        switch (info.y) {
            case 1:  return mcMobSkin(MCS_CAT_BLACK);
            case 2:  return mcMobSkin(MCS_CAT_RED);
            case 3:  return mcMobSkin(MCS_CAT_SIAMESE);
            case 4:  return mcMobSkin(MCS_CAT_BRITISH_SHORTHAIR);
            case 5:  return mcMobSkin(MCS_CAT_CALICO);
            case 6:  return mcMobSkin(MCS_CAT_PERSIAN);
            case 7:  return mcMobSkin(MCS_CAT_RAGDOLL);
            case 8:  return mcMobSkin(MCS_CAT_WHITE);
            case 9:  return mcMobSkin(MCS_CAT_JELLIE);
            case 10: return mcMobSkin(MCS_CAT_ALL_BLACK);
            default: return mcMobSkin(MCS_CAT_TABBY);
        }
    }
    if (info.x == 4) {
        // the game's dye colours (DyeColor.textureDiffuseColor), white and the greys
        float3 dye = info.y == 8 ? float3(0x9D, 0x9D, 0x97) / 255.0 : info.y == 7 ? float3(0x47, 0x4F, 0x52) / 255.0
                   : info.y == 15 ? float3(0x1D, 0x1D, 0x21) / 255.0 : info.y == 12 ? float3(0x83, 0x54, 0x32) / 255.0
                   : float3(0xF9, 0xFF, 0xFE) / 255.0;
        return mcMobSheepSkin(false, true, mcFromSRGB(dye));
    }
    if (info.x == 7) {
        int colour = info.y & 255, marks = (info.y >> 8) & 255;
        int base = colour == 0 ? MCS_HORSE_WHITE : colour == 1 ? MCS_HORSE_CREAMY : colour == 2 ? MCS_HORSE_CHESTNUT
                 : colour == 3 ? MCS_HORSE_BROWN : colour == 4 ? MCS_HORSE_BLACK : colour == 5 ? MCS_HORSE_GRAY
                 : MCS_HORSE_DARKBROWN;
        MCMOB_Skin sk = mcMobSkin(base);
        sk.over1 = marks == 1 ? MCS_HORSE_MARKINGS_WHITE : marks == 2 ? MCS_HORSE_MARKINGS_WHITEFIELD
                 : marks == 3 ? MCS_HORSE_MARKINGS_WHITEDOTS : marks == 4 ? MCS_HORSE_MARKINGS_BLACKDOTS : -1;
        return sk;
    }
    bool baby = (info.w & 1) != 0;
    if (info.x == 5) return mcMobSkin(baby ? (info.y == 2 ? MCS_PIG_COLD_BABY : info.y == 1 ? MCS_PIG_WARM_BABY : MCS_PIG_TEMPERATE_BABY)
                                           : (info.y == 2 ? MCS_PIG_COLD : info.y == 1 ? MCS_PIG_WARM : MCS_PIG_TEMPERATE));
    if (info.x == 6) return mcMobSkin(baby ? (info.y == 2 ? MCS_CHICKEN_COLD_BABY : info.y == 1 ? MCS_CHICKEN_WARM_BABY : MCS_CHICKEN_TEMPERATE_BABY)
                                           : (info.y == 2 ? MCS_CHICKEN_COLD : info.y == 1 ? MCS_CHICKEN_WARM : MCS_CHICKEN_TEMPERATE));
    return mcMobSkin(baby ? (info.y == 2 ? MCS_COW_COLD_BABY : info.y == 1 ? MCS_COW_WARM_BABY : MCS_COW_TEMPERATE_BABY)
                          : (info.y == 2 ? MCS_COW_COLD : info.y == 1 ? MCS_COW_WARM : MCS_COW_TEMPERATE));
}

// World ray -> the mob's own space; a lying mob is laid on its back, head
// toward its heading. (c, s) are the heading's cosine and sine.
static inline void owMobSpace(float3 at, float c, float s, bool lying, float3 ro, float3 rd,
                              thread float3& lro, thread float3& lrd,
                              thread float3& ex, thread float3& ey, thread float3& ez) {
    float3 o = at;
    if (!lying) {
        ex = float3(c, 0.0, -s); ey = float3(0.0, 1.0, 0.0); ez = float3(s, 0.0, c);
    } else {
        ey = float3(s, 0.0, c);            // the body runs toward the head of the bed
        ez = float3(0.0, 1.0, 0.0);        // face up
        ex = cross(ey, ez);
        o = at - ey * 1.6 + float3(0.0, 0.3, 0.0);   // the head on the pillow
    }
    float3 p = ro - o;
    lro = float3(dot(p, ex), dot(p, ey), dot(p, ez));
    lrd = float3(dot(rd, ex), dot(rd, ey), dot(rd, ez));
}

// ==== Doors ========================================================================
// The volume has every door closed. A villager going home walks through its
// door, so the door opens, as the game's villagers open it, while one is
// within a block and a half of it: the closed door is traced past and the open
// one drawn, the game's 3/16-thick panel turned onto its hinge side.

// The door (index into MCW_DOORS) whose cell, lower or upper, holds `cell`, or -1.
static inline int owDoorAt(int3 cell) {
    for (int i = 0; i < MCW_DOOR_COUNT; ++i) {
        int3 d = MCW_DOORS[i].xyz;
        if (cell.x == d.x && cell.z == d.z && (cell.y == d.y || cell.y == d.y + 1)) return i;
    }
    return -1;
}

// The open panel of door i along a ray: distance (or INFINITY), colour (a = coverage), normal.
static inline float owDoorPanel(McWorld W, int i, float3 ro, float3 rd, thread float4& colour, thread float3& n) {
    int4 D = MCW_DOORS[i];
    int side = (D.w >> 6) & 3;                 // the open panel's side: 0 -z, 1 +x, 2 +z, 3 -x
    float3 lo = float3(D.xyz), hi = lo + float3(1.0, 2.0, 1.0);
    float th = 3.0 / 16.0;
    if (side == 0) hi.z = lo.z + th; else if (side == 2) lo.z = hi.z - th;
    else if (side == 1) lo.x = hi.x - th; else hi.x = lo.x + th;
    float3 inv = mcModelInv(rd);
    float3 ta = (lo - ro) * inv, tb = (hi - ro) * inv;
    float3 tn = min(ta, tb), tf = max(ta, tb);
    float t0 = max(max(tn.x, tn.y), tn.z), t1 = min(min(tf.x, tf.y), tf.z);
    if (t0 > t1 || t1 <= 0.0) return INFINITY;
    for (int pass = 0; pass < 2; ++pass) {
        float t = pass == 0 ? t0 : t1;
        float3 P = ro + rd * t;
        float3 q = (P - lo) / max(hi - lo, float3(1e-4));
        int ax = pass == 0 ? (tn.x >= tn.y && tn.x >= tn.z ? 0 : tn.y >= tn.z ? 1 : 2)
                           : (tf.x <= tf.y && tf.x <= tf.z ? 0 : tf.y <= tf.z ? 1 : 2);
        n = ax == 0 ? float3(-sign(rd.x), 0, 0) : ax == 1 ? float3(0, -sign(rd.y), 0) : float3(0, 0, -sign(rd.z));
        if (pass == 1) n = -n;
        float along = (side == 0 || side == 2) ? q.x : q.z;
        float y2 = P.y - lo.y;
        int layer = y2 >= 1.0 ? MC_OAK_DOOR_TOP : MC_OAK_DOOR_BOTTOM;
        float4 c = mcTile(W.tiles, layer, float2(along, 1.0 - fract(min(y2, 1.999))), t * W.pxA);
        if (c.a >= 0.5) { colour = float4(c.rgb, 1.0); return t; }
    }
    return INFINITY;
}

// ==== Shading =====================================================================
// mcWorldShade's own steps (the kit's sky, light, water, fog and layer), with
// the sun's shadow ray cut short: `steps` cells of the kit's skip march
// (mcwShadowRay) rather than its 96. A low sun's rays run long over open
// ground, and the far end of one seldom finds anything a near one does not.
static inline float3 owShade(McWorld W, McWorldHit h, float3 ro, float3 rd, float3 sun, int moon, bool shadows,
                             int steps, float fogEnd, float rain, float thunder) {
    float day = mcWorldDay(sun.y, rain, thunder);
    float3 col;
    if (h.t >= fogEnd) return mcWorldSky(W, rd, sun, moon, rain, thunder);
    if (h.color.a < 0.0) return mcWorldSkyFog(rd, sun, rain, thunder);
    float3 L = sun.y > -0.05 ? sun : -sun;
    float sh = 1.0;
    float3 sn = (h.flags & MCW_HIT_FLAT) != 0u && dot(h.n, L) < 0.0 ? -h.n : h.n;
    // (no shadow ray from plants and torches: lit flat by their own cell, as
    // the game does, they show a sun shadow only as a faint change)
    if (shadows && rain < 1.0 && h.waterT < 0.0 && (h.flags & (MCW_HIT_FAR | MCW_HIT_EMISSIVE | MCW_HIT_FLAT)) == 0u) {
        sh = dot(sn, L) <= 0.0 ? 0.0 : mcwShadowRay(W, h.p + sn * 0.002 + L * 0.001, L, steps);
        sh = mix(sh, 1.0, rain);
    }
    col = h.color.rgb * mcWorldLight(W, h, day, sh);
    if (h.waterT < 0.0) {
        col = mcWorldFog(col, rd, h.t, sun, fogEnd, rain, thunder);
    } else {
        col = mcWorldWater(W, h, ro, rd, col, h.t - h.waterT, day, col);
        col = mcWorldFog(col, rd, h.waterT, sun, fogEnd, rain, thunder);
    }
    if (h.layerT >= 0.0) col = mcWorldLayer(W, h, ro, rd, col, sun, fogEnd, rain, thunder);
    return col;
}

// ==== The director ==================================================================
// Every Mac cuts at the same instants, on 40-second boundaries of the shared
// clock (30 shots a game day), and each films the same moment from its own
// camera: the seed picks which shots it takes and in what order.

constant float OW_SHOT = 40.0;   // seconds a shot

// A camera may be here: not in a block, not under the ground, a little room round it.
static inline bool owRoom(McWorld W, float3 e) {
    if (e.y < mcWorldSurface(W, e.xz) + 0.8) return false;
    for (int k = 0; k < 5; ++k) {
        float3 o = k == 0 ? float3(0.0) : float3(k == 1 ? 0.35 : k == 2 ? -0.35 : 0.0, 0.0, k == 3 ? 0.35 : k == 4 ? -0.35 : 0.0);
        if (mcWorldSolid(W, e + o) || mcWorldSolid(W, e + o + float3(0.0, 0.4, 0.0))) return false;
    }
    return true;
}

// Nothing solid between the camera and most of the way to what it looks at
// (the last quarter may cross a stall's awning or a fence round the subject).
static inline bool owSees(McWorld W, float3 e, float3 t) {
    for (int k = 1; k <= 12; ++k) {
        float3 p = mix(e, t, float(k) / 16.0);
        if (mcWorldSolid(W, p)) return false;
    }
    return true;
}

// The first of eight bearings round `at`, from a0 on, where a camera `r`
// out and `up` up has room and sees `at`.
static inline float owClearAngle(McWorld W, float3 at, float r, float up, float a0) {
    for (int j = 0; j < 8; ++j) {
        float a = a0 + float(j) * (M_PI_F / 4.0);
        float3 e = at + float3(sin(a) * r, up, cos(a) * r);
        if (owRoom(W, e) && owSees(W, e, at)) return a;
    }
    return a0;
}

struct OwCam { float3 eye; float3 at; float focal; };

static inline float2 owDir(float a) { return float2(sin(a), cos(a)); }

// Shot recipes. `p` runs 0..1 through the shot, `v` (0..1) is this Mac's
// variant of it. All are placed from the bake's points of interest.
constant int OW_RECIPES = 9;
struct OwSubject { int mob; int day; float sec0; };   // who a portrait follows, and when its slot starts
__attribute__((noinline)) static OwCam owRecipe(McWorld W, int k, float p, float v, float3 meet, float3 sun, OwSubject subj) {
    OwCam c; c.focal = 1.6;
    float drift = p - 0.5;
    if (k == 0) {
        // The meeting place from over the roofs round it, drifting sideways.
        c.at = meet + float3(0.0, 1.0, 0.0);
        float a = owClearAngle(W, c.at, 13.0, 6.5, v * 6.2832) + drift * 0.35;
        c.eye = c.at + float3(owDir(a).x * 13.0, 6.5, owDir(a).y * 13.0);
        c.focal = 1.8;
    } else if (k == 1) {
        // From the hill over the village, looking down on the roofs.
        int h = owPoi(MCW_POI_HILLTOP, 0);
        float3 H = MCW_POI[max(h, 0)].xyz;
        float2 side = normalize(float2(meet.z - H.z, H.x - meet.x));
        float2 toward = normalize(meet.xz - H.xz);
        c.eye = H + float3(side.x, 0.0, side.y) * (drift * 8.0 + (v - 0.5) * 30.0)
              + float3(toward.x, 0.0, toward.y) * 14.0 + float3(0.0, 9.0, 0.0);
        c.at = meet + float3(0.0, 2.0, 0.0);
        c.focal = 1.7;
    } else if (k == 2) {
        // The whole village, high and wide, turning slowly about it.
        int ci = owPoi(MCW_POI_CLUSTER, 0);
        float4 C = MCW_POI[max(ci, 0)];
        float a = v * 6.2832 + drift * 0.25;
        c.at = C.xyz + float3(0.0, 2.0, 0.0);
        c.eye = c.at + float3(owDir(a).x * C.w * 0.9, 22.0, owDir(a).y * C.w * 0.9);
        c.focal = 1.5;
    } else if (k == 3) {
        // Down a street at eye height, walking pace, along a village loop.
        int r = int(v * 97.0) % MCW_ROUTE_COUNT;
        float n = owRouteLen(r);
        float a0 = floor(v * 7919.0) - floor(v * 7919.0 / n) * n;
        float s = a0 + p * 14.0;
        float hd;
        float3 e = float3(0.0), t = float3(0.0);
        for (int j = -2; j <= 2; ++j) { e += mcWorldRoute(r, s + float(j), 1.0, hd); t += mcWorldRoute(r, s + 7.0 + float(j), 1.0, hd); }
        c.eye = e / 5.0 + float3(0.0, 1.8, 0.0);
        c.at = t / 5.0 + float3(0.0, 1.4, 0.0);
        c.focal = 1.4;
    } else if (k == 4) {
        // A house, from the side the bake says it is seen best.
        int sCount = 0;
        for (int i = 0; i < MCW_POI_COUNT; ++i) sCount += MCW_POI_KIND[i] == MCW_POI_STRUCTURE ? 1 : 0;
        int si = owPoi(MCW_POI_STRUCTURE, int(v * float(max(sCount, 1))) % max(sCount, 1));
        float4 S = MCW_POI[max(si, 0)];
        float3 vw = MCW_POI_VIEW[max(si, 0)].xyz;
        if (dot(vw, vw) < 0.5) vw = float3(1.0, 0.0, 0.0);
        float2 sd = float2(-vw.z, vw.x);
        c.at = S.xyz + float3(0.0, 1.0, 0.0);
        c.eye = c.at + vw * (S.w + 7.0) + float3(sd.x, 0.0, sd.y) * drift * 6.0 + float3(0.0, 2.5, 0.0);
        c.focal = 1.7;
    } else if (k == 5) {
        // A lit corner: lamp posts, the lava pool. For the night.
        int lCount = 0;
        for (int i = 0; i < MCW_POI_COUNT; ++i) lCount += MCW_POI_KIND[i] == MCW_POI_LIT ? 1 : 0;
        int li = owPoi(MCW_POI_LIT, int(v * float(max(lCount, 1))) % max(lCount, 1));
        float4 Lp = MCW_POI[max(li, 0)];
        float a = v * 40.0 + drift * 0.3;
        c.at = Lp.xyz + float3(0.0, 1.0, 0.0);
        c.eye = c.at + float3(owDir(a).x * 13.0, 5.0, owDir(a).y * 13.0);
        c.focal = 1.7;
    } else if (k == 6) {
        // Low by the bell, looking up past the roofs to the sun or the moon.
        float3 L = sun.y > 0.0 ? sun : -sun;
        float2 az = normalize(L.xz + float2(1e-4, 0.0));
        c.eye = meet + float3(-az.x * 8.0, 1.7, -az.y * 8.0) + float3(az.y, 0.0, -az.x) * drift * 3.0;
        c.at = c.eye + float3(az.x, 0.45 + 0.2 * v, az.y) * 10.0;
        c.focal = 1.3;
    } else if (k == 8) {
        // A portrait: one mob, from a few blocks off, turning slowly round it.
        OwTime Tp; Tp.day = subj.day; Tp.sec = subj.sec0 + p * OW_SHOT; Tp.tick = Tp.sec * 20.0;
        float4 extra;
        OwMob m = owMob(W, max(subj.mob, 0), Tp, meet + float3(0.0, 2.5, 0.0), extra);
        float big = m.type == MCMOB_HORSE ? 1.6 : 1.0;
        // a clear bearing found where the subject is halfway through the shot
        OwTime Th = Tp; Th.sec = subj.sec0 + 0.5 * OW_SHOT; Th.tick = Th.sec * 20.0;
        float3 mid = owMob(W, max(subj.mob, 0), Th, meet + float3(0.0, 2.5, 0.0), extra).p + float3(0.0, 1.1 * big, 0.0);
        float a = owClearAngle(W, mid, 9.0 * big, 1.8, v * 6.2832) + drift * 0.5;
        c.at = m.p + float3(0.0, 1.1 * big, 0.0);
        c.eye = c.at + float3(owDir(a).x * 9.0 * big, 1.8, owDir(a).y * 9.0 * big);
        c.focal = 1.9;
    } else {
        // The shore: low over the water's edge, toward a low sun (or the moon)
        // when there is one to look at, else back at the village.
        int nS = 0;
        for (int i = 0; i < MCW_POI_COUNT; ++i) nS += MCW_POI_KIND[i] == MCW_POI_SHORE ? 1 : 0;
        int si = owPoi(MCW_POI_SHORE, int(v * 13.0) % max(nS, 1));
        float3 S = MCW_POI[max(si, 0)].xyz;
        float3 L = sun.y > -0.1 ? sun : -sun;
        float2 toSun = normalize(L.xz + float2(1e-4, 0.0));
        float2 toVil = normalize(meet.xz - S.xz + float2(1e-4, 0.0));
        float2 look = abs(L.y) < 0.45 ? toSun : toVil;
        float2 side = float2(-look.y, look.x);
        c.eye = S + float3(-look.x * 6.0 + side.x * drift * 6.0, 3.0, -look.y * 6.0 + side.y * drift * 6.0);
        c.eye.y = max(c.eye.y, mcWorldSurface(W, c.eye.xz) + 2.5);
        c.at = c.eye + float3(look.x, abs(L.y) < 0.45 ? 0.18 : 0.02, look.y) * 20.0;   // more sky, less sea: cheaper
        c.focal = 1.5;
    }
    return c;
}

// Is this shot good for the whole of its 40 seconds? The camera has room at
// its start, middle and end and sees what it looks at; a street shot also
// stays out of doors (the sky light above it is the open sky's).
// A mob that appears or goes (the trader at the field's end, the trap
// horse) must not do it in shot: `pops` are (place, tick of the shot's slot, as 0..1 of it).
static inline bool owSeesPop(McWorld W, OwCam c, float3 P) {
    float3 f = normalize(c.at - c.eye);
    float3 d = P + float3(0.0, 1.0, 0.0) - c.eye;
    float L = length(d);
    if (L > 190.0 || dot(d / L, f) < 0.6) return false;   // outside the widest lens's view
    for (int k = 1; k <= 15; ++k) if (mcWorldSolid(W, c.eye + d * (float(k) / 16.0))) return false;
    return true;
}

// One of a shot's five checks, so 32 lanes can share them out: part 0..2
// the camera at the start, middle and end has room, sees its subject and
// has nothing in the near corners of the frame (a street shot also stays
// out of doors); part 3 and 4: the appearances in `pop0` / `pop1` happen out
// of its sight.
__attribute__((noinline)) static bool owCheck(McWorld W, int k, float v, float3 meet, float3 sun, float4 pop0, float4 pop1,
                           OwSubject subj, int part, bool dark) {
    if (part >= 3) {
        float4 pp = part == 3 ? pop0 : pop1;
        if (pp.w < -0.05 || pp.w > 1.05) return true;
        return !owSeesPop(W, owRecipe(W, k, saturate(pp.w), v, meet, sun, subj), pp.xyz);
    }
    OwCam c = owRecipe(W, k, float(part) * 0.5, v, meet, sun, subj);
    if (!owRoom(W, c.eye) || !owSees(W, c.eye, c.at)) return false;
    if (k == 3 || k == 6) {
        int3 cell = int3(floor(c.eye));
        if (mcwInBox(cell) && mcwLightAt(W, c.eye).a < 0.99) return false;
    }
    // After dark (or under a storm) a close shot is only of a place with its
    // own light: lamplight of level 8 or more somewhere about what it looks at.
    if (dark && (k == 0 || k == 3 || k == 4 || k == 5)) {
        float best = 0.0;
        for (int q = 0; q < 9; ++q) {
            float3 o = float3(float(q % 3) - 1.0, 0.0, float(q / 3) - 1.0) * 3.0 + float3(0.0, 0.5, 0.0);
            float4 L = mcwLightAt(W, c.at + o);
            best = max(best, max(L.r, max(L.g, L.b)));
        }
        if (best < 8.0 / 15.0) return false;
    }
    float3 f = normalize(c.at - c.eye);
    float3 r = normalize(cross(f, float3(0.0, 1.0, 0.0)));
    float3 up = cross(r, f);
    // nothing filling the frame's top corners or sides from close by (the
    // bottom edge may well show the ground the camera stands over)
    // (a street or a portrait may have walls at its sides: only its top corners count)
    for (int q = (k == 3 || k == 8) ? 2 : 0; q < 4; ++q) {
        float3 d = normalize(f * c.focal + r * ((q & 1) != 0 ? 1.4 : -1.4) + up * ((q & 2) != 0 ? 0.8 : 0.0));
        for (int st = 1; st <= 3; ++st) if (mcWorldSolid(W, c.eye + d * (1.5 * float(st)))) return false;
    }
    return true;
}

// Which shots suit the hour (and the village's doings), as weights.
static inline float owWeight(int k, float tick, float sunY, int subject, bool wet) {
    // Rain costs about 3.5 ms a frame (the game's rain quads round the camera),
    // so under rain only the shots that leave room for it: the market, streets,
    // the village from above and portraits.
    if (wet && (k == 1 || k == 4 || k == 5 || k == 7)) return 0.0;
    // After dark and in storms the director keeps to what has its own light:
    // the lamp-lit square, lit streets and doorways (each checked for lamplight
    // in owCheck), and the whole village's lights from the hill or from above.
    // Open country, the shore and sleeping villagers are no shot then.
    bool dark = sunY < -0.12 || (wet && sunY < 0.2);
    if (k == 8) return subject == OW_TRAP || subject == OW_CREEPER ? 24.0 : subject == OW_TRADER ? 3.0
                     : subject >= 0 && !dark ? 2.0 : 0.0;
    bool low = abs(sunY) < 0.3;
    bool meeting = tick >= 9000.0 && tick < 11000.0;
    float w;
    if (dark)         w = k == 0 ? 3.0 : k == 5 ? 3.0 : k == 3 ? 2.0 : k == 4 ? 2.0 : k == 1 ? 1.5 : k == 2 ? 1.0 : 0.0;
    else if (low)     w = k == 7 ? 3.0 : k == 2 ? 2.0 : k == 1 ? 1.0 : k == 4 ? 1.5 : k == 0 ? 1.5 : k == 3 ? 1.0 : 0.0;
    else if (meeting) w = k == 0 ? 5.0 : k == 3 ? 1.5 : k == 2 ? 1.0 : k == 1 ? 0.5 : k == 4 ? 1.0 : 0.0;
    else              w = k == 3 ? 3.0 : k == 4 ? 3.0 : k == 0 ? 2.0 : k == 2 ? 1.5 : k == 1 ? 0.7 : k == 7 ? 1.0 : 0.0;
    return w;
}

// The shot this Mac takes in slot `slot` (global: game day * 30 + shot of the day):
// a weighted draw from this Mac's own stream, skipping whatever it took last.
static inline int owDraw(int slot, uint key, int tries, float tick, float sunY, int avoid, int subject, bool wet = false) {
    // A rare visitor may be filmed slot after slot; any other shot not twice running.
    bool event = subject == OW_TRAP || subject == OW_CREEPER;
    if (event && avoid == 8) avoid = -1;
    float total = 0.0;
    for (int k = 0; k < OW_RECIPES; ++k) total += k == avoid ? 0.0 : owWeight(k, tick, sunY, subject, wet);
    float x = float(owH(slot * 7 + tries, key) % 10000u) / 10000.0 * total;
    for (int k = 0; k < OW_RECIPES; ++k) {
        float w = k == avoid ? 0.0 : owWeight(k, tick, sunY, subject, wet);
        if (x < w) return k;
        x -= w;
    }
    return 2;
}

// ==== The look ======================================================================

// The shot this Mac takes in `slot`: four tries at a weighted draw, five
// checks each, shared out a check a lane; the first try whose checks all
// pass, else the wide shot. For the plan kernel (one SIMD group).
__attribute__((noinline)) static int owChoose(McWorld W, int slot, uint key, float slotTick, float3 sunAt, int avoid, float3 meet,
                           float4 pop0, float4 pop1, OwSubject subj, uint lane, thread float& variant,
                           thread ulong& okBits, float4 pm0, float4 pm1, float4 pm2, bool mobCheck) {
    int myCheck = min(int(lane), 19);
    int myTry = myCheck / 5;
    float2 wxs = owWeather(subj.day, slotTick + 400.0);
    bool wet = wxs.x > 0.3;
    bool dark = sunAt.y < -0.12 || (wxs.y > 0.3 && sunAt.y < 0.2) || (wet && sunAt.y < 0.2);
    int myK = owDraw(slot, key, myTry, slotTick, sunAt.y, avoid, subj.mob, wet);
    float myV = float(owH(slot * 13 + myTry, key ^ 0x5bd1e995u) % 1000u) / 1000.0;
    bool myOK = owCheck(W, myK, myV, meet, sunAt, pop0, pop1, subj, myCheck % 5, dark);
    // No mob in the lens: none within 2.5 blocks of the camera and in its view
    // at the shot's start, middle or end (pm0..2: each lane's mob at those times).
    if (mobCheck) {
        int part = myCheck % 5;
        OwCam c = owRecipe(W, myK, float(min(part, 2)) * 0.5, myV, meet, sunAt, subj);
        float3 f = normalize(c.at - c.eye);
        bool near = false;
        for (int mi = 0; mi < OW_MOBS; ++mi) {
            float4 q0 = simd_shuffle(pm0, ushort(mi)), q1 = simd_shuffle(pm1, ushort(mi)), q2 = simd_shuffle(pm2, ushort(mi));
            float4 q = part == 0 ? q0 : part == 1 ? q1 : q2;
            float3 d = q.xyz + float3(0.0, 1.0, 0.0) - c.eye;
            float L = length(d);
            if (part < 3 && q.w > 0.5 && L < 2.5 && dot(d, f) > -0.5) near = true;
        }
        myOK = myOK && !near;
    }
    okBits = ulong(simd_vote::vote_t(simd_ballot(myOK)));
    variant = float(owH(slot * 13, key ^ 0x5bd1e995u) % 1000u) / 1000.0;
    for (int j = 0; j < 4; ++j) {
        if (((okBits >> (j * 5)) & 31ul) == 31ul) {
            variant = float(owH(slot * 13 + j, key ^ 0x5bd1e995u) % 1000u) / 1000.0;
            return owDraw(slot, key, j, slotTick, sunAt.y, avoid, subj.mob, wet);
        }
    }
    return 2;
}

// ==== The plan: once a frame =========================================================
// Everything that is the same for every pixel (where each mob is, which shot
// this Mac takes and whether it is clear, the weather, which doors stand open)
// is worked out here, once a frame, by one SIMD group, and read by lerpMain.

constant int OWP_CAM = 0;      // eye, focal
constant int OWP_AT = 1;       // look-at, recipe
constant int OWP_SKY = 2;      // rain, thunder, moon phase, open doors (bits)
constant int OWP_BOLT = 3;     // strike point, 1 while a bolt shows
constant int OWP_MISC = 4;     // bolt seed (bits), mobs in view (bits)
constant int OWP_MOBS = 5;     // four float4s a mob: OwPacked a, b, c, and where it is on screen
constant int OWP_TILES = OWP_MOBS + 4 * 32;   // 64 screen tiles (8 x 8): which mobs each may show, a uint each

kernel void lerpPlan(constant LerpUniforms& u [[buffer(0)]], MCW_BINDINGS,
                     device float4* plan [[buffer(13)]], uint lane [[thread_index_in_simdgroup]]) {
    McWorld W = MCW_WORLD;
    if (u.date >= 0.0) W.clock.day = int(u.date);
    OwTime T = owTime(W, u.time);
    float3 meet = owMeet();
    float3 bell = meet + float3(0.0, 2.5, 0.0);
    float3 sun = mcWorldSunDir(T.tick);
    float2 wx = owWeather(T.day, T.tick);

    // Each lane one mob.
    int mine = min(int(lane), OW_MOBS - 1);
    OwPacked own = owPack(W, mine, T, bell);
    if (int(lane) < OW_MOBS) {
        plan[OWP_MOBS + 4 * lane] = own.a;
        plan[OWP_MOBS + 4 * lane + 1] = own.b;
        plan[OWP_MOBS + 4 * lane + 2] = own.c;
    }

    float sp = T.sec / OW_SHOT;
    uint key = uint(u.seed * 65521.0) * 2654435761u + 17u;   // this Mac's own stream of shots
    int slot = T.day * 30 + int(floor(sp));
    float slotTick = floor(sp) * OW_SHOT * 20.0;
    float3 sunAt = mcWorldSunDir(slotTick + 400.0);
    // Appearances this slot: the trader at his field end, the trap horse.
    float4 pop0 = float4(0.0, 0.0, 0.0, -9.0), pop1 = pop0;
    float4 dT = simd_shuffle(own.d, ushort(OW_TRADER)), dH = simd_shuffle(own.d, ushort(OW_TRAP));
    float4 dC = simd_shuffle(own.d, ushort(OW_CREEPER));
    // the trap horse and the charged creeper share the second appearance check
    // (both come only in storms; whichever is nearer this slot)
    bool creeperNear = dC.z >= -0.5 && (dH.z < -0.5 || min(abs(dC.z - slotTick), abs(dC.w - slotTick)) < min(abs(dH.z - slotTick), abs(dH.w - slotTick)));
    if (dT.w > 0.5) {
        float tEnd = OW_TRADER_OUT + (float((int(dT.w) / 64) % 64) + (int(dT.w) >= 4096 ? OW_TRADER_WAY : 0.0)) / OW_TRADER_WALK * 20.0;
        float tPop = abs(OW_TRADER_IN - slotTick - 400.0) < abs(tEnd - slotTick - 400.0) ? OW_TRADER_IN : tEnd;
        pop0 = float4(dT.xyz, (tPop - slotTick) / 800.0);
    }
    {
        float4 d2 = creeperNear ? dC : dH;
        if (d2.z >= -0.5) {
            float tPop = abs(d2.z - slotTick - 400.0) < abs(d2.w - slotTick - 400.0) ? d2.z : d2.w;
            float water;
            pop1 = float4(d2.x, mcWorldGround(W, d2.xy, water), d2.y, (tPop - slotTick) / 800.0);
        }
    }
    // Whom a portrait would follow: the trap horse, else the trader, else a
    // villager of this Mac's choosing, by day.
    OwSubject subj; subj.day = T.day; subj.sec0 = floor(sp) * OW_SHOT; subj.mob = -1;
    if (dC.z >= -0.5 && slotTick >= dC.z + 400.0 && slotTick + 800.0 < dC.w) subj.mob = OW_CREEPER;
    else if (dH.z >= -0.5 && slotTick >= dH.z - 800.0 && slotTick + 800.0 < dH.w) subj.mob = OW_TRAP;
    else if (dT.w > 0.5 && slotTick > OW_TRADER_IN + 800.0 && slotTick + 800.0 < OW_TRADER_OUT) subj.mob = OW_TRADER;
    else if (sunAt.y > 0.1) {
        // a villager of this Mac's choosing: the first at or after a drawn index
        int start = int(owH(slot, key) % uint(max(MCW_MOB_COUNT, 1)));
        for (int j = 0; j < MCW_MOB_COUNT; ++j) {
            int c = (start + j) % MCW_MOB_COUNT;
            if (MCW_MOB_INFO[c].x == 0) { subj.mob = c; break; }
        }
    }

    // The shot before (so as not to take the same twice running), then this one.
    int prev2 = owDraw(slot - 2, key, 0, slotTick - 1600.0, mcWorldSunDir(slotTick - 1200.0).y, -1, -1);
    float vPrev;
    ulong okPrev;
    int prev = owChoose(W, slot - 1, key, slotTick - 800.0, mcWorldSunDir(slotTick - 400.0), prev2, meet,
                        float4(0, 0, 0, -9), float4(0, 0, 0, -9), subj, lane, vPrev, okPrev,
                        float4(0.0), float4(0.0), float4(0.0), false);
    // each lane's mob at the start, middle and end of this slot, for the lens check
    float4 pm[3];
    for (int j = 0; j < 3; ++j) {
        OwTime Tj = T; Tj.sec = floor(sp) * OW_SHOT + float(j) * 0.5 * OW_SHOT; Tj.tick = Tj.sec * 20.0;
        OwPacked q = owPack(W, mine, Tj, bell);
        pm[j] = float4(q.a.xyz, int(lane) < OW_MOBS && (int(q.c.z) & 64) != 0 && (int(q.c.z) & 128) == 0 ? 1.0 : 0.0);
    }
    float variant;
    ulong okBits;
    int recipe = owChoose(W, slot, key, slotTick, sunAt, prev, meet, pop0, pop1, subj, lane, variant, okBits,
                          pm[0], pm[1], pm[2], true);
    if (u.shot >= 0) {
        recipe = u.shot; variant = fract(u.seed * 7.31 + 0.13);
        // a held portrait follows a visitor if one is about at all, for previewing
        if (subj.mob != OW_TRAP && subj.mob != OW_CREEPER && dT.w > 0.5 && slotTick >= OW_TRADER_IN - 800.0) subj.mob = OW_TRADER;
        if (subj.mob < 0) {
            for (int j = 0; j < MCW_MOB_COUNT; ++j) if (MCW_MOB_INFO[j].x == 0) { subj.mob = j; break; }
        }
    }
    OwCam cam = owRecipe(W, recipe, fract(sp), variant, meet, recipe == 6 ? sunAt : sun, subj);

    // Doors standing open: lane j asks whether anyone is within a block and a half of door j.
    bool open = false;
    for (int i = 0; i < OW_MOBS; ++i) {
        float4 a = simd_shuffle(own.a, ushort(i));
        float code = simd_shuffle(own.c.z, ushort(i));
        if (int(lane) < MCW_DOOR_COUNT && (int(code) & 64) != 0) {
            float3 dc = float3(MCW_DOORS[lane].xyz) + float3(0.5, 0.0, 0.5);
            if (distance(a.xz, dc.xz) < 1.5 && abs(a.y - dc.y) < 1.5) open = true;
        }
    }
    uint doors = uint(ulong(simd_vote::vote_t(simd_ballot(open && int(lane) < MCW_DOOR_COUNT))) & 0xFFFFFFFFul);
    // Mobs the camera might see: shown, within the fog, ahead of it.
    // Each one's bounding sphere (its round shadow included) as a circle on
    // the screen, in lerpUV's units, so a pixel far from it skips it at once.
    float3 fwd = normalize(cam.at - cam.eye);
    float3 rgt = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 upv = cross(rgt, fwd);
    int mtype = int(own.c.z) & 63;
    bool lyingM = (int(own.c.z) & 128) != 0;
    float rad = owRadius(mtype) * (lyingM ? 2.0 : 1.0) + 0.3;
    float3 rel = own.a.xyz + float3(0.0, lyingM ? 0.4 : owRadius(mtype) * 0.9, 0.0) - cam.eye;
    float depth = dot(rel, fwd);
    float dist = length(rel);
    bool seen = int(lane) < OW_MOBS && (int(own.c.z) & 64) != 0 && dist < 130.0 && depth > -rad;
    float4 circle = depth > rad + 0.2
        ? float4(dot(rel, rgt) * cam.focal / depth, dot(rel, upv) * cam.focal / depth, rad * cam.focal / (depth - rad), 0.0)
        : float4(0.0, 0.0, 1e6, 0.0);
    if (int(lane) < OW_MOBS) plan[OWP_MOBS + 4 * lane + 3] = circle;
    uint mobs = uint(ulong(simd_vote::vote_t(simd_ballot(seen))) & 0xFFFFFFFFul);
    // Which mobs each of 8 x 8 screen tiles may show (its circle meets the
    // tile), so most pixels of a wide shot look at none.
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 ext = float2(max(aspect, 1.0), max(1.0 / aspect, 1.0));
    uint tileLo = 0u, tileHi = 0u;   // this lane keeps tiles `lane` and `lane + 32`
    for (int t = 0; t < 64; ++t) {
        float2 lo = -ext + 2.0 * ext * float2(float(t % 8), float(t / 8)) / 8.0;
        float2 hi = lo + 2.0 * ext / 8.0;
        bool hit = seen && distance(clamp(circle.xy, lo, hi), circle.xy) <= circle.z;
        uint m = uint(ulong(simd_vote::vote_t(simd_ballot(hit))) & 0xFFFFFFFFul);
        if (int(lane) == (t & 31)) { if (t < 32) tileLo = m; else tileHi = m; }
    }
    device float* planF = (device float*)plan;
    planF[OWP_TILES * 4 + int(lane)] = as_type<float>(tileLo);
    planF[OWP_TILES * 4 + 32 + int(lane)] = as_type<float>(tileHi);

    if (lane == 0) {
        plan[OWP_CAM] = float4(cam.eye, cam.focal);
        plan[OWP_AT] = float4(cam.at, float(recipe));
        plan[OWP_SKY] = float4(wx, float(((T.day % 8) + 8) % 8), as_type<float>(doors));
        OwBolt b = owBoltNow(W, T, wx.y, meet);
        plan[OWP_BOLT] = float4(b.at, b.on ? 1.0 : 0.0);
        plan[OWP_MISC] = float4(as_type<float>(b.seed), as_type<float>(mobs), 0.0, 0.0);
    }
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]], MCW_BINDINGS,
                        constant float4* plan [[buffer(13)]]) {
    McWorld W = MCW_WORLD;
    if (u.date >= 0.0) W.clock.day = int(u.date);
    float2 uv = lerpUV(pos, u.resolution);
    OwTime T = owTime(W, u.time);
    float3 sun = mcWorldSunDir(T.tick);
    float4 sky = plan[OWP_SKY];
    float2 wx = sky.xy;
    int moon = int(sky.z);
    uint doors = as_type<uint>(sky.w);
    float3 ro = plan[OWP_CAM].xyz;
    float focal = plan[OWP_CAM].w;
    float3 fwd = normalize(plan[OWP_AT].xyz - ro);
    float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 rd = normalize(uv.x * right + uv.y * cross(right, fwd) + focal * fwd);
    W.pxA = 2.0 / (focal * min(u.resolution.x, u.resolution.y));
    // The game's fog at a render distance of 8 chunks (128 blocks), one of its
    // own settings: the village and its shores sit well inside it, and the
    // long views cost a third less than at the default 12.
    const float fogEnd = 128.0;

    McWorldHit h = mcWorldTrace(W, ro, rd, fogEnd);
    // A door someone is passing stands open.
    float4 doorC = float4(0.0); float3 doorN = float3(0.0); float doorT = INFINITY;
    if (doors != 0u && h.t < fogEnd) {
        int door = owDoorAt(mcWorldHitCell(h));
        if (door >= 0 && ((doors >> uint(door)) & 1u) != 0u) {
            // past the door's two cells, then the open panel in front of that
            float3 lo = float3(MCW_DOORS[door].xyz), hi = lo + float3(1.0, 2.0, 1.0);
            float3 inv = mcModelInv(rd);
            float3 tf = max((lo - ro) * inv, (hi - ro) * inv);
            float tOut = min(min(tf.x, tf.y), tf.z) + 1e-3;
            McWorldHit h2 = mcWorldTrace(W, ro + rd * tOut, rd, fogEnd - tOut);
            h2.t += tOut;
            if (h2.waterT >= 0.0) h2.waterT += tOut;
            if (h2.layerT >= 0.0) h2.layerT += tOut;
            h = h2;
            doorT = owDoorPanel(W, door, ro, rd, doorC, doorN);
        }
    }
    float tWorld = min(h.t, doorT);
    // The game's mob shadows fall only on full blocks' tops within 16 blocks of the camera.
    bool ground = h.t < 16.0 && h.n.y > 0.5 && doorT >= h.t && (h.flags & (MCW_HIT_MODEL | MCW_HIT_FAR)) == 0u;
    float groundLight = 0.0;
    if (ground) {
        // the light level of the cell over the block, as the game's shadow reads it:
        // block light, or sky light less the night's darkening
        float4 Lg = mcwLightAt(W, h.p + float3(0.0, 0.5, 0.0));
        groundLight = max(max(Lg.r, max(Lg.g, Lg.b)) * 15.0, Lg.a * 15.0 - 11.0 * (1.0 - mcLightDay(sun.y)));
    }
    float3 groundP = h.p;
    // Sun shadows by day; by moonlight they would barely show, so the night saves them.
    // Past 56 blocks a block's sun shadow is a few pixels: not traced there.
    // A low sun's shadow rays run long and cost twice as much: 24 cells of
    // the march then, 48 otherwise.
    bool shadows = sun.y > -0.08;
    float3 col = owShade(W, h, ro, rd, sun, moon, shadows && h.t < 56.0, abs(sun.y) < 0.3 ? 24 : 48,
                         fogEnd, wx.x, wx.y);
    if (h.t >= fogEnd) {
        float4 cl = mcWorldClouds(W, ro, rd, 700.0, sun, wx.x, 700.0);
        col = mix(col, cl.rgb, cl.a);
    }
    float day = mcWorldDay(sun.y, wx.x, wx.y);
    if (doorT < h.t) {
        float3 P = ro + rd * doorT;
        col = doorC.rgb * mcWorldLightAt(W, P + doorN * 0.3, float3(0.0), day, 1.0) * mcFaceShade(doorN);
        col = mcWorldFog(col, rd, doorT, sun, fogEnd, wx.x, wx.y);
    }

    // Mobs the plan says are in view: the nearest along the ray, and the
    // game's round shadow each casts on the ground under it.
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 ext = float2(max(aspect, 1.0), max(1.0 / aspect, 1.0));
    int2 tile = clamp(int2(floor((uv + ext) / (2.0 * ext) * 8.0)), int2(0), int2(7));
    int ti = tile.x + 8 * tile.y;
    uint mobs = as_type<uint>(plan[OWP_TILES + ti / 4][ti % 4]);
    float best = min(tWorld, fogEnd);
    int hitMob = -1;
    MCMOB_Hit mh;
    float3 mN = float3(0.0, 1.0, 0.0);
    float dark = 0.0;
    float3 aura = float3(0.0);
    while (mobs != 0u) {
        int i = int(ctz(mobs));
        mobs &= mobs - 1u;
        float4 sc4 = plan[OWP_MOBS + 4 * i + 3];
        if (distance(uv, sc4.xy) > sc4.z) continue;
        float4 qa = plan[OWP_MOBS + 4 * i], qb = plan[OWP_MOBS + 4 * i + 1], qc = plan[OWP_MOBS + 4 * i + 2];
        int code = int(qc.z);
        int type = code & 63;
        bool lying = (code & 128) != 0;
        if (ground && !lying)
            dark = max(dark, mcMobShadow(type, qa.xyz, groundP, ro, groundLight, tWorld * W.pxA, mcSkins));
        float rad = owRadius(type);
        float3 oc = ro - (qa.xyz + float3(0.0, lying ? 0.4 : rad * 0.9, 0.0));
        float sb = dot(oc, rd), sc = dot(oc, oc) - rad * rad * (lying ? 4.0 : 1.0);
        float disc = sb * sb - sc;
        if (disc < 0.0 || -sb - sqrt(disc) > best) continue;
        float3 lro, lrd, ex, ey, ez;
        owMobSpace(qa.xyz, qa.w, qb.x, lying, ro, rd, lro, lrd, ex, ey, ez);
        float2 bb = mcMobBounds(type, lro, lrd);
        if (bb.x >= bb.y || bb.x >= best) continue;
        MCMOB_Pose pose = mcMobStill();
        pose.walk = qb.y; pose.speed = qb.z; pose.yaw = qb.w; pose.graze = qc.x; pose.wag = qc.y;
        if ((code & 256) != 0) {
            // the charge: the creeper's model again, swollen by the game's two
            // pixels, in creeper_armor.png scrolling 0.01 a tick, added on
            float3 cen = float3(0.0, 0.8, 0.0);
            float sw = 1.14;
            MCMOB_Hit ah = mcMobTrace(type, pose, mcMobSkin(MCS_CREEPER_ARMOR), cen + (lro - cen) / sw, lrd / sw,
                                      best, mcSkins, mcMaps);
            if (ah.t < best) {
                float scroll = mcWorldSeconds(W, u.time, 100) * 20.0 * 0.01 * 64.0;
                float2 px = ah.px + float2(scroll, scroll * 0.5);
                px -= float2(64.0, 32.0) * floor(px / float2(64.0, 32.0));
                aura += mcSkin(mcSkins, MCS_CREEPER_ARMOR, px, ah.t * W.pxA * 16.0).rgb * 0.5;
            }
        }
        MCMOB_Hit mq = mcMobTrace(type, pose, owSkin(i, code), lro, lrd, best, mcSkins, mcMaps);
        if (mq.t < best) {
            best = mq.t; hitMob = i; mh = mq;
            mN = normalize(mq.n.x * ex + mq.n.y * ey + mq.n.z * ez);
        }
    }

    // The llamas' leads to the trader, where a llama or he may be in this tile.
    float leadT = INFINITY; float3 leadC = float3(0.0);
    uint tileMobs = as_type<uint>(plan[OWP_TILES + ti / 4][ti % 4]);
    if ((tileMobs & ((3u << uint(OW_LLAMA0)) | (1u << uint(OW_TRADER)))) != 0u) {
        float4 ta = plan[OWP_MOBS + 4 * OW_TRADER];
        if ((int(plan[OWP_MOBS + 4 * OW_TRADER + 2].z) & 64) != 0) {
            for (int k = 0; k < 2; ++k) {
                int li = OW_LLAMA0 + k;
                float4 la = plan[OWP_MOBS + 4 * li], lb = plan[OWP_MOBS + 4 * li + 1];
                if ((int(plan[OWP_MOBS + 4 * li + 2].z) & 64) == 0) continue;
                float3 from = mcMobPoint(MCMOB_LLAMA_LEASH, la.xyz, atan2(lb.x, la.w));
                float3 to = ta.xyz + float3(0.0, MCMOB_TRADER_HOLD, 0.0);
                MCMOB_Lead ld = mcMobLead(ro, rd, from, to, min(best, leadT));
                if (ld.t < leadT) {
                    leadT = ld.t;
                    leadC = ld.rgb * mcWorldLightAt(W, mix(from, to, ld.f), float3(0.0), day, 1.0);
                }
            }
        }
    }

    float3 L = sun.y > -0.05 ? sun : -sun;
    if (hitMob >= 0) {
        int hcode = int(plan[OWP_MOBS + 4 * hitMob + 2].z);
        MCMOB_Skin sk = owSkin(hitMob, hcode);
        int type = int(plan[OWP_MOBS + 4 * hitMob + 2].z) & 63;
        float4 c = mcMobColor(type, mh, sk, best * W.pxA * 16.0, mcSkins, mcMaps);
        float3 P = ro + rd * best;
        float sh = wx.x > 0.98 || !shadows ? 1.0 : mix(mcWorldShadow(W, P + mN * 0.05, mN, L), 1.0, wx.x);
        float3 lit = mcWorldLightAt(W, P + mN * 0.1, float3(0.0), day, sh);
        col = c.rgb * lit * mcFaceShade(mN) + c.rgb * c.a;
        col = mcWorldFog(col, rd, best, sun, fogEnd, wx.x, wx.y);
    } else {
        col *= 1.0 - dark;
    }
    if (leadT < best) col = mcWorldFog(leadC, rd, leadT, sun, fogEnd, wx.x, wx.y);
    col += aura;
    float4 bolt = plan[OWP_BOLT];
    if (bolt.w > 0.5) {
        OwBolt b; b.on = true; b.at = bolt.xyz; b.seed = as_type<uint>(plan[OWP_MISC].x);
        col += owBoltLight(b, ro, rd, best, W.pxA);
    }
    float4 rn = owRain(W, ro, rd, best, wx.x, day, mcWorldSeconds(W, u.time, 3200) * 20.0);
    col = col * (1.0 - rn.a) + rn.rgb;
    // Exposed for the night, as my-world is: the game's night (and a storm's
    // gloom) is a dark rectangle on a lit screen in a room; a film crew opens
    // up the dim parts, not the lamps' pools.
    float lum = dot(col, float3(0.3, 0.59, 0.11));
    col *= 1.0 + 0.7 * (1.0 - day) * (1.0 - smoothstep(0.25, 0.7, lum));
    return half4(half3(lerpDither(col, pos)), 1.0h);
}
