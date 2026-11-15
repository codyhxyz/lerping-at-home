// Block Weather — the sky over a block world, keeping the Mac's hours.
// Original work for Lerping@Home, drawn with Minecraft's own textures
// (Mojang's, bound at run time; see the "Minecraft looks" section of PORTING.md).
//
// lerp-category: Minecraft
// lerp-requires: minecraft
// lerp-data: clock
//
// You stand on a grassy knoll above a lake, oaks either side, and watch the
// game's sky go by. The cloud layer is the game's own `clouds.png`, one
// texel to a 12x12 cell, four blocks thick, drifting east. The square sun
// crosses the frame from the left horizon to the right between today's
// sunrise and sunset (`lerp-data: clock`), and the moon follows through the
// night in one of its eight phase textures, under the game's tilted square
// stars. Sky, fog, sunrise fan, cloud colour and the light on the land all
// follow the game's own curves for the time of day.
//
// The weather is the game's: clear spells, then rain everywhere at once,
// the sky and clouds greying, the land dimming, and `rain.png` falling on
// the game's ring of panels round the viewer; sometimes a thunderstorm's
// darker grey. On short winter days the world is a snowy taiga: snow on
// the ground, spruces, the lake iced over, and `snow.png` drifting down.
// Every frame is a pure function of (time, seed).
//
// Everything is lit as the game lights it, in its own (gamma) colour space:
// texture x biome tint x fixed face shade x smooth-lighting corner shade x
// lightmap. No sun shading, no shadows; the game has neither.
//
// Stills (gallery, snapshots) are midnight on an equinox, as the clock
// provider gives them; `clock` pins the hour, `pace` runs the day faster.
//
// Cost: 13.1 ms a frame at 3456x2234 on an M5 against maze's 10.1 in the
// same minute (bench state: midnight, raining). The kit's tree walk is
// about 0.8 of that over the leaner walk this look had before it.
// Worst pixel: up to 4 rounds of (14 march samples + 10 column cells) in
// the near field, 12 bands of 10 cells; for rays toward the knoll's flanks
// a walk of up to 6 tree regions and the kit's mcTree through one crown (up
// to 26 blocks, a texel at each leaf); one region lookup for the canopy's
// shade on the ground; 8 corner lookups (near tops only); 4 cells of plant tests; a
// 4-cell cloud walk; up to 12 rain panels, one texel fetch each. The land
// walks never sample a texture. Rain is the costly part (about 4 ms with
// the game's 10-block ring), so the panels are walked out to 8 blocks
// (BW_RAINW), the faintest two dropped; a dry frame skips them.
//
// lerp-param: clock    float -1 24  = -1 "Hour (-1 = now)"
// lerp-param: pace     float 1 240  = 1  "Day speed"
// lerp-param: winter   int -1 1     = -1 "Winter (-1 = by day length)"
// lerp-param: showers  float 0 1    = 0.6 "Rain"
// lerp-param: wind     float 0 3    = 1  "Wind"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -30 40  = 0 "Tilt"
// lerp-param: magnify  float -1 1.2  = 0 "Zoom"
// lerp-param: parallax float 0 2     = 1 "Head parallax"
//
// lerp-preset: "Day in Ten Minutes" pace=144
// lerp-preset: "Winter Day" winter=1, clock=11
// lerp-preset: "Summer Storms" winter=0, showers=1, clock=17

constant float BW_FOCAL   = 1.9;
constant float BW_PITCH   = 0.08;     // radians; horizon a little below centre
constant float BW_MAXH    = 24.0;     // no column is taller
constant float BW_WATER   = -0.12;    // lake surface (a water block's top sits a little low)
constant float BW_DEEP    = -2.0;     // below this the lake bed is just "deep"
constant float BW_FOG0    = 96.0;     // terrain fog, by horizontal distance
constant float BW_FOG1    = 140.0;    // (the world's render distance)
constant float BW_SKYFOG  = 140.0;    // the sky plane fogs over the same distance

constant float BW_CY      = 72.0;     // cloud base (about 63 blocks over the eye)
constant float BW_CT      = 4.0;      // cloud thickness, as in the game
constant float BW_CELL    = 12.0;     // blocks per clouds.png texel, as in the game
constant float BW_CFAR    = 900.0;
constant int   BW_CSTEPS  = 4;

constant float BW_SUN     = 0.15;     // quad half-sizes: 30 and 20 wide at 100, as in the game
constant float BW_MOON    = 0.10;
constant float BW_RAINR   = 10.0;     // the game's rain radius (Fancy): panel height and fade
constant float BW_RAINW   = 8.0;      // panels walked out to here (the faintest two blocks cost 1 ms)

constant float BW_AZMAX   = 0.52;     // sun/moon rise this far left, set this far right
constant float BW_DEG     = 0.0174533;

// ---------------------------------------------------------------------------
// The world's state at this instant.

struct BwEnv {
    float3 sunDir, moonDir;
    float  g;                       // the game's cos(celestial angle): 1 noon, 0 sun on the horizon, -1 midnight
    float3 sky, fog;                // sky colour overhead; fog colour before the sunrise blend
    float4 rise;                    // sunrise / sunset colour and strength
    float3 cloud;                   // cloud colour
    float  lightDay;                // `day` for mcLightmap, rain and thunder included
    float3 light15;                 // lightmap at full sky light
    float  star;                    // star brightness
    float  rain, thunder;
    float  winter;                  // 0..1
    int    phase;                   // moon phase, 0 full .. 7 waxing gibbous (never 4, new)
    int    one;                     // 1, but only known at run time (see bwEnv)
    float2 drift;                   // cloud layer offset (blocks)
    int2   coff;                    // clouds.png offset (texels)
    float  t;                       // seconds
    float  starTurn;
};

static inline float3 bwDir(float az, float el) {
    return float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
}

// ---------------------------------------------------------------------------
// Terrain: one column of blocks per integer cell, top face at y = height.
//
// Near the viewer (z < BW_ZB: the knoll and the lake) it is a full height
// field, walked cell by cell close to the ground and skipped through in
// open air. Beyond, the land is laid out in bands BW_BD deep across the
// view, each a ridge whose height varies along x only, like the flats of a
// stage receding into haze: a ray meets a band at its front face or walks a
// few cells along it, instead of crossing every column out to the horizon.
// (A full height field out to the fog cost four times the frame budget.)

