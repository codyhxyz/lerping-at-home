// Window Room — original shader written for Lerping@Home (AGPL-3.0, like the
// rest of this project). A tribute to Johnny Chung Lee's 2007 demo "Head
// Tracking for Desktop VR Displays using the Wii Remote", written from scratch
// from the idea alone: no code is copied from that demo or from any of the
// unlicensed repositories that reproduce it.
//
// The scene is the canonical head-coupled one. A room exactly the size of the
// screen runs back behind the glass — wireframe grid on the floor, ceiling,
// side walls and far wall — with bullseye targets hanging at different depths,
// each on a thin stem that runs straight back to the far wall, so where it
// hangs is never in doubt. Two more targets float in front of the glass and
// pop out towards the watcher. Everything sways a little on its stem.
//
// Head tracking. `parallax` opts the look in (Shader › Track Head with
// Camera). The eye is lerpViewerEye's, and each pixel's ray is the one
// lerpViewerRay builds for an identity camera — eye at (e.x, e.y, e.z - focal),
// aimed at that pixel's fixed spot on the glass, (uv, 0) — kept unnormalised
// so that its parameter is 1 exactly at the glass. That is what makes the room
// read: the glass is at z = 0 and the room's open front is the screen's own
// rectangle, so the walls start precisely at the screen edges whatever the
// head does, nearer things swing against the head and farther ones follow it.
// The eye may come at most 45% of the way to the glass, which keeps it in
// front of the pop-out targets at any parallax gain.
//
// The crosshair. A small crosshair sits exactly in the glass plane at the
// screen's centre. Every ray passes through its own pixel's spot on the glass,
// so the crosshair cannot move with the head — it is a built-in level: if it
// ever appears to drift against the room, the off-axis camera is broken.
//
// `eyeDistance` is the static camera: how far the eye sits from the glass, in
// half screen-heights (the short side spans ±1). The illusion is physically
// exact when it matches the real distance and parallax is 1: about 3.5 for a
// 27" display at arm's length, 5 or so for a laptop. The default, 3.6, is
// tuned for a desktop display; a shorter distance deepens the perspective.
//
// Depth cues, in the order the eye uses them: the grid's cells are a fixed
// size in the room, so they crowd together with depth; the walls dim with
// distance from the glass; each target throws a soft shadow straight down on
// the floor and a blurred one on the far wall from a key light up front, both
// widening the farther they fall; and the stems meet the far wall on small
// anchor plates.
//
// Rendering is analytic — no march. The ray exits the room box through one
// wall; targets are discs facing the glass, stems are segments resolved by the
// ray's closest approach, and both are anti-aliased by their exact pixel
// footprint (ray differentials, not fwidth, so wall seams stay clean). Up to
// four overlapping fragments are kept per pixel, sorted by depth, and
// composited front to back over the wall.
//
// Seed: where the in-room targets hang (a 3D low-discrepancy sequence keeps
// them spread across the room in x, y and depth), their sizes, sway phases,
// and which diagonal the pop-out pair takes.
//
// lerp-category: Scenes
// lerp-param: parallax    float 0 2  = 1    "Head parallax"
// lerp-param: depth       float 1 10 = 4    "Room depth"
// lerp-param: targets     int   0 12 = 7    "Targets"
// lerp-param: popout      float 0 1  = 0.7  "Pop-out"
// lerp-param: palette     int   0 3  = 0    "Palette"
// lerp-param: grid        int   4 16 = 8    "Grid lines"
// lerp-param: sway        float 0 2  = 1    "Sway"
// lerp-param: eyeDistance float 2 8  = 3.6  "Eye distance"
//
// lerp-preset: Blueprint     palette=1, depth=5, grid=10
// lerp-preset: Neon          palette=2, targets=10, depth=6
// lerp-preset: Phosphor      palette=3, grid=6, targets=5, popout=1

constant int   WR_MAX_TARGETS = 12;
constant int   WR_POPS        = 2;
constant int   WR_LAYERS      = 4;        // fragments kept per pixel
constant float WR_LINE        = 0.0028;   // grid line half-width, room units
constant float WR_STEM        = 0.0075;   // stem radius
constant float WR_THICK       = 0.05;     // disc thickness
constant float WR_EYE_MAX     = 0.45;     // the eye stops this fraction of the way to the glass
constant float WR_POP_NEAR    = 0.40;     // nearest pop-out depth, as a fraction of eyeDistance

