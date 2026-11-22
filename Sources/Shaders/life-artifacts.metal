// Skyrim-inspired Loading Screen of Your Life: ordinary relics in a museum-lit smoky void.
// lerp-category: Artifacts
// lerp-data: artifacts
// lerp-param: relic int 0 7 = 0 "Relic (0 = auto)"
// lerp-param: fog float 0 1 = 0.65 "Void mist"
// lerp-param: hud float 0 1 = 1.0 "Lore & level HUD"
// lerp-param: speed float 0 2 = 0.5 "Orbit speed"
// lerp-param: yaw float -180 180 = 0 "Turn"
// lerp-param: pitch float -60 60 = 0 "Tilt"
// lerp-param: magnify float -0.6 0.8 = 0 "Zoom"
// lerp-param: parallax float 0 2 = 0.8 "Head parallax"
// lerp-preset: "Worn Keycap" relic=2
// lerp-preset: "Repo Cartridge" relic=3
// lerp-preset: "Chrome Mixtape" relic=4
// lerp-preset: "Blue-Ribbon Trophy" relic=5
// lerp-preset: "Cracked Hourglass" relic=6
// lerp-preset: "Photo Relic" relic=7

static float artifactCloud(float2 p) {
    float f = 0, gain = 0.5;
    for (int i=0; i<4; ++i) { f += gain * valueNoise(p); p = rotate(p * 2.03, 0.6); gain *= 0.5; }
    return f;
}
fragment float4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
    constant ArtifactUniforms& a [[buffer(1)]], texture2d<float> relicTex [[texture(1)]],
    texture2d<float> depthTex [[texture(2)]], texture2d<float> hudTex [[texture(3)]]) {
    float2 uv = pos.xy / u.resolution;
    float aspect = u.resolution.x / u.resolution.y;
    float2 center = float2(a.params3.x > 0.5 && aspect > 1.25 ? 0.34 : 0.5, 0.48);
    float2 q = (uv-center)*float2(aspect,1);
    float cone = exp(-dot(q,q)*4.2);
    float3 bg = mix(float3(5,6,9), float3(22,27,36), cone) / 255.0;
    float t = u.time * (0.022 + u.speed * 0.032);
    float mist = 0, fgMist = 0;
    for (int i = 0; i < 3; i++) {
        float k = float(i);
        float2 p = uv * float2(2.6 * aspect, 3.2 + k * 1.4) + float2(t * (0.8 + k * 0.35), k * 5.7 - t * 0.12);
        p += float2(snoise(p * 0.55 + t * 0.4), snoise(p * 0.45 - t * 0.3)) * 0.55;
        float w = artifactCloud(p) * (0.48 / (1.0 + k * 0.65));
        mist += w;
        if (i > 0) fgMist += w;
    }
    float floorFade = smoothstep(0.16, 0.98, uv.y);
    float lowBand = smoothstep(0.50, 1.0, uv.y);
    float mistAmt = mist * (0.35 * floorFade + 0.65 * lowBand) * a.params1.w;
    float3 fogCol = mix(a.params1.xyz, float3(0.46, 0.51, 0.58), 0.35);
    bg += fogCol * mistAmt * (0.34 + 0.28 * cone);
    bg += fogCol * lowBand * lowBand * 0.09 * a.params1.w;
    float2 dustGrid = uv * float2(aspect, 1) * 72.0 + float2(t * 0.8, -t * 1.1);
    float2 cell = floor(dustGrid);
    float mote = exp(-dot(fract(dustGrid) - hash22(cell), fract(dustGrid) - hash22(cell)) * 120.0);
    bg += float3(0.86, 0.90, 0.96) * mote * step(0.982, hash21(cell + 3.0)) * (0.25 + 0.75 * cone) * 0.24;
    float4 relic;
    float dep = 0;
    if (a.params0.x < .5) {
        relic = relicTex.sample(lerpArtifactSampler,uv);
        dep = depthTex.sample(lerpArtifactSampler,uv).r;
    } else {
        float2 tilt = float2(sin(a.params2.x),sin(a.params2.y))*.06 + u.viewer.xy*u.parallax*.025;
        float2 p = q-float2(0,a.params2.w);
        p /= float2(max(.15,a.params0.z),1)*.62*a.params2.z;
        p.x /= max(.35,abs(cos(a.params2.x)));
        p.y /= max(.5,abs(cos(a.params2.y)));
        p += .5;
        if (a.params3.z > .5) {
            float2 origin = p;
            for (int i=0;i<16;i++) {
                float z = 1-float(i)/15;
                p = origin+tilt*(z-.5);
                if (depthTex.sample(lerpArtifactSampler,p).r >= z) break;
            }
        }
        float inside = step(0.0,p.x)*step(p.x,1.0)*step(0.0,p.y)*step(p.y,1.0);
        relic = relicTex.sample(lerpArtifactSampler,p)*inside;
        dep = depthTex.sample(lerpArtifactSampler,p).r;
        float2 px = 1.0/float2(relicTex.get_width(),relicTex.get_height());
        float edge = abs(relicTex.sample(lerpArtifactSampler,p+px).a-relicTex.sample(lerpArtifactSampler,p-px).a);
        float grad = abs(depthTex.sample(lerpArtifactSampler,p+px).r-depthTex.sample(lerpArtifactSampler,p-px).r);
        relic.rgb += float3(.72,.79,.86)*min(.25,edge*.6+grad*.4)*relic.a;
    }
    float3 color = relic.rgb + bg * (1.0 - relic.a);
    color += fogCol * fgMist * a.params1.w * 0.26 * relic.a * smoothstep(0.46, 0.92, uv.y) * (0.45 + 0.55 * dep);
    color *= 1.0 - 0.24 * smoothstep(0.28, 0.92, length((uv - 0.5) * float2(1.0, 0.82)));
    float4 hud = hudTex.sample(lerpArtifactSampler,uv);
    float fade = a.params0.y*smoothstep(0.0,.8,a.params3.y);
    color = color*(1-hud.a*fade)+hud.rgb*fade;
    return float4(lerpDither(color,pos),1);
}
