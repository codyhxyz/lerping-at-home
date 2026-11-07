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
// with real thickness. Light is plain and even: one soft light at the eye,
// a touch of shading where walls meet, and corridors dimming with distance.
//
// Every maze is built from its own masonry — red brick, cream brick, dark
// Flemish-bond brick, or dressed stone — and never the same one twice
// running. A few walls beside the walker's route are feature walls: a glazed
// tile panel, or an old doorway bricked up inside a stone arch. They are only
// placed where the walk passes, so none is wasted.
//
// lerp-param: size        int 4 40     = 12      "Maze size"
// lerp-param: speed       float 0.25 4 = 1.3     "Walk speed (cells/s)"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -60 60   = 0 "Tilt"
// lerp-param: magnify  float -1 1.5 = 0 "Zoom"
// lerp-param: flips       bool         = true    "Flip polyhedra"
// lerp-param: style       int 0 4      = 0       "Walls (0 = new each maze)"
// lerp-param: colorFloor  color        = #6b625a "Floor"
// lerp-param: colorCeil   color        = #4a3b2e "Ceiling"
// lerp-param: colorGoal   color        = #ffbf5a "Goal"
// lerp-param: light       float 0 2    = 1       "Brightness"
//
// lerp-preset: Maze size=12
// lerp-preset: "Red Brick" style=1
// lerp-preset: Labyrinth size=28, speed=2.2, colorGoal=#7dffb0

// --- Geometry, in cell widths.
constant float MZ_WALL_H = 1.2;     // floor to ceiling
constant float MZ_EYE    = 0.52;    // eye height
constant float MZ_HALF_T = 0.07;    // half the wall thickness
constant float MZ_FOCAL  = 1.3;     // ~75° vertical field of view


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

// Masonry. Each maze is built from one of four, and consecutive mazes never
// repeat one (MazeData.swift picks; the `style` parameter can pin it).
//
// The bond is laid out from the grid, not from world x: every unit length
// divides a cell exactly (4 bricks, 3 Flemish periods or 2 stones per cell),
// and one course in two has a joint at each post face (vertex ± MZ_HALF_T),
// the other is offset by half a unit. So every wall end and corner meets the
// same joints, and `mzMasonry` is told where the face it is drawing stops:
// a joint that would fall within MZ_SLIVER of that edge is dropped and the
// sliver joins its neighbour, and the edge itself gets no mortar. Before
// this, joints landed wherever world x put them, and about one wall end or
// corner in three showed a 1-4 mm brick sliver beside the arris (the end
// caps are only 0.14 wide, narrower than one brick).
struct MzStyle {
    float h;            // course height
    float w;            // stretcher length (running bond: the period too)
    float period;       // pattern period along the wall; divides 1
    float joint;        // half the joint width
    float spread;       // unit-to-unit value variation
    int   flemish;      // 0 running bond, 1 Flemish bond (headers between stretchers)
    float3 unit, mortar;
};

constant float MZ_SLIVER = 0.045;   // shortest piece left beside a corner

static inline MzStyle mzStyleOf(uint i) {
    MzStyle s;
    switch (i & 3u) {
    case 0u:   // red brick, running bond
        s.h = 1.2 / 16.0; s.w = 0.25;  s.joint = 0.005;  s.spread = 0.28;
        s.flemish = 0; s.unit = float3(0.557, 0.231, 0.145); s.mortar = float3(0.549, 0.510, 0.451);
        break;
    case 1u:   // cream stock brick, running bond
        s.h = 1.2 / 17.0; s.w = 0.25;  s.joint = 0.0047; s.spread = 0.22;
        s.flemish = 0; s.unit = float3(0.70, 0.585, 0.41); s.mortar = float3(0.81, 0.77, 0.68);
        break;
    case 2u:   // dark brick, Flemish bond with burnt headers: 3 periods a cell
        s.h = 1.2 / 16.0; s.w = 2.0 / 9.0; s.joint = 0.005; s.spread = 0.24;
        s.flemish = 1; s.unit = float3(0.42, 0.22, 0.18); s.mortar = float3(0.50, 0.48, 0.45);
        break;
    default:   // dressed stone blocks
        s.h = 0.2;        s.w = 0.5;   s.joint = 0.004;  s.spread = 0.16;
        s.flemish = 0; s.unit = float3(0.56, 0.54, 0.49); s.mortar = float3(0.36, 0.345, 0.315);
        break;
    }
    s.period = s.flemish != 0 ? 1.5 * s.w : s.w;
    s.unit = pow(s.unit, 2.2);
    s.mortar = pow(s.mortar, 2.2);
    return s;
}

