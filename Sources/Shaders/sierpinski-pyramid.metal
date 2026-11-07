// Fractal Pyramids — original shader written for Lerping@Home (AGPL-3.0, like
// the rest of this project). A slow drone flight through, or orbit around, a
// kaleidoscopic IFS (KIFS) polyhedral fractal: the Sierpinski tetrahedron by
// default, with octahedral, icosahedral and dodecahedral variants and a
// per-iteration rotation that blooms the solids into crystalline forms.
//
// Written from the published math, no code copied:
//   - Knighty's kaleidoscopic IFS (fractalforums.com, 2010): fold space by the
//     mirror planes of a symmetry group, optionally rotate, then scale about a
//     vertex, p -> s·p - (s-1)·c, and repeat; the distance estimate is the
//     final level's distance divided by s^n.
//   - Mikael Christensen (Syntopia), "Distance Estimated 3D Fractals (III):
//     Folding Space" (http://blog.hvidtfeldts.net/), for the tetrahedral fold
//     planes x+y, x+z, y+z and the octahedral abs-and-sort fold.
//   - The icosahedral fold is derived here from the icosahedral reflection
//     group H3, whose 15 mirrors are the coordinate planes and the planes
//     with unit normals (±φ, ±1, ±1/φ)/2 and their cyclic shifts. abs(p), two
//     of those mirrors, abs(p) again and a third mirror take every point into
//     the fundamental chamber (found by a brute-force search over mirror
//     sequences and checked on 200k random points). The chamber's corners are
//     the 5-fold (icosahedron vertex) and 3-fold (dodecahedron vertex) axes,
//     the scaling centres of the icosahedral and dodecahedral forms.
//   - Ray marching with a distance-relative hit threshold, penumbra soft
//     shadows from the closest miss along the shadow ray, and distance-sampled
//     ambient occlusion, as Inigo Quilez explains them (iquilezles.org/articles);
//     over-relaxed sphere tracing with fallback, Keinert et al., "Enhanced
//     Sphere Tracing" (STAG 2014); the SIMD-group shared march is mandelbox's.
//
// Motion. `fly` (on by default) flies a baked route; "Orbit" (fly=false) is
// the original slow orbit, unchanged. A route exists for each preset's form,
// scale and fold rotation (see SP_ROUTES); anything else (a scale slider moved
// more than 0.02 off a preset, say) falls back to the orbit rather than fly a
// path nobody checked.
//
// The routes, one closed loop per preset, all designed around the fractal's
// own structure and repeated by its symmetry about the vertical axis:
//   - Defaults (tetrahedron, s=2): three cycles, one per side face. Glide down
//     a face, slant in through its window (the central hole) into the
//     octahedral room at the centre, through a wall's hole into a corner
//     copy's room, through that room's wall into the next copy down — the
//     same room at a quarter of the size — then out of that room's window on
//     another face, skim it, and pull back over the ridge with the camera
//     turned to watch the pyramid fall away.
//   - Rose Quartz (twisted, s=1.8): the same lap through the central room only
//     (the twist closes the deeper holes for some seeds).
//   - Jade (octahedron): over each face, dipping through its window into the
//     pocket behind it and out again, over the equator and the vertex tips.
//   - Amethyst (icosahedron), Stone and Crystal Bloom (dodecahedra): low over
//     the faces, dipping into each face's pit, with a wide pull-back once per
//     cycle.
// Seed picks where on the loop a session starts and which of the form's
// symmetries about the vertical axis carries it (6 for the tetrahedron, 8 for
// the octahedron, 10 for the icosahedral forms; a twisted tetrahedron has none
// left, as its three-mirror fold is not a full chamber fold, so for Rose Quartz
// the seed's own twist axis is the variation). A loop lasts 5-9 minutes.
//
// How they were made (offline, Python + a C port of spDE; the scripts are not
// part of the repo): waypoints from the fold structure (window centres, room
// centres S_a(0), hole centres, face pits) joined by a grid Dijkstra that
// prefers clearance, smoothed by a fourth-difference elastic band pushed out
// of the solid by the DE gradient, resampled so control points sit closer
// where clearance is small (the camera slows in tight places, ~0.025 units/s,
// to ~0.09 outside), then repaired wherever the spline between control points
// dipped and smoothed again until no turn or change of speed is abrupt. The view direction is baked too, by a virtual
// cinematographer: per control point it scores candidate directions up to
// 172° off the direction of travel on how much structure a 7x5 ray grid sees
// through the fog, penalising a wall in the middle of the frame closer than
// 1.5 clearances and turning away from travel, then smooths the result along
// the loop. So the camera looks along its path inside, and turns to watch the
// solid as it pulls back (a reverse dolly) rather than stare at the empty room.
//
// Verification, dense along every spline (40 samples per control point), at
// scale, scale ± 0.02 and under every symmetry the seed can choose: minimum DE
// at the camera (fractal units; the attractor's bound is 1.77 for the
// tetrahedron, 1.02 for the others):
//   Defaults 0.034 · Jade 0.069 · Amethyst 0.130 · Stone 0.069
//   Rose Quartz 0.037, over 32 seeds' twist axes x 7 fold angles in [0, 0.3]
//     (the preset's drift spans 0.045-0.285) x every depth 7-15
//   Crystal Bloom 0.175, over 24 seeds x 7 angles in [0, 0.3] x depths 6-15
// Untwisted, a shallower solid contains every deeper one, so verifying at the
// shallowest depth the flight ever uses (SpRoute.lodMin) covers them all;
// twisted, it does not, so every depth in the route's range is checked. The
// same pass checked that a fog-weighted 7x5 ray grid always sees structure
// (worst moment 9% of the frame, climbing out over a ridge; typically
// 20-60%) and that the view turns at most ~11°/s.
//
// Detail while flying: the depth grows by one level each time the distance
// shrinks by the fold scale, from the orbit's detail at the orbit's distance,
// less SP_FLY_LOD_BIAS (and a per-route bias for the costlier folds), so the
// finest features stay ~10-20 reference pixels, and never below the verified
// depth. The depth is fractional: the distance estimate blends the solids of
// the two whole depths either side (a geomorph, see spDE), and the shading
// depths blend the same way, so a level grows in over a factor of the fold
// scale in distance instead of popping in all at once at a fixed distance
// from the camera (which made bands of the distant lattice visibly change
// shape as the camera flew). The blend lies between two verified solids, so
// the clearances above hold for it. Fog is measured in the route's local
// clearance, so every depth of the descent fades the same way; the march ends
// where it reaches 95%.
// Lighting close up: no shadow rays (the key rides over the camera's
// shoulder), a lamp just above the camera with distance falloff, one
// occlusion probe deepened by the crevice trap, and a prefiltered normal two
// levels shallower than the hit (see the comment where it is taken: the
// exact one sparkled).
//
// GPU cost, LerpPreview --bench at 3840x2160 on an Apple M5, best of several
// runs interleaved with fractal-multiverse and scaled to its 8.6 ms (the GPU
// was shared). Flying, the mean over ten moments along each loop: Jade 12.4,
// Amethyst 13.6, Defaults 13.7, Rose Quartz 13.8, Crystal Bloom 14.4, Stone
// 14.8 ms; pull-backs cost 4-9, a face filling the screen 19-24. At the
// bench's own moment (t 6-8, seed 0.37): Defaults 13, Jade 15, Crystal Bloom
// 15.5, Amethyst 17, Stone 18.5, Rose Quartz 19.5. Orbit 5.1 (it was 4.7).
// (These predate the prefiltered normal, which added 1.5-5 ms, and the
// geomorph and capped hit tolerance, which are not measured yet: above the
// floor depth each estimate pays one more fold, half a level more than the
// rounded depth did on average, and grazing rays take more steps to settle.)
// That is over the ~12 ms aimed for. Close up nearly every pixel hits the
// fractal, and the floor is the depth the routes were verified at times the
// steps: shading at a fifth of the depth cost only a third less, and half
// precision for the deep levels was slower.
//
// Cost control, because this runs full-screen for hours:
//   - every ray is clipped to the attractor's bounding sphere; rays that miss
//     it never evaluate the fractal.
//   - the distance estimate bails out of the iteration as soon as the point
//     is outside the attractor's bound at that level, which is still a valid
//     lower bound, so empty space costs one or two iterations, not ten.
//   - the hit threshold and the iteration depth are tied to a fixed reference
//     resolution, not the drawable, so a 5K frame costs at most the 1200x750
//     frame times the pixel ratio.
//   - the orbit's shadow and occlusion rays use fewer iterations than primary
//     rays; the flight's march is spMarchFly (see there).
//
// Seed (orbit): the starting bearing, direction, tilt and zoom rhythm. Both
// modes: the axes of the per-iteration rotation (so a twisted form is a
// different crystal every activation).
//
// form: 0 tetrahedron, 1 octahedron, 2 icosahedron, 3 dodecahedron.
//
// lerp-param: form      int   0 3     = 0    "Form"
// lerp-param: scale     float 1.5 3.0 = 2.0  "Fold scale"
// lerp-param: twist     float 0 1     = 0.0  "Fold rotation"
// lerp-param: bloom     float 0 1     = 0.5  "Rotation drift"
// lerp-param: detail    float 0 1     = 0.5  "Detail"
// lerp-param: speed     float 0 3     = 1.0  "Camera speed"
// lerp-param: zoom      float 0 1     = 0.4  "Camera distance (orbit)"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -90 90   = 0 "Tilt"
// lerp-param: magnify  float -1 1 = 0 "Zoom"
// lerp-param: fly       bool          = true "Fly-through"
// lerp-param: metal     float 0 1     = 1.0  "Metalness"
// lerp-param: gloss     float 0 1     = 0.7  "Gloss"
// lerp-param: colorA    color         = (0.95, 0.72, 0.36) "Material"
// lerp-param: colorB    color         = (0.55, 0.22, 0.08) "Crevice tint"
// lerp-param: colorRim  color         = (0.35, 0.55, 0.95) "Rim light"
// lerp-param: colorBack color         = (0.075, 0.068, 0.085) "Background"
//
// lerp-preset: "Orbit"             fly=false
// lerp-preset: "Jade Octahedron"   form=1, scale=2.0, detail=0.4, metal=0.0, gloss=0.8, zoom=0.35
// lerp-preset: "Jade Octahedron"   colorA=(0.20, 0.55, 0.38), colorB=(0.02, 0.12, 0.08)
// lerp-preset: "Jade Octahedron"   colorRim=(0.85, 0.95, 0.75), colorBack=(0.050, 0.075, 0.068)
// lerp-preset: "Amethyst Icosahedron" form=2, scale=2.0, detail=0.4, metal=0.25, gloss=0.95, zoom=0.45
// lerp-preset: "Amethyst Icosahedron" colorA=(0.50, 0.24, 0.80), colorB=(0.10, 0.02, 0.22)
// lerp-preset: "Amethyst Icosahedron" colorRim=(0.95, 0.55, 0.75), colorBack=(0.070, 0.048, 0.095)
// lerp-preset: "Stone Dodecahedron" form=3, scale=2.5, metal=0.0, gloss=0.2, zoom=0.5
// lerp-preset: "Stone Dodecahedron" colorA=(0.62, 0.56, 0.48), colorB=(0.20, 0.16, 0.13)
// lerp-preset: "Stone Dodecahedron" colorRim=(1.0, 0.70, 0.45), colorBack=(0.085, 0.078, 0.070)
// lerp-preset: "Crystal Bloom"     form=3, scale=2.2, twist=animate(0.18, 0.3, period=240), bloom=0.8, detail=0.2
// lerp-preset: "Crystal Bloom"     metal=0.6, gloss=0.95, colorA=(0.45, 0.70, 0.92), colorB=(0.03, 0.10, 0.26)
// lerp-preset: "Crystal Bloom"     colorRim=(1.0, 0.62, 0.38), colorBack=(0.045, 0.058, 0.090)
// lerp-preset: "Rose Quartz Spiral" form=0, scale=1.8, twist=animate(0.18, 0.3, period=220), bloom=0.8, detail=0.2
// lerp-preset: "Rose Quartz Spiral" metal=0.1, gloss=0.85, colorA=(0.95, 0.62, 0.66), colorB=(0.45, 0.12, 0.22)
// lerp-preset: "Rose Quartz Spiral" colorRim=(0.55, 0.80, 1.0), colorBack=(0.080, 0.050, 0.070)

constant float SP_SQRT3 = 1.73205080757;
// Icosahedral mirrors (unit normals (±φ, ±1, ±1/φ)/2 and cyclic shifts).
// SP_N_C bounds the fundamental chamber together with x, y, z >= 0.
constant float3 SP_N_A = float3(0.80901699437, -0.5, -0.30901699437);
constant float3 SP_N_B = float3(0.30901699437, 0.80901699437, -0.5);
constant float3 SP_N_C = float3(0.80901699437, 0.5, -0.30901699437);
// Chamber corners: icosahedron vertex (5-fold) and face (3-fold) axes.
constant float3 SP_C5 = float3(0.0, 0.52573111212, 0.85065080835);
constant float3 SP_C3 = float3(0.35682208977, 0.0, 0.93417235896);
constant float SP_IN_ICO = 0.79465447229;   // inradius / circumradius of icosa and dodeca

constant int   SP_STEPS = 120;               // primary march budget
constant int   SP_SHADOW_STEPS = 16;
constant int   SP_FLY_STEPS = 40;
constant float SP_FOG_END = 24.0;           // flying, the march ends here (in clearance units), where fog is 95%
constant float SP_PIXEL = 1.0 / 1600.0;      // reference pixel footprint, in focal units
constant float SP_PIXEL_5K = 1.0 / 2880.0;   // a 5K drawable's pixel: the flight's normal filter never gets finer
constant float SP_FOCAL = 2.0;
constant float SP_LOD_MIN = 6.0;             // stands in for SpRoute.lodMin when not flying (unused there)
constant float SP_LOD_MAX = 12.0;
constant float SP_LOD_REF = 2.68;            // the orbit's distance, in bounds, at the default zoom
constant float SP_FLY_LOD_BIAS = -3.5;       // flying, the smallest features stay ~10-15 reference px

