// Paper Texture — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// A sheet of paper built entirely out of noise: cell-based crumples, curly
// fibre noise, screen-space roughness, sparse speckle drops and a set of
// folds, all summed into a normal and lit by a single directional light.
// Upstream renders one still frame; this port orbits the light and walks the
// fold anchors around so the relief keeps catching the light. The optional
// u_image layer is dropped (a screensaver has nothing to composite) and the
// noise-texture randomizers become the prelude's hash21 / hash22.

// Parameters mirror the upstream <PaperTexture> props. Upstream's fixed
// `seed` prop is replaced by this project's per-launch `u.seed`. `speed` is
// this port's own addition — upstream renders one still frame, and this is the
// rate the light and fold anchors drift at.
//
// lerp-param: colorFront   color        = (0.694, 0.596, 0.455) "Paper"
// lerp-param: colorBack    color        = (0.043, 0.031, 0.043) "Shadow"
// lerp-param: contrast     float 0 1    = 0.60 "Contrast"
// lerp-param: roughness    float 0 1    = 0.40 "Roughness"
// lerp-param: fiber        float 0 1    = 0.28 "Fiber"
// lerp-param: fiberSize    float 0.01 1 = 0.65 "Fiber size"
// lerp-param: crumples     float 0 1    = 0.60 "Crumples"
// lerp-param: crumpleSize  float 0.01 1 = 0.55 "Crumple size"
// lerp-param: folds        float 0 1    = 0.70 "Folds"
// lerp-param: foldCount    int 1 15     = 7    "Fold count"
// lerp-param: fade         float 0 1    = 0.35 "Fade"
// lerp-param: drops        float 0 1    = 0.30 "Drops"
// lerp-param: speed        float 0 1    = 0.10 "Drift speed"
//
// Upstream presets, restricted to the props this port implements.
// lerp-preset: Cardboard colorFront=#c7b89e, colorBack=#999180, contrast=0.4
// lerp-preset: Cardboard roughness=0, fiber=0.35, fiberSize=0.14, crumples=0.7
// lerp-preset: Cardboard crumpleSize=0.1, folds=0, foldCount=1, fade=0, drops=0.1
// lerp-preset: Abstract  colorFront=#00eeff, colorBack=#ff0a81, contrast=0.85
// lerp-preset: Abstract  roughness=0, fiber=0.1, fiberSize=0.2, crumples=0.01
// lerp-preset: Abstract  crumpleSize=0.3, folds=1, foldCount=3, fade=0, drops=0.2
// lerp-preset: Details   colorFront=#ffffff, colorBack=#000000, contrast=0.01
// lerp-preset: Details   roughness=1, fiber=0.27, fiberSize=0.22, crumples=1
// lerp-preset: Details   crumpleSize=0.5, folds=1, foldCount=15, fade=0, drops=0.01

// Upstream reads these out of a pre-baked noise texture; a per-cell hash is
// the same thing without the sampler.
static float  ptCellRand1(float2 p) { return hash21(floor(p)); }
static float2 ptCellRand2(float2 p) { return hash22(floor(p)); }

// Screen-space paper roughness: 3 octaves of cell noise plus a directional
// ridge term, so the grain has a faint machine direction like real stock.
static float ptRoughness(float2 p) {
    p *= 0.1;
    float o = 0.0;
    for (int i = 0; i < 3; i++) {
        float4 w = float4(floor(p), ceil(p));
        float2 f = fract(p);
        o += mix(mix(ptCellRand1(w.xy), ptCellRand1(w.xw), f.y),
                 mix(ptCellRand1(w.zy), ptCellRand1(w.zw), f.y), f.x);
        o += 0.2 / exp(2.0 * abs(sin(0.2 * p.x + 0.5 * p.y)));
        p *= 2.1;
    }
    return o / 3.0;
}

// Curly fibre noise: the gradient magnitude of a rotated fBm, which draws
// hair-like filaments instead of blobs.
static float ptFiberRand(float2 p) { return hash21(floor(p) + 37.7); }

