#include <metal_stdlib>
using namespace metal;

// Shot transitions for the launch montage. Both looks are rendered live (A is
// the outgoing shot, B the incoming one) and mixed here, so a transition can
// use what is in the pictures: where A is bright, which way B's gradients
// run. `p` runs 0 → 1 across the transition's window.

struct Params {
    float2 res;
    float p;
    float time;
    int kind;
    float seed;
    float2 pad;
};

enum Kind : int { cut = 0, burn = 1, pour = 2, ripple = 3, melt = 4, halftone = 5, zoom = 6, none = 7 };

constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);

static float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}
static float fbm(float2 p) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 5; i++) { s += a * vnoise(p); p = p * 2.03 + 17.1; a *= 0.5; }
    return s;
}
static float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
static float3 at(texture2d<float> t, float2 uv) { return t.sample(smp, uv).rgb; }
static float smoother(float x) { x = clamp(x, 0.0, 1.0); return x * x * x * (x * (x * 6.0 - 15.0) + 10.0); }

/// Signed distance to the pouring front, in UV: negative where B has arrived.
static float pourFront(float2 uv, float asp, float p, float time, float seed) {
    // Low-frequency only: a liquid edge is smooth and bulging, not jagged.
    float2 q = uv * float2(asp, 1.0);
    float n = vnoise(q * 1.3 + float2(seed * 9.0, time * 0.3)) * 0.7 + vnoise(q * 2.7 + 5.3 + time * 0.2) * 0.3;
    float front = mix(-0.4, 1.4, smoother(p));
    return uv.x * 0.85 + (1.0 - uv.y) * 0.15 + 0.3 * (n - 0.5) - front;
}

