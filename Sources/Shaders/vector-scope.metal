// Vector Scope — phosphor traces and a vector clock.
// Clock is session-anchored by ClockData; stills use midnight. Audio uniforms
// are zero without capture, leaving a continuously animated silent trace.
// lerp-category: Sound & Flow
// lerp-data: clock
// lerp-param: clock float -1 24 = -1 "Hour (-1 = now)"
// lerp-param: speed float 0 2 = 0.35 "Speed"

static inline float vsSegment(float2 p, float2 a, float2 b) {
    float2 v = b - a;
    return length(p - (a + v * clamp(dot(p - a, v) / max(dot(v, v), 1e-6), 0.0, 1.0)));
}
static inline float2 vsPoint(float t, float phase, float bass, float treble) {
    return float2(0.72 * sin(3.0 * t + phase + bass * 0.4),
                  0.48 * sin(4.0 * t + treble * 0.4));
}
fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        constant LerpClock& clock [[buffer(1)]]) {
    float2 p = lerpUV(pos, u.resolution);
    float phase = u.time * u.speed + u.seed * 6.2831853;
    float d = 10.0;
    // The curve lies inside ±(0.72, 0.48). Beyond this padded box its
    // widest glow is below 0.0001, so avoid 80 segment tests in the margins.
    if (all(abs(p) < float2(1.14, 0.90))) {
        float2 prev = vsPoint(0.0, phase, u.audioBass, u.audioTreble);
        for (int i = 1; i <= 80; ++i) {
            float2 next = vsPoint(float(i) * (6.2831853 / 80.0), phase, u.audioBass, u.audioTreble);
            d = min(d, vsSegment(p, prev, next));
            prev = next;
        }
    }
    float hour = glmod(clock.hourAtZero + u.time / 3600.0, 24.0);
    float minuteAngle = 6.2831853 * fract(hour);
    float hourAngle = 6.2831853 * hour / 12.0;
    float2 center = float2(0.0, 0.0);
    float2 minute = 0.31 * float2(sin(minuteAngle), cos(minuteAngle));
    float2 h = 0.20 * float2(sin(hourAngle), cos(hourAngle));
    float dc = min(vsSegment(p, center, minute), vsSegment(p, center, h));
    float ring = abs(length(p) - 0.36);
    float pixel = 2.0 / min(u.resolution.x, u.resolution.y);
    float trace = exp(-d * 110.0) + 0.18 * exp(-d * 18.0);
    float dial = exp(-min(dc, ring) / max(pixel * 1.2, 0.002));
    float3 col = float3(0.14, 0.95, 0.58) * trace * (0.75 + 0.3 * u.audioLevel)
               + float3(0.38, 0.85, 0.95) * dial * 0.65;
    col += float3(0.003, 0.009, 0.008);
    return half4(half3(lerpDither(col, pos)), 1.0h);
}
