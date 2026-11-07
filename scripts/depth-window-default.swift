// The `depth-window` look's default picture: a lake at dusk under a low sun,
// ridges stepping back into haze, a few pines on the near shore, all reflected
// in the water. Drawn here, procedurally, together with its exact depth, so the
// look works out of the box with no photo, no model and no third-party licence.
//
//     DepthWindowDefault <out-dir>     (`make images` runs it)
//
// writes <out-dir>/depth-window.png (colour, 8-bit, tagged Display P3 — the
// space the screen layer is tagged with, so it reaches the screen unconverted)
// and <out-dir>/depth-window.depth.png (16-bit grey nearness: 1 nearest, 0 the
// sky, proportional to 1/distance, the convention a monocular depth model such
// as Depth Anything uses and `ImageData.swift` documents).
//
// Deterministic: integer hashes, no clock, no randomness, so `make clean &&
// make images` reproduces the same bytes.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 1920, height = 1200
let supersample = 3                      // 3×3 per pixel

// MARK: - Noise

@inline(__always) func hash(_ x: Int32, _ y: Int32, _ s: Int32) -> Float {
    var h = UInt32(bitPattern: x &* 374761393 &+ y &* 668265263 &+ s &* 1442695041)
    h = (h ^ (h >> 13)) &* 1274126177
    h ^= h >> 16
    return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
}

@inline(__always) func noise(_ x: Float, _ y: Float, _ s: Int32) -> Float {
    let xi = floor(x), yi = floor(y)
    let fx = x - xi, fy = y - yi
    let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
    let ix = Int32(xi), iy = Int32(yi)
    let a = hash(ix, iy, s), b = hash(ix + 1, iy, s)
    let c = hash(ix, iy + 1, s), d = hash(ix + 1, iy + 1, s)
    return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy
}

func fbm(_ x: Float, _ y: Float, _ s: Int32, octaves: Int = 5) -> Float {
    var sum: Float = 0, amp: Float = 0.5, f: Float = 1, norm: Float = 0
    for o in 0..<octaves {
        sum += amp * noise(x * f, y * f, s &+ Int32(o) &* 17)
        norm += amp; amp *= 0.5; f *= 2.03
    }
    return sum / norm
}

/// Sharp-crested, for mountain skylines.
func ridged(_ x: Float, _ s: Int32) -> Float {
    var sum: Float = 0, amp: Float = 0.5, f: Float = 1, norm: Float = 0
    for o in 0..<6 {
        let n = 1 - abs(2 * noise(x * f, 0.5, s &+ Int32(o) &* 31) - 1)
        sum += amp * n * n
        norm += amp; amp *= 0.5; f *= 2.1
    }
    return sum / norm
}

// MARK: - Scene
//
// Screen coordinates: X right, Y up, the short side spanning −0.5…0.5. A pinhole
// camera `camH` above the water with its horizon at `horizon`: a point at
// distance d and world height h is at Y = horizon + (h − camH)/d.

typealias RGB = SIMD3<Float>
let horizon: Float = -0.04
let camH: Float = 0.22
let nearest: Float = 0.8                 // distance that maps to nearness 1
let sun = SIMD2<Float>(0.30, horizon + 0.19)

func mix(_ a: RGB, _ b: RGB, _ t: Float) -> RGB { a + (b - a) * t }
func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
}

let haze = RGB(0.93, 0.62, 0.48)

func sky(_ X: Float, _ Y: Float) -> RGB {
    let h = max(Y - horizon, 0)
    var c = mix(haze, RGB(0.55, 0.36, 0.52), smooth(0.0, 0.18, h))
    c = mix(c, RGB(0.20, 0.17, 0.36), smooth(0.12, 0.42, h))
    c = mix(c, RGB(0.07, 0.08, 0.20), smooth(0.38, 0.62, h))
    let ds = SIMD2(X - sun.x, (Y - sun.y) * 1.15)
    let r = (ds * ds).sum().squareRoot()
    c += RGB(1.0, 0.62, 0.30) * (0.55 * exp(-r * 9) + 0.25 * exp(-r * 2.5))
    c = mix(c, RGB(1.0, 0.93, 0.78), smooth(0.026, 0.022, r))
    // Cloud streaks, lit from below by the sun.
    let band = smooth(0.06, 0.12, h) * (1 - smooth(0.30, 0.46, h))
    let n = fbm(X * 2.2 + 4.0, h * 16.0, 7)
    let cloud = smooth(0.52, 0.72, n) * band
    let lit = RGB(1.0, 0.66, 0.52) * (0.55 + 0.6 * exp(-r * 3)) * (1 - 0.6 * smooth(0.1, 0.4, h))
    return mix(c, lit + RGB(0.08, 0.04, 0.12), cloud * 0.8)
}