// --- Fly-through routes (generated; see the header). Each route is a closed,
// uniform Catmull-Rom loop in the fractal's own frame: per control point, the
// position and the local clearance scale, the view direction, and up.
struct SpRoute {
    int   form;
    float scale, scaleTol;   // verified for |scale - this| <= scaleTol
    float angLo, angHi;      // ... and for fold rotations within [angLo, angHi]
    int   start, count;      // control points in SP_PATH
    float rate;              // control points per second at speed 1
    float lodMin;            // the shallowest depth it was verified at (see the header)
    float lodBias;           // extra levels (negative: coarser) for the costlier forms
};
// ROUTES-BEGIN
constant int SP_NROUTES = 6;
constant SpRoute SP_ROUTES[6] = {
    {0, 2.000, 0.020, 0.000, 0.000, 0, 113, 0.3500, 6.0, -1.30},  // tetra2
    {0, 1.800, 0.020, 0.000, 0.300, 113, 101, 0.3500, 7.0, -3.00},  // rose
    {1, 2.000, 0.020, 0.000, 0.000, 214, 163, 0.3500, 6.0, -3.00},  // octa
    {2, 2.000, 0.020, 0.000, 0.000, 377, 184, 0.3500, 6.0, -2.50},  // icosa
    {3, 2.500, 0.020, 0.000, 0.000, 561, 158, 0.3500, 6.0, -1.50},  // stone
    {3, 2.200, 0.020, 0.000, 0.300, 719, 132, 0.3500, 6.0, -2.50},  // bloom
};
constant float4 SP_PATH[2553] = {
    // tetra2
    float4(-0.3342, 0.5093, 0.8546, 0.2430), float4(0.218, -0.281, -0.935, 0), float4(-0.106, 0.945, -0.309, 0),
    float4(-0.3497, 0.4599, 0.6495, 0.2194), float4(0.184, -0.243, -0.952, 0), float4(-0.209, 0.937, -0.280, 0),
    float4(-0.3429, 0.3973, 0.4597, 0.2026), float4(0.095, -0.146, -0.985, 0), float4(-0.325, 0.930, -0.169, 0),
    float4(-0.3207, 0.3357, 0.2830, 0.1858), float4(-0.036, -0.006, -0.999, 0), float4(-0.438, 0.899, 0.010, 0),
    float4(-0.2965, 0.2898, 0.1172, 0.1690), float4(-0.169, 0.149, -0.974, 0), float4(-0.529, 0.820, 0.218, 0),
    float4(-0.2858, 0.2699, -0.0387, 0.1550), float4(-0.256, 0.323, -0.911, 0), float4(-0.591, 0.693, 0.412, 0),
    float4(-0.2991, 0.2795, -0.1820, 0.1407), float4(-0.248, 0.547, -0.799, 0), float4(-0.629, 0.536, 0.563, 0),
    float4(-0.3364, 0.3154, -0.3055, 0.1269), float4(-0.099, 0.811, -0.576, 0), float4(-0.655, 0.383, 0.651, 0),
    float4(-0.3856, 0.3702, -0.3989, 0.1145), float4(0.179, 0.962, -0.205, 0), float4(-0.673, 0.271, 0.688, 0),
    float4(-0.4283, 0.4351, -0.4527, 0.1021), float4(0.442, 0.885, 0.150, 0), float4(-0.674, 0.216, 0.707, 0),
    float4(-0.4482, 0.5022, -0.4635, 0.0897), float4(0.623, 0.705, 0.338, 0), float4(-0.645, 0.219, 0.732, 0),
    float4(-0.4386, 0.5665, -0.4376, 0.0754), float4(0.765, 0.525, 0.373, 0), float4(-0.566, 0.271, 0.778, 0),
    float4(-0.4031, 0.6264, -0.3907, 0.0611), float4(0.885, 0.339, 0.320, 0), float4(-0.434, 0.349, 0.830, 0),
    float4(-0.3510, 0.6824, -0.3428, 0.0522), float4(0.960, 0.106, 0.260, 0), float4(-0.280, 0.421, 0.863, 0),
    float4(-0.2900, 0.7343, -0.3097, 0.0502), float4(0.940, -0.192, 0.280, 0), float4(-0.160, 0.479, 0.863, 0),
    float4(-0.2228, 0.7791, -0.2980, 0.0482), float4(0.763, -0.493, 0.418, 0), float4(-0.104, 0.544, 0.832, 0),
    float4(-0.1477, 0.8113, -0.3033, 0.0463), float4(0.452, -0.654, 0.607, 0), float4(-0.100, 0.639, 0.763, 0),
    float4(-0.0631, 0.8249, -0.3149, 0.0443), float4(0.187, -0.634, 0.750, 0), float4(-0.111, 0.745, 0.658, 0),
    float4(0.0288, 0.8154, -0.3209, 0.0473), float4(0.085, -0.547, 0.833, 0), float4(-0.116, 0.825, 0.553, 0),
    float4(0.1282, 0.7865, -0.3188, 0.0584), float4(0.112, -0.474, 0.873, 0), float4(-0.114, 0.867, 0.486, 0),
    float4(0.2336, 0.7431, -0.3092, 0.0794), float4(0.170, -0.436, 0.884, 0), float4(-0.106, 0.883, 0.456, 0),
    float4(0.3455, 0.6906, -0.2939, 0.1067), float4(0.170, -0.425, 0.889, 0), float4(-0.095, 0.891, 0.444, 0),
    float4(0.4669, 0.6341, -0.2746, 0.1340), float4(0.069, -0.432, 0.899, 0), float4(-0.082, 0.896, 0.436, 0),
    float4(0.6026, 0.5791, -0.2519, 0.1615), float4(-0.130, -0.444, 0.886, 0), float4(-0.067, 0.896, 0.439, 0),
    float4(0.7567, 0.5310, -0.2261, 0.1895), float4(-0.391, -0.443, 0.807, 0), float4(-0.054, 0.886, 0.460, 0),
    float4(0.9330, 0.4939, -0.1973, 0.2145), float4(-0.640, -0.411, 0.649, 0), float4(-0.050, 0.865, 0.499, 0),
    float4(1.1344, 0.4690, -0.1649, 0.2397), float4(-0.813, -0.356, 0.461, 0), float4(-0.055, 0.835, 0.548, 0),
    float4(1.3605, 0.4526, -0.1257, 0.2719), float4(-0.902, -0.303, 0.307, 0), float4(-0.064, 0.798, 0.599, 0),
    float4(1.6023, 0.4351, -0.0743, 0.3081), float4(-0.938, -0.273, 0.213, 0), float4(-0.073, 0.757, 0.649, 0),
    float4(1.8370, 0.4038, -0.0053, 0.3517), float4(-0.948, -0.272, 0.163, 0), float4(-0.084, 0.711, 0.698, 0),
    float4(2.0281, 0.3476, 0.0829, 0.3891), float4(-0.950, -0.286, 0.128, 0), float4(-0.098, 0.660, 0.745, 0),
    float4(2.1365, 0.2625, 0.1848, 0.4118), float4(-0.954, -0.285, 0.089, 0), float4(-0.106, 0.604, 0.790, 0),
    float4(2.1368, 0.1541, 0.2888, 0.4229), float4(-0.968, -0.247, 0.043, 0), float4(-0.102, 0.547, 0.831, 0),
    float4(2.0293, 0.0360, 0.3810, 0.4172), float4(-0.986, -0.169, -0.007, 0), float4(-0.089, 0.487, 0.869, 0),
    float4(1.8387, -0.0766, 0.4510, 0.3948), float4(-0.996, -0.064, -0.064, 0), float4(-0.085, 0.419, 0.904, 0),
    float4(1.6022, -0.1728, 0.4946, 0.3619), float4(-0.990, 0.046, -0.132, 0), float4(-0.108, 0.345, 0.932, 0),
    float4(1.3530, -0.2476, 0.5126, 0.3205), float4(-0.969, 0.142, -0.202, 0), float4(-0.159, 0.266, 0.951, 0),
    float4(1.1115, -0.3012, 0.5078, 0.2802), float4(-0.945, 0.206, -0.255, 0), float4(-0.219, 0.182, 0.959, 0),
    float4(0.8856, -0.3344, 0.4831, 0.2464), float4(-0.938, 0.221, -0.268, 0), float4(-0.255, 0.088, 0.963, 0),
    float4(0.6762, -0.3475, 0.4416, 0.2217), float4(-0.957, 0.180, -0.229, 0), float4(-0.237, -0.023, 0.971, 0),
    float4(0.4820, -0.3413, 0.3891, 0.2055), float4(-0.987, 0.085, -0.135, 0), float4(-0.147, -0.150, 0.978, 0),
    float4(0.3014, -0.3206, 0.3350, 0.1892), float4(-0.999, -0.045, -0.000, 0), float4(0.013, -0.281, 0.959, 0),
    float4(0.1330, -0.2963, 0.2913, 0.1730), float4(-0.972, -0.172, 0.162, 0), float4(0.219, -0.400, 0.890, 0),
    float4(-0.0237, -0.2832, 0.2691, 0.1579), float4(-0.899, -0.250, 0.359, 0), float4(0.437, -0.490, 0.754, 0),
    float4(-0.1667, -0.2931, 0.2752, 0.1416), float4(-0.758, -0.231, 0.610, 0), float4(0.620, -0.547, 0.563, 0),
    float4(-0.2902, -0.3282, 0.3096, 0.1280), float4(-0.491, -0.073, 0.868, 0), float4(0.727, -0.583, 0.362, 0),
    float4(-0.3852, -0.3779, 0.3660, 0.1164), float4(-0.118, 0.187, 0.975, 0), float4(0.771, -0.602, 0.208, 0),
    float4(-0.4426, -0.4231, 0.4346, 0.1047), float4(0.192, 0.427, 0.884, 0), float4(0.792, -0.599, 0.117, 0),
    float4(-0.4580, -0.4461, 0.5053, 0.0930), float4(0.345, 0.607, 0.716, 0), float4(0.821, -0.565, 0.083, 0),
    float4(-0.4364, -0.4386, 0.5719, 0.0791), float4(0.356, 0.751, 0.556, 0), float4(0.868, -0.486, 0.100, 0),
    float4(-0.3919, -0.4038, 0.6322, 0.0651), float4(0.273, 0.872, 0.408, 0), float4(0.922, -0.357, 0.147, 0),
    float4(-0.3443, -0.3511, 0.6872, 0.0575), float4(0.167, 0.963, 0.212, 0), float4(0.958, -0.210, 0.196, 0),
    float4(-0.3102, -0.2889, 0.7376, 0.0546), float4(0.123, 0.985, -0.118, 0), float4(0.968, -0.093, 0.235, 0),
    float4(-0.2972, -0.2201, 0.7810, 0.0524), float4(0.187, 0.806, -0.562, 0), float4(0.960, -0.029, 0.277, 0),
    float4(-0.3017, -0.1433, 0.8120, 0.0501), float4(0.316, 0.431, -0.845, 0), float4(0.938, -0.006, 0.347, 0),
    float4(-0.3139, -0.0564, 0.8253, 0.0478), float4(0.451, 0.147, -0.880, 0), float4(0.890, -0.003, 0.456, 0),
    float4(-0.3241, 0.0401, 0.8177, 0.0516), float4(0.588, 0.054, -0.807, 0), float4(0.809, -0.006, 0.588, 0),
    float4(-0.3266, 0.1437, 0.7898, 0.0619), float4(0.701, 0.091, -0.707, 0), float4(0.710, -0.008, 0.704, 0),
    float4(-0.3203, 0.2522, 0.7453, 0.0850), float4(0.768, 0.148, -0.624, 0), float4(0.631, -0.004, 0.776, 0),
    float4(-0.3064, 0.3664, 0.6898, 0.1131), float4(0.801, 0.142, -0.582, 0), float4(0.587, 0.007, 0.810, 0),
    float4(-0.2856, 0.4902, 0.6298, 0.1411), float4(0.820, 0.042, -0.570, 0), float4(0.570, 0.025, 0.821, 0),
    float4(-0.2589, 0.6285, 0.5724, 0.1692), float4(0.817, -0.149, -0.558, 0), float4(0.569, 0.044, 0.821, 0),
    float4(-0.2270, 0.7858, 0.5232, 0.1991), float4(0.760, -0.399, -0.514, 0), float4(0.581, 0.062, 0.811, 0),
    float4(-0.1912, 0.9656, 0.4858, 0.2252), float4(0.635, -0.641, -0.432, 0), float4(0.610, 0.071, 0.790, 0),
    float4(-0.1513, 1.1703, 0.4597, 0.2515), float4(0.474, -0.812, -0.340, 0), float4(0.653, 0.065, 0.754, 0),
    float4(-0.1049, 1.3987, 0.4396, 0.2833), float4(0.339, -0.899, -0.276, 0), float4(0.703, 0.047, 0.710, 0),
    float4(-0.0468, 1.6405, 0.4160, 0.3214), float4(0.258, -0.932, -0.254, 0), float4(0.750, 0.028, 0.661, 0),
    float4(0.0281, 1.8707, 0.3775, 0.3617), float4(0.218, -0.940, -0.261, 0), float4(0.794, 0.015, 0.608, 0),
    float4(0.1210, 2.0520, 0.3153, 0.3989), float4(0.179, -0.945, -0.272, 0), float4(0.835, -0.000, 0.551, 0),
    float4(0.2264, 2.1458, 0.2275, 0.4218), float4(0.118, -0.958, -0.262, 0), float4(0.874, -0.025, 0.485, 0),
    float4(0.3326, 2.1294, 0.1210, 0.4300), float4(0.035, -0.976, -0.217, 0), float4(0.910, -0.059, 0.411, 0),
    float4(0.4264, 2.0066, 0.0085, 0.4241), float4(-0.057, -0.988, -0.140, 0), float4(0.939, -0.101, 0.329, 0),
    float4(0.4978, 1.8052, -0.0971, 0.4000), float4(-0.148, -0.988, -0.045, 0), float4(0.958, -0.155, 0.240, 0),
    float4(0.5422, 1.5628, -0.1870, 0.3645), float4(-0.234, -0.971, 0.054, 0), float4(0.964, -0.224, 0.143, 0),
    float4(0.5588, 1.3120, -0.2580, 0.3240), float4(-0.302, -0.943, 0.142, 0), float4(0.953, -0.299, 0.042, 0),
    float4(0.5488, 1.0716, -0.3095, 0.2814), float4(-0.336, -0.920, 0.202, 0), float4(0.933, -0.355, -0.066, 0),
    float4(0.5141, 0.8483, -0.3410, 0.2447), float4(-0.324, -0.920, 0.220, 0), float4(0.912, -0.365, -0.184, 0),
    float4(0.4597, 0.6420, -0.3513, 0.2213), float4(-0.262, -0.947, 0.185, 0), float4(0.896, -0.310, -0.317, 0),
    float4(0.3944, 0.4503, -0.3412, 0.2051), float4(-0.151, -0.984, 0.092, 0), float4(0.872, -0.176, -0.457, 0),
    float4(0.3313, 0.2712, -0.3169, 0.1890), float4(0.002, -0.999, -0.047, 0), float4(0.811, 0.029, -0.584, 0),
    float4(0.2842, 0.1032, -0.2912, 0.1728), float4(0.192, -0.964, -0.184, 0), float4(0.693, 0.266, -0.671, 0),
    float4(0.2642, -0.0529, -0.2799, 0.1589), float4(0.424, -0.867, -0.263, 0), float4(0.522, 0.471, -0.711, 0),
    float4(0.2760, -0.1940, -0.2944, 0.1421), float4(0.701, -0.677, -0.225, 0), float4(0.344, 0.596, -0.726, 0),
    float4(0.3172, -0.3133, -0.3344, 0.1294), float4(0.934, -0.355, -0.038, 0), float4(0.214, 0.641, -0.737, 0),
    float4(0.3794, -0.4021, -0.3869, 0.1182), float4(0.973, 0.021, 0.229, 0), float4(0.161, 0.649, -0.744, 0),
    float4(0.4512, -0.4521, -0.4319, 0.1069), float4(0.838, 0.296, 0.458, 0), float4(0.170, 0.656, -0.736, 0),
    float4(0.5225, -0.4606, -0.4520, 0.0926), float4(0.645, 0.438, 0.627, 0), float4(0.223, 0.676, -0.702, 0),
    float4(0.5871, -0.4336, -0.4403, 0.0784), float4(0.447, 0.483, 0.753, 0), float4(0.303, 0.710, -0.636, 0),
    float4(0.6440, -0.3864, -0.4009, 0.0648), float4(0.260, 0.482, 0.837, 0), float4(0.386, 0.742, -0.548, 0),
    float4(0.6947, -0.3387, -0.3430, 0.0593), float4(0.073, 0.497, 0.865, 0), float4(0.459, 0.753, -0.471, 0),
    float4(0.7414, -0.3070, -0.2737, 0.0562), float4(-0.138, 0.574, 0.807, 0), float4(0.525, 0.734, -0.431, 0),
    float4(0.7846, -0.2979, -0.1944, 0.0532), float4(-0.370, 0.694, 0.618, 0), float4(0.593, 0.688, -0.418, 0),
    float4(0.8236, -0.3081, -0.1025, 0.0502), float4(-0.542, 0.767, 0.344, 0), float4(0.655, 0.642, -0.399, 0),
    float4(0.8559, -0.3277, 0.0045, 0.0547), float4(-0.617, 0.774, 0.143, 0), float4(0.694, 0.621, -0.364, 0),
    float4(0.8766, -0.3464, 0.1249, 0.0680), float4(-0.648, 0.758, 0.074, 0), float4(0.704, 0.633, -0.322, 0),
    float4(0.8778, -0.3562, 0.2536, 0.0927), float4(-0.676, 0.733, 0.078, 0), float4(0.691, 0.668, -0.276, 0),
    float4(0.8506, -0.3521, 0.3848, 0.1219), float4(-0.709, 0.702, 0.065, 0), float4(0.674, 0.702, -0.229, 0),
    float4(0.7911, -0.3322, 0.5160, 0.1512), float4(-0.736, 0.677, -0.026, 0), float4(0.669, 0.721, -0.181, 0),
    float4(0.7051, -0.2980, 0.6500, 0.1805), float4(-0.733, 0.646, -0.215, 0), float4(0.677, 0.724, -0.132, 0),
    float4(0.6085, -0.2537, 0.7941, 0.2098), float4(-0.670, 0.572, -0.473, 0), float4(0.681, 0.728, -0.083, 0),
    float4(0.5209, -0.2056, 0.9579, 0.2368), float4(-0.538, 0.435, -0.722, 0), float4(0.665, 0.746, -0.046, 0),
    float4(0.4567, -0.1581, 1.1497, 0.2584), float4(-0.376, 0.276, -0.885, 0), float4(0.633, 0.774, -0.028, 0),
    float4(0.4181, -0.1107, 1.3711, 0.2839), float4(-0.249, 0.158, -0.956, 0), float4(0.593, 0.805, -0.021, 0),
    float4(0.3949, -0.0578, 1.6117, 0.3167), float4(-0.190, 0.106, -0.976, 0), float4(0.551, 0.835, -0.016, 0),
    float4(0.3692, 0.0082, 1.8451, 0.3524), float4(-0.192, 0.102, -0.976, 0), float4(0.506, 0.863, -0.009, 0),
    float4(0.3248, 0.0915, 2.0318, 0.3847), float4(-0.221, 0.106, -0.970, 0), float4(0.457, 0.889, -0.007, 0),
    float4(0.2535, 0.1890, 2.1317, 0.4055), float4(-0.235, 0.087, -0.968, 0), float4(0.403, 0.915, -0.016, 0),
    float4(0.1581, 0.2908, 2.1209, 0.4111), float4(-0.209, 0.040, -0.977, 0), float4(0.344, 0.938, -0.035, 0),
    float4(0.0499, 0.3843, 2.0027, 0.4065), float4(-0.141, -0.020, -0.990, 0), float4(0.279, 0.958, -0.059, 0),
    float4(-0.0577, 0.4595, 1.8046, 0.3865), float4(-0.047, -0.084, -0.995, 0), float4(0.210, 0.973, -0.092, 0),
    float4(-0.1544, 0.5109, 1.5649, 0.3547), float4(0.052, -0.149, -0.987, 0), float4(0.136, 0.981, -0.141, 0),
    float4(-0.2345, 0.5368, 1.3159, 0.3173), float4(0.139, -0.214, -0.967, 0), float4(0.060, 0.976, -0.207, 0),
    float4(-0.2952, 0.5361, 1.0769, 0.2780), float4(0.199, -0.265, -0.943, 0), float4(-0.019, 0.962, -0.274, 0),
    // rose
    float4(-0.3508, 0.5372, 0.8427, 0.1261), float4(0.428, -0.500, -0.753, 0), float4(0.902, 0.185, 0.390, 0),
    float4(-0.3545, 0.5106, 0.7342, 0.1187), float4(0.495, -0.542, -0.679, 0), float4(0.856, 0.170, 0.488, 0),
    float4(-0.3555, 0.4790, 0.6410, 0.1093), float4(0.529, -0.569, -0.630, 0), float4(0.816, 0.137, 0.562, 0),
    float4(-0.3560, 0.4449, 0.5580, 0.1034), float4(0.529, -0.584, -0.616, 0), float4(0.792, 0.079, 0.606, 0),
    float4(-0.3556, 0.4096, 0.4817, 0.0999), float4(0.513, -0.584, -0.630, 0), float4(0.777, 0.003, 0.629, 0),
    float4(-0.3512, 0.3726, 0.4104, 0.0975), float4(0.509, -0.559, -0.654, 0), float4(0.757, -0.072, 0.650, 0),
    float4(-0.3383, 0.3325, 0.3437, 0.0952), float4(0.538, -0.505, -0.675, 0), float4(0.722, -0.138, 0.678, 0),
    float4(-0.3128, 0.2894, 0.2812, 0.0928), float4(0.596, -0.416, -0.687, 0), float4(0.678, -0.198, 0.708, 0),
    float4(-0.2732, 0.2457, 0.2216, 0.0909), float4(0.664, -0.289, -0.690, 0), float4(0.638, -0.264, 0.724, 0),
    float4(-0.2209, 0.2063, 0.1624, 0.0924), float4(0.727, -0.112, -0.678, 0), float4(0.614, -0.337, 0.714, 0),
    float4(-0.1593, 0.1766, 0.1012, 0.0985), float4(0.774, 0.124, -0.621, 0), float4(0.609, -0.412, 0.678, 0),
    float4(-0.0924, 0.1602, 0.0367, 0.1019), float4(0.784, 0.407, -0.469, 0), float4(0.621, -0.480, 0.620, 0),
    float4(-0.0229, 0.1586, -0.0305, 0.1026), float4(0.714, 0.676, -0.182, 0), float4(0.645, -0.534, 0.547, 0),
    float4(0.0480, 0.1708, -0.0978, 0.1023), float4(0.539, 0.816, 0.208, 0), float4(0.680, -0.567, 0.464, 0),
    float4(0.1209, 0.1947, -0.1611, 0.1020), float4(0.313, 0.764, 0.564, 0), float4(0.722, -0.577, 0.382, 0),
    float4(0.1970, 0.2281, -0.2157, 0.1017), float4(0.125, 0.594, 0.795, 0), float4(0.762, -0.570, 0.307, 0),
    float4(0.2774, 0.2686, -0.2569, 0.0999), float4(-0.000, 0.404, 0.915, 0), float4(0.799, -0.550, 0.243, 0),
    float4(0.3629, 0.3134, -0.2812, 0.0935), float4(-0.092, 0.229, 0.969, 0), float4(0.831, -0.519, 0.201, 0),
    float4(0.4539, 0.3588, -0.2877, 0.0898), float4(-0.179, 0.071, 0.981, 0), float4(0.856, -0.481, 0.191, 0),
    float4(0.5516, 0.4007, -0.2784, 0.0888), float4(-0.277, -0.065, 0.959, 0), float4(0.870, -0.440, 0.222, 0),
    float4(0.6584, 0.4362, -0.2580, 0.0925), float4(-0.393, -0.165, 0.905, 0), float4(0.864, -0.404, 0.301, 0),
    float4(0.7794, 0.4639, -0.2318, 0.1043), float4(-0.524, -0.217, 0.824, 0), float4(0.824, -0.376, 0.425, 0),
    float4(0.9222, 0.4839, -0.2028, 0.1259), float4(-0.659, -0.230, 0.716, 0), float4(0.742, -0.352, 0.570, 0),
    float4(1.0942, 0.4960, -0.1702, 0.1506), float4(-0.777, -0.223, 0.589, 0), float4(0.628, -0.326, 0.706, 0),
    float4(1.2972, 0.4968, -0.1290, 0.1864), float4(-0.863, -0.212, 0.458, 0), float4(0.503, -0.293, 0.813, 0),
    float4(1.5192, 0.4789, -0.0720, 0.2432), float4(-0.917, -0.206, 0.343, 0), float4(0.388, -0.254, 0.886, 0),
    float4(1.7310, 0.4333, 0.0060, 0.2766), float4(-0.946, -0.207, 0.247, 0), float4(0.290, -0.211, 0.933, 0),
    float4(1.8914, 0.3544, 0.1039, 0.2943), float4(-0.964, -0.209, 0.166, 0), float4(0.203, -0.169, 0.964, 0),
    float4(1.9625, 0.2456, 0.2133, 0.2941), float4(-0.976, -0.200, 0.091, 0), float4(0.118, -0.131, 0.984, 0),
    float4(1.9270, 0.1192, 0.3203, 0.2772), float4(-0.986, -0.168, 0.016, 0), float4(0.033, -0.098, 0.995, 0),
    float4(1.7961, -0.0075, 0.4116, 0.2555), float4(-0.992, -0.111, -0.061, 0), float4(-0.053, -0.070, 0.996, 0),
    float4(1.6038, -0.1194, 0.4793, 0.2227), float4(-0.989, -0.029, -0.142, 0), float4(-0.141, -0.048, 0.989, 0),
    float4(1.3899, -0.2082, 0.5221, 0.1690), float4(-0.972, 0.069, -0.226, 0), float4(-0.228, -0.031, 0.973, 0),
    float4(1.1849, -0.2731, 0.5429, 0.1386), float4(-0.936, 0.171, -0.307, 0), float4(-0.315, -0.019, 0.949, 0),
    float4(1.0030, -0.3179, 0.5457, 0.1203), float4(-0.887, 0.261, -0.380, 0), float4(-0.396, -0.013, 0.918, 0),
    float4(0.8451, -0.3474, 0.5330, 0.1117), float4(-0.838, 0.332, -0.433, 0), float4(-0.463, -0.015, 0.886, 0),
    float4(0.7057, -0.3645, 0.5056, 0.1101), float4(-0.801, 0.393, -0.451, 0), float4(-0.503, -0.032, 0.864, 0),
    float4(0.5794, -0.3695, 0.4637, 0.1139), float4(-0.780, 0.461, -0.423, 0), float4(-0.507, -0.070, 0.859, 0),
    float4(0.4636, -0.3599, 0.4073, 0.1222), float4(-0.769, 0.537, -0.347, 0), float4(-0.482, -0.129, 0.867, 0),
    float4(0.3581, -0.3321, 0.3374, 0.1304), float4(-0.757, 0.607, -0.242, 0), float4(-0.440, -0.200, 0.876, 0),
    float4(0.2632, -0.2840, 0.2569, 0.1286), float4(-0.747, 0.652, -0.132, 0), float4(-0.394, -0.274, 0.877, 0),
    float4(0.1781, -0.2166, 0.1726, 0.1218), float4(-0.742, 0.670, -0.031, 0), float4(-0.349, -0.346, 0.871, 0),
    float4(0.0999, -0.1351, 0.0953, 0.1139), float4(-0.736, 0.673, 0.069, 0), float4(-0.302, -0.417, 0.857, 0),
    float4(0.0255, -0.0474, 0.0382, 0.1060), float4(-0.705, 0.686, 0.181, 0), float4(-0.257, -0.485, 0.836, 0),
    float4(-0.0469, 0.0383, 0.0122, 0.0943), float4(-0.604, 0.730, 0.320, 0), float4(-0.222, -0.540, 0.812, 0),
    float4(-0.1161, 0.1160, 0.0219, 0.0781), float4(-0.367, 0.798, 0.479, 0), float4(-0.205, -0.571, 0.795, 0),
    float4(-0.1785, 0.1837, 0.0634, 0.0621), float4(0.050, 0.803, 0.593, 0), float4(-0.202, -0.573, 0.794, 0),
    float4(-0.2298, 0.2431, 0.1264, 0.0560), float4(0.513, 0.646, 0.565, 0), float4(-0.199, -0.551, 0.810, 0),
    float4(-0.2670, 0.2986, 0.1983, 0.0550), float4(0.809, 0.400, 0.430, 0), float4(-0.187, -0.518, 0.834, 0),
    float4(-0.2892, 0.3549, 0.2689, 0.0598), float4(0.940, 0.182, 0.289, 0), float4(-0.171, -0.482, 0.859, 0),
    float4(-0.2973, 0.4166, 0.3317, 0.0645), float4(0.985, 0.006, 0.171, 0), float4(-0.150, -0.444, 0.883, 0),
    float4(-0.2935, 0.4868, 0.3838, 0.0693), float4(0.986, -0.152, 0.067, 0), float4(-0.124, -0.404, 0.906, 0),
    float4(-0.2801, 0.5683, 0.4245, 0.0741), float4(0.950, -0.310, -0.026, 0), float4(-0.093, -0.363, 0.927, 0),
    float4(-0.2592, 0.6644, 0.4540, 0.0836), float4(0.878, -0.467, -0.102, 0), float4(-0.062, -0.321, 0.945, 0),
    float4(-0.2326, 0.7794, 0.4733, 0.1002), float4(0.776, -0.612, -0.156, 0), float4(-0.027, -0.280, 0.960, 0),
    float4(-0.2008, 0.9195, 0.4839, 0.1213), float4(0.653, -0.732, -0.195, 0), float4(0.016, -0.244, 0.970, 0),
    float4(-0.1622, 1.0904, 0.4864, 0.1419), float4(0.525, -0.822, -0.219, 0), float4(0.067, -0.217, 0.974, 0),
    float4(-0.1132, 1.2925, 0.4782, 0.1740), float4(0.410, -0.883, -0.229, 0), float4(0.123, -0.196, 0.973, 0),
    float4(-0.0487, 1.5140, 0.4528, 0.2282), float4(0.320, -0.919, -0.230, 0), float4(0.180, -0.179, 0.967, 0),
    float4(0.0348, 1.7266, 0.4014, 0.2662), float4(0.253, -0.939, -0.232, 0), float4(0.241, -0.171, 0.955, 0),
    float4(0.1360, 1.8905, 0.3181, 0.2883), float4(0.197, -0.953, -0.230, 0), float4(0.301, -0.165, 0.939, 0),
    float4(0.2467, 1.9679, 0.2053, 0.2919), float4(0.138, -0.968, -0.210, 0), float4(0.359, -0.148, 0.922, 0),
    float4(0.3543, 1.9406, 0.0748, 0.2834), float4(0.073, -0.985, -0.158, 0), float4(0.412, -0.114, 0.904, 0),
    float4(0.4456, 1.8184, -0.0554, 0.2662), float4(0.004, -0.997, -0.078, 0), float4(0.463, -0.067, 0.884, 0),
    float4(0.5125, 1.6343, -0.1682, 0.2358), float4(-0.071, -0.997, 0.016, 0), float4(0.512, -0.022, 0.859, 0),
    float4(0.5530, 1.4286, -0.2531, 0.1826), float4(-0.157, -0.981, 0.118, 0), float4(0.557, 0.011, 0.830, 0),
    float4(0.5701, 1.2332, -0.3082, 0.1456), float4(-0.254, -0.942, 0.221, 0), float4(0.598, 0.027, 0.801, 0),
    float4(0.5689, 1.0639, -0.3381, 0.1199), float4(-0.352, -0.882, 0.313, 0), float4(0.632, 0.022, 0.774, 0),
    float4(0.5539, 0.9227, -0.3506, 0.1055), float4(-0.441, -0.813, 0.381, 0), float4(0.657, -0.003, 0.754, 0),
    float4(0.5288, 0.8041, -0.3538, 0.0987), float4(-0.511, -0.750, 0.421, 0), float4(0.673, -0.044, 0.739, 0),
    float4(0.4966, 0.7010, -0.3540, 0.0964), float4(-0.556, -0.704, 0.442, 0), float4(0.685, -0.087, 0.723, 0),
    float4(0.4602, 0.6073, -0.3547, 0.0958), float4(-0.571, -0.677, 0.465, 0), float4(0.707, -0.117, 0.698, 0),
    float4(0.4215, 0.5188, -0.3555, 0.0973), float4(-0.551, -0.664, 0.506, 0), float4(0.747, -0.122, 0.654, 0),
    float4(0.3815, 0.4331, -0.3524, 0.1005), float4(-0.497, -0.654, 0.570, 0), float4(0.804, -0.100, 0.586, 0),
    float4(0.3404, 0.3494, -0.3390, 0.1055), float4(-0.418, -0.639, 0.645, 0), float4(0.865, -0.063, 0.499, 0),
    float4(0.2989, 0.2680, -0.3097, 0.1105), float4(-0.330, -0.611, 0.719, 0), float4(0.915, -0.021, 0.402, 0),
    float4(0.2589, 0.1893, -0.2614, 0.1155), float4(-0.246, -0.564, 0.789, 0), float4(0.952, 0.014, 0.307, 0),
    float4(0.2244, 0.1133, -0.1946, 0.1245), float4(-0.170, -0.486, 0.857, 0), float4(0.975, 0.043, 0.218, 0),
    float4(0.1999, 0.0396, -0.1131, 0.1290), float4(-0.105, -0.364, 0.925, 0), float4(0.988, 0.065, 0.138, 0),
    float4(0.1895, -0.0322, -0.0218, 0.1283), float4(-0.055, -0.181, 0.982, 0), float4(0.994, 0.081, 0.070, 0),
    float4(0.1962, -0.1016, 0.0744, 0.1257), float4(-0.022, 0.071, 0.997, 0), float4(0.995, 0.095, 0.015, 0),
    float4(0.2205, -0.1662, 0.1720, 0.1213), float4(-0.011, 0.374, 0.927, 0), float4(0.993, 0.109, -0.033, 0),
    float4(0.2606, -0.2216, 0.2694, 0.1169), float4(-0.027, 0.668, 0.744, 0), float4(0.989, 0.125, -0.076, 0),
    float4(0.3114, -0.2624, 0.3672, 0.1125), float4(-0.078, 0.879, 0.471, 0), float4(0.983, 0.147, -0.112, 0),
    float4(0.3655, -0.2837, 0.4676, 0.1041), float4(-0.155, 0.973, 0.171, 0), float4(0.973, 0.180, -0.141, 0),
    float4(0.4147, -0.2839, 0.5743, 0.1001), float4(-0.238, 0.966, -0.106, 0), float4(0.961, 0.218, -0.169, 0),
    float4(0.4526, -0.2652, 0.6920, 0.0998), float4(-0.304, 0.886, -0.349, 0), float4(0.949, 0.248, -0.196, 0),
    float4(0.4768, -0.2329, 0.8268, 0.1014), float4(-0.346, 0.754, -0.559, 0), float4(0.938, 0.268, -0.219, 0),
    float4(0.4878, -0.1919, 0.9856, 0.1144), float4(-0.359, 0.583, -0.729, 0), float4(0.931, 0.278, -0.236, 0),
    float4(0.4868, -0.1438, 1.1736, 0.1424), float4(-0.345, 0.407, -0.846, 0), float4(0.928, 0.281, -0.243, 0),
    float4(0.4712, -0.0858, 1.3876, 0.1852), float4(-0.315, 0.262, -0.912, 0), float4(0.930, 0.278, -0.241, 0),
    float4(0.4344, -0.0127, 1.6094, 0.2296), float4(-0.285, 0.163, -0.945, 0), float4(0.933, 0.274, -0.234, 0),
    float4(0.3690, 0.0784, 1.8049, 0.2588), float4(-0.259, 0.098, -0.961, 0), float4(0.937, 0.268, -0.225, 0),
    float4(0.2724, 0.1841, 1.9331, 0.2708), float4(-0.230, 0.046, -0.972, 0), float4(0.942, 0.262, -0.210, 0),
    float4(0.1512, 0.2940, 1.9630, 0.2773), float4(-0.189, -0.005, -0.982, 0), float4(0.950, 0.254, -0.184, 0),
    float4(0.0207, 0.3944, 1.8882, 0.2724), float4(-0.128, -0.061, -0.990, 0), float4(0.960, 0.245, -0.139, 0),
    float4(-0.1010, 0.4739, 1.7303, 0.2526), float4(-0.047, -0.123, -0.991, 0), float4(0.969, 0.236, -0.076, 0),
    float4(-0.2002, 0.5272, 1.5280, 0.2144), float4(0.046, -0.194, -0.980, 0), float4(0.974, 0.226, 0.002, 0),
    float4(-0.2711, 0.5554, 1.3200, 0.1722), float4(0.146, -0.272, -0.951, 0), float4(0.973, 0.215, 0.088, 0),
    float4(-0.3156, 0.5632, 1.1318, 0.1441), float4(0.246, -0.357, -0.901, 0), float4(0.962, 0.204, 0.182, 0),
    float4(-0.3399, 0.5558, 0.9732, 0.1332), float4(0.342, -0.436, -0.832, 0), float4(0.939, 0.195, 0.284, 0),
    // octa
    float4(0.5750, 1.0064, 0.2829, 0.1816), float4(-0.466, -0.862, -0.197, 0), float4(0.624, -0.163, -0.764, 0),
    float4(0.5331, 0.8257, 0.2775, 0.1343), float4(-0.481, -0.843, -0.242, 0), float4(0.635, -0.144, -0.758, 0),
    float4(0.4719, 0.6586, 0.2702, 0.1087), float4(-0.472, -0.833, -0.289, 0), float4(0.654, -0.111, -0.748, 0),
    float4(0.4113, 0.5050, 0.2733, 0.0939), float4(-0.458, -0.819, -0.346, 0), float4(0.675, -0.067, -0.734, 0),
    float4(0.3760, 0.3693, 0.3012, 0.0888), float4(-0.460, -0.782, -0.421, 0), float4(0.695, -0.022, -0.719, 0),
    float4(0.3841, 0.2598, 0.3647, 0.0837), float4(-0.491, -0.705, -0.513, 0), float4(0.709, 0.019, -0.705, 0),
    float4(0.4362, 0.1864, 0.4657, 0.0785), float4(-0.543, -0.584, -0.604, 0), float4(0.717, 0.053, -0.695, 0),
    float4(0.5125, 0.1578, 0.5957, 0.0857), float4(-0.589, -0.446, -0.674, 0), float4(0.722, 0.086, -0.687, 0),
    float4(0.5810, 0.1794, 0.7383, 0.1081), float4(-0.607, -0.339, -0.719, 0), float4(0.729, 0.122, -0.673, 0),
    float4(0.6112, 0.2511, 0.8738, 0.1429), float4(-0.592, -0.297, -0.750, 0), float4(0.742, 0.163, -0.650, 0),
    float4(0.5855, 0.3664, 0.9844, 0.1944), float4(-0.541, -0.321, -0.777, 0), float4(0.760, 0.209, -0.615, 0),
    float4(0.5022, 0.5121, 1.0561, 0.2575), float4(-0.453, -0.392, -0.801, 0), float4(0.782, 0.258, -0.568, 0),
    float4(0.3711, 0.6708, 1.0807, 0.3129), float4(-0.334, -0.482, -0.810, 0), float4(0.800, 0.309, -0.514, 0),
    float4(0.2076, 0.8230, 1.0549, 0.3511), float4(-0.204, -0.573, -0.794, 0), float4(0.811, 0.354, -0.465, 0),
    float4(0.0270, 0.9507, 0.9803, 0.3699), float4(-0.078, -0.657, -0.750, 0), float4(0.816, 0.390, -0.426, 0),
    float4(-0.1556, 1.0397, 0.8641, 0.3574), float4(0.047, -0.727, -0.685, 0), float4(0.818, 0.422, -0.391, 0),
    float4(-0.3250, 1.0803, 0.7190, 0.3230), float4(0.177, -0.779, -0.602, 0), float4(0.817, 0.458, -0.352, 0),
    float4(-0.4645, 1.0684, 0.5619, 0.2719), float4(0.308, -0.808, -0.502, 0), float4(0.811, 0.499, -0.307, 0),
    float4(-0.5578, 1.0055, 0.4123, 0.2092), float4(0.420, -0.814, -0.400, 0), float4(0.800, 0.540, -0.259, 0),
    float4(-0.5936, 0.8992, 0.2889, 0.1543), float4(0.497, -0.806, -0.322, 0), float4(0.790, 0.574, -0.215, 0),
    float4(-0.5724, 0.7631, 0.2063, 0.1165), float4(0.533, -0.795, -0.289, 0), float4(0.786, 0.592, -0.177, 0),
    float4(-0.5111, 0.6165, 0.1734, 0.0909), float4(0.537, -0.785, -0.308, 0), float4(0.790, 0.596, -0.144, 0),
    float4(-0.4399, 0.4806, 0.1923, 0.0816), float4(0.524, -0.766, -0.372, 0), float4(0.793, 0.598, -0.113, 0),
    float4(-0.3912, 0.3740, 0.2588, 0.0865), float4(0.514, -0.720, -0.466, 0), float4(0.787, 0.612, -0.077, 0),
    float4(-0.3853, 0.3064, 0.3645, 0.0924), float4(0.515, -0.640, -0.571, 0), float4(0.766, 0.642, -0.030, 0),
    float4(-0.4217, 0.2764, 0.4992, 0.0983), float4(0.520, -0.535, -0.667, 0), float4(0.733, 0.680, 0.026, 0),
    float4(-0.4822, 0.2726, 0.6536, 0.1135), float4(0.517, -0.430, -0.741, 0), float4(0.699, 0.711, 0.075, 0),
    float4(-0.5415, 0.2796, 0.8221, 0.1392), float4(0.502, -0.349, -0.792, 0), float4(0.675, 0.730, 0.106, 0),
    float4(-0.5797, 0.2843, 1.0042, 0.1863), float4(0.480, -0.296, -0.826, 0), float4(0.661, 0.741, 0.118, 0),
    float4(-0.5868, 0.2792, 1.2023, 0.2513), float4(0.459, -0.258, -0.850, 0), float4(0.650, 0.750, 0.122, 0),
    float4(-0.5597, 0.2610, 1.4171, 0.3198), float4(0.443, -0.224, -0.868, 0), float4(0.636, 0.761, 0.128, 0),
    float4(-0.4970, 0.2284, 1.6406, 0.4101), float4(0.429, -0.194, -0.882, 0), float4(0.622, 0.771, 0.133, 0),
    float4(-0.3968, 0.1806, 1.8515, 0.4931), float4(0.405, -0.174, -0.898, 0), float4(0.613, 0.780, 0.125, 0),
    float4(-0.2605, 0.1177, 2.0172, 0.5447), float4(0.354, -0.166, -0.920, 0), float4(0.613, 0.784, 0.095, 0),
    float4(-0.0971, 0.0435, 2.1045, 0.5795), float4(0.270, -0.161, -0.949, 0), float4(0.619, 0.784, 0.043, 0),
    float4(0.0760, -0.0349, 2.0933, 0.5748), float4(0.153, -0.147, -0.977, 0), float4(0.625, 0.781, -0.019, 0),
    float4(0.2388, -0.1090, 1.9866, 0.5415), float4(0.015, -0.114, -0.993, 0), float4(0.627, 0.775, -0.079, 0),
    float4(0.3753, -0.1721, 1.8087, 0.4809), float4(-0.123, -0.064, -0.990, 0), float4(0.626, 0.769, -0.127, 0),
    float4(0.4781, -0.2213, 1.5934, 0.3918), float4(-0.249, -0.000, -0.969, 0), float4(0.625, 0.764, -0.161, 0),
    float4(0.5457, -0.2561, 1.3708, 0.3099), float4(-0.354, 0.068, -0.933, 0), float4(0.626, 0.758, -0.183, 0),
    float4(0.5784, -0.2769, 1.1588, 0.2471), float4(-0.434, 0.132, -0.891, 0), float4(0.629, 0.752, -0.195, 0),
    float4(0.5754, -0.2842, 0.9630, 0.1867), float4(-0.485, 0.187, -0.854, 0), float4(0.636, 0.746, -0.199, 0),
    float4(0.5388, -0.2811, 0.7825, 0.1444), float4(-0.506, 0.233, -0.831, 0), float4(0.649, 0.737, -0.188, 0),
    float4(0.4799, -0.2762, 0.6161, 0.1129), float4(-0.500, 0.283, -0.818, 0), float4(0.672, 0.723, -0.161, 0),
    float4(0.4210, -0.2839, 0.4657, 0.1002), float4(-0.483, 0.353, -0.801, 0), float4(0.703, 0.702, -0.115, 0),
    float4(0.3889, -0.3200, 0.3376, 0.0932), float4(-0.476, 0.456, -0.752, 0), float4(0.736, 0.674, -0.057, 0),
    float4(0.4010, -0.3952, 0.2408, 0.0864), float4(-0.491, 0.581, -0.648, 0), float4(0.765, 0.645, -0.001, 0),
    float4(0.4543, -0.5090, 0.1850, 0.0825), float4(-0.524, 0.689, -0.501, 0), float4(0.780, 0.624, 0.043, 0),
    float4(0.5253, -0.6492, 0.1776, 0.0920), float4(-0.554, 0.747, -0.366, 0), float4(0.782, 0.618, 0.077, 0),
    float4(0.5802, -0.7958, 0.2216, 0.1224), float4(-0.567, 0.769, -0.296, 0), float4(0.780, 0.617, 0.108, 0),
    float4(0.5903, -0.9271, 0.3138, 0.1641), float4(-0.553, 0.779, -0.295, 0), float4(0.780, 0.609, 0.143, 0),
    float4(0.5421, -1.0248, 0.4441, 0.2226), float4(-0.507, 0.791, -0.343, 0), float4(0.790, 0.585, 0.184, 0),
    float4(0.4379, -1.0768, 0.5967, 0.2841), float4(-0.425, 0.804, -0.416, 0), float4(0.805, 0.546, 0.231, 0),
    float4(0.2907, -1.0770, 0.7528, 0.3308), float4(-0.314, 0.803, -0.507, 0), float4(0.820, 0.498, 0.281, 0),
    float4(0.1172, -1.0256, 0.8934, 0.3593), float4(-0.183, 0.775, -0.605, 0), float4(0.830, 0.452, 0.327, 0),
    float4(-0.0662, -0.9277, 1.0020, 0.3650), float4(-0.046, 0.717, -0.695, 0), float4(0.834, 0.411, 0.368, 0),
    float4(-0.2440, -0.7941, 1.0668, 0.3362), float4(0.091, 0.638, -0.765, 0), float4(0.835, 0.369, 0.408, 0),
    float4(-0.4003, -0.6401, 1.0810, 0.2952), float4(0.229, 0.538, -0.811, 0), float4(0.832, 0.324, 0.449, 0),
    float4(-0.5186, -0.4843, 1.0434, 0.2374), float4(0.354, 0.424, -0.834, 0), float4(0.826, 0.277, 0.491, 0),
    float4(-0.5846, -0.3456, 0.9584, 0.1767), float4(0.447, 0.318, -0.836, 0), float4(0.818, 0.233, 0.526, 0),
    float4(-0.5917, -0.2409, 0.8363, 0.1307), float4(0.499, 0.253, -0.829, 0), float4(0.813, 0.192, 0.549, 0),
    float4(-0.5476, -0.1817, 0.6933, 0.1030), float4(0.517, 0.246, -0.820, 0), float4(0.814, 0.156, 0.560, 0),
    float4(-0.4757, -0.1734, 0.5496, 0.0885), float4(0.515, 0.288, -0.807, 0), float4(0.816, 0.121, 0.565, 0),
    float4(-0.4084, -0.2152, 0.4255, 0.0875), float4(0.513, 0.366, -0.776, 0), float4(0.813, 0.084, 0.577, 0),
    float4(-0.3742, -0.3010, 0.3359, 0.0923), float4(0.520, 0.467, -0.716, 0), float4(0.796, 0.041, 0.604, 0),
    float4(-0.3855, -0.4213, 0.2857, 0.0972), float4(0.532, 0.578, -0.619, 0), float4(0.764, -0.012, 0.645, 0),
    float4(-0.4339, -0.5657, 0.2689, 0.1040), float4(0.535, 0.680, -0.502, 0), float4(0.727, -0.067, 0.684, 0),
    float4(-0.4973, -0.7261, 0.2718, 0.1256), float4(0.521, 0.756, -0.396, 0), float4(0.696, -0.107, 0.711, 0),
    float4(-0.5516, -0.8989, 0.2794, 0.1585), float4(0.496, 0.805, -0.325, 0), float4(0.677, -0.124, 0.725, 0),
    float4(-0.5805, -1.0850, 0.2809, 0.2133), float4(0.469, 0.836, -0.284, 0), float4(0.668, -0.125, 0.733, 0),
    float4(-0.5764, -1.2873, 0.2707, 0.2834), float4(0.447, 0.857, -0.258, 0), float4(0.661, -0.121, 0.741, 0),
    float4(-0.5368, -1.5044, 0.2467, 0.3597), float4(0.431, 0.872, -0.234, 0), float4(0.651, -0.120, 0.750, 0),
    float4(-0.4592, -1.7245, 0.2078, 0.4587), float4(0.415, 0.885, -0.212, 0), float4(0.640, -0.119, 0.759, 0),
    float4(-0.3424, -1.9226, 0.1533, 0.5366), float4(0.384, 0.904, -0.189, 0), float4(0.632, -0.108, 0.767, 0),
    float4(-0.1905, -2.0653, 0.0848, 0.5777), float4(0.321, 0.933, -0.163, 0), float4(0.630, -0.082, 0.772, 0),
    float4(-0.0162, -2.1227, 0.0073, 0.6016), float4(0.220, 0.967, -0.128, 0), float4(0.632, -0.041, 0.774, 0),
    float4(0.1601, -2.0815, -0.0711, 0.5825), float4(0.089, 0.993, -0.082, 0), float4(0.633, 0.007, 0.774, 0),
    float4(0.3176, -1.9513, -0.1419, 0.5365), float4(-0.049, 0.998, -0.027, 0), float4(0.631, 0.052, 0.774, 0),
    float4(0.4415, -1.7598, -0.1993, 0.4638), float4(-0.180, 0.983, 0.031, 0), float4(0.628, 0.090, 0.773, 0),
    float4(0.5261, -1.5409, -0.2411, 0.3648), float4(-0.293, 0.952, 0.087, 0), float4(0.625, 0.122, 0.771, 0),
    float4(0.5717, -1.3213, -0.2674, 0.2849), float4(-0.384, 0.913, 0.138, 0), float4(0.623, 0.146, 0.769, 0),
    float4(0.5805, -1.1149, -0.2793, 0.2230), float4(-0.448, 0.875, 0.184, 0), float4(0.624, 0.159, 0.765, 0),
    float4(0.5557, -0.9243, -0.2787, 0.1668), float4(-0.483, 0.846, 0.227, 0), float4(0.632, 0.157, 0.759, 0),
    float4(0.5044, -0.7471, -0.2714, 0.1318), float4(-0.494, 0.825, 0.274, 0), float4(0.648, 0.140, 0.749, 0),
    float4(0.4425, -0.5825, -0.2685, 0.1084), float4(-0.496, 0.801, 0.335, 0), float4(0.671, 0.108, 0.734, 0),
    float4(0.3929, -0.4345, -0.2853, 0.1006), float4(-0.500, 0.758, 0.419, 0), float4(0.697, 0.066, 0.714, 0),
    float4(0.3776, -0.3123, -0.3360, 0.0965), float4(-0.518, 0.677, 0.523, 0), float4(0.723, 0.019, 0.690, 0),
    float4(0.4062, -0.2267, -0.4277, 0.0923), float4(-0.546, 0.554, 0.628, 0), float4(0.744, -0.024, 0.668, 0),
    float4(0.4685, -0.1873, -0.5557, 0.0937), float4(-0.574, 0.419, 0.704, 0), float4(0.756, -0.061, 0.652, 0),
    float4(0.5378, -0.1992, -0.7048, 0.1092), float4(-0.584, 0.321, 0.746, 0), float4(0.763, -0.097, 0.639, 0),
    float4(0.5826, -0.2618, -0.8540, 0.1384), float4(-0.568, 0.288, 0.771, 0), float4(0.773, -0.135, 0.619, 0),
    float4(0.5787, -0.3685, -0.9815, 0.1874), float4(-0.519, 0.314, 0.795, 0), float4(0.790, -0.179, 0.586, 0),
    float4(0.5168, -0.5068, -1.0696, 0.2486), float4(-0.437, 0.376, 0.817, 0), float4(0.811, -0.227, 0.538, 0),
    float4(0.4015, -0.6602, -1.1067, 0.3040), float4(-0.330, 0.458, 0.826, 0), float4(0.830, -0.277, 0.485, 0),
    float4(0.2465, -0.8098, -1.0882, 0.3420), float4(-0.215, 0.548, 0.808, 0), float4(0.839, -0.319, 0.440, 0),
    float4(0.0689, -0.9378, -1.0166, 0.3671), float4(-0.102, 0.639, 0.762, 0), float4(0.842, -0.352, 0.408, 0),
    float4(-0.1144, -1.0297, -0.9009, 0.3579), float4(0.011, 0.720, 0.694, 0), float4(0.843, -0.380, 0.381, 0),
    float4(-0.2866, -1.0755, -0.7552, 0.3273), float4(0.135, 0.781, 0.609, 0), float4(0.841, -0.416, 0.347, 0),
    float4(-0.4306, -1.0703, -0.5969, 0.2770), float4(0.268, 0.818, 0.509, 0), float4(0.834, -0.461, 0.303, 0),
    float4(-0.5300, -1.0142, -0.4450, 0.2144), float4(0.389, 0.828, 0.403, 0), float4(0.821, -0.510, 0.256, 0),
    float4(-0.5733, -0.9131, -0.3173, 0.1575), float4(0.478, 0.820, 0.315, 0), float4(0.807, -0.551, 0.211, 0),
    float4(-0.5599, -0.7794, -0.2285, 0.1182), float4(0.528, 0.807, 0.266, 0), float4(0.798, -0.578, 0.171, 0),
    float4(-0.5051, -0.6317, -0.1884, 0.0902), float4(0.543, 0.795, 0.270, 0), float4(0.796, -0.590, 0.136, 0),
    float4(-0.4374, -0.4920, -0.2006, 0.0825), float4(0.538, 0.777, 0.328, 0), float4(0.797, -0.595, 0.104, 0),
    float4(-0.3887, -0.3802, -0.2627, 0.0873), float4(0.528, 0.732, 0.431, 0), float4(0.790, -0.610, 0.068, 0),
    float4(-0.3799, -0.3076, -0.3668, 0.0920), float4(0.522, 0.647, 0.556, 0), float4(0.768, -0.640, 0.024, 0),
    float4(-0.4128, -0.2739, -0.5018, 0.0968), float4(0.518, 0.533, 0.669, 0), float4(0.735, -0.678, -0.029, 0),
    float4(-0.4711, -0.2682, -0.6574, 0.1106), float4(0.509, 0.423, 0.750, 0), float4(0.701, -0.709, -0.076, 0),
    float4(-0.5307, -0.2750, -0.8268, 0.1354), float4(0.491, 0.344, 0.800, 0), float4(0.678, -0.728, -0.103, 0),
    float4(-0.5714, -0.2803, -1.0086, 0.1820), float4(0.469, 0.299, 0.831, 0), float4(0.665, -0.739, -0.110, 0),
    float4(-0.5818, -0.2758, -1.2049, 0.2464), float4(0.449, 0.270, 0.852, 0), float4(0.655, -0.748, -0.109, 0),
    float4(-0.5572, -0.2579, -1.4171, 0.3147), float4(0.439, 0.241, 0.866, 0), float4(0.642, -0.759, -0.114, 0),
    float4(-0.4953, -0.2253, -1.6383, 0.4055), float4(0.433, 0.209, 0.877, 0), float4(0.624, -0.772, -0.124, 0),
    float4(-0.3940, -0.1770, -1.8488, 0.4953), float4(0.416, 0.179, 0.891, 0), float4(0.608, -0.784, -0.127, 0),
    float4(-0.2548, -0.1136, -2.0176, 0.5534), float4(0.370, 0.156, 0.916, 0), float4(0.601, -0.792, -0.108, 0),
    float4(-0.0872, -0.0388, -2.1118, 0.5922), float4(0.284, 0.141, 0.948, 0), float4(0.603, -0.795, -0.063, 0),
    float4(0.0910, 0.0403, -2.1100, 0.5912), float4(0.161, 0.125, 0.979, 0), float4(0.608, -0.794, 0.001, 0),
    float4(0.2582, 0.1149, -2.0126, 0.5595), float4(0.018, 0.093, 0.995, 0), float4(0.609, -0.791, 0.063, 0),
    float4(0.3964, 0.1779, -1.8413, 0.4998), float4(-0.124, 0.042, 0.991, 0), float4(0.607, -0.787, 0.109, 0),
    float4(0.4967, 0.2259, -1.6292, 0.4087), float4(-0.250, -0.021, 0.968, 0), float4(0.606, -0.784, 0.139, 0),
    float4(0.5579, 0.2585, -1.4072, 0.3187), float4(-0.352, -0.084, 0.932, 0), float4(0.606, -0.780, 0.158, 0),
    float4(0.5818, 0.2766, -1.1948, 0.2513), float4(-0.426, -0.141, 0.894, 0), float4(0.608, -0.776, 0.168, 0),
    float4(0.5708, 0.2817, -0.9992, 0.1869), float4(-0.469, -0.189, 0.863, 0), float4(0.615, -0.771, 0.165, 0),
    float4(0.5293, 0.2770, -0.8192, 0.1404), float4(-0.481, -0.235, 0.845, 0), float4(0.630, -0.763, 0.146, 0),
    float4(0.4684, 0.2704, -0.6521, 0.1070), float4(-0.471, -0.286, 0.835, 0), float4(0.652, -0.750, 0.111, 0),
    float4(0.4089, 0.2745, -0.4985, 0.0928), float4(-0.457, -0.348, 0.818, 0), float4(0.677, -0.733, 0.066, 0),
    float4(0.3756, 0.3038, -0.3632, 0.0875), float4(-0.459, -0.430, 0.777, 0), float4(0.700, -0.714, 0.019, 0),
    float4(0.3860, 0.3690, -0.2551, 0.0822), float4(-0.488, -0.528, 0.695, 0), float4(0.718, -0.696, -0.024, 0),
    float4(0.4397, 0.4717, -0.1841, 0.0769), float4(-0.534, -0.625, 0.569, 0), float4(0.730, -0.681, -0.063, 0),
    float4(0.5160, 0.6030, -0.1590, 0.0853), float4(-0.572, -0.697, 0.433, 0), float4(0.738, -0.668, -0.099, 0),
    float4(0.5826, 0.7460, -0.1844, 0.1091), float4(-0.588, -0.737, 0.333, 0), float4(0.744, -0.654, -0.136, 0),
    float4(0.6097, 0.8811, -0.2597, 0.1452), float4(-0.574, -0.761, 0.301, 0), float4(0.752, -0.636, -0.175, 0),
    float4(0.5803, 0.9901, -0.3775, 0.1980), float4(-0.528, -0.782, 0.332, 0), float4(0.763, -0.608, -0.218, 0),
    float4(0.4936, 1.0595, -0.5244, 0.2606), float4(-0.443, -0.799, 0.406, 0), float4(0.780, -0.567, -0.265, 0),
    float4(0.3600, 1.0809, -0.6826, 0.3152), float4(-0.326, -0.805, 0.496, 0), float4(0.796, -0.517, -0.316, 0),
    float4(0.1949, 1.0513, -0.8328, 0.3532), float4(-0.195, -0.787, 0.585, 0), float4(0.805, -0.469, -0.362, 0),
    float4(0.0138, 0.9728, -0.9572, 0.3708), float4(-0.066, -0.745, 0.664, 0), float4(0.809, -0.429, -0.401, 0),
    float4(-0.1686, 0.8530, -1.0422, 0.3571), float4(0.062, -0.681, 0.729, 0), float4(0.810, -0.393, -0.436, 0),
    float4(-0.3375, 0.7049, -1.0791, 0.3208), float4(0.194, -0.596, 0.779, 0), float4(0.807, -0.354, -0.472, 0),
    float4(-0.4770, 0.5459, -1.0645, 0.2678), float4(0.326, -0.492, 0.808, 0), float4(0.801, -0.310, -0.512, 0),
    float4(-0.5708, 0.3957, -1.0006, 0.2051), float4(0.437, -0.384, 0.813, 0), float4(0.791, -0.266, -0.551, 0),
    float4(-0.6070, 0.2732, -0.8948, 0.1503), float4(0.512, -0.300, 0.805, 0), float4(0.782, -0.225, -0.582, 0),
    float4(-0.5852, 0.1924, -0.7604, 0.1121), float4(0.546, -0.264, 0.795, 0), float4(0.779, -0.189, -0.598, 0),
    float4(-0.5217, 0.1613, -0.6160, 0.0860), float4(0.544, -0.283, 0.790, 0), float4(0.786, -0.159, -0.598, 0),
    float4(-0.4471, 0.1805, -0.4821, 0.0757), float4(0.525, -0.346, 0.777, 0), float4(0.793, -0.131, -0.595, 0),
    float4(-0.3950, 0.2454, -0.3770, 0.0804), float4(0.516, -0.432, 0.740, 0), float4(0.789, -0.097, -0.606, 0),
    float4(-0.3872, 0.3476, -0.3105, 0.0880), float4(0.526, -0.523, 0.670, 0), float4(0.766, -0.050, -0.641, 0),
    float4(-0.4236, 0.4779, -0.2811, 0.0957), float4(0.545, -0.610, 0.575, 0), float4(0.729, 0.006, -0.685, 0),
    float4(-0.4848, 0.6283, -0.2771, 0.1106), float4(0.548, -0.689, 0.473, 0), float4(0.692, 0.056, -0.720, 0),
    float4(-0.5435, 0.7938, -0.2830, 0.1446), float4(0.528, -0.754, 0.391, 0), float4(0.668, 0.085, -0.739, 0),
    float4(-0.5782, 0.9730, -0.2854, 0.1892), float4(0.492, -0.803, 0.335, 0), float4(0.658, 0.091, -0.747, 0),
    float4(-0.5790, 1.1678, -0.2769, 0.2513), float4(0.455, -0.839, 0.298, 0), float4(0.653, 0.087, -0.752, 0),
    float4(-0.5446, 1.3790, -0.2551, 0.3151), float4(0.423, -0.867, 0.263, 0), float4(0.646, 0.085, -0.759, 0),
    float4(-0.4758, 1.6007, -0.2197, 0.3980), float4(0.396, -0.890, 0.226, 0), float4(0.635, 0.087, -0.767, 0),
    float4(-0.3720, 1.8148, -0.1702, 0.4881), float4(0.363, -0.911, 0.195, 0), float4(0.626, 0.084, -0.775, 0),
    float4(-0.2342, 1.9915, -0.1068, 0.5479), float4(0.314, -0.933, 0.175, 0), float4(0.623, 0.064, -0.780, 0),
    float4(-0.0699, 2.0969, -0.0325, 0.5799), float4(0.239, -0.957, 0.164, 0), float4(0.625, 0.022, -0.781, 0),
    float4(0.1050, 2.1072, 0.0461, 0.5831), float4(0.135, -0.980, 0.149, 0), float4(0.627, -0.032, -0.778, 0),
    float4(0.2695, 2.0194, 0.1205, 0.5469), float4(0.009, -0.993, 0.115, 0), float4(0.627, -0.084, -0.775, 0),
    float4(0.4060, 1.8534, 0.1831, 0.4936), float4(-0.122, -0.991, 0.056, 0), float4(0.624, -0.121, -0.772, 0),
    float4(0.5047, 1.6422, 0.2304, 0.4086), float4(-0.243, -0.970, -0.016, 0), float4(0.622, -0.143, -0.770, 0),
    float4(0.5642, 1.4185, 0.2619, 0.3165), float4(-0.345, -0.935, -0.087, 0), float4(0.620, -0.158, -0.768, 0),
    float4(0.5867, 1.2038, 0.2789, 0.2472), float4(-0.421, -0.895, -0.147, 0), float4(0.620, -0.166, -0.767, 0),
    // icosa
    float4(0.9809, 0.4091, 0.7111, 0.2076), float4(-0.786, -0.325, -0.526, 0), float4(-0.498, -0.171, 0.850, 0),
    float4(0.7755, 0.4299, 0.6431, 0.1788), float4(-0.720, -0.413, -0.558, 0), float4(-0.533, -0.186, 0.825, 0),
    float4(0.6022, 0.4939, 0.5976, 0.1658), float4(-0.621, -0.524, -0.583, 0), float4(-0.572, -0.205, 0.794, 0),
    float4(0.4845, 0.6017, 0.5812, 0.1639), float4(-0.517, -0.624, -0.586, 0), float4(-0.603, -0.219, 0.767, 0),
    float4(0.4451, 0.7343, 0.5896, 0.1700), float4(-0.456, -0.689, -0.564, 0), float4(-0.616, -0.213, 0.758, 0),
    float4(0.4930, 0.8582, 0.6088, 0.1885), float4(-0.455, -0.716, -0.530, 0), float4(-0.610, -0.183, 0.771, 0),
    float4(0.6145, 0.9384, 0.6220, 0.2013), float4(-0.497, -0.714, -0.493, 0), float4(-0.592, -0.136, 0.795, 0),
    float4(0.7753, 0.9512, 0.6160, 0.2071), float4(-0.558, -0.694, -0.455, 0), float4(-0.566, -0.083, 0.820, 0),
    float4(0.9304, 0.8922, 0.5856, 0.2129), float4(-0.624, -0.658, -0.421, 0), float4(-0.537, -0.030, 0.843, 0),
    float4(1.0400, 0.7752, 0.5306, 0.2188), float4(-0.691, -0.604, -0.397, 0), float4(-0.509, 0.017, 0.861, 0),
    float4(1.0822, 0.6275, 0.4525, 0.2246), float4(-0.755, -0.529, -0.387, 0), float4(-0.486, 0.056, 0.872, 0),
    float4(1.0618, 0.4819, 0.3517, 0.2244), float4(-0.813, -0.446, -0.375, 0), float4(-0.459, 0.095, 0.883, 0),
    float4(1.0078, 0.3703, 0.2297, 0.2117), float4(-0.868, -0.377, -0.325, 0), float4(-0.402, 0.148, 0.903, 0),
    float4(0.9609, 0.3153, 0.0910, 0.2049), float4(-0.917, -0.342, -0.205, 0), float4(-0.289, 0.219, 0.932, 0),
    float4(0.9524, 0.3233, -0.0570, 0.2057), float4(-0.942, -0.334, -0.022, 0), float4(-0.128, 0.298, 0.946, 0),
    float4(0.9884, 0.3801, -0.2075, 0.2105), float4(-0.929, -0.331, 0.165, 0), float4(0.035, 0.365, 0.930, 0),
    float4(1.0461, 0.4550, -0.3552, 0.2054), float4(-0.894, -0.329, 0.303, 0), float4(0.156, 0.406, 0.900, 0),
    float4(1.0875, 0.5122, -0.4946, 0.1989), float4(-0.860, -0.329, 0.390, 0), float4(0.234, 0.425, 0.874, 0),
    float4(1.0797, 0.5266, -0.6150, 0.1924), float4(-0.829, -0.330, 0.452, 0), float4(0.292, 0.433, 0.853, 0),
    float4(1.0101, 0.4962, -0.7006, 0.1859), float4(-0.795, -0.327, 0.510, 0), float4(0.350, 0.439, 0.828, 0),
    float4(0.8906, 0.4443, -0.7370, 0.1794), float4(-0.749, -0.331, 0.574, 0), float4(0.414, 0.443, 0.795, 0),
    float4(0.7495, 0.4084, -0.7214, 0.1720), float4(-0.681, -0.366, 0.634, 0), float4(0.472, 0.442, 0.762, 0),
    float4(0.6194, 0.4232, -0.6684, 0.1607), float4(-0.593, -0.456, 0.664, 0), float4(0.508, 0.427, 0.748, 0),
    float4(0.5261, 0.5053, -0.6052, 0.1592), float4(-0.500, -0.587, 0.637, 0), float4(0.516, 0.389, 0.763, 0),
    float4(0.4820, 0.6496, -0.5583, 0.1622), float4(-0.428, -0.710, 0.560, 0), float4(0.504, 0.327, 0.799, 0),
    float4(0.4862, 0.8372, -0.5418, 0.1757), float4(-0.395, -0.785, 0.478, 0), float4(0.490, 0.260, 0.832, 0),
    float4(0.5280, 1.0483, -0.5518, 0.2099), float4(-0.399, -0.811, 0.428, 0), float4(0.484, 0.211, 0.849, 0),
    float4(0.5923, 1.2699, -0.5703, 0.2673), float4(-0.424, -0.805, 0.414, 0), float4(0.488, 0.182, 0.853, 0),
    float4(0.6629, 1.4929, -0.5731, 0.3540), float4(-0.453, -0.788, 0.417, 0), float4(0.500, 0.163, 0.851, 0),
    float4(0.7241, 1.7028, -0.5397, 0.4256), float4(-0.469, -0.781, 0.412, 0), float4(0.510, 0.141, 0.848, 0),
    float4(0.7613, 1.8747, -0.4603, 0.4721), float4(-0.467, -0.800, 0.378, 0), float4(0.512, 0.103, 0.853, 0),
    float4(0.7640, 1.9785, -0.3407, 0.4922), float4(-0.447, -0.842, 0.303, 0), float4(0.502, 0.044, 0.864, 0),
    float4(0.7299, 1.9924, -0.2002, 0.4863), float4(-0.413, -0.888, 0.201, 0), float4(0.484, -0.027, 0.875, 0),
    float4(0.6656, 1.9144, -0.0643, 0.4564), float4(-0.374, -0.922, 0.102, 0), float4(0.467, -0.093, 0.879, 0),
    float4(0.5831, 1.7627, 0.0464, 0.4002), float4(-0.341, -0.940, 0.029, 0), float4(0.458, -0.140, 0.878, 0),
    float4(0.4926, 1.5665, 0.1248, 0.3147), float4(-0.323, -0.946, -0.017, 0), float4(0.455, -0.171, 0.874, 0),
    float4(0.3969, 1.3555, 0.1792, 0.2443), float4(-0.312, -0.948, -0.054, 0), float4(0.453, -0.199, 0.869, 0),
    float4(0.2918, 1.1564, 0.2276, 0.1990), float4(-0.289, -0.951, -0.111, 0), float4(0.449, -0.237, 0.862, 0),
    float4(0.1724, 0.9946, 0.2864, 0.1772), float4(-0.220, -0.954, -0.206, 0), float4(0.441, -0.285, 0.851, 0),
    float4(0.0412, 0.8951, 0.3607, 0.1708), float4(-0.095, -0.942, -0.323, 0), float4(0.435, -0.331, 0.838, 0),
    float4(-0.0877, 0.8760, 0.4387, 0.1677), float4(0.048, -0.909, -0.414, 0), float4(0.430, -0.355, 0.830, 0),
    float4(-0.1923, 0.9382, 0.4966, 0.1775), float4(0.150, -0.881, -0.448, 0), float4(0.426, -0.352, 0.834, 0),
    float4(-0.2510, 1.0610, 0.5095, 0.1945), float4(0.186, -0.884, -0.429, 0), float4(0.418, -0.324, 0.849, 0),
    float4(-0.2523, 1.2058, 0.4648, 0.2026), float4(0.167, -0.913, -0.372, 0), float4(0.408, -0.280, 0.869, 0),
    float4(-0.1993, 1.3286, 0.3681, 0.2078), float4(0.115, -0.950, -0.290, 0), float4(0.396, -0.224, 0.890, 0),
    float4(-0.1091, 1.3931, 0.2400, 0.2131), float4(0.049, -0.980, -0.194, 0), float4(0.384, -0.161, 0.909, 0),
    float4(-0.0076, 1.3804, 0.1047, 0.2183), float4(-0.022, -0.995, -0.098, 0), float4(0.372, -0.099, 0.923, 0),
    float4(0.0777, 1.2946, -0.0207, 0.2236), float4(-0.096, -0.995, -0.009, 0), float4(0.359, -0.044, 0.932, 0),
    float4(0.1243, 1.1633, -0.1324, 0.2191), float4(-0.159, -0.984, 0.085, 0), float4(0.349, 0.025, 0.937, 0),
    float4(0.1200, 1.0302, -0.2366, 0.2074), float4(-0.183, -0.961, 0.208, 0), float4(0.345, 0.135, 0.929, 0),
    float4(0.0655, 0.9385, -0.3434, 0.2046), float4(-0.147, -0.923, 0.355, 0), float4(0.345, 0.289, 0.893, 0),
    float4(-0.0280, 0.9107, -0.4590, 0.2047), float4(-0.061, -0.870, 0.489, 0), float4(0.339, 0.443, 0.830, 0),
    float4(-0.1421, 0.9357, -0.5828, 0.2087), float4(0.038, -0.814, 0.580, 0), float4(0.326, 0.559, 0.763, 0),
    float4(-0.2563, 0.9742, -0.7067, 0.2020), float4(0.127, -0.767, 0.629, 0), float4(0.313, 0.633, 0.708, 0),
    float4(-0.3516, 0.9795, -0.8162, 0.1953), float4(0.201, -0.728, 0.656, 0), float4(0.303, 0.683, 0.665, 0),
    float4(-0.4152, 0.9237, -0.8934, 0.1887), float4(0.265, -0.687, 0.677, 0), float4(0.295, 0.726, 0.621, 0),
    float4(-0.4455, 0.8108, -0.9205, 0.1820), float4(0.319, -0.635, 0.703, 0), float4(0.285, 0.772, 0.568, 0),
    float4(-0.4546, 0.6739, -0.8878, 0.1753), float4(0.370, -0.576, 0.729, 0), float4(0.274, 0.817, 0.507, 0),
    float4(-0.4656, 0.5565, -0.8009, 0.1686), float4(0.432, -0.523, 0.734, 0), float4(0.267, 0.852, 0.450, 0),
    float4(-0.5027, 0.4936, -0.6819, 0.1579), float4(0.520, -0.500, 0.693, 0), float4(0.276, 0.866, 0.417, 0),
    float4(-0.5810, 0.4992, -0.5621, 0.1585), float4(0.621, -0.513, 0.593, 0), float4(0.311, 0.855, 0.414, 0),
    float4(-0.7009, 0.5678, -0.4682, 0.1647), float4(0.701, -0.546, 0.458, 0), float4(0.365, 0.827, 0.427, 0),
    float4(-0.8515, 0.6830, -0.4115, 0.1821), float4(0.744, -0.576, 0.339, 0), float4(0.418, 0.797, 0.437, 0),
    float4(-1.0179, 0.8283, -0.3839, 0.2262), float4(0.760, -0.592, 0.267, 0), float4(0.453, 0.778, 0.436, 0),
    float4(-1.1855, 0.9915, -0.3638, 0.2939), float4(0.763, -0.600, 0.240, 0), float4(0.472, 0.771, 0.427, 0),
    float4(-1.3391, 1.1610, -0.3266, 0.3838), float4(0.754, -0.612, 0.239, 0), float4(0.490, 0.766, 0.416, 0),
    float4(-1.4600, 1.3200, -0.2554, 0.4439), float4(0.738, -0.633, 0.234, 0), float4(0.517, 0.753, 0.407, 0),
    float4(-1.5275, 1.4446, -0.1475, 0.4801), float4(0.719, -0.665, 0.202, 0), float4(0.559, 0.727, 0.399, 0),
    float4(-1.5258, 1.5111, -0.0160, 0.4906), float4(0.703, -0.699, 0.134, 0), float4(0.610, 0.689, 0.392, 0),
    float4(-1.4533, 1.5062, 0.1162, 0.4767), float4(0.687, -0.725, 0.043, 0), float4(0.659, 0.648, 0.382, 0),
    float4(-1.3245, 1.4335, 0.2263, 0.4347), float4(0.671, -0.741, -0.042, 0), float4(0.699, 0.613, 0.368, 0),
    float4(-1.1630, 1.3099, 0.3015, 0.3691), float4(0.656, -0.747, -0.107, 0), float4(0.728, 0.588, 0.353, 0),
    float4(-0.9914, 1.1562, 0.3447, 0.2813), float4(0.642, -0.750, -0.160, 0), float4(0.750, 0.570, 0.337, 0),
    float4(-0.8266, 0.9899, 0.3733, 0.2235), float4(0.621, -0.749, -0.231, 0), float4(0.776, 0.545, 0.317, 0),
    float4(-0.6816, 0.8245, 0.4122, 0.1887), float4(0.578, -0.737, -0.351, 0), float4(0.815, 0.501, 0.290, 0),
    float4(-0.5712, 0.6737, 0.4817, 0.1742), float4(0.510, -0.690, -0.513, 0), float4(0.858, 0.445, 0.255, 0),
    float4(-0.5130, 0.5544, 0.5863, 0.1729), float4(0.444, -0.602, -0.663, 0), float4(0.886, 0.403, 0.229, 0),
    float4(-0.5208, 0.4823, 0.7095, 0.1740), float4(0.425, -0.507, -0.750, 0), float4(0.888, 0.393, 0.237, 0),
    float4(-0.5955, 0.4652, 0.8182, 0.1874), float4(0.461, -0.445, -0.768, 0), float4(0.867, 0.411, 0.283, 0),
    float4(-0.7200, 0.4981, 0.8770, 0.1995), float4(0.529, -0.429, -0.732, 0), float4(0.831, 0.438, 0.343, 0),
    float4(-0.8620, 0.5636, 0.8635, 0.2045), float4(0.598, -0.454, -0.661, 0), float4(0.792, 0.462, 0.398, 0),
    float4(-0.9841, 0.6380, 0.7769, 0.2094), float4(0.653, -0.506, -0.563, 0), float4(0.756, 0.482, 0.444, 0),
    float4(-1.0556, 0.6964, 0.6356, 0.2144), float4(0.691, -0.568, -0.447, 0), float4(0.721, 0.497, 0.482, 0),
    float4(-1.0631, 0.7182, 0.4675, 0.2193), float4(0.708, -0.627, -0.325, 0), float4(0.688, 0.510, 0.517, 0),
    float4(-1.0172, 0.6917, 0.3001, 0.2232), float4(0.717, -0.668, -0.199, 0), float4(0.646, 0.529, 0.551, 0),
    float4(-0.9502, 0.6172, 0.1538, 0.2147), float4(0.741, -0.668, -0.066, 0), float4(0.570, 0.574, 0.588, 0),
    float4(-0.9056, 0.5078, 0.0405, 0.2076), float4(0.801, -0.595, 0.071, 0), float4(0.433, 0.657, 0.617, 0),
    float4(-0.9191, 0.3831, -0.0373, 0.2078), float4(0.878, -0.442, 0.186, 0), float4(0.244, 0.746, 0.620, 0),
    float4(-1.0003, 0.2598, -0.0856, 0.2081), float4(0.933, -0.264, 0.243, 0), float4(0.069, 0.796, 0.601, 0),
    float4(-1.1258, 0.1443, -0.1178, 0.2081), float4(0.961, -0.131, 0.244, 0), float4(-0.039, 0.810, 0.585, 0),
    float4(-1.2494, 0.0344, -0.1498, 0.2001), float4(0.974, -0.050, 0.222, 0), float4(-0.090, 0.812, 0.576, 0),
    float4(-1.3222, -0.0729, -0.1916, 0.1922), float4(0.979, 0.010, 0.203, 0), float4(-0.126, 0.813, 0.568, 0),
    float4(-1.3149, -0.1736, -0.2402, 0.1842), float4(0.977, 0.073, 0.202, 0), float4(-0.175, 0.814, 0.554, 0),
    float4(-1.2298, -0.2576, -0.2778, 0.1762), float4(0.965, 0.147, 0.218, 0), float4(-0.244, 0.811, 0.531, 0),
    float4(-1.0981, -0.3164, -0.2797, 0.1679), float4(0.946, 0.224, 0.234, 0), float4(-0.315, 0.804, 0.504, 0),
    float4(-0.9667, -0.3508, -0.2281, 0.1597), float4(0.930, 0.297, 0.216, 0), float4(-0.366, 0.799, 0.476, 0),
    float4(-0.8798, -0.3720, -0.1223, 0.1517), float4(0.923, 0.360, 0.133, 0), float4(-0.380, 0.805, 0.455, 0),
    float4(-0.8641, -0.3953, 0.0214, 0.1529), float4(0.916, 0.401, -0.011, 0), float4(-0.356, 0.826, 0.437, 0),
    float4(-0.9236, -0.4307, 0.1793, 0.1604), float4(0.896, 0.411, -0.170, 0), float4(-0.312, 0.854, 0.416, 0),
    float4(-1.0440, -0.4793, 0.3345, 0.1823), float4(0.868, 0.403, -0.292, 0), float4(-0.275, 0.877, 0.394, 0),
    float4(-1.2026, -0.5328, 0.4837, 0.2319), float4(0.845, 0.394, -0.360, 0), float4(-0.255, 0.891, 0.376, 0),
    float4(-1.3749, -0.5783, 0.6352, 0.3049), float4(0.836, 0.389, -0.388, 0), float4(-0.250, 0.898, 0.362, 0),
    float4(-1.5358, -0.6016, 0.7972, 0.3946), float4(0.838, 0.378, -0.395, 0), float4(-0.245, 0.905, 0.347, 0),
    float4(-1.6584, -0.5918, 0.9667, 0.4547), float4(0.845, 0.352, -0.403, 0), float4(-0.228, 0.918, 0.324, 0),
    float4(-1.7168, -0.5442, 1.1256, 0.4909), float4(0.847, 0.310, -0.432, 0), float4(-0.194, 0.937, 0.291, 0),
    float4(-1.6951, -0.4640, 1.2470, 0.5004), float4(0.835, 0.256, -0.487, 0), float4(-0.148, 0.957, 0.249, 0),
    float4(-1.5956, -0.3650, 1.3086, 0.4814), float4(0.807, 0.199, -0.555, 0), float4(-0.099, 0.974, 0.204, 0),
    float4(-1.4385, -0.2647, 1.3024, 0.4323), float4(0.773, 0.149, -0.616, 0), float4(-0.060, 0.985, 0.162, 0),
    float4(-1.2519, -0.1776, 1.2372, 0.3581), float4(0.744, 0.115, -0.658, 0), float4(-0.037, 0.991, 0.131, 0),
    float4(-1.0577, -0.1094, 1.1342, 0.2671), float4(0.719, 0.097, -0.688, 0), float4(-0.028, 0.993, 0.111, 0),
    float4(-0.8647, -0.0576, 1.0204, 0.2058), float4(0.680, 0.084, -0.728, 0), float4(-0.024, 0.995, 0.093, 0),
    float4(-0.6727, -0.0155, 0.9244, 0.1671), float4(0.598, 0.059, -0.799, 0), float4(-0.012, 0.998, 0.064, 0),
    float4(-0.4838, 0.0207, 0.8726, 0.1489), float4(0.454, 0.016, -0.891, 0), float4(0.009, 1.000, 0.022, 0),
    float4(-0.3118, 0.0485, 0.8822, 0.1447), float4(0.276, -0.027, -0.961, 0), float4(0.027, 0.999, -0.020, 0),
    float4(-0.1809, 0.0587, 0.9533, 0.1430), float4(0.138, -0.042, -0.990, 0), float4(0.038, 0.999, -0.037, 0),
    float4(-0.1167, 0.0404, 1.0658, 0.1533), float4(0.087, -0.024, -0.996, 0), float4(0.041, 0.999, -0.020, 0),
    float4(-0.1326, -0.0115, 1.1850, 0.1743), float4(0.111, 0.020, -0.994, 0), float4(0.041, 0.999, 0.025, 0),
    float4(-0.2218, -0.0916, 1.2744, 0.1871), float4(0.179, 0.076, -0.981, 0), float4(0.037, 0.996, 0.084, 0),
    float4(-0.3586, -0.1840, 1.3074, 0.1978), float4(0.263, 0.132, -0.956, 0), float4(0.030, 0.989, 0.145, 0),
    float4(-0.5055, -0.2683, 1.2726, 0.2085), float4(0.352, 0.182, -0.918, 0), float4(0.022, 0.979, 0.203, 0),
    float4(-0.6257, -0.3301, 1.1734, 0.2192), float4(0.439, 0.216, -0.872, 0), float4(0.016, 0.969, 0.248, 0),
    float4(-0.6944, -0.3686, 1.0260, 0.2299), float4(0.524, 0.230, -0.820, 0), float4(0.015, 0.960, 0.279, 0),
    float4(-0.7064, -0.3992, 0.8580, 0.2302), float4(0.606, 0.248, -0.756, 0), float4(0.006, 0.949, 0.316, 0),
    float4(-0.6756, -0.4468, 0.7032, 0.2199), float4(0.674, 0.317, -0.668, 0), float4(-0.041, 0.918, 0.395, 0),
    float4(-0.6263, -0.5338, 0.5911, 0.2178), float4(0.698, 0.456, -0.553, 0), float4(-0.142, 0.844, 0.517, 0),
    float4(-0.5788, -0.6674, 0.5334, 0.2182), float4(0.658, 0.618, -0.430, 0), float4(-0.264, 0.725, 0.637, 0),
    float4(-0.5402, -0.8345, 0.5162, 0.2176), float4(0.579, 0.740, -0.342, 0), float4(-0.352, 0.605, 0.714, 0),
    float4(-0.5037, -1.0048, 0.5070, 0.2094), float4(0.499, 0.812, -0.302, 0), float4(-0.397, 0.524, 0.754, 0),
    float4(-0.4577, -1.1411, 0.4729, 0.2011), float4(0.429, 0.857, -0.287, 0), float4(-0.422, 0.471, 0.775, 0),
    float4(-0.3948, -1.2127, 0.4010, 0.1928), float4(0.366, 0.893, -0.262, 0), float4(-0.448, 0.416, 0.791, 0),
    float4(-0.3150, -1.2072, 0.3065, 0.1846), float4(0.305, 0.928, -0.213, 0), float4(-0.480, 0.343, 0.807, 0),
    float4(-0.2236, -1.1364, 0.2251, 0.1763), float4(0.238, 0.958, -0.157, 0), float4(-0.513, 0.262, 0.817, 0),
    float4(-0.1261, -1.0336, 0.1930, 0.1676), float4(0.152, 0.979, -0.135, 0), float4(-0.541, 0.197, 0.818, 0),
    float4(-0.0271, -0.9416, 0.2295, 0.1600), float4(0.040, 0.982, -0.185, 0), float4(-0.561, 0.175, 0.809, 0),
    float4(0.0690, -0.8962, 0.3309, 0.1605), float4(-0.080, 0.950, -0.303, 0), float4(-0.580, 0.203, 0.789, 0),
    float4(0.1581, -0.9137, 0.4781, 0.1677), float4(-0.173, 0.882, -0.438, 0), float4(-0.602, 0.257, 0.756, 0),
    float4(0.2370, -0.9880, 0.6503, 0.1898), float4(-0.224, 0.812, -0.538, 0), float4(-0.621, 0.306, 0.721, 0),
    float4(0.3051, -1.0968, 0.8363, 0.2398), float4(-0.244, 0.767, -0.594, 0), float4(-0.635, 0.336, 0.695, 0),
    float4(0.3633, -1.2104, 1.0340, 0.3132), float4(-0.245, 0.747, -0.618, 0), float4(-0.645, 0.349, 0.679, 0),
    float4(0.4122, -1.2987, 1.2406, 0.3994), float4(-0.236, 0.740, -0.630, 0), float4(-0.655, 0.358, 0.666, 0),
    float4(0.4497, -1.3357, 1.4426, 0.4552), float4(-0.217, 0.731, -0.647, 0), float4(-0.667, 0.373, 0.645, 0),
    float4(0.4712, -1.3048, 1.6129, 0.4879), float4(-0.196, 0.704, -0.683, 0), float4(-0.684, 0.400, 0.609, 0),
    float4(0.4723, -1.2056, 1.7206, 0.4974), float4(-0.181, 0.652, -0.736, 0), float4(-0.703, 0.437, 0.561, 0),
    float4(0.4527, -1.0546, 1.7452, 0.4768), float4(-0.178, 0.582, -0.794, 0), float4(-0.721, 0.473, 0.507, 0),
    float4(0.4162, -0.8797, 1.6858, 0.4272), float4(-0.180, 0.511, -0.840, 0), float4(-0.734, 0.499, 0.461, 0),
    float4(0.3701, -0.7063, 1.5601, 0.3541), float4(-0.184, 0.457, -0.870, 0), float4(-0.744, 0.514, 0.427, 0),
    float4(0.3233, -0.5465, 1.3952, 0.2683), float4(-0.194, 0.412, -0.890, 0), float4(-0.751, 0.521, 0.405, 0),
    float4(0.2853, -0.3967, 1.2195, 0.2127), float4(-0.217, 0.349, -0.912, 0), float4(-0.759, 0.527, 0.382, 0),
    float4(0.2669, -0.2463, 1.0606, 0.1798), float4(-0.259, 0.232, -0.938, 0), float4(-0.769, 0.537, 0.345, 0),
    float4(0.2786, -0.0911, 0.9440, 0.1635), float4(-0.312, 0.058, -0.948, 0), float4(-0.783, 0.549, 0.292, 0),
    float4(0.3268, 0.0570, 0.8895, 0.1622), float4(-0.360, -0.117, -0.926, 0), float4(-0.795, 0.558, 0.239, 0),
    float4(0.4091, 0.1713, 0.9037, 0.1650), float4(-0.398, -0.222, -0.890, 0), float4(-0.795, 0.568, 0.214, 0),
    float4(0.5117, 0.2219, 0.9741, 0.1788), float4(-0.431, -0.236, -0.871, 0), float4(-0.778, 0.586, 0.226, 0),
    float4(0.6122, 0.1913, 1.0718, 0.1963), float4(-0.455, -0.184, -0.871, 0), float4(-0.749, 0.609, 0.262, 0),
    float4(0.6866, 0.0843, 1.1610, 0.2039), float4(-0.461, -0.094, -0.883, 0), float4(-0.714, 0.630, 0.305, 0),
    float4(0.7167, -0.0721, 1.2110, 0.2115), float4(-0.441, 0.018, -0.897, 0), float4(-0.678, 0.648, 0.347, 0),
    float4(0.6968, -0.2398, 1.2027, 0.2191), float4(-0.398, 0.143, -0.906, 0), float4(-0.641, 0.663, 0.386, 0),
    float4(0.6370, -0.3839, 1.1314, 0.2268), float4(-0.338, 0.269, -0.902, 0), float4(-0.602, 0.675, 0.426, 0),
    float4(0.5624, -0.4858, 1.0072, 0.2316), float4(-0.280, 0.385, -0.879, 0), float4(-0.558, 0.680, 0.476, 0),
    float4(0.5072, -0.5473, 0.8534, 0.2254), float4(-0.254, 0.494, -0.831, 0), float4(-0.503, 0.667, 0.550, 0),
    float4(0.5029, -0.5856, 0.6998, 0.2156), float4(-0.285, 0.600, -0.748, 0), float4(-0.428, 0.618, 0.659, 0),
    float4(0.5659, -0.6215, 0.5708, 0.2178), float4(-0.376, 0.685, -0.624, 0), float4(-0.333, 0.528, 0.781, 0),
    float4(0.6878, -0.6675, 0.4734, 0.2206), float4(-0.493, 0.724, -0.482, 0), float4(-0.231, 0.425, 0.875, 0),
    float4(0.8376, -0.7224, 0.3937, 0.2158), float4(-0.597, 0.717, -0.360, 0), float4(-0.147, 0.344, 0.928, 0),
    float4(0.9722, -0.7732, 0.3085, 0.2068), float4(-0.672, 0.690, -0.268, 0), float4(-0.087, 0.286, 0.954, 0),
    float4(1.0535, -0.8028, 0.2026, 0.1978), float4(-0.722, 0.667, -0.185, 0), float4(-0.034, 0.232, 0.972, 0),
    float4(1.0637, -0.7962, 0.0816, 0.1888), float4(-0.751, 0.655, -0.088, 0), float4(0.028, 0.165, 0.986, 0),
    float4(1.0122, -0.7453, -0.0301, 0.1798), float4(-0.769, 0.639, 0.027, 0), float4(0.104, 0.083, 0.991, 0),
    float4(0.9324, -0.6515, -0.1038, 0.1686), float4(-0.793, 0.594, 0.136, 0), float4(0.172, 0.003, 0.985, 0),
    float4(0.8685, -0.5265, -0.1236, 0.1567), float4(-0.842, 0.501, 0.199, 0), float4(0.201, -0.051, 0.978, 0),
    float4(0.8583, -0.3902, -0.0931, 0.1525), float4(-0.912, 0.368, 0.183, 0), float4(0.169, -0.070, 0.983, 0),
    float4(0.9200, -0.2641, -0.0304, 0.1534), float4(-0.969, 0.227, 0.099, 0), float4(0.085, -0.069, 0.994, 0),
    float4(1.0496, -0.1631, 0.0446, 0.1629), float4(-0.993, 0.118, -0.003, 0), float4(-0.011, -0.067, 0.998, 0),
    float4(1.2282, -0.0902, 0.1213, 0.1900), float4(-0.996, 0.052, -0.078, 0), float4(-0.082, -0.069, 0.994, 0),
    float4(1.4325, -0.0361, 0.2018, 0.2459), float4(-0.993, 0.015, -0.119, 0), float4(-0.120, -0.073, 0.990, 0),
    float4(1.6391, 0.0146, 0.2958, 0.3247), float4(-0.990, -0.009, -0.139, 0), float4(-0.138, -0.079, 0.987, 0),
    float4(1.8232, 0.0755, 0.4108, 0.4071), float4(-0.987, -0.027, -0.158, 0), float4(-0.155, -0.086, 0.984, 0),
    float4(1.9559, 0.1520, 0.5436, 0.4589), float4(-0.981, -0.043, -0.191, 0), float4(-0.186, -0.095, 0.978, 0),
    float4(2.0101, 0.2384, 0.6782, 0.4885), float4(-0.968, -0.062, -0.244, 0), float4(-0.237, -0.105, 0.966, 0),
    float4(1.9704, 0.3210, 0.7910, 0.4935), float4(-0.946, -0.095, -0.311, 0), float4(-0.300, -0.118, 0.947, 0),
    float4(1.8430, 0.3846, 0.8611, 0.4700), float4(-0.915, -0.141, -0.379, 0), float4(-0.362, -0.131, 0.923, 0),
    float4(1.6528, 0.4194, 0.8790, 0.4158), float4(-0.882, -0.188, -0.433, 0), float4(-0.412, -0.143, 0.900, 0),
    float4(1.4312, 0.4257, 0.8490, 0.3386), float4(-0.852, -0.227, -0.471, 0), float4(-0.446, -0.153, 0.882, 0),
    float4(1.2027, 0.4154, 0.7863, 0.2578), float4(-0.825, -0.267, -0.499, 0), float4(-0.472, -0.161, 0.867, 0),
    // stone
    float4(1.0529, 0.8851, -0.0191, 0.1789), float4(-0.801, -0.597, 0.053, 0), float4(0.063, 0.004, 0.998, 0),
    float4(0.8802, 0.8002, 0.0379, 0.1292), float4(-0.787, -0.616, 0.028, 0), float4(0.040, -0.006, 0.999, 0),
    float4(0.7159, 0.7223, 0.0610, 0.0942), float4(-0.761, -0.649, 0.021, 0), float4(0.033, -0.005, 0.999, 0),
    float4(0.5697, 0.6765, 0.0653, 0.0790), float4(-0.705, -0.709, 0.019, 0), float4(0.030, -0.002, 1.000, 0),
    float4(0.4515, 0.6852, 0.0647, 0.0779), float4(-0.615, -0.789, 0.012, 0), float4(0.024, -0.004, 1.000, 0),
    float4(0.3693, 0.7579, 0.0638, 0.0769), float4(-0.508, -0.861, -0.002, 0), float4(0.015, -0.012, 1.000, 0),
    float4(0.3252, 0.8834, 0.0543, 0.0823), float4(-0.417, -0.909, -0.014, 0), float4(0.007, -0.019, 1.000, 0),
    float4(0.3145, 1.0315, 0.0185, 0.1023), float4(-0.354, -0.935, -0.008, 0), float4(0.008, -0.012, 1.000, 0),
    float4(0.3281, 1.1638, -0.0611, 0.1398), float4(-0.312, -0.949, 0.031, 0), float4(0.021, 0.025, 0.999, 0),
    float4(0.3561, 1.2479, -0.1920, 0.1859), float4(-0.283, -0.953, 0.107, 0), float4(0.047, 0.098, 0.994, 0),
    float4(0.3900, 1.2668, -0.3665, 0.2164), float4(-0.269, -0.939, 0.215, 0), float4(0.083, 0.199, 0.976, 0),
    float4(0.4218, 1.2195, -0.5641, 0.2305), float4(-0.276, -0.899, 0.340, 0), float4(0.124, 0.317, 0.940, 0),
    float4(0.4435, 1.1169, -0.7565, 0.2307), float4(-0.300, -0.832, 0.467, 0), float4(0.167, 0.436, 0.884, 0),
    float4(0.4467, 0.9765, -0.9140, 0.2255), float4(-0.331, -0.743, 0.582, 0), float4(0.207, 0.545, 0.813, 0),
    float4(0.4254, 0.8186, -1.0107, 0.2056), float4(-0.354, -0.647, 0.675, 0), float4(0.241, 0.635, 0.734, 0),
    float4(0.3775, 0.6641, -1.0320, 0.1684), float4(-0.357, -0.563, 0.745, 0), float4(0.266, 0.703, 0.659, 0),
    float4(0.3057, 0.5316, -0.9823, 0.1225), float4(-0.334, -0.507, 0.795, 0), float4(0.282, 0.751, 0.597, 0),
    float4(0.2159, 0.4353, -0.8881, 0.0922), float4(-0.279, -0.484, 0.829, 0), float4(0.288, 0.782, 0.553, 0),
    float4(0.1147, 0.3829, -0.7912, 0.0784), float4(-0.185, -0.492, 0.851, 0), float4(0.289, 0.800, 0.525, 0),
    float4(0.0088, 0.3758, -0.7326, 0.0792), float4(-0.058, -0.512, 0.857, 0), float4(0.289, 0.814, 0.505, 0),
    float4(-0.0959, 0.4114, -0.7352, 0.0801), float4(0.070, -0.526, 0.848, 0), float4(0.290, 0.824, 0.487, 0),
    float4(-0.1951, 0.4858, -0.7963, 0.0868), float4(0.165, -0.533, 0.830, 0), float4(0.292, 0.830, 0.475, 0),
    float4(-0.2866, 0.5960, -0.8927, 0.1106), float4(0.220, -0.543, 0.810, 0), float4(0.298, 0.828, 0.474, 0),
    float4(-0.3700, 0.7407, -0.9936, 0.1590), float4(0.249, -0.559, 0.791, 0), float4(0.308, 0.820, 0.483, 0),
    float4(-0.4449, 0.9168, -1.0710, 0.2220), float4(0.269, -0.578, 0.770, 0), float4(0.320, 0.808, 0.495, 0),
    float4(-0.5086, 1.1135, -1.1039, 0.2891), float4(0.293, -0.599, 0.745, 0), float4(0.334, 0.794, 0.507, 0),
    float4(-0.5551, 1.3086, -1.0791, 0.3389), float4(0.317, -0.631, 0.708, 0), float4(0.353, 0.772, 0.529, 0),
    float4(-0.5773, 1.4705, -0.9927, 0.3639), float4(0.333, -0.684, 0.650, 0), float4(0.382, 0.728, 0.570, 0),
    float4(-0.5717, 1.5686, -0.8534, 0.3647), float4(0.335, -0.756, 0.563, 0), float4(0.420, 0.655, 0.628, 0),
    float4(-0.5408, 1.5857, -0.6829, 0.3423), float4(0.326, -0.829, 0.455, 0), float4(0.461, 0.559, 0.689, 0),
    float4(-0.4928, 1.5230, -0.5091, 0.2952), float4(0.311, -0.885, 0.348, 0), float4(0.495, 0.463, 0.736, 0),
    float4(-0.4384, 1.3975, -0.3566, 0.2326), float4(0.299, -0.917, 0.266, 0), float4(0.515, 0.389, 0.764, 0),
    float4(-0.3881, 1.2335, -0.2371, 0.1661), float4(0.296, -0.930, 0.217, 0), float4(0.523, 0.348, 0.778, 0),
    float4(-0.3517, 1.0569, -0.1481, 0.1158), float4(0.313, -0.931, 0.188, 0), float4(0.523, 0.335, 0.784, 0),
    float4(-0.3396, 0.8939, -0.0771, 0.0904), float4(0.362, -0.919, 0.156, 0), float4(0.519, 0.337, 0.786, 0),
    float4(-0.3623, 0.7701, -0.0106, 0.0835), float4(0.446, -0.890, 0.098, 0), float4(0.514, 0.344, 0.786, 0),
    float4(-0.4270, 0.7050, 0.0572, 0.0825), float4(0.539, -0.842, 0.016, 0), float4(0.513, 0.344, 0.786, 0),
    float4(-0.5336, 0.7025, 0.1199, 0.0816), float4(0.608, -0.791, -0.064, 0), float4(0.519, 0.336, 0.786, 0),
    float4(-0.6714, 0.7468, 0.1599, 0.0956), float4(0.647, -0.754, -0.112, 0), float4(0.523, 0.332, 0.785, 0),
    float4(-0.8214, 0.8075, 0.1562, 0.1260), float4(0.676, -0.728, -0.113, 0), float4(0.508, 0.351, 0.787, 0),
    float4(-0.9606, 0.8519, 0.0938, 0.1717), float4(0.712, -0.700, -0.063, 0), float4(0.464, 0.401, 0.790, 0),
    float4(-1.0686, 0.8572, -0.0291, 0.2093), float4(0.749, -0.662, 0.030, 0), float4(0.389, 0.476, 0.789, 0),
    float4(-1.1329, 0.8156, -0.1994, 0.2293), float4(0.774, -0.615, 0.150, 0), float4(0.293, 0.559, 0.776, 0),
    float4(-1.1495, 0.7314, -0.3929, 0.2347), float4(0.781, -0.560, 0.277, 0), float4(0.191, 0.636, 0.748, 0),
    float4(-1.1218, 0.6161, -0.5795, 0.2340), float4(0.773, -0.497, 0.395, 0), float4(0.089, 0.701, 0.708, 0),
    float4(-1.0573, 0.4845, -0.7287, 0.2194), float4(0.756, -0.426, 0.497, 0), float4(-0.009, 0.753, 0.658, 0),
    float4(-0.9661, 0.3524, -0.8149, 0.1884), float4(0.735, -0.353, 0.579, 0), float4(-0.097, 0.790, 0.605, 0),
    float4(-0.8613, 0.2337, -0.8248, 0.1419), float4(0.716, -0.285, 0.637, 0), float4(-0.170, 0.814, 0.555, 0),
    float4(-0.7608, 0.1367, -0.7635, 0.1037), float4(0.707, -0.229, 0.669, 0), float4(-0.222, 0.826, 0.518, 0),
    float4(-0.6863, 0.0611, -0.6558, 0.0831), float4(0.724, -0.180, 0.666, 0), float4(-0.252, 0.829, 0.498, 0),
    float4(-0.6589, -0.0004, -0.5384, 0.0770), float4(0.773, -0.123, 0.622, 0), float4(-0.265, 0.829, 0.493, 0),
    float4(-0.6917, -0.0570, -0.4452, 0.0779), float4(0.837, -0.051, 0.544, 0), float4(-0.270, 0.827, 0.492, 0),
    float4(-0.7857, -0.1135, -0.3937, 0.0788), float4(0.888, 0.029, 0.459, 0), float4(-0.279, 0.827, 0.488, 0),
    float4(-0.9309, -0.1677, -0.3801, 0.0914), float4(0.915, 0.094, 0.393, 0), float4(-0.291, 0.827, 0.480, 0),
    float4(-1.1126, -0.2116, -0.3841, 0.1275), float4(0.927, 0.129, 0.352, 0), float4(-0.296, 0.829, 0.475, 0),
    float4(-1.3146, -0.2347, -0.3803, 0.1789), float4(0.936, 0.137, 0.325, 0), float4(-0.286, 0.833, 0.474, 0),
    float4(-1.5187, -0.2282, -0.3475, 0.2553), float4(0.945, 0.127, 0.300, 0), float4(-0.264, 0.839, 0.476, 0),
    float4(-1.7003, -0.1876, -0.2752, 0.3092), float4(0.958, 0.112, 0.265, 0), float4(-0.232, 0.846, 0.480, 0),
    float4(-1.8291, -0.1159, -0.1650, 0.3480), float4(0.974, 0.091, 0.209, 0), float4(-0.184, 0.855, 0.485, 0),
    float4(-1.8783, -0.0237, -0.0301, 0.3628), float4(0.990, 0.058, 0.126, 0), float4(-0.114, 0.863, 0.493, 0),
    float4(-1.8367, 0.0728, 0.1096, 0.3528), float4(1.000, 0.006, 0.028, 0), float4(-0.019, 0.866, 0.499, 0),
    float4(-1.7146, 0.1562, 0.2328, 0.3180), float4(0.996, -0.060, -0.069, 0), float4(0.087, 0.862, 0.499, 0),
    float4(-1.5379, 0.2131, 0.3236, 0.2662), float4(0.981, -0.123, -0.148, 0), float4(0.180, 0.851, 0.494, 0),
    float4(-1.3367, 0.2369, 0.3754, 0.1896), float4(0.966, -0.166, -0.198, 0), float4(0.244, 0.838, 0.488, 0),
    float4(-1.1356, 0.2278, 0.3933, 0.1353), float4(0.956, -0.187, -0.226, 0), float4(0.276, 0.829, 0.487, 0),
    float4(-0.9525, 0.1918, 0.3938, 0.0953), float4(0.950, -0.183, -0.251, 0), float4(0.288, 0.824, 0.489, 0),
    float4(-0.8026, 0.1386, 0.4014, 0.0792), float4(0.940, -0.154, -0.304, 0), float4(0.293, 0.820, 0.491, 0),
    float4(-0.7006, 0.0787, 0.4393, 0.0764), float4(0.914, -0.098, -0.394, 0), float4(0.300, 0.817, 0.492, 0),
    float4(-0.6573, 0.0183, 0.5184, 0.0747), float4(0.865, -0.030, -0.501, 0), float4(0.312, 0.814, 0.490, 0),
    float4(-0.6740, -0.0440, 0.6286, 0.0778), float4(0.807, 0.030, -0.590, 0), float4(0.326, 0.811, 0.486, 0),
    float4(-0.7400, -0.1159, 0.7403, 0.0941), float4(0.763, 0.074, -0.643, 0), float4(0.331, 0.809, 0.486, 0),
    float4(-0.8358, -0.2066, 0.8160, 0.1291), float4(0.746, 0.121, -0.654, 0), float4(0.313, 0.804, 0.505, 0),
    float4(-0.9404, -0.3192, 0.8262, 0.1764), float4(0.757, 0.186, -0.627, 0), float4(0.261, 0.793, 0.550, 0),
    float4(-1.0355, -0.4482, 0.7596, 0.2125), float4(0.784, 0.267, -0.561, 0), float4(0.178, 0.769, 0.614, 0),
    float4(-1.1075, -0.5812, 0.6249, 0.2302), float4(0.814, 0.349, -0.463, 0), float4(0.074, 0.729, 0.680, 0),
    float4(-1.1455, -0.7023, 0.4450, 0.2337), float4(0.837, 0.422, -0.350, 0), float4(-0.033, 0.676, 0.736, 0),
    float4(-1.1410, -0.7963, 0.2498, 0.2322), float4(0.845, 0.482, -0.231, 0), float4(-0.138, 0.614, 0.777, 0),
    float4(-1.0893, -0.8503, 0.0706, 0.2175), float4(0.838, 0.533, -0.114, 0), float4(-0.237, 0.545, 0.804, 0),
    float4(-0.9920, -0.8577, -0.0661, 0.1841), float4(0.818, 0.576, -0.003, 0), float4(-0.330, 0.472, 0.818, 0),
    float4(-0.8596, -0.8225, -0.1442, 0.1384), float4(0.786, 0.612, 0.092, 0), float4(-0.408, 0.400, 0.821, 0),
    float4(-0.7104, -0.7638, -0.1626, 0.1039), float4(0.741, 0.654, 0.153, 0), float4(-0.467, 0.338, 0.817, 0),
    float4(-0.5666, -0.7123, -0.1350, 0.0878), float4(0.674, 0.721, 0.164, 0), float4(-0.507, 0.290, 0.812, 0),
    float4(-0.4486, -0.7002, -0.0822, 0.0859), float4(0.574, 0.811, 0.117, 0), float4(-0.530, 0.259, 0.807, 0),
    float4(-0.3697, -0.7476, -0.0223, 0.0860), float4(0.455, 0.890, 0.032, 0), float4(-0.540, 0.247, 0.805, 0),
    float4(-0.3335, -0.8544, 0.0377, 0.0880), float4(0.359, 0.932, -0.052, 0), float4(-0.541, 0.253, 0.802, 0),
    float4(-0.3352, -1.0037, 0.1032, 0.1043), float4(0.312, 0.943, -0.113, 0), float4(-0.538, 0.274, 0.797, 0),
    float4(-0.3652, -1.1706, 0.1875, 0.1451), float4(0.305, 0.939, -0.157, 0), float4(-0.532, 0.304, 0.790, 0),
    float4(-0.4134, -1.3309, 0.3038, 0.2001), float4(0.314, 0.929, -0.194, 0), float4(-0.524, 0.340, 0.781, 0),
    float4(-0.4701, -1.4626, 0.4566, 0.2732), float4(0.325, 0.917, -0.233, 0), float4(-0.516, 0.378, 0.769, 0),
    float4(-0.5251, -1.5443, 0.6369, 0.3211), float4(0.332, 0.900, -0.282, 0), float4(-0.505, 0.422, 0.753, 0),
    float4(-0.5671, -1.5576, 0.8219, 0.3533), float4(0.337, 0.874, -0.350, 0), float4(-0.488, 0.480, 0.729, 0),
    float4(-0.5857, -1.4939, 0.9818, 0.3632), float4(0.337, 0.833, -0.438, 0), float4(-0.463, 0.552, 0.693, 0),
    float4(-0.5750, -1.3614, 1.0896, 0.3461), float4(0.335, 0.776, -0.535, 0), float4(-0.431, 0.631, 0.646, 0),
    float4(-0.5357, -1.1843, 1.1307, 0.3045), float4(0.332, 0.713, -0.618, 0), float4(-0.398, 0.699, 0.594, 0),
    float4(-0.4746, -0.9936, 1.1058, 0.2482), float4(0.329, 0.660, -0.675, 0), float4(-0.370, 0.748, 0.551, 0),
    float4(-0.3996, -0.8145, 1.0286, 0.1738), float4(0.322, 0.628, -0.709, 0), float4(-0.352, 0.774, 0.526, 0),
    float4(-0.3160, -0.6612, 0.9220, 0.1247), float4(0.303, 0.612, -0.731, 0), float4(-0.343, 0.785, 0.515, 0),
    float4(-0.2254, -0.5383, 0.8155, 0.0911), float4(0.263, 0.601, -0.755, 0), float4(-0.338, 0.790, 0.512, 0),
    float4(-0.1277, -0.4476, 0.7405, 0.0780), float4(0.196, 0.583, -0.789, 0), float4(-0.333, 0.796, 0.505, 0),
    float4(-0.0237, -0.3930, 0.7221, 0.0775), float4(0.106, 0.549, -0.829, 0), float4(-0.327, 0.806, 0.493, 0),
    float4(0.0831, -0.3807, 0.7674, 0.0770), float4(0.009, 0.508, -0.861, 0), float4(-0.323, 0.816, 0.479, 0),
    float4(0.1873, -0.4158, 0.8589, 0.0863), float4(-0.084, 0.477, -0.875, 0), float4(-0.320, 0.818, 0.477, 0),
    float4(0.2820, -0.4985, 0.9590, 0.1116), float4(-0.165, 0.473, -0.865, 0), float4(-0.316, 0.806, 0.501, 0),
    float4(0.3600, -0.6220, 1.0249, 0.1539), float4(-0.232, 0.505, -0.831, 0), float4(-0.306, 0.773, 0.555, 0),
    float4(0.4150, -0.7726, 1.0253, 0.1951), float4(-0.281, 0.571, -0.771, 0), float4(-0.287, 0.717, 0.635, 0),
    float4(0.4438, -0.9319, 0.9499, 0.2204), float4(-0.303, 0.659, -0.689, 0), float4(-0.259, 0.638, 0.725, 0),
    float4(0.4470, -1.0793, 0.8083, 0.2302), float4(-0.299, 0.750, -0.589, 0), float4(-0.227, 0.544, 0.808, 0),
    float4(0.4298, -1.1944, 0.6234, 0.2297), float4(-0.277, 0.832, -0.480, 0), float4(-0.192, 0.442, 0.876, 0),
    float4(0.3999, -1.2587, 0.4242, 0.2200), float4(-0.250, 0.896, -0.367, 0), float4(-0.158, 0.336, 0.929, 0),
    float4(0.3655, -1.2590, 0.2400, 0.1942), float4(-0.230, 0.939, -0.255, 0), float4(-0.124, 0.231, 0.965, 0),
    float4(0.3345, -1.1919, 0.0943, 0.1514), float4(-0.223, 0.962, -0.156, 0), float4(-0.093, 0.138, 0.986, 0),
    float4(0.3157, -1.0698, -0.0006, 0.1098), float4(-0.237, 0.968, -0.084, 0), float4(-0.070, 0.069, 0.995, 0),
    float4(0.3195, -0.9217, -0.0470, 0.0840), float4(-0.284, 0.958, -0.046, 0), float4(-0.055, 0.032, 0.998, 0),
    float4(0.3560, -0.7860, -0.0600, 0.0737), float4(-0.375, 0.926, -0.036, 0), float4(-0.049, 0.019, 0.999, 0),
    float4(0.4313, -0.6970, -0.0585, 0.0746), float4(-0.491, 0.870, -0.033, 0), float4(-0.046, 0.012, 0.999, 0),
    float4(0.5446, -0.6722, -0.0553, 0.0755), float4(-0.598, 0.801, -0.022, 0), float4(-0.041, -0.003, 0.999, 0),
    float4(0.6885, -0.7077, -0.0512, 0.0871), float4(-0.668, 0.744, -0.008, 0), float4(-0.035, -0.021, 0.999, 0),
    float4(0.8529, -0.7838, -0.0359, 0.1183), float4(-0.704, 0.711, -0.006, 0), float4(-0.038, -0.030, 0.999, 0),
    float4(1.0275, -0.8747, 0.0059, 0.1737), float4(-0.718, 0.695, -0.021, 0), float4(-0.056, -0.027, 0.998, 0),
    float4(1.2007, -0.9564, 0.0860, 0.2454), float4(-0.728, 0.684, -0.047, 0), float4(-0.082, -0.018, 0.996, 0),
    float4(1.3551, -1.0086, 0.2069, 0.3045), float4(-0.745, 0.663, -0.074, 0), float4(-0.108, -0.011, 0.994, 0),
    float4(1.4682, -1.0160, 0.3578, 0.3485), float4(-0.773, 0.625, -0.104, 0), float4(-0.136, -0.004, 0.991, 0),
    float4(1.5181, -0.9704, 0.5171, 0.3680), float4(-0.805, 0.573, -0.155, 0), float4(-0.180, 0.014, 0.984, 0),
    float4(1.4944, -0.8750, 0.6584, 0.3612), float4(-0.824, 0.513, -0.240, 0), float4(-0.250, 0.050, 0.967, 0),
    float4(1.4038, -0.7445, 0.7591, 0.3314), float4(-0.820, 0.455, -0.347, 0), float4(-0.342, 0.098, 0.935, 0),
    float4(1.2669, -0.6005, 0.8065, 0.2772), float4(-0.795, 0.406, -0.451, 0), float4(-0.431, 0.144, 0.891, 0),
    float4(1.1097, -0.4625, 0.7993, 0.2065), float4(-0.764, 0.372, -0.527, 0), float4(-0.498, 0.178, 0.849, 0),
    float4(0.9546, -0.3410, 0.7460, 0.1485), float4(-0.740, 0.353, -0.573, 0), float4(-0.540, 0.197, 0.818, 0),
    float4(0.8189, -0.2354, 0.6634, 0.1047), float4(-0.727, 0.327, -0.604, 0), float4(-0.567, 0.209, 0.796, 0),
    float4(0.7180, -0.1374, 0.5755, 0.0853), float4(-0.730, 0.260, -0.632, 0), float4(-0.593, 0.219, 0.775, 0),
    float4(0.6662, -0.0381, 0.5078, 0.0815), float4(-0.744, 0.132, -0.655, 0), float4(-0.620, 0.227, 0.751, 0),
    float4(0.6740, 0.0656, 0.4772, 0.0812), float4(-0.757, -0.028, -0.653, 0), float4(-0.640, 0.233, 0.732, 0),
    float4(0.7422, 0.1673, 0.4823, 0.0811), float4(-0.768, -0.158, -0.621, 0), float4(-0.640, 0.238, 0.731, 0),
    float4(0.8591, 0.2519, 0.5014, 0.0930), float4(-0.791, -0.226, -0.568, 0), float4(-0.611, 0.247, 0.752, 0),
    float4(1.0032, 0.3016, 0.5028, 0.1240), float4(-0.833, -0.241, -0.499, 0), float4(-0.551, 0.263, 0.792, 0),
    float4(1.1496, 0.3024, 0.4596, 0.1684), float4(-0.884, -0.222, -0.411, 0), float4(-0.461, 0.282, 0.841, 0),
    float4(1.2764, 0.2504, 0.3615, 0.2067), float4(-0.935, -0.175, -0.307, 0), float4(-0.348, 0.300, 0.888, 0),
    float4(1.3676, 0.1535, 0.2160, 0.2271), float4(-0.975, -0.101, -0.196, 0), float4(-0.218, 0.314, 0.924, 0),
    float4(1.4130, 0.0293, 0.0425, 0.2324), float4(-0.996, -0.013, -0.084, 0), float4(-0.084, 0.321, 0.943, 0),
    float4(1.4062, -0.0992, -0.1345, 0.2333), float4(-0.997, 0.075, 0.026, 0), float4(0.049, 0.321, 0.946, 0),
    float4(1.3456, -0.2081, -0.2902, 0.2223), float4(-0.980, 0.151, 0.132, 0), float4(0.174, 0.314, 0.933, 0),
    float4(1.2356, -0.2775, -0.4043, 0.1923), float4(-0.950, 0.212, 0.230, 0), float4(0.287, 0.303, 0.909, 0),
    float4(1.0903, -0.2958, -0.4661, 0.1487), float4(-0.915, 0.255, 0.314, 0), float4(0.382, 0.290, 0.877, 0),
    float4(0.9335, -0.2627, -0.4810, 0.1114), float4(-0.882, 0.268, 0.386, 0), float4(0.455, 0.279, 0.846, 0),
    float4(0.7950, -0.1880, -0.4703, 0.0919), float4(-0.862, 0.229, 0.452, 0), float4(0.503, 0.272, 0.821, 0),
    float4(0.7025, -0.0884, -0.4637, 0.0876), float4(-0.851, 0.122, 0.511, 0), float4(0.524, 0.270, 0.807, 0),
    float4(0.6736, 0.0194, -0.4856, 0.0881), float4(-0.833, -0.026, 0.553, 0), float4(0.527, 0.270, 0.806, 0),
    float4(0.7106, 0.1246, -0.5445, 0.0885), float4(-0.806, -0.158, 0.571, 0), float4(0.521, 0.268, 0.810, 0),
    float4(0.8034, 0.2257, -0.6309, 0.1028), float4(-0.784, -0.238, 0.573, 0), float4(0.515, 0.265, 0.815, 0),
    float4(0.9358, 0.3292, -0.7232, 0.1419), float4(-0.776, -0.271, 0.569, 0), float4(0.510, 0.261, 0.820, 0),
    float4(1.0906, 0.4438, -0.7966, 0.1961), float4(-0.780, -0.285, 0.557, 0), float4(0.499, 0.254, 0.829, 0),
    float4(1.2493, 0.5731, -0.8290, 0.2683), float4(-0.790, -0.299, 0.536, 0), float4(0.480, 0.242, 0.843, 0),
    float4(1.3895, 0.7101, -0.8056, 0.3164), float4(-0.802, -0.324, 0.502, 0), float4(0.450, 0.224, 0.864, 0),
    float4(1.4860, 0.8382, -0.7221, 0.3494), float4(-0.814, -0.365, 0.452, 0), float4(0.406, 0.199, 0.892, 0),
    float4(1.5175, 0.9369, -0.5876, 0.3627), float4(-0.823, -0.421, 0.381, 0), float4(0.343, 0.165, 0.925, 0),
    float4(1.4761, 0.9907, -0.4237, 0.3479), float4(-0.826, -0.483, 0.291, 0), float4(0.266, 0.121, 0.956, 0),
    float4(1.3708, 0.9951, -0.2590, 0.3084), float4(-0.821, -0.537, 0.193, 0), float4(0.183, 0.073, 0.980, 0),
    float4(1.2222, 0.9557, -0.1189, 0.2526), float4(-0.812, -0.574, 0.109, 0), float4(0.111, 0.031, 0.993, 0),
    // bloom
    float4(0.9886, 0.8686, -0.0269, 0.2220), float4(-0.746, -0.663, -0.063, 0), float4(0.032, -0.131, 0.991, 0),
    float4(0.7885, 0.8464, 0.0280, 0.2010), float4(-0.655, -0.741, -0.149, 0), float4(-0.024, -0.177, 0.984, 0),
    float4(0.6117, 0.8843, 0.0543, 0.1962), float4(-0.525, -0.831, -0.184, 0), float4(-0.047, -0.188, 0.981, 0),
    float4(0.4739, 0.9761, 0.0424, 0.1964), float4(-0.391, -0.908, -0.150, 0), float4(-0.036, -0.148, 0.988, 0),
    float4(0.3871, 1.0944, -0.0202, 0.2001), float4(-0.296, -0.954, -0.058, 0), float4(-0.003, -0.060, 0.998, 0),
    float4(0.3539, 1.2001, -0.1393, 0.2139), float4(-0.259, -0.964, 0.065, 0), float4(0.041, 0.056, 0.998, 0),
    float4(0.3646, 1.2566, -0.3078, 0.2186), float4(-0.266, -0.944, 0.197, 0), float4(0.088, 0.180, 0.980, 0),
    float4(0.3997, 1.2417, -0.5046, 0.2190), float4(-0.286, -0.901, 0.326, 0), float4(0.136, 0.298, 0.945, 0),
    float4(0.4364, 1.1531, -0.7000, 0.2184), float4(-0.297, -0.843, 0.448, 0), float4(0.183, 0.410, 0.894, 0),
    float4(0.4530, 1.0074, -0.8631, 0.2179), float4(-0.297, -0.771, 0.563, 0), float4(0.229, 0.515, 0.826, 0),
    float4(0.4328, 0.8344, -0.9706, 0.2172), float4(-0.291, -0.679, 0.674, 0), float4(0.275, 0.615, 0.739, 0),
    float4(0.3661, 0.6704, -1.0141, 0.2129), float4(-0.276, -0.567, 0.776, 0), float4(0.320, 0.707, 0.630, 0),
    float4(0.2535, 0.5495, -1.0039, 0.1986), float4(-0.236, -0.457, 0.858, 0), float4(0.358, 0.779, 0.514, 0),
    float4(0.1067, 0.4955, -0.9668, 0.1933), float4(-0.154, -0.395, 0.906, 0), float4(0.384, 0.821, 0.423, 0),
    float4(-0.0543, 0.5163, -0.9357, 0.1924), float4(-0.034, -0.408, 0.912, 0), float4(0.399, 0.832, 0.386, 0),
    float4(-0.2087, 0.6060, -0.9374, 0.1950), float4(0.099, -0.478, 0.873, 0), float4(0.413, 0.818, 0.401, 0),
    float4(-0.3424, 0.7508, -0.9813, 0.2123), float4(0.203, -0.556, 0.806, 0), float4(0.431, 0.790, 0.436, 0),
    float4(-0.4515, 0.9364, -1.0560, 0.2541), float4(0.263, -0.608, 0.749, 0), float4(0.448, 0.764, 0.463, 0),
    float4(-0.5381, 1.1484, -1.1346, 0.3268), float4(0.290, -0.634, 0.717, 0), float4(0.462, 0.749, 0.475, 0),
    float4(-0.6040, 1.3671, -1.1837, 0.3842), float4(0.306, -0.647, 0.699, 0), float4(0.473, 0.740, 0.478, 0),
    float4(-0.6466, 1.5641, -1.1758, 0.4134), float4(0.320, -0.667, 0.672, 0), float4(0.489, 0.724, 0.486, 0),
    float4(-0.6599, 1.7055, -1.0995, 0.4227), float4(0.332, -0.708, 0.623, 0), float4(0.514, 0.690, 0.511, 0),
    float4(-0.6403, 1.7643, -0.9637, 0.4210), float4(0.334, -0.766, 0.549, 0), float4(0.547, 0.632, 0.549, 0),
    float4(-0.5912, 1.7316, -0.7929, 0.4039), float4(0.326, -0.825, 0.461, 0), float4(0.582, 0.560, 0.590, 0),
    float4(-0.5247, 1.6203, -0.6147, 0.3623), float4(0.313, -0.877, 0.365, 0), float4(0.615, 0.480, 0.625, 0),
    float4(-0.4593, 1.4589, -0.4474, 0.2898), float4(0.303, -0.918, 0.257, 0), float4(0.644, 0.396, 0.655, 0),
    float4(-0.4161, 1.2807, -0.2951, 0.2325), float4(0.305, -0.944, 0.127, 0), float4(0.669, 0.308, 0.677, 0),
    float4(-0.4146, 1.1156, -0.1543, 0.2036), float4(0.333, -0.943, -0.019, 0), float4(0.686, 0.229, 0.691, 0),
    float4(-0.4671, 0.9856, -0.0262, 0.1945), float4(0.398, -0.904, -0.154, 0), float4(0.689, 0.184, 0.701, 0),
    float4(-0.5736, 0.9014, 0.0758, 0.1936), float4(0.493, -0.838, -0.233, 0), float4(0.668, 0.194, 0.718, 0),
    float4(-0.7194, 0.8600, 0.1280, 0.1960), float4(0.595, -0.770, -0.230, 0), float4(0.617, 0.254, 0.745, 0),
    float4(-0.8777, 0.8459, 0.1087, 0.2065), float4(0.683, -0.714, -0.154, 0), float4(0.534, 0.344, 0.772, 0),
    float4(-1.0176, 0.8358, 0.0102, 0.2151), float4(0.747, -0.663, -0.037, 0), float4(0.431, 0.443, 0.786, 0),
    float4(-1.1133, 0.8072, -0.1546, 0.2169), float4(0.787, -0.609, 0.097, 0), float4(0.318, 0.535, 0.782, 0),
    float4(-1.1503, 0.7458, -0.3549, 0.2163), float4(0.799, -0.553, 0.237, 0), float4(0.201, 0.617, 0.761, 0),
    float4(-1.1280, 0.6481, -0.5510, 0.2157), float4(0.782, -0.495, 0.380, 0), float4(0.082, 0.685, 0.724, 0),
    float4(-1.0591, 0.5200, -0.7040, 0.2152), float4(0.748, -0.424, 0.511, 0), float4(-0.037, 0.742, 0.670, 0),
    float4(-0.9684, 0.3732, -0.7856, 0.2123), float4(0.718, -0.331, 0.612, 0), float4(-0.152, 0.783, 0.603, 0),
    float4(-0.8879, 0.2222, -0.7862, 0.2012), float4(0.716, -0.217, 0.664, 0), float4(-0.252, 0.807, 0.534, 0),
    float4(-0.8494, 0.0814, -0.7185, 0.1920), float4(0.749, -0.091, 0.656, 0), float4(-0.323, 0.815, 0.481, 0),
    float4(-0.8755, -0.0379, -0.6127, 0.1897), float4(0.812, 0.027, 0.583, 0), float4(-0.355, 0.816, 0.457, 0),
    float4(-0.9735, -0.1286, -0.5041, 0.1918), float4(0.879, 0.111, 0.465, 0), float4(-0.346, 0.818, 0.460, 0),
    float4(-1.1362, -0.1885, -0.4176, 0.2037), float4(0.926, 0.150, 0.345, 0), float4(-0.311, 0.824, 0.475, 0),
    float4(-1.3469, -0.2182, -0.3581, 0.2374), float4(0.953, 0.159, 0.260, 0), float4(-0.271, 0.829, 0.489, 0),
    float4(-1.5827, -0.2182, -0.3117, 0.3000), float4(0.964, 0.159, 0.214, 0), float4(-0.248, 0.832, 0.497, 0),
    float4(-1.8140, -0.1889, -0.2565, 0.3690), float4(0.968, 0.163, 0.192, 0), float4(-0.240, 0.832, 0.500, 0),
    float4(-2.0047, -0.1322, -0.1763, 0.4082), float4(0.972, 0.161, 0.169, 0), float4(-0.225, 0.834, 0.503, 0),
    float4(-2.1179, -0.0543, -0.0698, 0.4229), float4(0.983, 0.135, 0.127, 0), float4(-0.181, 0.841, 0.510, 0),
    float4(-2.1283, 0.0331, 0.0495, 0.4237), float4(0.995, 0.080, 0.063, 0), float4(-0.101, 0.849, 0.518, 0),
    float4(-2.0337, 0.1150, 0.1602, 0.4107), float4(1.000, 0.006, -0.011, 0), float4(0.000, 0.853, 0.522, 0),
    float4(-1.8559, 0.1785, 0.2454, 0.3759), float4(0.994, -0.071, -0.080, 0), float4(0.103, 0.849, 0.519, 0),
    float4(-1.6307, 0.2150, 0.3022, 0.3122), float4(0.979, -0.146, -0.142, 0), float4(0.199, 0.837, 0.510, 0),
    float4(-1.3948, 0.2214, 0.3434, 0.2422), float4(0.954, -0.210, -0.215, 0), float4(0.292, 0.818, 0.496, 0),
    float4(-1.1781, 0.1974, 0.3914, 0.2018), float4(0.916, -0.252, -0.313, 0), float4(0.381, 0.792, 0.477, 0),
    float4(-1.0038, 0.1436, 0.4651, 0.1861), float4(0.863, -0.248, -0.440, 0), float4(0.453, 0.765, 0.458, 0),
    float4(-0.8893, 0.0609, 0.5673, 0.1822), float4(0.801, -0.178, -0.572, 0), float4(0.490, 0.745, 0.453, 0),
    float4(-0.8445, -0.0487, 0.6792, 0.1832), float4(0.743, -0.054, -0.667, 0), float4(0.482, 0.734, 0.478, 0),
    float4(-0.8666, -0.1799, 0.7669, 0.1895), float4(0.714, 0.084, -0.696, 0), float4(0.436, 0.724, 0.534, 0),
    float4(-0.9379, -0.3242, 0.7957, 0.2053), float4(0.722, 0.203, -0.662, 0), float4(0.360, 0.706, 0.609, 0),
    float4(-1.0294, -0.4697, 0.7449, 0.2114), float4(0.756, 0.296, -0.583, 0), float4(0.266, 0.676, 0.688, 0),
    float4(-1.1090, -0.6032, 0.6159, 0.2142), float4(0.796, 0.374, -0.476, 0), float4(0.158, 0.631, 0.760, 0),
    float4(-1.1494, -0.7116, 0.4312, 0.2170), float4(0.823, 0.447, -0.352, 0), float4(0.040, 0.571, 0.820, 0),
    float4(-1.1334, -0.7864, 0.2270, 0.2197), float4(0.826, 0.518, -0.221, 0), float4(-0.082, 0.498, 0.863, 0),
    float4(-1.0568, -0.8273, 0.0441, 0.2214), float4(0.805, 0.586, -0.088, 0), float4(-0.204, 0.414, 0.887, 0),
    float4(-0.9289, -0.8445, -0.0822, 0.2179), float4(0.754, 0.656, 0.036, 0), float4(-0.322, 0.322, 0.890, 0),
    float4(-0.7726, -0.8580, -0.1312, 0.2048), float4(0.666, 0.736, 0.121, 0), float4(-0.420, 0.236, 0.876, 0),
    float4(-0.6183, -0.8913, -0.1028, 0.2016), float4(0.552, 0.824, 0.132, 0), float4(-0.480, 0.185, 0.857, 0),
    float4(-0.4960, -0.9626, -0.0143, 0.2015), float4(0.439, 0.896, 0.059, 0), float4(-0.501, 0.190, 0.844, 0),
    float4(-0.4254, -1.0793, 0.1097, 0.2063), float4(0.359, 0.932, -0.058, 0), float4(-0.499, 0.244, 0.832, 0),
    float4(-0.4113, -1.2349, 0.2509, 0.2277), float4(0.320, 0.933, -0.164, 0), float4(-0.489, 0.311, 0.815, 0),
    float4(-0.4442, -1.4110, 0.4032, 0.2754), float4(0.314, 0.921, -0.232, 0), float4(-0.482, 0.365, 0.796, 0),
    float4(-0.5057, -1.5797, 0.5687, 0.3542), float4(0.321, 0.908, -0.271, 0), float4(-0.480, 0.402, 0.779, 0),
    float4(-0.5739, -1.7073, 0.7457, 0.4023), float4(0.326, 0.895, -0.305, 0), float4(-0.480, 0.435, 0.762, 0),
    float4(-0.6290, -1.7628, 0.9205, 0.4238), float4(0.323, 0.878, -0.353, 0), float4(-0.477, 0.474, 0.740, 0),
    float4(-0.6568, -1.7277, 1.0677, 0.4277), float4(0.315, 0.851, -0.420, 0), float4(-0.469, 0.525, 0.711, 0),
    float4(-0.6515, -1.6053, 1.1612, 0.4206), float4(0.311, 0.811, -0.496, 0), float4(-0.455, 0.585, 0.671, 0),
    float4(-0.6155, -1.4190, 1.1874, 0.3970), float4(0.314, 0.758, -0.571, 0), float4(-0.436, 0.650, 0.623, 0),
    float4(-0.5551, -1.2024, 1.1521, 0.3471), float4(0.318, 0.696, -0.644, 0), float4(-0.413, 0.713, 0.567, 0),
    float4(-0.4743, -0.9865, 1.0785, 0.2660), float4(0.312, 0.620, -0.720, 0), float4(-0.385, 0.775, 0.501, 0),
    float4(-0.3726, -0.7929, 0.9987, 0.2156), float4(0.278, 0.532, -0.800, 0), float4(-0.354, 0.831, 0.429, 0),
    float4(-0.2472, -0.6364, 0.9424, 0.1919), float4(0.200, 0.439, -0.876, 0), float4(-0.325, 0.873, 0.363, 0),
    float4(-0.0995, -0.5307, 0.9268, 0.1858), float4(0.076, 0.367, -0.927, 0), float4(-0.302, 0.895, 0.329, 0),
    float4(0.0598, -0.4896, 0.9496, 0.1865), float4(-0.062, 0.345, -0.937, 0), float4(-0.285, 0.893, 0.348, 0),
    float4(0.2116, -0.5220, 0.9894, 0.1904), float4(-0.172, 0.383, -0.907, 0), float4(-0.264, 0.869, 0.418, 0),
    float4(0.3355, -0.6243, 1.0139, 0.2037), float4(-0.238, 0.468, -0.851, 0), float4(-0.235, 0.822, 0.518, 0),
    float4(0.4169, -0.7775, 0.9924, 0.2124), float4(-0.274, 0.572, -0.773, 0), float4(-0.199, 0.752, 0.628, 0),
    float4(0.4519, -0.9507, 0.9083, 0.2139), float4(-0.294, 0.675, -0.677, 0), float4(-0.158, 0.664, 0.731, 0),
    float4(0.4468, -1.1088, 0.7637, 0.2124), float4(-0.298, 0.767, -0.568, 0), float4(-0.116, 0.562, 0.819, 0),
    float4(0.4155, -1.2203, 0.5774, 0.2110), float4(-0.281, 0.848, -0.450, 0), float4(-0.072, 0.449, 0.891, 0),
    float4(0.3767, -1.2638, 0.3779, 0.2087), float4(-0.255, 0.913, -0.319, 0), float4(-0.027, 0.323, 0.946, 0),
    float4(0.3522, -1.2333, 0.1952, 0.2034), float4(-0.247, 0.952, -0.181, 0), float4(0.017, 0.191, 0.981, 0),
    float4(0.3623, -1.1421, 0.0536, 0.1886), float4(-0.283, 0.958, -0.053, 0), float4(0.055, 0.071, 0.996, 0),
    float4(0.4211, -1.0210, -0.0343, 0.1784), float4(-0.374, 0.927, 0.041, 0), float4(0.081, -0.012, 0.997, 0),
    float4(0.5312, -0.9093, -0.0686, 0.1755), float4(-0.504, 0.860, 0.081, 0), float4(0.084, -0.044, 0.995, 0),
    float4(0.6844, -0.8409, -0.0590, 0.1771), float4(-0.632, 0.772, 0.064, 0), float4(0.061, -0.033, 0.998, 0),
    float4(0.8664, -0.8326, -0.0164, 0.1879), float4(-0.723, 0.690, 0.016, 0), float4(0.020, -0.002, 1.000, 0),
    float4(1.0632, -0.8794, 0.0529, 0.2195), float4(-0.772, 0.635, -0.033, 0), float4(-0.020, 0.027, 0.999, 0),
    float4(1.2627, -0.9588, 0.1489, 0.2792), float4(-0.794, 0.605, -0.059, 0), float4(-0.043, 0.041, 0.998, 0),
    float4(1.4504, -1.0393, 0.2732, 0.3528), float4(-0.805, 0.589, -0.068, 0), float4(-0.053, 0.043, 0.998, 0),
    float4(1.6050, -1.0900, 0.4205, 0.3954), float4(-0.814, 0.575, -0.083, 0), float4(-0.068, 0.048, 0.997, 0),
    float4(1.7002, -1.0895, 0.5748, 0.4141), float4(-0.821, 0.556, -0.130, 0), float4(-0.109, 0.070, 0.992, 0),
    float4(1.7146, -1.0314, 0.7115, 0.4183), float4(-0.823, 0.527, -0.212, 0), float4(-0.180, 0.111, 0.977, 0),
    float4(1.6430, -0.9253, 0.8069, 0.4100), float4(-0.814, 0.491, -0.309, 0), float4(-0.265, 0.160, 0.951, 0),
    float4(1.5009, -0.7902, 0.8482, 0.3808), float4(-0.794, 0.458, -0.401, 0), float4(-0.345, 0.204, 0.916, 0),
    float4(1.3197, -0.6436, 0.8382, 0.3237), float4(-0.767, 0.425, -0.481, 0), float4(-0.415, 0.242, 0.877, 0),
    float4(1.1362, -0.4928, 0.7925, 0.2525), float4(-0.742, 0.379, -0.554, 0), float4(-0.481, 0.275, 0.833, 0),
    float4(0.9842, -0.3355, 0.7317, 0.2124), float4(-0.725, 0.298, -0.621, 0), float4(-0.544, 0.306, 0.782, 0),
    float4(0.8901, -0.1692, 0.6722, 0.1962), float4(-0.726, 0.167, -0.667, 0), float4(-0.596, 0.330, 0.732, 0),
    float4(0.8694, -0.0017, 0.6203, 0.1929), float4(-0.748, 0.001, -0.664, 0), float4(-0.622, 0.347, 0.702, 0),
    float4(0.9227, 0.1456, 0.5707, 0.1937), float4(-0.786, -0.150, -0.600, 0), float4(-0.608, 0.362, 0.706, 0),
    float4(1.0337, 0.2446, 0.5098, 0.1995), float4(-0.835, -0.235, -0.497, 0), float4(-0.550, 0.384, 0.742, 0),
    float4(1.1724, 0.2735, 0.4231, 0.2132), float4(-0.890, -0.241, -0.388, 0), float4(-0.456, 0.409, 0.790, 0),
    float4(1.3022, 0.2276, 0.3024, 0.2172), float4(-0.940, -0.185, -0.285, 0), float4(-0.338, 0.433, 0.836, 0),
    float4(1.3909, 0.1213, 0.1507, 0.2183), float4(-0.979, -0.096, -0.181, 0), float4(-0.205, 0.449, 0.870, 0),
    float4(1.4172, -0.0163, -0.0183, 0.2194), float4(-0.998, 0.003, -0.066, 0), float4(-0.058, 0.456, 0.888, 0),
    float4(1.3748, -0.1492, -0.1851, 0.2205), float4(-0.994, 0.096, 0.059, 0), float4(0.096, 0.451, 0.887, 0),
    float4(1.2736, -0.2425, -0.3311, 0.2207), float4(-0.966, 0.173, 0.190, 0), float4(0.248, 0.435, 0.866, 0),
    float4(1.1385, -0.2700, -0.4448, 0.2160), float4(-0.920, 0.220, 0.324, 0), float4(0.389, 0.408, 0.826, 0),
    float4(1.0046, -0.2219, -0.5258, 0.2033), float4(-0.864, 0.210, 0.457, 0), float4(0.503, 0.376, 0.778, 0),
    float4(0.9083, -0.1076, -0.5843, 0.2004), float4(-0.816, 0.122, 0.565, 0), float4(0.569, 0.350, 0.745, 0),
    float4(0.8769, 0.0488, -0.6349, 0.2003), float4(-0.785, -0.024, 0.619, 0), float4(0.578, 0.329, 0.747, 0),
    float4(0.9209, 0.2202, -0.6894, 0.2059), float4(-0.774, -0.172, 0.610, 0), float4(0.547, 0.305, 0.780, 0),
    float4(1.0345, 0.3884, -0.7497, 0.2286), float4(-0.776, -0.274, 0.568, 0), float4(0.501, 0.277, 0.820, 0),
    float4(1.1982, 0.5484, -0.8060, 0.2780), float4(-0.786, -0.325, 0.526, 0), float4(0.465, 0.250, 0.849, 0),
    float4(1.3836, 0.7028, -0.8395, 0.3556), float4(-0.796, -0.347, 0.496, 0), float4(0.442, 0.227, 0.868, 0),
    float4(1.5562, 0.8502, -0.8306, 0.4021), float4(-0.803, -0.366, 0.470, 0), float4(0.423, 0.204, 0.883, 0),
    float4(1.6801, 0.9793, -0.7674, 0.4225), float4(-0.806, -0.399, 0.438, 0), float4(0.400, 0.178, 0.899, 0),
    float4(1.7276, 1.0707, -0.6535, 0.4266), float4(-0.806, -0.446, 0.390, 0), float4(0.365, 0.145, 0.920, 0),
    float4(1.6877, 1.1076, -0.5070, 0.4205), float4(-0.807, -0.494, 0.323, 0), float4(0.315, 0.102, 0.944, 0),
    float4(1.5700, 1.0862, -0.3541, 0.3972), float4(-0.811, -0.534, 0.239, 0), float4(0.252, 0.050, 0.966, 0),
    float4(1.3977, 1.0200, -0.2172, 0.3472), float4(-0.811, -0.567, 0.144, 0), float4(0.181, -0.009, 0.984, 0),
    float4(1.1969, 0.9363, -0.1079, 0.2690), float4(-0.794, -0.606, 0.041, 0), float4(0.105, -0.070, 0.992, 0),
};
// ROUTES-END