constant float BW_ZB = 34.0;      // where the bands begin
constant float BW_BD = 9.0;       // band depth
constant int   BW_NB = 12;        // bands, out past the fog

// Linear ramps: the columns quantise them into terraces anyway.
static inline float bwBaseZ(float z) {
    float lake = -6.0 * saturate((z - 8.0) * (1.0 / 14.0)) * saturate((54.0 - z) * (1.0 / 18.0));
    return 2.5 + lake + 6.0 * saturate((z - 44.0) * (1.0 / 41.0));
}

static inline float bwSide(float x) { return 7.0 * saturate((abs(x - 6.0) - 18.0) * (1.0 / 42.0)); }

// Continuous height; a column's top is floor() of it.
static inline float bwHeightC(float2 p, float2 off) {
    float2 q = p + off;
    float n = 3.2 * sin(dot(q, float2(0.052, 0.021)))
            + 2.0 * sin(dot(q, float2(-0.030, 0.075)))
            + 1.0 * sin(dot(q, float2(0.130, 0.070)));
    float2 k = float2(p.x * (1.0 / 22.0), (p.y + 7.0) * (1.0 / 17.0));
    float ku = saturate(1.0 - dot(k, k));
    // the waves die down on the knoll, so the viewer always overlooks the lake
    float amp = 0.25 + 0.75 * saturate((dot(k, k) - 0.1) * 1.4);
    return min(bwBaseZ(p.y) + 6.5 * ku * ku + bwSide(p.x) + amp * n, BW_MAXH - 1.0);
}

// Band i's ridge: the field's shaping at the band's middle, with waves of
// its own (a shifted phase), so the far land reads as layered ridges.
static inline float bwBandHeight(float x, float i, float2 off) {
    float zm = BW_ZB + BW_BD * (i + 0.5);
    float2 q = float2(x, zm + i * 53.7) + off;
    float n = 3.2 * sin(dot(q, float2(0.052, 0.021)))
            + 2.0 * sin(dot(q, float2(-0.030, 0.075)))
            + 1.0 * sin(dot(q, float2(0.130, 0.070)));
    return floor(min(bwBaseZ(zm) + 0.5 * bwSide(x) + n, BW_MAXH - 1.0));
}

static inline float bwHeight(int2 c, float2 off) {
    float z = float(c.y) + 0.5;
    if (z > BW_ZB) return bwBandHeight(float(c.x) + 0.5, floor((z - BW_ZB) / BW_BD), off);
    return floor(bwHeightC(float2(float(c.x) + 0.5, z), off));
}

// The near field. Returns the hit distance, 1e9 for none before tMax, or a
// deep-water hit (n = 0) once the ray is well under the lake's surface.
//
// Two plain loops a round, so the lanes of a SIMD group stay in step: march
// over the smooth field until the ray is within a block of it, then walk the
// columns exactly for a few cells from there.
static inline float bwTraceNear(float3 ro, float3 rd, float tMax, float2 off,
                                thread float3& n, thread int2& cellOut) {
    float t = 0.0;
    float hl = max(length(rd.xz), 1e-4);
    float sd = max(-rd.y / hl, 0.0);            // descent per block across
    float2 d = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float2 inv = 1.0 / d;
    int2 stp = int2(sign(d));
    float2 tDelta = abs(inv);
    for (int round = 0; round < 4; ++round) {
        // March.
        for (int i = 0; i < 14; ++i) {
            if (t > tMax) return 1e9;
            float3 p = ro + rd * t;
            if (rd.y > 0.0 && p.y > BW_MAXH) return 1e9;
            if (p.y < BW_DEEP) { n = float3(0.0); cellOut = int2(0); return t; }
            float gap = p.y - bwHeightC(p.xz, off);
            if (gap < 1.3) break;
            t += clamp((gap - 1.0) / (0.7 + sd), 0.5, 16.0) / hl;
        }
        // Walk.
        int2 cell = int2(floor(ro.xz + rd.xz * t));
        float2 tNext = (float2(cell) + select(float2(0.0), float2(1.0), d > 0.0) - ro.xz) * inv;
        float tEnter = t;
        int axis = -1;
        for (int i = 0; i < 10; ++i) {
            float h = bwHeight(cell, off);
            float yEnter = ro.y + rd.y * tEnter;
            if (yEnter < h) {
                n = axis == 0 ? float3(-float(stp.x), 0.0, 0.0)
                  : axis == 1 ? float3(0.0, 0.0, -float(stp.y)) : float3(0.0, 1.0, 0.0);
                cellOut = cell;
                return tEnter;
            }
            float tExit = min(tNext.x, tNext.y);
            float yExit = ro.y + rd.y * tExit;
            if (yExit < h) {
                n = float3(0.0, 1.0, 0.0);
                cellOut = cell;
                return (h - ro.y) / rd.y;
            }
            if (tExit > tMax) return 1e9;
            if (yExit < BW_DEEP) { n = float3(0.0); cellOut = int2(0); return tExit; }
            if (yExit > h + 2.5) { tEnter = tExit; break; }   // clear of the ground: march again
            if (tNext.x < tNext.y) { tEnter = tNext.x; tNext.x += tDelta.x; cell.x += stp.x; axis = 0; }
            else                   { tEnter = tNext.y; tNext.y += tDelta.y; cell.y += stp.y; axis = 1; }
        }
        t = tEnter;
    }
    // Out of steps while skimming the land: close enough to call it a top
    // (or, rising, to call it sky).
    if (rd.y > 0.0) return 1e9;
    float3 p = ro + rd * t;
    n = float3(0.0, 1.0, 0.0);
    cellOut = int2(floor(p.xz));
    return t;
}

