import AVFoundation
import CoreText
import CoreVideo
import Metal
import Darwin

/// Display credit, shared by the frame window and the optional MP4 overlay.
struct LerpMuseumPlacard: Sendable {
    var title: String
    var artist: String
    var remixedFrom: Remix? = nil

    struct Remix: Sendable {
        var title: String
        var artist: String
    }

    var remixLine: String? { remixedFrom.map { "Remixed from \($0.title) by \($0.artist)" } }

    init(title: String, artist: String, remixedFrom: Remix? = nil) {
        self.title = title
        self.artist = artist
        self.remixedFrom = remixedFrom
    }

    init(shader: LerpShader, preset: String?) {
        let name = shader.captionLines.first { $0.role == .title }?.text ?? shader.displayName
        title = name + (preset.map { " · \($0)" } ?? "")
        let authors = ShaderMetadata.parse(source: shader.source).authors
        artist = authors.isEmpty ? (shader.captionLines.first { $0.role == .credit }?.text ?? "Artist not credited")
                                 : authors.joined(separator: ", ")
    }
}

/// Offline SDR export. The input is a value snapshot, not a handle to the
/// editor. In particular an active drift is carried as its curve + pin state,
/// not evaluated once (nor reread from the editor as the frames are written).
public enum LerpLoopExport {
    public static let framesPerSecond: Int32 = 30
    public static let frameCount = 300
    public static let duration = Double(frameCount) / Double(framesPerSecond)

    public struct Look: Sendable {
        let shader: LerpShader
        let parameters: LerpParameterValues
        let seed: Float
        let startTime: Double

        public init(shader: LerpShader, parameters: LerpParameterValues, seed: Float, startTime: Double) {
            self.shader = shader
            self.parameters = parameters
            self.seed = seed
            self.startTime = startTime
        }
    }

    public enum Mode: Sendable {
        /// Sample one whole, caller-supplied cycle over the 10-second file.
        /// Only seamless when *the entire look*, including drifts, repeats on
        /// that cycle. No attempt is made to guess a period from Metal code.
        case periodic(periodSeconds: Double = LerpLoopExport.duration)
        /// Blend into the preceding cycle's time in the last `windowSeconds`.
        /// With u=t−T and weight→1, the endpoint approaches F(s) from
        /// earlier shader times. It does not dissolve to a held still.
        case crossfade(windowSeconds: Double)

        fileprivate var isValid: Bool {
            switch self {
            case .periodic(let period): return period.isFinite && period > 0 && Float(period).isFinite
            case .crossfade(let window): return window.isFinite && window > 0 && window <= LerpLoopExport.duration
            }
        }

        func sample(frame: Int, start: Double) -> (first: Float, second: Float?, weight: Float) {
            let t = Double(frame) / Double(LerpLoopExport.framesPerSecond)
            let duration = LerpLoopExport.duration
            switch self {
            case .periodic(let period): return (Float(start + t / duration * period), nil, 0)
            case .crossfade(let window):
                let u = t - duration
                guard u > -window else { return (Float(start + t), nil, 0) }
                let x = min(1, max(0, 1 + u / window))
                return (Float(start + t), Float(start + u), Float(x * x * (3 - 2 * x)))
            }
        }
    }

    public enum Failure: LocalizedError {
        case invalidSettings, noMetal, rendering(String), writing(String), cancelled

        public var errorDescription: String? {
            switch self {
            case .invalidSettings: return "Use positive even dimensions, valid look settings, and a positive loop period or crossfade of at most 10 seconds."
            case .noMetal: return "Metal is unavailable."
            case .rendering(let message): return "Could not render the loop: \(message)"
            case .writing(let message): return "Could not write the MP4: \(message)"
            case .cancelled: return "Loop export cancelled."
            }
        }
    }

    /// One lock defines the commit point: cancellation that wins this lock
    /// before the rename leaves the destination untouched, even when replacing
    /// an existing movie. After the rename, cancellation cannot undo success.
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var committed = false
        fileprivate var wake: (() -> Void)?

