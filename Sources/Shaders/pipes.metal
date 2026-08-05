// Pipes — an homage to Microsoft's 3D Pipes screensaver (sspipes, 1994).
// Original work for Lerping@Home; no code from the original, but the geometry,
// camera, material table and lighting model are reproduced from its published
// constants so the result matches what people remember.
//
// lerp-data: pipes
//
// The lattice walk lives on the CPU (Sources/LerpCore/PipesData.swift) and is
// regenerated from (seed, time) every frame. This file raymarches it: the ray
// is stepped cell by cell through the lattice and only the one node record
// belonging to the current cell is evaluated, so cost is independent of how
// many pipes are on screen.

// --- Geometry. Original: divSize 7.0, pipe radius 1.0, ball joints √2·radius.
constant float PP_R       = 1.0 / 7.0;
constant float PP_JOINT_R = 1.41421356 / 7.0;

// --- Camera. Original: gluPerspective(90°), zTrans -75 with divSize 7, and a
// scene yaw that advances 9.73156° on every wipe and is otherwise dead still.
constant float PP_FOCAL    = 1.0;          // = 1 / tan(90°/2)
constant float PP_VIEWDIST = 75.0 / 7.0;   // lattice units from the eye to the volume
constant float PP_YAW_STEP = 0.16985;      // 9.73156° in radians

constant int PP_STEPS = 160;                // cell/sphere-trace iterations per ray

// --- Materials. The original picked from 16 of the OpenGL "teapot" materials:
// emerald, jade, pearl, ruby, turquoise, brass, bronze, copper, gold, silver,
// cyan/white/yellow plastic, cyan/green/white rubber. Ambient, diffuse,
// specular and specular exponent are the original table's values verbatim.
// Note the metals carry a real ambient term so their unlit sides stay readable,
// while the plastics have none and go pure black — that contrast is part of
// the look.
constant float3 PP_KA[16] = {
    float3(0.0215,   0.1745,   0.0215),   // emerald
    float3(0.135,    0.2225,   0.1575),   // jade
    float3(0.25,     0.20725,  0.20725),  // pearl
    float3(0.1745,   0.01175,  0.01175),  // ruby
    float3(0.1,      0.18725,  0.1745),   // turquoise
    float3(0.329412, 0.223529, 0.027451), // brass
    float3(0.2125,   0.1275,   0.054),    // bronze
    float3(0.19125,  0.0735,   0.0225),   // copper
    float3(0.24725,  0.1995,   0.0745),   // gold
    float3(0.19225,  0.19225,  0.19225),  // silver
    float3(0.0,      0.1,      0.06),     // cyan plastic
    float3(0.0,      0.0,      0.0),      // white plastic
    float3(0.0,      0.0,      0.0),      // yellow plastic
    float3(0.0,      0.05,     0.05),     // cyan rubber
    float3(0.0,      0.05,     0.0),      // green rubber
    float3(0.05,     0.05,     0.05),     // white rubber
};
constant float3 PP_KD[16] = {
    float3(0.07568,  0.61424,  0.07568),
    float3(0.54,     0.89,     0.63),
    float3(1.0,      0.829,    0.829),
    float3(0.61424,  0.04136,  0.04136),
    float3(0.396,    0.74151,  0.69102),
    float3(0.780392, 0.568627, 0.113725),
    float3(0.714,    0.4284,   0.18144),
    float3(0.7038,   0.27048,  0.0828),
    float3(0.75164,  0.60648,  0.22648),
    float3(0.50754,  0.50754,  0.50754),
    float3(0.0,      0.50980392, 0.50980392),
    float3(0.55,     0.55,     0.55),
    float3(0.5,      0.5,      0.0),
    float3(0.4,      0.5,      0.5),
    float3(0.4,      0.5,      0.4),
    float3(0.5,      0.5,      0.5),
};
// rgb = specular reflectance, a = GL shininess (specExp * 128).
constant float4 PP_KS[16] = {
    float4(0.633,    0.727811, 0.633,    0.6      * 128.0),
    float4(0.316228, 0.316228, 0.316228, 0.1      * 128.0),
    float4(0.296648, 0.296648, 0.296648, 0.088    * 128.0),
    float4(0.727811, 0.626959, 0.626959, 0.6      * 128.0),
    float4(0.297254, 0.30829,  0.306678, 0.1      * 128.0),
    float4(0.992157, 0.941176, 0.807843, 0.217948 * 128.0),
    float4(0.393548, 0.271906, 0.166721, 0.2      * 128.0),
    float4(0.256777, 0.137622, 0.086014, 0.1      * 128.0),
    float4(0.628281, 0.555802, 0.366065, 0.4      * 128.0),
    float4(0.508273, 0.508273, 0.508273, 0.4      * 128.0),
    float4(0.50196078, 0.50196078, 0.50196078, 0.25 * 128.0),
    float4(0.70,     0.70,     0.70,     0.25     * 128.0),
    float4(0.60,     0.60,     0.50,     0.25     * 128.0),
    float4(0.04,     0.7,      0.7,      0.078125 * 128.0),
    float4(0.04,     0.7,      0.04,     0.078125 * 128.0),
    float4(0.7,      0.7,      0.7,      0.078125 * 128.0),
};

