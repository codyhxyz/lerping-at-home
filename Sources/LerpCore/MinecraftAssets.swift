import Foundation
import Metal

/// Minecraft's own textures, for a look that asks for them:
///
///     // lerp-requires: minecraft
///
/// `make minecraft` packs the textures of the game installed on this Mac into
/// `~/Library/Application Support/Lerping/Minecraft` (see
/// `scripts/minecraft-atlas.swift` for the layout). They are Mojang's, so they
/// are never in the repo or in a release: a Mac without that folder simply has
/// no Minecraft looks, the way a Mac without Metal 4 has no `neural-field`.
///
/// Unlike a `// lerp-data:` provider these ride beside whatever provider the
/// look already has (`hedge-maze` walks `maze`, `piston-clock` reads `clock`),
/// so they are bound at their own fragment texture indices, 8 to 11, well
/// clear of the 1-and-up a provider owns:
///
///     texture2d_array<float> mcTiles [[texture(8)]]    block faces, 16x16
///     texture2d_array<float> mcItems [[texture(9)]]    items, 16x16
///     texture2d_array<float> mcSkins [[texture(10)]]   mobs, particles, sun and moon, 64x64
///     texture2d_array<float> mcMaps  [[texture(11)]]   clouds, colormaps, rain, big mobs, 256x256
///
/// A shader takes only the ones it reads. Textures are input, not state, so
/// the purity contract holds trivially.
public enum LerpMinecraft {
    public static let requirement = "minecraft"
    static let folder = "Library/Application Support/Lerping/Minecraft"
    static let firstTextureIndex = 8

    public struct Atlas {
        let textures: [MTLTexture]   // tiles, items, skins, maps
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var atlases: [UInt64: Atlas] = [:]
    nonisolated(unsafe) private static var prelude: String?

