// Sandpile — the Abelian sandpile model (Bak, Tang & Wiesenfeld, 1987),
// stepped on the GPU by compute kernels. Original shader for Lerping@Home.
//
// Grains pour into one to three sources; a cell holding four topples, sending
// one to each neighbour, and the avalanches settle into the model's fractal.
// The simulation lives in Sources/LerpCore/SandpileData.swift and runs through
// LerpGPUSimulation; this file only colours its state. Every frame is still a
// pure function of (time, seed, parameters): each epoch replays from nothing.
//
// Once the pile has settled, the camera pushes in on it about a focus near
// the centre (to 1.4x, easing in from 60% of the story); see Plan.camera.
// Settled sand is otherwise perfectly still, and the hold used to show 0% of
// pixels changing for ~24 s of every 100 s story. Because the grid now moves
// under the pixels, each pixel box-filters the (at most) 2x2 cells it covers;
// nearest-cell sampling stepped every cell edge a whole pixel at a time.
//
// lerp-category: Simulations
// lerp-data: sandpile
// lerp-param: cells     int   96 400  = 220  "Cells (short side)"
// lerp-param: speed     float 0 960   = 240  "Steps per second"
// lerp-param: feed      int   4 256   = 24   "Grains per step"
// lerp-param: fill      float 0.2 1   = 0.92 "Fill"
// lerp-param: sources   int   0 3     = 0    "Sources (0 = by seed)"
// lerp-param: glow      float 0 1     = 0.55 "Avalanche glow"
// lerp-param: colorBack color = (0.012, 0.016, 0.034) "Empty"
// lerp-param: color1    color = (0.86, 0.60, 0.30)    "One grain"
// lerp-param: color2    color = (0.10, 0.42, 0.46)    "Two grains"
// lerp-param: color3    color = (0.10, 0.13, 0.31)    "Three grains"
// lerp-param: colorHot  color = (1.00, 0.90, 0.74)    "Toppling"
//
// lerp-preset: Single   sources=1
// lerp-preset: Triad    sources=3, feed=48
// lerp-preset: Ember    colorBack=(0.02, 0.008, 0.006), color1=(0.95, 0.78, 0.42), color2=(0.70, 0.22, 0.12), color3=(0.24, 0.05, 0.06), colorHot=(1.0, 0.85, 0.55)
// lerp-preset: Fine     cells=360, feed=64, speed=480

static inline float3 spColor(uint h, constant LerpUniforms& u) {
    switch (h) {
        case 0u: return u.colorBack.rgb;
        case 1u: return u.color1.rgb;
        case 2u: return u.color2.rgb;
        case 3u: return u.color3.rgb;
        default: {
            // Still unstable: the colour it will keep after toppling, warmed
            // by how many grains are still waiting to leave.
            float load = saturate(log2(float(h) - 2.0) / 10.0);
            float3 rest = h % 4u == 0u ? u.colorBack.rgb
                        : h % 4u == 1u ? u.color1.rgb
                        : h % 4u == 2u ? u.color2.rgb : u.color3.rgb;
            return mix(rest * 0.55, u.colorHot.rgb * 0.75, 0.25 + 0.5 * load);
        }
    }
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpSandpileFrame& F [[buffer(1)]],
                        texture2d<uint> grid [[texture(1)]]) {
    float3 back = u.colorBack.rgb;
    if (F.ready == 0u) {
        // No simulation on this GPU: a quiet field in the same palette.
        float2 uv = lerpUV(pos, u.resolution);
        float r = length(uv);
        float3 color = mix(u.color3.rgb, back, smoothstep(0.0, 1.4, r));
        return half4(half3(lerpDither(color, pos)), 1.0h);
    }

    // The grid's rows span the height; its columns are centred on the width.
    // The camera magnifies about F.focus (cells from the centre).
    float2 size = float2(grid.get_width(), grid.get_height());
    float cellsPerPixel = size.y / (u.resolution.y * F.zoom);
    float2 centre = 0.5 * size + F.focus;
    float2 cellPos = (pos.xy - 0.5 * u.resolution) * cellsPerPixel + centre;

    // Box-filter the pixel over the cells it covers (at most two a side when
    // a cell is at least a pixel wide), so the push-in glides instead of
    // stepping cell edges a whole pixel at a time.
    float2 b = floor(cellPos + 0.5);
    float2 t = saturate((cellPos - b) / cellsPerPixel + 0.5);
    float3 color = 0.0;
    for (int k = 0; k < 4; ++k) {
        int2 o = int2(k & 1, k >> 1);
        int2 cell = int2(b) - 1 + o;
        float2 w2 = mix(1.0 - t, t, float2(o));
        float w = w2.x * w2.y;
        float3 c = back;
        if (w > 0.0 && cell.x >= 0 && cell.y >= 0 && cell.x < int(size.x) && cell.y < int(size.y)) {
            uint4 s = grid.read(uint2(cell));
            c = spColor(s.r, u);
            // Avalanche glow: settled cells that toppled recently, fading
            // over ~20 steps, so the fronts sparkle across the pattern.
            if (s.g > 0u && s.r < 4u) {
                float age = float(F.generation - s.g);
                c += u.glow * 0.55 * exp(-age / 20.0) * u.colorHot.rgb;
            }
        }
        color += w * c;
    }

    // Once a cell is several pixels wide, round it off a little so the
    // pattern reads as grains rather than as an upscaled bitmap.
    float pixelsPerCell = 1.0 / cellsPerPixel;
    float2 f = abs(fract(cellPos) - 0.5);
    float edge = smoothstep(0.5 - 1.5 / pixelsPerCell, 0.5, max(f.x, f.y));
    bool onGrid = all(cellPos >= 0.0) && all(cellPos < size);
    color *= 1.0 - (onGrid ? 0.22 : 0.0) * edge * smoothstep(3.0, 8.0, pixelsPerCell);

    color = mix(back, color, F.fade);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
