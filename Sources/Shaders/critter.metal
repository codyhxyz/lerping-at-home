// Critter — a small creature on a toy island that lives off how this Mac is
// used. Original look for Lerping@Home.
//
// LerpPulse (Sources/Pulse) notes once a minute whether anyone is at the
// keyboard and what kind of app is in front; CritterData turns the last weeks
// of that into vitals (Sources/LerpCore/CritterLedger.swift), CritterBehavior
// turns the vitals into what the critter is doing this frame, and CritterScene
// poses the 3D models (Sources/Critter/*.usdz, made in Blender by
// tools/critter-assets) and renders them with SceneKit into a texture before
// this pass runs. See CritterFrame.swift for how the parts fit.
//
// This file is the compositor: the rendered island (CritterLook draws the
// sky dome; the gradient here only fills what the scene left empty), then the 2D things that float over it — Zzz, hearts,
// sparkles, rain, lightning, the scribble of a frazzled mind, a sweat drop,
// the "!" of noticing you, fireflies — then the season in the air, a gentle
// vignette and dither. Every overlay hangs off an anchor CritterData projects
// with the scene's own camera, and hides behind whatever the scene drew in
// front of it (texture 2 is the scene's depth).
//
// Each frame is still a function of (time, seed, parameters) plus the vitals,
// which nothing accumulates. LerpPreview (snapshots, gallery stills) is
// always given a fixed fixture creature; see CritterData.
//
// lerp-category: Scenes
// lerp-data: critter
// lerp-param: mood  int   0 6   = 0    "Mood (0 = live)"
// lerp-param: clock float -1 24 = -1   "Hour (-1 = now)"
// lerp-param: drift float 0 1   = 0.35 "Camera drift"
// lerp-param: act   int   -1 9  = -1   "Activity (-1 = its choice)"
// lerp-param: yaw   float -180 180 = 0 "Turn"
// lerp-param: pitch float -35 20   = 0 "Tilt"
// lerp-param: magnify float -0.7 0.6 = 0 "Zoom"

struct Cam { float3 ro, fw, rt, up; float focal; };

// Screen position (lerpUV) and view depth. Anything closer than 0.2 to the
// lens (or behind it) is sent far off screen and far away, so an overlay
// sized by focal / z neither balloons over the picture nor passes a depth test.
static inline float3 project(float3 wp, Cam c) {
    float3 v = wp - c.ro;
    float z = dot(v, c.fw);
    if (z < 0.2) return float3(1e4, 1e4, 1e5);
    return float3(float2(dot(v, c.rt), dot(v, c.up)) * c.focal / z, z);
}

static inline float sdSeg(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}
static inline float sdZ(float2 p) {
    float d = sdSeg(p, float2(-0.45, 0.5), float2(0.45, 0.5));
    d = min(d, sdSeg(p, float2(0.45, 0.5), float2(-0.45, -0.5)));
    return min(d, sdSeg(p, float2(-0.45, -0.5), float2(0.45, -0.5)));
}
static inline float sdHeart(float2 p) {
    p.x = abs(p.x); p.y += 0.55;
    if (p.y + p.x > 1.0) return length(p - float2(0.25, 0.75)) - 0.35355;
    float2 a = p - float2(0.0, 1.0);
    float2 b = p - 0.5 * max(p.x + p.y, 0.0);
    return sqrt(min(dot(a, a), dot(b, b))) * sign(p.x - p.y);
}
// A drop: a circle of radius r at the origin and a point at (0, h), joined by
// the two lines tangent to the circle.
static inline float sdTear(float2 p, float r, float h) {
    p.x = abs(p.x);
    float s = r / h, c = sqrt(1.0 - s * s);
    if (p.y * c - p.x * s > 0.0) {
        float2 tip = float2(0.0, h);
        if (dot(p - tip, float2(-s, c)) > 0.0) return length(p - tip);
        return dot(p, float2(c, s)) - r;
    }
    return length(p) - r;
}

// sin(t * w) for a clock that has run for hours (see the old raymarcher's
// note): wrap the cycle count before multiplying out.
static inline float tphase(float t, float w) {
    return TWO_PI * fract(t * (w / TWO_PI));
}