struct SpFrac {
    float3x3 rot;      // per-iteration rotation (identity when untwisted)
    float3   off;      // scaling centre times (scale - 1)
    float    scale;
    float    bound;    // attractor radius at every level
    int      form;
    int      iters;
    bool     twisted;
};

static inline float3x3 spAxisRotation(float3 ax, float ang) {
    float s = sin(ang), co = cos(ang), r = 1.0 - co;
    return float3x3(float3(ax.x * ax.x * r + co,        ax.y * ax.x * r + ax.z * s, ax.z * ax.x * r - ax.y * s),
                    float3(ax.x * ax.y * r - ax.z * s, ax.y * ax.y * r + co,        ax.z * ax.y * r + ax.x * s),
                    float3(ax.x * ax.z * r + ax.y * s, ax.y * ax.z * r - ax.x * s, ax.z * ax.z * r + co));
}

// One fold into the form's fundamental region.
static inline float3 spFold(float3 p, int form) {
    if (form == 0) {
        // Tetrahedral: mirrors x+y=0, x+z=0, y+z=0.
        if (p.x + p.y < 0.0) p.xy = -p.yx;
        if (p.x + p.z < 0.0) p.xz = -p.zx;
        if (p.y + p.z < 0.0) p.zy = -p.yz;
    } else if (form == 1) {
        // Octahedral: abs, then sort so x >= y >= z.
        p = abs(p);
        if (p.x < p.y) p.xy = p.yx;
        if (p.x < p.z) p.xz = p.zx;
        if (p.y < p.z) p.yz = p.zy;
    } else {
        // Icosahedral (H3): reaches the chamber from anywhere in five folds.
        p = abs(p);
        p -= 2.0 * max(dot(p, SP_N_A), 0.0) * SP_N_A;
        p -= 2.0 * max(dot(p, SP_N_B), 0.0) * SP_N_B;
        p = abs(p);
        p -= 2.0 * max(dot(p, SP_N_C), 0.0) * SP_N_C;
    }
    return p;
}