// Palettes, six colours each: wall, grid line, ring A, ring B, stem, crosshair.
constant float3 WR_PAL[24] = {
    // Classic: black room, cold white wire, red and white targets.
    float3(0.050, 0.056, 0.072), float3(0.62, 0.68, 0.78), float3(0.80, 0.09, 0.07),
    float3(0.92, 0.90, 0.86),    float3(0.72, 0.73, 0.76), float3(0.35, 1.00, 0.55),
    // Blueprint: ink-blue room, cyan wire, orange and white targets.
    float3(0.020, 0.060, 0.130), float3(0.32, 0.68, 1.00), float3(1.00, 0.48, 0.10),
    float3(0.90, 0.95, 1.00),    float3(0.68, 0.84, 1.00), float3(1.00, 0.86, 0.30),
    // Neon: violet dark, magenta wire, cyan and lemon targets.
    float3(0.050, 0.020, 0.075), float3(0.92, 0.24, 0.84), float3(0.08, 0.86, 0.95),
    float3(0.98, 0.94, 0.42),    float3(0.80, 0.70, 0.95), float3(1.00, 1.00, 1.00),
    // Phosphor: an amber terminal.
    float3(0.060, 0.035, 0.010), float3(1.00, 0.60, 0.16), float3(1.00, 0.36, 0.06),
    float3(1.00, 0.84, 0.55),    float3(0.90, 0.64, 0.34), float3(1.00, 0.92, 0.72),
};

struct WrTarget {
    float3 p;    // disc centre (it faces the glass)
    float3 a;    // where its stem meets the far wall
    float  r;    // disc radius
};

// Light falling off with distance behind the glass (the key is up front).
static inline float wrLight(float z) {
    return 0.36 + 0.64 * exp(-0.2 * max(z, 0.0));
}

// Target i. The first `nIn` hang inside the room, the next two in front of it.
static inline WrTarget wrTarget(int i, int nIn, float hx, float hy, float D, float F,
                                float popout, float sway, float t, float seed) {
    WrTarget T;
    float3 p0;
    float h = hash11(float(i) * 7.31 + seed * 91.7);
    if (i < nIn) {
        // R3 low-discrepancy sequence (generalised golden ratio, phi_3 =
        // 1.22074...): spread evenly through the room's volume.
        float3 q = fract(float3(hash11(seed * 13.1), hash11(seed * 7.7 + 1.0), hash11(seed * 3.3 + 2.0))
                         + float(i + 1) * float3(0.8191725134, 0.6710436067, 0.5497004779));
        T.r = mix(0.13, 0.20, h);
        float mx = hx - T.r - 0.14, my = hy - T.r - 0.14;
        p0 = float3((2.0 * q.x - 1.0) * mx * 0.92, (2.0 * q.y - 1.0) * my * 0.88,
                    D * (0.12 + 0.78 * q.z));
    } else {
        // The pop-out pair, on a diagonal clear of the crosshair. Placed by
        // where they land on the glass from a centred eye, so coming nearer
        // enlarges them without pushing them off the edge of the screen.
        float side = (i == nIn ? -1.0 : 1.0) * (hash11(seed * 5.9 + 3.0) < 0.5 ? 1.0 : -1.0);
        T.r = 0.16;
        float z = mix(0.3, -WR_POP_NEAR * F, popout);
        p0 = float3(float2(side * 0.5 * hx, -side * 0.33 * hy) * ((F + z) / F), z);
    }
    T.a = float3(p0.xy, D);
    // Sway: the disc swings on its stem about the anchor, a few hundredths of
    // a radian, on two slow incommensurate waves.
    float L = D - p0.z;
    float w1 = 0.23 + 0.12 * h, w2 = 0.17 + 0.10 * fract(h * 7.3);
    float amp = 0.028 * sway;
    float ax = amp * sin(w1 * t + h * 37.0);
    float ay = 0.7 * amp * sin(w2 * t + h * 53.0);
    T.p = T.a + float3(L * sin(ax), L * sin(ay), -L * cos(ax) * cos(ay));
    return T;
}