// The unit of the bond containing x (already shifted for its course):
// (start, end, id). Flemish ids are even for stretchers, odd for headers.
static inline float3 mzUnitAt(float x, MzStyle st) {
    float k = floor(x / st.period);
    if (st.flemish == 0) return float3(k * st.w, k * st.w + st.w, k);
    float m = x - k * st.period;
    bool header = m >= st.w;
    float a = k * st.period + (header ? st.w : 0.0);
    return float3(a, header ? k * st.period + st.period : a + st.w, k * 2.0 + (header ? 1.0 : 0.0));
}

// u runs along the wall in world units; [lo, hi] is the face's extent along u
// near this point (±1e9 where it runs on); `phase` flips which courses carry
// the joints at post faces, so that at a corner one face shows a whole brick
// where the other shows a short one, course by course.
static inline float3 mzMasonry(float u, float v, float face, float fw, MzStyle st,
                               float lo, float hi, float phase) {
    float row = floor(v / st.h);
    float odd = fmod(abs(row) + phase, 2.0);
    float shift = MZ_HALF_T + odd * 0.5 * st.period;
    float x = u - shift, elo = lo - shift, ehi = hi - shift;

    float3 b = mzUnitAt(x, st);
    // Pieces shorter than MZ_SLIVER at either edge join the unit next door,
    // which keeps its colour; units overhanging an edge are cut at it.
    if (b.y < elo + MZ_SLIVER) { float3 n = mzUnitAt(b.y + 1e-4, st); b.y = n.y; b.z = n.z; }
    if (b.x > ehi - MZ_SLIVER) { float3 n = mzUnitAt(b.x - 1e-4, st); b.x = n.x; b.z = n.z; }
    bool openL = b.x < elo + MZ_SLIVER, openR = b.y > ehi - MZ_SLIVER;   // no joint at an arris
    bool header = st.flemish != 0 && fmod(abs(b.z), 2.0) > 0.5;

    float fy = v / st.h - row;
    float ex = min(openL ? 1e9 : x - b.x, openR ? 1e9 : b.y - x);
    float e = min(ex, min(fy, 1.0 - fy) * st.h);
    float aa = max(fw * 0.5, 1e-4);
    float body = smoothstep(st.joint - aa, st.joint + aa, e);

    // Each unit a slightly different tone, nothing more.
    float id = b.z;
    float h1 = hash21(float2(id, row) + face * 41.3);
    float h2 = hash21(float2(row, id) * 1.37 + 7.1 + face);
    float3 c = st.unit * (1.0 - 0.5 * st.spread + st.spread * h1);
    c *= float3(1.0 + 0.08 * (h2 - 0.5), 1.0, 1.0 - 0.08 * (h2 - 0.5));
    if (header) c *= float3(0.7, 0.72, 0.78);   // Flemish bond's darker header ends

    float3 alb = mix(st.mortar * 0.8, c, body);   // joints sit back from the face
    // Far away the pattern averages out rather than aliasing.
    float far = smoothstep(st.h * 0.12, st.h * 0.45, fw);
    float jointFrac = 2.0 * st.joint / st.h + 2.0 * st.joint / st.w;
    return mix(alb, mix(st.unit, st.mortar * 0.8, jointFrac), far);
}

// --- Feature walls. Only on walls beside the walker's route; `lu` runs 0..1
// along the wall from one grid vertex to the next, so both faces agree.

// A glazed tile panel with a cream border course.
static inline float3 mzTiles(float lu, float v, float fw, float pick, thread bool& inside) {
    const float x0 = 0.13, x1 = 0.87, y0 = 0.1, y1 = 0.96;
    inside = lu > x0 && lu < x1 && v > y0 && v < y1;
    if (!inside) return float3(0.0);
    const float G = 0.004;
    float2 q = float2((lu - x0) / (x1 - x0) * 8.0, (v - y0) / (y1 - y0) * 9.0);
    float2 c = floor(q), f = q - c;
    float2 sz = float2((x1 - x0) / 8.0, (y1 - y0) / 9.0);
    float e = min(min(f.x, 1.0 - f.x) * sz.x, min(f.y, 1.0 - f.y) * sz.y);
    float aa = max(fw * 0.5, 1e-4);
    float body = smoothstep(G - aa, G + aa, e);

    const float3 glazes[4] = { float3(0.137, 0.314, 0.561), float3(0.118, 0.455, 0.408),
                               float3(0.486, 0.149, 0.20),  float3(0.725, 0.541, 0.18) };
    bool border = c.x < 0.5 || c.x > 6.5 || c.y < 0.5 || c.y > 7.5;
    float3 glaze = border ? float3(0.867, 0.827, 0.733) : glazes[int(pick * 4.0) & 3];
    float3 tile = pow(glaze, 2.2) * (0.92 + 0.12 * hash21(c + pick * 31.0));
    float3 grout = pow(float3(0.72, 0.69, 0.62), 2.2);
    float3 alb = mix(grout, tile, body);
    return mix(alb, mix(tile, grout, 0.1), smoothstep(sz.y * 0.15, sz.y * 0.5, fw));
}