    /// The packed folder, if `make minecraft` has been run. `atlas.json` is
    /// written last, so finding it means the rest is complete.
    public static func directory() -> URL? {
        LerpFileLocations.homeDirectories(appending: folder).first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("atlas.json").path)
        }
    }

    public static var isInstalled: Bool { directory() != nil }

    private static func installed() throws -> URL {
        guard let directory = directory() else {
            throw Failure(message: "Minecraft textures are not installed; run `make minecraft`")
        }
        return directory
    }

    /// The generated layer constants (`MC_STONE`, `MCS_PIG_TEMPERATE`, …) and
    /// the sampling helpers, for the prelude of a shader that requires them.
    public static func metalPrelude() throws -> String {
        lock.lock()
        if let prelude { lock.unlock(); return prelude }
        lock.unlock()
        let url = try installed().appendingPathComponent("atlas.metal")
        guard let constants = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure(message: "cannot read \(url.path); run `make minecraft` again")
        }
        let source = constants + helpers
        lock.lock(); defer { lock.unlock() }
        prelude = source
        return source
    }

    /// The four arrays for `device`, loaded once. Called when a shader that
    /// requires them is compiled, which is before its first frame and off the
    /// render thread.
    @discardableResult
    public static func load(device: MTLDevice) throws -> Atlas {
        lock.lock()
        if let cached = atlases[device.registryID] { lock.unlock(); return cached }
        lock.unlock()

        let directory = try installed()
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("atlas.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tile = json["tile"] as? Int, let skin = json["skin"] as? Int, let map = json["map"] as? Int,
              let tiles = json["tiles"] as? Int, let items = json["items"] as? Int,
              let skins = json["skins"] as? Int, let maps = json["maps"] as? Int else {
            throw Failure(message: "\(directory.path)/atlas.json is unreadable; run `make minecraft` again")
        }
        let atlas = Atlas(textures: [
            try array(device, directory, "tiles", size: tile, count: tiles),
            try array(device, directory, "items", size: tile, count: items),
            try array(device, directory, "skins", size: skin, count: skins),
            try array(device, directory, "maps", size: map, count: maps),
        ])
        lock.lock(); defer { lock.unlock() }
        atlases[device.registryID] = atlas
        return atlas
    }

    private static func array(_ device: MTLDevice, _ directory: URL, _ name: String,
                              size: Int, count: Int) throws -> MTLTexture {
        let url = directory.appendingPathComponent(name + ".rgba")
        let layerBytes = size * size * 4
        guard count > 0, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count == layerBytes * count else {
            throw Failure(message: "\(url.path) is missing or the wrong size; run `make minecraft` again")
        }
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .rgba8Unorm
        d.width = size
        d.height = size
        d.arrayLength = count
        d.mipmapLevelCount = size.bitWidth - size.leadingZeroBitCount   // down to 1x1
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else {
            throw Failure(message: "cannot allocate the Minecraft \(name) texture array (\(count) layers)")
        }
        texture.label = "minecraft " + name
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for slice in 0..<count {
                texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, slice: slice,
                                withBytes: base + slice * layerBytes, bytesPerRow: size * 4,
                                bytesPerImage: layerBytes)
            }
        }
        guard let queue = device.makeCommandQueue(), let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else {
            throw Failure(message: "cannot build mipmaps for the Minecraft \(name) texture array")
        }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return texture
    }

    /// Binds the arrays if some shader on `device` has asked for them. Called
    /// for every pass: a look that takes none of them is untouched by four
    /// bound textures it never declared.
    static func bindIfLoaded(to encoder: MTLRenderCommandEncoder, device: MTLDevice) {
        lock.lock()
        let atlas = atlases[device.registryID]
        lock.unlock()
        guard let atlas else { return }
        for (offset, texture) in atlas.textures.enumerated() {
            encoder.setFragmentTexture(texture, index: firstTextureIndex + offset)
        }
    }

    static let helpers = """

    // lerp-requires: minecraft — the game's own textures (MinecraftAssets.swift).
    // Layer constants above: MC_* in mcTiles, MC_ITEM_* in mcItems, MCS_* in
    // mcSkins (with *_SIZE in pixels), MCM_* in mcMaps (with *_SIZE).
    constant float MC_TILE = 16.0;
    constant float MC_SKIN = 64.0;
    constant float MC_MAP  = 256.0;

    constexpr sampler mcRepeat(coord::normalized, address::repeat,
                               filter::linear, mip_filter::linear);
    constexpr sampler mcClamp(coord::normalized, address::clamp_to_edge,
                              filter::linear, mip_filter::linear);
    constexpr sampler mcAniso(coord::normalized, address::repeat,
                              filter::linear, mip_filter::linear, max_anisotropy(8));

    // Texel-crisp sampling that does not shimmer: `t` is the position in
    // texels, `w` the width of one screen pixel in texels. Inside a texel the
    // lookup sits on its centre (a hard pixel edge, as in the game); across an
    // edge it blends over exactly one screen pixel; once texels are smaller
    // than pixels it becomes ordinary trilinear filtering.
    static inline float2 mcCrisp(float2 t, float w) {
        float2 i = floor(t - 0.5);
        float2 f = t - 0.5 - i;
        return i + 0.5 + clamp((f - 0.5) / max(w, 1e-4) + 0.5, 0.0, 1.0);
    }

    // A block face. `uv` runs 0..1 across the face and repeats; `footprint` is
    // the width of one screen pixel at the hit, in blocks.
    static inline float4 mcTile(texture2d_array<float> tiles, int layer, float2 uv, float footprint) {
        float w = footprint * MC_TILE;
        return tiles.sample(mcRepeat, mcCrisp(uv * MC_TILE, w) / MC_TILE, layer, level(log2(max(w, 1.0))));
    }

    // The same face seen at a glancing angle (a floor running to the horizon):
    // pass the uv change across one screen pixel in x and in y, and the
    // sampler filters along the long axis instead of blurring both.
    static inline float4 mcTileAniso(texture2d_array<float> tiles, int layer, float2 uv,
                                     float2 duvdx, float2 duvdy) {
        float w = min(length(duvdx), length(duvdy)) * MC_TILE;
        return tiles.sample(mcAniso, mcCrisp(uv * MC_TILE, w) / MC_TILE, layer, gradient2d(duvdx, duvdy));
    }

    // Which frame of an animated tile shows at `time` seconds: pass the tile's
    // MC_X, MC_X_FRAMES and MC_X_TICKS. The game runs 20 ticks a second.
    static inline int mcFrame(int first, int frames, int ticks, float time) {
        return first + int(glmod(floor(time * 20.0 / float(ticks)), float(frames)));
    }

    // A skin or a map, addressed in its own pixels (0,0 is the top-left corner
    // of the picture, as in the PNG). `w` is the width of one screen pixel in
    // texture pixels; pass 0 when unsure and get hard texels.
    static inline float4 mcSkin(texture2d_array<float> skins, int layer, float2 pixel, float w) {
        return skins.sample(mcClamp, mcCrisp(pixel, w) / MC_SKIN, layer, level(log2(max(w, 1.0))));
    }
    static inline float4 mcMap(texture2d_array<float> maps, int layer, float2 pixel, float w) {
        return maps.sample(mcClamp, mcCrisp(pixel, w) / MC_MAP, layer, level(log2(max(w, 1.0))));
    }

    // --- The game's own conventions, so every look gets them the same way.

    // A colour written as the game writes it (sRGB, 0..1) in the space these
    // shaders and the packed textures use (Display P3). Tints and sky colours
    // quoted from the game go through this; the textures already have.
    static inline float3 mcFromSRGB(float3 c) {
        float3 l = mix(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(float3(0.04045), c));
        l = float3(0.8224621 * l.r + 0.1775380 * l.g,
                   0.0331941 * l.r + 0.9668058 * l.g,
                   0.0170827 * l.r + 0.0723974 * l.g + 0.9105199 * l.b);
        return mix(l * 12.92, 1.055 * pow(l, float3(1.0 / 2.4)) - 0.055, step(float3(0.0031308), l));
    }
    constant float3 MC_WATER_TINT = float3(0.2996, 0.4575, 0.8652);   // #3F76E4, most biomes
    constant float3 MC_SKY_DAY    = float3(0.5096, 0.6498, 0.9739);   // #78A7FF, plains at noon
    constant float3 MC_FOG_DAY    = float3(0.7708, 0.8442, 0.9864);   // #C0D8FF

    // Fixed shading by face, as the game applies before any light: top 1,
    // bottom 0.5, north and south (z) 0.8, east and west (x) 0.6.
    static inline float mcFaceShade(float3 n) {
        float3 a = abs(n);
        return a.y > 0.5 ? (n.y > 0.0 ? 1.0 : 0.5) : (a.z > 0.5 ? 0.8 : 0.6);
    }

    // Brightness of a light level 0..15 (torch 14, lava and glowstone 15,
    // falling by one a block): the game's curve, steep near the source.
    static inline float mcLight(float level) {
        float b = clamp(level / 15.0, 0.0, 1.0);
        return b / (4.0 - 3.0 * b);
    }

    // The game's Brightness option at its default (50%), which it applies to
    // everything it lights. Without it a night comes out far darker than the
    // game shows it.
    static inline float3 mcBright(float3 v) {
        float3 c = saturate(v);
        return mix(c, 1.0 - pow(1.0 - c, float3(4.0)), 0.5);
    }

    // The game's lightmap: what a face's texture is multiplied by, from the
    // block-light and sky-light levels (0..15) of the air in front of it.
    // Block light is warm, sky light goes blue as it dims. `day` is 1 at noon
    // and 0 at midnight; `ambient` is the dimension's own light, 0 in the
    // Overworld and 0.1 in the Nether. The Brightness option is included, so
    // do not apply mcBright on top.
    static inline float3 mcLightmap(float blockLevel, float skyLevel, float day, float ambient) {
        float darken = mix(0.2, 1.0, saturate(day));
        float sky = mix(mcLight(skyLevel), 1.0, ambient) * (darken * 0.95 + 0.05);
        float blk = mix(mcLight(blockLevel), 1.0, ambient) * 1.5;
        float3 c = float3(blk, blk * ((blk * 0.6 + 0.4) * 0.6 + 0.4), blk * (blk * blk * 0.6 + 0.4));
        c += mix(float3(darken, darken, 1.0), float3(1.0), 0.35) * sky;
        c = mcBright(mix(c, float3(0.75), 0.04));
        return saturate(mix(c, float3(0.75), 0.04));
    }

    // Sky and fog through the day, as the game dims them: `day` 1 at noon, 0
    // at midnight. As in the game, the sky itself goes black at night and the
    // fog at the horizon stays a very dark blue.
    static inline float3 mcSkyAt(float day) { return MC_SKY_DAY * saturate(day); }
    static inline float3 mcFogAt(float day) {
        float d = saturate(day);
        return MC_FOG_DAY * float3(d * 0.94 + 0.06, d * 0.94 + 0.06, d * 0.91 + 0.09);
    }
    // Fog elsewhere. The Nether has no sky: its fog is everything beyond the blocks.
    constant float3 MC_FOG_NETHER_WASTES    = float3(0.1816, 0.0443, 0.0381);   // #330808
    constant float3 MC_FOG_BASALT_DELTAS    = float3(0.4019, 0.3738, 0.4343);   // #685F70
    constant float3 MC_FOG_SOUL_SAND_VALLEY = float3(0.1526, 0.2746, 0.2693);   // #1B4745
    constant float3 MC_FOG_CRIMSON_FOREST   = float3(0.1806, 0.0256, 0.0189);   // #330303
    constant float3 MC_FOG_WARPED_FOREST    = float3(0.0916, 0.0234, 0.0978);   // #1A051A
    constant float3 MC_FOG_END              = float3(0.6076, 0.5068, 0.6194);   // #A080A0

    // Biome tint for grass and for leaves, from the game's colormaps.
    // Plains are temperature 0.8, downfall 0.4; desert 2.0 (clamped), 0;
    // taiga 0.25, 0.8; jungle 0.95, 0.9; swamp 0.8, 0.9.
    static inline float2 mcColormapUV(float temperature, float downfall) {
        float t = clamp(temperature, 0.0, 1.0);
        float d = clamp(downfall, 0.0, 1.0) * t;
        return (float2(1.0 - t, 1.0 - d) * 255.0 + 0.5) / MC_MAP;
    }
    static inline float3 mcGrassTint(texture2d_array<float> maps, float temperature, float downfall) {
        return maps.sample(mcClamp, mcColormapUV(temperature, downfall), MCM_COLORMAP_GRASS, level(0.0)).rgb;
    }
    static inline float3 mcFoliageTint(texture2d_array<float> maps, float temperature, float downfall) {
        return maps.sample(mcClamp, mcColormapUV(temperature, downfall), MCM_COLORMAP_FOLIAGE, level(0.0)).rgb;
    }

    // The side of a grass block: dirt with the grey grass fringe laid over it
    // in the biome's tint. (The top is MC_GRASS_BLOCK_TOP times the tint.)
    static inline float3 mcGrassSide(texture2d_array<float> tiles, float2 uv, float footprint, float3 tint) {
        float3 base = mcTile(tiles, MC_GRASS_BLOCK_SIDE, uv, footprint).rgb;
        float4 fringe = mcTile(tiles, MC_GRASS_BLOCK_SIDE_OVERLAY, uv, footprint);
        return mix(base, fringe.rgb * tint, fringe.a);
    }

    """
}