// Keep the WR_LAYERS nearest fragments, sorted by ray parameter.
static inline void wrPush(thread float* fs, thread float4* fc, float s, float4 c) {
    if (c.a < 0.002 || s >= fs[WR_LAYERS - 1]) return;
    int i = WR_LAYERS - 1;
    while (i > 0 && fs[i - 1] > s) {
        fs[i] = fs[i - 1];
        fc[i] = fc[i - 1];
        i--;
    }
    fs[i] = s;
    fc[i] = c;
}

// Coverage of a line of half-width w at distance g, for a pixel footprint fp:
// sharp when the line is wider than a pixel, fading in proportion to its
// width when it is thinner, so far lines thin out instead of shimmering.
static inline float wrLineCover(float g, float w, float fp) {
    float we = max(w, 0.5 * fp);
    return (w / we) * (1.0 - smoothstep(we - 0.5 * fp, we + 0.5 * fp, g));
}

// Point on the ray where it crosses wall `axis` (0 sides, 1 floor/ceiling, 2 far).
static inline float3 wrWallPoint(float3 ro, float3 d, float3 bound, int axis) {
    float s = (bound[axis] - ro[axis]) / d[axis];
    return ro + s * d;
}

// Grid coordinates on wall `axis`, in cells, counted from the room's corners.
static inline float2 wrWallGrid(float3 P, int axis, float hx, float hy, float3 cell) {
    if (axis == 0) return float2(P.z / cell.z, (P.y + hy) / cell.y);
    if (axis == 1) return float2((P.x + hx) / cell.x, P.z / cell.z);
    return float2((P.x + hx) / cell.x, (P.y + hy) / cell.y);
}