struct FX {
    float2 uv;
    Cam    cam;
    float  depth;      // view depth of what the scene drew here (zFar for none)
    float3 head;       // just above its head
    float3 feet;
    float3 cloud;
    float  cloudK;     // its cloud's scale
    float  s;          // its size
    float  stage;
    float  nearW;      // this pixel's distance from the head, world units at its depth
    float  time;
    float  zzz, love, glee, sick, storm, flash, sweat, bang, frazzle, butterfly;
    float  night;
};

// ---- the sky, where the scene drew none

static float3 skyColor(float3 rd, float3 sunDir, float night, float golden) {
    float y = clamp(rd.y, -0.2, 1.0);
    float3 top = mix(mix(float3(0.494, 0.784, 0.949), float3(0.40, 0.42, 0.76), golden), float3(0.02, 0.035, 0.11), night);
    float3 hor = mix(mix(float3(0.867, 0.953, 1.0), float3(1.0, 0.70, 0.52), golden), float3(0.09, 0.12, 0.26), night);
    float3 c = mix(hor, top, pow(smoothstep(-0.05, 0.65, y), 0.7));
    float sd = max(dot(rd, sunDir), 0.0);
    c += (1.0 - night) * (float3(1.0, 0.9, 0.7) * 0.25 * pow(sd, 24.0) + float3(1.0, 0.97, 0.9) * smoothstep(0.9993, 0.9996, sd));
    // A few stars at night.
    float2 sp = float2(atan2(rd.z, rd.x) * 40.0, rd.y * 60.0);
    float2 cell = floor(sp);
    float star = step(0.985, hash21(cell)) * smoothstep(0.25, 0.05, length(fract(sp) - 0.5));
    c += star * night * smoothstep(0.02, 0.2, rd.y) * 0.8;
    return c;
}

// ---- overlays: the floating 2D things, each drawn over `col`

static inline void fxZzz(thread float3& col, thread const FX& fx) {
    if (!(fx.zzz > 0.01 && fx.nearW < 1.0)) return;
    for (int i = 0; i < 3; i++) {
        float ph = fract(fx.time * 0.22 + float(i) / 3.0);
        float3 wp = fx.head + fx.cam.rt * (0.15 + 0.35 * ph) + float3(0.0, 0.5 * ph, 0.0);
        float3 pj = project(wp, fx.cam);
        float size = (0.07 + 0.08 * ph) * fx.cam.focal / pj.z;
        float d = sdZ((fx.uv - pj.xy) / size) * size;
        float a = sin(ph * PI) * fx.zzz * step(pj.z, fx.depth);
        col = mix(col, float3(0.25, 0.3, 0.45), a * smoothstep(0.16 * size, 0.1 * size, d));
        col = mix(col, float3(1.0), a * smoothstep(0.09 * size, 0.04 * size, d));
    }
}

static inline void fxHearts(thread float3& col, thread const FX& fx) {
    if (!(fx.love > 0.01 && fx.nearW < 0.9)) return;
    for (int i = 0; i < 2; i++) {
        float ph = fract(fx.time * 0.3 + float(i) * 0.5);
        float3 wp = fx.head + fx.cam.rt * (0.35 * sin(float(i) * 2.0 + 1.0) - 0.15) + float3(0.0, 0.45 * ph, 0.0);
        float3 pj = project(wp, fx.cam);
        float size = 0.12 * fx.cam.focal / pj.z;
        float d = sdHeart((fx.uv - pj.xy) / size) * size;
        float a = sin(ph * PI) * fx.love * step(pj.z, fx.depth + 0.3);
        col = mix(col, float3(1.0), a * smoothstep(0.1 * size, 0.04 * size, d));
        col = mix(col, float3(1.0, 0.4, 0.5), a * smoothstep(0.02 * size, -0.03 * size, d));
    }
}

