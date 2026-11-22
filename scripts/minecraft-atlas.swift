// Packs a Minecraft resource tree's textures into the four texture arrays that
// `Sources/LerpCore/MinecraftAssets.swift` binds for a look that says
// `// lerp-requires: minecraft`. `make minecraft` runs it on the textures of
// the game this Mac has installed.
//
//   MinecraftAtlas <.../assets/minecraft/textures> <out dir> <source label>
//
// Nothing it reads or writes is in the repo: the textures are Mojang's (or a
// resource pack author's), so they come from the user's own copy and the
// packed result lives in ~/Library/Application Support/Lerping/Minecraft.
//
// Four arrays, by what a texture is and how big:
//
//   tiles  16x16   block/   one layer per frame; an animated strip is split
//   items  16x16   item/
//   skins  64x64   anything else up to 64 px: mobs, particles, paintings, the
//                  sun and moon. Drawn unscaled in the layer's top-left corner.
//   maps   256x256 anything up to 256 px: clouds, colormaps, rain, big mobs.
//
// Pixels are converted from sRGB to Display P3, the space every shader here
// writes in, and stored with straight alpha. A fully transparent texel takes
// its layer's mean colour, so a filtered cutout edge fades toward leaf green
// rather than toward black.

import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("minecraft-atlas: " + message + "\n").utf8))
    exit(1)
}

struct Picture {
    let width: Int
    let height: Int
    var rgba: [UInt8]   // straight alpha, Display P3 encoded, top row first
}

// sRGB encoded byte -> linear, and linear -> encoded byte (P3 uses the same curve).
let decode: [Float] = (0..<256).map { i in
    let c = Float(i) / 255
    return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
}
func encode(_ v: Float) -> UInt8 {
    let c = min(max(v, 0), 1)
    let e = c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
    return UInt8((e * 255).rounded())
}

func load(_ url: URL) -> Picture {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { fail("unreadable: \(url.path)") }
    let w = image.width, h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = px.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { fail("cannot decode: \(url.path)") }
    for i in stride(from: 0, to: px.count, by: 4) {
        let a = Float(px[i + 3])
        guard a > 0 else { continue }
        // Un-premultiply, then sRGB -> Display P3 in linear light.
        func straight(_ c: UInt8) -> Float { decode[Int(min(255, (Float(c) * 255 / a).rounded()))] }
        let r = straight(px[i]), g = straight(px[i + 1]), b = straight(px[i + 2])
        px[i]     = encode(0.8224621 * r + 0.1775380 * g)
        px[i + 1] = encode(0.0331941 * r + 0.9668058 * g)
        px[i + 2] = encode(0.0170827 * r + 0.0723974 * g + 0.9105199 * b)
    }
    return Picture(width: w, height: h, rgba: px)
}

/// One `size`-square layer holding the `w`x`h` region of `picture` whose top
/// row is `top`, in the layer's top-left corner.
func layer(_ picture: Picture, top: Int, w: Int, h: Int, size: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: size * size * 4)
    var sum = [Float](repeating: 0, count: 3), weight: Float = 0
    for y in 0..<h {
        for x in 0..<w {
            let s = ((top + y) * picture.width + x) * 4, d = (y * size + x) * 4
            for c in 0..<4 { out[d + c] = picture.rgba[s + c] }
            let a = Float(picture.rgba[s + 3]) / 255
            for c in 0..<3 { sum[c] += Float(picture.rgba[s + c]) * a }
            weight += a
        }
    }
    let mean = (0..<3).map { weight > 0 ? UInt8((sum[$0] / weight).rounded()) : 0 }
    for i in stride(from: 0, to: out.count, by: 4) where out[i + 3] == 0 {
        for c in 0..<3 { out[i + c] = mean[c] }
    }
    return out
}

/// `block/oak_log.png` -> `OAK_LOG`; `entity/pig/pig_temperate.png` ->
/// `PIG_TEMPERATE` (a folder that only repeats the start of the next part is
/// dropped); `environment/clouds.png` -> `ENVIRONMENT_CLOUDS`.
func constantName(_ relative: String, dropping root: String, full: Bool = false) -> String {
    var parts = relative.dropLast(4).split(separator: "/").map(String.init)
    if parts.first == root, !full { parts.removeFirst() }
    var kept: [String] = []
    for (i, part) in parts.enumerated() {
        if !full, i + 1 < parts.count, parts[i + 1].hasPrefix(part) { continue }
        kept.append(part)
    }
    let joined = kept.joined(separator: "_").uppercased()
    return String(joined.map { $0.isLetter || $0.isNumber ? $0 : "_" })
}

