// Game of Life — ten short stories about emergence, rendered as living matter.
//
// Sources/LerpCore/LifeData.swift supplies one texel per cell: R is alive, G is
// a short birth ramp, and B is a fading death trail. The simulation remains an
// exact cellular automaton. This shader turns that binary board into a smooth
// scalar field, then shades its body, membrane, birth energy, and afterglow.
// Adjacent cells fuse visually into organisms without changing a single rule.
//
// Every preset completes its arc in about twelve seconds or less, fades through
// its epoch boundary, and starts again. Random stories get a new seed each cycle;
// canonical stories mirror their stage so a longer watch is not one fixed GIF.
//
// lerp-data: life
//
// lerp-param: colorBack  color          = #000000 "Background"
// lerp-param: colorFront color          = #e8f0ff "Organism"
// lerp-param: colorGlow  color          = #6ea8ff "Glow"
// lerp-param: story      int 0 9        = 0       "Story"
// lerp-param: size       float 4 32     = 8       "Cell size"
// lerp-param: speed      float 0 160    = 32      "Generations/sec"
// lerp-param: density    float 0 1      = 0.42    "Starting density"
// lerp-param: trail      float 0 1      = 0.35    "Death trail"
// lerp-param: glow       float 0 2      = 0.85    "Bloom"
//
// 0 — Conway B3/S23: soup burns down to still lifes, oscillators, and gliders
//     in eight seconds.
// 1 — Gosper gun: the machine is always visible; its first glider arrives in
//     under half a second and a new one follows every 0.75 seconds.
// 2 — R-pentomino: five cells hold long enough to read, then all 1,103 famous
//     generations unfold in one ten-second cycle under an expanding camera.
// 3 — HighLife B36/S23: Thompson's replicator becomes two copies after twelve
//     generations and grows a Rule-90-like family tree in eight seconds.
// 4 — Two period-30 guns make recurring inputs whose streams collide within
//     the first few seconds—the primitive from which Life logic gates are made.
// 5 — Maze B3/S12345: each seed is measured for when its changes fall below
//     one percent, then the finished field holds, slowly pulls back, and fades.
// 6 — Day & Night B3678/S34678 begins as mirrored complementary halves.
// 7 — Seeds B2/S: nothing survives, but births make advancing fireworks.
// 8 — Life Without Death B3/S012345678 grows irreversible coral from spores.
// 9 — Conway, HighLife, and Seeds evolve side by side from identical soups.
//
// The first named preset equals the defaults, so rotation keeps its useful name
// and omits the indistinguishable “Defaults” tile: exactly ten stories remain.
//
// lerp-preset: "Chaos to Order" story=0
// lerp-preset: "Gosper Glider Gun" story=1, colorBack=#060a12, colorFront=#ffd166
// lerp-preset: "Gosper Glider Gun" colorGlow=#ff7b00, speed=40, trail=0.55, glow=0.9
// lerp-preset: "R-pentomino" story=2, colorBack=#100507, colorFront=#ff6b6b
// lerp-preset: "R-pentomino" colorGlow=#ff2d8d, speed=112, trail=0.75, glow=1.1
// lerp-preset: "HighLife Replicator" story=3, colorBack=#020b14, colorFront=#67e8f9
// lerp-preset: "HighLife Replicator" colorGlow=#7c5cff, speed=30, trail=0.5, glow=0.95
// lerp-preset: "Computation by Collision" story=4, colorBack=#03050b, colorFront=#a7c7ff
// lerp-preset: "Computation by Collision" colorGlow=#5b7cfa, speed=40, trail=0.55, glow=1
// lerp-preset: Maze story=5, colorBack=#07150f, colorFront=#d7f5df, colorGlow=#4ade80
// lerp-preset: Maze size=8, speed=5.5, density=0.43, trail=0.18, glow=0.2
// lerp-preset: "Day & Night" story=6, colorBack=#000000, colorFront=#ffffff
// lerp-preset: "Day & Night" colorGlow=#7dd3fc, size=7, speed=24, density=0.28
// lerp-preset: "Day & Night" trail=0.2, glow=0.35
// lerp-preset: Seeds story=7, colorBack=#0b0614, colorFront=#ff4fd8, colorGlow=#8b5cf6
// lerp-preset: Seeds size=7, speed=8, density=0.03, trail=0.55, glow=1.1
// lerp-preset: "Life Without Death" story=8, colorBack=#07120d, colorFront=#7ce0b0
// lerp-preset: "Life Without Death" colorGlow=#14b8a6, size=7, speed=12
// lerp-preset: "Life Without Death" density=0.32, trail=0, glow=0.55
// lerp-preset: "Three Rule Worlds" story=9, colorBack=#090b10, colorFront=#f8e16c
// lerp-preset: "Three Rule Worlds" colorGlow=#f97316, size=7, speed=20
// lerp-preset: "Three Rule Worlds" density=0.34, trail=0.4, glow=0.65