// Distance from p to the last level's solid, unscaled.
static inline float spSolid(float3 p, int form) {
    if (form == 0) {
        float m = max(max(-p.x - p.y - p.z, -p.x + p.y + p.z), max(p.x - p.y + p.z, p.x + p.y - p.z));
        return (m - 1.0) / SP_SQRT3;
    }
    if (form == 1) {
        p = abs(p);
        return (p.x + p.y + p.z - 1.0) / SP_SQRT3;
    }
    p = spFold(p, 2);
    return dot(p, form == 2 ? SP_C3 : SP_C5) - SP_IN_ICO;
}

// Distance estimate to a fractional depth `lod` (a geomorph): the solid at
// depth n = floor(lod), blended toward depth n + 1 by the fraction. A whole
// depth popped a level of detail in at a fixed camera distance, so a band of
// the surface visibly changed shape as the camera moved through it; blended,
// each level grows in over a factor of the fold scale in distance. The two
// depths share their first n folds, so the blend costs one more fold and one
// more solid, not a second estimate, and keeps one point live, not two (an
// earlier blend of two depths cost a third of the frame in register
// pressure); a whole `lod` (the orbit; the flight at its floor depth) skips
// it. Bails out once the
// point is clear of the level's bounding sphere: the attractor lies within
// `bound` at every level, so (|p| - bound) / s^i is still a lower bound for
// both depths.
static float spDE(float3 p, thread const SpFrac& F, float lod) {
    int n = int(lod);
    float f = lod - float(n);
    float k = 1.0;
    float lim = 4.0 * F.bound * F.bound;
    for (int i = 0; i < n; i++) {
        float r2 = dot(p, p);
        if (r2 > lim) return (sqrt(r2) - F.bound) * k;
        p = spFold(p, F.form);
        if (F.twisted) p = F.rot * p;
        p = p * F.scale - F.off;
        k /= F.scale;
    }
    float d = spSolid(p, F.form) * k;
    if (f > 0.0) {
        p = spFold(p, F.form);
        if (F.twisted) p = F.rot * p;
        p = p * F.scale - F.off;
        d = mix(d, spSolid(p, F.form) * (k / F.scale), f);
    }
    return d;
}

