// Perlin Noise — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Original algorithm: https://www.shadertoy.com/view/NlSGDz
// Classic 3D Perlin fBm sliced along z = time, mapped to a two-colour ramp.
//
// Parameters mirror the upstream <PerlinNoise> props. `scale` is in this
// port's units, not upstream's sizing system; `speed` is capped low because
// the fBm multiplies the z slice by the octave frequency.
//
// lerp-param: colorFront  color         = (0.902, 0.435, 0.204) "Front"
// lerp-param: colorBack   color         = (0.035, 0.024, 0.086) "Background"
// lerp-param: scale       float 0.02 1  = 0.16 "Scale"
// lerp-param: octaveCount int 1 8       = 4    "Octaves"
// lerp-param: persistence float 0.3 1   = 0.45 "Persistence"
// lerp-param: lacunarity  float 1.5 10  = 2.0  "Lacunarity"
// lerp-param: proportion  float 0 1     = 0.40 "Proportion"
// lerp-param: softness    float 0 1     = 0.45 "Softness"
// lerp-param: speed       float 0 0.5   = 0.018 "Speed"
//
// Upstream presets, scale mapped into this port's units and speed kept at the
// port's much slower drift.
// lerp-preset: "Nintendo Water" colorBack=#2d69d4, colorFront=#d1eefc, scale=0.8
// lerp-preset: "Nintendo Water" proportion=0.42, softness=0, octaveCount=2
// lerp-preset: "Nintendo Water" persistence=0.55, lacunarity=1.8, speed=0.0144
// lerp-preset: Moss  colorBack=#05ff4a, colorFront=#262626, scale=1
// lerp-preset: Moss  proportion=0.65, softness=0.35, octaveCount=6
// lerp-preset: Moss  persistence=1, lacunarity=2.55, speed=0.00072
// lerp-preset: Worms colorBack=#ffffff, colorFront=#595959, scale=0.144
// lerp-preset: Worms proportion=0.5, softness=0, octaveCount=1
// lerp-preset: Worms persistence=1, lacunarity=1.5, speed=0

static float pnHash31(float3 p) {
    p = fract(p * 0.3183099) + 0.1;
    p += dot(p, p.yzx + 19.19);
    return fract(p.x * (p.y + p.z));
}

static float3 pnGradient(float h) {
    int idx = int(h * 12.0) % 12;
    if (idx == 0)  return float3( 1.0,  1.0,  0.0);
    if (idx == 1)  return float3(-1.0,  1.0,  0.0);
    if (idx == 2)  return float3( 1.0, -1.0,  0.0);
    if (idx == 3)  return float3(-1.0, -1.0,  0.0);
    if (idx == 4)  return float3( 1.0,  0.0,  1.0);
    if (idx == 5)  return float3(-1.0,  0.0,  1.0);
    if (idx == 6)  return float3( 1.0,  0.0, -1.0);
    if (idx == 7)  return float3(-1.0,  0.0, -1.0);
    if (idx == 8)  return float3( 0.0,  1.0,  1.0);
    if (idx == 9)  return float3( 0.0, -1.0,  1.0);
    if (idx == 10) return float3( 0.0,  1.0, -1.0);
    return float3(0.0, -1.0, -1.0);
}

static float pnInterpolate(float v000, float v001, float v010, float v011,
                           float v100, float v101, float v110, float v111, float3 t) {
    t = clamp(t, 0.0, 1.0);
    float v00 = mix(v000, v100, t.x);
    float v01 = mix(v001, v101, t.x);
    float v10 = mix(v010, v110, t.x);
    float v11 = mix(v011, v111, t.x);
    float v0 = mix(v00, v10, t.y);
    float v1 = mix(v01, v11, t.y);
    return mix(v0, v1, t.z);
}

static float3 pnFade(float3 t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

static float pnPerlin(float3 position, float seed) {
    position += float3(seed * 127.1, seed * 311.7, seed * 74.7);

    float3 i = floor(position);
    float3 f = fract(position);

    float3 g000 = pnGradient(pnHash31(i));
    float3 g001 = pnGradient(pnHash31(i + float3(0.0, 0.0, 1.0)));
    float3 g010 = pnGradient(pnHash31(i + float3(0.0, 1.0, 0.0)));
    float3 g011 = pnGradient(pnHash31(i + float3(0.0, 1.0, 1.0)));
    float3 g100 = pnGradient(pnHash31(i + float3(1.0, 0.0, 0.0)));
    float3 g101 = pnGradient(pnHash31(i + float3(1.0, 0.0, 1.0)));
    float3 g110 = pnGradient(pnHash31(i + float3(1.0, 1.0, 0.0)));
    float3 g111 = pnGradient(pnHash31(i + float3(1.0, 1.0, 1.0)));

    float v000 = dot(g000, f - float3(0.0, 0.0, 0.0));
    float v001 = dot(g001, f - float3(0.0, 0.0, 1.0));
    float v010 = dot(g010, f - float3(0.0, 1.0, 0.0));
    float v011 = dot(g011, f - float3(0.0, 1.0, 1.0));
    float v100 = dot(g100, f - float3(1.0, 0.0, 0.0));
    float v101 = dot(g101, f - float3(1.0, 0.0, 1.0));
    float v110 = dot(g110, f - float3(1.0, 1.0, 0.0));
    float v111 = dot(g111, f - float3(1.0, 1.0, 1.0));

    return pnInterpolate(v000, v001, v010, v011, v100, v101, v110, v111, pnFade(f));
}

static float pnFbm(float3 position, float persistence, float lacunarity, int octaveCount) {
    float value = 0.0;
    float amplitude = 1.0;
    float frequency = 10.0;
    for (int i = 0; i < octaveCount; i++) {
        value += pnPerlin(position * frequency, float(i) * 0.7319) * amplitude;
        amplitude *= persistence;
        frequency *= lacunarity;
    }
    return value;
}

static float pnMaxAmp(float persistence, float octaveCount) {
    persistence = clamp(persistence * 0.999, 0.0, 0.999);
    if (abs(persistence - 1.0) < 0.001) { return octaveCount; }
    return (1.0 - pow(persistence, octaveCount)) / max(1e-4, 1.0 - persistence);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution) * u.scale;
    uv = rotate(uv, u.seed * TWO_PI);

    // Slowed hard from the original's .2 * u_time: the fBm multiplies the z
    // slice by the octave frequency (up to 80x), so anything faster than this
    // boils rather than drifts. Offset so each launch starts on a different
    // slice of the noise volume.
    float t = u.speed * u.time + 24.0 * u.seed;

    float3 p = float3(uv, t);
    float noise = pnFbm(p, u.persistence, u.lacunarity, u.octaveCount);

    float maxAmp = pnMaxAmp(u.persistence, float(u.octaveCount));
    float noiseNorm = clamp(noise / max(1e-4, 2.0 * maxAmp) + u.proportion, 0.0, 1.0);

    float sharpness = clamp(u.softness, 0.0, 1.0);
    float smoothW = 0.5 * max(fwidth(noiseNorm), 0.001);
    float res = smoothstep(0.5 - 0.5 * sharpness - smoothW,
                           0.5 + 0.5 * sharpness + smoothW,
                           noiseNorm);

    float3 color = mix(u.colorBack.rgb, u.colorFront.rgb, res);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
