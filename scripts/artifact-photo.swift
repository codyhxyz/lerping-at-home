import AppKit
import Vision
import CoreImage
import CoreML
import ImageIO
import UniformTypeIdentifiers

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data(("artifact-photo: \(text)\n").utf8)); exit(1)
}
func note(_ text: String) { FileHandle.standardError.write(Data(("artifact-photo: \(text)\n").utf8)) }
let args = CommandLine.arguments
guard args.count >= 4, (args.count - 4) % 2 == 0 else {
    fail("usage: ArtifactPhoto <photo-path> <slug> <out-dir> [--title TITLE] [--lore LORE] [--depth-model PATH]")
}
let slug = args[2], directory = URL(fileURLWithPath: args[3])
guard slug.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { fail("invalid slug") }
var options: [String: String] = [:]
for i in stride(from: 4, to: args.count, by: 2) {
    guard ["--title", "--lore", "--depth-model"].contains(args[i]) else { fail("unknown option \(args[i])") }
    options[args[i]] = args[i + 1]
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let photo = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 2800
      ] as CFDictionary) else { fail("cannot decode photo") }
let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
let dateText = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
let parser = DateFormatter()
parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
let captured = dateText.flatMap { parser.date(from: $0) }
let display = DateFormatter()
display.locale = Locale(identifier: "en_US"); display.dateFormat = "MMM d, yyyy '·' h:mm a"
let camera = tiff[kCGImagePropertyTIFFModel as String] as? String
let recovery = captured.map { "Taken \(display.string(from: $0))." } ?? camera.map { "Shot on a \($0)." } ?? "Found on your hard drive."
let context = CIContext()
let original = CIImage(cgImage: photo)
let w = photo.width, h = photo.height
var mask: CIImage?
if #available(macOS 14.0, *) {
    do {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: photo)
        try handler.perform([request])
        if let result = request.results?.first, !result.allInstances.isEmpty {
            mask = CIImage(cvPixelBuffer: try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler))
        }
    } catch { note("Vision unavailable: \(error)") }
}
if mask == nil {
    note("no foreground found; using soft elliptical cutout")
    var bytes = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w {
        let dx = (Double(x) + 0.5 - Double(w)/2) / (Double(w)*0.49)
        let dy = (Double(y) + 0.5 - Double(h)/2) / (Double(h)*0.49)
        let t = min(1, max(0, (1 - sqrt(dx*dx + dy*dy)) / 0.16))
        bytes[y*w+x] = UInt8(255 * t*t*(3-2*t))
    } }
    mask = CIImage(bitmapData: Data(bytes), bytesPerRow: w, size: CGSize(width: w, height: h),
                   format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
}
let cutout = original.applyingFilter("CIBlendWithMask", parameters: [
    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: original.extent),
    kCIInputMaskImageKey: mask!
])
var rgba = [UInt8](repeating: 0, count: w*h*4)
context.render(cutout, toBitmap: &rgba, rowBytes: w*4, bounds: original.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
var left = w, bottom = h, right = 0, top = 0
for y in 0..<h { for x in 0..<w where rgba[(y*w+x)*4+3] > 2 {
    left = min(left,x); right = max(right,x); bottom = min(bottom,y); top = max(top,y)
} }
guard left <= right, bottom <= top else { fail("empty cutout") }
let pad = CGFloat(max(right-left+1,top-bottom+1))*0.06
let crop = CGRect(x: left, y: bottom, width: right-left+1, height: top-bottom+1).insetBy(dx: -pad, dy: -pad).intersection(original.extent).integral
let scale = min(1, 1400 / max(crop.width,crop.height))
func fitted(_ image: CIImage) -> CIImage {
    image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
}
let color = fitted(cutout)
let width = Int(color.extent.width), height = Int(color.extent.height)
let bounds = CGRect(x: 0,y: 0,width: width,height: height)
rgba = [UInt8](repeating: 0, count: width*height*4)
context.render(color, toBitmap: &rgba, rowBytes: width*4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
var modelDepth: [Float]?
if let path = options["--depth-model"], FileManager.default.fileExists(atPath: path) {
    do {
        let model = try MLModel(contentsOf: URL(fileURLWithPath: path))
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: photo).perform([request])
        var predicted: CIImage?
        if let observation = request.results?.first as? VNPixelBufferObservation {
            predicted = CIImage(cvPixelBuffer: observation.pixelBuffer)
        } else if let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
                  let array = observation.featureValue.multiArrayValue, array.shape.count >= 2 {
            let mw = array.shape[array.shape.count-1].intValue
            let mh = array.shape[array.shape.count-2].intValue
            if mw > 0, mh > 0, array.count == mw*mh {
                let values = (0..<array.count).map { array[$0].floatValue }
                predicted = CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) },
                                    bytesPerRow: mw*4, size: CGSize(width: mw,height: mh),
                                    format: .Rf, colorSpace: nil)
            }
        }
        if let image = predicted {
            let full = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w)/image.extent.width, y: CGFloat(h)/image.extent.height))
            var values = [Float](repeating: 0, count: width*height)
            context.render(fitted(full), toBitmap: &values, rowBytes: width*4, bounds: bounds, format: .Rf, colorSpace: nil)
            let sorted = values.filter(\.isFinite).sorted()
            if !sorted.isEmpty {
                let lo = sorted[Int(Double(sorted.count-1)*0.005)], hi = sorted[Int(Double(sorted.count-1)*0.995)]
                modelDepth = values.map { $0.isFinite ? min(1,max(0,($0-lo)/max(hi-lo,0.000001))) : 0 }
            }
        }
        if modelDepth == nil { note("unsupported model output; using offline relief") }
    } catch { note("depth inference failed; using offline relief: \(error)") }
}
// Two-pass chamfer distance gives the silhouette a gently rounded volume.
var distance = (0..<width*height).map { rgba[$0*4+3] < 128 ? Float(0) : Float(min(width,height)) }
for y in 0..<height { for x in 0..<width {
    let i = y*width+x
    distance[i] = min(distance[i], Float(min(x+1,y+1)))
    if x > 0 { distance[i] = min(distance[i],distance[i-1]+1) }
    if y > 0 { distance[i] = min(distance[i],distance[i-width]+1) }
} }
for y in (0..<height).reversed() { for x in (0..<width).reversed() {
    let i = y*width+x
    distance[i] = min(distance[i],Float(min(width-x,height-y)))
    if x+1 < width { distance[i] = min(distance[i],distance[i+1]+1) }
    if y+1 < height { distance[i] = min(distance[i],distance[i+width]+1) }
} }
let maximum = max(1,distance.max() ?? 1)
let depth: [UInt16] = (0..<width*height).map { i in
    let luminance = (Float(rgba[i*4])+Float(rgba[i*4+1])+Float(rgba[i*4+2]))/765
    let relief = 0.25 + 0.65*sin(distance[i]/maximum * .pi/2) + 0.1*luminance
    return UInt16(min(1,max(0,(modelDepth?[i] ?? relief)*Float(rgba[i*4+3])/255))*65535)
}
func write(_ image: CGImage, _ url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination,image,nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot finalize \(url.path)") }
}
do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { fail("\(error)") }
let colorURL = directory.appendingPathComponent(slug+".png")
let depthURL = directory.appendingPathComponent(slug+".depth.png")
let jsonURL = directory.appendingPathComponent(slug+".relic.json")
guard let colorImage = context.createCGImage(color, from: bounds),
      let provider = CGDataProvider(data: depth.withUnsafeBufferPointer { Data(buffer: $0) } as CFData),
      let depthImage = CGImage(width: width,height: height,bitsPerComponent: 16,bitsPerPixel: 16,bytesPerRow: width*2,
        space: CGColorSpaceCreateDeviceGray(),bitmapInfo: [.byteOrder16Little],provider: provider,decode: nil,shouldInterpolate: true,intent: .defaultIntent)
else { fail("cannot create output images") }
write(colorImage,colorURL); write(depthImage,depthURL)
let metadata: [String: Any] = [
    "slug": slug, "title": options["--title"] ?? slug.replacingOccurrences(of: "-", with: " ").capitalized,
    "lore": options["--lore"] ?? "\(recovery) You forgot this was still on your Mac.",
    "capturedAt": captured.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
    "location": NSNull(), "aspect": Double(width)/Double(height),
    "imagePath": colorURL.lastPathComponent, "depthPath": depthURL.lastPathComponent
]
do { try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted,.sortedKeys]).write(to: jsonURL) } catch { fail("\(error)") }
print("artifact-photo: wrote \(colorURL.path)\n\(depthURL.path)\n\(jsonURL.path)")