// The bands, from tStart (where the ray crosses z = BW_ZB).
static inline float bwTraceBands(float3 ro, float3 rd, float tStart, float tMax, float2 off,
                                 thread float3& n, thread int2& cellOut) {
    float invZ = 1.0 / rd.z;
    float invX = 1.0 / (abs(rd.x) > 1e-5 ? rd.x : 1e-5);
    int sx = rd.x >= 0.0 ? 1 : -1;
    for (int i = 0; i < BW_NB; ++i) {
        float z0 = BW_ZB + BW_BD * float(i), zm = z0 + 0.5 * BW_BD;
        float ta = max((z0 - ro.z) * invZ, tStart), tb = (z0 + BW_BD - ro.z) * invZ;
        if (tb < tStart) continue;
        if (ta > tMax) return 1e9;
        float ya = ro.y + rd.y * ta, yb = ro.y + rd.y * tb;
        float xa = ro.x + rd.x * ta, xb = ro.x + rd.x * tb;
        float top = bwBaseZ(zm) + bwSide(max(abs(xa - 6.0), abs(xb - 6.0)) + 6.0) + 6.3;
        if (min(ya, yb) >= top) {
            if (rd.y >= 0.0 && ya > 22.0) return 1e9;   // above every band left
            continue;                                   // passes over this one
        }
        int cx = int(floor(xa));
        float bi = float(i);
        float h = bwBandHeight(float(cx) + 0.5, bi, off);
        if (ya < h) {
            n = float3(0.0, 0.0, -1.0);
            cellOut = int2(cx, int(z0));
            return ta;
        }
        float tX = (float(cx + (sx > 0 ? 1 : 0)) - ro.x) * invX;
        for (int k = 0; k < 10; ++k) {
            float tE = min(tX, tb);
            if (ro.y + rd.y * tE < h) {
                float th = (h - ro.y) / rd.y;
                n = float3(0.0, 1.0, 0.0);
                cellOut = int2(cx, int(clamp(floor(ro.z + rd.z * th), z0, z0 + BW_BD - 1.0)));
                return th;
            }
            if (tX >= tb) break;
            cx += sx;
            h = bwBandHeight(float(cx) + 0.5, bi, off);
            if (ro.y + rd.y * tX < h) {
                n = float3(-float(sx), 0.0, 0.0);
                cellOut = int2(cx, int(clamp(floor(ro.z + rd.z * tX), z0, z0 + BW_BD - 1.0)));
                return tX;
            }
            tX += abs(invX);
        }
    }
    return 1e9;
}

static inline float bwTrace(float3 ro, float3 rd, float tMax, float2 off,
                            thread float3& n, thread int2& cellOut) {
    float tZ = rd.z > 0.02 ? (BW_ZB - ro.z) / rd.z : 1e9;
    // A rising ray is done once it clears the tallest the land can be along
    // its way: near field and bands, each bounded by its own shaping terms.
    float xFar = abs(ro.x + rd.x * min(tZ, tMax) - 6.0);
    float tNear = min(tMax, tZ), tBands = tMax;
    if (rd.y > 0.0) {
        float hNear = 2.5 + 6.5 + 6.2 + bwSide(xFar + 6.0) + 0.5;
        tNear = min(tNear, max(hNear - ro.y, 0.0) / rd.y);
        float hBand = 2.5 + 6.0 + 6.3 + 7.0 + 0.5;
        tBands = min(tBands, max(hBand - ro.y, 0.0) / rd.y);
    }
    float t = bwTraceNear(ro, rd, tNear, off, n, cellOut);
    if (t < 1e8 || tZ > tBands) return t;
    return bwTraceBands(ro, rd, tZ, tBands, off, n, cellOut);
}

// ---------------------------------------------------------------------------
// Trees: at most one in each 7x7 region, grown by the game's rule (the
// kit's mcTreeGrow: oak in summer, spruce in a winter world), its trunk
// kept in from the region's edges so the whole crown stays inside it (a
// spruce's reach of 3 sits it in the middle). They grow only on the knoll's
// flanks either side of the view out over the lake (framing it, never
// blocking it), on dry land.
//
// They are found after the land, in a pass of their own that only rays able
// to reach the flanks take: walk the regions along the ray and hand each
// tree to the kit's mcTree, which steps through its blocks with the leaves
// cut out by their alpha.

constant int BW_TREG = 7;

// How far a point is outside the central wedge of the view (trunks stand
// at 3.5 and more, so no crown comes nearer than about -0.7).
static inline float bwWedge(float2 p) { return abs(p.x - 0.5) - 0.4 * max(p.y + 8.5, 0.0); }

struct BwTree { McTree tr; float on; };

static inline BwTree bwTreeIn(int2 r, float2 off, bool spruce) {
    BwTree T;
    T.on = 0.0;
    float2 h = hash22(float2(r) * 1.31 + off * 0.173);
    float h2 = hash21(float2(r) * 0.77 + off * 0.31 + 3.1);
    int2 trunk = r * BW_TREG + (spruce ? int2(3) : 2 + int2(floor(h * 2.999)));
    float2 c = float2(trunk) + 0.5;
    if (h2 < 0.72 && bwWedge(c) > 3.5 && c.y > -4.0 && c.y < 12.0) {
        float g = floor(bwHeightC(c, off));
        if (g >= 2.0) {
            T.on = 1.0;
            T.tr = mcTreeGrow(spruce ? MC_TREE_SPRUCE : MC_TREE_OAK,
                              float3(float(trunk.x), g, float(trunk.y)), h2 * 97.0 + h.x * 13.0);
        }
    }
    return T;
}

// The nearest tree face before tBest, if any (kind 1 log, 2 leaves).
static inline float bwTrees(float3 ro, float3 rd, float tBest, float2 off, bool spruce, float px,
                            texture2d_array<float> tiles, texture2d_array<float> maps,
                            thread McModelHit& hit, thread int& kind, thread float& passed) {
    float tEnd = min(tBest, rd.z > 1e-3 ? (15.0 - ro.z) / rd.z : 60.0);
    // a rising ray is done once it is over the tallest crown can be
    if (rd.y > 0.0) tEnd = min(tEnd, (28.0 - ro.y) / rd.y);
    float3 tint = mcTreeLeafTint(spruce ? MC_TREE_SPRUCE : MC_TREE_OAK, mcFoliageTint(maps, 0.8, 0.4));
    float3 dr = select(rd, float3(1e-6), abs(rd) < 1e-6);
    float3 inv = 1.0 / dr;
    int3 stp = int3(sign(dr));
    float R = float(BW_TREG);
    int2 r = int2(floor(ro.xz / R));
    float2 tR = ((float2(r) + select(float2(0.0), float2(1.0), dr.xz > 0.0)) * R - ro.xz) * inv.xz;
    float tIn = 0.0;
    for (int i = 0; i < 6; ++i) {
        if (tIn >= tEnd) break;
        BwTree T = bwTreeIn(r, off, spruce);
        if (T.on > 0.5) {
            int k = mcTree(tiles, T.tr, tint, ro, rd, 0.0, tEnd, px, hit, passed);
            if (k > 0) { kind = k; return hit.t; }
        }
        tIn = min(tR.x, tR.y);
        if (tR.x < tR.y) { tR.x += R * abs(inv.x); r.x += stp.x; }
        else             { tR.y += R * abs(inv.z); r.y += stp.z; }
    }
    return 1e9;
}