/// A strip's animation, from its `.mcmeta`: ticks per frame, and the order the
/// frames play in when the file lists one (lava plays 0…19 and back, so its
/// 20 pictures become 38 layers in playing order, and a look just counts up).
func animation(of relative: String, in root: URL, frames: Int) -> (order: [Int], ticks: Int) {
    var ticks = 1
    var order = Array(0..<frames)
    if let data = try? Data(contentsOf: root.appendingPathComponent(relative + ".mcmeta")),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let animation = json["animation"] as? [String: Any] {
        if let frametime = animation["frametime"] as? Int { ticks = max(1, frametime) }
        if let listed = animation["frames"] as? [Any] {
            let indices = listed.compactMap { entry -> Int? in
                if let i = entry as? Int { return i }
                return (entry as? [String: Any])?["index"] as? Int
            }
            if !indices.isEmpty, indices.allSatisfy({ $0 >= 0 && $0 < frames }) { order = indices }
        }
    }
    return (order, ticks)
}

let args = CommandLine.arguments
guard args.count == 4 else { fail("usage: MinecraftAtlas <textures dir> <out dir> <source label>") }
let root = URL(fileURLWithPath: args[1]).standardizedFileURL
let out = URL(fileURLWithPath: args[2])
let tile = 16, skin = 64, map = 256

let folders = ["block", "item", "entity", "environment", "colormap", "painting", "particle"]
var files: [String] = []
for folder in folders {
    let base = root.appendingPathComponent(folder)
    guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
        fail("no \(folder)/ under \(root.path)")
    }
    for case let url as URL in walker where url.pathExtension == "png" {
        files.append(String(url.standardizedFileURL.path.dropFirst(root.path.count + 1)))
    }
}
// Single textures from folders not packed whole: the round shadow the game
// draws under every mob (the mobs kit's mcMobShadow).
for single in ["misc/shadow.png"] {
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent(single).path) else {
        fail("no \(single) under \(root.path)")
    }
    files.append(single)
}
files.sort()

var tiles = Data(), items = Data(), skins = Data(), maps = Data()
var tileCount = 0, itemCount = 0, skinCount = 0, mapCount = 0
var metal: [String] = [], index: [String] = [], skipped: [String] = []
var seen = Set<String>()

/// The short name, or the whole path spelled out when a short name is taken
/// (`entity/banner_base.png` and `entity/banner/base.png` both shorten to
/// BANNER_BASE; the second becomes ENTITY_BANNER_BASE).
func uniqueName(_ prefix: String, _ relative: String, dropping root: String) -> String {
    let short = prefix + constantName(relative, dropping: root)
    if !seen.contains(short) { return short }
    let long = prefix + constantName(relative, dropping: root, full: true)
    guard !seen.contains(long) else { fail("no free name for \(relative) (tried \(short), \(long))") }
    return long
}

func declare(_ name: String, _ lines: [String], _ note: String) {
    guard seen.insert(name).inserted else { fail("two textures both want the name \(name)") }
    metal += lines
    index.append(name.padding(toLength: 52, withPad: " ", startingAt: 0) + " " + note)
}

