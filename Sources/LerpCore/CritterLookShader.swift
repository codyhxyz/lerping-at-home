import Foundation

// The Metal source of CritterLook's shader modifiers. One source for every
// material (the kind is a per-material uniform), so SceneKit compiles a
// handful of variants rather than one program per kind.
//
//   geometry        the rolled world (every vertex but the sky's drops by
//                   bend·|xz − focus|², its normal tilts to match) and, on an
//                   ink hull, the push along the normal. Hands the fragment the
//                   unbent world, object and critter-local positions.
//   lightingModel   the key light as a soft 3-band toon ramp with wrap; the
//                   shadow map's attenuation rides in _light.intensity.
//   fragment        albedo by kind (season, health, face, sea, sky…), then
//                   cool lavender ambient + warm key + sky rim + tiny crisp
//                   highlights + haze, written display-encoded (sRGB-ish).
//
// Colours in this file are written as sRGB and decoded with lkLin.
enum CritterLookShader {

    // Kinds (CritterLook.Kind mirrors these).
    static let geometry = """
    struct LookU {
        float4x4 critterInv;
        float4 light;    // lightDir.xyz (world), night
        float4 sun;      // sunColor.rgb, golden
        float4 amb;      // skyAmbient.rgb, time
        float4 bend;     // bend, focus.x, focus.y, hour
        float4 face;     // mouth, mouthO, bags, happy
        float4 eyes;     // eye, lid, lidTilt, droop
        float4 who;      // season, health, identity, stage
        float4 body;     // body colour (sRGB), bloom
        float4 sunDir;   // sunDir.xyz, hatch
        float4 moonDir;  // moonDir.xyz, wobble
        float4 fx;       // flash, cloudDark, storm, sick
        float4 ink;      // fraction of screen height, min px, -, -
    };

    #define LK_GENERIC 0
    #define LK_BODY 1
    #define LK_LIMB 2
    #define LK_EYE 3
    #define LK_LEAF 4
    #define LK_BLOSSOM 5
    #define LK_EGG 6
    #define LK_NEST 7
    #define LK_BARK 8
    #define LK_CANOPY 9
    #define LK_FRUIT 10
    #define LK_PETAL 11
    #define LK_STEM 12
    #define LK_SKYCLOUD 13
    #define LK_STORM 14
    #define LK_WING 15
    #define LK_CASTLE 16
    #define LK_ROCK 17
    #define LK_GROUND 18
    #define LK_SEA 19
    #define LK_SKY 20

    static inline float3 lkLin(float3 c) { return pow(max(c, 0.0), 2.2); }
    static inline float3 lkEnc(float3 c) { return pow(max(c, 0.0), 1.0 / 2.2); }
    // Integer hash of a lattice cell (fast-math float hashes collapse on
    // some inputs); `s` picks an independent stream.
    static inline float lkHash(float2 p, uint s) {
        int2 i = int2(floor(p));
        uint h = uint(i.x) * 1597334677u ^ uint(i.y) * 3812015801u ^ s * 2654435769u;
        h = (h ^ (h >> 16)) * 2246822519u;
        h = (h ^ (h >> 13)) * 3266489917u;
        h ^= h >> 16;
        return float(h & 0xffffffu) / 16777216.0;
    }
    static inline float lkHash(float2 p) { return lkHash(p, 0u); }
    static inline float lkNoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = lkHash(i), b = lkHash(i + float2(1, 0)), c = lkHash(i + float2(0, 1)), d = lkHash(i + float2(1, 1));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }
    // sin(t·w) safe for a clock that has run for hours.
    static inline float lkPhase(float t, float w) { return 6.2831853 * fract(t * (w / 6.2831853)); }
    // 1 inside (d < 0), antialiased over a pixel.
    static inline float lkFill(float d) { float w = max(fwidth(d), 1e-5); return clamp(0.5 - d / w, 0.0, 1.0); }
    // The island's height (the old shader's groundH, ISLAND_R 7): the sea
    // uses it for its depth and foam.
    static inline float lkGround(float2 xz, float ident) {
        float d = length(xz);
        float hills = 0.11 * sin(xz.x * 0.55 + ident * 7.0) * sin(xz.y * 0.5 + ident * 3.0)
                    + 0.035 * sin(xz.x * 1.7 + ident * 11.0 + sin(xz.y * 1.3)) * sin(xz.y * 1.9 - ident * 5.0);
        hills *= smoothstep(1.4, 3.6, d);
        float shore = smoothstep(7.0 - 1.7, 7.0 + 0.9, d);
        return 0.04 + hills * (1.0 - shore) - 0.8 * shore;
    }
    static inline float3 lkHorizon(LookU u) {
        float3 day = mix(float3(0.87, 0.95, 1.0), float3(1.0, 0.7, 0.46), u.sun.w);
        return mix(day, float3(0.12, 0.15, 0.3), u.light.w);
    }
    static inline float3 lkSky(float3 rd, LookU u) {
        float night = u.light.w, golden = u.sun.w, t = u.amb.w;
        float y = clamp(rd.y, -0.2, 1.0);
        float3 top = mix(mix(float3(0.45, 0.76, 0.95), float3(0.5, 0.52, 0.85), golden), float3(0.025, 0.04, 0.12), night);
        float3 hor = lkHorizon(u);
        float3 c = mix(hor, top, smoothstep(-0.02, 0.75, y));
        float3 sd3 = normalize(u.sunDir.xyz);
        float sd = dot(rd, sd3);
        float day = 1.0 - night;
        c += day * pow(max(sd, 0.0), 14.0) * mix(float3(0.16, 0.13, 0.06), float3(0.5, 0.26, 0.08), golden);
        float sun = lkFill(0.9993 - sd);
        c = mix(c, mix(float3(1.0, 0.98, 0.9), float3(1.0, 0.86, 0.6), golden), sun * day);
        float3 md3 = normalize(u.moonDir.xyz);
        float md = dot(rd, md3);
        float moon = lkFill(0.99955 - md);
        // a crescent: the disc less one nudged toward the sun's side
        float3 off = normalize(md3 + 0.022 * normalize(cross(md3, float3(0, 1, 0)) + float3(0, 0.3, 0)));
        moon *= 1.0 - lkFill(0.99955 - dot(rd, off));
        c += night * pow(max(md, 0.0), 80.0) * float3(0.06, 0.08, 0.14);
        c = mix(c, float3(1.0, 0.97, 0.84), moon * night);
        if (rd.y > 0.0 && night > 0.01) {
            float2 st = float2(atan2(rd.z, rd.x), asin(rd.y)) * 60.0;
            float2 cell = floor(st);
            float h = lkHash(cell);
            float2 o = float2(lkHash(cell, 1u), lkHash(cell, 2u)) - 0.5;
            float r = length(fract(st) - 0.5 - o * 0.6);
            float star = lkFill(r - 0.07 - 0.05 * fract(h * 13.0)) * step(0.955, h);
            star *= 0.65 + 0.35 * sin(lkPhase(t, 1.0 + 3.0 * h) + h * 40.0);
            c += night * star * smoothstep(0.02, 0.2, rd.y) * float3(0.95, 0.95, 1.0);
        }
        return c;
    }

    #pragma arguments
    LookU lookU;
    float4 lookMat;   // kind, ink (1), param (eye radius / egg height), ink width scale

    #pragma varyings
    float3 lookW;
    float3 lookO;
    float3 lookC;

    #pragma body
    float4x4 lkM = scn_node.modelTransform;
    float4x4 lkMi = scn_node.inverseModelTransform;
    float3x3 lkMi3 = float3x3(lkMi[0].xyz, lkMi[1].xyz, lkMi[2].xyz);
    float3x3 lkM3 = float3x3(lkM[0].xyz, lkM[1].xyz, lkM[2].xyz);
    float4 lkWp = lkM * _geometry.position;
    float3 lkNw = normalize(_geometry.normal * lkMi3);
    out.lookW = lkWp.xyz;
    out.lookO = _geometry.position.xyz;
    out.lookC = (lookU.critterInv * lkWp).xyz;
    int lkKind = int(lookMat.x + 0.5);
    if (lkKind != LK_SKY) {
        float lkB = lookU.bend.x;
        float2 lkD = lkWp.xz - lookU.bend.yz;
        lkWp.y -= lkB * dot(lkD, lkD);
        lkNw = normalize(float3(lkNw.x + 2.0 * lkB * lkD.x * lkNw.y, lkNw.y, lkNw.z + 2.0 * lkB * lkD.y * lkNw.y));
    }
    if (lookMat.y > 0.5) {
        // Ink hull: out along the normal by a fixed share of the screen's
        // height (never under `min px`), so the line is the same weight at
        // any resolution and any distance.
        float lkZ = max(-(scn_frame.viewTransform * lkWp).z, 0.05);
        float lkIr = scn_frame.inverseResolution.y;
        float lkPx = max(lookU.ink.x / lkIr, lookU.ink.y) * lookMat.w;
        float lkWorld = lkPx * 2.0 * lkZ * lkIr / scn_frame.projectionTransform[1][1];
        lkWp.xyz += lkNw * lkWorld;
    }
    _geometry.position = lkMi * lkWp;
    _geometry.normal = normalize(lkNw * lkM3);
    """

