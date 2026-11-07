// Depth Window — a photograph made into a window. The picture sits on the
// glass and what it shows recedes behind it by its own depth map, so a
// tracked head looks round the near things at the far ones.
//
// Lerping's own (AGPL-3.0). The default picture, `depth-window`, is made by
// `make images` (scripts/depth-window-default.swift): a procedural dusk lake
// drawn together with its exact depth, so it needs no model and carries no
// third-party licence. `make depth-window IMAGE=photo.jpg NAME=beach` makes a
// look of your own photo, its depth estimated on this Mac by Depth Anything V2
// Small through Core ML (scripts/depth-window.swift).
//
// How. The photo is a heightfield in the centred camera's own projective
// space: the pixel at screen point q lies on the ray from the centred eye
// through q, at a depth set by its nearness — the nearest thing on the glass,
// the farthest `depth` focal lengths behind it. From the centred eye every ray
// therefore meets exactly the pixel it passes through, and the look is the
// photo, untouched: that is the saver, every snapshot and every gallery still.
// From any other eye (`lerpViewerEye`, the same off-axis camera as every
// parallax look) each pixel's ray is marched through the heightfield — a
// linear search, then a binary refine: relief mapping.
//
// Disocclusion. Where the head uncovers what a near thing hid, the photo has
// nothing to show. A bare heightfield fills the gap with the near thing's rim,
// stretched like a rubber sheet. Those are exactly the pixels where the hit
// barely moves from one screen pixel to the next, so the screen-space
// derivative of the hit finds them, and there the colour is taken from the far
// side of the depth edge instead: the background is stretched into the gap, not
// the foreground's rim. From the centred eye the derivative is the plain one
// everywhere, so this never touches the photo.
//
// Fit: the photo covers the screen (cropped, never stretched; distances are
// in short-side units), plus `margin` of overscan for the head to look past.
//
// lerp-category: Scenes
// lerp-data: image:depth-window
//
// lerp-param: parallax float 0 2   = 1    "Head parallax"
// lerp-param: depth    float 0 2   = 0.6  "Depth (focal lengths behind the glass)"
// lerp-param: margin   float 0 0.3 = 0.06 "Overscan"
// lerp-param: sway     float 0 1   = 0    "Idle sway (an imagined head, for the saver)"
//
// lerp-preset: Drifting sway=0.6

// Distance from the eye to the glass, in short-side half-widths: about a
// 37° view across the short side, a screen at arm's length.
constant float DW_FOCAL = 3.0;

// Nearness at screen point q: 1 nearest, 0 farthest.
static inline float dwNear(texture2d<float> depth, float2 q, float2 halfExt) {
    float2 st = float2(0.5 + 0.5 * q.x / halfExt.x, 0.5 - 0.5 * q.y / halfExt.y);
    return depth.sample(lerpImageSampler, st, level(0.0)).r;
}