struct Land {
    var distance: Float
    var color: RGB
    var top: (Float) -> Float            // skyline Y at X
    var base: Float { horizon - camH / distance }
}

let lands: [Land] = [                    // nearest first
    Land(distance: 1.15, color: RGB(0.05, 0.05, 0.07)) { X in   // near shore, right
        horizon - 0.25 + 0.36 * smooth(0.30, 0.75, X) + 0.025 * fbm(X * 9, 0.3, 61)
    },
    Land(distance: 1.6, color: RGB(0.08, 0.07, 0.11)) { X in    // headland, left
        horizon - 0.16 + 0.30 * smooth(-0.15, -0.70, X) + 0.03 * fbm(X * 7, 0.7, 53)
    },
    Land(distance: 2.6, color: RGB(0.16, 0.12, 0.20)) { X in
        horizon + 0.035 + 0.075 * fbm(X * 2.6 + 1.3, 0.2, 41) - 0.06 * exp(-pow((X - 0.18) * 3.5, 2))
    },
    Land(distance: 4.2, color: RGB(0.30, 0.21, 0.32)) { X in
        horizon + 0.085 + 0.08 * ridged(X * 1.6 + 7.0, 29)
    },
    Land(distance: 7.0, color: RGB(0.50, 0.36, 0.48)) { X in
        horizon + 0.12 + 0.16 * ridged(X * 1.2 + 3.1, 17)
    },
]

// Skylines tabulated once, finer than the supersampling, and interpolated:
// they depend on X alone, and every sample would otherwise rebuild five fBms.
let tableStep: Float = 1 / Float(height * supersample * 2)
let tableMin: Float = -1.2
let tables: [[Float]] = lands.map { land in
    (0..<Int(2.4 / tableStep) + 2).map { land.top(tableMin + Float($0) * tableStep) }
}
func topAt(_ i: Int, _ X: Float) -> Float {
    let f = min(max((X - tableMin) / tableStep, 0), Float(tables[i].count - 2))
    let j = Int(f), t = f - Float(j)
    return tables[i][j] + (tables[i][j + 1] - tables[i][j]) * t
}

struct Pine { var x: Float; var land: Int; var height: Float }
let pines: [Pine] = [
    Pine(x: 0.52, land: 0, height: 0.30), Pine(x: 0.61, land: 0, height: 0.38),
    Pine(x: 0.70, land: 0, height: 0.27), Pine(x: 0.78, land: 0, height: 0.42),
    Pine(x: -0.58, land: 1, height: 0.21), Pine(x: -0.66, land: 1, height: 0.26),
    Pine(x: -0.74, land: 1, height: 0.18),
]

/// Whether (X, Y) is inside a pine's silhouette.
func inPine(_ p: Pine, _ X: Float, _ Y: Float) -> Bool {
    let baseY = topAt(p.land, p.x) - 0.012
    let v = (Y - baseY) / p.height
    guard v >= 0, v <= 1 else { return false }
    let dx = abs(X - p.x) / p.height
    if v < 0.10 { return dx < 0.022 }
    let tier = (v * 7).truncatingRemainder(dividingBy: 1)
    let half = 0.21 * (1 - v) * (0.62 + 0.38 * (1 - tier))
        + 0.025 * (noise(v * 40, p.x * 13, 71) - 0.5)
    return dx < max(half, 0.008)
}

/// What a ray towards (X, Y) meets above the water: colour and distance
/// (infinity for the sky). `beyond` skips anything nearer than it.
func scene(_ X: Float, _ Y: Float, beyond: Float = 0) -> (RGB, Float) {
    for (i, land) in lands.enumerated() where land.distance > beyond {
        for p in pines where p.land == i && inPine(p, X, Y) {
            let d = land.distance - 0.05
            var c = RGB(0.025, 0.035, 0.04)
            if (X - p.x) * (sun.x - p.x) > 0 {       // rim on the sun's side
                c += RGB(0.9, 0.45, 0.2) * 0.08 * smooth(0.6, 0.0, abs(X - p.x) / p.height)
            }
            return (fog(c, d), d)
        }
        let top = topAt(i, X)
        if Y < top && Y >= land.base {
            let d = land.distance
            // Faces: lit nearer the skyline and on the sun's side, with texture.
            let below = top - Y
            let tex = fbm(X * 30 / d, Y * 45 / d, Int32(i) &+ 90)
            var c = land.color * (0.55 + 0.9 * tex)
            c += RGB(1.0, 0.55, 0.30) * 0.10 * exp(-below * 40) * exp(-abs(X - sun.x) * 1.5)
            if i == lands.count - 1 {        // snow on the far peaks
                let snow = smooth(horizon + 0.17, horizon + 0.24, Y + 0.03 * tex)
                c = mix(c, RGB(0.95, 0.74, 0.70), snow * 0.75)
            }
            return (fog(c, d), d)
        }
    }
    return (sky(X, Y), .infinity)
}