// ---------------------------------------------------------------------------
// Sun, moon and weather through the day.

// Where the sun and moon are: stylised arcs across the frame, the sun from
// sunrise to sunset, the moon through the night. Elevation follows day
// length. `g` is the game's own day curve over the same hours.
struct BwArc {
    float3 sunDir, moonDir;
    float  g;
    float  hour, dayLen;
};

static inline BwArc bwArc(constant LerpUniforms& u, constant LerpClock& clock) {
    BwArc A;
    float hour = glmod(clock.hourAtZero + u.time * u.pace / 3600.0, 24.0);
    float rise = clock.sunrise, set = clock.sunset;
    float dayLen = set - rise;
    float maxEl = mix(24.0, 40.0, saturate((dayLen - 9.0) / 6.0)) * BW_DEG;
    float sd = (hour - rise) / dayLen;                   // 0..1 by day
    float sn = glmod(hour - set, 24.0) / (24.0 - dayLen); // 0..1 by night
    float sunEl, moonEl, sunAz, moonAz;
    // the arc spans the frame's width, narrower on a portrait screen
    float BW_AZ = min(BW_AZMAX, atan(0.8 * u.resolution.x / min(u.resolution.x, u.resolution.y) / BW_FOCAL));
    if (sd >= 0.0 && sd <= 1.0) {
        sunEl = maxEl * sin(PI * sd) + 2.5 * BW_DEG;
        sunAz = mix(-BW_AZ, BW_AZ, sd);
        moonEl = -0.3 * sin(PI * sd) + 2.5 * BW_DEG;
        moonAz = mix(BW_AZ, -BW_AZ, sd);   // back below the horizon
        A.g = sin(PI * sd);
    } else {
        sunEl = -0.42 * sin(PI * sn) + 2.5 * BW_DEG;
        sunAz = mix(BW_AZ, -BW_AZ, sn);
        moonEl = maxEl * 0.72 * sin(PI * sn) + 2.5 * BW_DEG;
        moonAz = mix(-BW_AZ, BW_AZ, sn);
        A.g = -sin(PI * sn);
    }
    A.sunDir = bwDir(sunAz, sunEl);
    A.moonDir = bwDir(moonAz, moonEl);
    A.hour = hour;
    A.dayLen = dayLen;
    return A;
}

static inline float bwWinter(constant LerpUniforms& u, BwArc A) {
    return u.winter < 0 ? smoothstep(10.6, 10.0, A.dayLen) : float(u.winter);
}

static inline float2 bwTerrainOff(float seed) {
    return float2(fract(seed * 3.7), fract(seed * 9.13)) * 900.0 + 40.0;
}

static inline float bwLuma(float3 c) { return dot(c, float3(0.3, 0.59, 0.11)); }

// The game's sky, fog, cloud and light colours for the hour and the weather
// (its ClientLevel / FogRenderer / LightTexture arithmetic, in its own
// gamma-space colour).
static inline BwEnv bwEnv(constant LerpUniforms& u, BwArc A, float3 look) {
    BwEnv E;
    E.winter = bwWinter(u, A);
    E.sunDir = A.sunDir;
    E.moonDir = A.moonDir;
    float g = A.g;
    E.g = g;
    float t = u.time;
    E.t = t;

    // Weather: two slow swings, never quite repeating. The rain comes and
    // goes over half a minute or so; `showers` is how much of the time.
    float ph = u.seed * 37.0;
    float w = 0.65 * sin(t * TWO_PI / 700.0 + ph) + 0.35 * sin(t * TWO_PI / 1630.0 + ph * 1.7);
    float th = mix(1.1, -0.4, u.showers);
    float rain = u.showers > 0.001 ? smoothstep(th - 0.09, th + 0.09, w) : 0.0;
    float thunder = rain * smoothstep(0.55, 0.85, sin(t * TWO_PI / 2300.0 + ph * 0.7));
    E.rain = rain;
    E.thunder = thunder;

    // Sky: the biome's sky colour dimmed by the day, greyed by rain and storm.
    // KIT: the rain/storm greying of sky, fog and clouds.
    float day = mcSkyDay(g);
    float3 sky = mcSkyAt(day);
    sky = mix(sky, float3(bwLuma(sky) * 0.6), rain * 0.75);
    sky = mix(sky, float3(bwLuma(sky) * 0.2), thunder * 0.75);
    E.sky = sky;

    // Sunrise and sunset: the game's glow, its fan drawn in bwSky; the fog
    // warmed toward it by the camera's facing (one fog for the whole view,
    // as the game has it), drawn a little toward the sky (render distance),
    // then darkened by rain and storm.
    E.rise = mcSunsetAt(g);
    float3 fog = mcFogToward(mcFogAt(day), E.rise, look, A.sunDir);
    fog += (sky - fog) * 0.146;
    E.fog = fog * float3(1.0 - rain * 0.5, 1.0 - rain * 0.5, 1.0 - rain * 0.4) * (1.0 - thunder * 0.5);

    // Clouds: white, greyed by rain, dimmed by the night, storm-dark.
    float3 cl = mix(float3(1.0), float3(0.6), rain * 0.95);
    cl *= float3(day * 0.9 + 0.1, day * 0.9 + 0.1, day * 0.85 + 0.15);
    cl = mix(cl, float3(bwLuma(cl) * 0.2), thunder * 0.95);
    E.cloud = cl;

    // The lightmap's day: the game's sky darkening, rain and storm included.
    float dk = mcLightDay(g) * (1.0 - rain * 5.0 / 16.0) * (1.0 - thunder * 5.0 / 16.0);
    E.lightDay = dk;
    E.light15 = mcLightmap(0.0, 15.0, dk, 0.0);
    float sb = saturate(1.0 - (g * 2.0 + 0.25));
    E.star = sb * sb * 0.5 * (1.0 - rain);

    // Moon phase from the seed (never new: there would be nothing to see).
    // Loops that sample a texture run to bounds the compiler cannot see
    // through, so it does not unroll them into many samples in flight.
    E.one = 1 + int(u.resolution.x < 0.0);
    E.phase = int(floor(fract(u.seed * 7.31 + 0.13) * 7.0));
    if (E.phase >= 4) E.phase += 1;

    // The cloud layer drifts east, as the game's does.
    E.drift = float2(u.wind * 1.2 * t, 0.0);
    E.coff = int2(int(fract(u.seed * 5.3) * 256.0), int(fract(u.seed * 1.91) * 256.0));
    E.starTurn = A.hour * (TWO_PI / 24.0);
    return E;
}

