// Static Radial Gradient — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// A focal (cone-traced) radial gradient with a petal distortion and film
// grain. Upstream renders one still frame; this port orbits the focal point
// and breathes the distortion so the bloom drifts across the screen.

// Parameters mirror the upstream <StaticRadialGradient> props. Upstream takes
// a variable-length `colors` array (max 10); this port fixes four tunable
// slots. `focalAngle` and `distortionShift` are the *base* values this port
// orbits/breathes around rather than fixed positions, and `speed` is this
// port's own addition (upstream renders one still frame).
//
// lerp-param: color1          color         = (0.078, 0.055, 0.208) "Deep violet"
// lerp-param: color2          color         = (0.451, 0.125, 0.376) "Plum"
// lerp-param: color3          color         = (0.898, 0.376, 0.243) "Ember"
// lerp-param: color4          color         = (0.976, 0.812, 0.502) "Gold core"
// lerp-param: colorBack       color         = (0.012, 0.012, 0.031) "Background"
// lerp-param: radius          float 0 3     = 1.05 "Radius"
// lerp-param: focalDistance   float 0 3     = 0.55 "Focal distance"
// lerp-param: focalAngle      float 0 360   = 0.0  "Focal angle"
// lerp-param: falloff         float -1 1    = 0.25 "Falloff"
// lerp-param: mixing          float 0 1     = 0.72 "Mixing"
// lerp-param: distortion      float 0 1     = 0.55 "Distortion"
// lerp-param: distortionShift float -1 1    = 0.0  "Distortion shift"
// lerp-param: distortionFreq  int 0 20      = 6    "Distortion frequency"
// lerp-param: grainMixer      float 0 1     = 0.35 "Grain mixer"
// lerp-param: grainOverlay    float 0 1     = 0.28 "Grain overlay"
// lerp-param: speed           float 0 1     = 0.13 "Drift speed"
//
// Upstream presets (their static focal/distortion values carry over; this
// port keeps drifting around them).
// lerp-preset: "Lo-Fi" colorBack=#2e1f27, color1=#d72638, color2=#3f88c5, color3=#f49d37
// lerp-preset: "Lo-Fi" color4=#d72638, radius=1, focalDistance=0, focalAngle=0, falloff=0.9
// lerp-preset: "Lo-Fi" mixing=0.7, distortion=0, distortionShift=0, distortionFreq=12
// lerp-preset: "Lo-Fi" grainMixer=1, grainOverlay=0.5
// lerp-preset: "Cross Section" colorBack=#3d348b, color1=#7678ed, color2=#f7b801
// lerp-preset: "Cross Section" color3=#f18701, color4=#37a066, radius=1, focalDistance=0
// lerp-preset: "Cross Section" focalAngle=0, falloff=0, mixing=0, distortion=1
// lerp-preset: "Cross Section" distortionShift=0, distortionFreq=12, grainMixer=0, grainOverlay=0
// lerp-preset: Radial colorBack=#264653, color1=#9c2b2b, color2=#f4a261, color3=#ffffff
// lerp-preset: Radial color4=#9c2b2b, radius=1, focalDistance=0, focalAngle=0, falloff=0
// lerp-preset: Radial mixing=1, distortion=0, distortionShift=0, distortionFreq=12
// lerp-preset: Radial grainMixer=0, grainOverlay=0