static inline void fxSparkles(thread float3& col, thread const FX& fx) {
    if (!(fx.glee > 0.01 && fx.nearW < 1.7 * fx.s + 0.15)) return;
    for (int i = 0; i < 5; i++) {
        float ph = fract(fx.time * 0.45 + float(i) * 0.2 + hash11(float(i)) * 0.3);
        float a0 = float(i) * 1.257 + floor(fx.time * 0.45 + float(i) * 0.2) * 2.1;
        float3 wp = fx.feet + float3(cos(a0) * 1.2 * fx.s, (1.0 + 1.6 * ph) * fx.s, sin(a0) * 1.2 * fx.s);
        float3 pj = project(wp, fx.cam);
        float size = 0.09 * fx.cam.focal / pj.z * sin(ph * PI);
        float2 g2 = abs(fx.uv - pj.xy) / max(size, 1e-4);
        float star = smoothstep(1.0, 0.6, sqrt(g2.x) + sqrt(g2.y)) * step(pj.z, fx.depth + 0.3);
        col = mix(col, float3(1.0, 0.97, 0.75), star * fx.glee);
    }
}

static inline void fxRain(thread float3& col, thread const FX& fx) {
    if (!(fx.sick > 0.01 && fx.cloudK > 0.01 && fx.nearW < 2.2 * fx.s + 0.9)) return;
    float3 cp = project(fx.cloud, fx.cam);
    float3 fp = project(fx.feet, fx.cam);
    float w = 0.35 * fx.cloudK * fx.cam.focal / cp.z;
    float lane = 0.016 * fx.cam.focal / cp.z * 4.0;
    float colId = floor((fx.uv.x - cp.x) / lane);
    float hr = hash11(colId * 1.7 + 0.3);
    float ph = fract(hr + fx.time * (0.9 + 0.5 * hr));
    float dropY = mix(cp.y - 0.05, fp.y, ph);
    float inside = step(abs(fx.uv.x - cp.x), w) * smoothstep(0.26, 0.1, abs(fract((fx.uv.x - cp.x) / lane) - 0.5));
    float streak = smoothstep(0.055, 0.0, abs(fx.uv.y - dropY)) * inside * step(0.25, hr);
    col = mix(col, float3(0.5, 0.68, 1.0), streak * 0.95 * fx.sick * step(fp.z, fx.depth + 0.5));
}

// Lightning: a short chunky zigzag from the cloud's underside, off to one
// side, stopping above its head; and the whole frame brightens with it.
static inline void fxLightning(thread float3& col, thread const FX& fx) {
    float flash = fx.flash;
    if (flash > 0.01 && fx.cloudK > 0.01 && fx.nearW < 1.2) {
        float3 top = project(fx.cloud + float3(0.0, -0.06 * fx.cloudK, 0.0) + fx.cam.rt * 0.22 * fx.cloudK, fx.cam);
        float bh = 0.42 * fx.cloudK * fx.cam.focal / top.z;          // bolt height on screen
        float2 b = (fx.uv - top.xy) / bh;                            // 0 at the top, -1 at the tip
        float bolt = 1e5;
        float2 zz[5] = { float2(0.0, 0.0), float2(-0.2, -0.38), float2(0.1, -0.44),
                         float2(-0.1, -0.78), float2(0.06, -1.0) };
        for (int i = 0; i < 4; i++) {
            float w = 0.075 - 0.045 * float(i) / 3.0;                 // tapers to the tip
            bolt = min(bolt, sdSeg(b, zz[i], zz[i + 1]) - w);
        }
        col = mix(col, float3(0.25, 0.22, 0.4), flash * smoothstep(0.045, 0.025, bolt));
        col = mix(col, float3(1.0, 0.95, 0.6), flash * smoothstep(0.01, -0.01, bolt));
    }
    col += 0.05 * flash;
}