static int golEpoch(int story) {
    switch (story) {
        case 0: return 256;
        case 1: return 320;
        case 2: return 1120;
        case 3: return 240;
        case 4: return 320;
        case 5: return 64;
        case 6: return 192;
        case 7: return 64;
        case 8: return 96;
        default: return 160;
    }
}

static float4 golRead(texture2d<float, access::read> board,
                      int2 cell, int2 dims, bool finite) {
    if (finite) {
        if (any(cell < 0) || any(cell >= dims)) return 0.0;
    } else {
        cell = int2((cell.x % dims.x + dims.x) % dims.x,
                    (cell.y % dims.y + dims.y) % dims.y);
    }
    return board.read(uint2(cell));
}

// Corners are (00, 10, 01, 11). Smooth interpolation rounds the isolines while
// preserving a solid bridge between orthogonally adjacent live cells.
static float golField(float4 corners, float2 weight) {
    return mix(mix(corners.x, corners.y, weight.x),
               mix(corners.z, corners.w, weight.x), weight.y);
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        texture2d<float, access::read> board [[texture(1)]]) {
    float2 frag = float2(pos.x, u.resolution.y - pos.y);
    int2 dims = int2(board.get_width(), board.get_height());
    bool finite = u.story >= 1 && u.story <= 4;
    bool paused = u.speed <= 0.0;

    float cyclePosition = paused ? 0.0
        : max(0.0, u.time) * u.speed / float(golEpoch(u.story));
    float epoch = floor(cyclePosition);
    float phase = fract(cyclePosition);
    float generation = floor(phase * float(golEpoch(u.story)));
    if (u.story == 2) {
        generation = phase < 0.10 ? 0.0
                   : phase < 0.65 ? floor((phase - 0.10) / 0.55 * 500.0)
                   : phase < 0.88 ? 500.0 + floor((phase - 0.65) / 0.23 * 603.0)
                   : 1103.0;
    }

    // A breathing transition hides the state jump between epochs. Maze spends
    // more than three seconds dissolving; pausing holds a fully visible board.
    float fadeInEnd = u.story == 5 ? 0.07 : 0.04;
    float fadeOutStart = u.story == 5 ? 0.68 : 0.92;
    float visibility = paused ? 1.0
        : smoothstep(0.0, fadeInEnd, phase)
        * (1.0 - smoothstep(fadeOutStart, 1.0, phase));

    float2 boardPos;
    if (finite) {
        float2 viewCells = float2(dims);
        if (u.story == 1) {
            viewCells = float2(112.0, 72.0);
        } else if (u.story == 2) {
            // Follow the turbulent core for most of the cycle; only pull back
            // near the finish to reveal the far-flung ash and escaped gliders.
            float closeView = min(220.0, 24.0 + 0.30 * generation);
            float reveal = smoothstep(900.0, 1103.0, generation);
            viewCells = float2(mix(closeView, 560.0, reveal));
        } else if (u.story == 3) {
            viewCells = float2(min(256.0, 20.0 + 0.35 * generation));
        } else if (u.story == 4) {
            viewCells = float2(112.0, 80.0);
        }

        float2 focusOffset = 0.0;
        if (u.story == 2) {
            float early = smoothstep(20.0, 100.0, generation);
            float late = smoothstep(180.0, 450.0, generation);
            focusOffset.x = mix(-10.0 * early, 10.0, late);
            focusOffset.y = 4.0 * smoothstep(100.0, 300.0, generation);
        }

        float pixelsPerCell = min(u.resolution.x / viewCells.x,
                                  u.resolution.y / viewCells.y);
        float2 viewport = pixelsPerCell * viewCells;
        float2 local = (frag - 0.5 * (u.resolution - viewport)) / pixelsPerCell;
        if (any(local < 0.0) || any(local >= viewCells)) {
            return half4(half3(lerpDither(u.colorBack.rgb, pos)), 1.0h);
        }
        boardPos = local + 0.5 * (float2(dims) - viewCells) + focusOffset;

        // Same canonical history, a different orientation each cycle.
        int turn = int(epoch) & 3;
        if ((turn & 1) != 0) boardPos.x = float(dims.x) - boardPos.x;
        if ((turn & 2) != 0) boardPos.y = float(dims.y) - boardPos.y;
    } else if (u.story == 5) {
        // Start at the old Maze framing, then reveal forty percent more board.
        // LifeData allocates for the final scale up front, so zooming never
        // changes or reseeds the automaton being measured.
        float finalCellSize = max(4.0, u.size * 0.60);
        float cellSize = mix(max(4.0, u.size), finalCellSize,
                             smoothstep(0.02, 0.90, phase));
        boardPos = (frag - 0.5 * u.resolution) / cellSize + 0.5 * float2(dims);
    } else {
        boardPos = frag / u.size;
    }

    // Interpolate cell-centre values into one continuous organism field. Four
    // board reads replace a full blur/bloom render pass.
    float2 centred = boardPos - 0.5;
    int2 base = int2(floor(centred));
    float2 f = fract(centred);
    float2 weight = f * f * (3.0 - 2.0 * f);
    float2 weightDerivative = 6.0 * f * (1.0 - f);

    float4 s00 = golRead(board, base,                  dims, finite);
    float4 s10 = golRead(board, base + int2(1, 0),    dims, finite);
    float4 s01 = golRead(board, base + int2(0, 1),    dims, finite);
    float4 s11 = golRead(board, base + int2(1, 1),    dims, finite);

    float4 alive = float4(s00.r, s10.r, s01.r, s11.r);
    float4 solidity = float4(s00.g, s10.g, s01.g, s11.g);
    float4 energy = alive * (0.68 + 0.32 * solidity);
    float field = golField(energy, weight);
    float trailField = golField(float4(s00.b, s10.b, s01.b, s11.b), weight) * u.trail;
    float birthField = golField(alive * (1.0 - solidity), weight);

    float2 gradient;
    gradient.x = mix(energy.y - energy.x, energy.w - energy.z, weight.y)
               * weightDerivative.x;
    gradient.y = mix(energy.z - energy.x, energy.w - energy.y, weight.x)
               * weightDerivative.y;

    const float threshold = 0.52;
    float aa = max(0.008, 1.25 * fwidth(field));
    float body = smoothstep(threshold - aa, threshold + aa, field);
    float membrane = 1.0 - smoothstep(aa, 0.09 + 2.0 * aa,
                                      abs(field - threshold));
    float halo = pow(clamp(field / threshold, 0.0, 1.0), 0.72) * (1.0 - body);
    float deathGlow = pow(clamp(trailField, 0.0, 1.0), 0.70) * (1.0 - body);

    float3 normal = normalize(float3(-2.0 * gradient, 1.0));
    float3 light = normalize(float3(-0.38, 0.55, 0.74));
    float diffuse = 0.70 + 0.34 * max(0.0, dot(normal, light));
    float3 litBody = u.colorFront.rgb * diffuse;
    float3 membraneColor = mix(u.colorFront.rgb, float3(1.0), 0.72);

    float3 color = u.colorBack.rgb;
    color += u.colorGlow.rgb * u.glow * visibility
           * (0.30 * halo + 0.58 * deathGlow);
    color = mix(color, litBody, body * visibility);
    color = mix(color, membraneColor,
                clamp(0.72 * membrane * visibility, 0.0, 1.0));

    float birthPulse = smoothstep(0.04, 0.55, birthField) * body * visibility;
    color = mix(color, float3(1.0), 0.55 * birthPulse);

    return half4(half3(lerpDither(color, pos)), 1.0h);
}