// ---------------------------------------------------------------------------
// Sky.

// Gnomonic coordinates of rd in a quad's own frame, in quad half-sizes.
static inline float2 bwDiscUV(float3 rd, float3 dir, float size) {
    float3 r = normalize(cross(float3(0.0, 1.0, 0.0), dir));
    float3 up = cross(dir, r);
    float z = dot(rd, dir);
    if (z <= 0.0) return float2(9.0);
    return float2(dot(rd, r), dot(rd, up)) / (z * size);
}

static inline int bwMoonLayer(int p) {
    switch (p) {
    case 0:  return MCS_ENVIRONMENT_CELESTIAL_MOON_FULL_MOON;
    case 1:  return MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_GIBBOUS;
    case 2:  return MCS_ENVIRONMENT_CELESTIAL_MOON_THIRD_QUARTER;
    case 3:  return MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_CRESCENT;
    case 5:  return MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_CRESCENT;
    case 6:  return MCS_ENVIRONMENT_CELESTIAL_MOON_FIRST_QUARTER;
    default: return MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_GIBBOUS;
    }
}

// The open sky, as the game draws it: the sky plane fogged toward the
// horizon, the sunrise fan, then sun, moon and stars added on top.
static inline float3 bwSky(float3 rd, BwEnv E, float px, texture2d_array<float> skins) {
    float y = rd.y;
    float hd = 16.0 * sqrt(max(1.0 - y * y, 0.0)) / max(y, 1e-4);
    float3 c = mix(E.sky, E.fog, y > 0.0 ? saturate(hd / BW_SKYFOG) : 1.0);

    c = mix(c, E.rise.rgb, mcSunsetFan(rd, E.sunDir, E.rise));

    float clear = 1.0 - E.rain;
    if (clear <= 0.0) return c;
    float2 su = bwDiscUV(rd, E.sunDir, BW_SUN);
    if (max(abs(su.x), abs(su.y)) < 1.0) {
        float2 p = float2(su.x * 0.5 + 0.5, 0.5 - su.y * 0.5) * 32.0;
        c += mcSkin(skins, MCS_ENVIRONMENT_CELESTIAL_SUN, p, px * 32.0 / (2.0 * BW_SUN)).rgb * clear;
    }
    float2 mu = bwDiscUV(rd, E.moonDir, BW_MOON);
    if (max(abs(mu.x), abs(mu.y)) < 1.0) {
        float2 p = float2(mu.x * 0.5 + 0.5, 0.5 - mu.y * 0.5) * 32.0;
        c += mcSkin(skins, bwMoonLayer(E.phase), p, px * 32.0 / (2.0 * BW_MOON)).rgb * clear;
    }

    // Stars: the game's tilted grey squares, 0.15 to 0.25 wide at 100,
    // about 1500 over the sphere, turning with the sky.
    if (E.star > 0.003 && y > -0.02) {
        float3 ax = normalize(float3(0.0, 0.64, -0.77));
        float a = E.starTurn;
        float3 d = rd * cos(a) + cross(ax, rd) * sin(a) + ax * dot(ax, rd) * (1.0 - cos(a));
        const float K = 30.0;
        float3 cell = floor(d * K);
        float h = hash21(cell.xy * 1.3 + cell.z * 7.1 + 0.3);
        if (h < 0.09) {
            float3 j = float3(hash22(cell.xz + 3.3), hash21(cell.yz + 9.1));
            float3 sdir = normalize((cell + 0.25 + 0.5 * j) / K);
            float3 fp = sdir * K - floor(sdir * K);
            if (all(floor(sdir * K) == cell) && all(abs(fp - 0.5) < 0.45)) {
                float3 e1 = normalize(cross(sdir, abs(sdir.y) < 0.9 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0)));
                float3 e2 = cross(sdir, e1);
                float3 dd = d - sdir;
                float2 q = float2(dot(dd, e1), dot(dd, e2));
                float ang = h * 70.0;
                float cs = cos(ang), sn = sin(ang);
                q = float2(cs * q.x - sn * q.y, sn * q.x + cs * q.y);
                float sz = 0.0015 + 0.001 * hash21(cell.zx + 1.9);
                float cov = saturate((sz - abs(q.x)) / px + 0.5) * saturate((sz - abs(q.y)) / px + 0.5);
                c += E.star * cov;
            }
        }
    }
    return c;
}

// ---------------------------------------------------------------------------
// KIT: the cloud layer, stars and rain/snow panels are every sky's.
// Clouds: the game's layer, one clouds.png texel to a 12x12-block cell,
// four blocks thick, faces shaded as the game shades them (top 1, bottom
// 0.7, x sides 0.9, z sides 0.8) and drawn at 80% opacity, nearest face
// only. Returns premultiplied colour and coverage.

static inline float bwCloudCell(int2 c, BwEnv E, texture2d_array<float> maps) {
    uint2 q = uint2((c + E.coff) & 255);
    return maps.read(q, uint(MCM_ENVIRONMENT_CLOUDS)).a;
}