// Frazzled, while it paces under its storm cloud: a tangled scribble ball
// just above and beside its head, redrawn a few times a second.
static inline void fxScribble(thread float3& col, thread const FX& fx) {
    float frazzle = fx.frazzle;
    if (!(frazzle > 0.01 && fx.nearW < 0.9)) return;
    float3 pj = project(fx.head - float3(0.0, 0.05 * fx.s, 0.0) - fx.cam.rt * 0.75 * fx.s, fx.cam);
    float size = 0.1 * fx.cam.focal / pj.z;
    float2 b = (fx.uv - pj.xy) / size;
    if (dot(b, b) >= 2.4) return;
    float jit = floor(fx.time * 4.0);
    float d = 1e5;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float2 c = (hash22(float2(fi, jit)) - 0.5) * 0.5;
        float2 r = float2(0.55, 0.42) + 0.2 * hash22(float2(jit, fi + 7.0));
        float2 q2 = rotate(b - c, fi * 0.8 + jit);
        d = min(d, abs(length(q2 / r) - 1.0) * min(r.x, r.y));
    }
    col = mix(col, float3(0.24, 0.23, 0.28), frazzle * smoothstep(0.075, 0.04, d) * step(pj.z, fx.depth + 0.3));
}

// A sweat drop, sliding down beside its head: a glossy bead of water with an
// ink outline, a little light pooled in its bottom, a crisp highlight.
static inline void fxSweat(thread float3& col, thread const FX& fx) {
    float sweat = fx.sweat;
    if (!(sweat > 0.01 && fx.nearW < 0.9)) return;
    float ph = fract(fx.time * 0.45);
    float3 pj = project(fx.head + float3(0.0, (-0.4 - 0.35 * ph) * fx.s, 0.0) + fx.cam.rt * 1.05 * fx.s, fx.cam);
    float size = 0.12 * fx.cam.focal / pj.z;
    float2 b = (fx.uv - pj.xy) / size + float2(0.0, 0.2);
    if (dot(b, b) > 2.5) return;
    float px = 1.5 * length(fwidth(fx.uv)) / size;         // a pixel, in drop units
    float d = sdTear(b, 0.42, 1.0) - 0.02;
    float a = sweat * smoothstep(0.0, 0.15, ph) * smoothstep(1.0, 0.75, ph) * step(pj.z, fx.depth + 0.3);
    // Outline, in the darker, saturated blue of the water.
    col = mix(col, float3(0.10, 0.22, 0.52), a * smoothstep(0.075 + px, 0.075, d));
    // Body: deeper at the top, where it thins, lighter low down.
    float3 water = mix(float3(0.50, 0.80, 1.0), float3(0.26, 0.55, 0.95), smoothstep(-0.45, 0.75, b.y));
    // Light gathered in its round bottom, as through a lens.
    float pool = smoothstep(0.16, 0.0, abs(d + 0.11)) * smoothstep(0.0, -0.32, b.y);
    water = mix(water, float3(0.82, 0.96, 1.0), 0.65 * pool);
    col = mix(col, water, a * smoothstep(px, 0.0, d));
    // Highlights: a tilted lozenge upper left, and a dot opposite.
    float2 h = rotate(b - float2(-0.17, 0.02), -0.45);
    float hl = length(h / float2(0.075, 0.17)) - 1.0;
    col = mix(col, float3(1.0), a * smoothstep(0.12 + 3.0 * px, 0.0, hl) * 0.95);
    col = mix(col, float3(1.0), a * 0.85 * smoothstep(0.05 + px, 0.05, length(b - float2(0.17, -0.2))));
}

// "!" — it has noticed you.
static inline void fxBang(thread float3& col, thread const FX& fx) {
    float bang = fx.bang;
    if (!(bang > 0.01 && fx.nearW < 0.9)) return;
    float3 pj = project(fx.head + float3(0.0, 0.12, 0.0) + fx.cam.rt * 0.45 * fx.s, fx.cam);
    float pop = smoothstep(0.0, 0.35, bang) * (1.0 + 0.4 * exp(-max(fx.time - 0.62, 0.0) * 8.0));
    float size = 0.24 * pop * fx.cam.focal / pj.z;
    float2 b = (fx.uv - pj.xy) / max(size, 1e-4);
    float d = min(sdSeg(b, float2(0.0, 0.08), float2(0.0, 0.62)) - (0.08 + 0.07 * clamp(b.y / 0.62, 0.0, 1.0)),
                  length(b - float2(0.0, -0.24)) - 0.12);
    col = mix(col, float3(0.3, 0.16, 0.1), bang * smoothstep(0.11, 0.07, d));
    col = mix(col, float3(1.0, 0.84, 0.25), bang * smoothstep(0.035, 0.0, d));
}