// A bricked-up arched doorway: a ring of dressed stone with a keystone, and
// slightly darker infill inside it.
static inline float3 mzArch(float lu, float v, float face, float fw, MzStyle st,
                            thread bool& inside) {
    const float A = 0.24, S = 0.6, R = 0.06;       // half-width, springing height, ring width
    float2 rel = float2(lu - 0.5, v - S);
    float d = v < S ? abs(rel.x) - A : length(rel) - A;
    inside = d < R;
    if (!inside) return float3(0.0);
    if (d < 0.0) return mzMasonry(lu + 3.1, v, face + 5.0, fw, st, -1e9, 1e9, 0.0) * 0.8;

    // Ring stones: jamb blocks below the springing line, nine voussoirs above.
    float seg, ej;
    if (v < S) {
        float k = v / 0.12;
        seg = floor(k) + (rel.x > 0.0 ? 50.0 : 0.0);
        ej = min(fract(k), 1.0 - fract(k)) * 0.12;
    } else {
        const float step = PI / 9.0;
        float k = atan2(rel.y, rel.x) / step;
        seg = floor(k) + 100.0;
        ej = min(fract(k), 1.0 - fract(k)) * step * (A + d);
    }
    float e = min(ej, min(d, R - d));
    float aa = max(fw * 0.5, 1e-4);
    float body = smoothstep(st.joint - aa, st.joint + aa, e);
    float3 stone = pow(float3(0.74, 0.69, 0.60), 2.2) * (0.9 + 0.12 * hash21(float2(seg, face)));
    if (seg == 104.0) stone *= 1.08;   // keystone
    return mix(st.mortar * 0.8, stone, body);
}

