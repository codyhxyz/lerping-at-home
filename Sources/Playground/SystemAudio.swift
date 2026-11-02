import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os
import QuartzCore
import simd

// System-audio input for the `audio*` uniforms: a Core Audio process tap on
// everything the Mac is playing, an aggregate device to clock it, and an FFT
// that boils each 1024-sample window down to four smoothed levels.
//
// Playground only. The saver runs inside Apple's sandboxed `legacyScreenSaver`
// host, which has no `NSAudioCaptureUsageDescription` for TCC to show and so
// cannot be granted system-audio capture; it renders with `.silent`, which is
// exactly what every shader rendered before these uniforms existed.

/// Pure DSP: mono samples in, `LerpAudioLevels` out. No Core Audio in here, so
/// a probe can drive it with a synthetic tone as easily as with the tap.
final class AudioBandAnalyzer {
    static let fftSize = 1024
    /// New samples between analyses: 50% overlap, ~94 updates/s at 48 kHz —
    /// faster than any display the levels end up on.
    static let hop = 512

    /// Band edges in Hz. `level` is broadband RMS rather than a band.
    static let bass: ClosedRange<Double> = 20...250
    static let mid: ClosedRange<Double> = 250...4_000
    static let treble: ClosedRange<Double> = 4_000...16_000

    /// dB (re full scale, mean-square) mapped onto 0…1. Treble carries far less
    /// energy than bass in almost all program material, so its window sits
    /// lower; otherwise it would barely leave zero.
    private static let floors: SIMD4<Float> = [-54, -54, -60, -72]
    private static let spans: SIMD4<Float> = [42, 42, 42, 42]
    /// Envelope follower time constants: snap up to a hit, ease back down.
    private static let attack: Double = 0.025
    private static let release: Double = 0.30

    let sampleRate: Double
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private let meanSquareScale: Float
    private let bins: [Range<Int>]
    private let attackK: Float, releaseK: Float

    private var ring = [Float](repeating: 0, count: fftSize)
    private var writeIndex = 0
    private var pending = 0
    private var frame = [Float](repeating: 0, count: fftSize)
    private var real = [Float](repeating: 0, count: fftSize / 2)
    private var imag = [Float](repeating: 0, count: fftSize / 2)
    private var power = [Float](repeating: 0, count: fftSize / 2)
    private var smoothed = SIMD4<Float>(repeating: 0)

    init(sampleRate: Double) {
        let n = Self.fftSize
        self.sampleRate = sampleRate
        fft = vDSP.FFT(log2n: vDSP_Length(n.trailingZeroBitCount), radix: .radix2,
                       ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: n, isHalfWindow: false)
        // vDSP's real FFT returns 2× the DFT, so |out|² = 4|X|². Parseval with
        // the window's energy then gives each bin's share of the signal's mean
        // square: a full-scale sine sums to 0.5 across its main lobe.
        meanSquareScale = 1 / (2 * Float(n) * vDSP.sum(vDSP.multiply(window, window)))
        let binHz = sampleRate / Double(n)
        bins = [Self.bass, Self.mid, Self.treble].map { band in
            let lo = max(1, Int((band.lowerBound / binHz).rounded()))
            let hi = min(n / 2, max(lo + 1, Int((band.upperBound / binHz).rounded())))
            return lo..<hi
        }
        let dt = Double(Self.hop) / sampleRate
        attackK = Float(1 - exp(-dt / Self.attack))
        releaseK = Float(1 - exp(-dt / Self.release))
    }

    /// Feeds mono samples; calls `emit` once per completed analysis window.
    func process(_ samples: UnsafeBufferPointer<Float>, emit: (LerpAudioLevels) -> Void) {
        let n = Self.fftSize
        for sample in samples {
            ring[writeIndex] = sample.isFinite ? sample : 0
            writeIndex = (writeIndex + 1) & (n - 1)
            pending += 1
            if pending >= Self.hop {
                pending = 0
                emit(analyze())
            }
        }
    }

    private func analyze() -> LerpAudioLevels {
        let n = Self.fftSize
        // Oldest sample first: the ring's write head is where the window starts.
        let head = n - writeIndex
        frame.withUnsafeMutableBufferPointer { out in
            ring.withUnsafeBufferPointer { src in
                out.baseAddress!.update(from: src.baseAddress! + writeIndex, count: head)
                (out.baseAddress! + head).update(from: src.baseAddress!, count: writeIndex)
            }
        }
        let rms = vDSP.rootMeanSquare(frame)
        vDSP.multiply(frame, window, result: &frame)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                // imagp[0] is the Nyquist term, not DC's imaginary part. No band
                // reaches either end, so zero it rather than mis-fold it.
                ip[0] = 0
                vDSP.squareMagnitudes(split, result: &power)
            }
        }

        func decibels(_ meanSquare: Float) -> Float { 10 * log10(max(meanSquare, 1e-12)) }
        var db = SIMD4<Float>(decibels(rms * rms), 0, 0, 0)
        for (i, range) in bins.enumerated() {
            let sum = power.withUnsafeBufferPointer { vDSP.sum(UnsafeBufferPointer(rebasing: $0[range])) }
            db[i + 1] = decibels(sum * meanSquareScale)
        }
        let target = simd_clamp((db - Self.floors) / Self.spans, .zero, .one)
        let rising = target .> smoothed
        let k = SIMD4<Float>(repeating: releaseK).replacing(with: attackK, where: rising)
        smoothed += (target - smoothed) * k
        return LerpAudioLevels(level: smoothed[0], bass: smoothed[1],
                               mid: smoothed[2], treble: smoothed[3])
    }
}