        public func cancel() {
            lock.lock()
            guard !cancelled, !committed else { lock.unlock(); return }
            cancelled = true
            let wake = self.wake
            lock.unlock()
            wake?()
        }

        fileprivate var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        fileprivate func publish(from temporary: URL, to destination: URL) throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw Failure.cancelled }
            // The job directory is beside the destination; this same-volume
            // POSIX rename is atomic, including replacement.
            let status = temporary.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in rename(source, target) }
            }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            committed = true
        }
    }

    /// `progress` (frames written) and `completion` run on the serial worker,
    /// not main. Only completion with success means a movie was published.
    @discardableResult
    public static func start(look: Look, width: Int, height: Int, mode: Mode, to destination: URL,
                             progress: @escaping (Int) -> Void = { _ in },
                             completion: @escaping (Result<URL, Error>) -> Void) -> Cancellation {
        start(look: look, width: width, height: height, mode: mode, placard: nil,
              to: destination, progress: progress, completion: completion)
    }

    @discardableResult
    static func start(look: Look, width: Int, height: Int, mode: Mode, placard: LerpMuseumPlacard?,
                      to destination: URL, progress: @escaping (Int) -> Void = { _ in },
                      completion: @escaping (Result<URL, Error>) -> Void) -> Cancellation {
        let job = Job(look: look, width: width, height: height, mode: mode, placard: placard,
                      destination: destination, progress: progress, completion: completion)
        job.cancellation.wake = { [weak job] in job?.wakeForCancellation() }
        job.queue.async { job.prepare() }
        return job.cancellation
    }

    /// All mutable writer/render state is owned by this queue. The only state
    /// the caller touches after setup is the locked cancellation handle.
    private final class Job: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.hergenroeder.lerping.loop-export", qos: .userInitiated)
        let cancellation = Cancellation()
        private let look: Look
        private let width: Int
        private let height: Int
        private let mode: Mode
        private let placard: LerpMuseumPlacard?
        private let destination: URL
        private let temporaryDirectory: URL
        private let temporary: URL
        private let progress: (Int) -> Void
        private let completion: (Result<URL, Error>) -> Void
        private var writer: AVAssetWriter?
        private var input: AVAssetWriterInput?
        private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        private var render: Render?
        private var watchdog: DispatchSourceTimer?
        private var ownsTemporaryDirectory = false
        private var frame = 0
        private var finishing = false
        private var done = false

        init(look: Look, width: Int, height: Int, mode: Mode, placard: LerpMuseumPlacard?, destination: URL,
             progress: @escaping (Int) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
            self.look = look
            self.width = width
            self.height = height
            self.mode = mode
            self.placard = placard
            self.destination = destination
            let directory = destination.deletingLastPathComponent()
                .appendingPathComponent(".lerp-export-\(UUID().uuidString)", isDirectory: true)
            temporaryDirectory = directory
            temporary = directory.appendingPathComponent("loop.mp4")
            self.progress = progress
            self.completion = completion
        }

        func wakeForCancellation() {
            queue.async { [weak self] in self?.finish(.failure(Failure.cancelled)) }
        }

        func prepare() {
            do {
                guard !cancellation.isCancelled else { throw Failure.cancelled }
                let last = mode.sample(frame: frameCount - 1, start: look.startTime)
                guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2),
                      destination.isFileURL, mode.isValid, look.seed.isFinite,
                      Float(look.startTime).isFinite, last.first.isFinite, last.second?.isFinite ?? true,
                      look.parameters.parameters == look.shader.parameters else { throw Failure.invalidSettings }
                render = try Render(look: look, width: width, height: height, mode: mode, placard: placard)
                guard !cancellation.isCancelled else { throw Failure.cancelled }
                // AVAssetWriter can create its own sidecar files. Keep them
                // under one name that can be removed even on a failed export.
                try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
                ownsTemporaryDirectory = true
                let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
                self.writer = writer
                writer.shouldOptimizeForNetworkUse = true
                let settings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width, AVVideoHeightKey: height,
                    AVVideoColorPropertiesKey: [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                    ],
                    AVVideoCompressionPropertiesKey: [
                        AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                        AVVideoAverageBitRateKey: max(500_000, min(40_000_000, Double(width) * Double(height) * 6)),
                    ],
                ]
                guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                    throw Failure.writing("these dimensions are not supported by the H.264 encoder")
                }
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                input.expectsMediaDataInRealTime = false
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                ])
                guard writer.canAdd(input) else { throw Failure.writing("cannot add the video input") }
                writer.add(input)
                guard writer.startWriting() else { throw writerFailure() }
                writer.startSession(atSourceTime: .zero)
                guard adaptor.pixelBufferPool != nil else { throw Failure.writing("no pixel buffer pool") }
                self.input = input
                self.adaptor = adaptor

                // Readiness owns production; the watchdog only catches an
                // asynchronous failure that can leave readiness false forever.
                // It retains this job until finish cancels it.
                let watchdog = DispatchSource.makeTimerSource(queue: queue)
                watchdog.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
                watchdog.setEventHandler { [self] in
                    if writer.status == .failed || writer.status == .cancelled {
                        finish(.failure(writerFailure()))
                    }
                }
                self.watchdog = watchdog
                watchdog.resume()
                input.requestMediaDataWhenReady(on: queue) { [weak self] in self?.writeReadyFrames() }
            } catch {
                finish(.failure(error))
            }
        }

        private func writeReadyFrames() {
            guard !done, !finishing, let writer, let input, let adaptor, let render,
                  let pool = adaptor.pixelBufferPool else { return }
            do {
                while input.isReadyForMoreMediaData, frame < frameCount {
                    try autoreleasepool {
                        guard !cancellation.isCancelled else { throw Failure.cancelled }
                        var pixelBuffer: CVPixelBuffer?
                        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
                        guard status == kCVReturnSuccess, let pixelBuffer else {
                            throw Failure.writing("pixel buffer allocation failed (\(status))")
                        }
                        try render.draw(to: pixelBuffer, sample: mode.sample(frame: frame, start: look.startTime))
                        guard !cancellation.isCancelled else { throw Failure.cancelled }
                        let timestamp = CMTime(value: Int64(frame), timescale: framesPerSecond)
                        guard adaptor.append(pixelBuffer, withPresentationTime: timestamp) else { throw writerFailure() }
                        frame += 1
                        progress(frame)
                    }
                }
                if frame == frameCount {
                    finishing = true
                    self.render = nil
                    writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: framesPerSecond))
                    input.markAsFinished()
                    writer.finishWriting { [self] in queue.async { self.publish() } }
                }
            } catch {
                finish(.failure(error))
            }
        }

        private func writerFailure() -> Error {
            writer?.error ?? Failure.writing("the video encoder did not accept the frame or finish the file")
        }

        private func publish() {
            guard !done else { return }
            do {
                guard writer?.status == .completed else { throw writerFailure() }
                try cancellation.publish(from: temporary, to: destination)
                finish(.success(destination))
            } catch {
                finish(.failure(error))
            }
        }

        private func finish(_ result: Result<URL, Error>) {
            guard !done else { return }
            done = true
            watchdog?.cancel()
            watchdog = nil
            if case .failure = result, writer?.status == .writing { writer?.cancelWriting() }
            writer = nil
            input = nil
            adaptor = nil
            render = nil
            if ownsTemporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
            completion(result)
        }
    }

    private final class Render {
        private let look: Look
        private let renderer: LerpRenderer
        private let pipeline: MTLRenderPipelineState
        private let composite: MTLRenderPipelineState
        private let data: LerpDataProvider?
        private let seamData: LerpDataProvider?
        private let first: MTLTexture
        private let second: MTLTexture?
        private let overlay: MTLTexture?
        private let margin: Int
        private let cache: CVMetalTextureCache

        init(look: Look, width: Int, height: Int, mode: Mode, placard: LerpMuseumPlacard?) throws {
            self.look = look
            guard let renderer = LerpRenderer() else { throw Failure.noMetal }
            self.renderer = renderer
            let device = renderer.device
            let library = ShaderLibrary(device: device, mode: .still)
            let format = MTLPixelFormat.rgba16Float
            pipeline = try library.pipeline(for: look.shader, pixelFormat: format)
            data = try library.dataProvider(for: look.shader)
            (data as? SplatData)?.captionOpacity = 0
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .renderTarget]
            guard let first = device.makeTexture(descriptor: descriptor) else { throw Failure.rendering("texture allocation failed") }
            self.first = first
            if case .crossfade = mode {
                guard let second = device.makeTexture(descriptor: descriptor) else { throw Failure.rendering("seam texture allocation failed") }
                self.second = second
                // Each clock samples a separate provider so a replay-based
                // simulation is not scrubbed backwards every other pass.
                seamData = try ShaderLibrary(device: device, mode: .still).dataProvider(for: look.shader)
                (seamData as? SplatData)?.captionOpacity = 0
            } else {
                second = nil
                seamData = nil
            }
            let post = try device.makeLibrary(source: Self.compositeSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = post.makeFunction(name: "loopVertex")
            desc.fragmentFunction = post.makeFunction(name: "loopComposite")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            composite = try device.makeRenderPipelineState(descriptor: desc)
            margin = max(2, min(width, height) / 28)
            if let placard {
                overlay = try Self.makePlacard(placard, device: device, width: width, height: height)
            } else {
                overlay = nil
            }
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
                throw Failure.rendering("could not create the pixel buffer texture cache")
            }
            self.cache = cache
        }

        func draw(to pixelBuffer: CVPixelBuffer, sample: (first: Float, second: Float?, weight: Float)) throws {
            let width = first.width, height = first.height
            let usage = [kCVMetalTextureUsage as String: MTLTextureUsage.renderTarget.rawValue] as CFDictionary
            var wrapper: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, usage, .bgra8Unorm,
                                                                    width, height, 0, &wrapper)
            guard status == kCVReturnSuccess, let wrapper, let target = CVMetalTextureGetTexture(wrapper) else {
                throw Failure.rendering("could not map the BGRA pixel buffer to Metal (\(status))")
            }
            defer { withExtendedLifetime(wrapper) {} }
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

            func shaderPass(_ texture: MTLTexture, time: Float, provider: LerpDataProvider?) throws -> MTLCommandBuffer {
                let uniforms = LerpUniforms(resolution: SIMD2(Float(width), Float(height)), time: time, seed: look.seed,
                                            audio: .silent, viewer: .centered)
                guard let buffer = renderer.encodePass(target: texture, pipeline: pipeline, uniforms: uniforms,
                                                       params: look.parameters, data: provider) else {
                    throw Failure.rendering("could not encode the shader")
                }
                buffer.commit()
                return buffer
            }
            let a = try shaderPass(first, time: sample.first, provider: data)
            let b = try sample.second.flatMap { time in try second.map { try shaderPass($0, time: time, provider: seamData) } }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let buffer = renderer.commandQueue.makeCommandBuffer(),
                  let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw Failure.rendering("could not encode the post pass")
            }
            var blend = sample.weight
            var overlayRect = SIMD4<UInt32>.zero
            if let overlay {
                overlayRect = SIMD4(UInt32(margin), UInt32(max(0, height - margin - overlay.height)),
                                    UInt32(overlay.width), UInt32(overlay.height))
            }
            enc.setRenderPipelineState(composite)
            enc.setFragmentTexture(first, index: 0)
            enc.setFragmentTexture(b == nil ? first : second, index: 1)
            enc.setFragmentTexture(overlay ?? first, index: 2)
            enc.setFragmentBytes(&blend, length: MemoryLayout<Float>.size, index: 0)
            enc.setFragmentBytes(&overlayRect, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            buffer.commit()
            // Same Metal queue, so the preceding shader passes are done too.
            // Never submit the pixel buffer to VideoToolbox before this fence.
            buffer.waitUntilCompleted()
            for command in [a, b, buffer].compactMap({ $0 }) where command.status != .completed {
                throw command.error ?? Failure.rendering("GPU command did not complete")
            }
        }

        private static func makePlacard(_ placard: LerpMuseumPlacard, device: MTLDevice,
                                        width: Int, height: Int) throws -> MTLTexture {
            let shortSide = min(width, height)
            let fontSize = CGFloat(max(10, shortSide / 62))
            let padding = max(4, shortSide / 82)
            let lineHeight = Int(ceil(fontSize * 1.32))
            let maxWidth = max(1, Int(Double(width) * 0.64))
            let maxLineWidth = CGFloat(max(1, maxWidth - 2 * padding))
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            func line(_ text: String, title: Bool) -> CTLine {
                let font = CTFontCreateWithName((title ? "HelveticaNeue-Medium" : "HelveticaNeue") as CFString,
                                                title ? fontSize : fontSize * 0.9, nil)
                let shade: CGFloat = title ? 1 : 0.84
                let color = CGColor(colorSpace: space, components: [shade, shade, shade, 1])!
                func make(_ text: String) -> CTLine {
                    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                    ]))
                }
                let full = make(text)
                if CTLineGetTypographicBounds(full, nil, nil, nil) <= maxLineWidth { return full }
                let token = make("…")
                return CTLineCreateTruncatedLine(full, maxLineWidth, .end, token) ?? token
            }
            var lines = [line(placard.title, title: true), line(placard.artist, title: false)]
            if let remix = placard.remixLine { lines.append(line(remix, title: false)) }
            let measured = lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max() ?? 0
            let w = min(maxWidth, Int(ceil(measured)) + 2 * padding)
            let h = min(height, lineHeight * lines.count + 2 * padding)
            let flags = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            desc.storageMode = .shared
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: flags), let bytes = ctx.data,
                  let texture = device.makeTexture(descriptor: desc) else {
                throw Failure.rendering("placard texture allocation failed")
            }
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.clear(rect)
            ctx.setFillColor(CGColor(colorSpace: space, components: [0.04, 0.04, 0.04, 0.65])!)
            let radius = CGFloat(padding) * 0.55
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            for (index, line) in lines.enumerated() {
                ctx.textPosition = CGPoint(x: padding, y: h - padding - lineHeight * (index + 1) + lineHeight / 4)
                CTLineDraw(line, ctx)
            }
            texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
            return texture
        }

        private static let compositeSource = """
        #include <metal_stdlib>
        using namespace metal;

        vertex float4 loopVertex(uint vid [[vertex_id]]) {
            float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
            return float4(p[vid], 0, 1);
        }
        // Shaders output Display P3 with the sRGB transfer curve, as in the
        // live SDR layer. Decode before mixing, then convert the primaries.
        float3 decode(float3 e) {
            e = clamp(e, 0.0, 1.0);
            return select(pow((e + 0.055) / 1.055, 2.4), e / 12.92, e <= 0.04045);
        }
        fragment float4 loopComposite(float4 pos [[position]],
                                       texture2d<float, access::read> first [[texture(0)]],
                                       texture2d<float, access::read> second [[texture(1)]],
                                       texture2d<float, access::read> placard [[texture(2)]],
                                       constant float& weight [[buffer(0)]],
                                       constant uint4& rect [[buffer(1)]]) {
            uint2 px = uint2(pos.xy);
            float3 p3 = decode(first.read(px).rgb);
            if (weight > 0) p3 = mix(p3, decode(second.read(px).rgb), weight);
            // Linear Display P3 (D65) -> linear Rec.709 / sRGB (D65).
            float3 c = float3(dot(p3, float3(1.22494, -0.22494, 0)),
                              dot(p3, float3(-0.042057, 1.042057, 0)),
                              dot(p3, float3(-0.019638, -0.078636, 1.098274)));
            if (all(px >= rect.xy) && all(px - rect.xy < rect.zw)) {
                float4 ink = placard.read(px - rect.xy); // premultiplied sRGB
                if (ink.a > 0) c = mix(c, decode(ink.rgb / ink.a), ink.a);
            }
            c = clamp(c, 0.0, 1.0);
            return float4(select(1.099 * pow(c, 0.45) - 0.099, 4.5 * c, c < 0.018), 1);
        }
        """
    }
}
