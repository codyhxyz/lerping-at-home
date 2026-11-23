import CryptoKit
import Foundation
import Metal
import QuartzCore

/// A baked Minecraft world, for a look that asks for one:
///
///     // lerp-requires: minecraft world:mine
///     // lerp-requires: minecraft mobs world:shared
///
/// The bake (`scripts/minecraft-world/`, format in its `FORMAT.md`) writes a
/// save as voxel volumes and tables into
/// `~/Library/Application Support/Lerping/Minecraft/Worlds/<name>/`, with
/// `world.json` last. Like the textures it is the game's, made on this Mac
/// from the user's own copy, so it is never in the repo: a Mac without the
/// bake simply has no such look, as `ShaderLibrary.discover()` leaves it out.
///
/// A world is baked against one texture atlas (its materials name layers of
/// `mcTiles`), so a world whose recorded atlas hash differs from the installed
/// `atlas.txt` is refused with a compile error saying to re-bake. There is no
/// way to draw it anyway: every texture would be the wrong one.
///
/// Bindings, beside the atlas's 8 to 11 and well clear of the 1-and-up a
/// `// lerp-data:` provider owns (the look takes them all at once with the
/// prelude's `MCW_BINDINGS` macro; see PORTING.md "Worlds"):
///
///     texture3d<ushort>      mcwBlocks    [[texture(12)]]  blocks.r16: material id, skip distance
///     texture3d<float>       mcwLight     [[texture(13)]]  light.rgba8: block light rgb, sky light a
///     texture2d_array<float> mcwTints     [[texture(14)]]  tints.rgba8: grass, foliage, water (re-encoded Display P3)
///     texture2d<ushort>      mcwFarH      [[texture(15)]]  far.rg16: ground and water height
///     texture2d_array<float> mcwFar       [[texture(16)]]  far.rgba8: ground and water colour (Display P3)
///     texture2d<uint>        mcwMaterials [[texture(17)]]  materials: one row per material id
///     texture2d<uint>        mcwElements  [[texture(18)]]  elements: model boxes and their faces
///     texture2d<ushort>      mcwFarMax    [[texture(19)]]  the far field's highest surface per 16 x 16 tile (made here)
///     constant McWorldClock& mcwClock     [[buffer(12)]]   shared wall-clock time
///
/// Loaded once per device and bake, when a look that uses the world is
/// compiled or about to be shown (off the render thread, as the atlas is), and
/// shared by every view and library on that device: the table here refers to
/// a loaded world only weakly. What holds it is the `LerpWorldProvider` of each
/// look drawing it, and `ShaderLibrary.releaseIdleWorlds` lets a provider's
/// world go once its look has not drawn for `LerpWorldProvider.idleRelease`
/// seconds, so the screensaver does not carry it through the rest of a
/// rotation. `mine`, 384 x 107 x 384, is 122 MiB on the GPU: light 60, blocks
/// 30, far field 8, tints 2 (and allocation rounding).
///
/// A look may also have a per-frame plan kernel, `lerpPlan` (`// lerp-plan: N`,
/// PORTING.md "Worlds"), run before each frame by the provider; its output is
/// bound at fragment buffer 13.
public enum LerpMinecraftWorld {
    public static let requirementPrefix = "world:"
    /// The most float4s a `lerpPlan` kernel may write (`// lerp-plan: N`).
    public static let maxPlan = 256
    static let planBufferIndex = 13
    static let folder = "Library/Application Support/Lerping/Minecraft/Worlds"
    static let firstTextureIndex = 12
    static let clockBufferIndex = 12

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The one world a look's requirements name, nil for none. Two names is an
    /// error the compile reports (`worldName(of:)` in ShaderLibrary).
    static func worldNames(in requirements: [String]) -> [String] {
        requirements.filter { $0.hasPrefix(requirementPrefix) }
            .map { String($0.dropFirst(requirementPrefix.count)) }
    }