static float ptFiberValueNoise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = ptFiberRand(i);
    float b = ptFiberRand(i + float2(1.0, 0.0));
    float c = ptFiberRand(i + float2(0.0, 1.0));
    float d = ptFiberRand(i + float2(1.0, 1.0));
    float2 uu = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, uu.x), mix(c, d, uu.x), uu.y);
}

static float ptFiberFbm(float2 n) {
    float total = 0.0, amplitude = 1.0;
    for (int i = 0; i < 3; i++) {
        n = rotate(n, 0.7);
        total += ptFiberValueNoise(n) * amplitude;
        n *= 2.0;
        amplitude *= 0.6;
    }
    return total;
}

static float ptFiberNoise(float2 uv) {
    const float eps = 0.001;
    float n0 = ptFiberFbm(uv);
    float nx = ptFiberFbm(uv + float2(eps, 0.0));
    float ny = ptFiberFbm(uv + float2(0.0, eps));
    return length(float2(nx - n0, ny - n0)) / eps;
}

// Cell-based crumple pattern: jittered points weighted by a separable
// smoothstep falloff, tiled every 8 cells like upstream.
// Both call sites use a compile-time exponent (16 and 2), and pow() is by
// far the most expensive op in this shader, so square them out by hand.
static float ptPow16(float x) { float a = x * x; a *= a; a *= a; return a * a; }

// Evaluated at `t` and `t + d` in a single sweep of the 3x3 neighbourhood.
// The offset is a tiny finite difference used to turn the field into a
// normal, so both points share a neighbourhood and the per-cell hash and
// sine get paid once rather than twice — this loop is ~40% of the shader.
static float2 ptCrumpledPair(float2 t, float2 d, bool sharp) {
    float2 p = floor(t);
    float2 wsum = float2(0.0);
    float2 cl = float2(0.0);
    for (int y = -1; y < 2; y++) {
        for (int x = -1; x < 2; x++) {
            float2 q = float2(float(x), float(y)) + p;
            float2 q2 = q - floor(q / 8.0) * 8.0;
            float2 c = q + ptCellRand2(q2);
            float amp = 0.5 + 0.5 * sin((q2.x + q2.y * 5.0) * 8.0);

            float2 r0 = c - t;
            float2 r1 = r0 - d;
            float sx0 = smoothstep(0.0, 1.0, 1.0 - abs(r0.x));
            float sy0 = smoothstep(0.0, 1.0, 1.0 - abs(r0.y));
            float sx1 = smoothstep(0.0, 1.0, 1.0 - abs(r1.x));
            float sy1 = smoothstep(0.0, 1.0, 1.0 - abs(r1.y));
            float2 w = sharp
                ? float2(ptPow16(sx0) * ptPow16(sy0), ptPow16(sx1) * ptPow16(sy1))
                : float2(sx0 * sx0 * sy0 * sy0, sx1 * sx1 * sy1 * sy1);

            cl += amp * w;
            wsum += w;
        }
    }
    return sqrt(cl / max(wsum, 1e-20)) * 2.0;
}

// float2(shape(uv), shape(uv + d)).
static float2 ptCrumplesShapePair(float2 uv, float2 d) {
    return ptCrumpledPair(uv * 0.25, d * 0.25, true)
         * ptCrumpledPair(uv * 0.5,  d * 0.5,  false);
}

// Nearest-anchor field: the direction to the closest fold anchor, faded out
// as you approach it, which reads as a crease running through the sheet.
// Upstream picks the anchors from a hashed seed; here they orbit slowly so
// the creases migrate instead of sitting still.
static float2 ptFolds(float2 uv, float t, int foldCount) {
    float3 pp = float3(0.0);
    float l = 9.0;
    for (int i = 0; i < foldCount; i++) {
        float2 rnd = hash22(float2(float(i) * 3.7 + 1.0, float(i) * 1.9 + 5.0));
        float an = rnd.x * TWO_PI + 0.35 * t * (0.4 + 0.6 * rnd.y);
        float2 p = float2(cos(an), sin(an)) * (0.25 + 0.7 * rnd.y);
        float dist = distance(uv, p);
        l = min(l, dist);
        if (l == dist) {
            pp.xy = uv - p;
            pp.z = dist;
        }
    }
    return mix(pp.xy, float2(0.0), sqrt(sqrt(pp.z)));
}

