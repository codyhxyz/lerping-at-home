// Pulse Rings — ported from "pulse" by gman (Gregg Tavares) on vertexshaderart.com (CC0)
// https://www.vertexshaderart.com/art/JnRaHZcXYv7WBhq5b
// Licence: "Note: All the shaders I've posted are licensed CC0" (gman's
// vertexshaderart profile), and "Any art by "gman" is CC0" in the site's
// LICENSE.md (https://github.com/greggman/vertexshaderart.com).
//
// Upstream is a *vertex* shader: 10000 POINTS, each placed from its vertexId on
// one of 99 rings of 51 points. Ring `count` sits at radius count*0.02 plus a
// pulse of 0.2*sin(3t - 0.05*count)^4 and the whole set turns at 1 rad/s. This
// engine has only a fullscreen fragment function, so the point set is
// evaluated in reverse, per pixel: a ring can only reach radius rho if
// count*0.02 lies in [rho - 0.2 - size, rho + size], so each pixel visits ~13
// of the 99 rings, and on each ring only the points near it in angle: the
// nearest and one either side out where points are far apart, more in the
// middle where the squares overlap their neighbours.
// Cost is bounded per pixel and independent of the 10000-point count.
//
// Kept from upstream: the ring/point layout and its doubled vertices (each of
// the 51 points is emitted twice, so ring 98 has only points 0, 1, 5 and 6),
// the square gl_PointSize of 2 + 20 px * length * width/1600 (in CSS pixels,
// as vertexshaderart sizes its canvas; see `pointBase`), fit-to-width
// aspect, the colour mix(hsv(hue, 1 - pulse, 1), background, length - pulse)
// clamped as the framebuffer would, and the draw order: vertexshaderart draws
// with depth test LESS and every point at z = 0, so at any pixel the
// *first-drawn* point wins — lower rings over higher ones. The port composites
// front to back in that order, with box-filtered square coverage so the
// slowed motion doesn't shimmer.
//
// Port additions, not in upstream: `speed` (upstream runs at 1x; slowed here
// for a screensaver) and the per-launch seed offset into time. `background` is
// upstream's backgroundColor setting, black in the original.
//
// lerp-param: speed      float 0 2 = 0.3        "Speed"
// lerp-param: background color    = (0, 0, 0)  "Background"
//
// lerp-preset: Upstream  speed=1

constant float PR_SEGMENTS = 51.0;     // NUM_SEGMENTS
constant float PR_RING_STEP = 0.02;    // radius per ring (count * 0.02)
constant float PR_PULSE = 0.2;         // rPlus * 0.2
constant float PR_LAST_RING = 98.0;    // floor(9999 / 102)
constant int   PR_MAX_RINGS = 24;      // loop bound; ~13 are ever in range
constant float PR_COS_STEP = 0.99242051;  // cos(2pi/51)
constant float PR_SIN_STEP = 0.12288829;  // sin(2pi/51)

