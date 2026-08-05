// Custom shader template for Lerping@Home.
//
// Contract: define exactly this entry point —
//
//   fragment half4 lerpMain(float4 pos [[position]],
//                          constant LerpUniforms& u [[buffer(0)]])
//
// Uniforms available on `u`:
//   u.resolution  float2  drawable size in pixels
//   u.time        float   seconds since the saver started
//   u.seed        float   random per-launch value in [0, 1) — use it so
//                         every activation looks a little different
//
// Helpers available from the prelude (see README for the full list):
//   lerpUV(pos, u.resolution)        centered UV, [-1,1] short axis, y up
//   lerpScreenUV(pos, u.resolution)  0..1 UV, y down
//   rotate(uv, radians), hash11/21/22, valueNoise, snoise (simplex),
//   glmod/glmod2/glmod3 (GLSL-style mod), lerpDither(color, pos), PI, TWO_PI
//
// Drop this file into:
//   ~/Library/Application Support/Lerping/Shaders/
// The file stem becomes the shader's name. LerpPreview picks it up live —
// compile errors are reported at launch and on 'r' reload. Once it looks
// right, `make install` bakes it into the screensaver (the sandboxed saver
// can only load from its own bundle).

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float t = 0.4 * u.time + u.seed * TWO_PI;

    // Classic three-wave plasma.
    float v = sin(uv.x * 3.0 + t);
    v += sin((uv.y * 3.0 + t) * 0.7);
    v += sin(length(uv * 4.0) - 1.5 * t);
    v += 0.6 * snoise(uv * 1.5 + 0.1 * t);

    // Soft duotone palette: deep indigo through teal to warm cream.
    float w = 0.5 + 0.5 * sin(v * PI * 0.5);
    float3 color = mix(float3(0.055, 0.049, 0.180), float3(0.098, 0.631, 0.612), smoothstep(0.0, 0.65, w));
    color = mix(color, float3(0.973, 0.925, 0.808), smoothstep(0.65, 1.0, w));

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
