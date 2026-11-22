import AVFoundation
import Foundation

/// Exercises the real Metal, IOSurface, and H.264 path, not a mock writer.
enum LoopExportSelfTest {
    private enum Failure: Error { case check(String) }

    static func run() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await exercise() }
            catch { PreviewMain.fail("export self-test: \(error)") }
            done.signal()
        }
        // The CLI has no running AppKit event loop. AVFoundation's loads and
        // the exporter run off main; only the process waits here.
        guard done.wait(timeout: .now() + 120) == .success else { PreviewMain.fail("export self-test timed out") }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.check(message) }
    }

    private static func exercise() async throws {
        let dir = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("lerp-loop-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shader = LerpShader(name: "export-test", source: """
            // lerp-param: wash float 0 1 = 0.12
            // lerp-animate: wash 0.08 0.18 period=10
            fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
                float centered = (u.viewer.x == 0.0 && u.viewer.y == 0.0 && u.audioLevel == 0.0) ? 1.0 : 0.0;
                float brightness = mix(0.13, 0.88, clamp(u.time / 10.0, 0.0, 1.0));
                return half4(half3(brightness * (0.7 + 0.3 * pos.x / u.resolution.x) + 0.12 * u.wash + 0.05 * u.seed) * centered, 1.0);
            }
            """, isBuiltIn: false, url: nil)
        let look = LerpLoopExport.Look(shader: shader, parameters: shader.defaultParameterValues(), seed: 0.41, startTime: 0)
        let crossfade = LerpLoopExport.Mode.crossfade(windowSeconds: 2)
        let periodic = LerpLoopExport.Mode.periodic(periodSeconds: 4)
        try check(periodic.sample(frame: 150, start: 3).first == 5 && periodic.sample(frame: 300, start: 3).first == 7,
                  "periodic mode must sample its full cycle, not raw movie seconds")
        let midpoint = crossfade.sample(frame: 270, start: 3)
        try check(midpoint.first == 12 && midpoint.second == 2 && midpoint.weight == 0.5,
                  "crossfade must mix F(s+t) with F(s+t−T) at smoothstep weights")
        let movie = dir.appendingPathComponent("loop.mp4")
        let credit = LerpMuseumPlacard(title: "Lerping", artist: "Preview",
                                      remixedFrom: .init(title: "Test", artist: "Fixture"))
        let result: URL = try await withCheckedThrowingContinuation { continuation in
            LerpLoopExport.start(look: look, width: 320, height: 180, mode: crossfade, placard: credit, to: movie) {
                continuation.resume(with: $0)
            }
        }
        try check(result == movie, "completed export did not deliver the requested URL")
        try await inspect(movie, look: look)
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        try check(contents == [movie.lastPathComponent], "successful export leaked a temporary file")

        // Hold the writer at its first progress callback, cancel from a
        // different thread, then let it unwind. A pre-existing file must
        // survive, and the partial MP4 must not appear at its path.
        let existing = dir.appendingPathComponent("existing.mp4")
        let original = Data("not ours to delete".utf8)
        try original.write(to: existing)
        let wroteFrame = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let reachedEncoder = DispatchSemaphore(value: 0)
        let cancelled: Result<URL, Error> = await withCheckedContinuation { continuation in
            let handle = LerpLoopExport.start(look: look, width: 180, height: 320, mode: periodic, to: existing, progress: { count in
                if count == 1 { wroteFrame.signal(); resume.wait() }
            }) { continuation.resume(returning: $0) }
            DispatchQueue.global().async {
                if wroteFrame.wait(timeout: .now() + 10) == .success { reachedEncoder.signal() }
                handle.cancel()
                resume.signal()
            }
        }
        guard case .failure(LerpLoopExport.Failure.cancelled) = cancelled else {
            throw Failure.check("cancelling did not report cancellation: \(cancelled)")
        }
        try check(hasSignal(reachedEncoder), "cancellation did not exercise an in-progress writer")
        let preserved = try Data(contentsOf: existing)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        try check(preserved == original && Set(remaining) == Set([movie.lastPathComponent, existing.lastPathComponent]),
                  "cancelled export published or leaked a partial movie: \(remaining)")
        try FileManager.default.removeItem(at: dir)
        print("OK    H.264 Rec.709, 300 decoded frames at 30 fps, 10.0s, nonblank linear-light crossfade; cancellation and cleanup")
    }

    private static func hasSignal(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    private static func inspect(_ url: URL, look: LerpLoopExport.Look) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let video = tracks.first else { throw Failure.check("MP4 has no video track") }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        try check(tracks.count == 1 && audio.isEmpty, "unexpected tracks")
        try check(abs(duration - 10) <= 0.05, "duration was \(duration), expected 10.0s")
        let formats = try await video.load(.formatDescriptions)
        guard let format = formats.first else { throw Failure.check("video has no format") }
        try check(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264, "video is not H.264")
        for (key, expected) in [
            (kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2),
            (kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2),
            (kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2),
        ] {
            let tag = CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
            try check(tag == expected as String, "incorrect \(key) tag: \(tag ?? "missing")")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        try check(reader.startReading(), "could not start decoding")
        var count = 0
        var lumaByFrame: [Int: Int] = [:]
        while let sample = output.copyNextSampleBuffer() {
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try check(abs(presentation - Double(count) / 30) < 0.001, "non-contiguous timestamp at frame \(count): \(presentation)")
            if [0, 150, 239, 270, 299].contains(count), let pixel = CMSampleBufferGetImageBuffer(sample) {
                try check(CVPixelBufferGetWidth(pixel) == 320 && CVPixelBufferGetHeight(pixel) == 180, "incorrect decoded dimensions")
                let status = CVPixelBufferLockBaseAddress(pixel, .readOnly)
                try check(status == kCVReturnSuccess, "could not read decoded pixels")
                defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
                guard let bytes = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) else {
                    throw Failure.check("missing decoded pixels")
                }
                let row = 55 * CVPixelBufferGetBytesPerRow(pixel)
                let left = Int(bytes[row + 32 * 4 + 1]), right = Int(bytes[row + 288 * 4 + 1])
                try check(left > 12 && right > left + 4, "blank or spatially flat frame \(count): \(left), \(right)")
                if count == 150 {
                    let inkRow = 150 * CVPixelBufferGetBytesPerRow(pixel)
                    let withPlacard = Int(bytes[inkRow + 8 * 4 + 1])
                    let bare = Int(bytes[row + 8 * 4 + 1])
                    try check(withPlacard < bare - 12, "optional placard did not reach the encoded frame")
                }
                lumaByFrame[count] = right
            }
            count += 1
        }
        try check(reader.status == .completed && count == 300, "decoder produced \(count) frames: \(String(describing: reader.error))")
        guard let first = lumaByFrame[0], let middle = lumaByFrame[150], let before = lumaByFrame[239],
              let blend = lumaByFrame[270], let last = lumaByFrame[299] else { throw Failure.check("missing pixel samples") }
        try check(middle > first + 35 && before > middle + 20 && blend < before && blend > first + 25
                  && abs(last - first) < 8, "unexpected motion or loop seam: \(lumaByFrame)")
        func linearSample(_ time: Float) throws -> Double {
            guard case .scalar(let wash) = look.parameters.resolved(time: time, seed: look.seed)["wash"] else {
                throw Failure.check("missing fixture drift")
            }
            let brightness = 0.13 + 0.75 * min(1, max(0, Double(time) / 10))
            let encoded = brightness * (0.7 + 0.3 * 288.5 / 320) + 0.12 * wash + 0.05 * Double(look.seed)
            return pow((encoded + 0.055) / 1.055, 2.4)
        }
        let linearMidpoint = try (linearSample(9) + linearSample(-1)) * 0.5
        let expected = (1.099 * pow(linearMidpoint, 0.45) - 0.099) * 255
        try check(abs(Double(blend) - expected) < 9, "mid-fade is not linear light: observed \(blend), expected ~\(expected)")
    }
}