// GL_LIGHT0 sat at (90, 90, 150, 0) — a directional light fixed in *eye* space,
// over the viewer's right shoulder. With GL_LIGHT_MODEL_LOCAL_VIEWER off the
// eye vector is a constant (0,0,1), so the Blinn half-vector is constant too,
// which is why the original's highlight is a broad band down the pipe rather
// than a hotspot. Global ambient was (1,1,1) and the light's own ambient
// (0.1,0.1,0.1), hence the 1.1× on ka.
constant float3 PP_L_EYE = float3(0.4558, 0.4558, 0.7597);
constant float3 PP_H_EYE = float3(0.2433, 0.2433, 0.9392);
constant float  PP_AMBIENT = 1.1;

// ---------------------------------------------------------------------------
// Node SDF. `q` is relative to the cell centre, so the cell is [-0.5, 0.5]^3
// and every stub reaches exactly to a face.

static inline float ppNode(float3 q, LerpPipesNode n) {
    float d = 1e9;

    // Treat the growing tip as a connection when deciding whether this node is
    // a straight pass-through: that way a node about to continue in a straight
    // line never briefly sprouts a ball joint.
    uint eff = n.mask;
    if (n.hasPartial && !n.inward) eff |= (1u << n.partialDir);

    // Three axis runs, each spanning [lo, hi] of the cell.
    float3 lo = float3((eff & 2u) ? -0.5 : 0.0, (eff & 8u) ? -0.5 : 0.0, (eff & 32u) ? -0.5 : 0.0);
    float3 hi = float3((eff & 1u) ?  0.5 : 0.0, (eff & 4u) ?  0.5 : 0.0, (eff & 16u) ?  0.5 : 0.0);
    // The partial stub is drawn separately; keep it out of the full-length runs.
    if (n.hasPartial && !n.inward) {
        uint a = n.partialDir >> 1;
        if ((n.partialDir & 1u) == 0u) hi[a] = 0.0; else lo[a] = 0.0;
    }

    for (uint a = 0; a < 3; ++a) {
        if (lo[a] == hi[a]) continue;
        float3 c = q;
        c[a] -= clamp(q[a], lo[a], hi[a]);
        d = min(d, length(c) - PP_R);
    }

    // Growing tip: outward [0, len] from the centre, or inward [0.5-len, 0.5]
    // from the face, depending on which side of the gap between two nodes the
    // tip has reached.
    if (n.hasPartial) {
        uint a = n.partialDir >> 1;
        float s = (n.partialDir & 1u) ? -1.0 : 1.0;
        float t0 = n.inward ? (0.5 - n.partialLen) : 0.0;
        float t1 = n.inward ? 0.5 : n.partialLen;
        float3 c = q;
        c[a] -= s * clamp(q[a] * s, t0, t1);
        d = min(d, length(c) - PP_R);
    }

    // Ball joint on every node that is not a straight pass-through — the
    // original drew a full-length cylinder for a straight run and a shortened
    // one plus a √2·r ball for a turn or a cap. On the node the tip is
    // currently leaving, swell the ball in with the new run so it does not pop.
    bool straight = (eff == 3u) || (eff == 12u) || (eff == 48u);
    if (!straight && (n.mask != 0u || (n.hasPartial && !n.inward))) {
        float r = PP_JOINT_R;
        if (n.hasPartial && !n.inward) {
            r = mix(PP_R, PP_JOINT_R, smoothstep(0.0, 0.16, n.partialLen));
        }
        d = min(d, length(q) - r);
    }
    return d;
}

static inline float3 ppNormal(float3 q, LerpPipesNode n) {
    const float h = 0.0012;
    float2 k = float2(1.0, -1.0);
    return normalize(k.xyy * ppNode(q + k.xyy * h, n) +
                     k.yyx * ppNode(q + k.yyx * h, n) +
                     k.yxy * ppNode(q + k.yxy * h, n) +
                     k.xxx * ppNode(q + k.xxx * h, n));
}