static inline float4 bwClouds(float3 ro, float3 rd, BwEnv E, float px, texture2d_array<float> maps) {
    if (rd.y < 0.01) return float4(0.0);
    float t0 = (BW_CY - ro.y) / rd.y;
    float t1 = (BW_CY + BW_CT - ro.y) / rd.y;
    if (t0 > BW_CFAR) return float4(0.0);
    float3 p0 = ro + rd * t0;
    float2 g = (p0.xz - E.drift) / BW_CELL;

    // The underside, its edges filtered by the sampler.
    float wB = t0 * px / (BW_CELL * sqrt(max(rd.y, 0.02)));
    float2 pg = g + float2(E.coff);
    pg -= 256.0 * floor(pg / 256.0);
    float cov = mcMap(maps, MCM_ENVIRONMENT_CLOUDS, pg, wB).a;
    float3 acc = E.cloud * 0.7 * cov;
    float a = cov;

    // Through the gaps: walk the slab to the first side face.
    // (Far off a side face is a sliver: the underside alone will do.)
    if (cov < 0.99 && t0 < 400.0) {
        int2 cell = int2(floor(g));
        float2 d = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
        int2 stp = int2(sign(d));
        float2 tDelta = abs(BW_CELL / d);
        float2 tNext = t0 + (float2(cell) + select(float2(0.0), float2(1.0), d > 0.0) - g) * BW_CELL / d;
        for (int i = 0; i < BW_CSTEPS * E.one; ++i) {
            float tN = min(tNext.x, tNext.y);
            if (tN > t1) break;
            int axis;
            if (tNext.x < tNext.y) { tNext.x += tDelta.x; cell.x += stp.x; axis = 0; }
            else                   { tNext.y += tDelta.y; cell.y += stp.y; axis = 1; }
            if (bwCloudCell(cell, E, maps) > 0.5) {
                float y = ro.y + rd.y * tN;
                float edge = smoothstep(0.0, tN * px * 1.5, BW_CY + BW_CT - y);
                float3 side = E.cloud * (axis == 0 ? 0.9 : 0.8);
                acc += (1.0 - a) * side * edge;
                a += (1.0 - a) * edge;
                break;
            }
        }
    }
    float fade = 1.0 - smoothstep(BW_CFAR * 0.35, BW_CFAR, t0);
    return float4(acc, a) * (0.8 * fade);
}

// ---------------------------------------------------------------------------
// Rain and snow: the game's panels. Every block column within ten blocks
// of the eye carries a one-block-wide vertical panel through its centre,
// turned square-on to the eye, from its ground (or the water) to ten blocks
// above the eye, with rain.png or snow.png running down it: 64 texels a
// block, rain falling about nine blocks a second (each column restarting
// its cycle on its own), snow drifting slowly and sideways. Opacity falls
// off with distance from the eye, as the game's does.

static inline float4 bwPrecip(float3 ro, float3 rd, float tEnd, BwEnv E, float px,
                              texture2d_array<float> maps) {
    float4 acc = float4(0.0);
    if (E.rain < 0.01) return acc;
    bool snow = E.winter > 0.5;
    uint layer = uint(snow ? MCM_ENVIRONMENT_SNOW : MCM_ENVIRONMENT_RAIN);
    float2 d = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float2 inv = 1.0 / d;
    int2 stp = int2(sign(d));
    float2 tDelta = abs(inv);
    int2 cell = int2(floor(ro.xz));
    float2 tNext = (float2(cell) + select(float2(0.0), float2(1.0), d > 0.0) - ro.xz) * inv;
    float ticks = E.t * 20.0;
    float snowV = -fract(ticks / 512.0);
    float y0 = floor(ro.y) - BW_RAINR, y1 = floor(ro.y) + BW_RAINR;
    const float R2 = BW_RAINW * BW_RAINW;
    for (int i = 0; i < 12 * E.one; ++i) {
        // The column's panel: through its centre c, square-on to the eye.
        // Met where the ray crosses that plane, if within half a block of
        // c: tested without a root or a divide, as most cells miss.
        float2 dc = float2(cell) + 0.5 - ro.xz;
        float d2 = dot(dc, dc);
        if (d2 > R2) break;
        float dd = dot(rd.xz, dc);
        float cr = dc.x * rd.z - dc.y * rd.x;
        if (dd > 1e-4 && cr * cr * d2 < 0.25 * dd * dd) {
            float tq = d2 / dd;
            float py = ro.y + rd.y * tq;
            // The panel runs from its column's ground (or the water) up: a
            // ray that has met nothing before tq is above both there, so
            // only the panel's fixed top and bottom need testing.
            if (tq > 0.05 && tq < tEnd && py > y0 && py < y1) {
                float sidx = sqrt(d2) * cr / dd;      // across the panel, -0.5..0.5
                uint hc = (uint(cell.x) * 73856093u) ^ (uint(cell.y) * 19349663u);
                hc *= 0x9E3779B1u;
                float r1 = float(hc & 0xffffu) * (1.0 / 65536.0);
                float r2 = float(hc >> 16) * (1.0 / 65536.0);
                float v = (y1 - py) * 0.25 + r1 * 4.0;
                float uu = sidx + 0.5;
                if (snow) {
                    v += snowV + r2 + ticks * (r1 - 0.5) * 0.0008;
                    uu += r1 + ticks * 0.0035 * (r2 - 0.5);
                } else {
                    // each column runs the game's 32-tick cycle from its own phase
                    v -= fract((ticks + r2 * 32.0) / 32.0) * (3.0 + r1);
                }
                uint2 pix = uint2(fract(uu) * 64.0, fract(v) * 256.0);
                uint lod = tq * px * 64.0 > 1.5 ? 1u : 0u;   // within ten blocks, never coarser
                float4 tx = maps.read(pix >> lod, layer, lod);
                float al = saturate((1.0 - d2 / (BW_RAINR * BW_RAINR)) * 0.5 + 0.5) * E.rain * tx.a;
                acc.rgb += (1.0 - acc.a) * al * tx.rgb;
                acc.a += (1.0 - acc.a) * al;
            }
        }
        if (min(tNext.x, tNext.y) >= tEnd) break;
        if (tNext.x < tNext.y) { tNext.x += tDelta.x; cell.x += stp.x; }
        else                   { tNext.y += tDelta.y; cell.y += stp.y; }
    }
    acc.rgb *= E.light15;
    return acc;
}

// ---------------------------------------------------------------------------
// Blocks.

// Smooth lighting on a top face: each corner darkened by the solid blocks
// beside it, as the game does it (both sides solid hides the diagonal).
static inline float bwCorner(float a, float b, float c) {
    return 1.0 - 0.2 * (a + b + (a + b > 1.5 ? 1.0 : c));
}