// The same, with orbit traps for colouring: x = the closest any level came to
// the origin (crevices), y = the deepest level's position on its solid (face
// shading). Fractional depths blend the traps of the two whole depths, as
// spDE blends their solids.
static float2 spTrap(float3 p, thread const SpFrac& F, float lod) {
    int n = int(lod);
    float f = lod - float(n);
    float trap = 1e9;
    for (int i = 0; i < n; i++) {
        p = spFold(p, F.form);
        if (F.twisted) p = F.rot * p;
        p = p * F.scale - F.off;
        trap = min(trap, dot(p, p) / (F.bound * F.bound));
    }
    float2 tr = float2(sqrt(trap), clamp(length(p) / F.bound, 0.0, 1.5));
    if (f > 0.0) {
        p = spFold(p, F.form);
        if (F.twisted) p = F.rot * p;
        p = p * F.scale - F.off;
        trap = min(trap, dot(p, p) / (F.bound * F.bound));
        tr = mix(tr, float2(sqrt(trap), clamp(length(p) / F.bound, 0.0, 1.5)), f);
    }
    return tr;
}

static inline float3 spNormal(float3 p, float e, thread const SpFrac& F, float lod) {
    const float2 k = float2(1.0, -1.0);
    return normalize(k.xyy * spDE(p + k.xyy * e, F, lod) +
                     k.yyx * spDE(p + k.yyx * e, F, lod) +
                     k.yxy * spDE(p + k.yxy * e, F, lod) +
                     k.xxx * spDE(p + k.xxx * e, F, lod));
}