static inline float3 mzFlagstones(float2 p, float fw, float3 stone) {
    const float S = 0.5, G = 0.006;
    float2 c = floor(p / S);
    float2 f = p / S - c;
    float2 e2 = min(f, 1.0 - f) * S;
    float e = min(e2.x, e2.y);
    float aa = max(fw * 0.5, 1e-4);
    float body = smoothstep(G - aa, G + aa, e);
    float h = hash21(c + 3.7);
    float3 alb = mix(stone * 0.5, stone * (0.86 + 0.2 * h), body);
    return mix(alb, stone * 0.9, smoothstep(0.03, 0.15, fw));
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
    float3 alb = mix(wood * 0.45, wood * (0.84 + 0.24 * h), body);
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

    // One soft, neutral light at the eye. Surfaces facing you are lit fully,
    // grazing ones a little less, and nothing goes black.
    float3 lightCol = float3(1.0, 0.97, 0.92) * 1.25 * u.light;

    if (solid >= 0) {
        float3 n = sN;
        float3 L = -rd;
        float3 R = reflect(rd, n);
        if (solid == 8) {
            // The goal: a faceted gem with a slow glow.
            float facet = pow(max(dot(n, L), 0.0), 2.0);
            col = goalCol * (0.45 + 0.75 * facet) * (0.7 + 0.3 * pulse);
        } else {
            // Polyhedra: polished silver.
            float3 env = mix(mzLinear(u.colorFloor), mzLinear(u.colorCeil) * 1.3, R.y * 0.5 + 0.5);
            float diff = max(dot(n, L), 0.0);
            col = float3(0.62, 0.66, 0.72) * (0.45 * diff * lightCol + env * 0.4)
                + pow(max(dot(R, L), 0.0), 60.0) * lightCol * 0.6;
        }
    } else if (t > 1e8) {
        col = float3(0.0);   // never seen: the outer wall is closed
    } else {
        float3 n;
        float3 alb;
        float ao;
        float fw;
        if (wall) {
            n = float3(n2.x, 0.0, n2.y);
            float cosi = max(abs(dot(rd, n)), 0.06);
            fw = t * pxAngle / cosi;
            bool alongX = abs(n.z) > 0.5;          // face normal ±z: bricks run along x
            float uu = alongX ? P.x : P.z;
            float face = alongX ? (n.z > 0.0 ? 1.0 : 2.0) : (n.x > 0.0 ? 3.0 : 4.0);
            MzStyle st = mzStyleOf(u.style > 0 ? uint(u.style - 1) : F.dim.w);

            // Which wall this is: the one from grid vertex `vtx` along +x or +z.
            float along = alongX ? P.x : P.z;
            float lineC = alongX ? round(P.z) : round(P.x);
            float ei = floor(along);
            float lu = along - ei;
            int2 vtx = alongX ? int2(int(ei), int(lineC)) : int2(int(lineC), int(ei));
            bool feature = (mzRecord(verts, vtx, cells) & (alongX ? 16u : 32u)) != 0u;

            bool done = false;
            if (feature) {
                float pick = hash21(float2(vtx) * 1.731 + (alongX ? 0.37 : 0.71) + F.goal.z * 17.0);
                if (pick < 0.5) alb = mzTiles(lu, P.y, fw, pick * 2.0, done);
                else            alb = mzArch(lu, P.y, face, fw, st, done);
            }
            if (!done) {
                // Where this face stops near here: at a wall end or outside
                // corner (vertex ± MZ_HALF_T where an arm is missing), or an
                // inside corner (where a wall leaves on the face's own side).
                uint plusA = alongX ? 1u : 4u, minusA = alongX ? 2u : 8u;
                uint own = alongX ? (n.z > 0.0 ? 4u : 8u) : (n.x > 0.0 ? 1u : 2u);
                float lo = -1e9, hi = 1e9;
                for (int k = 0; k < 2; ++k) {
                    float vk = ei + float(k);
                    int2 vv = alongX ? int2(int(vk), int(lineC)) : int2(int(lineC), int(vk));
                    uint r = mzRecord(verts, vv, cells);
                    float eL, eR;
                    if (r & own) { eL = vk + MZ_HALF_T; eR = vk - MZ_HALF_T; }
                    else {
                        eL = (r & minusA) ? -1e9 : vk - MZ_HALF_T;
                        eR = (r & plusA)  ?  1e9 : vk + MZ_HALF_T;
                    }
                    if (eL <= uu + 1e-3) lo = max(lo, eL);
                    if (eR >= uu - 1e-3) hi = min(hi, eR);
                }
                float phase = (n.z < -0.5 || n.x > 0.5) ? 1.0 : 0.0;
                alb = mzMasonry(uu, P.y, face, fw, st, lo, hi, phase);
            }

            // A little shading where walls meet the floor, the ceiling and each other.
            float aoV = min(P.y, MZ_WALL_H - P.y);
            float aoC = mzWallDist(P.xz + n2 * 0.2, verts, cells);
            ao = mix(0.8, 1.0, saturate(aoV / 0.2)) * mix(0.75, 1.0, saturate(aoC / 0.2));
        } else {
            bool isFloor = rd.y < 0.0;
            n = float3(0.0, isFloor ? 1.0 : -1.0, 0.0);
            fw = t * pxAngle / max(abs(rd.y), 0.06);
            if (isFloor) {
                alb = mzFlagstones(P.xz, fw, mzLinear(u.colorFloor));
            } else {
                alb = mzBoards(P.xz, fw, mzLinear(u.colorCeil));
            }
            float d = mzWallDist(P.xz, verts, cells);
            ao = mix(0.75, 1.0, saturate(d / 0.2));
        }

        float diff = max(dot(n, -rd), 0.0);
        col = alb * lightCol * (0.4 + 0.6 * diff) * ao;
        // Corridors dim gently with distance.
        col *= 1.0 / (1.0 + 0.045 * t * t);
    }

    // A soft halo round the goal.
    {
        float tc = dot(gemC - ro, rd);
        if (tc > 0.0 && tc < t + MZ_GEM_R) {
            float d = length(ro + rd * tc - gemC);
            col += goalCol * pulse * 0.0012 / (d * d + 0.01);
        }
    }

    return col;
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpMazeFrame& F [[buffer(1)]],
                        device const uint* verts [[buffer(2)]]) {
    float minRes = min(u.resolution.x, u.resolution.y);
    float pxAngle = 2.0 / (minRes * MZ_FOCAL);

    // Camera: level, at eye height, no bob.
    float yaw = F.camera.z, roll = F.camera.w;
    float3 ro = float3(F.camera.x, MZ_EYE, F.camera.y);
    float3 fwd = float3(cos(yaw), 0.0, sin(yaw));
    float3 right0 = float3(-fwd.z, 0.0, fwd.x);
    float3 up0 = float3(0.0, 1.0, 0.0);
    float cr = cos(roll), sr = sin(roll);
    float3 right = right0 * cr + up0 * sr;
    float3 up = up0 * cr - right0 * sr;
    // Drag to look round, pinch to zoom: the walker's own view stays level.
    float lens = lerpLook(u.yaw, u.pitch, u.magnify, up0, right, fwd);
    if (u.yaw != 0.0 || u.pitch != 0.0) up = cross(right, fwd);
    pxAngle /= lens;

    const float2 grid[4] = { float2(0.125, 0.375), float2(0.375, -0.125),
                             float2(-0.125, -0.375), float2(-0.375, 0.125) };
    float3 col = float3(0.0);
    for (int s = 0; s < MZ_SAMPLES; ++s) {
        float4 p = pos;
        p.xy += grid[s];
        float2 uv = lerpUV(p, u.resolution);
        float3 rd = normalize(uv.x * right + uv.y * up + lens * MZ_FOCAL * fwd);
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