static inline float bwOcclusion(float3 P, float3 n, int2 cell, float h, float t, float2 off) {
    if (n.y > 0.5) {
        if (t > 13.0) return 1.0;
        float x0 = bwHeight(cell + int2(-1, 0), off) > h ? 1.0 : 0.0;
        float x1 = bwHeight(cell + int2( 1, 0), off) > h ? 1.0 : 0.0;
        float z0 = bwHeight(cell + int2(0, -1), off) > h ? 1.0 : 0.0;
        float z1 = bwHeight(cell + int2(0,  1), off) > h ? 1.0 : 0.0;
        float d00 = bwHeight(cell + int2(-1, -1), off) > h ? 1.0 : 0.0;
        float d10 = bwHeight(cell + int2( 1, -1), off) > h ? 1.0 : 0.0;
        float d01 = bwHeight(cell + int2(-1,  1), off) > h ? 1.0 : 0.0;
        float d11 = bwHeight(cell + int2( 1,  1), off) > h ? 1.0 : 0.0;
        float2 f = fract(P.xz);
        float v = mix(mix(bwCorner(x0, z0, d00), bwCorner(x1, z0, d10), f.x),
                      mix(bwCorner(x0, z1, d01), bwCorner(x1, z1, d11), f.x), f.y);
        return mix(1.0, v, 1.0 - smoothstep(8.0, 13.0, t));
    }
    // a side face: its lowest block darkens toward the ground in front
    float hn = bwHeight(cell + int2(int(n.x), int(n.z)), off);
    return mix(0.8, 1.0, saturate(P.y - hn));
}

// Lake-bed blocks in patches, as the game's lakes have them.
static inline int bwBedBlock(int2 cell, float h, float2 off) {
    if (h >= -1.0) return MC_SAND;
    float k = hash21(floor((float2(cell) + off) / 3.0) + 0.7);
    return k < 0.35 ? MC_SAND : (k < 0.65 ? MC_GRAVEL : (k < 0.85 ? MC_CLAY : MC_DIRT));
}

struct BwFace { float2 uv, dx, dy; };

// A face's texture coordinates and their change across one screen pixel.
static inline BwFace bwFaceUV(float3 P, float3 n, float3 dPdx, float3 dPdy) {
    BwFace F;
    if (abs(n.y) > 0.5) {
        F.uv = P.xz; F.dx = dPdx.xz; F.dy = dPdy.xz;
    } else if (abs(n.x) > 0.5) {
        float s = n.x > 0.0 ? -1.0 : 1.0;
        F.uv = float2(s * P.z, -P.y); F.dx = float2(s * dPdx.z, -dPdx.y); F.dy = float2(s * dPdy.z, -dPdy.y);
    } else {
        float s = n.z > 0.0 ? 1.0 : -1.0;
        F.uv = float2(s * P.x, -P.y); F.dx = float2(s * dPdx.x, -dPdx.y); F.dy = float2(s * dPdy.x, -dPdy.y);
    }
    return F;
}

static inline float3 bwGrassTint(texture2d_array<float> maps) { return mcGrassTint(maps, 0.8, 0.4); }   // plains

// A block face's colour before light: which block, its texture, its tint.
static inline float3 bwAlbedo(float3 P, float3 n, int2 cell, float h, bool winter,
                              BwFace F, float2 off,
                              texture2d_array<float> tiles, texture2d_array<float> maps) {
    bool top = abs(n.y) > 0.5;
    int L;
    float3 tint = float3(1.0);
    bool fringe = false;          // a grass block's side: dirt under the tinted fringe
    if (top) {
        if (h < 0.0) L = bwBedBlock(cell, h, off);
        else if (winter) L = MC_SNOW;
        else if (h < 1.0) L = MC_SAND;
        else { L = MC_GRASS_BLOCK_TOP; tint = bwGrassTint(maps); }
    } else {
        float depth = h - floor(P.y) - 1.0;   // 0 for the top block
        if (h < 0.0) L = bwBedBlock(cell, h, off);
        else if (h < 1.0) L = depth < 2.0 ? MC_SAND : MC_STONE;
        else if (depth < 0.5) { L = winter ? MC_GRASS_BLOCK_SNOW : MC_GRASS_BLOCK_SIDE; fringe = !winter; }
        else if (depth < 3.5) L = MC_DIRT;
        else L = MC_STONE;
    }
    if (fringe) {
        float fp = sqrt(max(length(F.dx) * length(F.dy), 1e-10));
        return mcGrassSide(tiles, F.uv, fp, bwGrassTint(maps));
    }
    return mcTile(tiles, L, F.uv, max(length(F.dx), length(F.dy))).rgb * tint;
}

