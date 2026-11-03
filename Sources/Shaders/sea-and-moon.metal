// Sea and Moon — ported from Shadertoy "Sea and moon" by mrange (Mårten Rånge)
// https://www.shadertoy.com/view/csfXzN  (2022-11-15)
// Upstream licence line, verbatim: "// License CC0: Sea and moon"
// (CC0 1.0, https://creativecommons.org/publicdomain/zero/1.0/)
//
// Upstream: "Tinkering with the colors of an old shaders to make it a better
// fit for windows terminal". An analytic ocean — a sum of gravity and
// capillary waves with analytic normals — under a low moon, viewed from a
// fixed camera. One ray-plane hit per pixel, no marching. Port notes:
// - Upstream's `tanh_approx` helper carries "License: Unknown"; this port
//   does not include it and calls Metal's built-in `tanh` instead (with
//   k*h >= 25 both evaluate to 1.0, so the look is unchanged).
// - Time runs at 0.5x upstream, offset by `u.seed`, so the swell is calm and
//   each activation starts on a different sea. `speed` is added by this
//   port (upstream is fixed at 1x, which the "Upstream" preset restores).
// - `gravity`, `waterTension` and the six colours are upstream's own
//   constants, exposed with upstream's names. Upstream builds the sky and
//   moon colours with a `.zyx` swizzle and scales; the defaults below are
//   those results. The "Old sunset" preset drops the swizzle, giving a warm
//   sky and sun from the same constants.
// - GPU cost: 8 analytic waves per pixel, about the cheapest shader here.
//
// lerp-param: gravity      float 0.2 4  = 1.0  "Gravity"
// lerp-param: waterTension float 0 0.1  = 0.01 "Water tension"
// lerp-param: skyCol1 color = (0.15, 0.175, 0.3) "Sky, horizon"
// lerp-param: skyCol2 color = (0.15, 0.15, 0.5)  "Sky, zenith"
// lerp-param: sunCol1 color = (0.4, 0.5, 1.0)    "Moon glow"
// lerp-param: sunCol2 color = (0.8, 0.8, 1.0)    "Moon disc"
// lerp-param: seaCol1 color = (0.02, 0.04, 0.04) "Sea, deep"
// lerp-param: seaCol2 color = (0.1, 0.45, 0.3)   "Sea, crest"
// lerp-param: speed   float 0 2 = 0.5            "Speed"
//
// lerp-preset: "Old sunset" skyCol1=(0.3, 0.175, 0.15), skyCol2=(0.5, 0.15, 0.15)
// lerp-preset: "Old sunset" sunCol1=(1.0, 0.5, 0.4), sunCol2=(1.0, 0.8, 0.8)
// lerp-preset: Upstream speed=1.0

static float2 seaWave(float t, float a, float w, float p) {
    return float2(t, a * sin(t * w + p));
}

static float2 seaDWave(float t, float a, float w, float p) {
    return float2(1.0, a * w * cos(t * w + p));
}

static float seaGravityW(float k, float h, float g) {
    return sqrt(g * k * tanh(k * h));
}

static float seaCapillaryW(float k, float h, float g, float tension) {
    return sqrt((g * k + tension * k * k * k) * tanh(k * h));
}

static float2 seaRot(float2 p, float a) {
    float c = cos(a);
    float s = sin(a);
    return float2(c * p.x + s * p.y, -s * p.x + c * p.y);
}

