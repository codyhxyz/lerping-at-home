import AppKit
import CoreText
import Metal

/// Pixel-sized, premultiplied overlay. Owned by the provider's serial render path.
final class ArtifactHUDLayer {
    private let device: MTLDevice
    private var texture: MTLTexture?
    private var previous: ArtifactCard?
    private var size = SIMD2<Float>.zero
    private var status = false
    init(device: MTLDevice) { self.device = device }
    var bindable: MTLTexture? { texture }

    func update(card: ArtifactCard, drawable size: SIMD2<Float>, showStatus: Bool, commandBuffer: MTLCommandBuffer) {
        guard previous != card || self.size != size || status != showStatus || texture == nil else { return }
        let tiny = size.y < 180
        let w = tiny ? 1 : max(1, Int(size.x)), h = tiny ? 1 : max(1, Int(size.y))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        if !tiny {
            let H = CGFloat(h), W = CGFloat(w), margin = H * 0.055
            let x = W > H * 1.25 ? W * 0.59 : margin
            let width = max(1, W - x - margin)
            func text(_ s: String, y: CGFloat, height: CGFloat, scale: CGFloat, muted: Bool = false) {
                let p = NSMutableParagraphStyle(); p.lineHeightMultiple = 1.18
                let font = NSFont(name: "IowanOldStyle-Roman", size: H * scale) ?? NSFont(name: "Georgia", size: H * scale) ?? .systemFont(ofSize: H * scale)
                let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: muted ? NSColor(white: 0.65, alpha: 1) : NSColor(red: 0.949, green: 0.937, blue: 0.902, alpha: 1), .paragraphStyle: p])
                let f = CTFramesetterCreateWithAttributedString(a)
                let path = CGPath(rect: CGRect(x: x, y: y, width: width, height: height), transform: nil)
                c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: -1), blur: H * 0.004, color: NSColor.black.cgColor)
                CTFrameDraw(CTFramesetterCreateFrame(f, CFRange(location: 0, length: 0), path, nil), c); c.restoreGState()
            }
            text("LEVEL  \(card.level)", y: H * 0.9, height: H * 0.05, scale: 0.024)
            let bar = CGRect(x: x, y: H * 0.875, width: width, height: H * 0.007)
            c.setStrokeColor(NSColor(white: 0.7, alpha: 0.8).cgColor); c.stroke(bar)
            c.setFillColor(NSColor(red: 0.85, green: 0.79, blue: 0.59, alpha: 1).cgColor)
            c.fill(CGRect(x: bar.minX + 2, y: bar.minY + 2, width: max(0, (bar.width - 4) * CGFloat(min(1, max(0, card.xpProgress)))), height: max(1, bar.height - 4)))
            text(card.title, y: H * 0.48, height: H * 0.13, scale: 0.036)
            c.setLineWidth(0.7); c.move(to: CGPoint(x: x, y: H * 0.475)); c.addLine(to: CGPoint(x: x + width, y: H * 0.475)); c.strokePath()
            text(card.subtitle.uppercased(), y: H * 0.395, height: H * 0.065, scale: 0.017, muted: true)
            text(card.tipHeading, y: H * 0.325, height: H * 0.05, scale: 0.019)
            text(card.loreBody, y: H * 0.08, height: H * 0.24, scale: 0.022)
            if showStatus {
                let a = NSAttributedString(string: "◇  " + card.statusLine, attributes: [.font: NSFont.systemFont(ofSize: H * 0.014), .foregroundColor: NSColor(white: 0.6, alpha: 0.8)])
                c.textPosition = CGPoint(x: margin, y: H * 0.94)
                CTLineDraw(CTLineCreateWithAttributedString(a), c)
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: !tiny)
        d.usage = [.shaderRead]; d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d), let data = c.data else { return }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        if !tiny, let blit = commandBuffer.makeBlitCommandEncoder() { blit.generateMipmaps(for: t); blit.endEncoding() }
        texture = t; previous = card; self.size = size; status = showStatus
    }
}
