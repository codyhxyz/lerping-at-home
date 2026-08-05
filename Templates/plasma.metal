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
// Tunable parameters are declared in comments and land on `u` as extra fields,
// so `u.NAME` works with no change to the lerpMain signature:
//
//   // lerp-param: NAME TYPE [MIN MAX] = DEFAULT "Label"
//   // lerp-preset: NAME  key=value, key=value
//
// TYPE is float, int, bool or color; MIN/MAX are required for float and int
// and forbidden for bool and color. Colour defaults take `#RRGGBB`,
// `#RRGGBBAA` or `(r, g, b[, a])` with components 0..1. Repeat a preset name
// on later lines to keep the lines short. Full syntax: PORTING.md.
//
// Drop this file into:
//   ~/Library/Application Support/Lerping/Shaders/
// The file stem becomes the shader's name. LerpPreview picks it up live —
// compile errors are reported at launch and on 'r' reload. Once it looks
// right, `make install` bakes it into the screensaver (the sandboxed saver
// can only load from its own bundle).
//
// lerp-param: colorLow  color       = (0.055, 0.049, 0.180) "Deep indigo"
// lerp-param: colorMid  color       = (0.098, 0.631, 0.612) "Teal"
// lerp-param: colorHigh color       = (0.973, 0.925, 0.808) "Warm cream"
// lerp-param: scale     float 0.2 6 = 1.0  "Scale"
// lerp-param: noise     float 0 2   = 0.6  "Noise"
// lerp-param: speed     float 0 2   = 0.4  "Speed"
//
// lerp-preset: Ember colorLow=#1a0505, colorMid=#c2410c, colorHigh=#fde68a, noise=1.2
// lerp-preset: Ice   colorLow=#020617, colorMid=#0e7490, colorHigh=#f0f9ff, scale=2, speed=0.2

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution) * u.scale;
    float t = u.speed * u.time + u.seed * TWO_PI;

    // Classic three-wave plasma.
    float v = sin(uv.x * 3.0 + t);
    v += sin((uv.y * 3.0 + t) * 0.7);
    v += sin(length(uv * 4.0) - 1.5 * t);
    v += u.noise * snoise(uv * 1.5 + 0.1 * t);

    // Soft duotone palette: deep indigo through teal to warm cream.
    float w = 0.5 + 0.5 * sin(v * PI * 0.5);
    float3 color = mix(u.colorLow.rgb, u.colorMid.rgb, smoothstep(0.0, 0.65, w));
    color = mix(color, u.colorHigh.rgb, smoothstep(0.65, 1.0, w));

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