kernel void transition(texture2d<float> a [[texture(0)]],
                       texture2d<float> b [[texture(1)]],
                       texture2d<float, access::write> out [[texture(2)]],
                       constant Params& P [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / P.res;
    float asp = P.res.x / P.res.y;
    float p = clamp(P.p, 0.0, 1.0);
    float3 col;

    switch (P.kind) {
    case none: {
        col = at(a, uv);
        break;
    }
    case burn: {
        // B burns through A's brightest light first, down to its shadows, with
        // a hot edge on the threshold.
        // The burn order is A's light mixed with a full-range noise, so a mostly
        // black picture still burns as a spreading front rather than all at once.
        float3 ca = at(a, uv), cb = at(b, uv);
        float2 px = 6.0 / P.res;
        float soft = 0.25 * (luma(at(a, uv + float2(px.x, 0))) + luma(at(a, uv - float2(px.x, 0))) +
                             luma(at(a, uv + float2(0, px.y))) + luma(at(a, uv - float2(0, px.y))));
        float n = fbm(uv * float2(asp, 1.0) * 2.5 + P.seed * 7.0 + float2(0.0, P.time * 0.15));
        float la = 0.6 * soft + 0.4 * smoothstep(0.2, 0.8, n);
        float th = mix(1.02, -0.04, smoother(p));
        float m = smoothstep(th - 0.008, th + 0.008, la);
        float edge = exp(-pow((la - th) / 0.012, 2.0)) * smoothstep(0.0, 0.06, p) * (1.0 - smoothstep(0.88, 1.0, p));
        float halo = exp(-pow((la - th) / 0.05, 2.0)) * smoothstep(0.0, 0.06, p) * (1.0 - smoothstep(0.88, 1.0, p));
        float3 hot = mix(float3(1.0, 0.72, 0.42), float3(1.0), 0.35);
        col = mix(ca, cb, m) + edge * hot * 1.2 + halo * hot * 0.18;
        break;
    }
    case pour: {
        // A liquid-chrome front sweeps across, refracting both pictures at its edge.
        float d = pourFront(uv, asp, p, P.time, P.seed);
        float2 e = float2(2.0 / P.res.x, 2.0 / P.res.y);
        float2 g = float2(pourFront(uv + float2(e.x, 0), asp, p, P.time, P.seed) - d,
                          pourFront(uv + float2(0, e.y), asp, p, P.time, P.seed) - d);
        float2 n = normalize(g / e + 1e-6);
        float w = 0.034;
        float near = 1.0 - smoothstep(0.0, w * 2.5, abs(d));
        float2 off = n * near * 0.03 / float2(asp, 1.0);
        float m = smoothstep(w * 0.2, -w * 0.2, d);
        col = mix(at(a, uv + off), at(b, uv - off), m);
        // The rim itself, shaded like the title: hard chrome bands, a little dispersion.
        float ang = atan2(n.y, n.x);
        float phase = ang * 2.0 + uv.y * 9.0 + P.time * 1.5 + d * 60.0;
        float3 chrome;
        for (int c = 0; c < 3; c++) {
            float band = 0.5 + 0.5 * sin(phase + float(c - 1) * 0.35);
            chrome[c] = mix(0.06, 0.99, smoothstep(0.42, 0.58, band));
        }
        float rim = 1.0 - smoothstep(w * 0.55, w, abs(d));
        col = mix(col, chrome, rim * 0.95);
        col += near * 0.06;
        break;
    }
    case ripple: {
        // A refracting ring opens from the centre; B is inside it.
        float2 v = (uv - 0.5) * float2(asp, 1.0);
        float r = length(v);
        float R = mix(-0.05, 1.2, smoother(p));
        float k = r - R;
        float ring = exp(-pow(k / 0.08, 2.0));
        float2 dir = r > 1e-4 ? v / r : float2(0.0);
        float2 off = dir / float2(asp, 1.0) * sin(k * 60.0) * 0.022 * ring;
        float3 ca = float3(a.sample(smp, uv + off * 1.25).r, a.sample(smp, uv + off).g, a.sample(smp, uv + off * 0.75).b);
        float3 cb = float3(b.sample(smp, uv + off * 1.25).r, b.sample(smp, uv + off).g, b.sample(smp, uv + off * 0.75).b);
        float m = smoothstep(0.012, -0.012, k);
        col = mix(ca, cb, m) + ring * 0.1 * sin(M_PI_F * p);
        break;
    }
    case melt: {
        // A flows along B's contours and B condenses out of A's.
        float2 px = 5.0 / P.res;
        float2 gb = float2(luma(at(b, uv + float2(px.x, 0))) - luma(at(b, uv - float2(px.x, 0))),
                           luma(at(b, uv + float2(0, px.y))) - luma(at(b, uv - float2(0, px.y))));
        float2 ga = float2(luma(at(a, uv + float2(px.x, 0))) - luma(at(a, uv - float2(px.x, 0))),
                           luma(at(a, uv + float2(0, px.y))) - luma(at(a, uv - float2(0, px.y))));
        float e = smoother(p);
        float bell = sin(M_PI_F * p);
        float2 flow = (float2(fbm(uv * 3.0 + P.seed + P.time * 0.3), fbm(uv * 3.0 + 31.7 - P.time * 0.3)) - 0.5) * 0.22 * bell;
        float2 offA = gb * 1.2 * e + flow;
        float2 offB = -ga * 1.2 * (1.0 - e) + flow;
        col = mix(at(a, uv + offA), at(b, uv + offB), e);
        break;
    }
    case halftone: {
        // A breaks into halftone dots, the dots grow, then re-form as B.
        float k = sin(M_PI_F * p);
        float cell = mix(2.0, 54.0, pow(k, 1.5));
        float ang = 0.45;
        float2x2 rot = float2x2(float2(cos(ang), sin(ang)), float2(-sin(ang), cos(ang)));
        float2 g = rot * float2(gid) / cell;
        float2 ci = floor(g) + 0.5;
        float2 cc = transpose(rot) * (ci * cell);
        bool useB = p >= 0.5;
        float3 src = useB ? at(b, cc / P.res) : at(a, cc / P.res);
        float rad = sqrt(clamp(luma(src) * 1.15, 0.0, 1.0)) * 0.72;
        float aa = 1.2 / cell;
        float dm = 1.0 - smoothstep(rad - aa, rad + aa, length(g - ci));
        float3 dots = src / max(luma(src), 0.12) * 0.75 * dm;
        float3 full = useB ? at(b, uv) : at(a, uv);
        col = mix(full, dots, smoothstep(0.05, 0.45, k));
        break;
    }
    case zoom: {
        // Punch through A on a radial blur and land on B.
        const int N = 28;
        float3 acc = 0.0;
        if (p < 0.5) {
            float s = pow(p * 2.0, 2.0);
            for (int i = 0; i < N; i++) {
                float t = float(i) / float(N - 1);
                acc += at(a, 0.5 + (uv - 0.5) / (1.0 + s * (0.5 + 0.4 * t)));
            }
        } else {
            float s = pow((1.0 - p) * 2.0, 2.0);
            for (int i = 0; i < N; i++) {
                float t = float(i) / float(N - 1);
                acc += at(b, 0.5 + (uv - 0.5) / (1.0 + s * (0.25 + 0.4 * t)));
            }
        }
        col = acc / float(N) + pow(sin(M_PI_F * p), 6.0) * 0.45;
        break;
    }
    default: {
        // Hard cut (the window starts on the cut), with a short push on B so
        // the downbeat lands physically.
        col = at(b, 0.5 + (uv - 0.5) / (1.0 + 0.07 * pow(1.0 - p, 3.0)));
        break;
    }
    }
    out.write(float4(clamp(col, 0.0, 1.0), 1.0), gid);
}