static inline float wrSegDist2(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float k = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-8), 0.0, 1.0);
    return length(p - a - k * ab);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 res = u.resolution;
    float mr = min(res.x, res.y);
    float2 uv = lerpUV(pos, res);
    float hx = res.x / mr, hy = res.y / mr;     // the glass, and the room's mouth
    float px = 2.0 / mr;                        // one pixel on the glass
    float F = u.eyeDistance;
    float D = u.depth;
    float t = u.time + u.seed * 300.0;
    int pal = clamp(int(u.palette), 0, 3) * 6;
    float3 cWall = WR_PAL[pal], cLine = WR_PAL[pal + 1], cA = WR_PAL[pal + 2];
    float3 cB = WR_PAL[pal + 3], cStem = WR_PAL[pal + 4], cCross = WR_PAL[pal + 5];

    // The eye and this pixel's ray (lerpViewerRay with an identity camera,
    // unnormalised so s = 1 at the glass).
    float3 e = lerpViewerEye(u, F, u.parallax);
    e.z = min(e.z, WR_EYE_MAX * F);
    float3 ro = float3(e.xy, e.z - F);
    float3 d = float3(uv - e.xy, F - e.z);
    d.x = abs(d.x) < 1e-6 ? 1e-6 : d.x;
    d.y = abs(d.y) < 1e-6 ? 1e-6 : d.y;

    // ---- The room: where the ray leaves the box ----
    float3 bound = float3(copysign(hx, d.x), copysign(hy, d.y), D);
    float3 sv = (bound - ro) / d;
    int axis = (sv.x < sv.y) ? (sv.x < sv.z ? 0 : 2) : (sv.y < sv.z ? 1 : 2);
    float sWall = sv[axis];
    float3 P = ro + sWall * d;

    int nGrid = int(u.grid);
    float cell0 = 2.0 * min(hx, hy) / float(nGrid);
    float3 cell = float3(2.0 * hx / max(1.0, round(2.0 * hx / cell0)),
                         2.0 * hy / max(1.0, round(2.0 * hy / cell0)),
                         D / max(1.0, round(D / cell0)));
    float2 q = wrWallGrid(P, axis, hx, hy, cell);
    // Footprint from the neighbouring pixels' rays meeting the same plane.
    float2 qx = wrWallGrid(wrWallPoint(ro, d + float3(px, 0.0, 0.0), bound, axis), axis, hx, hy, cell);
    float2 qy = wrWallGrid(wrWallPoint(ro, d + float3(0.0, px, 0.0), bound, axis), axis, hx, hy, cell);
    float2 fw = abs(qx - q) + abs(qy - q) + 1e-5;
    float2 cellW = axis == 0 ? cell.zy : (axis == 1 ? cell.xz : cell.xy);
    float2 g = abs(fract(q + 0.5) - 0.5);
    float2 wl = WR_LINE / cellW;
    float line = max(wrLineCover(g.x, wl.x, fw.x), wrLineCover(g.y, wl.y, fw.y));
    // Fade the wire where whole cells shrink under a pixel (grazing floor).
    float fine = 1.0 - smoothstep(0.18, 0.45, max(fw.x, fw.y));
    float2 gw = g * cellW;
    float glow = 0.10 * exp(-min(gw.x, gw.y) / 0.03) * fine;
    line *= mix(0.35, 1.0, fine);

    // Corners gather a little darkness.
    float3 toWall = float3(hx - abs(P.x), hy - abs(P.y), D - P.z);
    toWall[axis] = 10.0;
    float ao = 1.0;
    for (int k = 0; k < 3; k++) ao *= mix(0.55, 1.0, smoothstep(0.0, 0.7, toWall[k]));

    float wallTone = axis == 0 ? 0.9 : (axis == 2 ? 0.85 : (P.y < 0.0 ? 1.0 : 0.72));
    float lightZ = wrLight(P.z);

    // ---- Targets: shadows on the room, and fragments for the ray ----
    int nIn = clamp(int(u.targets), 0, WR_MAX_TARGETS);
    int nAll = nIn + WR_POPS;
    float fs[WR_LAYERS];
    float4 fc[WR_LAYERS];
    for (int k = 0; k < WR_LAYERS; k++) { fs[k] = sWall; fc[k] = float4(0.0); }

    float shade = 1.0;
    float plate = 0.0;
    // Key light for the far wall's shadows: up front, above the screen.
    float3 Lk = float3(-0.35 * hx, 1.5 * hy, -0.9 * F);
    for (int i = 0; i < WR_MAX_TARGETS + WR_POPS; i++) {
        if (i >= nAll) break;
        WrTarget T = wrTarget(i, nIn, hx, hy, D, F, u.popout, u.sway, t, u.seed);

        if (axis == 1 && P.y < 0.0) {
            // Floor: a soft overhead shadow. The disc is edge-on to an overhead
            // light, so the blob is long in x and short in z, and it spreads
            // and fades with height.
            float hgt = T.p.y + hy;
            float blur = 0.06 + 0.16 * hgt;
            float2 o = (P.xz - T.p.xz) / float2(T.r + blur, 0.03 + blur);
            float sh = (1.0 - smoothstep(0.1, 1.0, length(o))) * 0.8 / (1.0 + 0.3 * hgt);
            float st = wrSegDist2(P.xz, T.p.xz, T.a.xz);
            sh = max(sh, (1.0 - smoothstep(0.0, 0.02 + 0.07 * hgt, st)) * 0.28 / (1.0 + 0.6 * hgt));
            shade *= 1.0 - sh;
        } else if (axis == 2) {
            // Far wall: the key light's shadow, blurred by the gap behind the disc.
            float k = (D - Lk.z) / (T.p.z - Lk.z);
            float2 S = Lk.xy + (T.p.xy - Lk.xy) * k;
            float rad = T.r * k;
            float blur = 0.03 + 0.07 * (D - T.p.z);
            float sh = (1.0 - smoothstep(rad - blur, rad + blur, length(P.xy - S))) * 0.7;
            float st = wrSegDist2(P.xy, S, T.a.xy);
            sh = max(sh, (1.0 - smoothstep(0.0, WR_STEM * k + 0.5 * blur, st)) * 0.3);
            shade *= 1.0 - sh;
            // The stem's anchor plate.
            float pd = length(P.xy - T.a.xy);
            float fp = px * sWall;
            plate = max(plate, 1.0 - smoothstep(0.03 - 0.5 * fp, 0.03 + 0.5 * fp, pd));
        }

        // The disc: a bullseye of five bands facing the glass, WR_THICK deep.
        // Its silhouette is everything within T.r of the axis anywhere
        // between its two faces, so the edge shows as the head moves aside.
        float sF = (T.p.z - ro.z) / d.z;
        if (sF > 0.0) {
            float sB = (T.p.z + WR_THICK - ro.z) / d.z;
            float2 o = ro.xy - T.p.xy;
            float sm = clamp(-dot(o, d.xy) / dot(d.xy, d.xy), sF, sB);
            float2 hm = o + sm * d.xy;
            float2 hp = o + sF * d.xy;
            float rr = length(hp);
            float fp = px * sF;
            float cover = 1.0 - smoothstep(T.r - 0.5 * fp, T.r + 0.5 * fp, length(hm));
            if (cover > 0.0) {
                float x = rr / T.r * 5.0;                    // band coordinate
                float tri = abs(fract((x - 0.5) * 0.5) - 0.5) * 2.0;
                float bw = 0.5 * fp / T.r * 5.0 + 1e-4;
                float3 c = mix(cB, cA, smoothstep(0.5 - bw, 0.5 + bw, tri));
                // A thin dark rim gives the face an edge.
                c *= 1.0 - 0.55 * smoothstep(T.r - 0.012 - fp, T.r - 0.012, rr);
                // Lit from up front: a gentle gradient across the face.
                c *= 0.88 + 0.12 * clamp(hp.y / T.r, -1.0, 1.0);
                float3 side = cB * 0.38 * (0.7 + 0.3 * clamp(hm.y / T.r, -1.0, 1.0));
                c = mix(side, c, 1.0 - smoothstep(T.r - 0.5 * fp, T.r + 0.5 * fp, rr));
                c *= min(wrLight(T.p.z) * 1.05, 1.0);
                wrPush(fs, fc, sF, float4(c, cover));
            }
        }

        // The stem: back from just behind the disc to the far wall.
        float3 B = T.p + normalize(T.a - T.p) * (WR_THICK + 0.02);
        float3 Ls = T.a - B;
        float3 w0 = ro - B;
        float qa = dot(d, d), qb = dot(d, Ls), qc = dot(Ls, Ls);
        float qd = dot(d, w0), qe = dot(Ls, w0);
        // |d x Ls|^2 is qa*qc - qb^2 without the cancellation: rays near a
        // stem's vanishing point run almost parallel to it.
        float3 dxl = cross(d, Ls);
        float den = max(dot(dxl, dxl), 1e-9);
        float v = clamp((qa * qe - qb * qd) / den, 0.0, 1.0);
        float ss = (qb * v - qd) / qa;
        if (ss > 0.0) {
            float dist = length(w0 + ss * d - v * Ls);
            float fp = px * ss;
            float cover = wrLineCover(dist, WR_STEM, fp);
            if (cover > 0.0) {
                float we = max(WR_STEM, 0.5 * fp);
                float lat = clamp(dist / we, 0.0, 1.0);
                float3 c = cStem * (0.55 + 0.45 * sqrt(1.0 - lat * lat));
                c *= wrLight(B.z + v * Ls.z);
                wrPush(fs, fc, ss, float4(c, cover));
            }
        }
    }

    // ---- The crosshair, in the glass ----
    {
        float2 a = abs(uv);
        float hw = 0.6 * px;
        float arm = 0.055, gap = 0.014, ring = 0.03;
        float hBar = wrLineCover(a.y, hw, px) * step(gap, a.x) * (1.0 - smoothstep(arm - px, arm, a.x));
        float vBar = wrLineCover(a.x, hw, px) * step(gap, a.y) * (1.0 - smoothstep(arm - px, arm, a.y));
        float rng = wrLineCover(abs(length(uv) - ring), hw, px);
        float cover = 0.85 * max(max(hBar, vBar), rng);
        wrPush(fs, fc, 1.0, float4(cCross, cover));
    }

    // ---- Composite ----
    float3 wall = cWall * wallTone * ao;
    wall += cLine * (line + glow);
    wall = mix(wall, cStem * 0.6, plate);
    // The key light pools on the far wall, where its shadows fall.
    float pool = 1.0;
    if (axis == 2) {
        float2 sp = (P.xy - float2(-0.25 * hx, 0.2 * hy)) / float2(hx, hy);
        pool += 1.4 * exp(-dot(sp, sp) / 0.35);
    }
    float3 back = wall * lightZ * shade * pool;

    float3 color = float3(0.0);
    float trans = 1.0;
    for (int k = 0; k < WR_LAYERS; k++) {
        if (fs[k] >= sWall) break;
        color += trans * fc[k].a * fc[k].rgb;
        trans *= 1.0 - fc[k].a;
    }
    color += trans * back;

    color = lerpDither(color, pos);
    return half4(half3(saturate(color)), 1.0h);
}