    static let lighting = """
    {
        float lkNdl = dot(_surface.normal, _light.direction);
        float lkW = (lkNdl + 0.32) / 1.32;
        float lkBand = 0.5 * smoothstep(0.17, 0.23, lkW) + 0.5 * smoothstep(0.52, 0.6, lkW);
        // `_att` is the light's attenuation times its shadow (SceneKit
        // passes shade(l, colour, intensity) through as _att); intensity is
        // the colour. The key is white: CritterLook tints it in the fragment.
        _lightingContribution.diffuse += lkBand * _light._att * _light.intensity.rgb;
    }
    """

    static let fragment = """
    #pragma arguments
    LookU lookU;
    float4 lookMat;

    #pragma body
    {
    LookU u = lookU;
    int kind = int(lookMat.x + 0.5);
    bool ink = lookMat.y > 0.5;
    float night = u.light.w;
    float golden = u.sun.w;
    float time = u.amb.w;
    int season = int(u.who.x + 0.5);
    float health = u.who.y;
    float ident = u.who.z;
    float3 W = in.lookW;
    float3 O = in.lookO;
    float3 C = in.lookC;
    float3x3 iv = float3x3(scn_frame.inverseViewTransform[0].xyz, scn_frame.inverseViewTransform[1].xyz, scn_frame.inverseViewTransform[2].xyz);
    float3 camW = scn_frame.inverseViewTransform[3].xyz;
    float3 N = normalize(_surface.normal);
    float3 nW = normalize(iv * N);
    float3 V = normalize(-_surface.position);
    float3 Lv = normalize((scn_frame.viewTransform * float4(u.light.xyz, 0.0)).xyz);
    float4x4 M = scn_node.modelTransform;
    float2 origin = M[3].xz;                       // this node's place: per-instance variety
    float idh = lkHash(origin * 7.31 + ident * 170.0, 3u);
    float3 base = _surface.diffuse.rgb;            // asset colour, linear
    float3 bodyCol = lkLin(u.body.rgb);

    float3 alb = base;
    float rim = 0.2, spec = 0.0, emit = 0.0, aoK = 1.0, aoA = 1.0;
    bool unlit = false;
    float3 flat = float3(0.0);

    if (kind == LK_SKY) {
        unlit = true;
        flat = lkSky(normalize(W - camW), u);
    } else if (kind == LK_BODY || kind == LK_LIMB) {
        alb = bodyCol;
        float3 rel = C - float3(0.0, 0.95, 0.0);
        if (kind == LK_BODY) {
            // lighter tummy
            float tum = smoothstep(0.35, 0.7, rel.z) * smoothstep(0.25, -0.3, rel.y) * smoothstep(0.22, 0.38, C.y);
            alb = mix(alb, mix(alb, lkLin(float3(1.0, 0.98, 0.92)), 0.5), tum);
            float front = smoothstep(0.25, 0.45, rel.z);
            // blush: a soft-edged oval under each eye
            float2 ck = float2(abs(rel.x) - 0.55, rel.y + 0.1) / float2(1.0, 0.72);
            float blush = smoothstep(0.15, 0.1, length(ck)) * front;
            alb = mix(alb, lkLin(float3(1.0, 0.56, 0.62)), blush * 0.7);
            // worn out: shadows under the eyes
            float2 ue = float2(abs(rel.x) - 0.34, rel.y - 0.1);
            float bag = smoothstep(0.22, 0.06, abs(length(ue / float2(0.13, 0.2)) - 1.0)) * smoothstep(-0.08, -0.14, ue.y) * front;
            alb = mix(alb, alb * lkLin(float3(0.72, 0.62, 0.84)), bag * u.face.z);
            // mouth: a curve (smile/frown), or an open "o" ("D" when happy)
            float mouth = u.face.x, mouthO = u.face.y;
            float mx = rel.x, my = rel.y + 0.14;
            float amp = 5.4 * mouth;
            float cx = clamp(mx, -0.12, 0.12);
            float slope = amp * 2.8 * cx;
            float dm = length(float2(mx - cx, (my + amp * (0.01 - cx * cx * 1.4)) * rsqrt(1.0 + slope * slope)));
            float line = lkFill(dm - 0.024) * (1.0 - smoothstep(0.15, 0.4, mouthO));
            float2 orad = float2(0.045 + 0.045 * mouthO, 0.025 + 0.075 * mouthO);
            float2 mo = float2(mx, my + 0.01) / orad;
            float lip = mo.y - (1.0 - 0.75 * clamp(mouth, 0.0, 1.0));
            float open = lkFill(max(length(mo), 1.0 + lip) - 1.0) * step(0.05, mouthO);
            float onFace = step(0.5, rel.z);
            alb = mix(alb, lkLin(float3(0.3, 0.12, 0.14)), max(line, open) * onFace);
            alb = mix(alb, lkLin(float3(0.96, 0.46, 0.52)), open * smoothstep(-0.2, -0.6, mo.y) * onFace);
        } else {
            alb *= mix(1.0, 0.86, smoothstep(0.35, 0.15, C.y));   // feet a shade darker
        }
        alb *= mix(float3(1.0), float3(1.5, 1.3, 1.0), night);   // its colour survives the moonlight
        emit = night * 0.03;
        rim = 0.55;
    } else if (kind == LK_EYE) {
        // eye-local, unit radius; x outward from the face's middle
        float3 e = O / max(lookMat.z, 1e-4);
        float side = C.x >= 0.0 ? 1.0 : -1.0;
        float happy = u.face.w, eyeOpen = u.eyes.x, lid = u.eyes.y, tilt = u.eyes.z;
        float shut = max(lid, 1.0 - eyeOpen);
        alb = lkLin(float3(0.07, 0.055, 0.1));
        alb = mix(alb, lkLin(float3(0.2, 0.2, 0.34)), smoothstep(-0.2, -0.8, e.y) * 0.8);   // a little light pooled low
        float glintOK = step(0.3, eyeOpen) * step(lid, 0.4) * (1.0 - step(0.5, abs(happy)));
        float g1 = lkFill(length(e.xy - float2(0.3 * side, 0.38)) - 0.26);
        float g2 = lkFill(length(e.xy - float2(-0.22 * side, -0.32)) - 0.11);
        alb = mix(alb, float3(1.6), max(g1, g2 * 0.85) * glintOK);
        if (abs(happy) > 0.5 || shut > 0.9) {
            // ^^ (happy), ‿ (asleep) or a plain shut line, drawn as a stroke
            // on the eye's surface; the rest of the eye is gone.
            float k = happy > 0.5 ? -1.0 : (happy < -0.5 ? 0.8 : 0.35);
            float yy = (happy > 0.5 ? 0.25 : -0.15) + k * 0.9 * e.x * e.x;
            float d = abs(e.y - yy) - 0.17;
            d = max(d, abs(e.x) - 0.85);
            if (d > 0.0) discard_fragment();
            alb = lkLin(float3(0.12, 0.08, 0.12));
        } else if (shut > 0.02) {
            // the lid: skin above a slanted line, a dark rim along its edge
            float outer = e.x * side;
            float yl = 1.05 - 2.1 * shut - tilt * 0.55 * outer;
            float under = lkFill(yl - e.y);
            float edge = lkFill(abs(e.y - yl) - 0.09);
            alb = mix(alb, bodyCol, under);
            alb = mix(alb, lkLin(float3(0.12, 0.08, 0.12)), edge);
        }
        rim = 0.15;
    } else if (kind == LK_LEAF) {
        alb = mix(lkLin(float3(0.45, 0.78, 0.33)), lkLin(float3(0.68, 0.58, 0.32)), u.eyes.w * 0.85);
        emit = night * 0.12 * health;
        rim = 0.4;
    } else if (kind == LK_BLOSSOM) {
        alb = lkLin(mix(float3(1.0, 0.58, 0.72), float3(1.0, 0.85, 0.36), fract(ident * 3.7)));
        emit = night * 0.2;
        rim = 0.45;
    } else if (kind == LK_EGG) {
        float h = max(lookMat.z, 1e-4);
        float3 p = O / h;
        float wob = u.moonDir.w;
        float3 spotCol = mix(bodyCol, lkLin(float3(0.64, 0.66, 0.58)), (1.0 - health) * 0.5);
        alb = lkLin(float3(0.99, 0.96, 0.88));
        float sp = lkNoise(p.xy * 7.0 + p.z * 5.0 + ident * 20.0);
        alb = mix(alb, spotCol, lkFill(0.64 - sp));
        float ang = atan2(p.z, p.x);
        float hatch = u.sunDir.w;
        float zig = 0.55 + 0.04 * (2.0 * abs(fract(ang * 2.2) - 0.5) * 2.0 - 1.0);
        float crack = lkFill(abs(p.y - zig) - (0.008 + 0.008 * hatch)) * step(0.05, hatch)
                    * step(fract(ang / 6.2831853 + 0.5), 0.25 + 0.75 * hatch);
        alb = mix(alb, lkLin(float3(0.35, 0.26, 0.22)), crack);
        rim = 0.35;
        (void)wob;
    } else if (kind == LK_NEST) {
        alb = lkLin(float3(0.78, 0.6, 0.36)) * (0.82 + 0.3 * lkNoise(float2(atan2(O.z, O.x) * 9.0, O.y * 30.0)));
    } else if (kind == LK_BARK) {
        alb = lkLin(float3(0.6, 0.41, 0.27)) * (0.9 + 0.1 * step(0.5, fract(O.y * 6.0 + 0.25 * sin(atan2(O.z, O.x) * 3.0))));
        rim = 0.15;
    } else if (kind == LK_CANOPY) {
        float3 c;
        if (season == 0) c = (idh < 0.5 || lookMat.z > 0.5) ? float3(0.36, 0.73, 0.35) : float3(1.0, 0.77, 0.84);
        else if (season == 1) c = idh < 0.5 ? float3(0.36, 0.73, 0.35) : float3(0.3, 0.6, 0.34);
        else if (season == 2 && lookMat.z < 0.5) c = idh < 0.34 ? float3(0.95, 0.64, 0.24) : (idh < 0.67 ? float3(0.89, 0.38, 0.23) : float3(0.96, 0.78, 0.29));
        else if (season == 2) c = float3(0.27, 0.54, 0.36);   // evergreens keep theirs
        else c = float3(0.25, 0.48, 0.38);
        c = mix(c, c * float3(0.88, 0.82, 0.62), (1.0 - health) * 0.5);
        alb = lkLin(c);
        if (season == 3) alb = mix(alb, lkLin(float3(0.96, 0.97, 1.0)), lkFill(0.55 - nW.y - 0.1 * lkNoise(W.xz * 6.0)));
        rim = 0.3;
    } else if (kind == LK_FRUIT) {
        alb = lkLin(season == 2 ? float3(1.0, 0.5, 0.18) : float3(0.93, 0.22, 0.24));
        spec = 1.0; rim = 0.3;
    } else if (kind == LK_PETAL) {
        float3 pal[6] = { float3(1.0, 0.98, 0.95), float3(1.0, 0.62, 0.74), float3(1.0, 0.86, 0.32),
                          float3(0.95, 0.38, 0.38), float3(0.74, 0.6, 1.0), float3(1.0, 0.64, 0.32) };
        alb = lkLin(pal[int(idh * 5.999)]);
        alb = mix(alb, alb * lkLin(float3(0.85, 0.75, 0.55)), (1.0 - health) * 0.5);
        rim = 0.3;
    } else if (kind == LK_STEM) {
        float3 g = season == 2 ? float3(0.52, 0.62, 0.3) : float3(0.33, 0.62, 0.36);
        alb = lkLin(mix(g, float3(0.66, 0.6, 0.36), (1.0 - health) * 0.6));
        rim = 0.1;
    } else if (kind == LK_SKYCLOUD) {
        alb = lkLin(mix(mix(float3(1.0), float3(1.0, 0.82, 0.72), golden), float3(0.36, 0.4, 0.58), night));
        aoA = 1.9; aoK = 0.85; rim = 0.6;   // soft: lit mostly by the sky
    } else if (kind == LK_STORM) {
        alb = lkLin(mix(float3(0.46, 0.48, 0.56), float3(0.58, 0.61, 0.7), u.fx.y));
        alb = mix(alb, lkLin(float3(0.85, 0.88, 0.98)), u.fx.x);
        rim = 0.35;
    } else if (kind == LK_WING) {
        rim = 0.45;
    } else if (kind == LK_CASTLE) {
        alb = lkLin(float3(0.93, 0.83, 0.6)) * (0.92 + 0.1 * lkNoise(O.xz * 40.0 + O.y * 30.0));
        rim = 0.15;
    } else if (kind == LK_ROCK) {
        alb = lkLin(float3(0.66, 0.64, 0.7)) * (0.9 + 0.12 * lkNoise(O.xz * 6.0 + O.y * 5.0));
        rim = 0.2;
    } else if (kind == LK_GROUND) {
        float gh = W.y;
        float3 lush = season == 3 ? float3(0.9, 0.93, 0.97) : (season == 2 ? float3(0.66, 0.77, 0.42) : (season == 1 ? float3(0.5, 0.79, 0.39) : float3(0.53, 0.82, 0.42)));
        float3 dry = float3(0.8, 0.74, 0.47);
        float3 grass = mix(lush, dry, smoothstep(0.65, 0.2, health) * (season == 3 ? 0.2 : 1.0));
        // big soft-edged patches, a shade apart: toon dapple
        float patch = lkFill(0.56 - lkNoise(W.xz * 0.75 + 3.0));
        grass *= mix(1.0, season == 3 ? 0.97 : 0.94, patch);
        float3 sand = float3(0.95, 0.87, 0.64) * (0.97 + 0.05 * lkNoise(W.xz * 5.0));
        float wet = smoothstep(-0.12, -0.2, gh);
        sand = mix(sand, sand * float3(0.86, 0.82, 0.76), wet);
        float shore = lkFill(gh - (-0.03 + 0.02 * lkNoise(W.xz * 2.0)));
        alb = lkLin(mix(grass, sand, shore));
        // a worn patch where it stands
        alb = mix(alb, lkLin(float3(0.8, 0.76, 0.5)), smoothstep(0.75, 0.45, length(W.xz)) * 0.18 * (season == 3 ? 0.0 : 1.0));
        // contact shadow at its feet
        float cr = length(C.xz);
        float cont = smoothstep(1.25, 0.15, cr) * smoothstep(0.8, 0.0, abs(C.y));
        aoA = 1.0 - 0.45 * cont;
        aoK = 1.0 - 0.6 * cont;
        // cloud shadows drifting over
        float2 cs = W.xz * 0.16 + float2(0.05, 0.022) * time;
        float cl = smoothstep(0.55, 0.7, lkNoise(cs) * 0.65 + lkNoise(cs * 2.3 + 5.0) * 0.35);
        aoK *= 1.0 - 0.25 * cl * (1.0 - night);
        rim = 0.0;
    } else if (kind == LK_SEA) {
        float depth = -0.2 - lkGround(W.xz, ident);
        float r = length(W.xz);
        float3 sh = float3(0.35, 0.85, 0.81), dp = float3(0.14, 0.46, 0.72);
        float3 c = mix(sh, dp, smoothstep(0.0, 0.9, depth));
        c = mix(c, dp * 0.85, smoothstep(14.0, 30.0, r));
        // drifting light streaks
        float2 q = W.xz * float2(0.9, 1.6) + float2(time * 0.06, time * 0.035);
        float streak = lkFill(0.66 - lkNoise(q)) * (1.0 - lkFill(0.7 - lkNoise(q)));
        c = mix(c, mix(c, float3(0.85, 0.98, 1.0), 0.35), streak * smoothstep(0.1, 0.5, depth));
        // foam: a wobbling ring on the shore, and a wave line rolling in
        float ang = atan2(W.z, W.x);
        float foam = lkFill(depth - (0.05 + 0.025 * sin(lkPhase(time, 1.3) + ang * 9.0)));
        float ph = fract(time * 0.11);
        float wl = 0.06 + 0.42 * (1.0 - ph);
        float wave = lkFill(abs(depth - wl) - 0.012 * (0.4 + ph)) * smoothstep(0.0, 0.25, ph) * (0.5 + 0.5 * sin(ang * 5.0 + 1.3));
        c = mix(c, float3(1.0), max(foam, wave * 0.8));
        alb = lkLin(mix(c, c * float3(0.4, 0.5, 0.75), night * 0.4));
        // sparkle: crisp glints where the sun (or moon) would mirror
        float2 sc = W.xz * 2.2;
        float2 cell = floor(sc);
        float hh = lkHash(cell, 4u);
        float2 sp = cell + 0.5 + (float2(lkHash(cell, 5u), lkHash(cell, 6u)) - 0.5) * 0.6;
        float tw = 0.5 + 0.5 * sin(lkPhase(time, 1.7 + 2.0 * hh) + hh * 30.0);
        float3 Rv = reflect(-V, N);
        float mir = pow(max(dot(Rv, Lv), 0.0), 6.0);
        float dot1 = lkFill(length(sc - sp) - 0.07 * smoothstep(0.75, 1.0, tw));
        emit = dot1 * step(0.55, hh) * mir * 1.4 * smoothstep(0.1, 0.4, depth);
        // the sky in it, toward the horizon
        float fres = pow(1.0 - max(dot(N, V), 0.0), 5.0);
        alb = mix(alb, lkLin(lkHorizon(u)) * 0.8, fres * 0.6);
        rim = 0.0;
    }

    float3 col;
    if (ink) {
        // darker, more saturated version of its own colour
        float3 s = lkEnc(alb);
        float m = max(max(s.r, s.g), max(s.b, 1e-3));
        float3 sat = pow(s / m, float3(1.7)) * m;
        float3 inkc = mix(sat * 0.5, float3(0.17, 0.1, 0.16), 0.22);
        inkc *= mix(1.0, 0.6, night);
        col = inkc;
    } else if (unlit) {
        col = flat;
    } else {
        float lit = clamp(_lightingContribution.diffuse.r, 0.0, 1.0) * aoK;
        float3 key = lkLin(u.sun.rgb) * 0.72;
        // the shade: the sky's ambient pushed toward lavender, never grey
        float3 amb = lkLin(mix(u.amb.rgb, float3(0.66, 0.62, 0.95) * dot(u.amb.rgb, float3(0.333)) / 0.733, 0.45)) * 0.62 * (0.75 + 0.25 * nW.y) * aoA;
        amb += lkLin(float3(0.55, 0.62, 0.4)) * (0.5 - 0.5 * nW.y) * 0.12 * (1.0 - night);
        // by night colours fade toward moonlit blue (not for its own glow)
        float lum = dot(alb, float3(0.3, 0.55, 0.15));
        alb = mix(alb, lum * float3(0.55, 0.75, 1.25), night * 0.55);
        float3 lin = alb * (amb + key * lit);
        float fr = pow(clamp(1.0 - dot(N, V), 0.0, 1.0), 3.0);
        lin += lkLin(lkHorizon(u)) * rim * fr * (0.35 + 0.4 * lit) * alb * 1.6;
        if (spec > 0.0) {
            float3 Hv = normalize(Lv + V);
            lin += spec * lkFill(0.975 - dot(N, Hv)) * lit * key;
        }
        lin += emit * lkLin(float3(1.0, 0.92, 0.7));
        // haze toward the horizon
        float t = length(_surface.position);
        float fog = 1.0 - exp(-0.0004 * t * t);
        lin = mix(lin, lkLin(lkHorizon(u)), fog);
        col = lkEnc(lin);
    }
    _output.color = float4(col * _output.color.a, _output.color.a);
    }
    """
}
