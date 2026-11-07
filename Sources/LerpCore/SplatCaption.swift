import AppKit
import CoreText
import Metal

/// A look's `// lerp-caption…:` lines, set in type and kept as a texture the
/// fragment shader composites over the capture (`lerpSplatCaption` in the splat
/// prelude). The texture is a single coverage channel the size of the caption's
/// panel, mipmapped so a look can blur the glyphs into a halo; where the panel
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

    /// Set like a gallery wall label: a serif title in regular weight, a
    /// quieter sans line or two under it, and the credit in small tracked
    /// capitals under a hairline. The lines are balanced, so a body that
    /// needs two lines gets two even ones rather than a long one and a widow.
    private func build(_ lines: [LerpCaptionLine], size: SIMD2<Float>) {
        let h = CGFloat(size.y), w = CGFloat(size.x)
        let titleSize = (0.0235 * h).rounded()
        let bodySize = (0.0128 * h).rounded()
        let creditSize = max(9, (0.0092 * h).rounded())
        let padX = (0.026 * h).rounded(), padY = (0.022 * h).rounded()
        let margin = (0.055 * h).rounded()
        let maxText = max(4 * titleSize, min(0.36 * w - 2 * padX, 0.30 * h))
        let hairline = max(1, (0.0007 * h).rounded())

        let serif = NSFont.systemFont(ofSize: titleSize, weight: .regular).fontDescriptor.withDesign(.serif)
        let titleFont = serif.flatMap { NSFont(descriptor: $0, size: titleSize) }
            ?? NSFont.systemFont(ofSize: titleSize, weight: .regular)
        let bodyFont = NSFont.systemFont(ofSize: bodySize, weight: .regular)
        // Small capitals, so a name keeps the capitals its owner gave it
        // ("spAItial", "SuperDelphi") and still sets as one even row.
        let creditBase = NSFont.systemFont(ofSize: creditSize * 1.22, weight: .medium)
        let creditFont = NSFont(descriptor: creditBase.fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kLowerCaseSmallCapsSelector]],
        ]), size: creditSize * 1.22) ?? creditBase

        func paragraph(lineHeight: CGFloat, before: CGFloat) -> NSParagraphStyle {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            para.lineHeightMultiple = lineHeight
            para.paragraphSpacingBefore = before
            return para
        }
        let block = NSMutableAttributedString()
        let credit = NSMutableAttributedString()
        for line in lines {
            switch line.role {
            case .title, .body:
                let title = line.role == .title
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: title ? titleFont : bodyFont,
                    .foregroundColor: NSColor(white: title ? 0.97 : 0.70, alpha: 1),
                    .paragraphStyle: paragraph(lineHeight: title ? 1.0 : 1.3,
                                               before: block.length > 0 ? (title ? 0.3 : 0.55) * bodySize : 0),
                    .kern: title ? -0.012 * titleSize : 0.0,
                ]
                if block.length > 0 { block.append(NSAttributedString(string: "\n", attributes: attrs)) }
                // A hyphenated compound stays on one line.
                block.append(NSAttributedString(string: line.text.replacingOccurrences(of: "-", with: "\u{2011}"),
                                                attributes: attrs))
            case .credit:
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: creditFont,
                    .foregroundColor: NSColor(white: 0.5, alpha: 1),
                    .paragraphStyle: paragraph(lineHeight: 1.2, before: 0),
                    .kern: 0.09 * creditSize,
                ]
                if credit.length > 0 { credit.append(NSAttributedString(string: "\n", attributes: attrs)) }
                credit.append(NSAttributedString(string: line.text, attributes: attrs))
            }
        }

        // Size of a string set at `width`, and how many lines it took.
        func set(_ text: NSAttributedString, _ width: CGFloat) -> (CTFramesetter, CGSize, Int) {
            let setter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(
                setter, CFRange(location: 0, length: 0), nil,
                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            return (setter, CGSize(width: ceil(fit.width), height: ceil(fit.height)),
                    CFArrayGetCount(CTFrameGetLines(frame)))
        }
        // Balance: the narrowest measure that needs no more lines than the
        // widest one does.
        var measure = maxText
        if block.length > 0 {
            let lineCount = set(block, maxText).2
            var lo = min(maxText, set(NSAttributedString(string: lines.first { $0.role == .title }?.text ?? "",
                                                          attributes: [.font: titleFont]), maxText).1.width)
            var hi = maxText
            while hi - lo > 2 {
                let mid = (lo + hi) / 2
                if set(block, mid).2 <= lineCount { hi = mid } else { lo = mid }
            }
            measure = hi + 1
        }
        let (blockSetter, blockSize, _) = set(block, measure)
        let (creditSetter, creditSize2, _) = set(credit, maxText)
        let hasCredit = credit.length > 0, hasBlock = block.length > 0
        let gapAbove = hasCredit && hasBlock ? (0.95 * bodySize).rounded() : 0
        let gapBelow = hasCredit && hasBlock ? (0.75 * bodySize).rounded() : 0
        let textW = max(blockSize.width, creditSize2.width)
        let ruleH = hasCredit && hasBlock ? hairline : 0
        let textH = blockSize.height + gapAbove + ruleH + gapBelow + (hasCredit ? creditSize2.height : 0)
        let pw = Int(ceil(textW + 2 * padX)), ph = Int(ceil(textH + 2 * padY))
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSubpixelPositioning(true)
        // CoreGraphics is y up: lay out from the top edge down.
        var top = CGFloat(ph) - padY
        if hasBlock {
            let r = CGRect(x: padX, y: top - blockSize.height, width: measure, height: blockSize.height)
            CTFrameDraw(CTFramesetterCreateFrame(blockSetter, CFRange(location: 0, length: 0),
                                                 CGPath(rect: r, transform: nil), nil), ctx)
            top -= blockSize.height + gapAbove
        }
        if ruleH > 0 {
            ctx.setFillColor(gray: 0.22, alpha: 1)
            ctx.fill(CGRect(x: padX, y: top - ruleH, width: textW, height: ruleH))
            top -= ruleH + gapBelow
        }
        if hasCredit {
            let r = CGRect(x: padX, y: top - creditSize2.height, width: maxText, height: creditSize2.height)
            CTFrameDraw(CTFramesetterCreateFrame(creditSetter, CFRange(location: 0, length: 0),
                                                 CGPath(rect: r, transform: nil), nil), ctx)
        }
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
        rect = SIMD4(Float(margin), Float(h - margin) - Float(ph), Float(pw), Float(ph))
    }
}