    /// The bake's folder, if a complete bake of `name` is here (`world.json`
    /// is written last).
    public static func directory(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return LerpFileLocations.homeDirectories(appending: folder + "/" + name).first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("world.json").path)
        }
    }

    public static func isBaked(_ name: String) -> Bool { directory(named: name) != nil }

    // MARK: - Loaded worlds

    /// One world's GPU textures and its prelude text, for one device.
    public final class World {
        public let name: String
        /// Identifies the bake: a hash of its `world.json` (which records the
        /// bake's date and every file's size). A re-bake is a new stamp.
        public let stamp: String
        /// In binding order from `firstTextureIndex`.
        let textures: [MTLTexture]
        /// `world.metal`, the bake's constants, and the few the loader derives
        /// from the data (`MCWK_*`).
        let constants: String
        /// What the textures occupy on the GPU, in bytes.
        public let bytes: Int

        init(name: String, stamp: String, textures: [MTLTexture], constants: String) {
            self.name = name
            self.stamp = stamp
            self.textures = textures
            self.constants = constants
            self.bytes = textures.reduce(0) { $0 + $1.allocatedSize }
        }
    }

    private final class WeakWorld { weak var world: World?; init(_ w: World) { world = w } }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: WeakWorld] = [:]
    /// Serialises loads, so two libraries compiling the same world at once
    /// read it once.
    private static let loadLock = NSLock()

    /// `world.json`'s bytes, its stamp and its parsed keys.
    static func manifest(_ name: String) throws -> (dir: URL, stamp: String, json: [String: Any]) {
        guard let dir = directory(named: name) else {
            throw Failure(message: "no baked world named '\(name)' (looked for Worlds/\(name)/world.json); bake it with scripts/minecraft-world")
        }
        let url = dir.appendingPathComponent("world.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "\(url.path) is unreadable; re-bake world '\(name)'")
        }
        let stamp = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return (dir, stamp, json)
    }

    /// The stamp of the bake on disk now, or nil if there is none. Part of a
    /// world look's pipeline cache key, so a re-bake recompiles it.
    static func currentStamp(_ name: String) -> String? {
        try? manifest(name).stamp
    }

    /// The world for `device`, loading it if no live library holds this bake.
    public static func load(_ name: String, device: MTLDevice) throws -> World {
        let (dir, stamp, json) = try manifest(name)
        let key = "\(device.registryID)|\(name)|\(stamp)"
        loadLock.lock(); defer { loadLock.unlock() }
        lock.lock()
        if let cached = loaded[key]?.world { lock.unlock(); return cached }
        loaded = loaded.filter { $0.value.world != nil }
        lock.unlock()

        try checkAtlas(name, json)
        let world = try build(name: name, stamp: stamp, dir: dir, json: json, device: device)
        lock.lock(); loaded[key] = WeakWorld(world); lock.unlock()
        return world
    }

    /// Refuses a world baked against a different atlas than the installed one.
    static func checkAtlas(_ name: String, _ json: [String: Any]) throws {
        guard let atlas = json["atlas"] as? [String: Any], let baked = atlas["hash"] as? String else {
            throw Failure(message: "world '\(name)' does not record the atlas it was baked against; re-bake it")
        }
        guard let dir = LerpMinecraft.directory(),
              let text = try? Data(contentsOf: dir.appendingPathComponent("atlas.txt")) else {
            throw Failure(message: "Minecraft textures are not installed; run `make minecraft`, then re-bake world '\(name)'")
        }
        let installed = SHA256.hash(data: text).map { String(format: "%02x", $0) }.joined()
        guard installed == baked.lowercased() else {
            throw Failure(message: "world '\(name)' was baked against a different texture atlas (atlas.txt \(baked.prefix(12))…, installed \(installed.prefix(12))…); re-bake it with scripts/minecraft-world")
        }
    }

    static func ints(_ value: Any?, _ count: Int) -> [Int]? {
        guard let array = value as? [Any], array.count == count else { return nil }
        let out = array.compactMap { ($0 as? NSNumber)?.intValue }
        return out.count == count ? out : nil
    }

    private static func build(name: String, stamp: String, dir: URL, json: [String: Any],
                              device: MTLDevice) throws -> World {
        guard let size = ints(json["size"], 3), size.allSatisfy({ $0 > 0 }) else {
            throw Failure(message: "world '\(name)': world.json has no usable size; re-bake it")
        }
        let (w, h, d) = (size[0], size[1], size[2])
        guard let far = json["far"] as? [String: Any], let fs = ints(far["size"], 2) else {
            throw Failure(message: "world '\(name)': world.json has no far.size; re-bake it")
        }
        guard let constants = try? String(contentsOf: dir.appendingPathComponent("world.metal"), encoding: .utf8) else {
            throw Failure(message: "world '\(name)': world.metal is missing; re-bake it")
        }
        let loader = TextureLoader(device: device, dir: dir, world: name)

        // Tints: three layers (grass, foliage, water), a fourth for dry
        // foliage when the bake has it.
        let tintBytes = try loader.size("tints.rgba8")
        let tintLayers = tintBytes / (w * d * 4)
        guard tintLayers >= 3, tintLayers * w * d * 4 == tintBytes else {
            throw Failure(message: "world '\(name)': tints.rgba8 is not whole \(w)x\(d) layers; re-bake it")
        }
        // Materials: 8 texels (32 words) a row; elements: 20 texels (80 words).
        let materialBytes = try loader.size("materials.u32"), elementBytes = try loader.size("elements.u32")
        let materialRows = materialBytes / 128, elementRows = elementBytes / 320
        let declared = ((json["materials"] as? [String: Any])?["count"] as? NSNumber)?.intValue ?? 0
        guard materialRows > 0, materialRows * 128 == materialBytes, elementRows * 320 == elementBytes,
              materialRows >= declared else {
            throw Failure(message: "world '\(name)': materials.u32 (\(materialRows) rows) or elements.u32 do not match world.json (\(declared) materials); re-bake it")
        }
        let words = try loader.data("materials.u32", bytes: materialRows * 128)
        let elementWords = try loader.data("elements.u32", bytes: elementRows * 320)
        if tintLayers < 4, Self.usesTint(4, materials: words, elements: elementWords) {
            throw Failure(message: "world '\(name)': a material is tinted dry foliage (tint 4) but tints.rgba8 has no fourth layer; re-bake it")
        }
        let farHeights = try loader.data("far.rg16", bytes: fs[0] * fs[1] * 4)
        let farTop = farHeights.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt16.self).reduce(0) { max($0, $1) }
        }
        // The far field's highest surface (ground or water, as encoded) in
        // each 16 x 16 tile of columns, 0 where the save has none: lets the
        // horizon march cross a tile the ray is above in one step.
        let tiles = ((fs[0] + 15) / 16, (fs[1] + 15) / 16)
        var tileMax = [UInt16](repeating: 0, count: tiles.0 * tiles.1)
        farHeights.withUnsafeBytes { raw in
            let hgt = raw.bindMemory(to: UInt16.self)
            for j in 0..<fs[1] {
                for i in 0..<fs[0] {
                    let k = 2 * (i + fs[0] * j)
                    let top = max(UInt16(littleEndian: hgt[k]), UInt16(littleEndian: hgt[k + 1]))
                    let t = i / 16 + tiles.0 * (j / 16)
                    tileMax[t] = max(tileMax[t], top)
                }
            }
        }

        let elements = try elementRows > 0 ? loader.plane("elements.u32", .rgba32Uint, 16, 20, elementRows)
                                           : loader.empty(.rgba32Uint, 20)
        // The top of the highest non-air voxel in each column: their
        // maximum is MCWK_VOLUME_TOP, above which a climbing ray (or a
        // shadow ray) has nothing left to meet in the volume.
        let columns = try loader.data("blocks.r16", bytes: w * h * d * 2).withUnsafeBytes { raw in
            let v = raw.bindMemory(to: UInt16.self)
            var top = [UInt16](repeating: 0, count: w * d)
            for z in 0..<d {
                for y in stride(from: h - 1, through: 0, by: -1) {
                    let row = (y + h * z) * w
                    for x in 0..<w where top[x + w * z] == 0 && UInt16(littleEndian: v[row + x]) & 0x0FFF != 0 {
                        top[x + w * z] = UInt16(y + 1)
                    }
                }
            }
            return top
        }
        let volumeTop = columns.max() ?? 0
        // Plain water (kind 0, water, not waterlogged): the ids whose voxels get
        // a skip distance of their own (`addWaterSkip`).
        var water = [Bool](repeating: false, count: 4096)
        words.withUnsafeBytes { raw in
            let m = raw.bindMemory(to: UInt32.self)
            for r in 0..<min(materialRows, 4096) {
                let w0 = UInt32(littleEndian: m[r * 32]), w3 = UInt32(littleEndian: m[r * 32 + 3])
                water[r] = w0 & 3 == 0 && w3 & 3 == 1 && (w3 >> 7) & 1 == 0
            }
        }
        let textures = [
            try loader.volume("blocks.r16", .r16Uint, 2, w, h, d) { Self.addWaterSkip(&$0, w, h, d, water: water) },
            try loader.volume("light.rgba8", .rgba8Unorm, 4, w, h, d),
            try loader.layers("tints.rgba8", .rgba8Unorm, 4, w, d, tintLayers, toP3: true),
            try loader.plane("far.rg16", .rg16Uint, 4, fs[0], fs[1]),
            try loader.layers("far.rgba8", .rgba8Unorm, 4, fs[0], fs[1], 2, toP3: true),
            try loader.plane("materials.u32", .rgba32Uint, 16, 8, materialRows),
            elements,
            try loader.small(.r16Uint, tiles.0, tiles.1, tileMax, label: "far tiles"),
        ]
        try loader.finish()
        let derived = """

        // Derived by the loader (MinecraftWorld.swift) from this bake's files.
        constant float MCWK_FAR_TOP = float(\(Int(farTop)) - 1 + MCW_FAR_MIN_Y) + 1.0;   // above the highest far column
        constant int   MCWK_TINT_LAYERS = \(tintLayers);
        constant int2  MCWK_FAR_TILES = int2(\(tiles.0), \(tiles.1));            // mcwFarMax: 16 x 16 column tiles
        constant float MCWK_VOLUME_TOP = \(volumeTop).0;                        // above every non-air voxel

        """
        return World(name: name, stamp: stamp, textures: textures, constants: constants + derived)
    }

    /// Reads a bake's raw files into private GPU textures: each file is
    /// mapped, copied once into a staging buffer and blitted, so the texture
    /// is laid out for sampling and the file's pages are let go.
    final class TextureLoader {
        let device: MTLDevice
        let dir: URL
        let world: String
        private let queue: MTLCommandQueue?
        private var pending: [MTLCommandBuffer] = []

        init(device: MTLDevice, dir: URL, world: String) {
            self.device = device
            self.dir = dir
            self.world = world
            self.queue = device.makeCommandQueue()
        }

        func size(_ file: String) throws -> Int {
            let url = dir.appendingPathComponent(file)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                throw Failure(message: "world '\(world)': \(file) is missing; re-bake it")
            }
            return size.intValue
        }

        /// A small texture made here rather than read from the bake.
        func small(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ values: [UInt16], label: String) throws -> MTLTexture {
            let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            t.usage = .shaderRead
            t.storageMode = .shared
            guard values.count == w * h, let texture = device.makeTexture(descriptor: t) else {
                throw Failure(message: "world '\(world)': cannot allocate the \(label) texture")
            }
            texture.label = "minecraft world \(world) \(label)"
            values.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: w * 2)
            }
            return texture
        }

        /// A one-row table of zeros, for a world with no model elements at all.
        func empty(_ format: MTLPixelFormat, _ width: Int) throws -> MTLTexture {
            let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: 1, mipmapped: false)
            t.usage = .shaderRead
            t.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: t) else {
                throw Failure(message: "world '\(world)': cannot allocate an empty table")
            }
            let zeros = [UInt8](repeating: 0, count: width * 16)
            texture.replace(region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0, withBytes: zeros, bytesPerRow: width * 16)
            return texture
        }

        func data(_ file: String, bytes expected: Int) throws -> Data {
            let url = dir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                throw Failure(message: "world '\(world)': \(file) is missing; re-bake it")
            }
            guard data.count == expected else {
                throw Failure(message: "world '\(world)': \(file) is \(data.count) bytes, expected \(expected) from world.json; re-bake it")
            }
            return data
        }

        private func upload(_ file: String, _ descriptor: MTLTextureDescriptor, texel: Int,
                            slices: Int, sliceIsDepth: Bool, toP3: Bool = false,
                            transform: ((inout Data) -> Void)? = nil) throws -> MTLTexture {
            let w = descriptor.width, h = descriptor.height
            let sliceBytes = w * h * texel
            var data = try data(file, bytes: sliceBytes * slices)
            if toP3 || transform != nil {
                // The file is mapped read-only: change a copy of it.
                data = data.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
            }
            if toP3 { data = LerpMinecraftWorld.sRGBToDisplayP3(data) }
            transform?(&data)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor),
                  let staging = data.withUnsafeBytes({ raw in
                      device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
                  }),
                  let commands = queue?.makeCommandBuffer(),
                  let blit = commands.makeBlitCommandEncoder() else {
                throw Failure(message: "world '\(world)': cannot allocate the texture for \(file) (\(data.count) bytes)")
            }
            texture.label = "minecraft world \(world) \(file)"
            if sliceIsDepth {
                blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: w * texel,
                          sourceBytesPerImage: sliceBytes, sourceSize: MTLSize(width: w, height: h, depth: slices),
                          to: texture, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            } else {
                for slice in 0..<slices {
                    blit.copy(from: staging, sourceOffset: slice * sliceBytes, sourceBytesPerRow: w * texel,
                              sourceBytesPerImage: sliceBytes, sourceSize: MTLSize(width: w, height: h, depth: 1),
                              to: texture, destinationSlice: slice, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                }
            }
            blit.endEncoding()
            commands.commit()
            pending.append(commands)
            return texture
        }

        func volume(_ file: String, _ format: MTLPixelFormat, _ texel: Int, _ w: Int, _ h: Int, _ d: Int,
                    transform: ((inout Data) -> Void)? = nil) throws -> MTLTexture {
            let t = MTLTextureDescriptor()
            t.textureType = .type3D
            t.pixelFormat = format
            t.width = w; t.height = h; t.depth = d
            return try upload(file, t, texel: texel, slices: d, sliceIsDepth: true, transform: transform)
        }

        func plane(_ file: String, _ format: MTLPixelFormat, _ texel: Int, _ w: Int, _ h: Int) throws -> MTLTexture {
            let t = MTLTextureDescriptor()
            t.textureType = .type2D
            t.pixelFormat = format
            t.width = w; t.height = h
            return try upload(file, t, texel: texel, slices: 1, sliceIsDepth: false)
        }

        func layers(_ file: String, _ format: MTLPixelFormat, _ texel: Int, _ w: Int, _ h: Int, _ n: Int,
                    toP3: Bool = false) throws -> MTLTexture {
            let t = MTLTextureDescriptor()
            t.textureType = .type2DArray
            t.pixelFormat = format
            t.width = w; t.height = h; t.arrayLength = n
            return try upload(file, t, texel: texel, slices: n, sliceIsDepth: false, toP3: toP3)
        }

        /// Waits for every upload, and fails loudly if one did not land.
        func finish() throws {
            for commands in pending {
                commands.waitUntilCompleted()
                if commands.status != .completed {
                    throw Failure(message: "world '\(world)': uploading the textures failed (\(commands.error.map { String(describing: $0) } ?? "unknown"))")
                }
            }
            pending.removeAll()
        }
    }

    /// Whether any face descriptor in the tables uses tint `code`: cube faces
    /// and overlays at words 8..31 of a material row, element faces at words
    /// 68..79 of an element row (FORMAT.md).
    static func usesTint(_ code: UInt32, materials: Data, elements: Data) -> Bool {
        func scan(_ data: Data, row: Int, words: StrideTo<Int>) -> Bool {
            data.withUnsafeBytes { raw in
                let w = raw.bindMemory(to: UInt32.self)
                var r = 0
                while (r + 1) * row <= w.count {
                    for k in words {
                        let a = UInt32(littleEndian: w[r * row + k])
                        if (a >> 23) & 1 == 1, (a >> 16) & 15 == code { return true }
                    }
                    r += 1
                }
                return false
            }
        }
        return scan(materials, row: 32, words: stride(from: 8, to: 32, by: 2))
            || scan(elements, row: 80, words: stride(from: 68, to: 80, by: 2))
    }

    /// Gives every plain-water voxel a skip distance in the high 4 bits, as
    /// the bake gives air one: the Chebyshev distance to the nearest voxel
    /// that is not plain water, at most 15 (1 next to anything else). The
    /// bake leaves those bits 0 for every non-air voxel (FORMAT.md
    /// `blocks.r16`), so this changes nothing else. The tracer uses it only
    /// once a ray is under the surface, to cross open water to the bed in a
    /// few steps instead of one a block. Derived here because it is the
    /// tracer's acceleration structure, not part of the world.
    static func addWaterSkip(_ data: inout Data, _ w: Int, _ h: Int, _ d: Int, water: [Bool]) {
        let n = w * h * d, plane = w * h
        data.withUnsafeMutableBytes { raw in
            let v = raw.bindMemory(to: UInt16.self)
            guard v.count == n else { return }
            // `reached`: 1 where the voxel is not plain water, or is already
            // within the distance counted so far.
            var A = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
            var B = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
            let dist = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
            defer { A.deallocate(); B.deallocate(); dist.deallocate() }
            var ylo = h, yhi = -1
            for i in 0..<n {
                let wet = water[Int(UInt16(littleEndian: v[i]) & 0x0FFF)]
                A[i] = wet ? 0 : 1
                B[i] = A[i]
                dist[i] = 15
                if wet { let y = (i / w) % h; ylo = min(ylo, y); yhi = max(yhi, y) }
            }
            // Only the rows that hold water are worked on; a row either side
            // of them is never water, so it never changes.
            for j in 1..<(yhi >= 0 ? 15 : 1) {   // no water: nothing to dilate
                // Dilate A by one voxel, an axis at a time: x into B, y into
                // A, z into B; then mark what is new and swap.
                for z in 0..<d {
                    for y in ylo...yhi {
                        let row = z * plane + y * w
                        for x in 0..<w {
                            let i = row + x
                            B[i] = A[i] | (x > 0 ? A[i - 1] : 0) | (x < w - 1 ? A[i + 1] : 0)
                        }
                    }
                }
                for z in 0..<d {
                    for y in ylo...yhi {
                        let row = z * plane + y * w
                        for x in 0..<w {
                            let i = row + x
                            A[i] = B[i] | (y > 0 ? B[i - w] : 0) | (y < h - 1 ? B[i + w] : 0)
                        }
                    }
                }
                var grew = false
                for z in 0..<d {
                    for y in ylo...yhi {
                        let row = z * plane + y * w
                        for x in 0..<w {
                            let i = row + x
                            let r = A[i] | (z > 0 ? A[i - plane] : 0) | (z < d - 1 ? A[i + plane] : 0)
                            if r != 0 && dist[i] == 15 && water[Int(UInt16(littleEndian: v[i]) & 0x0FFF)] {
                                dist[i] = UInt8(j)
                                grew = true
                            }
                            B[i] = r
                        }
                    }
                }
                swap(&A, &B)
                if !grew { break }
            }
            for i in 0..<n {
                let m = UInt16(littleEndian: v[i]) & 0x0FFF
                if water[Int(m)] { v[i] = (m | UInt16(dist[i]) << 12).littleEndian }
            }
        }
    }

    /// RGBA8 colours written as the game writes them (sRGB) re-encoded in
    /// Display P3, the space the atlas's textures and these shaders use — the
    /// same conversion as the kit's `mcFromSRGB`, done once at load instead of
    /// per pixel. Alpha is kept.
    static func sRGBToDisplayP3(_ data: Data) -> Data {
        let decode = (0..<256).map { i -> Float in
            let c = Float(i) / 255
            return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        let steps = 4096
        let encode = (0...steps).map { i -> UInt8 in
            let l = Float(i) / Float(steps)
            let e = l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
            return UInt8(max(0, min(255, (e * 255).rounded())))
        }
        func enc(_ l: Float) -> UInt8 { encode[Int(max(0, min(1, l)) * Float(steps) + 0.5)] }
        var out = data
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 3 < p.count {
                let r = decode[Int(p[i])], g = decode[Int(p[i + 1])], b = decode[Int(p[i + 2])]
                p[i] = enc(0.8224621 * r + 0.1775380 * g)
                p[i + 1] = enc(0.0331941 * r + 0.9668058 * g)
                p[i + 2] = enc(0.0170827 * r + 0.0723974 * g + 0.9105199 * b)
                i += 4
            }
        }
        return out
    }

    // MARK: - Prelude

    /// What a world look's prelude gets after the atlas's: the bake's
    /// constants, then the shared tracer.
    static func metalPrelude(for world: World) -> String {
        "\n// ---- world '\(world.name)' (bake \(world.stamp)): world.metal --------------\n"
            + world.constants + "\n" + kit
    }
}

