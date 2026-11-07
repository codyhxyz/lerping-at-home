// Gives a photo depth, for the `depth-window` look.
//
//     DepthWindow <model.mlmodelc> <photo> <name> <out-dir>
//
// (`make depth-window IMAGE=photo.jpg NAME=beach` builds and runs this.)
//
// Runs Depth Anything V2 Small — Apple's Core ML conversion,
// https://huggingface.co/apple/coreml-depth-anything-v2-small, Apache-2.0,
// downloaded by the Makefile into tools/ (gitignored) and never committed to
// this repo — on the photo, on this Mac, and writes:
//
//   <out-dir>/<name>.jpg        the photo, upright, at most 3840 px on its long
//                               side, keeping its own colour profile;
//   <out-dir>/<name>.depth.png  16-bit grey nearness at the same size: 1
//                               nearest, 0 farthest, as `ImageData.swift`
//                               reads it.
//
// The model sees a fixed 518×392. A portrait photo is turned on its side for it
// and the result turned back, so it is never squeezed to half its width. Its
// output is relative inverse depth; the 0.5th–99.5th percentiles are stretched
// to 0…1, so one stray pixel cannot flatten the rest. The upsampled map is then
// grown by about one model pixel on its nearer side, so a near thing's rim —
// pixels that are part near and part far — travels with it instead of being
// left smeared on the background.

import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("depth-window: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 5 else {
    fail("usage: DepthWindow <model.mlmodelc> <photo> <name> <out-dir>")
}
let modelURL = URL(fileURLWithPath: args[1])
let photoURL = URL(fileURLWithPath: args[2])
let name = args[3]
let outDir = URL(fileURLWithPath: args[4])
guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else {
    fail("NAME must be letters, digits, - and _ (it becomes a file name and a look name)")
}

// MARK: - Photo

guard let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil) else {
    fail("cannot read \(photoURL.path)")
}
let thumbOptions: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,     // EXIF orientation
    kCGImageSourceThumbnailMaxPixelSize: 3840,
    kCGImageSourceShouldCacheImmediately: true,
]
guard let photo = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
    fail("cannot decode \(photoURL.path)")
}
let width = photo.width, height = photo.height
let portrait = height > width

// MARK: - Model

let config = MLModelConfiguration()
config.computeUnits = .all
let model: MLModel
do { model = try MLModel(contentsOf: modelURL, configuration: config) }
catch { fail("cannot load the model at \(modelURL.path): \(error)") }
guard let inputName = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image })?.key,
      let constraint = model.modelDescription.inputDescriptionsByName[inputName]?.imageConstraint
else { fail("the model has no image input") }
let mw = constraint.pixelsWide, mh = constraint.pixelsHigh

// The photo, stretched to the model's frame (turned a quarter if portrait), as BGRA.
var input: CVPixelBuffer?
CVPixelBufferCreate(nil, mw, mh, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &input)
guard let input else { fail("cannot allocate the model input") }
CVPixelBufferLockBaseAddress(input, [])
do {
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(input), width: mw, height: mh,
                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(input),
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)
    else { fail("cannot draw the model input") }
    ctx.interpolationQuality = .high
    if portrait {
        // A quarter turn anticlockwise: the photo's top lands on the frame's
        // left, its left edge along the frame's bottom.
        ctx.translateBy(x: CGFloat(mw), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(photo, in: CGRect(x: 0, y: 0, width: mh, height: mw))
    } else {
        ctx.draw(photo, in: CGRect(x: 0, y: 0, width: mw, height: mh))
    }
}
CVPixelBufferUnlockBaseAddress(input, [])

let started = Date()
let output: MLFeatureProvider
do {
    output = try model.prediction(from: MLDictionaryFeatureProvider(
        dictionary: [inputName: MLFeatureValue(pixelBuffer: input)]))
} catch { fail("inference failed: \(error)") }
let elapsed = Date().timeIntervalSince(started)