// `hs` is the scale of the neighbourhood: the attractor's bound in the orbit,
// shrinking with the distance to the hit inside the fractal.
static float spShadow(float3 p, float3 l, float hs, float lod, int steps, thread const SpFrac& F) {
    float res = 1.0;
    float t = 0.01 * hs;
    for (int i = 0; i < steps; i++) {
        float d = spDE(p + l * t, F, lod);
        res = min(res, 9.0 * d / t);
        t += clamp(d, 0.004 * hs, 0.25 * hs);
        if (res < 0.01 || t > 2.5 * hs) break;
    }
    return smoothstep(0.0, 1.0, clamp(res, 0.0, 1.0));
}

// Four probes along the normal, or (`sparse`) only the second and fourth,
// reweighted to the same total.
static float spOcclusion(float3 p, float3 n, float hs, float lod, bool sparse, thread const SpFrac& F) {
    float occ = 0.0, w = 1.0;
    for (int i = 1; i <= 4; i++) {
        float h = hs * 0.035 * float(i * i);
        if (!sparse || (i & 1) == 0) occ += w * max(h - spDE(p + n * h, F, lod), 0.0) / h;
        w *= 0.6;
    }
    return clamp(1.0 - 0.9 * occ * (sparse ? 2.667 : 1.0), 0.0, 1.0);
}