constant int SRG_COLOR_COUNT = 4;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float3 colors[SRG_COLOR_COUNT] = { u.color1.rgb, u.color2.rgb, u.color3.rgb, u.color4.rgb };

    // 2 * v_objectUV — [-1, 1] on the short axis.
    float2 uv = lerpUV(pos, u.resolution);
    float2 grainUV = uv * 500.0;

    float t = u.speed * u.time + 40.0 * u.seed;

    float2 center = float2(0.0);
    // upstream: -radians(focalAngle + 90); this port keeps orbiting from there.
    float angleRad = -(u.focalAngle * (PI / 180.0) + t * 0.5 + u.seed * TWO_PI);
    float2 focalPoint = float2(cos(angleRad), sin(angleRad)) * u.focalDistance;
    float radius = u.radius;
    float distortionShift = u.distortionShift + 0.35 * sin(0.27 * t);

    float2 cToUV = uv - center;
    float2 fToUV = uv - focalPoint;
    float2 fToC = center - focalPoint;
    float r = length(cToUV);

    float fragAngle = atan2(cToUV.y, cToUV.x);
    float angleDiff = fract((fragAngle - angleRad + PI) / TWO_PI) * TWO_PI - PI;

    float halfAngle = acos(clamp(radius / max(u.focalDistance, 1e-4), 0.0, 1.0));
    float e0 = 0.6 * PI, e1 = halfAngle;
    float s = smoothstep(min(e0, e1), max(e0, e1), abs(angleDiff));
    float isInSector = (e1 >= e0) ? (1.0 - s) : s;

    // Ray/circle intersection from the focal point through this fragment.
    float qa = dot(fToUV, fToUV);
    float qb = -2.0 * dot(fToUV, fToC);
    float qc = dot(fToC, fToC) - radius * radius;

    float discriminant = qb * qb - 4.0 * qa * qc;
    float hit = 1.0;
    if (discriminant >= 0.0) {
        float sqrtD = sqrt(discriminant);
        float div = max(1e-4, 2.0 * qa);
        hit = max((-qb - sqrtD) / div, (-qb + sqrtD) / div);
        hit = max(hit, 0.0);
    }

    float dist = length(fToUV);
    float normalized = dist / max(1e-4, length(fToUV * hit));
    float shape = clamp(normalized, 0.0, 1.0);

    float falloffMapped = mix(0.2 + 0.8 * max(0.0, u.falloff + 1.0),
                              mix(1.0, 15.0, u.falloff * u.falloff),
                              step(0.0, u.falloff));
    shape = pow(shape, mix(falloffMapped, 1.0, shape));
    shape = 1.0 - clamp(shape, 0.0, 1.0);

    const float outerMask = 0.002;
    float outer = 1.0 - smoothstep(radius - outerMask, radius + outerMask, r);
    outer = mix(outer, 1.0, isInSector);

    shape = mix(0.0, shape, outer);
    shape *= 1.0 - smoothstep(radius - 0.01, radius, r);

    float petalAngle = atan2(fToUV.y, fToUV.x);
    shape -= pow(u.distortion, 2.0) * shape
           * pow(abs(sin(PI * clamp(length(fToUV) - 0.2 + distortionShift, 0.0, 1.0))), 4.0)
           * (sin(float(u.distortionFreq) * petalAngle)
              + cos(floor(0.65 * float(u.distortionFreq)) * petalAngle));

    float grain = valueNoise(grainUV);
    float mixerGrain = 0.4 * u.grainMixer * (grain - 0.5);

    const float count = float(SRG_COLOR_COUNT);
    float mixer = shape * count + mixerGrain;

    float3 gradient = colors[0];
    float outerShape = 0.0;
    for (int i = 1; i <= SRG_COLOR_COUNT; i++) {
        float mLinear = clamp(mixer - float(i - 1), 0.0, 1.0);

        float aa = fwidth(mLinear);
        float width = min(u.mixing, 0.5);
        float k = clamp((mLinear - (0.5 - width - aa)) / (2.0 * width + 2.0 * aa), 0.0, 1.0);
        float p = mix(2.0, 1.0, clamp((u.mixing - 0.5) * 2.0, 0.0, 1.0));
        float m = (k < 0.5) ? 0.5 * pow(2.0 * k, p) : 1.0 - 0.5 * pow(2.0 * (1.0 - k), p);

        float quadBlend = clamp((u.mixing - 0.5) * 2.0, 0.0, 1.0);
        m = mix(m, m * m, 0.5 * quadBlend);

        if (i == 1) { outerShape = m; }
        gradient = mix(gradient, colors[i - 1], m);
    }

    float3 color = gradient * outerShape + u.colorBack.rgb * (1.0 - outerShape);

    color = lerpGrainOverlay(color, grainUV, u.grainOverlay);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