// The butterfly's dotted trail (the butterfly itself is in the scene).
static inline void fxTrail(thread float3& col, thread const FX& fx, constant CritterState& S) {
    if (fx.butterfly <= 0.01) return;
    int n = int(S.fx2.w + 0.5);
    for (int i = 0; i < 6; i++) {
        if (i >= n) break;
        float3 pj = project(S.trail[i].xyz, fx.cam);
        float j = float(i + 2);
        float d = length(fx.uv - pj.xy) - 0.007 * fx.cam.focal / pj.z;
        float vis = step(pj.z, fx.depth + 0.2) * fx.butterfly;
        col = mix(col, float3(1.0), vis * 0.55 * (1.0 - j / 7.0) * smoothstep(0.004, 0.0, d));
    }
}

static inline void fxFireflies(thread float3& col, thread const FX& fx, constant CritterState& S) {
    if (fx.night <= 0.2) return;
    for (int i = 0; i < 14; i++) {
        float4 f = S.fly[i];
        if (f.w <= 0.0) continue;
        float3 pj = project(f.xyz, fx.cam);
        float r = 0.012 * fx.cam.focal / pj.z * 6.0;
        float glow = exp(-dot(fx.uv - pj.xy, fx.uv - pj.xy) / (r * r) * 3.0);
        // One passing the lens fades out rather than swelling into a blob.
        float nearLens = smoothstep(0.6, 1.4, pj.z);
        col += float3(0.85, 1.0, 0.45) * glow * f.w * fx.night * nearLens * step(pj.z, fx.depth + 0.3) * 0.9;
    }
}

// ---- seasonInTheAir: in front of everything — spring petals, summer seed
// fluff, autumn leaves, winter snow. Three layers for depth. Sparse (one cell
// in eight; snow one in four), and thinned away over the critter itself, so
// the season is in the air but not in its face.
static inline void seasonInTheAir(thread float3& col, thread const FX& fx, constant CritterState& S) {
    float2 uv = fx.uv;
    float time = fx.time;
    int season = int(S.sky.z + 0.5);
    float3 cj = project(S.body.xyz, fx.cam);
    float cjr = S.body.w * fx.cam.focal / cj.z;
    float clear = smoothstep(0.75 * cjr, 1.6 * cjr, length(uv - cj.xy));
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float cell = 0.2 - 0.045 * fl;
        float fall = (season == 1 ? -0.03 : (season == 3 ? 0.07 : 0.055)) * (1.0 - 0.25 * fl);
        float2 pp = uv + float2(0.025 * time * (season == 3 ? 0.3 : 1.0) + fl * 3.1, fall * time);
        float2 id = floor(pp / cell);
        float hp1 = hash21(id + fl * 17.0);
        float keep = season == 3 ? 0.25 : 0.12;
        if (hp1 > keep) continue;
        hp1 *= (season == 3 ? 0.55 : 0.3) / keep;
        float2 f = fract(pp / cell) - 0.5;
        float2 jit = (hash22(id + 3.0 + fl) - 0.5) * 0.36;
        // Wrapped at 20π, a whole number of turns for ph, ph·0.7 and ph·2.
        float ph = 20.0 * PI * fract(time * (0.8 + hp1 * 2.0) / (20.0 * PI)) + hp1 * 40.0;
        f -= jit + float2(0.07 * sin(ph), 0.0);
        float size = (0.17 + 0.07 * hp1) * (1.0 - 0.22 * fl);
        float2 g2 = rotate(f, ph * 0.7) / size;
        float shape, tone = hash11(hp1 * 91.0);
        float3 pc;
        if (season == 3) {
            shape = length(g2) - 0.55;
            pc = float3(1.0);
        } else if (season == 1) {
            shape = min(length(g2) - 0.25, length(float2(abs(g2.x), g2.y * 0.9) - float2(0.25, 0.25)) - 0.2);
            pc = float3(1.0, 1.0, 0.95);
        } else {
            g2.x *= 1.0 + 0.6 * sin(ph * 2.0);     // tumbling
            shape = length(g2 * float2(1.0, 2.0)) - 0.6;
            pc = season == 2
               ? (tone < 0.33 ? float3(1.0, 0.55, 0.2) : (tone < 0.66 ? float3(0.92, 0.32, 0.2) : float3(1.0, 0.78, 0.28)))
               : (tone < 0.5 ? float3(1.0, 0.72, 0.8) : float3(1.0, 0.86, 0.9));
        }
        float a = smoothstep(0.06, -0.06, shape) * (0.85 - 0.2 * fl) * mix(1.0, 0.45, fx.night) * clear;
        col = mix(col, pc * mix(1.0, 0.5, fx.night), a);
    }
}

