// Physarum — a slime-mould transport network that grows, coarsens and dies.
// Original work, not a port. Written from Sage Jenson's description of the
// technique (https://cargocollective.com/sagejenson/physarum) and Jeff Jones,
// "Characteristics of pattern formation and evolution in approximations of
// Physarum transport networks", Artificial Life 16(2), 2010. No code from
// either is used.
//
// Sources/LerpCore/PhysarumData.swift runs the agents on the CPU: each senses
// the trail ahead, ahead-left and ahead-right, turns toward the strongest,
// moves one cell and deposits; the trail then diffuses and decays. Repeated
// over thousands of agents, that is enough to grow a network of veins. This
// file only shades the trail density it is handed.
//
// Two additions to the published model, both noted in PhysarumData.swift: a
// soft trail ceiling (`saturation`), which keeps the network from collapsing
// into a few loops within seconds, and an optional colonies start whose food
// sources keep laying trail. Agents also ignore sensor differences below 1%
// of the mean trail, which keeps growth fronts round on a square grid.
//
// The simulation reseeds every 480 steps (a minute at the default rate) so
// any frame is reachable in bounded time; the picture fades through the seam.
//
// lerp-category: Simulations
// lerp-data: physarum
//
// lerp-param: colorBack      color           = #03050a "Background"
// lerp-param: colorVein      color           = #2c7dd6 "Veins"
// lerp-param: colorCore      color           = #fff1c7 "Core"
// lerp-param: sensorAngle    float 1 90      = 22.5    "Sensor angle (°)"
// lerp-param: sensorDistance float 1 40      = 9       "Sensor distance (cells)"
// lerp-param: turnAngle      float 1 90      = 45      "Turn speed (°/step)"
// lerp-param: decay          float 0.005 0.5 = 0.1     "Trail decay"
// lerp-param: population     float 0.02 0.3  = 0.15    "Agents per cell"
// lerp-param: saturation     float 1 16      = 2       "Trail ceiling (× mean)"
// lerp-param: start          int 0 2         = 0       "Start (soup, spore, colonies)"
// lerp-param: speed          float 0 40      = 8       "Steps/sec"
// lerp-param: exposure       float 0.1 4     = 1.1     "Exposure"
// lerp-param: glow           float 0 2       = 0.6     "Glow"
//
// sensorAngle, sensorDistance and turnAngle are Jones' SA, SO and RA; the
// defaults are the values his paper uses for its transport networks. Changing
// a simulation parameter replays the current epoch from its first step under
// the new value; colours, exposure and glow are applied as drawn.
//
// Transport Network — Jones' defaults: a fine mesh that coarsens into a few
//     large polygons over the minute.
// Reticulum — sensors wider than the turn (SA 45, RA 22.5): the mesh settles
//     into stable, nearly regular cells instead of coarsening.
// Colonies — ten food sources each start a disc of agents; the discs grow,
//     meet and fuse into one network anchored on the food.
// Tendrils — a high ceiling and slow decay: a few long glowing strands that
//     slide and merge.
//
// lerp-preset: "Transport Network" colorVein=#2c7dd6, colorCore=#fff1c7
// lerp-preset: Reticulum sensorAngle=45, turnAngle=22.5, colorBack=#070302
// lerp-preset: Reticulum colorVein=#e0761b, colorCore=#fff2d6
// lerp-preset: Colonies start=2, colorBack=#06030b, colorVein=#8a4fe0
// lerp-preset: Colonies colorCore=#ffd9f4, glow=0.8
// lerp-preset: Tendrils saturation=12, decay=0.05, exposure=1.8, glow=1.2
// lerp-preset: Tendrils colorBack=#020806, colorVein=#1fa37a, colorCore=#d9ffe9

// Cubic B-spline filter from four bilinear taps: each pair of texels on an
// axis folds into one linear fetch placed between them in proportion to their
// weights. Smooths the cell grid away at any magnification.
static float2 physSample(texture2d<float> trail, float2 uv) {
    float2 size = float2(trail.get_width(), trail.get_height());
    float2 p = uv * size - 0.5;
    float2 i = floor(p);
    float2 f = p - i;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    float2 w3 = f3 / 6.0;
    float2 g0 = w0 + w1, g1 = w2 + w3;
    float2 c0 = (i - 0.5 + w1 / g0) / size;   // between texels i-1 and i
    float2 c1 = (i + 1.5 + w3 / g1) / size;   // between texels i+1 and i+2
    return g0.y * (g0.x * trail.sample(lerpPhysarumSampler, float2(c0.x, c0.y)).rg
                 + g1.x * trail.sample(lerpPhysarumSampler, float2(c1.x, c0.y)).rg)
         + g1.y * (g0.x * trail.sample(lerpPhysarumSampler, float2(c0.x, c1.y)).rg
                 + g1.x * trail.sample(lerpPhysarumSampler, float2(c1.x, c1.y)).rg);
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpPhysarumFrame& F [[buffer(1)]],
                        texture2d<float> trail [[texture(1)]]) {
    float2 uv = lerpScreenUV(pos, u.resolution);
    float2 texel = 1.0 / float2(trail.get_width(), trail.get_height());

    float2 here = physSample(trail, uv);
    float density = mix(here.x, here.y, F.blend);

    // Halo: a ring of plain bilinear taps a few cells out, turned with the
    // epoch so the ring's own pattern never settles into the picture.
    float halo = 0.0;
    float spin = 0.7 * F.epoch + 6.0 * u.seed;
    for (int k = 0; k < 8; k++) {
        float a = spin + float(k) * (TWO_PI / 8.0);
        float2 o = 3.0 * float2(cos(a), sin(a)) * texel;
        float2 s = trail.sample(lerpPhysarumSampler, uv + o).rg;
        halo += mix(s.x, s.y, F.blend);
    }
    halo /= 8.0;

    // Density arrives as a fraction of the trail's ceiling: 1 is a
    // saturated vein. The B-spline rounds each vein into a tube, so the core
    // colour lands along its spine and the vein colour on its flanks.
    float body = clamp(density * u.exposure, 0.0, 1.0) * F.fade;
    float bloom = clamp(halo * u.exposure, 0.0, 1.0) * F.fade;

    float3 color = u.colorBack.rgb;
    color += u.colorVein.rgb * u.glow * 0.4 * bloom;
    color = mix(color, u.colorVein.rgb, smoothstep(0.1, 0.6, body));
    color = mix(color, u.colorCore.rgb, 0.85 * smoothstep(0.6, 1.0, body));

    return half4(half3(lerpDither(color, pos)), 1.0h);
}
