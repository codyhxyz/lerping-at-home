import AppKit
import CoreText
import Metal

/// A look's `// lerp-caption…:` lines, set in type and kept as a texture the
/// fragment shader composites over the capture (`lerpSplatCaption` in the splat
/// prelude). The texture is a single coverage channel just bigger than the
/// type, mipmapped so the shader can blur the glyphs into a shadow; where it
/// sits on screen goes to the look as `LerpSplatView.caption`.
///
/// Type is sized from the drawable's height, so a caption reads the same on a
/// laptop panel and a 5K display, and is set again only when the lines or the
/// drawable size change. Nothing here depends on time: fading in is the look's
/// business, from `u.time`.
final class LerpSplatCaptionLayer {
    private let device: MTLDevice
    private let lock = NSLock()
    private var lines: [LerpCaptionLine] = []
    private var builtFor: (lines: [LerpCaptionLine], size: SIMD2<Float>)?
    private(set) var texture: MTLTexture?
    /// The panel, drawable pixels, y down: x, y, width, height. Zero when there
    /// is no caption.
    private(set) var rect = SIMD4<Float>(0, 0, 0, 0)
    private var needsMipmaps = false
    private lazy var empty: MTLTexture? = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        let t = device.makeTexture(descriptor: d)
        var zero: UInt8 = 0
        t?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 1)
        return t
    }()

    init(device: MTLDevice) { self.device = device }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return lines.isEmpty }

    func set(_ new: [LerpCaptionLine]) {
        lock.lock(); lines = new; lock.unlock()
    }

    /// The texture to bind at `texture(2)`: the caption, or a transparent texel.
    var bindable: MTLTexture? { texture ?? empty }

    /// Sets the type again if the lines or the drawable changed, and builds the
    /// glyph mipmaps on `commandBuffer` the first frame after.
    func update(drawable size: SIMD2<Float>, commandBuffer: MTLCommandBuffer) {
        lock.lock(); let current = lines; lock.unlock()
        if current.isEmpty {
            texture = nil; rect = .zero; builtFor = nil
            return
        }
        if builtFor?.lines != current || builtFor?.size != size {
            build(current, size: size)
            builtFor = (current, size)
        }
        if needsMipmaps, let texture, texture.mipmapLevelCount > 1,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "splat caption mipmaps"
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            needsMipmaps = false
        }
    }

    /// Set like the caption under a plate in an art book, straight onto the
    /// image with no panel: the title in Iowan Old Style, the description
    /// under it in the italic, the credit last in small roman. One family,
    /// three sizes, left aligned and ragged, the lines balanced so a body that
    /// needs two lines gets two even ones rather than a long one and a widow.
    ///
    /// Sizes follow the drawable's height. Where the smaller lines would drop
    /// under a size that can still be read, the caption steps down to its
    /// title alone, and below that to nothing. A word never breaks: the
    /// measure is never narrower than the widest word, and the type shrinks
    /// if even that would not fit the screen.
    private func build(_ lines: [LerpCaptionLine], size: SIMD2<Float>) {
        let h = CGFloat(size.y), w = CGFloat(size.x)
        texture = nil; rect = .zero
        let margin = (0.065 * h).rounded()
        // The tiers: everything, the title alone, or nothing.
        let readable: CGFloat = 9
        let full = 0.0125 * h >= readable * 0.9
        // A gallery thumbnail names its look under the picture, and a label
        // that small could only sit on the subject.
        guard h >= 160 else { return }
        var titleSize = full ? 0.034 * h : max(0.034 * h, min(11, 0.09 * h))
        var bodySize = max(readable, 0.0185 * h), creditSize = max(readable, 0.0138 * h)
        let shown = full ? lines : lines.filter { $0.role == .title }
        guard !shown.isEmpty else { return }

        func font(_ name: String, _ size: CGFloat) -> NSFont {
            NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
        }
        // Shrink everything together until the widest word fits the screen.
        let room = max(1, w - 2 * margin)
        func widestWord(_ ts: CGFloat, _ bs: CGFloat, _ cs: CGFloat) -> CGFloat {
            shown.map { line -> CGFloat in
                let f: NSFont = line.role == .title ? font("IowanOldStyle-Roman", ts)
                    : line.role == .body ? font("IowanOldStyle-Italic", bs) : font("IowanOldStyle-Roman", cs)
                return line.text.split(separator: " ").map {
                    NSAttributedString(string: String($0), attributes: [.font: f]).size().width
                }.max() ?? 0
            }.max() ?? 0
        }
        let widest = widestWord(titleSize, bodySize, creditSize)
        if widest > room {
            let k = room / widest
            titleSize *= k; bodySize *= k; creditSize *= k
        }
        titleSize = titleSize.rounded(); bodySize = bodySize.rounded(); creditSize = creditSize.rounded()

        // The title in the titling cut once it is display sized. The smaller
        // lines take old-style figures, and in the credit a word set all in
        // capitals (a licence, an acronym) takes small capitals, so neither
        // shouts over the names round it.
        func featured(_ f: NSFont, _ features: [(Int, Int)]) -> NSFont {
            NSFont(descriptor: f.fontDescriptor.addingAttributes([.featureSettings: features.map {
                [NSFontDescriptor.FeatureKey.typeIdentifier: $0.0, .selectorIdentifier: $0.1]
            }]), size: f.pointSize) ?? f
        }
        let figures = [(kNumberCaseType, kLowerCaseNumbersSelector)]
        let smallCaps = figures + [(kUpperCaseType, kUpperCaseSmallCapsSelector)]
        let titleFont = font(titleSize >= 30 ? "IowanOldStyle-Titling" : "IowanOldStyle-Roman", titleSize)
        let bodyFont = featured(font("IowanOldStyle-Italic", bodySize), figures)
        let creditFont = featured(font("IowanOldStyle-Roman", creditSize), figures)
        let capitals = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\\p{Lu}{2,}(?:-\\p{Lu}{2,})*(?![\\p{L}\\p{N}])")

        // Coverage carries each line's weight in the label: the title at full
        // strength, the rest quieter.
        let block = NSMutableAttributedString()
        var previous: LerpCaptionLine.Role?
        for line in shown {
            let (f, ink, leading): (NSFont, CGFloat, CGFloat) = switch line.role {
            case .title: (titleFont, 1.0, 1.08)
            case .body: (bodyFont, 0.84, 1.22)
            case .credit: (creditFont, 0.64, 1.25)
            }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            para.lineHeightMultiple = leading
            para.paragraphSpacingBefore = switch (previous, line.role) {
            case (nil, _): 0
            case (.title, .body): 0.12 * bodySize
            case (_, .credit) where previous != .credit: 1.1 * bodySize
            default: 0
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: f, .foregroundColor: NSColor(white: ink, alpha: 1), .paragraphStyle: para,
                .kern: line.role == .title ? -0.006 * titleSize : 0.0,
            ]
            if block.length > 0 { block.append(NSAttributedString(string: "\n", attributes: attrs)) }
            // A hyphenated compound stays on one line, and an apostrophe is
            // the typeset one, to match the curly quotes a caption already uses.
            let typeset = line.text.replacingOccurrences(of: "-", with: "\u{2011}")
                .replacingOccurrences(of: "(?<=\\p{L})'", with: "\u{2019}", options: .regularExpression)
            let text = NSMutableAttributedString(string: typeset, attributes: attrs)
            if line.role == .credit, let capitals {
                for m in capitals.matches(in: line.text, range: NSRange(location: 0, length: (line.text as NSString).length)) {
                    text.addAttributes([.font: featured(f, smallCaps), .kern: 0.05 * f.pointSize], range: m.range)
                }
            }
            block.append(text)
            previous = line.role
        }

        func set(_ width: CGFloat) -> (CGSize, Int) {
            let setter = CTFramesetterCreateWithAttributedString(block as CFAttributedString)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(
                setter, CFRange(location: 0, length: 0), nil,
                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            return (CGSize(width: ceil(fit.width), height: ceil(fit.height)), CFArrayGetCount(CTFrameGetLines(frame)))
        }
        // The measure: about fifty characters of the description, never more
        // than the screen allows, never less than the widest word.
        let floorW = ceil(widestWord(titleSize, bodySize, creditSize)) + 1
        let maxText = max(floorW, min(room, 0.62 * w, 26 * bodySize))
        // Balance: the narrowest measure that needs no more lines than the
        // widest one does.
        let lineCount = set(maxText).1
        var lo = floorW, hi = maxText
        while hi - lo > 2 {
            let mid = (lo + hi) / 2
            if set(mid).1 <= lineCount { hi = mid } else { lo = mid }
        }
        let measure = hi + 1
        let textSize = set(measure).0

        // Room round the type for the shadow the shader blurs out of it.
        let pad = ceil(max(2, 0.022 * h))
        let pw = Int(ceil(textSize.width + 2 * pad)), ph = Int(ceil(textSize.height + 2 * pad))
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSubpixelPositioning(true)
        let setter = CTFramesetterCreateWithAttributedString(block as CFAttributedString)
        let r = CGRect(x: pad, y: pad, width: measure, height: textSize.height)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: r, transform: nil), nil), ctx)
        guard let data = ctx.data else { return }

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: pw, height: ph, mipmapped: true)
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return }
        t.label = "splat caption"
        // A bitmap context's memory starts at its top row, so it uploads as
        // is: y down, like the drawable.
        t.replace(region: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0, withBytes: data, bytesPerRow: pw)
        texture = t
        needsMipmaps = true
        // The type's left edge and the bottom of its last line sit on the margin.
        rect = SIMD4(Float(margin - pad), Float(h - margin + pad) - Float(ph), Float(pw), Float(ph))
    }
}