// MARK: - Shared wall-clock time

/// Mirrors `struct McWorldClock` in the world kit: UTC as whole days since
/// 2026-01-01 and seconds into that day, at `u.time == 0`. Two numbers
/// because one float of seconds since any useful epoch has no precision left
/// for a frame.
struct LerpWorldClock: Equatable {
    var day: Int32
    var second: Float
    var pad: SIMD2<Float> = .zero

    /// 2026-01-01T00:00:00Z.
    static let epoch: TimeInterval = 1_767_225_600
    /// The instant a still is drawn at: 2026-01-01T00:08:20Z, game tick 10000
    /// of a 20-minute day running from the epoch, in the afternoon light of
    /// the gathering at the bell (ticks 9000-11000), so a world look's gallery
    /// card shows its village gathered rather than a dawn with nobody about.
    static let fixed = LerpWorldClock(day: 0, second: 500)

    static func at(_ unix: TimeInterval) -> LerpWorldClock {
        let since = unix - epoch
        let day = (since / 86_400).rounded(.down)
        return LerpWorldClock(day: Int32(day), second: Float(since - day * 86_400))
    }
}

/// What every look that uses a world is bound through: its textures, its
/// clock, and the look's own `// lerp-data:` provider, if it has one, which
/// it wraps so that nothing about that provider changes.
///
/// **Purity.** The same rules as `ClockData`: the wall clock is read once per
/// session and anchored to `u.time == 0`, so within a session a frame is a
/// pure function of `(time, seed, params)` and the scrubber works. A session
/// starts on a new `u.seed`, the clock put back, or a frame after
/// `ClockData.sessionGap` seconds without one. A `.still` library and a host
/// with no bundle identifier (`LerpPreview`) get `LerpWorldClock.fixed`, so
/// gallery stills and the snapshot suite are byte-reproducible. A `utc`
/// parameter set to 0…24 pins the time at `u.time == 0` to that hour (UTC) of
/// the epoch's day.
public final class LerpWorldProvider: LerpDataProvider {
    public let inner: LerpDataProvider?
    /// The world's textures; nil once let go (`ShaderLibrary.releaseIdleWorlds`).
    var world: LerpMinecraftWorld.World? {
        didSet { if let world { name = world.name; device = world.textures.first?.device } }
    }
    private var name: String
    private var device: MTLDevice?
    /// When it last drew, for `releaseIdleWorlds`.
    private(set) var lastBind = CACurrentMediaTime()
    /// How long a world look may go undrawn before its textures are let go.
    static let idleRelease: CFTimeInterval = 10
    /// The look's `lerpPlan` kernel and how many float4s it writes, if it has
    /// one; the buffers it writes into, three in rotation; and the one this
    /// frame's kernel wrote, for `bind`.
    private var plan: (pipeline: MTLComputePipelineState, size: Int)?
    private var planRing: LerpBufferRing?
    private var planned: MTLBuffer?
    private let live: Bool
    private var session: LerpWorldClock?
    private var sessionSeed: Float = -1
    private var lastTime: Float = 0
    private var lastWall: TimeInterval = 0

