// Maze — an homage to Microsoft's 3D Maze screensaver (ssmaze, Windows 95).
// Original work for Lerping@Home; no code, textures or artwork from the
// original. What it keeps is the idea: a first-person walk through brick
// corridors, solved hand-on-the-wall, with spinning polyhedra that turn the
// world upside down when you walk through them.
//
// lerp-data: maze
//
// What it does differently: the walk is one continuous path (quarter-circle
// turns, eased stops only at dead ends) instead of step-stop-rotate; the
// bricks, flagstones and ceiling boards are procedural and filtered to the
// pixel footprint, so nothing shimmers at a distance; the walls are slabs
// with real thickness rather than paper-thin quads; light comes from a
// lantern the walker carries, with ambient occlusion in every corner; and the
// goal is a lit gem whose glow you can see spilling round the last corners.
//
// lerp-param: size        int 4 40     = 12      "Maze size"
// lerp-param: speed       float 0.25 4 = 1.3     "Walk speed (cells/s)"
// lerp-param: flips       bool         = true    "Flip polyhedra"
// lerp-param: colorBrick  color        = #8e3b25 "Brick"
// lerp-param: colorMortar color        = #8c8273 "Mortar"
// lerp-param: colorFloor  color        = #6b625a "Floor"
// lerp-param: colorCeil   color        = #4a3b2e "Ceiling"
// lerp-param: colorGoal   color        = #ffbf5a "Goal"
// lerp-param: lantern     float 0 2    = 1       "Lantern"
// lerp-param: ambient     float 0 1    = 0.12    "Ambient light"
//
// lerp-preset: "Brick Maze" size=12
// lerp-preset: Catacombs colorBrick=#6d6a63, colorMortar=#3d3934, colorFloor=#4a4540
// lerp-preset: Catacombs colorCeil=#2a2724, colorGoal=#9fd4ff, lantern=0.85, ambient=0.08
// lerp-preset: Catacombs speed=1.0, size=16
// lerp-preset: Sandstone colorBrick=#c99a62, colorMortar=#e3d3b5, colorFloor=#8f7a5f
// lerp-preset: Sandstone colorCeil=#6e5640, colorGoal=#ff7a45, lantern=0.7, ambient=0.6
// lerp-preset: Labyrinth size=28, speed=2.2, colorGoal=#7dffb0

// --- Geometry, in cell widths.
constant float MZ_WALL_H = 1.2;     // floor to ceiling
constant float MZ_EYE    = 0.52;    // eye height
constant float MZ_HALF_T = 0.07;    // half the wall thickness
constant float MZ_FOCAL  = 1.3;     // ~75° vertical field of view

// --- Bricks: 16 courses, running bond.
constant float MZ_BH = 1.2 / 16.0;
constant float MZ_BW = 0.24;
constant float MZ_MORTAR = 0.0065;  // half the joint width

constant float MZ_OBJ_R  = 0.15;    // polyhedron size
constant float MZ_GEM_R  = 0.1;

constant int MZ_SAMPLES = 4;        // rotated-grid supersampling

// ---------------------------------------------------------------------------
// The grid.

static inline uint mzRecord(device const uint* verts, int2 v, uint2 cells) {
    if (v.x < 0 || v.y < 0 || v.x > int(cells.x) || v.y > int(cells.y)) return 0u;
    return verts[v.y * int(cells.x + 1) + v.x];
}

// The two bars of vertex v's cross: x = horizontal bar, y = vertical bar.
static inline void mzBars(uint rec, float2 v, thread float2& hlo, thread float2& hhi,
                          thread float2& vlo, thread float2& vhi) {
    const float w = MZ_HALF_T;
    hlo = v + float2((rec & 2u) ? -0.5 : -w, -w);
    hhi = v + float2((rec & 1u) ?  0.5 :  w,  w);
    vlo = v + float2(-w, (rec & 8u) ? -0.5 : -w);
    vhi = v + float2( w, (rec & 4u) ?  0.5 :  w);
}