// Sparse speckles — the multiplicative distance accumulator is upstream's,
// and is what keeps them rare.
static float ptDrops(float2 uv, float seed) {
    float2 iUV = floor(uv);
    float2 fUV = fract(uv);
    float minDist = 1.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 neighbor = float2(float(i), float(j));
            float2 offset = ptCellRand2(iUV + neighbor);
            offset = 0.5 + 0.5 * sin(10.0 * seed + TWO_PI * offset);
            float2 q = neighbor + offset - fUV;
            float dist = length(q);
            minDist = min(minDist, minDist * dist);
        }
    }
    return 1.0 - smoothstep(0.05, 0.09, sqrt(minDist));
}

static float ptFbm(float2 n) {
    float total = 0.0, amplitude = 0.4;
    for (int i = 0; i < 3; i++) {
        total += valueNoise(n) * amplitude;
        n *= 1.99;
        amplitude *= 0.65;
    }
    return total;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // 5 * (imageUV - .5) * aspect, i.e. 2.5 units on the short axis.
    float2 patternUV = 2.5 * lerpUV(pos, u.resolution);

    float t = u.speed * u.time + 30.0 * u.seed;
    float seed = 4.0 * u.seed + 0.03 * t;

    // Roughness lives in screen space so it behaves like film grain.
    float2 roughnessUv = 1.5 * (float2(pos.x, u.resolution.y - pos.y) - 0.5 * u.resolution);
    float roughness = ptRoughness(roughnessUv + float2(1.0, 0.0))
                    - ptRoughness(roughnessUv - float2(1.0, 0.0));

    float2 crumplesUV = fract(patternUV * 0.02 / u.crumpleSize - seed) * 32.0;
    float2 crumplePair = ptCrumplesShapePair(crumplesUV, float2(0.05, 0.0));
    float crumples = u.crumples * (crumplePair.y - crumplePair.x);

    float2 fiberUV = 2.0 / u.fiberSize * patternUV;
    float fiber = ptFiberNoise(fiberUV);
    fiber = 0.5 * u.fiber * (fiber - 1.0);

    float2 foldsUV = rotate(patternUV * 0.12, 4.0 * u.seed);
    float2 w = ptFolds(foldsUV, t, u.foldCount);
    float2 w2 = ptFolds(rotate(foldsUV + 0.007 * cos(seed), 0.01 * sin(seed)), t, u.foldCount);

    float drops = u.drops * ptDrops(patternUV * 2.0, seed);

    float fade = u.fade * ptFbm(0.17 * patternUV + 10.0 * u.seed);
    fade = clamp(8.0 * fade * fade * fade, 0.0, 1.0);

    w = mix(w, float2(0.0), fade);
    w2 = mix(w2, float2(0.0), fade);
    crumples = mix(crumples, 0.0, fade);
    drops = mix(drops, 0.0, fade);
    fiber *= mix(1.0, 0.5, fade);
    roughness *= mix(1.0, 0.5, fade);

    float2 normal = float2(0.0);
    normal += u.folds * min(5.0 * u.contrast, 1.0) * 4.0 * max(float2(0.0), w + w2);
    normal += crumples;
    normal += 3.0 * drops;
    normal += u.roughness * 1.5 * roughness;
    normal += fiber;

    // Upstream's fixed vec3(1, 2, 1) light, put on a slow orbit so the relief
    // keeps changing which way it catches the light.
    float la = 0.45 * t;
    float3 lightPos = float3(1.4 * cos(la), 1.6 + 0.9 * sin(la), 1.0);

    float res = dot(normalize(float3(normal, 9.5 - 9.0 * pow(u.contrast, 0.1))),
                    normalize(lightPos));

    float3 color = u.colorFront.rgb * res;
    float opacity = res;
    color += u.colorBack.rgb * (1.0 - opacity);
    color -= 0.007 * drops;
    color = clamp(color, 0.0, 1.0);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