/// The latest levels, handed from the audio queue to the render thread.
/// Readers get `.silent` once the tap has gone quiet for longer than a few
/// frames — a stalled device must not freeze a shader mid-pulse.
final class AudioLevelBox: Sendable {
    private struct State { var levels = LerpAudioLevels.silent; var stamp: CFTimeInterval = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private static let staleAfter: CFTimeInterval = 0.5

    func publish(_ levels: LerpAudioLevels) {
        let now = CACurrentMediaTime()
        state.withLock { $0 = State(levels: levels, stamp: now) }
    }

    func reset() { state.withLock { $0 = State() } }

    var current: LerpAudioLevels {
        let now = CACurrentMediaTime()
        return state.withLock { now - $0.stamp > Self.staleAfter ? .silent : $0.levels }
    }
}

/// A process tap on every process's output, routed through a private
/// aggregate device so it has a clock and an IOProc. Start and stop on the
/// main thread; the IOProc runs on its own serial queue and touches nothing
/// but the analyzer it was created with and the `AudioLevelBox`.
///
/// The first start triggers the system's "System Audio Recording" prompt,
/// worded by `NSAudioCaptureUsageDescription`. Until it is granted the tap
/// delivers silence rather than an error, so a denied tap reads as zeros.
@available(macOS 14.2, *)
final class SystemAudioTap {
    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (OSStatus \(status))" }
    }

    let levels = AudioLevelBox()
    /// Told when the default output device changes and the tap is rebuilt, or
    /// when that rebuild fails. Main thread.
    var onRestart: ((Error?) -> Void)?

    private let ioQueue = DispatchQueue(label: "com.hergenroeder.lerping.audio-tap",
                                        qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    deinit { stop() }

    func start() throws {
        guard !isRunning else { return }
        do {
            try build()
        } catch {
            tearDown()
            throw error
        }
        isRunning = true
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.restart()
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &Self.defaultOutputAddress, .main, listener)
    }

    func stop() {
        if let listener = deviceListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &Self.defaultOutputAddress, .main, listener)
            deviceListener = nil
        }
        tearDown()
        isRunning = false
        levels.reset()
    }

    /// The aggregate is clocked by the output device it was built on, so a
    /// switch to headphones or AirPlay rebuilds it on the new one.
    private func restart() {
        guard isRunning else { return }
        tearDown()
        do {
            try build()
            onRestart?(nil)
        } catch {
            tearDown()
            isRunning = false
            onRestart?(error)
        }
    }

    private func build() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Lerping@Home audio-reactive uniforms"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("AudioHardwareCreateProcessTap",
                  AudioHardwareCreateProcessTap(description, &tapID))

        var format = AudioStreamBasicDescription()
        try read(tapID, kAudioTapPropertyFormat, into: &format)
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
            throw Failure(step: "tap format is not 32-bit float PCM", status: -1)
        }
        sampleRate = format.mSampleRate

        var outputID = AudioObjectID(kAudioObjectUnknown)
        try read(AudioObjectID(kAudioObjectSystemObject),
                 kAudioHardwarePropertyDefaultOutputDevice, into: &outputID)
        var uid: Unmanaged<CFString>?
        try read(outputID, kAudioDevicePropertyDeviceUID, into: &uid)
        guard let outputUID = uid?.takeRetainedValue() as String? else {
            throw Failure(step: "reading the output device UID", status: -1)
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lerping@Home audio tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("AudioHardwareCreateAggregateDevice",
                  AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        // Captured by the block, not stored on self: a rebuilt tap gets a fresh
        // analyzer and nothing outside the IO queue ever touches this one.
        let analyzer = AudioBandAnalyzer(sampleRate: format.mSampleRate)
        let box = levels
        var mono = [Float](repeating: 0, count: 4096)
        try check("AudioDeviceCreateIOProcIDWithBlock",
                  AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0, let first = buffers.first, first.mNumberChannels > 0 else { return }
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
            guard frames > 0 else { return }
            if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
            mono.withUnsafeMutableBufferPointer { out in
                out.update(repeating: 0)
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let stride = Int(buffer.mNumberChannels)
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let available = min(frames, Int(buffer.mDataByteSize) / (4 * stride))
                    for f in 0..<available {
                        var sum: Float = 0
                        for c in 0..<stride { sum += samples[f * stride + c] }
                        out[f] += sum
                    }
                }
                let scale = 1 / Float(channels)
                for f in 0..<frames { out[f] *= scale }
                analyzer.process(UnsafeBufferPointer(rebasing: out[0..<frames])) { box.publish($0) }
            }
        })
        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, procID))
    }

    private func tearDown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw Failure(step: step, status: status) }
    }

    private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         into value: inout T) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &value) { raw in
            try check("reading property \(selector)",
                      AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw.baseAddress!))
        }
    }
}