// ---------------------------------------------------------------- main

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant CritterState& S [[buffer(1)]],
                        texture2d<float> sceneTex [[texture(1)]],
                        texture2d<float> depthTex [[texture(2)]]) {
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    float2 uv = lerpUV(pos, u.resolution);
    float2 suv = lerpScreenUV(pos, u.resolution);

    Cam cam;
    cam.ro = S.cam0.xyz; cam.focal = S.cam0.w;
    cam.fw = S.cam1.xyz; cam.rt = S.cam2.xyz; cam.up = S.cam3.xyz;
    float zNear = S.cam1.w, zFar = S.cam2.w;

    // The scene, gamma-encoded and premultiplied; the sky behind it.
    float4 scene = sceneTex.sample(linearClamp, suv);
    float3 col = scene.rgb;
    if (S.cam3.w < 0.5 && scene.a < 0.999) {
        float3 rd = normalize(uv.x * cam.rt + uv.y * cam.up + cam.focal * cam.fw);
        col += (1.0 - scene.a) * skyColor(rd, S.light.xyz, S.sky.x, S.sky.y);
    }
    uint2 dsz = uint2(depthTex.get_width(), depthTex.get_height());
    uint2 dp = min(uint2(suv * float2(dsz)), dsz - 1);
    float zb = depthTex.read(dp).r;
    float depth = zNear * zFar / max(zFar - zb * (zFar - zNear), 1e-6);

    FX fx;
    fx.uv = uv;
    fx.cam = cam;
    fx.depth = depth;
    fx.head = S.head.xyz; fx.s = S.head.w;
    fx.feet = S.feet.xyz; fx.stage = S.feet.w;
    fx.cloud = S.cloud.xyz; fx.cloudK = S.cloud.w;
    fx.time = S.sky.w;
    fx.zzz = S.fx0.x; fx.love = S.fx0.y; fx.glee = S.fx0.z; fx.sick = S.fx0.w;
    fx.storm = S.fx1.x; fx.flash = S.fx1.y; fx.sweat = S.fx1.z; fx.bang = S.fx1.w;
    fx.frazzle = S.fx2.x; fx.butterfly = S.fx2.z;
    fx.night = S.sky.x;
    // How far this pixel is from the critter's head, in world units at its
    // depth: the overlays near it are skipped beyond their reach.
    float3 hj = project(fx.head, cam);
    fx.nearW = length(uv - hj.xy) * hj.z / cam.focal;

    fxZzz(col, fx);
    fxHearts(col, fx);
    fxSparkles(col, fx);
    fxRain(col, fx);
    fxLightning(col, fx);
    fxScribble(col, fx);
    fxSweat(col, fx);
    fxBang(col, fx);
    fxTrail(col, fx, S);
    fxFireflies(col, fx, S);
    seasonInTheAir(col, fx, S);

    // A gentle vignette, and dither.
    float2 sp = suv - 0.5;
    col *= 1.0 - 0.28 * dot(sp, sp) * 1.6;
    col = lerpDither(col, pos);
    return half4(half3(clamp(col, 0.0, 1.0)), 1.0h);
}