static inline float mzBoxDist(float2 p, float2 lo, float2 hi) {
    float2 c = 0.5 * (lo + hi), h = 0.5 * (hi - lo);
    float2 q = abs(p - c) - h;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// Distance in the floor plane from p to the nearest wall. Exact within ~0.4 of
// a wall, which is all ambient occlusion asks of it.
static inline float mzWallDist(float2 p, device const uint* verts, uint2 cells) {
    int2 vi = int2(floor(p + 0.5));
    uint rec = mzRecord(verts, vi, cells);
    if (rec == 0u) return 1.0;
    float2 hlo, hhi, vlo, vhi;
    mzBars(rec, float2(vi), hlo, hhi, vlo, vhi);
    return min(mzBoxDist(p, hlo, hhi), mzBoxDist(p, vlo, vhi));
}

static inline void mzBoxHit(float2 ro, float2 inv, float2 lo, float2 hi,
                            thread float& best, thread float2& nrm) {
    float2 t1 = (lo - ro) * inv, t2 = (hi - ro) * inv;
    float2 tn = min(t1, t2), tf = max(t1, t2);
    float tNear = max(tn.x, tn.y), tFar = min(tf.x, tf.y);
    if (tNear <= tFar && tNear > 0.0 && tNear < best) {
        best = tNear;
        nrm = tn.x > tn.y ? float2(-sign(1.0 / inv.x), 0.0) : float2(0.0, -sign(1.0 / inv.y));
    }
}

// Walks the ray (ro, rd) through vertex squares in the floor plane. t is in
// units of rd, which need not be normalised. Returns the wall hit, or 1e9 if
// nothing is hit before tLimit.
static inline float mzTrace(float2 ro, float2 rd, float tLimit,
                            device const uint* verts, uint2 cells, thread float2& nrm) {
    rd = select(rd, float2(1e-7), abs(rd) < 1e-7);
    float2 inv = 1.0 / rd;
    float2 q = ro + 0.5;
    int2 cell = int2(floor(q));
    int2 stepDir = int2(sign(rd));
    float2 tDelta = abs(inv);
    float2 tMax = (float2(cell) + select(float2(0.0), float2(1.0), rd > 0.0) - q) * inv;

    int maxSteps = int(cells.x + cells.y) * 2 + 8;
    for (int i = 0; i < maxSteps; ++i) {
        if (cell.x < 0 || cell.y < 0 || cell.x > int(cells.x) || cell.y > int(cells.y)) break;
        uint rec = mzRecord(verts, cell, cells);
        if (rec != 0u) {
            float2 hlo, hhi, vlo, vhi;
            mzBars(rec, float2(cell), hlo, hhi, vlo, vhi);
            float best = 1e9;
            mzBoxHit(ro, inv, hlo, hhi, best, nrm);
            mzBoxHit(ro, inv, vlo, vhi, best, nrm);
            if (best < 1e8) return best < tLimit ? best : 1e9;
        }
        float tExit = min(tMax.x, tMax.y);
        if (tExit > tLimit) break;
        if (tMax.x < tMax.y) { tMax.x += tDelta.x; cell.x += stepDir.x; }
        else                 { tMax.y += tDelta.y; cell.y += stepDir.y; }
    }
    return 1e9;
}

// ---------------------------------------------------------------------------
// Polyhedra.

static inline float3 mzSpin(float3 q, float a) {
    float c = cos(a), s = sin(a);
    q.xz = float2(c * q.x - s * q.z, s * q.x + c * q.z);
    float c2 = cos(a * 0.63), s2 = sin(a * 0.63);
    q.yz = float2(c2 * q.y - s2 * q.z, s2 * q.y + c2 * q.z);
    return q;
}

static inline float mzOcta(float3 q, float r) {
    q = abs(q);
    return (q.x + q.y + q.z - r) * 0.57735027;
}

static inline float mzDodeca(float3 q, float r) {
    const float a = 0.52573111, b = 0.85065081;   // (1, φ) / |(1, φ)|
    q = abs(q);
    float d = max(max(dot(q, float3(0.0, a, b)), dot(q, float3(a, b, 0.0))), dot(q, float3(b, 0.0, a)));
    return d - r;
}

// Sphere-traces one spinning solid inside its bounding sphere. kind 0 = octahedron.
static inline bool mzSolid(float3 ro, float3 rd, float3 c, float r, float spin, int kind,
                           float tMax, thread float& tHit, thread float3& nrm) {
    float3 oc = ro - c;
    float b = dot(oc, rd);
    float disc = b * b - (dot(oc, oc) - r * r * 1.1);
    if (disc <= 0.0) return false;
    float t = max(-b - sqrt(disc), 0.0);
    float tEnd = min(-b + sqrt(disc), tMax);
    for (int i = 0; i < 32 && t < tEnd; ++i) {
        float3 q = mzSpin(ro + rd * t - c, spin);
        float d = kind == 0 ? mzOcta(q, r) : mzDodeca(q, r);
        if (d < 1e-4) {
            const float2 e = float2(1e-3, -1e-3);
            float3 p = ro + rd * t - c;
            float3 g = e.xyy * (kind == 0 ? mzOcta(mzSpin(p + e.xyy, spin), r) : mzDodeca(mzSpin(p + e.xyy, spin), r))
                     + e.yyx * (kind == 0 ? mzOcta(mzSpin(p + e.yyx, spin), r) : mzDodeca(mzSpin(p + e.yyx, spin), r))
                     + e.yxy * (kind == 0 ? mzOcta(mzSpin(p + e.yxy, spin), r) : mzDodeca(mzSpin(p + e.yxy, spin), r))
                     + e.xxx * (kind == 0 ? mzOcta(mzSpin(p + e.xxx, spin), r) : mzDodeca(mzSpin(p + e.xxx, spin), r));
            nrm = normalize(g);
            tHit = t;
            return true;
        }
        t += d;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Surfaces. Each returns linear albedo and perturbs `n`; `fw` is the pixel
// footprint in world units, which every pattern fades out against.

static inline float3 mzBricks(float u, float v, float face, float fw, float3 brick, float3 mortar,
                              float3 tangent, thread float3& n) {
    float row = floor(v / MZ_BH);
    float x = u + (fmod(abs(row), 2.0) * 0.5 + face * 0.31) * MZ_BW;
    float col = floor(x / MZ_BW);
    float fx = x / MZ_BW - col, fy = v / MZ_BH - row;
    float ex = min(fx, 1.0 - fx) * MZ_BW, ey = min(fy, 1.0 - fy) * MZ_BH;
    float e = min(ex, ey);

    float aa = max(fw * 0.5, 1e-4);
    float body = smoothstep(MZ_MORTAR - aa, MZ_MORTAR + aa, e);

    // Per-brick colour: value, a little hue, and the odd scorched one.
    float h1 = hash21(float2(col, row) + face * 41.3);
    float h2 = hash21(float2(row, col) * 1.37 + 7.1 + face);
    float3 b = brick * (0.68 + 0.5 * h1);
    b *= float3(1.0 + 0.16 * (h2 - 0.5), 1.0, 1.0 - 0.14 * (h2 - 0.5));
    if (h2 > 0.93) b *= 0.55;

    float detail = 1.0 - smoothstep(0.003, 0.02, fw);
    float speck = valueNoise(float2(u, v) * 55.0);
    b *= mix(1.0, 0.82 + 0.36 * speck, detail);
    float3 m = mortar * mix(1.0, 0.8 + 0.35 * valueNoise(float2(u, v) * 31.0 + 5.0), detail);
    m *= 0.78;   // recessed joints catch less light

    float3 alb = mix(m, b, body);

    // Bevelled brick edges: tilt the normal toward the nearest joint.
    float bevel = 1.0 - smoothstep(MZ_MORTAR, MZ_MORTAR + 0.011, e);
    float2 toward = ex < ey ? float2(sign(fx - 0.5), 0.0) : float2(0.0, sign(fy - 0.5));
    float k = 0.55 * bevel * body * (1.0 - smoothstep(0.004, 0.025, fw));
    n = normalize(n + k * (toward.x * tangent + toward.y * float3(0.0, 1.0, 0.0)));

    // Far away the pattern averages out rather than aliasing.
    float far = smoothstep(MZ_BH * 0.12, MZ_BH * 0.45, fw);
    float joint = 2.0 * MZ_MORTAR / MZ_BH + 2.0 * MZ_MORTAR / MZ_BW;
    alb = mix(alb, mix(brick * 0.93, mortar * 0.78, joint), far);

    // Grime: low-frequency staining, heavier near the floor.
    float g = valueNoise(float2(u * 1.7 + face * 9.0, v * 2.6));
    alb *= (0.78 + 0.34 * g) * mix(0.62, 1.0, smoothstep(0.0, 0.4, v));
    return alb;
}

static inline float3 mzFlagstones(float2 p, float fw, float3 stone, thread float& gloss) {
    const float S = 0.5, G = 0.006;
    float2 c = floor(p / S);
    float2 f = p / S - c;
    float2 e2 = min(f, 1.0 - f) * S;
    float e = min(e2.x, e2.y);
    float aa = max(fw * 0.5, 1e-4);
    float body = smoothstep(G - aa, G + aa, e);
    float h = hash21(c + 3.7);
    float detail = 1.0 - smoothstep(0.003, 0.02, fw);
    float3 s = stone * (0.72 + 0.42 * h) * mix(1.0, 0.85 + 0.3 * valueNoise(p * 23.0 + h * 10.0), detail);
    float3 alb = mix(stone * 0.35, s, body);
    alb = mix(alb, stone * 0.9, smoothstep(0.03, 0.15, fw));
    alb *= 0.8 + 0.3 * valueNoise(p * 1.3 + 11.0);
    gloss = body * (0.55 + 0.45 * h);
    return alb;
}

static inline float3 mzBoards(float2 p, float fw, float3 wood) {
    const float W = 0.125;
    float row = floor(p.y / W);
    float x = p.x + hash11(row) * 3.0;
    float plank = floor(x / 1.5);
    float fy = p.y / W - row, fx = x / 1.5 - plank;
    float e = min(min(fy, 1.0 - fy) * W, min(fx, 1.0 - fx) * 1.5);
    float aa = max(fw * 0.5, 1e-4);
    float body = smoothstep(0.004 - aa, 0.004 + aa, e);
    float h = hash21(float2(row, plank));
    float detail = 1.0 - smoothstep(0.003, 0.02, fw);
    float grain = valueNoise(float2(x * 3.0, p.y * 70.0 + h * 13.0));
    float3 alb = wood * (0.7 + 0.45 * h) * mix(1.0, 0.8 + 0.4 * grain, detail);
    alb = mix(wood * 0.3, alb, body);
    return mix(alb, wood * 0.85, smoothstep(0.02, 0.1, fw));
}

static inline float3 mzLinear(float4 c) { return pow(max(c.rgb, 0.0), 2.2); }

// ---------------------------------------------------------------------------

static inline float3 mzScene(float3 ro, float3 rd, float3 right, float3 up, float3 fwd,
                             float pxAngle, constant LerpUniforms& u,
                             constant LerpMazeFrame& F, device const uint* verts) {
    uint2 cells = F.dim.xy;
    float now = u.time;

    // --- Primary hit: wall, floor or ceiling.
    float tPlane = rd.y < -1e-5 ? -ro.y / rd.y
                 : (rd.y > 1e-5 ? (MZ_WALL_H - ro.y) / rd.y : 1e9);
    float2 n2 = float2(0.0);
    float tWall = mzTrace(ro.xz, rd.xz, tPlane, verts, cells, n2);
    bool wall = tWall < tPlane;
    float t = wall ? tWall : tPlane;

    // --- Polyhedra and the goal gem.
    int solid = -1;
    float3 sN = float3(0.0);
    float3 gemC = float3(F.goal.x, MZ_EYE, F.goal.y);
    float gemSpin = now * 0.7;
    {
        float th; float3 nn;
        if (mzSolid(ro, rd, gemC, MZ_GEM_R, gemSpin, 1, t, th, nn)) { t = th; sN = nn; solid = 8; }
        for (uint i = 0; i < min(F.dim.z, 8u); ++i) {
            float4 o = F.objects[i];
            if (o.z <= 0.0) continue;
            float3 c = float3(o.x, MZ_EYE, o.y);
            if (mzSolid(ro, rd, c, MZ_OBJ_R * o.z, now * 1.1 + o.w, 0, t, th, nn)) {
                t = th; sN = nn; solid = int(i);
            }
        }
    }

    float3 P = ro + rd * t;
    float3 goalCol = mzLinear(u.colorGoal);
    float pulse = 0.75 + 0.25 * sin(now * 2.1) + 1.5 * F.goal.w;
    float3 col;

    // Lantern: carried just right of and above the eye, so it rolls with you.
    float flicker = 1.0 + 0.035 * sin(now * 13.0) * sin(now * 7.3 + 1.0);
    float3 lanternPos = ro + right * 0.14 + up * 0.08 - fwd * 0.05;
    float3 lanternCol = float3(1.0, 0.8, 0.58) * 3.2 * u.lantern * flicker;
    float3 ambientCol = float3(0.55, 0.62, 0.75) * u.ambient;

    if (solid >= 0) {
        float3 n = sN;
        float3 L = normalize(lanternPos - P);
        float3 V = -rd;
        float3 R = reflect(rd, n);
        if (solid == 8) {
            // The goal: a lit gem, faceted by its own light.
            // Each face catches the lantern differently; edges glow hotter.
            float facet = pow(max(dot(n, L), 0.0), 3.0);
            float rim = pow(1.0 - max(dot(n, V), 0.0), 2.0);
            col = goalCol * (0.35 + 0.9 * facet) * (0.6 + 0.4 * pulse)
                + goalCol * goalCol * rim * 1.6 * pulse
                + pow(max(dot(R, L), 0.0), 60.0) * 1.5;
        } else {
            // Polyhedra: polished silver with a cold inner light.
            float3 env = mix(mzLinear(u.colorFloor), mzLinear(u.colorCeil) * 1.3, R.y * 0.5 + 0.5);
            float diff = max(dot(n, L), 0.0);
            float spec = pow(max(dot(R, L), 0.0), 60.0);
            col = float3(0.62, 0.66, 0.72) * (0.25 * diff * lanternCol + env * 0.35)
                + spec * lanternCol * 0.9
                + float3(0.25, 0.45, 0.9) * 0.35 * pow(1.0 - max(dot(n, V), 0.0), 2.0);
        }
    } else if (t > 1e8) {
        col = float3(0.0);   // never seen: the outer wall is closed
    } else {
        float3 n;
        float3 alb;
        float gloss = 0.0;
        float ao;
        float fw;
        if (wall) {
            n = float3(n2.x, 0.0, n2.y);
            float cosi = max(abs(dot(rd, n)), 0.06);
            fw = t * pxAngle / cosi;
            bool alongX = abs(n.z) > 0.5;          // face normal ±z: bricks run along x
            float uu = alongX ? P.x : P.z;
            float face = alongX ? (n.z > 0.0 ? 1.0 : 2.0) : (n.x > 0.0 ? 3.0 : 4.0);
            float3 tangent = alongX ? float3(1.0, 0.0, 0.0) : float3(0.0, 0.0, 1.0);
            alb = mzBricks(uu, P.y, face, fw, mzLinear(u.colorBrick), mzLinear(u.colorMortar), tangent, n);
            float aoV = min(P.y, MZ_WALL_H - P.y);
            float aoC = mzWallDist(P.xz + n2 * 0.3, verts, cells);
            ao = mix(0.45, 1.0, sqrt(saturate(aoV / 0.32))) * mix(0.4, 1.0, sqrt(saturate(aoC / 0.3)));
        } else {
            bool isFloor = rd.y < 0.0;
            n = float3(0.0, isFloor ? 1.0 : -1.0, 0.0);
            fw = t * pxAngle / max(abs(rd.y), 0.06);
            if (isFloor) {
                alb = mzFlagstones(P.xz, fw, mzLinear(u.colorFloor), gloss);
            } else {
                alb = mzBoards(P.xz, fw, mzLinear(u.colorCeil));
            }
            float d = mzWallDist(P.xz, verts, cells);
            ao = mix(0.35, 1.0, sqrt(saturate(d / 0.35)));
        }

        float3 V = -rd;
        float3 Lv = lanternPos - P;
        float dl = length(Lv);
        float3 L = Lv / dl;
        float atten = 1.0 / (1.0 + 1.2 * dl * dl);
        float diff = max(dot(n, L), 0.0);
        float3 H = normalize(L + V);
        float spec = pow(max(dot(n, H), 0.0), mix(16.0, 70.0, gloss)) * mix(0.05, 0.45, gloss);
        col = alb * (lanternCol * diff * atten + ambientCol * ao) + lanternCol * spec * atten * ao;

        // Light from the goal gem, where it can see the surface.
        float3 Lg = gemC - P;
        float dg = length(Lg);
        if (dg < 4.0) {
            float2 nn;
            float2 from = P.xz + n.xz * 0.002;
            float blocked = mzTrace(from, gemC.xz - from, 0.999, verts, cells, nn);
            if (blocked > 1e8) {
                float gd = max(dot(n, Lg / dg), 0.0);
                float ga = 1.0 / (1.0 + 2.5 * dg * dg) * (1.0 - smoothstep(3.0, 4.0, dg));
                col += alb * goalCol * gd * ga * 1.6 * pulse * mix(0.6, 1.0, ao);
            }
        }
    }

    // Halos: the gem, and a faint one round each polyhedron.
    {
        float tc = dot(gemC - ro, rd);
        if (tc > 0.0 && tc < t + MZ_GEM_R) {
            float d = length(ro + rd * tc - gemC);
            col += goalCol * pulse * 0.0025 / (d * d + 0.01);
        }
        for (uint i = 0; i < min(F.dim.z, 8u); ++i) {
            float4 o = F.objects[i];
            if (o.z <= 0.0) continue;
            float3 c = float3(o.x, MZ_EYE, o.y);
            float tco = dot(c - ro, rd);
            if (tco > 0.0 && tco < t + MZ_OBJ_R) {
                float d = length(ro + rd * tco - c);
                col += float3(0.3, 0.5, 1.0) * o.z * 0.0012 / (d * d + 0.006);
            }
        }
    }

    // Depth haze: corridors fall away into a dark, faintly warm murk.
    float haze = exp(-0.16 * t);
    col = mix(float3(0.006, 0.005, 0.004) + ambientCol * 0.04, col, haze);
    return col;
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpMazeFrame& F [[buffer(1)]],
                        device const uint* verts [[buffer(2)]]) {
    float minRes = min(u.resolution.x, u.resolution.y);
    float pxAngle = 2.0 / (minRes * MZ_FOCAL);

    // Camera. Walking bob: two footfalls per cell, scaled down when standing.
    float yaw = F.camera.z, roll = F.camera.w;
    float bob = 0.009 * sin(F.motion.y * TWO_PI / 0.5);
    float3 ro = float3(F.camera.x, MZ_EYE + bob, F.camera.y);
    float3 fwd = float3(cos(yaw), 0.0, sin(yaw));
    float3 right0 = float3(-fwd.z, 0.0, fwd.x);
    float3 up0 = float3(0.0, 1.0, 0.0);
    float cr = cos(roll), sr = sin(roll);
    float3 right = right0 * cr + up0 * sr;
    float3 up = up0 * cr - right0 * sr;

    const float2 grid[4] = { float2(0.125, 0.375), float2(0.375, -0.125),
                             float2(-0.125, -0.375), float2(-0.375, 0.125) };
    float3 col = float3(0.0);
    for (int s = 0; s < MZ_SAMPLES; ++s) {
        float4 p = pos;
        p.xy += grid[s];
        float2 uv = lerpUV(p, u.resolution);
        float3 rd = normalize(uv.x * right + uv.y * up + MZ_FOCAL * fwd);
        col += mzScene(ro, rd, right, up, fwd, pxAngle, u, F, verts);
    }
    col /= float(MZ_SAMPLES);

    // Gentle shoulder, then display gamma.
    col = col / (1.0 + col * 0.35);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col *= F.motion.x;
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