func fog(_ c: RGB, _ d: Float) -> RGB { mix(c, haze * 0.9, 1 - exp(-d * 0.12)) }

/// Colour and distance for one sample.
func sample(_ X: Float, _ Y: Float) -> (RGB, Float) {
    let (above, d) = scene(X, Y)
    if d.isFinite || Y >= horizon { return (above, d) }
    // Water: distance from the plane, then the mirror image of whatever lies
    // beyond that point, ripples shifting it sideways.
    let dw = camH / (horizon - Y)
    let ripple = (fbm(X * 6 / dw, dw * 3, 11, octaves: 3) - 0.5) * 0.02 / max(dw, 0.3)
    var bestColor = sky(X + ripple, 2 * horizon - Y)
    for land in lands where land.distance > dw {
        let ym = 2 * horizon - Y - 2 * camH / land.distance
        let (c, dd) = scene(X + ripple, ym, beyond: land.distance - 0.001)
        if dd <= land.distance + 0.001 { bestColor = c; break }
    }
    var c = bestColor * 0.72 + RGB(0.02, 0.03, 0.06)
    let streak = fbm(X * 3 / dw, dw * 14, 23, octaves: 3)
    c *= 0.86 + 0.28 * streak
    let glint = exp(-pow((X - sun.x) / (0.02 + 0.03 * (horizon - Y)), 2))
        * smooth(0.55, 0.85, fbm(X * 50, dw * 40, 5, octaves: 2))
    c += RGB(1.0, 0.7, 0.4) * glint * 0.5
    return (c, dw)
}

// MARK: - Render

var color = [UInt8](repeating: 0, count: width * height * 4)
var near = [Float](repeating: 0, count: width * height)
let ss = supersample
color.withUnsafeMutableBufferPointer { colorBuf in
    near.withUnsafeMutableBufferPointer { nearBuf in
        let cb = colorBuf, nb = nearBuf
        DispatchQueue.concurrentPerform(iterations: height) { y in
            for x in 0..<width {
                var acc = RGB(0, 0, 0)
                var n: Float = 0
                for sy in 0..<ss { for sx in 0..<ss {
                    let px = Float(x) + (Float(sx) + 0.5) / Float(ss)
                    let py = Float(y) + (Float(sy) + 0.5) / Float(ss)
                    let X = (px - Float(width) / 2) / Float(height)
                    let Y = (Float(height) / 2 - py) / Float(height)
                    let (c, d) = sample(X, Y)
                    acc += c
                    // The nearest thing in the pixel owns it, so its rim
                    // travels with it rather than smearing the background.
                    n = max(n, d.isFinite ? min(nearest / d, 1) : 0)
                }}
                acc /= Float(ss * ss)
                let i = y * width + x
                for k in 0..<3 {
                    cb[i * 4 + k] = UInt8(max(0, min(255, (acc[k] * 255).rounded())))
                }
                cb[i * 4 + 3] = 255
                nb[i] = n
            }
        }
    }
}

// One more pixel of the nearer side, for the anti-aliased rim.
var depth16 = [UInt16](repeating: 0, count: width * height)
for y in 0..<height {
    for x in 0..<width {
        var n: Float = 0
        for dy in -1...1 { for dx in -1...1 {
            let xx = min(max(x + dx, 0), width - 1), yy = min(max(y + dy, 0), height - 1)
            n = max(n, near[yy * width + xx])
        }}
        depth16[y * width + x] = UInt16((n * 65535).rounded())
    }
}

// MARK: - Write

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: DepthWindowDefault <out-dir>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let colorImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: width * 4, space: p3,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: CGDataProvider(data: Data(color) as CFData)!,
                         decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
write(colorImage, to: out.appendingPathComponent("depth-window.png"))

let depthData = depth16.withUnsafeBufferPointer { Data(buffer: $0) }
let depthImage = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                         bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
                                                  | CGBitmapInfo.byteOrder16Little.rawValue),
                         provider: CGDataProvider(data: depthData as CFData)!,
                         decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
write(depthImage, to: out.appendingPathComponent("depth-window.depth.png"))
print("wrote \(out.path)/depth-window.png, depth-window.depth.png (\(width)x\(height))")