    init(world: LerpMinecraftWorld.World, inner: LerpDataProvider?, mode: LerpRenderMode) {
        self.world = world
        self.name = world.name
        self.device = world.textures.first?.device
        self.inner = inner
        self.live = mode == .live && Bundle.main.bundleIdentifier != nil
    }

    public var metalPrelude: String { inner?.metalPrelude ?? "" }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        inner?.bind(to: encoder, uniforms: uniforms, params: params)
        lastBind = CACurrentMediaTime()
        guard let world = currentWorld() else { return }
        for (offset, texture) in world.textures.enumerated() {
            encoder.setFragmentTexture(texture, index: LerpMinecraftWorld.firstTextureIndex + offset)
        }
        var clock = resolve(uniforms, pinned: params?["utc"]?.scalarValue)
        encoder.setFragmentBytes(&clock, length: MemoryLayout<LerpWorldClock>.stride,
                                 index: LerpMinecraftWorld.clockBufferIndex)
        if let planned { encoder.setFragmentBuffer(planned, offset: 0, index: LerpMinecraftWorld.planBufferIndex) }
    }

    /// The world, loaded again if it was let go while this look still had a
    /// frame to draw (a crossfade's outgoing look after a long pause). The
    /// library reloads it before a look is shown, so this is the rare path.
    private func currentWorld() -> LerpMinecraftWorld.World? {
        if world == nil, let device { world = try? LerpMinecraftWorld.load(name, device: device) }
        return world
    }

    func setPlan(_ plan: (pipeline: MTLComputePipelineState, size: Int)?, device: MTLDevice) {
        if plan?.size != self.plan?.size || planRing == nil {
            planRing = plan.flatMap {
                LerpBufferRing(device: device, length: $0.size * 16, label: "Lerping/plan")
            }
        }
        self.plan = plan
    }

    /// The look's own provider's compute first, then its `lerpPlan`: one
    /// SIMD group of 32 threads, on this frame's command buffer, from this
    /// frame's uniforms and parameters (packed as `encodePass` packs them for
    /// the fragment shader) and the world, writing the buffer that `bind`
    /// then hands the fragment shader at buffer 13. Work every pixel would
    /// otherwise repeat (a directed camera checking its shot) is done once.
    public func encodeCompute(into commandBuffer: MTLCommandBuffer, uniforms: LerpUniforms,
                              params: LerpParameterValues?) {
        inner?.encodeCompute(into: commandBuffer, uniforms: uniforms, params: params)
        planned = nil
        lastBind = CACurrentMediaTime()
        guard let plan, let world = currentWorld(), let buffer = planRing?.next(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Lerping/plan"
        encoder.setComputePipelineState(plan.pipeline)
        var block = [UInt8](repeating: 0, count: LerpParamLayout.headerSize)
        withUnsafeBytes(of: uniforms) { block.replaceSubrange(0..<LerpParamLayout.headerSize, with: $0) }
        block += params?.packedTail ?? []
        encoder.setBytes(block, length: block.count, index: 0)
        if let atlas = try? LerpMinecraft.load(device: commandBuffer.device) {
            for (offset, texture) in atlas.textures.enumerated() {
                encoder.setTexture(texture, index: LerpMinecraft.firstTextureIndex + offset)
            }
        }
        for (offset, texture) in world.textures.enumerated() {
            encoder.setTexture(texture, index: LerpMinecraftWorld.firstTextureIndex + offset)
        }
        var clock = resolve(uniforms, pinned: params?["utc"]?.scalarValue)
        encoder.setBytes(&clock, length: MemoryLayout<LerpWorldClock>.stride, index: LerpMinecraftWorld.clockBufferIndex)
        encoder.setBuffer(buffer, offset: 0, index: LerpMinecraftWorld.planBufferIndex)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        encoder.endEncoding()
        planned = buffer
    }

    func resolve(_ u: LerpUniforms, pinned: Double?) -> LerpWorldClock {
        if let pinned, pinned >= 0 {
            return LerpWorldClock(day: 0, second: Float(pinned * 3600))
        }
        guard live else { return .fixed }
        let wall = Date().timeIntervalSince1970
        let newSession = session == nil
            || sessionSeed != u.seed
            || u.time < lastTime - 0.5
            || wall - lastWall > ClockData.sessionGap
        lastTime = u.time; lastWall = wall
        if newSession {
            session = LerpWorldClock.at(wall - TimeInterval(u.time))
            sessionSeed = u.seed
        }
        return session!
    }
}