for relative in files {
    let picture = load(root.appendingPathComponent(relative))
    let w = picture.width, h = picture.height
    let folder = String(relative.prefix { $0 != "/" })

    if folder == "block", w == tile, h % tile == 0 {
        let (order, ticks) = animation(of: relative, in: root, frames: h / tile)
        let frames = order.count
        let name = uniqueName("MC_", relative, dropping: "block")
        var lines = ["constant int \(name) = \(tileCount);"]
        if frames > 1 {
            lines.append("constant int \(name)_FRAMES = \(frames);")
            lines.append("constant int \(name)_TICKS = \(ticks);")
        }
        declare(name, lines, "tiles[\(tileCount)]  \(relative)" + (frames > 1 ? "  \(frames) frames, \(ticks) ticks each" : ""))
        for f in order { tiles.append(contentsOf: layer(picture, top: f * tile, w: tile, h: tile, size: tile)) }
        tileCount += frames
    } else if folder == "item", w == tile, h == tile {
        let name = uniqueName("MC_ITEM_", relative, dropping: "item")
        declare(name, ["constant int \(name) = \(itemCount);"], "items[\(itemCount)]  \(relative)")
        items.append(contentsOf: layer(picture, top: 0, w: tile, h: tile, size: tile))
        itemCount += 1
    } else if w <= skin, h > w, h % w == 0,
              FileManager.default.fileExists(atPath: root.appendingPathComponent(relative + ".mcmeta").path) {
        // An animated strip that is not a 16 px tile (flowing water and lava
        // are 32 px wide): one skin layer per frame.
        let (order, ticks) = animation(of: relative, in: root, frames: h / w)
        let frames = order.count
        let name = uniqueName("MCS_", relative, dropping: "entity")
        declare(name, ["constant int \(name) = \(skinCount);",
                       "constant float2 \(name)_SIZE = float2(\(w), \(w));",
                       "constant int \(name)_FRAMES = \(frames);",
                       "constant int \(name)_TICKS = \(ticks);"],
                "skins[\(skinCount)]  \(relative)  \(w)x\(w)  \(frames) frames, \(ticks) ticks each")
        for f in order { skins.append(contentsOf: layer(picture, top: f * w, w: w, h: w, size: skin)) }
        skinCount += frames
    } else if w <= skin, h <= skin {
        let name = uniqueName("MCS_", relative, dropping: "entity")
        declare(name, ["constant int \(name) = \(skinCount);",
                       "constant float2 \(name)_SIZE = float2(\(w), \(h));"],
                "skins[\(skinCount)]  \(relative)  \(w)x\(h)")
        skins.append(contentsOf: layer(picture, top: 0, w: w, h: h, size: skin))
        skinCount += 1
    } else if w <= map, h <= map {
        let name = uniqueName("MCM_", relative, dropping: "entity")
        declare(name, ["constant int \(name) = \(mapCount);",
                       "constant float2 \(name)_SIZE = float2(\(w), \(h));"],
                "maps[\(mapCount)]  \(relative)  \(w)x\(h)")
        maps.append(contentsOf: layer(picture, top: 0, w: w, h: h, size: map))
        mapCount += 1
    } else {
        skipped.append("\(relative)  \(w)x\(h)")
    }
}

// The arrays are 16 px tiles by construction; a higher-resolution pack would
// land every block in `skins` and leave `tiles` empty. Say so instead.
guard tileCount > 0, seen.contains("MC_STONE") else {
    fail("no 16x16 block textures found; only 16x resource packs are supported")
}
for (count, what) in [(tileCount, "tiles"), (itemCount, "items"), (skinCount, "skins"), (mapCount, "maps")]
where count > 2048 {
    fail("\(count) \(what) layers; a Metal texture array holds 2048")
}

do {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try tiles.write(to: out.appendingPathComponent("tiles.rgba"))
    try items.write(to: out.appendingPathComponent("items.rgba"))
    try skins.write(to: out.appendingPathComponent("skins.rgba"))
    try maps.write(to: out.appendingPathComponent("maps.rgba"))
    try (metal.joined(separator: "\n") + "\n")
        .write(to: out.appendingPathComponent("atlas.metal"), atomically: true, encoding: .utf8)
    let header = "# Minecraft textures packed from \(args[3]). One line per constant a shader can use.\n"
        + "# tiles and items are 16x16 layers; skins are 64x64 and maps 256x256, picture in the top-left corner.\n"
    let tail = skipped.isEmpty ? "" : "\n# Left out (larger than 256 px):\n" + skipped.map { "#   " + $0 }.joined(separator: "\n") + "\n"
    try (header + index.joined(separator: "\n") + "\n" + tail)
        .write(to: out.appendingPathComponent("atlas.txt"), atomically: true, encoding: .utf8)
    // Written last: its presence is what says the folder is complete.
    let manifest: [String: Any] = ["source": args[3], "tile": tile, "tiles": tileCount, "items": itemCount,
                                   "skin": skin, "skins": skinCount, "map": map, "maps": mapCount]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        .write(to: out.appendingPathComponent("atlas.json"))
} catch {
    fail("cannot write \(out.path): \(error.localizedDescription)")
}
print("minecraft-atlas: \(tileCount) tile layers, \(itemCount) items, \(skinCount) skins, \(mapCount) maps"
      + (skipped.isEmpty ? "" : ", \(skipped.count) left out") + " -> \(out.path)")