static float4 seaSea(float2 p, float ia, float time, float g, float tension) {
    float y = 0.0;
    float3 d = float3(0.0);

    const int maxIter = 8;
    const int midIter = 4;

    float kk = 1.0 / 1.3;
    float aa = 1.0 / (kk * kk);
    float k = 1.0 * pow(kk, -float(maxIter) + 1.0);
    float a = ia * 0.25 * pow(aa, -float(maxIter) + 1.0);

    float h = 25.0;
    p *= 0.5;

    float2 waveDir = float2(0.0, 1.0);

    for (int i = midIter; i < maxIter; ++i) {
        float t = dot(-waveDir, p) + float(i);
        float w = seaCapillaryW(k, h, g, tension);
        y += seaWave(t, a, k, w * time).y;
        float2 dw = seaDWave(-t, a, k, w * time);
        d += float3(waveDir.x, dw.y, waveDir.y);
        waveDir = seaRot(waveDir, PI / 3.0);
        k *= kk;
        a *= aa;
    }

    waveDir = float2(0.0, 1.0);

    for (int i = 0; i < midIter; ++i) {
        float t = dot(waveDir, p) + float(i);
        float w = seaGravityW(k, h, g);
        y += seaWave(t, a, k, w * time).y;
        float2 dw = seaDWave(t, a, k, w * time);
        d += float3(waveDir.x, dw.y, waveDir.y);
        waveDir = seaRot(waveDir, -step(2.0, float(i)));
        k *= kk;
        a *= aa;
    }

    float3 t = normalize(d);
    float3 nxz = normalize(float3(t.z, 0.0, -t.x));
    float3 nor = cross(t, nxz);

    return float4(y, nor);
}

static float3 seaSkyColor(float3 rd, constant LerpUniforms& u) {
    const float3 sunDir = normalize(float3(0.0, 0.06, 1.0));
    float sunDot = max(dot(rd, sunDir), 0.0);
    float3 final = float3(0.0);
    final += mix(u.skyCol1.rgb, u.skyCol2.rgb, rd.y);
    final += 0.5 * u.sunCol1.rgb * pow(sunDot, 90.0);
    final += 4.0 * u.sunCol2.rgb * pow(sunDot, 900.0);
    return final;
}

static float3 seaRender(float3 ro, float3 rd, float time, constant LerpUniforms& u) {
    float3 col = float3(0.0);
    float dsea = (0.0 - ro.y) / rd.y;
    const float3 sunDir = normalize(float3(0.0, 0.06, 1.0));
    float3 sky = seaSkyColor(rd, u);

    if (dsea > 0.0) {
        float3 p = ro + dsea * rd;
        float4 s = seaSea(p.xz, 1.0, time, u.gravity, u.waterTension);
        float h = s.x;
        float3 nor = s.yzw;
        nor = mix(nor, float3(0.0, 1.0, 0.0), smoothstep(0.0, 200.0, dsea));

        float fre = clamp(1.0 - dot(-nor, rd), 0.0, 1.0);
        fre = fre * fre * fre;
        float dif = mix(0.25, 1.0, max(dot(nor, sunDir), 0.0));

        float3 refl = seaSkyColor(reflect(rd, nor), u);
        float3 refr = u.seaCol1.rgb + dif * u.sunCol1.rgb * u.seaCol2.rgb * 0.1;

        col = mix(refr, 0.9 * refl, fre);

        float atten = max(1.0 - dsea * dsea * 0.001, 0.0);
        col += u.seaCol2.rgb * (p.y - h) * 2.0 * atten;

        col = mix(col, sky, 1.0 - exp(-0.01 * dsea));
    } else {
        col = sky;
    }

    return col;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // Upstream: p in [-1, 1] vertically, x scaled by the aspect, y up.
    float2 frag = float2(pos.x, u.resolution.y - pos.y);
    float2 q = frag / u.resolution;
    float2 p = -1.0 + 2.0 * q;
    p.x *= u.resolution.x / u.resolution.y;
    float time = u.speed * u.time + u.seed * 300.0;

    float3 ro = float3(0.0, 10.0, 0.0);
    float3 ww = normalize(float3(0.0, -0.1, 1.0));
    float3 uu = normalize(cross(float3(0.0, 1.0, 0.0), ww));
    float3 vv = normalize(cross(ww, uu));
    float3 rd = normalize(p.x * uu + p.y * vv + 2.5 * ww);

    float3 color = max(seaRender(ro, rd, time, u), 0.0);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