// ---------------------------------------------------------------------------

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpClock& clock [[buffer(1)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    float minRes = min(u.resolution.x, u.resolution.y);
    float2 uv = lerpUV(pos, u.resolution);
    float2 off = bwTerrainOff(u.seed);
    bool winter = (u.winter < 0 ? smoothstep(10.6, 10.0, clock.sunset - clock.sunrise) : float(u.winter)) > 0.5;

    // Camera: on the knoll, looking out over the lake.
    float3 ro = float3(0.5, 0.0, -8.5);
    ro.y = max(bwHeight(int2(0, -9), off), bwHeight(int2(0, -8), off)) + 2.8;
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 fwd = normalize(float3(0.0, sin(BW_PITCH), cos(BW_PITCH)));
    float3 right = normalize(cross(upHint, fwd));
    float lens = lerpLook(u.yaw, u.pitch, u.magnify, upHint, right, fwd);
    float3 up = cross(fwd, right);
    float focal = lens * BW_FOCAL;
    float px = 2.0 / (focal * minRes);
    float3 rd = lerpViewerRay(u, u.parallax, uv, focal, right, up, fwd, ro);

    // 1. The ground, then any tree in front of it. Only a ray that can reach
    //    the knoll's flanks looks for trees: the wedge's edge is convex along
    //    a ray, so its two ends in the tree zone decide.
    float3 n; int2 cell;
    int kind = 0;
    float t = bwTrace(ro, rd, BW_FOG1 + 10.0, off, n, cell);
    float tZe = rd.z > 1e-3 ? max((15.0 - ro.z) / rd.z, 0.0) : 0.0;
    float3 treeCol = float3(0.0);
    float treeSky = 15.0;
    // (no oak crown comes nearer the wedge than about -0.3, no spruce -0.7)
    if (max(bwWedge(ro.xz), bwWedge(ro.xz + rd.xz * tZe)) > (winter ? -1.0 : -0.5)) {
        McModelHit th; int kT = 0; float passed = 0.0;
        float tT = bwTrees(ro, rd, min(t, BW_FOG1), off, winter, px, mcTiles, mcMaps, th, kT, passed);
        if (tT < t) {
            t = tT; n = th.n; kind = kT; treeCol = th.color.rgb;
            treeSky = 15.0 - min(passed, 3.0);   // sky light lost through the leaves passed
        }
    }
    float tw = (BW_WATER - ro.y) / rd.y;
    bool water = rd.y < 0.0 && tw > 0.0 && tw < t && tw < BW_FOG1;
    bool hit = t < 1e8 && dot(n, n) > 0.5;

    BwEnv E = bwEnv(u, bwArc(u, clock), fwd);
    float3 P = ro + rd * t;
    float h = (hit && kind == 0) ? bwHeight(cell, off) : 0.0;

    // 2. Its colour: texture x tint x face shade x corner shade x lightmap.
    float3 col = float3(0.0);
    if (hit) {
        float dn = dot(rd, n);
        dn = dn < 0.0 ? min(dn, -0.05) : max(dn, 0.05);
        float3 dPdx = t * px * (right - rd * dot(right, n) / dn);
        float3 dPdy = t * px * (up - rd * dot(up, n) / dn);
        BwFace F = bwFaceUV(P, n, dPdx, dPdy);
        float3 alb = kind > 0 ? treeCol : bwAlbedo(P, n, cell, h, winter, F, off, mcTiles, mcMaps);
        float ao = (kind == 0 && n.y > -0.5 && P.z < BW_ZB) ? bwOcclusion(P, n, cell, h, t, off) : 1.0;
        // under the lake, sky light falls by one a block of water
        float sky = kind > 0 ? treeSky : 15.0 + min(h, 0.0);
        // and under a crown the ground loses some (the kit's mcTreeShade)
        if (kind == 0 && h >= 2.0 && bwWedge(P.xz) > -1.0 && P.z < 15.0) {
            BwTree T = bwTreeIn(int2(floor(P.xz / float(BW_TREG))), off, winter);
            if (T.on > 0.5) sky -= mcTreeShade(T.tr, P, ao);
        }
        float3 lm = sky < 15.0 ? mcLightmap(0.0, sky, E.lightDay, 0.0) : E.light15;
        col = alb * mcFaceShade(n) * ao * lm;

        // Short grass and flowers on the grass near the eye: the shared
        // cross-plane model, tested over the last few cells the ray crossed
        // just above the ground before it met it (never in the walk itself).
        if (!winter && t < 64.0 && rd.y < -0.01) {
            float hl = max(length(rd.xz), 1e-4);
            float tEndP = water ? min(t, tw) : t;
            float tS = max(t - min(1.1 / -rd.y, 4.0 / hl), 0.0);
            float2 d = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
            float2 inv = 1.0 / d;
            int2 stp = int2(sign(d));
            int2 c = int2(floor(ro.xz + rd.xz * tS));
            float2 tNext = (float2(c) + select(float2(0.0), float2(1.0), d > 0.0) - ro.xz) * inv;
            float tIn = tS;
            for (int i = 0; i < 5; ++i) {
                if (tIn >= tEndP) break;
                float tOut = min(min(tNext.x, tNext.y), tEndP);
                float k = hash21(float2(c) * 0.613 + off * 0.37);
                if (k < 0.38 && float(c.y) + 0.5 < BW_ZB) {
                    float hc = bwHeight(c, off);
                    if (hc >= 1.0) {
                        int L = k < 0.28 ? MC_SHORT_GRASS : k < 0.31 ? MC_DANDELION : k < 0.335 ? MC_POPPY
                              : k < 0.35 ? MC_AZURE_BLUET : k < 0.365 ? MC_OXEYE_DAISY : MC_CORNFLOWER;
                        float3 tint = k < 0.28 ? bwGrassTint(mcMaps) : float3(1.0);
                        McModelHit ph;
                        if (mcCross(mcTiles, L, float3(float(c.x), hc, float(c.y)), tint, ro, rd,
                                    tIn - 1e-3, tOut + 1e-3, px, ph)) {
                            col = ph.color.rgb * (ph.shade > 0.5 ? mcFaceShade(ph.n) : 1.0) * E.light15;
                            t = ph.t;
                            water = false;
                            break;
                        }
                    }
                }
                tIn = tOut;
                if (tNext.x < tNext.y) { tNext.x += abs(inv.x); c.x += stp.x; }
                else                   { tNext.y += abs(inv.y); c.y += stp.y; }
            }
        }
    } else if (t < 1e8) {
        // deep lake: a gravel floor in the dark
        col = mcTile(mcTiles, MC_GRAVEL, P.xz, t * px / max(-rd.y, 0.05)).rgb
            * mcLightmap(0.0, 10.0, E.lightDay, 0.0);
    }

    float tEnd = t;
    if (water) {
        // 3. The lake's top: the game's animated still water, tinted, over
        //    the bed; iced over in a winter world.
        tEnd = tw;
        float3 Pw = ro + rd * tw;
        float3 nw = float3(0.0, 1.0, 0.0);
        float dn = min(rd.y, -0.05);
        float3 dPdx = tw * px * (right - rd * right.y / dn);
        float3 dPdy = tw * px * (up - rd * up.y / dn);
        int fr = mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, E.t);
        float fpw = max(length(dPdx.xz), length(dPdy.xz));
        float4 wt = mcTile(mcTiles, fr, Pw.xz, fpw);
        col = mix(col, wt.rgb * MC_WATER_TINT * E.light15 * mcFaceShade(nw), wt.a);
        if (winter) {
            float4 ic = mcTile(mcTiles, MC_ICE, Pw.xz, fpw);
            col = mix(col, ic.rgb * E.light15, ic.a);
        }
        col = mix(col, E.fog, saturate((tw * length(rd.xz) - BW_FOG0) / (BW_FOG1 - BW_FOG0)));
    } else if (t < 1e8) {
        col = mix(col, E.fog, saturate((t * length(rd.xz) - BW_FOG0) / (BW_FOG1 - BW_FOG0)));
    } else {
        // 4. The sky and the cloud layer.
        col = bwSky(rd, E, px, mcSkins);
        float4 cl = bwClouds(ro, rd, E, px, mcMaps);
        col = col * (1.0 - cl.a) + cl.rgb;
        tEnd = 1e4;
    }

    // 5. Rain or snow on the panels between the eye and what it sees.
    float4 pr = bwPrecip(ro, rd, tEnd, E, px, mcMaps);
    col = col * (1.0 - pr.a) + pr.rgb;

    col = lerpDither(saturate(col), pos);
    return half4(half3(col), 1.0h);
}