// Linear-light colours of the look (the parameters are display-space).
struct SpLook { float3 a, b, rim, back; };

// Studio surround: a dark room, lighter overhead, with a soft key box and the
// rim light's glow behind the subject. The background is the dim version;
// reflections see the lit one, so metals have something to mirror.
static float3 spEnv(float3 d, float3 up, float3 key, float3 rimDir, thread const SpLook& L, bool refl) {
    float y = dot(d, up);
    float3 c = L.back * (0.55 + 0.9 * smoothstep(-0.7, 0.9, y));
    float rb = pow(max(dot(d, rimDir), 0.0), 6.0);
    if (refl) {
        float kb = smoothstep(0.55, 0.95, dot(d, key));
        c += float3(1.0, 0.95, 0.88) * (0.12 + 0.85 * smoothstep(-0.3, 0.9, y) + 3.0 * kb);
        c += L.rim * 1.2 * rb;
    } else {
        c += L.rim * 0.02 * rb;
    }
    return c;
}

static inline float4 spCatmull(float4 p0, float4 p1, float4 p2, float4 p3, float f) {
    return 0.5 * ((2.0 * p1) + (p2 - p0) * f + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f * f
                  + (3.0 * (p1 - p2) + p3 - p0) * f * f * f);
}

// Route r at control-point parameter a (wraps): position and clearance scale,
// with the baked view direction and up vector.
static float4 spPath(int r, float a, thread float3& look, thread float3& up) {
    int start = SP_ROUTES[r].start, count = SP_ROUTES[r].count;
    float n = float(count);
    a -= n * floor(a / n);
    int i = min(int(a), count - 1);
    float f = a - float(i);
    int i0 = 3 * (start + (i + count - 1) % count), i1 = 3 * (start + i);
    int i2 = 3 * (start + (i + 1) % count), i3 = 3 * (start + (i + 2) % count);
    look = spCatmull(SP_PATH[i0 + 1], SP_PATH[i1 + 1], SP_PATH[i2 + 1], SP_PATH[i3 + 1], f).xyz;
    up = spCatmull(SP_PATH[i0 + 2], SP_PATH[i1 + 2], SP_PATH[i2 + 2], SP_PATH[i3 + 2], f).xyz;
    return spCatmull(SP_PATH[i0], SP_PATH[i1], SP_PATH[i2], SP_PATH[i3], f);
}