// ---------------------------------------------------------------------------

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpPipesFrame& F [[buffer(1)]],
                        device const uint* nodes [[buffer(2)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    int3 dim = int3(F.dim.xyz);
    float3 centre = float3(dim) * 0.5;

    // Camera: level, aimed at the middle of the volume, one fixed yaw per
    // cycle. Seed picks the starting angle; each wipe nudges it round.
    // The 0.42 offset only keeps seed 0.5 — the value the snapshot suite uses —
    // off a dead-on axis view; the distribution over seeds is unchanged.
    float yaw = 0.42 + u.seed * TWO_PI + F.cycleIndex * PP_YAW_STEP;
    float3 back = float3(sin(yaw), 0.0, cos(yaw));
    float3 ro = centre + back * PP_VIEWDIST;
    float3 fwd = -back;
    float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(uv.x * right + uv.y * up + PP_FOCAL * fwd);

    // Light and half-vector are fixed in eye space; rotate them into the
    // lattice frame once per pixel (eye +z points back toward the viewer).
    float3 lightDir = PP_L_EYE.x * right + PP_L_EYE.y * up - PP_L_EYE.z * fwd;
    float3 halfDir  = PP_H_EYE.x * right + PP_H_EYE.y * up - PP_H_EYE.z * fwd;

    // Clip the march to the lattice box.
    float3 inv = 1.0 / rd;
    float3 ta = (float3(0.0) - ro) * inv;
    float3 tb = (float3(dim) - ro) * inv;
    float3 tn = min(ta, tb), tf = max(ta, tb);
    float tEnter = max(max(tn.x, tn.y), max(tn.z, 0.0));
    float tLeave = min(tf.x, min(tf.y, tf.z));

    float3 col = float3(0.0);

    if (tLeave > tEnter) {
        float t = tEnter + 1e-3;
        // Half-width of the pixel footprint at unit distance; drives both the
        // hit threshold and the silhouette antialiasing.
        float px = 1.0 / (PP_FOCAL * min(u.resolution.x, u.resolution.y));

        bool hit = false;
        float bestRatio = 1e9;   // closest approach, in pixel footprints
        float bestT = 0.0;
        uint bestRec = 0u;

        for (int i = 0; i < PP_STEPS; ++i) {
            if (t > tLeave) break;
            float3 p = ro + rd * t;

            int3 c = clamp(int3(floor(p)), int3(0), dim - 1);
            uint rec = nodes[(c.z * dim.y + c.y) * dim.x + c.x];

            // Distance along the ray to the far face of this cell.
            float3 bound = float3(c) + select(float3(0.0), float3(1.0), rd > 0.0);
            float3 tv = (bound - p) * inv;
            tv = select(float3(1e9), tv, isfinite(tv));
            float tCell = max(min(tv.x, min(tv.y, tv.z)), 0.0);

            float d = 1e9;
            if (rec != 0u) {
                d = ppNode(p - (float3(c) + 0.5), lerpPipesDecode(rec));
                float cone = max(px * t, 1e-5);
                float ratio = d / cone;
                if (ratio < bestRatio) { bestRatio = ratio; bestT = t; bestRec = rec; }
                if (ratio < 0.5) { hit = true; bestT = t; bestRec = rec; break; }
            }

            t += max(min(d, tCell + 1.5e-3), 1.5e-3);
        }

        // Coverage: 1 inside the silhouette, feathering to 0 about a pixel out.
        float cover = hit ? 1.0 : 1.0 - smoothstep(0.3, 1.2, bestRatio);

        if (cover > 0.0) {
            float3 p = ro + rd * bestT;
            int3 c = clamp(int3(floor(p)), int3(0), dim - 1);
            LerpPipesNode n = lerpPipesDecode(bestRec);
            float3 nrm = ppNormal(p - (float3(c) + 0.5), n);

            // The original's fixed-function lighting, verbatim:
            //   1.1·ka + kd·max(0, N·L) + ks·pow(max(0, N·H), shininess)
            // written straight to the framebuffer with no gamma step.
            uint m = n.color & 15u;
            float ndl = max(dot(nrm, lightDir), 0.0);
            float ndh = max(dot(nrm, halfDir), 0.0);
            float4 ks = PP_KS[m];
            float3 lit = PP_AMBIENT * PP_KA[m] + PP_KD[m] * ndl;
            if (ndl > 0.0) lit += ks.rgb * pow(ndh, ks.w);
            col = lit * cover;
        }
    }

    col *= F.fade;
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