// Where the ray from eye E (ez = E.z / focal) through glass point uv is, in
// the photo's screen coordinates, once it is s of the way from the glass to the
// back (w = k·s focal lengths behind the glass). Written so E = 0 returns uv
// bit for bit: the centred look is the photo, not a rounding of it.
static inline float2 dwAt(float2 uv, float2 exy, float ez, float k, float s) {
    float w = k * s;
    float c = w / ((1.0 + w) * (1.0 - ez));
    return uv * (1.0 + ez * c) - c * exy;
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        texture2d<float> photo [[texture(1)]],
                        texture2d<float> depth [[texture(2)]]) {
    float2 res = u.resolution;
    float minRes = min(res.x, res.y);
    float2 uv = lerpUV(pos, res);

    // Cover fit, aspect-correct: the photo's half extents in uv units.
    float2 photoSize = float2(photo.get_width(), photo.get_height());
    float aspect = photoSize.x / photoSize.y;
    float2 screenHalf = res / minRes;
    float hy = max(screenHalf.y, screenHalf.x / aspect);
    float2 halfExt = float2(hy * aspect, hy) * (1.0 + u.margin);

    // Screen pixels → photo texels, for the mip level and for sizing steps.
    float2 depthSize = float2(depth.get_width(), depth.get_height());
    float2 depthTexel = 2.0 * halfExt / depthSize;          // uv per depth texel
    float lod = max(0.0, log2((photoSize.y / (2.0 * halfExt.y)) * (2.0 / minRes)));

    // The eye: the tracked head, plus an imagined one wandering slowly when
    // `sway` is up (0 by default, so the saver shows the photo as it is).
    float3 E = lerpViewerEye(u, DW_FOCAL, u.parallax);
    float t = u.time + u.seed * 400.0;
    E.xy += u.sway * DW_FOCAL * 0.07 * float2(sin(t * 0.071), 0.45 * sin(t * 0.053 + 1.7));
    float ez = min(E.z / DW_FOCAL, 0.8);
    float k = u.depth;
    bool moved = (E.x != 0.0 || E.y != 0.0 || ez != 0.0) && k > 0.0;

    float2 q = uv;
    if (moved) {
        // As many steps as the ray crosses depth texels, give or take.
        float2 q1 = dwAt(uv, E.xy, ez, k, 1.0);
        float travel = length((q1 - uv) / depthTexel);
        int n = clamp(int(travel * 0.75) + 4, 4, 96);

        // Linear search from the glass back: the first sample at or behind
        // the surface. Depth fraction s, 0 on the glass, 1 at the back.
        float lo = 0.0, hi = 1.0;
        for (int i = 0; i <= n; i++) {
            float s = float(i) / float(n);
            float surface = 1.0 - dwNear(depth, dwAt(uv, E.xy, ez, k, s), halfExt);
            if (s >= surface) { hi = s; break; }
            lo = s;
        }
        // Binary refine between the last sample in front and the first behind.
        for (int i = 0; i < 6 && hi > lo; i++) {
            float mid = 0.5 * (lo + hi);
            float surface = 1.0 - dwNear(depth, dwAt(uv, E.xy, ez, k, mid), halfExt);
            if (mid >= surface) hi = mid; else lo = mid;
        }
        q = dwAt(uv, E.xy, ez, k, hi);
    }

    float2 st = float2(0.5 + 0.5 * q.x / halfExt.x, 0.5 - 0.5 * q.y / halfExt.y);
    float3 color = photo.sample(lerpImageSampler, st, level(lod)).rgb;

    if (moved) {
        // How much screen one pixel's worth of hit covers: 1 for the photo as
        // it was, near 0 where neighbouring rays all land on one depth cliff.
        float2 dqx = dfdx(q), dqy = dfdy(q);
        float stretch = sqrt(abs(dqx.x * dqy.y - dqx.y * dqy.x)) * (0.5 * minRes);
        float fill = 1.0 - smoothstep(0.2, 0.55, stretch);
        if (fill > 0.0) {
            // Toward the deeper side of the cliff, past its ramp, to the
            // farthest thing within reach: that is what the gap should show.
            float2 ox = float2(3.0 * depthTexel.x, 0.0), oy = float2(0.0, 3.0 * depthTexel.y);
            float2 g = float2(dwNear(depth, q + ox, halfExt) - dwNear(depth, q - ox, halfExt),
                              dwNear(depth, q + oy, halfExt) - dwNear(depth, q - oy, halfExt));
            float2 dir = -g / max(length(g), 1e-5);
            float stepLen = 1.5 * max(depthTexel.x, depthTexel.y);
            float best = dwNear(depth, q, halfExt);
            float2 qb = q;
            for (int i = 1; i <= 10; i++) {
                float2 p = q + dir * (float(i) * stepLen);
                float nearness = dwNear(depth, p, halfExt);
                if (nearness < best - 0.002) { best = nearness; qb = p; }
            }
            qb += dir * (2.0 * stepLen);   // clear of the rim's mixed pixels
            float2 sb = float2(0.5 + 0.5 * qb.x / halfExt.x, 0.5 - 0.5 * qb.y / halfExt.y);
            float3 behind = photo.sample(lerpImageSampler, sb, level(lod)).rgb;
            color = mix(color, behind, fill);
        }
    }

    // No dither: the photo is already quantised, and the centred look is
    // meant to be its pixels exactly.
    return half4(half3(color), 1.0h);
}
