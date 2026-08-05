import Foundation

/// The Metal source prelude prepended to every shader file (built-in and custom)
/// before runtime compilation. It defines the uniform block, the fullscreen-triangle
/// vertex function, and a small library of helpers shared by all shaders.
///
/// Custom shaders may use anything declared here. The only requirement for a shader
/// file is that it defines:
///
///     fragment half4 lerpMain(float4 pos [[position]],
///                            constant LerpUniforms& u [[buffer(0)]])
///
public enum LerpPrelude {
    /// The prelude every shader gets, with no `#line` directive. Use `source`
    /// (or `source(extra:)`) rather than this — they add the `#line 1` marker
    /// that keeps Metal's diagnostics pointing at the shader file's own lines.
    public static let helpers = """
    #include <metal_stdlib>
    using namespace metal;

    #define PI     3.14159265358979323846
    #define TWO_PI 6.28318530718

    struct LerpUniforms {
        float2 resolution; // drawable size in pixels
        float  time;       // seconds since the renderer started
        float  seed;       // random per-launch seed in [0, 1)
    };

    // Fullscreen triangle — no vertex buffer needed.
    vertex float4 lerpVertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        return float4(p[vid], 0.0, 1.0);
    }

    // Centered, aspect-corrected UV: [-1, 1] on the short axis, y pointing up.
    static inline float2 lerpUV(float4 pos, float2 res) {
        float2 p = float2(pos.x, res.y - pos.y);
        return (2.0 * p - res) / min(res.x, res.y);
    }

    // Plain 0..1 UV per axis, y pointing down (like CSS).
    static inline float2 lerpScreenUV(float4 pos, float2 res) {
        return pos.xy / res;
    }

    // GLSL-style mod (floors, unlike fmod which truncates).
    static inline float  glmod (float  x, float y) { return x - y * floor(x / y); }
    static inline float2 glmod2(float2 x, float y) { return x - y * floor(x / y); }
    static inline float3 glmod3(float3 x, float y) { return x - y * floor(x / y); }

    static inline float2 rotate(float2 uv, float th) {
        float c = cos(th), s = sin(th);
        return float2x2(float2(c, s), float2(-s, c)) * uv;
    }

    // Procedural hashes (from paper-design/shaders, Apache-2.0).
    static inline float hash11(float p) {
        p = fract(p * 0.3183099) + 0.1;
        p *= p + 19.19;
        return fract(p * p);
    }
    static inline float hash21(float2 p) {
        p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
        p += dot(p, p + 19.19);
        return fract(p.x * p.y);
    }
    static inline float2 hash22(float2 p) {
        p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
        p += dot(p, p.yx + 19.19);
        return fract(float2(p.x * p.y, p.x + p.y));
    }

    static inline float valueNoise(float2 st) {
        float2 i = floor(st);
        float2 f = fract(st);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    // 2D simplex noise (Ashima/paper-design port), returns roughly [-1, 1].
    static inline float3 lerpPermute(float3 x) { return glmod3(((x * 34.0) + 1.0) * x, 289.0); }
    static inline float snoise(float2 v) {
        const float4 C = float4(0.211324865405187, 0.366025403784439,
                                -0.577350269189626, 0.024390243902439);
        float2 i = floor(v + dot(v, C.yy));
        float2 x0 = v - i + dot(i, C.xx);
        float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
        float4 x12 = x0.xyxy + C.xxzz;
        x12.xy -= i1;
        i = glmod2(i, 289.0);
        float3 p = lerpPermute(lerpPermute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
        float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
        m = m * m;
        m = m * m;
        float3 x = 2.0 * fract(p * C.www) - 1.0;
        float3 h = abs(x) - 0.5;
        float3 ox = floor(x + 0.5);
        float3 a0 = x - ox;
        m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
        float3 g;
        g.x = a0.x * x0.x + h.x * x0.y;
        g.yz = a0.yz * x12.xz + h.yz * x12.yw;
        return 130.0 * dot(m, g);
    }

    // Breaks up gradient banding with a tiny screen-space dither
    // (from paper-design/shaders, Apache-2.0).
    static inline float3 lerpDither(float3 color, float4 pos) {
        return color + 1.0 / 256.0 *
            (fract(sin(dot(0.014 * pos.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);
    }
    """

    /// The standard prelude: helpers plus the `#line 1` marker.
    public static var source: String { source(extra: "") }

    /// The prelude with a data provider's MSL declarations spliced in between
    /// the helpers and the `#line 1` marker, so shader line numbers still match
    /// the file no matter how much the provider declares.
    public static func source(extra: String) -> String {
        let middle = extra.isEmpty ? "" : "\n" + extra + "\n"
        return helpers + "\n" + middle + "\n#line 1\n"
    }
}
