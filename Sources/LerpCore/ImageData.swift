import Foundation
import ImageIO
import Metal

/// A photograph and its depth, for a look that draws one: `depth-window`.
///
///     // lerp-data: image:<name>
///
/// binds two textures, both static for the life of the look:
///
///   texture(1)  `<name>.jpg` / `.png` / `.heic`, the colour, decoded into
///               Display P3 — the space the SDR layer is tagged with — so a
///               shader that returns the sample unchanged puts the photo's own
///               pixels on screen. Mipmapped.
///   texture(2)  `<name>.depth.png`, 16-bit grey *nearness*: 1 nearest, 0
///               farthest, linear in inverse depth, as a monocular depth model
///               such as Depth Anything gives it (`make depth-window` writes
///               one). Missing, it reads 0 everywhere: a flat picture.
///
/// Images are input, not state: nothing here depends on the clock, so the
/// purity contract holds trivially. A missing photo binds a 1×1 grey and logs
/// once, rather than failing the compile of a look the user may have just
/// dropped in without its picture.
public final class LerpImageData: LerpDataProvider {
    private let images: LerpImageAssets.Pair

    public init(device: MTLDevice, spec: String) {
        let name = String(spec.dropFirst("image:".count))
        images = LerpImageAssets.pair(name, device: device)
    }

    public var metalPrelude: String { Self.metalSource }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        encoder.setFragmentTexture(images.color, index: 1)
        encoder.setFragmentTexture(images.depth, index: 2)
    }

    static let metalSource = """
    // lerp-data: image:<name> — texture(1) is the photo (display-referred,
    // mipmapped), texture(2) its nearness (1 nearest, 0 farthest).
    constexpr sampler lerpImageSampler(coord::normalized,
                                       address::clamp_to_edge,
                                       filter::linear,
                                       mip_filter::linear);
    """
}

/// Where pictures are found, and the decoded ones kept.
///
/// Searched in this order, first match wins, so a picture of the user's own
/// shadows a built-in of the same name, as a custom shader does:
///
///   1. `~/Library/Application Support/Lerping/Images` — where
///      `make depth-window` puts the user's own (beside the custom Shaders
///      folder, which the sandboxed saver can also read).
///   2. `build/images` beside whichever `Sources/Shaders` a development host
///      was pointed at — the generated default, like `build/splats`.
///   3. `Resources/Images` in the host bundle — what the installed saver ships.
public enum LerpImageAssets {
    public struct Pair {
        public let color: MTLTexture
        public let depth: MTLTexture
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var extraDirectories: [URL] = []
    nonisolated(unsafe) private static var cache: [String: Pair] = [:]

    /// The user's own pictures.
    public static func customDirectories() -> [URL] {
        LerpFileLocations.homeDirectories(appending: "Library/Application Support/Lerping/Images")
    }

    /// Called by `ShaderLibrary` with its source-tree search URLs.
    static func addSourceRoots(_ shaderDirectories: [URL]) {
        lock.lock(); defer { lock.unlock() }
        for dir in shaderDirectories {
            let images = dir.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/images").standardizedFileURL
            if !extraDirectories.contains(images) { extraDirectories.append(images) }
        }
    }

    static func directories() -> [URL] {
        lock.lock()
        var dirs = extraDirectories
        lock.unlock()
        if let repo = ShaderLocations.repoShaderDirectory() {
            let built = repo.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/images").standardizedFileURL
            if !dirs.contains(built) { dirs.append(built) }
        }
        return customDirectories() + dirs + LerpBundleResources.directories(named: "Images")
    }

    /// The first `<name>.<ext>` for any of `extensions`, directory by directory.
    static func url(for name: String, extensions: [String]) -> URL? {
        for dir in directories() {
            for ext in extensions {
                let url = dir.appendingPathComponent(name + "." + ext)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// The photo and depth for `name`, decoded once per device.
    public static func pair(_ name: String, device: MTLDevice) -> Pair {
        let key = "\(device.registryID)/\(name)"
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        let colorURL = url(for: name, extensions: ["jpg", "jpeg", "png", "heic"])
        if colorURL == nil {
            NSLog("Lerping: image %@ not found (run `make images`, or `make depth-window`)", name)
        }
        // The depth is looked for beside the colour first, so a user's own
        // photo never borrows a built-in's depth of the same name.
        let depthURL = colorURL.map { $0.deletingPathExtension().appendingPathExtension("depth.png") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if colorURL != nil, depthURL == nil {
            NSLog("Lerping: image %@ has no %@.depth.png; drawing it flat", name, name)
        }
        let color = colorURL.flatMap { loadColor($0, device: device) }
            ?? solid(device: device, format: .rgba8Unorm, bytes: [128, 128, 128, 255])
        let depth = depthURL.flatMap { loadDepth($0, device: device) }
            ?? solid(device: device, format: .r16Unorm, bytes: [0, 0])
        let pair = Pair(color: color, depth: depth)

        lock.lock(); defer { lock.unlock() }
        cache[key] = pair
        return pair
    }

    private static func cgImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Thumbnail API so EXIF orientation is applied; the size cap keeps a
        // 48 MP original from becoming a 200 MB texture.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func loadColor(_ url: URL, device: MTLDevice) -> MTLTexture? {
        guard let image = cgImage(url) else {
            NSLog("Lerping: image %@ is unreadable", url.lastPathComponent)
            return nil
        }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let space = LerpEDR.sdrColorSpace,
                  let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h,
                                                         mipmapped: true)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.label = "image " + url.lastPathComponent
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: w * 4)
        if texture.mipmapLevelCount > 1, let queue = device.makeCommandQueue(),
           let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return texture
    }

    /// Read in the file's own grey space, so the 16-bit values reach the
    /// shader unconverted: they are distances, not tones.
    static func loadDepth(_ url: URL, device: MTLDevice) -> MTLTexture? {
        // Not through the thumbnail path, which can hand back 8 bits.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            NSLog("Lerping: depth %@ is unreadable", url.lastPathComponent)
            return nil
        }
        let w = image.width, h = image.height
        let space = (image.colorSpace?.model == .monochrome ? image.colorSpace : nil)
            ?? CGColorSpaceCreateDeviceGray()
        var values = [UInt16](repeating: 0, count: w * h)
        let drawn = values.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 16, bytesPerRow: w * 2, space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                                          | CGBitmapInfo.byteOrder16Little.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: w, height: h,
                                                         mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.label = "depth " + url.lastPathComponent
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: values, bytesPerRow: w * 2)
        return texture
    }

    private static func solid(device: MTLDevice, format: MTLPixelFormat, bytes: [UInt8]) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1,
                                                         mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        let texture = device.makeTexture(descriptor: d)!
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: bytes.count)
        return texture
    }
}
