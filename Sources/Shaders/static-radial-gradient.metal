// Static Radial Gradient — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// A focal (cone-traced) radial gradient with a petal distortion and film
// grain. Upstream renders one still frame; this port orbits the focal point
// and breathes the distortion so the bloom drifts across the screen.

constant int SRG_COLOR_COUNT = 4;
constant float3 SRG_COLORS[SRG_COLOR_COUNT] = {
    float3(0.078, 0.055, 0.208), // deep violet (outer)
    float3(0.451, 0.125, 0.376), // plum
    float3(0.898, 0.376, 0.243), // ember
    float3(0.976, 0.812, 0.502), // gold core
};
constant float3 SRG_COLOR_BACK = float3(0.012, 0.012, 0.031); // near-black

constant float SRG_RADIUS          = 1.05;
constant float SRG_FOCAL_DISTANCE  = 0.55;
constant float SRG_FALLOFF         = 0.25;
constant float SRG_MIXING          = 0.72;
constant float SRG_DISTORTION      = 0.55;
constant float SRG_DISTORTION_FREQ = 6.0;
constant float SRG_GRAIN_MIXER     = 0.35;
constant float SRG_GRAIN_OVERLAY   = 0.28;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // 2 * v_objectUV — [-1, 1] on the short axis.
    float2 uv = lerpUV(pos, u.resolution);
    float2 grainUV = uv * 500.0;

    float t = 0.13 * u.time + 40.0 * u.seed;

    float2 center = float2(0.0);
    float angleRad = -(t * 0.5 + u.seed * TWO_PI); // upstream: -radians(focalAngle + 90)
    float2 focalPoint = float2(cos(angleRad), sin(angleRad)) * SRG_FOCAL_DISTANCE;
    float radius = SRG_RADIUS;
    float distortionShift = 0.35 * sin(0.27 * t);

    float2 cToUV = uv - center;
    float2 fToUV = uv - focalPoint;
    float2 fToC = center - focalPoint;
    float r = length(cToUV);

    float fragAngle = atan2(cToUV.y, cToUV.x);
    float angleDiff = fract((fragAngle - angleRad + PI) / TWO_PI) * TWO_PI - PI;

    float halfAngle = acos(clamp(radius / max(SRG_FOCAL_DISTANCE, 1e-4), 0.0, 1.0));
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

    float falloffMapped = mix(0.2 + 0.8 * max(0.0, SRG_FALLOFF + 1.0),
                              mix(1.0, 15.0, SRG_FALLOFF * SRG_FALLOFF),
                              step(0.0, SRG_FALLOFF));
    shape = pow(shape, mix(falloffMapped, 1.0, shape));
    shape = 1.0 - clamp(shape, 0.0, 1.0);

    const float outerMask = 0.002;
    float outer = 1.0 - smoothstep(radius - outerMask, radius + outerMask, r);
    outer = mix(outer, 1.0, isInSector);

    shape = mix(0.0, shape, outer);
    shape *= 1.0 - smoothstep(radius - 0.01, radius, r);

    float petalAngle = atan2(fToUV.y, fToUV.x);
    shape -= pow(SRG_DISTORTION, 2.0) * shape
           * pow(abs(sin(PI * clamp(length(fToUV) - 0.2 + distortionShift, 0.0, 1.0))), 4.0)
           * (sin(SRG_DISTORTION_FREQ * petalAngle)
              + cos(floor(0.65 * SRG_DISTORTION_FREQ) * petalAngle));

    float grain = valueNoise(grainUV);
    float mixerGrain = 0.4 * SRG_GRAIN_MIXER * (grain - 0.5);

    const float count = float(SRG_COLOR_COUNT);
    float mixer = shape * count + mixerGrain;

    float3 gradient = SRG_COLORS[0];
    float outerShape = 0.0;
    for (int i = 1; i <= SRG_COLOR_COUNT; i++) {
        float mLinear = clamp(mixer - float(i - 1), 0.0, 1.0);

        float aa = fwidth(mLinear);
        float width = min(SRG_MIXING, 0.5);
        float k = clamp((mLinear - (0.5 - width - aa)) / (2.0 * width + 2.0 * aa), 0.0, 1.0);
        float p = mix(2.0, 1.0, clamp((SRG_MIXING - 0.5) * 2.0, 0.0, 1.0));
        float m = (k < 0.5) ? 0.5 * pow(2.0 * k, p) : 1.0 - 0.5 * pow(2.0 * (1.0 - k), p);

        float quadBlend = clamp((SRG_MIXING - 0.5) * 2.0, 0.0, 1.0);
        m = mix(m, m * m, 0.5 * quadBlend);

        if (i == 1) { outerShape = m; }
        gradient = mix(gradient, SRG_COLORS[i - 1], m);
    }

    float3 color = gradient * outerShape + SRG_COLOR_BACK * (1.0 - outerShape);

    float grainOverlay = valueNoise(rotate(grainUV, 1.0) + 3.0);
    grainOverlay = mix(grainOverlay, valueNoise(rotate(grainUV, 2.0) - 1.0), 0.5);
    grainOverlay = pow(grainOverlay, 1.3);

    float grainOverlayV = grainOverlay * 2.0 - 1.0;
    float3 grainOverlayColor = float3(step(0.0, grainOverlayV));
    float grainOverlayStrength = pow(SRG_GRAIN_OVERLAY * abs(grainOverlayV), 0.8);
    color = mix(color, grainOverlayColor, 0.35 * grainOverlayStrength);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