static inline float3 prHsv2rgb(float3 c) {
    c = float3(c.x, clamp(c.yz, 0.0, 1.0));
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// Ring 98 is cut short by the 10000-vertex count: only points 0, 1, 5, 6.
static inline bool prOnLastRing(float k) {
    float km = glmod(k, PR_SEGMENTS);
    return km == 0.0 || km == 1.0 || km == 5.0 || km == 6.0;
}

// Box-filter coverage of the pixel [px-0.5, px+0.5]^2 by an axis-aligned
// square of half-size h centred at c (all in framebuffer pixels).
static inline float prSquareCoverage(float2 px, float2 c, float h) {
    float2 lo = max(px - 0.5, c - h);
    float2 hi = min(px + 0.5, c + h);
    float2 o = clamp(hi - lo, 0.0, 1.0);
    return o.x * o.y;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float W = u.resolution.x, H = u.resolution.y;
    float t = u.speed * u.time + 60.0 * u.seed;

    // Upstream: gl_Position = xy * vec2(1, W/H), i.e. one xy unit is W/2
    // pixels on both axes, y up.
    float s = 0.5 * W;
    float2 centre = 0.5 * u.resolution;
    float2 q = float2(pos.x - centre.x, centre.y - pos.y) / s;
    float rho = length(q);
    float phi = atan2(q.y, q.x);

    // gl_PointSize = 2 + length * 20 * resolution.x / 1600, all in the CSS
    // pixels vertexshaderart's canvas is sized in. In framebuffer pixels the
    // slope term is unchanged (it already scales with width); the constant
    // becomes 2 CSS px, taking max(1, short side / 1000) px per CSS px.
    float pointBase = 2.0 * max(1.0, min(W, H) / 1000.0);
    float sizeK = 20.0 * W / 1600.0;                 // px per xy unit
    // Largest half-size any point that could touch this pixel can have.
    float hMax = (0.5 * (pointBase + (rho + 0.5) * sizeK) + 1.0) / s;
    float cLo = max(0.0, floor((rho - PR_PULSE - 1.5 * hMax) / PR_RING_STEP));
    float cHi = min(PR_LAST_RING, ceil((rho + 1.5 * hMax) / PR_RING_STEP));

    float3 acc = float3(0.0);
    float alpha = 0.0;
    float angStep = TWO_PI / PR_SEGMENTS;
    float tRot = glmod(t, TWO_PI);

    for (int i = 0; i < PR_MAX_RINGS; i++) {
        float count = cLo + float(i);
        if (count > cHi || alpha > 0.998) break;

        float sn = sin(tRot * 3.0 - count * 0.05);   // 3*tRot keeps sin(3t)'s phase
        float rPlus = (sn * sn) * (sn * sn);         // pow(sin(...), 4.0)
        float radius = count * PR_RING_STEP + rPlus * PR_PULSE;
        float hp = 0.5 * (pointBase + radius * sizeK); // half point size, px
        if (abs(radius - rho) * s > hp * 1.4143 + 1.0) continue;

        // angle = point * 2pi/51 - count*0.02, then + time. The time term
        // has period 2pi, so wrap it before it meets the small offsets.
        float base = tRot - count * 0.02;
        float k0 = round((phi - base) / angStep);
        float a0 = base + k0 * angStep;
        // A point can touch this pixel only within `reach` px of it, so at
        // most asin(reach / (radius * s)) rad from phi; k0 is up to half a
        // spacing off phi, so walk floor(that / angStep + 0.5) neighbours
        // each way (ceil for slack), and the whole ring (25 either side of
        // k0 is all 51) once reach exceeds the ring's radius. At the rim that
        // is one each way, as before. Near the middle the squares are wider
        // than the gaps between them (ring 1 at rest: 1.7-px spacing, 2.3-px
        // squares), and checking only k0 +/- 1 there cut corners off squares
        // in the inner two rings: up to 12/255 against a brute-force render
        // of all 5049 squares, which this now matches to 1/255 everywhere.
        float reach = hp * 1.4143 + 1.0;
        float ratio = reach / max(radius * s, 1e-3);
        int nSide = ratio >= 1.0 ? 25 : int(min(25.0, ceil(asin(ratio) / angStep + 0.5)));
        // One sincos for the nearest point; its neighbours are that vector
        // turned by -/+ one point spacing at a time.
        float2 d0 = float2(cos(a0), sin(a0));
        float2 c0 = centre + float2(d0.x, -d0.y) * (radius * s);
        bool lastRing = count == PR_LAST_RING;
        float cov = 0.0;
        if (!lastRing || prOnLastRing(k0)) cov = prSquareCoverage(pos.xy, c0, hp);
        float2 dm = d0, dp = d0;
        for (int j = 1; j <= nSide; j++) {
            dm = float2(dm.x * PR_COS_STEP + dm.y * PR_SIN_STEP, dm.y * PR_COS_STEP - dm.x * PR_SIN_STEP);
            dp = float2(dp.x * PR_COS_STEP - dp.y * PR_SIN_STEP, dp.y * PR_COS_STEP + dp.x * PR_SIN_STEP);
            if (!lastRing || prOnLastRing(k0 - float(j)))
                cov = max(cov, prSquareCoverage(pos.xy, centre + float2(dm.x, -dm.y) * (radius * s), hp));
            if (!lastRing || prOnLastRing(k0 + float(j)))
                cov = max(cov, prSquareCoverage(pos.xy, centre + float2(dp.x, -dp.y) * (radius * s), hp));
        }
        if (cov <= 0.0) continue;

        float hue = t * 0.01 + count * 1.001;
        float3 col = mix(prHsv2rgb(float3(hue, 1.0 - rPlus, 1.0)), u.background.rgb, radius - rPlus);
        col = saturate(col);

        // First-drawn wins: composite this ring *under* everything nearer the
        // front of the draw order.
        acc += (1.0 - alpha) * cov * col;
        alpha += (1.0 - alpha) * cov;
    }

    float3 color = acc + (1.0 - alpha) * u.background.rgb;
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