static inline float spLod(float t, float lodK, float invLogS, float lodMin) {
    return clamp((lodK - log(t)) * invLogS + SP_FLY_LOD_BIAS, lodMin, SP_LOD_MAX);
}

// The flight's march. Close to the lattice nearly every pixel hits, so this
// is where the frame goes; three things keep it affordable:
//   - the SIMD group crosses open space together: each lane tests a
//     different one of the next strides along the group's centre ray, and
//     the group jumps past every sample whose clearance (less a cone that
//     covers all lanes) vouches for the gap after it (as in mandelbox);
//   - each lane then over-relaxes its steps, falling back when a step
//     overshoots (Keinert et al., "Enhanced Sphere Tracing");
//   - the hit tolerance widens with the step count, so rays that graze the
//     lattice settle on it instead of creeping along it, and the march ends
//     where the fog is ~95%.
// The widening stops at 3 reference px (step 10). Uncapped it reached 7.5 px
// by the last step, and since a distant edge is reached late in the march,
// every ray passing within 7.5 px of one counted as a hit: distant edges grew
// fat, by an amount that changed with the step count as the camera moved. A
// ray that spends the whole budget still within that old 7.5 px is grazing a
// wall, not passing an edge, so it counts as a hit rather than a hole.
static float spMarchFly(float3 ro, float3 rd, float t, float tEnd, thread const SpFrac& F,
                        float lodK, float invLogS, float lodMin, thread float& dHit) {
    int i = 0;
    {
        float3 rc = normalize(simd_sum(rd));
        float cmin = simd_min(dot(rd, rc));
        float cone = sqrt(max(1.0 - cmin * cmin, 0.0)) / max(cmin, 0.5) + SP_PIXEL;
        uint rank = simd_prefix_exclusive_sum(1u);
        uint cnt = simd_sum(1u);
        float tq = simd_min(t), tq1 = simd_min(tEnd);
        float stride = max(spDE(ro + rc * tq, F, spLod(tq, lodK, invLogS, lodMin)), 1e-4) * 0.3;
        for (int q = 0; q < 16; q++) {
            float ti = tq + stride * float(rank + 1);
            float dc = spDE(ro + rc * ti, F, spLod(ti, lodK, invLogS, lodMin)) - cone * ti;
            bool tight = dc < 3.0 * SP_PIXEL * ti;
            bool gapOK = !tight && dc >= stride;
            uint firstTight = simd_min(tight ? rank : cnt);
            uint firstGap = simd_min(gapOK ? cnt : rank);
            if (firstTight == 0) break;
            uint m = min(firstTight - 1, firstGap);
            float dM = simd_max(rank == m ? dc : -1e9);
            tq += stride * float(m + 1);
            i++;
            if (firstTight < cnt || tq > tq1) break;
            stride = dM * 0.3;
        }
        t = max(t, tq);
    }
    float omega = 1.5, prevD = 0.0, stepLen = 0.0;
    float tLast = t, dLast = 1e9;
    for (; i < SP_FLY_STEPS; i++) {
        float d = spDE(ro + rd * t, F, spLod(t, lodK, invLogS, lodMin));
        if (omega > 1.0 && d + prevD < stepLen) {
            // The last step overshot: take it back and continue unrelaxed.
            t -= stepLen - prevD;
            stepLen = prevD;
            omega = 1.0;
            continue;
        }
        if (d < SP_PIXEL * t * min(1.5 + 0.15 * float(i), 3.0)) { dHit = d; return t; }
        tLast = t;
        dLast = d;
        stepLen = d * omega;
        prevD = d;
        t += stepLen;
        if (t > tEnd) return -1.0;
    }
    // Out of steps: still grazing a wall (see above) counts as a hit.
    if (dLast < SP_PIXEL * tLast * (1.5 + 0.15 * float(SP_FLY_STEPS - 1))) { dHit = dLast; return tLast; }
    return -1.0;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float seed = u.seed;

    // --- Fractal.
    SpFrac F;
    F.form = clamp(u.form, 0, 3);
    F.scale = u.scale;
    float3 c = F.form == 0 ? float3(1.0) : (F.form == 1 ? float3(1.0, 0.0, 0.0)
                                                        : (F.form == 2 ? SP_C5 : SP_C3));
    F.off = c * (F.scale - 1.0);
    F.bound = length(c) * 1.02;
    // Depth: features down to the reference pixel at the closest framing.
    float target = mix(150.0, 2500.0, u.detail * u.detail);
    F.iters = clamp(int(log(target) / log(F.scale) + 0.5), 3, 16);

    // Per-iteration rotation about a seeded axis near the scaling centre
    // (which keeps the copies overlapping, so the form stays solid), drifting
    // slowly with the camera clock.
    float ct = u.time * u.speed;
    float tw = u.twist;
    F.twisted = tw > 0.001;
    F.rot = float3x3(1.0);
    float angLo = 0.0, angHi = 0.0;
    if (F.twisted) {
        float3 ax = normalize(normalize(c) + 0.7 * (float3(hash11(seed * 13.1 + 0.7), hash11(seed * 7.9 + 2.3),
                                                          hash11(seed * 3.3 + 5.1)) - 0.5));
        float ang = tw * (0.55 + 0.35 * u.bloom * sin(0.031 * ct + seed * 40.0))
                  + 0.15 * u.bloom * tw * sin(0.013 * ct + seed * 17.0);
        F.rot = spAxisRotation(ax, ang);
        angLo = tw * (0.55 - 0.35 * u.bloom) - 0.15 * u.bloom * tw;
        angHi = tw * (0.55 + 0.35 * u.bloom) + 0.15 * u.bloom * tw;
    }

    // World orientation: stand the solid on a face so it reads as a pyramid
    // (tetrahedron) or a double pyramid (octahedron). World y maps to `fu`.
    float3 fu = F.form == 0 ? float3(1.0, 1.0, 1.0) / SP_SQRT3
              : (F.form == 1 ? float3(1.0, 0.0, 0.0) : SP_C5);
    float3 fx = normalize(cross(fu, abs(fu.z) < 0.9 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0)));
    float3 fz = cross(fx, fu);
    float3x3 W = float3x3(fx, fu, fz);    // world -> fractal: W * world

    // --- Camera, in the fractal's frame. A route verified for this form,
    // scale and range of fold rotation, or else the orbit.
    int route = -1;
    if (u.fly != 0) {
        for (int r = 0; r < SP_NROUTES; r++) {
            if (SP_ROUTES[r].form == F.form && abs(F.scale - SP_ROUTES[r].scale) <= SP_ROUTES[r].scaleTol
                && angLo >= SP_ROUTES[r].angLo && angHi <= SP_ROUTES[r].angHi) { route = r; break; }
        }
    }
    bool fly = route >= 0;
    float3 roF, fwdF, rightF, upF, upRef;
    float lens = 1.0;
    float sigma = F.bound;    // the neighbourhood's scale: clearance along a route
    if (fly) {
        // Seed: where on the loop, and which of the form's symmetries about
        // its vertical axis carries it. Always flown forwards: the view
        // directions were baked for that direction of travel.
        float h0 = hash11(seed * 37.3 + 1.1), h2 = hash11(seed * 11.3 + 8.8);
        float a = h0 * float(SP_ROUTES[route].count) + ct * SP_ROUTES[route].rate;
        // (The tetrahedral fold is three mirrors, not a full chamber fold, so
        // a twisted tetrahedron has no symmetry left: it flies as baked.)
        bool asym = F.form == 0 && F.twisted;
        int m = asym ? 1 : (F.form == 0 ? 3 : (F.form == 1 ? 4 : 5));
        float3x3 G = spAxisRotation(fu, TWO_PI * floor(h2 * float(m)) / float(m));
        if (fract(h2 * 7.0) > 0.5 && !asym) {
            float3x3 M = F.form == 0 ? float3x3(float3(0.0, 1.0, 0.0), float3(1.0, 0.0, 0.0), float3(0.0, 0.0, 1.0))
                       : (F.form == 1 ? float3x3(float3(1.0, 0.0, 0.0), float3(0.0, 1.0, 0.0), float3(0.0, 0.0, -1.0))
                                      : float3x3(float3(-1.0, 0.0, 0.0), float3(0.0, 1.0, 0.0), float3(0.0, 0.0, 1.0)));
            G = G * M;
        }
        float3 lk, upP;
        float4 P = spPath(route, a, lk, upP);
        roF = G * P.xyz;
        fwdF = normalize(G * lk);
        rightF = normalize(cross(G * upP, fwdF));
        lens = lerpLook(u.yaw, u.pitch, u.magnify, G * upP, rightF, fwdF);   // drag to turn, pinch to zoom, where it flies
        upF = cross(fwdF, rightF);
        upRef = upF;
        sigma = P.w;
    } else {
        // A slow orbit; seed picks bearing, direction, tilt and rhythm.
        float dir = hash11(seed * 5.7 + 0.3) < 0.5 ? -1.0 : 1.0;
        float az = seed * 97.0 + dir * 0.045 * ct;
        float el = 0.22 + 0.28 * sin(0.019 * ct + seed * 31.0);
        float dist = F.bound * mix(1.8, 4.0, u.zoom) * (1.0 + 0.10 * sin(0.011 * ct + seed * 23.0));
        float3 ro = dist * float3(cos(el) * sin(az), sin(el), cos(el) * cos(az));
        float3 look = float3(0.0, F.form == 0 ? 0.2 * F.bound : 0.0, 0.0);
        float3 fwd = normalize(look - ro);
        float roll = 0.05 * sin(0.017 * ct + seed * 11.0);
        float3 right = normalize(cross(float3(sin(roll), cos(roll), 0.0), fwd));
        lerpOrbit(u.yaw, u.pitch, u.magnify, look, float3(0.0, 1.0, 0.0), ro, right, fwd);   // drag to turn, pinch to zoom
        roF = W * ro;
        fwdF = W * fwd;
        rightF = W * right;
        upF = W * cross(fwd, right);
        upRef = fu;
    }
    float3 rdF = normalize(uv.x * rightF + uv.y * upF + lens * SP_FOCAL * fwdF);

    // Lights carried with the camera, so the lit side stays toward the viewer.
    float3 key = normalize(-0.55 * rightF + 0.75 * upRef - 0.35 * fwdF);
    float3 rim = normalize(0.6 * rightF + 0.25 * upRef + 0.9 * fwdF);

    SpLook L;
    L.a = pow(u.colorA.rgb, 2.2);
    L.b = pow(u.colorB.rgb, 2.2);
    L.rim = pow(u.colorRim.rgb, 2.2);
    L.back = pow(u.colorBack.rgb, 2.2);
    float3 bg = spEnv(rdF, upRef, key, rim, L, false);
    float3 col = bg;

    // Level of detail. The orbit uses one depth; the flight adds a level each
    // time the distance shrinks by the fold scale, from the orbit's detail at
    // the orbit's distance, and never drops below the verified depth.
    float invLogS = 1.0 / log(F.scale);
    float lodK = log(target * SP_LOD_REF * F.bound);
    float lodMin = fly ? SP_ROUTES[route].lodMin : SP_LOD_MIN;
    if (fly) lodK += SP_ROUTES[route].lodBias / invLogS;

    // --- March, in fractal space.
    float b = dot(roF, rdF);
    float cc = dot(roF, roF) - F.bound * F.bound;
    float disc = b * b - cc;
    float closest = 1e9;
    float dHit = 0.0;
    float tHit = -1.0;
    float tEnter = 0.0;
    if (disc > 0.0) {
        float sq = sqrt(disc);
        float t0 = max(-b - sq, 0.0), t1 = -b + sq;
        tEnter = t0;
        if (fly) {
            tHit = spMarchFly(roF, rdF, max(t0, 0.02 * sigma), min(t1, SP_FOG_END * sigma), F, lodK, invLogS, lodMin, dHit);
        } else {
            float t = t0;
            for (int i = 0; i < SP_STEPS; i++) {
                float d = spDE(roF + rdF * t, F, float(F.iters));
                closest = min(closest, d / t);
                if (d < SP_PIXEL * t) { tHit = t; break; }
                t += d;
                if (t > t1) break;
            }
        }
    }

    if (tHit > 0.0) {
        float3 p = roF + rdF * tHit;
        float lodH = fly ? spLod(tHit, lodK, invLogS, lodMin) : float(F.iters);
        float eN = max(0.25 * SP_PIXEL * tHit, 1e-6);
        // Flying, lodH is fractional, and so are the depths derived from it
        // below (normal, colour traps, occlusion): spDE and spTrap blend the
        // two whole depths either side by the same fraction as the hit's own
        // surface, so shading moves through a level as smoothly as the shape
        // does. As whole depths they switched at the same camera distances
        // as the surface but on solids 4-8x larger, and a band of the frame
        // tens of pixels across changed its light and colour at once.
        // The normal is prefiltered: two levels shallower than the
        // hit, over a few of the drawable's pixels. Past the camera's own
        // neighbourhood the flight sits at its verified floor depth, where
        // the deepest solids and the gaps between them are 2-4 px, and a
        // normal taken from them (it used to come free from the pixel quad's
        // hit points) gave every pixel its own facet: the whole surface
        // sparkled and crawled as the camera moved, about as frame-to-frame
        // incoherent as noise. The silhouette still has every level; the
        // light now reads the solids one could actually see. Costs four
        // shallow DE evaluations: at 3840x2160 on an M5, Stone 18.4 -> 23.2 ms,
        // Jade 15.0 -> 17.3, Defaults 14.4 -> 15.9. Frame-to-frame flicker at
        // 20 fps drops 40-80% across the flying presets (Stone 0.165 -> 0.044
        // mean |f(t-dt) - 2 f(t) + f(t+dt)|).
        float px = max(1.0 / min(u.resolution.x, u.resolution.y), SP_PIXEL_5K);
        float3 n = fly ? spNormal(p, 2.5 * px * tHit, F, max(lodH - 2.0, 3.0))
                       : spNormal(p, eN, F, lodH);
        float3 v = -rdF;
        float2 tr = spTrap(p, F, fly ? lodH - 3.0 : lodH);

        // Material: colorA on the faces, colorB down in the crevices.
        float crev = smoothstep(0.15, 0.9, tr.x);
        float3 alb = mix(L.b, L.a, crev);
        alb *= 0.85 + 0.15 * smoothstep(0.2, 1.2, tr.y);

        float hs = fly ? min(F.bound, 0.5 * tHit) : F.bound;
        float3 pb = p + n * (2.0 * SP_PIXEL * tHit);
        float occ;
        if (fly) {
            // One probe along the normal, deepened by the crevice trap.
            float hA = 0.15 * hs;
            occ = clamp(spDE(p + n * hA, F, max(lodH - 3.0, 3.0)) / hA, 0.0, 1.0);
            occ = (0.35 + 0.65 * occ) * mix(0.75, 1.0, smoothstep(0.1, 0.8, tr.x));
        } else {
            occ = spOcclusion(p, n, hs, max(lodH - 2.0, 3.0), false, F);
        }
        if (fly) occ = mix(1.0, occ, 0.7);
        float ndl = max(dot(n, key), 0.0);
        // No shadow rays in flight: the key rides over the camera's shoulder,
        // where the shadows it casts fall mostly out of sight.
        float sh = ndl <= 0.0 ? 0.0 : (fly ? 1.0 : spShadow(pb, key, hs, max(lodH - 3.0, 3.0), SP_SHADOW_STEPS, F));
        float3 h = normalize(key + v);
        float ndh = max(dot(n, h), 0.0);
        float ndv = max(dot(n, v), 0.0);
        float fres = pow(1.0 - ndv, 5.0);
        float pw = exp2(mix(3.0, 10.0, u.gloss));
        float3 f0 = mix(float3(0.04), alb, u.metal);
        float3 fr = f0 + (1.0 - f0) * fres;

        float3 keyCol = float3(1.0, 0.93, 0.82) * 2.6;
        float3 sky = 0.14 + 3.0 * L.back;
        float3 fillDir = normalize(-key + 0.3 * upRef);
        float3 diff = alb * (1.0 - u.metal) * (keyCol * ndl * sh
                    + sky * (0.6 + 0.4 * dot(n, upRef)) * occ
                    + float3(0.20, 0.22, 0.26) * max(dot(n, fillDir), 0.0) * occ
                    + 0.5 * L.rim * max(dot(n, rim), 0.0) * occ);
        float3 lin = diff + keyCol * fr * pow(ndh, pw) * (pw + 2.0) / 8.0 * sh;

        // Reflection of the studio, blurred toward the surround along the
        // normal as gloss drops, and occluded in crevices.
        float3 rf = reflect(-v, n);
        float3 env = spEnv(rf, upRef, key, rim, L, true);
        if (!fly) env = mix(spEnv(n, upRef, key, rim, L, true), env, u.gloss);
        lin += env * fr * occ * mix(0.4, 1.0, u.metal);

        // Rim: a coloured back light catching silhouettes.
        float rimT = pow(1.0 - ndv, 3.0) * smoothstep(-0.2, 0.6, dot(n, rim));
        lin += L.rim * 1.2 * rimT * occ * (fly ? 0.3 : 1.0);   // flying, slits seen edge-on would glow

        if (fly) {
            // A lamp riding just above the camera, so near walls read even
            // where the key light is shadowed.
            float3 lv = roF + sigma * (0.4 * upF - 0.25 * rightF) - p;
            float lr = length(lv);
            lv /= lr;
            float att = 1.0 / (1.0 + lr * lr / (9.0 * sigma * sigma));
            float3 hl = normalize(lv + v);
            float3 lamp = float3(1.0, 0.9, 0.78) * 0.9 * att;
            lin += lamp * (alb * (1.0 - u.metal) * max(dot(n, lv), 0.0)
                           + fr * pow(max(dot(n, hl), 0.0), pw) * (pw + 2.0) / 8.0) * occ;
            // Fog in units of the neighbourhood, so every depth of the descent
            // fades the same way.
            col = mix(lin, col, 1.0 - exp(-tHit / (SP_FOG_END / 3.0 * sigma)));
        } else {
            // Depth fog through the solid toward the background.
            float depth = clamp((tHit - tEnter) / (2.0 * F.bound), 0.0, 1.0);
            col = mix(lin, col, 0.65 * depth * depth);
        }
    } else if (closest < 1e8) {
        // A thin halo of the rim light along near misses.
        if (!fly) col += L.rim * 0.08 * exp(-closest * 160.0);
    }

    // Tonemap and back to display space.
    col = 1.0 - exp(-1.1 * col);
    col = pow(max(col, 0.0), float3(1.0 / 2.2));
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