// The model's map as floats, row 0 at the top, in the model's frame.
func readMap(_ value: MLFeatureValue) -> [Float]? {
    if let buffer = value.imageBufferValue {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w == mw, h == mh, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var out = [Float](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<h {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
                for x in 0..<w { out[y * w + x] = Float(row[x]) }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<w { out[y * w + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h {
                let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { out[y * w + x] = Float(row[x]) }
            }
        default:
            return nil
        }
        return out
    }
    if let array = value.multiArrayValue, array.count == mw * mh {
        return (0..<array.count).map { array[$0].floatValue }
    }
    return nil
}
guard let outName = model.modelDescription.outputDescriptionsByName.keys.sorted().first,
      let feature = output.featureValue(for: outName),
      var raw = readMap(feature)
else { fail("cannot read the model's output") }

// Back to the photo's own orientation (undo the quarter turn).
var rw = mw, rh = mh
if portrait {
    var turned = [Float](repeating: 0, count: raw.count)
    // The frame's column x is the photo's row v, and its row y (top down) is
    // the photo's column u counted from the right: photo (u, v) = frame (v, mh-1-u).
    for v in 0..<mw { for u in 0..<mh { turned[v * mh + u] = raw[(mh - 1 - u) * mw + v] } }
    raw = turned; rw = mh; rh = mw
}

// MARK: - Normalise, upsample, grow the near side

let sorted = raw.sorted()
let lo = sorted[Int(Float(sorted.count - 1) * 0.005)]
let hi = sorted[Int(Float(sorted.count - 1) * 0.995)]
let span = max(hi - lo, 1e-6)
let near = raw.map { min(max(($0 - lo) / span, 0), 1) }

// Bilinear, sample centres aligned.
var full = [Float](repeating: 0, count: width * height)
for y in 0..<height {
    let fy = max(0, min(Float(rh - 1), (Float(y) + 0.5) * Float(rh) / Float(height) - 0.5))
    let y0 = Int(fy), y1 = min(y0 + 1, rh - 1), ty = fy - Float(y0)
    for x in 0..<width {
        let fx = max(0, min(Float(rw - 1), (Float(x) + 0.5) * Float(rw) / Float(width) - 0.5))
        let x0 = Int(fx), x1 = min(x0 + 1, rw - 1), tx = fx - Float(x0)
        let a = near[y0 * rw + x0] + (near[y0 * rw + x1] - near[y0 * rw + x0]) * tx
        let b = near[y1 * rw + x0] + (near[y1 * rw + x1] - near[y1 * rw + x0]) * tx
        full[y * width + x] = a + (b - a) * ty
    }
}

// Max filter, separable, radius about one model pixel.
let radius = max(1, Int((Float(max(width, height)) / Float(max(rw, rh))).rounded()))
func grow(_ src: [Float], horizontal: Bool) -> [Float] {
    var dst = src
    for y in 0..<height {
        for x in 0..<width {
            var m: Float = 0
            for d in -radius...radius {
                let xx = horizontal ? min(max(x + d, 0), width - 1) : x
                let yy = horizontal ? y : min(max(y + d, 0), height - 1)
                m = max(m, src[yy * width + xx])
            }
            dst[y * width + x] = m
        }
    }
    return dst
}
let grown = grow(grow(full, horizontal: true), horizontal: false)
let depth16 = grown.map { UInt16(($0 * 65535).rounded()) }

// MARK: - Write

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(url.path)") }
}

let colorURL = outDir.appendingPathComponent(name + ".jpg")
write(photo, to: colorURL, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.92])

let depthURL = outDir.appendingPathComponent(name + ".depth.png")
let depthData = depth16.withUnsafeBufferPointer { Data(buffer: $0) }
guard let depthImage = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                               bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
                                                        | CGBitmapInfo.byteOrder16Little.rawValue),
                               provider: CGDataProvider(data: depthData as CFData)!,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent)
else { fail("cannot make the depth image") }
write(depthImage, to: depthURL, type: .png)

// The look's own image names win over any stale copy in another format.
for ext in ["jpeg", "png", "heic"] {
    try? FileManager.default.removeItem(at: outDir.appendingPathComponent(name + "." + ext))
}

print(String(format: "depth-window: %@ %dx%d, inference %.0f ms%@ -> %@, %@",
             photoURL.lastPathComponent, width, height, elapsed * 1000,
             portrait ? " (portrait, turned)" : "", colorURL.path, depthURL.lastPathComponent))
